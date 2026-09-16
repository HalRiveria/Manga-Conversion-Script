<#
.SYNOPSIS
    Standalone test harness for AbortPipeline.ps1.

.DESCRIPTION
    Dot-sources the real module (not a reimplementation) and exercises it
    with fake runspace jobs. Like Modules\ZipParallelProcessing.ps1
    elsewhere in this repo, this module IS the canonical source (not yet
    merged into Conversion Script Main.ps1), so there's nothing to keep in
    sync with a main-script copy yet.

    Scenarios D and E are timing-sensitive (they exercise a real Stopwatch-
    based timeout), but use small -TimeoutSeconds values instead of the
    original 60s, so the whole harness runs in a few seconds. Scenario E in
    particular is chosen with margin against the drain loop's fixed 250ms
    poll interval, not perfectly deterministic - see its comment.

.EXAMPLE
    .\Modules\_Harness\AbortPipeline.Harness.ps1
#>

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\AbortPipeline.ps1")

function Flush-ConsoleQueue {
    param([System.Collections.Concurrent.ConcurrentQueue[object]]$Queue)
    $item = $null
    while ($Queue.TryDequeue([ref]$item)) {
        Write-Host ("  [queued] " + $item)
    }
}

# AbortPipeline.ps1 forward-references $script:CleanConsoleOutputEnabled
# (owned by Logging.ps1, deliberately NOT redeclared here - absent/falsy
# on its own is harmless, no crash) and Write-GatedConsoleMessage (owned
# by CleanConsoleRendering.ps1, which itself calls
# Write-CleanConsoleMessage when its own -CleanConsoleOutputEnabled param
# is true). Write-GatedConsoleMessage is NOT optional the way the toggle
# variable is: Test-AbortSignal calls it on a real abort whenever
# $script:workerConsoleQueue is unset (i.e. every scenario below, since
# none of them set it - see the queue-routing scenario further down for
# the case where it IS set), so it must resolve to SOMETHING - real
# CleanConsoleRendering.ps1 is
# deliberately never dot-sourced here, and this stub is what satisfies
# that hard dependency instead (dot-sourcing only AbortPipeline.ps1 with
# NEITHER the real module nor this stub throws CommandNotFoundException
# the moment an abort fires). Call tracking on the inner stub, same
# pattern as Flush-ConsoleQueue above, so scenarios can assert WHICH path
# (raw Write-Host vs. this stub) actually fired for a given
# $script:CleanConsoleOutputEnabled value - not just that neither one
# threw.
$script:cleanConsoleMessageCalls = [System.Collections.Generic.List[hashtable]]::new()
function Write-CleanConsoleMessage {
    param([string]$Text, [string]$Color)
    $script:cleanConsoleMessageCalls.Add(@{ Text = $Text; Color = $Color })
}
function Write-GatedConsoleMessage {
    param([string]$Text, [string]$Color, [bool]$CleanConsoleOutputEnabled)
    if ($CleanConsoleOutputEnabled) {
        Write-CleanConsoleMessage -Text $Text -Color $Color
    } elseif ($Color) {
        Write-Host $Text -ForegroundColor $Color
    } else {
        Write-Host $Text
    }
}
$script:completeAllActiveSeriesProgressCallCount = 0
function Complete-AllActiveSeriesProgress {
    $script:completeAllActiveSeriesProgressCallCount++
}

$fakeWorkerOk = {
    param([int]$JobId, [int]$DelayMs)
    Start-Sleep -Milliseconds $DelayMs
    return @{ JobId = $JobId; Ok = $true }
}

$fakeWorkerFail = {
    param([int]$JobId)
    throw ("Simulated failure in worker " + $JobId)
}

function New-FakeHandles {
    param([int[]]$DelaysMs, [scriptblock]$Worker = $fakeWorkerOk)
    $pool = [RunspaceFactory]::CreateRunspacePool(1, [Math]::Max(1, $DelaysMs.Count))
    $pool.Open()
    $handles = [System.Collections.Generic.List[hashtable]]::new()
    for ($i = 0; $i -lt $DelaysMs.Count; $i++) {
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript($Worker)
        $null = $ps.AddParameter("JobId", $i + 1)
        if ($Worker -eq $fakeWorkerOk) { $null = $ps.AddParameter("DelayMs", $DelaysMs[$i]) }
        $handles.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
    }
    return @{ Pool = $pool; Handles = $handles }
}

$script:passCount = 0
$script:failCount = 0
function Test-Assert {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Host ("  [PASS] " + $Message) -ForegroundColor Green
        $script:passCount++
    } else {
        Write-Host ("  [FAIL] " + $Message) -ForegroundColor Red
        $script:failCount++
    }
}

function Reset-HarnessScenarioState {
    # Renamed from this harness's own former "Reset-AbortState" (2026-08-28)
    # once the real module gained a real function of that exact name - this
    # harness dot-sources the real module BEFORE defining its own helpers
    # (see top of file), so the harness's own same-named function was
    # silently shadowing the real one for every scenario in this file,
    # meaning NONE of them ever actually exercised it. Delegates the
    # abort-flag reset to the real Reset-AbortState now instead of
    # duplicating that logic by hand, so this harness's own per-scenario
    # cleanup can never silently drift from what the real function does -
    # only the extra test-isolation state below (CTS registry, CCR call
    # tracking) stays local, since the real function has no reason to know
    # about either.
    Reset-AbortState
    $script:abortCancellationSources.Clear()
    $script:CleanConsoleOutputEnabled = $false
    $script:cleanConsoleMessageCalls.Clear()
    $script:completeAllActiveSeriesProgressCallCount = 0
}

# ==============================================================================
#  Scenario A: Register/Unregister-AbortCancellationSource + Test-AbortSignal
#  cancels exactly the currently-registered set, exactly once.
# ==============================================================================
Write-Host "=== Scenario A: CTS registry + Test-AbortSignal ===" -ForegroundColor Cyan
Reset-HarnessScenarioState

$ctsKeep   = [System.Threading.CancellationTokenSource]::new()
$ctsDrop   = [System.Threading.CancellationTokenSource]::new()
$ctsRemove = [System.Threading.CancellationTokenSource]::new()
Register-AbortCancellationSource -Cts $ctsKeep
Register-AbortCancellationSource -Cts $ctsRemove
Unregister-AbortCancellationSource -Cts $ctsRemove   # should NOT get cancelled

[ConsoleCtrl]::AbortRequested = $true
[ConsoleCtrl]::IsCloseEvent   = $false
$firstResult  = Test-AbortSignal
$secondResult = Test-AbortSignal   # idempotency: should not throw or double-act

