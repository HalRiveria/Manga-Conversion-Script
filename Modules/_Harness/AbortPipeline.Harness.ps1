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

function Reset-AbortState {
    [ConsoleCtrl]::AbortRequested = $false
    [ConsoleCtrl]::IsCloseEvent   = $false
    [ConsoleCtrl]::DrainComplete.Reset()
    $script:abortRequested = $false
    $script:ctrlCloseAbort = $false
    $script:abortCancellationSources.Clear()
}

# ==============================================================================
#  Scenario A: Register/Unregister-AbortCancellationSource + Test-AbortSignal
#  cancels exactly the currently-registered set, exactly once.
# ==============================================================================
Write-Host "=== Scenario A: CTS registry + Test-AbortSignal ===" -ForegroundColor Cyan
Reset-AbortState

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
#  Scenario B: Get-AbortTriggerLabel reflects Ctrl+C vs window-close.
# ==============================================================================
Write-Host "=== Scenario B: Get-AbortTriggerLabel ===" -ForegroundColor Cyan
Reset-AbortState

[ConsoleCtrl]::AbortRequested = $true
[ConsoleCtrl]::IsCloseEvent   = $false
$null = Test-AbortSignal
Test-Assert ((Get-AbortTriggerLabel) -eq "Ctrl+C") "label is 'Ctrl+C' for a Ctrl+C abort"

Reset-AbortState
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
Reset-AbortState

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
Reset-AbortState

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
Reset-AbortState

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
Reset-AbortState

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
Reset-AbortState

$fake = New-FakeHandles -DelaysMs @(0) -Worker $fakeWorkerFail
$errorsG = [System.Collections.Generic.List[string]]::new()
$errHandlerG = { param($msg) $errorsG.Add($msg) }
$outcomeG = Invoke-GracefulDrain -Handles $fake.Handles -TimeoutSeconds 5 -ErrorHandler $errHandlerG
$fake.Pool.Close(); $fake.Pool.Dispose()

Test-Assert ($outcomeG.ForceStoppedCount -eq 0) "a thrown worker is not counted as force-stopped"
Test-Assert ($errorsG.Count -eq 1) ("the failure was reported via -ErrorHandler (got " + $errorsG.Count + " report(s))")
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