Test-Assert ($firstResult -eq $true) "Test-AbortSignal returns true after abort is signalled"
Test-Assert ($secondResult -eq $true) "Test-AbortSignal remains true on a second call"
Test-Assert ($ctsKeep.IsCancellationRequested -eq $true) "a registered CTS is cancelled"
Test-Assert ($ctsRemove.IsCancellationRequested -eq $false) "an unregistered CTS is NOT cancelled"
Test-Assert ($script:ctrlCloseAbort -eq $false) "ctrlCloseAbort is false for a Ctrl+C-style abort"
$ctsKeep.Dispose(); $ctsDrop.Dispose(); $ctsRemove.Dispose()
Write-Host ""

# ==============================================================================
#  Scenario A2: inside a runspace worker ($script:workerConsoleQueue set),
#  Test-AbortSignal must queue the abort message instead of calling
#  Write-GatedConsoleMessage directly - that function isn't in every
#  worker's -SharedFunctionNames list and would throw "term not
#  recognized" there (2026-09-14 fix).
# ==============================================================================
Write-Host "=== Scenario A2: Test-AbortSignal queues its message inside a worker ===" -ForegroundColor Cyan
Reset-HarnessScenarioState

$fakeQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:workerConsoleQueue = $fakeQueue
[ConsoleCtrl]::AbortRequested = $true
[ConsoleCtrl]::IsCloseEvent   = $false
$queuedResult = Test-AbortSignal

Test-Assert ($queuedResult -eq $true) "Test-AbortSignal still returns true when routing through the queue"
Test-Assert ($fakeQueue.Count -eq 1) "exactly one item was queued instead of calling Write-GatedConsoleMessage"
$queuedItem = $null
$null = $fakeQueue.TryDequeue([ref]$queuedItem)
Test-Assert ($queuedItem.Level -eq "Warn") "queued abort message uses Level=Warn, matching Flush-ConsoleQueue's expected shape"
Test-Assert ($queuedItem.Message -like "*Ctrl+C detected*") "queued abort message has the expected text"
Test-Assert ($script:cleanConsoleMessageCalls.Count -eq 0) "Write-GatedConsoleMessage/Write-CleanConsoleMessage was NOT called while the worker queue was set"

$script:workerConsoleQueue = $null
Write-Host ""

# ==============================================================================
#  Scenario B: Get-AbortTriggerLabel reflects Ctrl+C vs window-close.
# ==============================================================================
Write-Host "=== Scenario B: Get-AbortTriggerLabel ===" -ForegroundColor Cyan
Reset-HarnessScenarioState

[ConsoleCtrl]::AbortRequested = $true
[ConsoleCtrl]::IsCloseEvent   = $false
$null = Test-AbortSignal
Test-Assert ((Get-AbortTriggerLabel) -eq "Ctrl+C") "label is 'Ctrl+C' for a Ctrl+C abort"

Reset-HarnessScenarioState
[ConsoleCtrl]::AbortRequested = $true
[ConsoleCtrl]::IsCloseEvent   = $true
$null = Test-AbortSignal
Test-Assert ((Get-AbortTriggerLabel) -eq "window close (X button)") "label is 'window close (X button)' for an X-close abort"
Write-Host ""

# ==============================================================================
#  Scenario C: Invoke-GracefulDrain, all jobs finish comfortably inside the
#  timeout - results collected, ForceStoppedCount 0, DrainComplete signalled.
# ==============================================================================
Write-Host "=== Scenario C: Invoke-GracefulDrain, clean drain ===" -ForegroundColor Cyan
Reset-HarnessScenarioState

$fake = New-FakeHandles -DelaysMs @(100, 150, 120)
$resultsC = [System.Collections.Generic.List[hashtable]]::new()
$handlerC = { param($r) $resultsC.Add($r) }
$outcomeC = Invoke-GracefulDrain -Handles $fake.Handles -ResultHandler $handlerC -TimeoutSeconds 10
$fake.Pool.Close(); $fake.Pool.Dispose()

Test-Assert ($outcomeC.ForceStoppedCount -eq 0) "ForceStoppedCount is 0 when every job finishes in time"
Test-Assert ($resultsC.Count -eq 3) ("all 3 jobs' results were collected (got " + $resultsC.Count + ")")
Test-Assert ([ConsoleCtrl]::DrainComplete.IsSet) "DrainComplete was signalled after a clean drain"
Write-Host ""

# ==============================================================================
#  Scenario D: stragglers past the timeout get force-stopped. Uses a small
#  -TimeoutSeconds so this runs in ~2s instead of the original 60s.
# ==============================================================================
Write-Host "=== Scenario D: Invoke-GracefulDrain, force-stop after timeout ===" -ForegroundColor Cyan
Reset-HarnessScenarioState

$fake = New-FakeHandles -DelaysMs @(100, 30000, 30000)   # 1 fast, 2 that will never finish in time
$resultsD = [System.Collections.Generic.List[hashtable]]::new()
$handlerD = { param($r) $resultsD.Add($r) }
$outcomeD = Invoke-GracefulDrain -Handles $fake.Handles -ResultHandler $handlerD -TimeoutSeconds 1
$fake.Pool.Close(); $fake.Pool.Dispose()

Test-Assert ($outcomeD.ForceStoppedCount -eq 2) ("expected 2 force-stopped jobs, got " + $outcomeD.ForceStoppedCount)
Test-Assert ($resultsD.Count -eq 1) ("the 1 fast job's result was still collected (got " + $resultsD.Count + ")")
Test-Assert ([ConsoleCtrl]::DrainComplete.IsSet) "DrainComplete was signalled even when jobs were force-stopped"
Write-Host ""

# ==============================================================================
#  Scenario E: the CLAUDE.md "Known gaps" race - a job that finishes in the
#  ~250ms window between the drain loop's last poll and its timeout firing
#  must still be collected, not silently discarded/miscounted as
#  force-stopped. Timing-sensitive: the poll interval is a fixed 250ms, so a
#  job timed to land just inside the final gap (chosen with ~150ms margin on
#  either side) should reliably land there, but this is not bulletproof
#  against heavy system load.
# ==============================================================================
Write-Host "=== Scenario E: drain race - job finishing right at the timeout boundary ===" -ForegroundColor Cyan
Reset-HarnessScenarioState

$fake = New-FakeHandles -DelaysMs @(1900)
$resultsE = [System.Collections.Generic.List[hashtable]]::new()
$handlerE = { param($r) $resultsE.Add($r) }
$swE = [System.Diagnostics.Stopwatch]::StartNew()
$outcomeE = Invoke-GracefulDrain -Handles $fake.Handles -ResultHandler $handlerE -TimeoutSeconds 2
$swE.Stop()
$fake.Pool.Close(); $fake.Pool.Dispose()

Test-Assert ($outcomeE.ForceStoppedCount -eq 0) ("job that finished just before the timeout boundary was NOT force-stopped (got ForceStoppedCount=" + $outcomeE.ForceStoppedCount + ")")
Test-Assert ($resultsE.Count -eq 1) ("its result was collected despite finishing in the final poll gap (got " + $resultsE.Count + ")")
Write-Host ("  (drain took " + [math]::Round($swE.Elapsed.TotalSeconds, 2) + "s)") -ForegroundColor DarkGray
Write-Host ""

# ==============================================================================
#  Scenario F: empty Handles list - returns immediately, still signals
#  DrainComplete (covers "abort detected but nothing was ever dispatched").
# ==============================================================================
Write-Host "=== Scenario F: Invoke-GracefulDrain with no in-flight jobs ===" -ForegroundColor Cyan
Reset-HarnessScenarioState

$emptyHandles = [System.Collections.Generic.List[hashtable]]::new()
$outcomeF = Invoke-GracefulDrain -Handles $emptyHandles -TimeoutSeconds 60
Test-Assert ($outcomeF.ForceStoppedCount -eq 0) "ForceStoppedCount is 0 for an empty handle list"
Test-Assert ([ConsoleCtrl]::DrainComplete.IsSet) "DrainComplete is still signalled for an empty handle list"
Write-Host ""

# ==============================================================================
#  Scenario G: a worker that throws during drain collection is caught and
#  reported via -ErrorHandler, not silently swallowed (the duplicated inline
#  drain code this replaced had a bare `catch { }` here with no logging).
# ==============================================================================
Write-Host "=== Scenario G: worker throws during drain - reported, not silent ===" -ForegroundColor Cyan
Reset-HarnessScenarioState

$fake = New-FakeHandles -DelaysMs @(0) -Worker $fakeWorkerFail
$errorsG = [System.Collections.Generic.List[string]]::new()
$errHandlerG = { param($msg) $errorsG.Add($msg) }
$outcomeG = Invoke-GracefulDrain -Handles $fake.Handles -TimeoutSeconds 5 -ErrorHandler $errHandlerG
$fake.Pool.Close(); $fake.Pool.Dispose()

Test-Assert ($outcomeG.ForceStoppedCount -eq 0) "a thrown worker is not counted as force-stopped"
Test-Assert ($errorsG.Count -eq 1) ("the failure was reported via -ErrorHandler (got " + $errorsG.Count + " report(s))")
Write-Host ""

# ==============================================================================
#  Scenario H: Clean Console Output OFF (the default, $script:CleanConsole-
#  OutputEnabled = $false) - Test-AbortSignal keeps using raw Write-Host,
#  never calls the Write-CleanConsoleMessage stub. Captured via 6>&1 (the
#  same technique CleanConsoleRendering.Harness.ps1 uses) so this proves
#  real output was produced, not just that nothing threw.
# ==============================================================================
Write-Host "=== Scenario H: Clean Console Output off - unchanged raw Write-Host path ===" -ForegroundColor Cyan
Reset-HarnessScenarioState
[ConsoleCtrl]::AbortRequested = $true
[ConsoleCtrl]::IsCloseEvent   = $false
$outputH = & { Test-AbortSignal } 6>&1
$outputTextH = ($outputH | ForEach-Object { $_.ToString() }) -join "`n"
Test-Assert ($outputTextH -match [regex]::Escape("[ABORT] Ctrl+C detected")) "the abort message was printed via the normal raw Write-Host path"
Test-Assert ($script:cleanConsoleMessageCalls.Count -eq 0) "Write-CleanConsoleMessage was never called while the toggle is off"
Write-Host ""

# ==============================================================================
#  Scenario I: Clean Console Output ON - Test-AbortSignal routes its
#  message through Write-CleanConsoleMessage instead of raw Write-Host.
#  Confirms both that the stub WAS called with the right text/color, and
#  that the raw-Write-Host path produced NO console output at all for
#  this call (not just "also called the stub" alongside the old path).
# ==============================================================================
Write-Host "=== Scenario I: Clean Console Output on - Test-AbortSignal routes through CCR ===" -ForegroundColor Cyan
Reset-HarnessScenarioState
$script:CleanConsoleOutputEnabled = $true
[ConsoleCtrl]::AbortRequested = $true
[ConsoleCtrl]::IsCloseEvent   = $true
$outputI = & { Test-AbortSignal } 6>&1
# 6>&1 merges the Information stream into Success output, but Test-AbortSignal
# also legitimately returns $true on Success - that boolean rides along in
# $outputI too and must not be mistaken for a raw Write-Host call. Filter to
# actual InformationRecord objects (real Write-Host output) only.
$rawHostRecordsI = @($outputI | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
Test-Assert ($rawHostRecordsI.Count -eq 0) "no raw Write-Host output was produced - Test-AbortSignal did not fall through to the old path"
Test-Assert ($script:cleanConsoleMessageCalls.Count -eq 1) ("Write-CleanConsoleMessage was called exactly once (got " + $script:cleanConsoleMessageCalls.Count + ")")
Test-Assert ($script:cleanConsoleMessageCalls[0].Text -like "*Window close detected*") "the correct (window-close) message text was passed through"
Test-Assert ($script:cleanConsoleMessageCalls[0].Color -eq "Yellow") "the message was passed through with -Color Yellow, matching the original Write-Host -ForegroundColor"
Write-Host ""

# ==============================================================================
#  Scenario J: Clean Console Output ON - Invoke-GracefulDrain's own two
#  messages (the initial wait message, and the force-stop message once
#  stragglers get force-stopped) also route through Write-CleanConsoleMessage.
# ==============================================================================
Write-Host "=== Scenario J: Clean Console Output on - Invoke-GracefulDrain messages route through CCR ===" -ForegroundColor Cyan
Reset-HarnessScenarioState
$script:CleanConsoleOutputEnabled = $true

$fakeJ = New-FakeHandles -DelaysMs @(30000)   # will never finish before the 1s timeout
$outputJ = & { Invoke-GracefulDrain -Handles $fakeJ.Handles -TimeoutSeconds 1 } 6>&1
$fakeJ.Pool.Close(); $fakeJ.Pool.Dispose()

# Same 6>&1-merges-the-return-value caveat as Scenario I - Invoke-GracefulDrain
# legitimately returns a @{ForceStoppedCount=...} hashtable, which is not a
# raw Write-Host call. Filter to real InformationRecord objects only.
$rawHostRecordsJ = @($outputJ | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
Test-Assert ($rawHostRecordsJ.Count -eq 0) "no raw Write-Host output was produced for either drain message"
Test-Assert ($script:cleanConsoleMessageCalls.Count -eq 2) ("both the wait message and the force-stop message went through Write-CleanConsoleMessage (got " + $script:cleanConsoleMessageCalls.Count + " call(s))")
Test-Assert ($script:cleanConsoleMessageCalls[0].Text -like "*Waiting for current jobs*") "the first call is the wait message"
Test-Assert ($script:cleanConsoleMessageCalls[1].Text -like "*Force-stopping 1 job(s)*") "the second call is the force-stop message, with the correct count"
Test-Assert ($script:cleanConsoleMessageCalls[1].Color -eq "Red") "the force-stop message keeps its Red color (matching the original Write-Host -ForegroundColor Red)"
Write-Host ""

# ==============================================================================
#  Scenario K: Complete-AbortDrain finalizes the CCR display (via
#  Complete-AllActiveSeriesProgress) when Clean Console Output is on AND
#  this is a window-close event - NOT for a plain Ctrl+C (2026-09-08 fix,
#  real bug, live-reported: finalizing every active series here for an
#  ordinary Ctrl+C meant the run's own NORMAL per-chapter completion call,
#  made moments later once the abort-drain's in-flight files finished,
#  found the series already resolved and threw "not an active series" -
#  a real FATAL ERROR ending an otherwise-successful run). Also does NOT
#  call it at all when the toggle is off, so a caller that never
#  dot-sourced CleanConsoleRendering.ps1 is never forced to have it loaded
#  just because Complete-AbortDrain ran.
# ==============================================================================
Write-Host "=== Scenario K: Complete-AbortDrain finalizes CCR display only for a window-close event, not a plain Ctrl+C ===" -ForegroundColor Cyan
Reset-HarnessScenarioState
$script:CleanConsoleOutputEnabled = $true
[ConsoleCtrl]::IsCloseEvent = $true
Complete-AbortDrain
Test-Assert ($script:completeAllActiveSeriesProgressCallCount -eq 1) "Complete-AllActiveSeriesProgress was called once for a window-close event with the toggle on"
Test-Assert ([ConsoleCtrl]::DrainComplete.IsSet) "DrainComplete is still signalled afterward"

Reset-HarnessScenarioState
$script:CleanConsoleOutputEnabled = $true
[ConsoleCtrl]::IsCloseEvent = $false
Complete-AbortDrain
Test-Assert ($script:completeAllActiveSeriesProgressCallCount -eq 0) "Complete-AllActiveSeriesProgress is NOT called for a plain Ctrl+C, even with the toggle on - the run's own later, normal completion call is what should resolve it"
Test-Assert ([ConsoleCtrl]::DrainComplete.IsSet) "DrainComplete is still signalled either way"

Reset-HarnessScenarioState
[ConsoleCtrl]::IsCloseEvent = $true
Complete-AbortDrain
Test-Assert ($script:completeAllActiveSeriesProgressCallCount -eq 0) "Complete-AllActiveSeriesProgress is NOT called when the toggle is off, even for a window-close event"
Test-Assert ([ConsoleCtrl]::DrainComplete.IsSet) "DrainComplete is still signalled either way"
[ConsoleCtrl]::IsCloseEvent = $false
Write-Host ""

# ==============================================================================
#  Scenario L: with $script:CleanConsoleOutputEnabled entirely UNDEFINED
#  (not just $false) - e.g. a caller that never dot-sourced Logging.ps1 at
#  all - Test-AbortSignal still falls through to the original raw
#  Write-Host path cleanly, matching the module header's claim that this
#  forward reference degrades gracefully rather than throwing.
# ==============================================================================
Write-Host "=== Scenario L: `$script:CleanConsoleOutputEnabled entirely undefined ===" -ForegroundColor Cyan
Reset-HarnessScenarioState
Remove-Variable -Name CleanConsoleOutputEnabled -Scope script -ErrorAction SilentlyContinue
[ConsoleCtrl]::AbortRequested = $true
[ConsoleCtrl]::IsCloseEvent   = $false
$undefinedThrew = $false
$outputL = $null
try { $outputL = & { Test-AbortSignal } 6>&1 } catch { $undefinedThrew = $true }
Test-Assert (-not $undefinedThrew) "Test-AbortSignal does not throw when `$script:CleanConsoleOutputEnabled was never defined at all"
$rawHostRecordsL = @($outputL | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
Test-Assert ($rawHostRecordsL.Count -gt 0) "it still falls through to the original raw Write-Host path in that case"
$script:CleanConsoleOutputEnabled = $false
Write-Host ""

# ==============================================================================
#  Scenario M: regression test for a real, pre-existing bug found while
#  writing Scenario J above (not introduced by the Clean Console Output
#  work - present since this module was first written, just never
#  covered by a test that checked the wait message's actual CONTENT
#  before now). An omitted -AbortWaitMessage binds to "" in PowerShell,
#  not $null - so the original "if ($null -eq $AbortWaitMessage)" default-
#  message check never fired for ANY caller, ever, and the default
#  "[ABORT] Waiting for current jobs..." message was silently never
#  printed. Fixed by checking $PSBoundParameters instead. This scenario
#  confirms both halves: the default message now genuinely appears when
#  -AbortWaitMessage is omitted, AND passing "" explicitly still
#  suppresses it (the one case that accidentally "worked" before, for
#  the wrong reason - now works for the right one).
# ==============================================================================
Write-Host "=== Scenario M: default -AbortWaitMessage regression (was silently never printed) ===" -ForegroundColor Cyan
Reset-HarnessScenarioState
$fakeM1 = New-FakeHandles -DelaysMs @(100)
$outputM1 = & { Invoke-GracefulDrain -Handles $fakeM1.Handles -TimeoutSeconds 10 } 6>&1
$fakeM1.Pool.Close(); $fakeM1.Pool.Dispose()
$outputTextM1 = ($outputM1 | ForEach-Object { $_.ToString() }) -join "`n"
Test-Assert ($outputTextM1 -match [regex]::Escape("[ABORT] Waiting for current jobs")) "omitting -AbortWaitMessage now prints the default wait message (previously never printed at all, for any caller)"

Reset-HarnessScenarioState
$fakeM2 = New-FakeHandles -DelaysMs @(100)
$outputM2 = & { Invoke-GracefulDrain -Handles $fakeM2.Handles -TimeoutSeconds 10 -AbortWaitMessage "" } 6>&1
$fakeM2.Pool.Close(); $fakeM2.Pool.Dispose()
# Same 6>&1-merges-the-return-value caveat as Scenario I/J - filter to real
# InformationRecord objects, not Invoke-GracefulDrain's own legitimate
# @{ForceStoppedCount=...} return value riding along in the same capture.
$rawHostRecordsM2 = @($outputM2 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
Test-Assert ($rawHostRecordsM2.Count -eq 0) "explicitly passing -AbortWaitMessage '' still suppresses it entirely, as documented"
Write-Host ""

# ==============================================================================
#  Scenario N: Test-OwnAbortException - both conditions required
#  (abortRequested AND a matching exception type), built 2026-08-28 from
#  a real extraction of the main script's own top-level catch block (see
#  Modules\_Reference\AbortPipeline.reference.ps1).
# ==============================================================================
Write-Host "=== Scenario N: Test-OwnAbortException ===" -ForegroundColor Cyan

function New-FakeErrorRecord {
    <#
    .SYNOPSIS
        Builds a real System.Management.Automation.ErrorRecord wrapping
        $Exception WITHOUT ever throwing it through PowerShell's own
        pipeline - constructing the ErrorRecord directly instead.
        Deliberate, not a shortcut: a real `throw` of a
        PipelineStoppedException specifically triggers PowerShell's own
        internal pipeline-stop machinery (that IS what the type is FOR),
        which killed this harness process outright the first time this
        scenario was written using try/throw/catch to build a "caught"
        exception the normal way - live-caught, not hypothetical.
    #>
    param([Parameter(Mandatory)][System.Exception]$Exception)
    return [System.Management.Automation.ErrorRecord]::new($Exception, "TestError", [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
}

Reset-HarnessScenarioState
$script:abortRequested = $true
$errPipelineStopped = New-FakeErrorRecord -Exception ([System.Management.Automation.PipelineStoppedException]::new())
Test-Assert ((Test-OwnAbortException -ErrorRecord $errPipelineStopped) -eq $true) "abortRequested + PipelineStoppedException -> true"

$errOperationCanceled = New-FakeErrorRecord -Exception ([System.OperationCanceledException]::new())
Test-Assert ((Test-OwnAbortException -ErrorRecord $errOperationCanceled) -eq $true) "abortRequested + OperationCanceledException -> true"

$script:abortRequested = $false
Test-Assert ((Test-OwnAbortException -ErrorRecord $errPipelineStopped) -eq $false) "the SAME exception type with abortRequested false -> false (a matching exception type alone isn't enough)"

$script:abortRequested = $true
$errUnrelated = New-FakeErrorRecord -Exception ([System.IO.IOException]::new("disk full"))
Test-Assert ((Test-OwnAbortException -ErrorRecord $errUnrelated) -eq $false) "abortRequested true but an UNRELATED exception type -> false (a real crash mid-abort is still a real crash)"
Reset-HarnessScenarioState
Write-Host ""

# ==============================================================================
#  Scenario N2 (2026-08-31 fix): Ctrl+C landing during a stretch where
#  nothing happens to be polling Test-AbortSignal (chapter discovery,
#  Compress-FolderToZip, Test-ZipArchive, summary writing) - the NATIVE
#  handler's own [ConsoleCtrl]::AbortRequested flag is set immediately and
#  independent of polling, but $script:abortRequested (only ever set BY a
#  Test-AbortSignal call) has not caught up yet. Before this fix,
#  Test-OwnAbortException read $script:abortRequested directly and missed
#  this - a genuine own-abort PipelineStoppedException looked like an
#  unrelated crash. Simulates that exact gap: set the native flag directly
#  (as [ConsoleCtrl]'s real P/Invoke callback would), leave
#  $script:abortRequested false (as if nothing had polled yet).
# ==============================================================================
Write-Host "=== Scenario N2: Ctrl+C detected via the native flag even if nothing polled first ===" -ForegroundColor Cyan
Reset-HarnessScenarioState
[ConsoleCtrl]::AbortRequested = $true
Test-Assert ($script:abortRequested -eq $false) "sanity check: script:abortRequested genuinely hasn't caught up yet"
$errUnpolled = New-FakeErrorRecord -Exception ([System.Management.Automation.PipelineStoppedException]::new())
Test-Assert ((Test-OwnAbortException -ErrorRecord $errUnpolled) -eq $true) "own-abort correctly recognized from the native flag alone, with nothing having polled Test-AbortSignal first"
Test-Assert ($script:abortRequested -eq $true) "Test-OwnAbortException brought script:abortRequested up to date as a side effect, so a later Complete-AbortDrain-based cleanup path still sees a consistent state"
Reset-HarnessScenarioState
Write-Host ""

# ==============================================================================
#  Scenario O: Invoke-AbortOrFatalHandler - the own-abort branch finalizes
#  the drain (Complete-AbortDrain) and does NOT invoke -LogHandler - this
#  is a graceful abort, not something to report as an error.
# ==============================================================================
Write-Host "=== Scenario O: Invoke-AbortOrFatalHandler - own-abort branch ===" -ForegroundColor Cyan
Reset-HarnessScenarioState
$script:abortRequested = $true
$script:CleanConsoleOutputEnabled = $true
# IsCloseEvent true here (2026-09-08 update, matching Complete-AbortDrain's
# own fix - see Scenario K) - this scenario is specifically proving
# Invoke-AbortOrFatalHandler really calls Complete-AbortDrain, not a
# reimplementation; Complete-AbortDrain itself only finalizes CCR for a
# close event, which Scenario K already covers on its own.
[ConsoleCtrl]::IsCloseEvent = $true
$logCallsO = [System.Collections.Generic.List[string]]::new()
$logHandlerO = { param($m) $logCallsO.Add($m) }.GetNewClosure()

$resultO = Invoke-AbortOrFatalHandler -ErrorRecord $errPipelineStopped -LogHandler $logHandlerO

Test-Assert ($resultO -eq $true) "returns `$true for our own abort"
Test-Assert ($logCallsO.Count -eq 0) "-LogHandler was never invoked - a graceful abort is not a logged error"
Test-Assert ([ConsoleCtrl]::DrainComplete.IsSet) "DrainComplete was signalled (via Complete-AbortDrain)"
Test-Assert ($script:completeAllActiveSeriesProgressCallCount -eq 1) "Complete-AbortDrain's own CCR finalization fired too (CleanConsoleOutputEnabled was on) - proves this really called Complete-AbortDrain, not a reimplementation"
Reset-HarnessScenarioState
Write-Host ""

# ==============================================================================
#  Scenario P: Invoke-AbortOrFatalHandler - a genuine crash builds a real
#  "FATAL ERROR" message (exception text + stack trace) and hands it to
#  -LogHandler; DrainComplete is untouched by this branch.
# ==============================================================================
Write-Host "=== Scenario P: Invoke-AbortOrFatalHandler - genuine crash branch ===" -ForegroundColor Cyan
Reset-HarnessScenarioState
$script:abortRequested = $true   # even mid-abort, an unrelated crash is still a crash
$logCallsP = [System.Collections.Generic.List[string]]::new()
$logHandlerP = { param($m) $logCallsP.Add($m) }.GetNewClosure()

$resultP = Invoke-AbortOrFatalHandler -ErrorRecord $errUnrelated -LogHandler $logHandlerP

Test-Assert ($resultP -eq $false) "returns `$false for a genuine crash"
Test-Assert ($logCallsP.Count -eq 1) "-LogHandler invoked exactly once"
Test-Assert ($logCallsP[0] -match [regex]::Escape("FATAL ERROR:") -and $logCallsP[0] -match [regex]::Escape("disk full")) "the message names it a fatal error and includes the real exception text"
Test-Assert ($logCallsP[0] -match [regex]::Escape("Stack Trace:")) "the message includes a stack trace section"
Test-Assert (-not [ConsoleCtrl]::DrainComplete.IsSet) "DrainComplete was NOT touched by the fatal-error branch - only the own-abort branch finalizes the drain"
Reset-HarnessScenarioState
Write-Host ""

# ==============================================================================
#  Scenario Q: Invoke-AbortOrFatalHandler - the default -LogHandler is a
#  raw Write-Host (no hard Write-Log dependency), matching
#  Invoke-GracefulDrain's own -ErrorHandler default convention.
# ==============================================================================
Write-Host "=== Scenario Q: default -LogHandler needs no Logging.ps1 dependency ===" -ForegroundColor Cyan
Reset-HarnessScenarioState
$threwQ = $false
try {
    $resultQ = Invoke-AbortOrFatalHandler -ErrorRecord $errUnrelated
} catch { $threwQ = $true }
Test-Assert (-not $threwQ) "no -LogHandler supplied, no Write-Log dot-sourced anywhere in this harness - does not throw"
Test-Assert ($resultQ -eq $false) "still correctly identified as a genuine crash"
Reset-HarnessScenarioState
Write-Host ""

# ==============================================================================
#  Scenario R: Reset-AbortState (2026-08-28, closes the "abort state never
#  reset" bug - Todo.md/CHANGELOG.md) - proves the REAL function itself,
#  not just this harness's own Reset-HarnessScenarioState wrapper around
#  it (that wrapper is exercised by every other scenario already; this one
#  is the only scenario that would catch a regression in the real
#  function's own body). Simulates the exact real-world sequence the bug
#  report described: one abort, then a second "run" in the same process
#  with no new Ctrl+C - without the fix, Test-AbortSignal's first poll of
#  that second run would already be $true.
# ==============================================================================
Write-Host "=== Scenario R: Reset-AbortState clears every piece of abort state ===" -ForegroundColor Cyan
Reset-HarnessScenarioState

$ctsR = [System.Threading.CancellationTokenSource]::new()
Register-AbortCancellationSource -Cts $ctsR
[ConsoleCtrl]::AbortRequested = $true
[ConsoleCtrl]::IsCloseEvent   = $true
$null = Test-AbortSignal
Complete-AbortDrain   # signals DrainComplete, same as a real caller's drain finishing

Test-Assert ($script:abortRequested -eq $true) "sanity check: abort is genuinely in progress before reset"
Test-Assert ($script:ctrlCloseAbort -eq $true) "sanity check: ctrlCloseAbort is set too"
Test-Assert ([ConsoleCtrl]::DrainComplete.IsSet -eq $true) "sanity check: DrainComplete is signalled before reset"

Reset-AbortState

Test-Assert ($script:abortRequested -eq $false) "Reset-AbortState clears `$script:abortRequested"
Test-Assert ($script:ctrlCloseAbort -eq $false) "Reset-AbortState clears `$script:ctrlCloseAbort"
Test-Assert ([ConsoleCtrl]::AbortRequested -eq $false) "Reset-AbortState clears [ConsoleCtrl]::AbortRequested"
Test-Assert ([ConsoleCtrl]::IsCloseEvent -eq $false) "Reset-AbortState clears [ConsoleCtrl]::IsCloseEvent"
Test-Assert ([ConsoleCtrl]::DrainComplete.IsSet -eq $false) "Reset-AbortState un-signals DrainComplete"

$pollAfterResetR = Test-AbortSignal
Test-Assert ($pollAfterResetR -eq $false) "the exact bug this closes: a second 'run' in the same process, no new Ctrl+C - Test-AbortSignal's first poll is now `$false, not stuck `$true"

# A genuinely NEW abort after the reset must still be detected correctly -
# proves the reset didn't leave anything in a state that breaks detection
# for whatever real run comes next.
[ConsoleCtrl]::AbortRequested = $true
$secondAbortR = Test-AbortSignal
Test-Assert ($secondAbortR -eq $true) "a real NEW abort after the reset is still detected correctly"
Test-Assert ($ctsR.IsCancellationRequested -eq $true) "and still cancels whatever's registered at the time"

$ctsR.Dispose()
Reset-HarnessScenarioState
Write-Host ""

# ==============================================================================
#  Scenario S (2026-08-31 fix, caught by a same-day /code-review
#  full-codebase pass): Invoke-GracefulDrain's docstring promises it
#  ALWAYS signals DrainComplete before returning - but nothing enforced
#  that until this fix wrapped the drain body in try/finally. A failing
#  job (EndInvoke throws) routes into -ErrorHandler; if -ErrorHandler
#  ITSELF throws (a broken caller-supplied handler), that propagates out
#  of Receive-CompletedHandles uncaught - DrainComplete must still get
#  signalled despite that, so the native Ctrl+C/window-close handler
#  doesn't park in DrainComplete.Wait(65000) for up to 65s.
# ==============================================================================
Write-Host "=== Scenario S: a throwing -ErrorHandler still signals DrainComplete before propagating ===" -ForegroundColor Cyan
Reset-HarnessScenarioState
$fakeS = New-FakeHandles -DelaysMs @(0) -Worker $fakeWorkerFail
$throwingErrorHandlerS = { param($msg) throw "simulated broken -ErrorHandler" }
$threwS = $false
try {
    $null = Invoke-GracefulDrain -Handles $fakeS.Handles -ErrorHandler $throwingErrorHandlerS -TimeoutSeconds 5
} catch {
    $threwS = $true
}
$fakeS.Pool.Close(); $fakeS.Pool.Dispose()

Test-Assert $threwS "the injected -ErrorHandler failure propagated out of Invoke-GracefulDrain, not silently swallowed"
Test-Assert ([ConsoleCtrl]::DrainComplete.IsSet) "DrainComplete was still signalled despite the throw - the native abort handler is not left parked"
Reset-HarnessScenarioState
Write-Host ""

# ==============================================================================
#  Scenario S2 (2026-09-03 fix, Todo.md finding): a bug in the CALLER's own
#  -ResultHandler (the worker itself SUCCEEDS here) must propagate as ITS
#  OWN real exception, not get caught by the same try/catch as a genuine
#  EndInvoke() failure and mislabeled as "Error collecting runspace result
#  during abort drain" - a caller-side ResultHandler bug and a real
#  runspace failure are different problems needing different messages.
# ==============================================================================
Write-Host "=== Scenario S2: a throwing -ResultHandler propagates as its own exception, not mislabeled ===" -ForegroundColor Cyan
Reset-HarnessScenarioState
$fakeS2 = New-FakeHandles -DelaysMs @(0) -Worker $fakeWorkerOk
$throwingResultHandlerS2 = { param($r) throw "simulated bug inside the caller's own ResultHandler" }
$s2ErrorHandlerCalls = [System.Collections.Generic.List[string]]::new()
$s2ErrorHandler = { param($msg) $s2ErrorHandlerCalls.Add($msg) }
$caughtS2 = $null
try {
    $null = Invoke-GracefulDrain -Handles $fakeS2.Handles -ResultHandler $throwingResultHandlerS2 -ErrorHandler $s2ErrorHandler -TimeoutSeconds 5
} catch {
    $caughtS2 = $_
}
$fakeS2.Pool.Close(); $fakeS2.Pool.Dispose()

Test-Assert ($null -ne $caughtS2) "the injected -ResultHandler failure propagated out of Invoke-GracefulDrain, not silently swallowed"
Test-Assert ($null -ne $caughtS2 -and $caughtS2.ToString() -like "*simulated bug inside the caller's own ResultHandler*") "the propagated exception is the CALLER's real message"
Test-Assert ($s2ErrorHandlerCalls.Count -eq 0) "-ErrorHandler was NOT invoked for this - the worker itself succeeded, only the caller's own ResultHandler is broken"
Test-Assert ([ConsoleCtrl]::DrainComplete.IsSet) "DrainComplete was still signalled despite the -ResultHandler throw - the native abort handler is not left parked"
Reset-HarnessScenarioState
Write-Host ""

# ==============================================================================
#  Scenario T (2026-08-31 addition, project owner's own explicit
#  decision): ANY ctrl event (Ctrl+C, Ctrl+Break, window-close, logoff,
#  shutdown) while [ConsoleCtrl]::RunActive is $false (idle at the menu)
#  must fall through to the OS's own default action (return $false, no
#  AbortRequested set, no blocking) instead of being caught - previously
#  the handler caught EVERY Ctrl+C unconditionally, which leaked into the
#  very next run dispatched in the same loop iteration and blocked the
#  handler thread on a drain that would never happen. Window-close/
#  logoff/shutdown were widened into this same !RunActive guard on
#  2026-09-15 (a real bug - they were previously always caught regardless
#  of RunActive, hanging ~5s waiting on a drain nothing would ever
#  complete when closing the window at the menu). Invokes the private
#  static Handler method directly via reflection - the real logic under
#  test, not a simulation of its output state (the pattern every other
#  scenario in this file uses, since Handler can't otherwise be called
#  from outside the type).
# ==============================================================================
Write-Host "=== Scenario T: Ctrl+C/Ctrl+Break at the menu (RunActive `$false) falls through to the OS default, not caught ===" -ForegroundColor Cyan
Reset-HarnessScenarioState
$handlerMethodT = [ConsoleCtrl].GetMethod("Handler", [System.Reflection.BindingFlags]"NonPublic,Static")

[ConsoleCtrl]::RunActive = $false
$resultCtrlCT = $handlerMethodT.Invoke($null, @([uint32]0))   # CTRL_C_EVENT
Test-Assert ($resultCtrlCT -eq $false) "Ctrl+C with no active run returns `$false (let the OS terminate the process), not `$true"
Test-Assert ([ConsoleCtrl]::AbortRequested -eq $false) "AbortRequested was NOT set by a menu-time Ctrl+C"

$resultCtrlBreakT = $handlerMethodT.Invoke($null, @([uint32]1))   # CTRL_BREAK_EVENT
Test-Assert ($resultCtrlBreakT -eq $false) "Ctrl+Break with no active run also returns `$false"
Test-Assert ([ConsoleCtrl]::AbortRequested -eq $false) "AbortRequested still NOT set after Ctrl+Break"

# Window-close/logoff/shutdown are now ALSO exempted by !RunActive
# (2026-09-15 fix, real bug) - closing the window at the menu, with
# nothing actually running, used to still set AbortRequested and park
# the handler thread in its own 65s Wait() for a drain that would never
# complete (nothing dispatched to complete it) - a ~5s hang before
# Windows force-killed the process anyway. Pre-signal DrainComplete
# defensively (so this test can't itself hang for 65s if the fix
# regresses), but the real assertion is that Wait() is never reached at
# all - the handler returns immediately.
[ConsoleCtrl]::DrainComplete.Set()
$resultCloseT = $handlerMethodT.Invoke($null, @([uint32]2))   # CTRL_CLOSE_EVENT
Test-Assert ($resultCloseT -eq $false) "window-close with no active run now ALSO falls through to the OS default (returns `$false), not caught - closing at the menu no longer hangs ~5s waiting on a drain nothing will ever complete"
Test-Assert ([ConsoleCtrl]::AbortRequested -eq $false -and [ConsoleCtrl]::IsCloseEvent -eq $false) "AbortRequested/IsCloseEvent were NOT set for a menu-time window-close"
Reset-HarnessScenarioState

# Now with a run genuinely active: Ctrl+C IS caught normally.
[ConsoleCtrl]::RunActive = $true
[ConsoleCtrl]::DrainComplete.Set()   # pre-signalled so Wait(65000) returns immediately
$resultActiveT = $handlerMethodT.Invoke($null, @([uint32]0))
Test-Assert ($resultActiveT -eq $true) "Ctrl+C WITH an active run is caught normally (returns `$true)"
Test-Assert ([ConsoleCtrl]::AbortRequested -eq $true -and [ConsoleCtrl]::IsCloseEvent -eq $false) "AbortRequested was set, IsCloseEvent correctly `$false for a real Ctrl+C"
Reset-HarnessScenarioState
Write-Host ""

# ==============================================================================
#  Scenario U: Reset-AbortState also resets [ConsoleCtrl]::RunActive to
#  $false (defensive belt-and-suspenders alongside
#  Set-AbortHandlerRunActive's own try/finally at its real call site) -
#  otherwise a caller that forgot its own try/finally would leave the
#  very next Ctrl+C at the menu wrongly caught.
# ==============================================================================
Write-Host "=== Scenario U: Reset-AbortState clears RunActive too ===" -ForegroundColor Cyan
[ConsoleCtrl]::RunActive = $true
Reset-AbortState
Test-Assert ([ConsoleCtrl]::RunActive -eq $false) "Reset-AbortState reset RunActive back to `$false"
Write-Host ""

# ==============================================================================
#  Scenario V: Set-AbortHandlerRunActive is a thin, direct wrapper around
#  [ConsoleCtrl]::RunActive.
# ==============================================================================
Write-Host "=== Scenario V: Set-AbortHandlerRunActive sets [ConsoleCtrl]::RunActive ===" -ForegroundColor Cyan
Set-AbortHandlerRunActive -Active $true
Test-Assert ([ConsoleCtrl]::RunActive -eq $true) "Set-AbortHandlerRunActive `$true set RunActive `$true"
Set-AbortHandlerRunActive -Active $false
Test-Assert ([ConsoleCtrl]::RunActive -eq $false) "Set-AbortHandlerRunActive `$false set RunActive `$false"
Reset-HarnessScenarioState
Write-Host ""

# ==============================================================================
#  Scenario V2 (2026-09-08 addition): Set-ConsoleQuickEditEnabled never
#  throws regardless of whether this process has a real interactive
#  console attached (a harness run typically doesn't - stdin is
#  redirected/piped), and Reset-AbortState re-enables QuickEdit as its own
#  defensive belt-and-suspenders reset, same as it already does for
#  RunActive.
# ==============================================================================
Write-Host "=== Scenario V2: Set-ConsoleQuickEditEnabled degrades gracefully with no real console attached ===" -ForegroundColor Cyan
$threwV2a = $false
$resultV2a = $null
try { $resultV2a = Set-ConsoleQuickEditEnabled -Enabled $false } catch { $threwV2a = $true }
Test-Assert (-not $threwV2a) "disabling QuickEdit does not throw even without a real console"
Test-Assert ($resultV2a -is [bool]) "returns a real boolean either way (`$true if it changed the mode, `$false if there was nothing to change)"

$threwV2b = $false
try { $null = Set-ConsoleQuickEditEnabled -Enabled $true } catch { $threwV2b = $true }
Test-Assert (-not $threwV2b) "re-enabling QuickEdit does not throw either"

$threwV2c = $false
try { Reset-AbortState } catch { $threwV2c = $true }
Test-Assert (-not $threwV2c) "Reset-AbortState's own defensive QuickEdit re-enable does not throw"
Reset-HarnessScenarioState
Write-Host ""

# ==============================================================================
#  Scenario W (2026-09-03 fix, real bug, live-reported and live-tested):
#  Invoke-GracefulDrain's own wait-for-natural-completion loop must be
#  skipped entirely when [ConsoleCtrl]::IsCloseEvent is true, going
#  straight to force-stopping every handle instead - Windows force-kills
#  the whole process ~5s after a close event regardless, so waiting out
#  any part of -TimeoutSeconds can never fit. Long delays (30s) with a
#  long -TimeoutSeconds (30s) that would normally still be waiting, timed
#  with a Stopwatch to prove the whole call returns almost immediately.
# ==============================================================================
Write-Host "=== Scenario W: IsCloseEvent skips Invoke-GracefulDrain's wait entirely, force-stops immediately ===" -ForegroundColor Cyan
Reset-HarnessScenarioState

$fakeW = New-FakeHandles -DelaysMs @(30000, 30000)
[ConsoleCtrl]::IsCloseEvent = $true
$swW = [System.Diagnostics.Stopwatch]::StartNew()
try {
    # try/finally around the call (2026-09-16 fix) - [ConsoleCtrl] is a
    # real, process-wide static type, and this harness runs every later
    # scenario in this same process. If Invoke-GracefulDrain ever threw
    # here, IsCloseEvent would have stayed $true for the rest of the run,
    # silently making every later drain in this file take the immediate-
    # force-stop fast path instead of its own real wait behavior.
    $outcomeW = Invoke-GracefulDrain -Handles $fakeW.Handles -TimeoutSeconds 30
} finally {
    [ConsoleCtrl]::IsCloseEvent = $false
}
$swW.Stop()
$fakeW.Pool.Close(); $fakeW.Pool.Dispose()

Test-Assert ($swW.Elapsed.TotalSeconds -lt 5) ("returned in under 5s despite a 30s -TimeoutSeconds and 30s-delayed jobs (took " + [math]::Round($swW.Elapsed.TotalSeconds, 2) + "s)")
Test-Assert ($outcomeW.ForceStoppedCount -eq 2) ("both still-running jobs were force-stopped immediately, not waited for (got ForceStoppedCount=" + $outcomeW.ForceStoppedCount + ")")
Test-Assert ([ConsoleCtrl]::DrainComplete.IsSet) "DrainComplete was still signalled after the fast-path force-stop"
Write-Host ""

# ==============================================================================
#  Summary
# ==============================================================================
Write-Host "==============================================="
if ($script:failCount -eq 0) {
    Write-Host ("ALL PASSED  (" + $script:passCount + " assertions)") -ForegroundColor Green
} else {
    Write-Host ($script:failCount.ToString() + " FAILED, " + $script:passCount + " passed") -ForegroundColor Red
}
Write-Host "==============================================="

if ($script:failCount -gt 0) { exit 1 } else { exit 0 }
