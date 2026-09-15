<#
.SYNOPSIS
    Standalone test harness for Invoke-ZipParallelProcessing
    (Modules\ZipParallelProcessing.ps1).

.DESCRIPTION
    Dot-sources the REAL dependency modules now - AbortPipeline.ps1 and
    Logging.ps1 - instead of hand-rolling stand-ins for what used to be
    ZipParallelProcessing.ps1's own inline
    ConsoleCtrl/Write-Log/Flush-ConsoleQueue/Test-AbortSignal copies.
    Migrated 2026-08-27 along with the module itself (see
    ZipParallelProcessing.ps1's own header and CLAUDE.md "Known gaps") -
    this harness previously stubbed those pieces by hand precisely
    because the module defined its own; now that it forward-references
    the real ones, testing against stand-ins would no longer prove
    anything real, so this harness switched to the same real-dependency
    pattern ZipPipeline.Harness.ps1 already uses.

    Exercises the module with fake workers that do no real conversion or
    zipping - just simulated delay/failure/hang.

    Scenarios A, B, and D run in a few seconds. Scenario C (graceful-drain-
    then-force-stop after a real Ctrl+C-equivalent abort) takes about a
    minute by design, since it exercises the real 60-second timeout in
    Invoke-GracefulDrain (via Invoke-ZipParallelProcessing) - run it with
    -RunSlowTest.

    KNOWN GAP: this harness simulates abort by setting
    [ConsoleCtrl]::AbortRequested directly from a background runspace,
    which exercises everything from Test-AbortSignal onward (this is the
    part Invoke-ZipParallelProcessing actually depends on) but does NOT
    exercise the real SetConsoleCtrlHandler P/Invoke registration or the
    OS-blocking-handler dance around it. A real Ctrl+C press during a real
    run is the only thing that tests that part end-to-end.

.PARAMETER RunSlowTest
    Also run Scenario C (~65 seconds). Omit to run only the fast scenarios
    (A, B, D - a few seconds total).

.EXAMPLE
    .\Modules\_Harness\ZipParallelProcessing.Harness.ps1
    .\Modules\_Harness\ZipParallelProcessing.Harness.ps1 -RunSlowTest
#>

param(
    [switch]$RunSlowTest
)

$ErrorActionPreference = "Stop"

$modulesDir = Join-Path $PSScriptRoot ".."
. (Join-Path $modulesDir "AbortPipeline.ps1")
. (Join-Path $modulesDir "Logging.ps1")
. (Join-Path $modulesDir "ZipParallelProcessing.ps1")

# ==============================================================================
#  Real Initialize-LogPaths instead of hand-rolled $logFile/$pathHash stand-
#  ins - Logging.ps1's Write-Log and Invoke-ZipParallelProcessing's
#  Initialize-LogMutex both read $script:pathHash/$script:logFile/etc.
# ==============================================================================
$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("zpp-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Initialize-LogPaths -TargetPath $scratchDir -FullLogging $true -ScriptDir $scratchDir

$FullLogging  = $true
$logFile      = $script:logFile
$logErrorFile = $script:logErrorFile
$logWarnFile  = $script:logWarnFile

Write-Host ("Harness log file: " + $logFile) -ForegroundColor DarkGray
Write-Host ""

function Reset-HarnessAbortState {
    [ConsoleCtrl]::AbortRequested = $false
    [ConsoleCtrl]::IsCloseEvent   = $false
    [ConsoleCtrl]::DrainComplete.Reset()
    $script:abortRequested = $false
    $script:ctrlCloseAbort = $false
    $script:abortCancellationSources.Clear()
}
Reset-HarnessAbortState

# ==============================================================================
#  Fake workers - no real conversion/zipping, just simulated delay/failure.
#  Every worker used with Invoke-ZipParallelProcessing must declare CancelToken,
#  LogMutex, and ConsoleQueue - see the docstring on Invoke-ZipParallelProcessing.
#  These two ALSO declare DoFullLogging/LogFile/LogErrorFile/LogWarnFile and
#  bootstrap them into $script:*, matching the real $zipWorker/$zipOnlyWorker
#  pattern - not strictly required for what these fake workers log today
#  (Info-level only, which no-ops for file writes in split-log mode either
#  way), but faithful to the real pattern rather than accidentally-safe.
# ==============================================================================

# Succeeds after -DelayMs (use a large DelayMs, e.g. 120000, to simulate a
# hung job for the force-stop scenario - the SAME worker covers both the
# "fast, completes normally" and "slow, gets force-stopped" cases).
$fakeWorkerOk = {
    param(
        [int]$JobId,
        [int]$DelayMs,
        [bool]$DoFullLogging,
        [string]$LogFile,
        [string]$LogErrorFile,
        [string]$LogWarnFile,
        [System.Threading.Mutex]$LogMutex,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ConsoleQueue,
        [System.Threading.CancellationToken]$CancelToken
    )
    $script:logMutex           = $LogMutex
    $script:workerConsoleQueue = $ConsoleQueue
    $script:FullLogging        = $DoFullLogging
    $script:logFile            = $LogFile
    $script:logErrorFile       = $LogErrorFile
    $script:logWarnFile        = $LogWarnFile
    Write-Log ("Worker " + $JobId + " starting (delay " + $DelayMs + "ms)")
    Start-Sleep -Milliseconds $DelayMs
    Write-Log ("Worker " + $JobId + " done")
    return @{ JobId = $JobId; Ok = $true }
}

# Always throws immediately - for testing that a worker exception is caught,
# logged, and does not crash the whole batch.
$fakeWorkerFail = {
    param(
        [int]$JobId,
        [bool]$DoFullLogging,
        [string]$LogFile,
        [string]$LogErrorFile,
        [string]$LogWarnFile,
        [System.Threading.Mutex]$LogMutex,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ConsoleQueue,
        [System.Threading.CancellationToken]$CancelToken
    )
    $script:logMutex           = $LogMutex
    $script:workerConsoleQueue = $ConsoleQueue
    $script:FullLogging        = $DoFullLogging
    $script:logFile            = $LogFile
    $script:logErrorFile       = $LogErrorFile
    $script:logWarnFile        = $LogWarnFile
    throw ("Simulated failure in worker " + $JobId)
}

# ==============================================================================
#  Minimal assert helper
# ==============================================================================
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

# ==============================================================================
#  Scenario A: -JobParams (fixed up-front list), all succeed, no abort.
#  Mirrors how the zip-only pipeline (mode 3) calls this today.
# ==============================================================================
Write-Host "=== Scenario A: -JobParams, all succeed, no abort ===" -ForegroundColor Cyan

$script:cts = [System.Threading.CancellationTokenSource]::new()
$resultsA = [System.Collections.Generic.List[hashtable]]::new()
$jobParamsA = [System.Collections.Generic.List[hashtable]]::new()
for ($i = 1; $i -le 6; $i++) {
    $jobParamsA.Add(@{ JobId = $i; DelayMs = (Get-Random -Minimum 100 -Maximum 400); DoFullLogging = $FullLogging; LogFile = $logFile; LogErrorFile = $logErrorFile; LogWarnFile = $logWarnFile })
}
$handlerA = { param($r) $resultsA.Add($r) }

$outcomeA = Invoke-ZipParallelProcessing -WorkerScript $fakeWorkerOk -JobParams $jobParamsA `
    -SharedFunctionNames @('Write-Log', 'Invoke-MutexGuardedWrite', 'Format-LogLine', 'Write-LogLineToHost', 'Write-LogLineToFile') -MaxParallel 3 -Cts $script:cts -ResultHandler $handlerA
$script:cts.Dispose()

Test-Assert ($resultsA.Count -eq 6) ("all 6 jobs returned a result (got " + $resultsA.Count + ")")
Test-Assert ($outcomeA.ForceStoppedCount -eq 0) "ForceStoppedCount is 0 on a clean run"
Test-Assert ((@($resultsA | Where-Object { $_.Ok })).Count -eq 6) "all 6 results report Ok"
# Sort-Object -Unique on Hashtable objects compares the objects themselves,
# not the JobId property, and collapses to a single element regardless of
# distinct values - extract the property first so uniqueness is checked on
# plain ints.
Test-Assert ((@($resultsA | ForEach-Object { $_.JobId } | Sort-Object -Unique)).Count -eq 6) "all 6 JobIds are distinct (no duplicate/dropped dispatch)"
Write-Host ""

# ==============================================================================
#  Scenario A2 (2026-08-31 fix): the caller's own $script:logMutex (e.g.
#  the bootstrap's, from Initialize-LogMutex) must be RESTORED after the
#  call, not left $null - Invoke-ZipParallelProcessing creates its own
#  fresh, LOCAL mutex object to seed the worker runspaces' initial state,
#  which used to unconditionally null out $script:logMutex afterward
#  instead of putting the caller's own reference back, silently
#  unsynchronizing every main-thread Write-Log/Write-SummaryLog call for
#  the rest of the run (Invoke-MutexGuardedWrite no-ops the locking on a
#  $null mutex rather than erroring, so this was never visibly broken).
# ==============================================================================
Write-Host "=== Scenario A2: the caller's own log mutex is restored after the call, not left null ===" -ForegroundColor Cyan
Initialize-LogMutex
$callerMutexA2 = $script:logMutex
Test-Assert ($null -ne $callerMutexA2) "sanity check: the caller (simulating bootstrap) genuinely has a mutex before the call"

$script:cts2 = [System.Threading.CancellationTokenSource]::new()
$resultsA2 = [System.Collections.Generic.List[hashtable]]::new()
$jobParamsA2 = [System.Collections.Generic.List[hashtable]]::new()
$jobParamsA2.Add(@{ JobId = 1; DelayMs = 50; DoFullLogging = $FullLogging; LogFile = $logFile; LogErrorFile = $logErrorFile; LogWarnFile = $logWarnFile })
$handlerA2 = { param($r) $resultsA2.Add($r) }
$null = Invoke-ZipParallelProcessing -WorkerScript $fakeWorkerOk -JobParams $jobParamsA2 `
    -SharedFunctionNames @('Write-Log', 'Invoke-MutexGuardedWrite', 'Format-LogLine', 'Write-LogLineToHost', 'Write-LogLineToFile') -MaxParallel 3 -Cts $script:cts2 -ResultHandler $handlerA2
$script:cts2.Dispose()

Test-Assert ($null -ne $script:logMutex) "the caller's log mutex is not left `$null after the call"
Test-Assert ([object]::ReferenceEquals($script:logMutex, $callerMutexA2)) "the EXACT SAME mutex object the caller had before the call is restored, not a different/stale one"
$stillUsableA2 = $false
try { $null = $script:logMutex.WaitOne(0); $script:logMutex.ReleaseMutex(); $stillUsableA2 = $true } catch { }
Test-Assert $stillUsableA2 "the restored mutex is still genuinely usable (not disposed) - a later main-thread Write-Log call would succeed, not throw ObjectDisposedException"
Write-Host ""

# ==============================================================================
#  Scenario A3 (2026-08-31 fix): the mutex save/restore must hold even
#  when the call throws BEFORE the runspace pool is ever built - a bad
#  -SharedFunctionNames entry (not a real defined function) makes the
#  Get-Item ("Function:\" + $sharedFn) lookup throw. Before the fix, that
#  line sat OUTSIDE the try/finally that restores $script:logMutex, so an
#  exception there left it pointed at this call's own local mutex forever
#  (a handle leak - still a valid reference to the same NAMED mutex, so
#  not a correctness break, but the fix's own invariant didn't hold here).
# ==============================================================================
Write-Host "=== Scenario A3: the mutex is still restored even when the call throws before the runspace pool is built ===" -ForegroundColor Cyan
$callerMutexA3 = $script:logMutex
Test-Assert ($null -ne $callerMutexA3) "sanity check: the caller still has a mutex before this call (same one Scenario A2 restored)"

$script:cts3 = [System.Threading.CancellationTokenSource]::new()
$jobParamsA3 = [System.Collections.Generic.List[hashtable]]::new()
$jobParamsA3.Add(@{ JobId = 1; DelayMs = 10; DoFullLogging = $FullLogging; LogFile = $logFile; LogErrorFile = $logErrorFile; LogWarnFile = $logWarnFile })
$threwA3 = $false
$errMsgA3 = $null
try {
    $null = Invoke-ZipParallelProcessing -WorkerScript $fakeWorkerOk -JobParams $jobParamsA3 `
        -SharedFunctionNames @('This-Function-Does-Not-Exist') -MaxParallel 3 -Cts $script:cts3 -ResultHandler { param($r) }
} catch {
    $threwA3 = $true
    $errMsgA3 = $_.Exception.Message
}
$script:cts3.Dispose()

Test-Assert $threwA3 "sanity check: the bad -SharedFunctionNames entry genuinely made the call throw"
Test-Assert ([object]::ReferenceEquals($script:logMutex, $callerMutexA3)) "the caller's mutex is still restored even though the call threw before the runspace pool was ever built"
# 2026-08-31 fix: the raw Get-Item failure used to propagate as a bare
# "cannot find path" error with no mention of -SharedFunctionNames, the
# offending name, or a dot-sourcing-order hint - now re-thrown with that
# context (CLAUDE.md: "messages say what's wrong and what to do about it").
Test-Assert ($errMsgA3 -match "SharedFunctionNames" -and $errMsgA3 -match "This-Function-Does-Not-Exist") ("the error message names both -SharedFunctionNames and the offending function name, not a bare 'cannot find path' (got: " + $errMsgA3 + ")")
Write-Host ""

# ==============================================================================
#  Scenario B: -NextJobProvider, some items skipped inside the provider, no
#  abort. Mirrors the pattern mode 4 (ZIP-extraction) would use: peek an
#  item, decide to skip or dispatch, loop internally past skips.
# ==============================================================================
Write-Host "=== Scenario B: -NextJobProvider, some skipped, no abort ===" -ForegroundColor Cyan

$script:cts = [System.Threading.CancellationTokenSource]::new()
$resultsB = [System.Collections.Generic.List[hashtable]]::new()
$bTotal = 10
# A hashtable, not three separate scalars: property mutation on a shared
# object reliably persists across separate & $providerB invocations, unlike
# a plain "$x++" scalar reassignment inside the closure (see the [ref] fix
# and its docstring note in Invoke-ZipParallelProcessing for why - this harness
# hit the exact same bug in its own Scenario B provider before this fix).
$stateB = @{ Index = 0; SkippedCount = 0; DispatchedCount = 0 }
$providerB = {
    while ($stateB.Index -lt $bTotal) {
        $i = $stateB.Index
        $stateB.Index++
        if ($i % 3 -eq 0) {
            # Simulates mode 4's "already completed per resume-state, skip it"
            $stateB.SkippedCount++
            continue
        }
        $stateB.DispatchedCount++
        return @{ JobId = $i; DelayMs = (Get-Random -Minimum 50 -Maximum 250); DoFullLogging = $FullLogging; LogFile = $logFile; LogErrorFile = $logErrorFile; LogWarnFile = $logWarnFile }
    }
    return $null
}
$handlerB = { param($r) $resultsB.Add($r) }

$outcomeB = Invoke-ZipParallelProcessing -WorkerScript $fakeWorkerOk -NextJobProvider $providerB `
    -SharedFunctionNames @('Write-Log', 'Invoke-MutexGuardedWrite', 'Format-LogLine', 'Write-LogLineToHost', 'Write-LogLineToFile') -MaxParallel 4 -Cts $script:cts -ResultHandler $handlerB
$script:cts.Dispose()

Test-Assert ($stateB.Index -eq $bTotal) "provider was called through to full exhaustion"
Test-Assert ($stateB.SkippedCount -eq 4) ("expected 4 skips (indices 0,3,6,9), got " + $stateB.SkippedCount)
Test-Assert ($resultsB.Count -eq $stateB.DispatchedCount) ("dispatched count (" + $stateB.DispatchedCount + ") matches results collected (" + $resultsB.Count + ")")
Test-Assert ($outcomeB.ForceStoppedCount -eq 0) "ForceStoppedCount is 0 on a clean run"
Write-Host ""

# ==============================================================================
#  Scenario B2 (2026-09-09, Full Pipeline dispatch-redesign step 4):
#  -PollCallback fires at least once per dispatch-loop pass, and at least
#  once more after the final drain - proves a caller can rely on it to
#  drain a cross-worker event queue on a real cadence, not just once at
#  the very end.
# ==============================================================================
Write-Host "=== Scenario B2: -PollCallback fires per pass and after the final drain ===" -ForegroundColor Cyan

$script:cts = [System.Threading.CancellationTokenSource]::new()
$resultsB2 = [System.Collections.Generic.List[hashtable]]::new()
$jobParamsB2 = [System.Collections.Generic.List[hashtable]]::new()
for ($i = 1; $i -le 6; $i++) {
    $jobParamsB2.Add(@{ JobId = $i; DelayMs = (Get-Random -Minimum 100 -Maximum 400); DoFullLogging = $FullLogging; LogFile = $logFile; LogErrorFile = $logErrorFile; LogWarnFile = $logWarnFile })
}
$handlerB2 = { param($r) $resultsB2.Add($r) }
$pollCountB2 = @{ N = 0 }
$pollCallbackB2 = { $pollCountB2.N++ }

$outcomeB2 = Invoke-ZipParallelProcessing -WorkerScript $fakeWorkerOk -JobParams $jobParamsB2 `
    -SharedFunctionNames @('Write-Log', 'Invoke-MutexGuardedWrite', 'Format-LogLine', 'Write-LogLineToHost', 'Write-LogLineToFile') `
    -MaxParallel 2 -Cts $script:cts -ResultHandler $handlerB2 -PollCallback $pollCallbackB2
$script:cts.Dispose()

Test-Assert ($resultsB2.Count -eq 6) ("all 6 jobs still returned a result with -PollCallback supplied (got " + $resultsB2.Count + ")")
# -MaxParallel 2 against 6 jobs forces at least 3 dispatch waves, each
# needing at least one poll pass to notice a slot freed up - a bare
# "greater than 0" assertion wouldn't distinguish "fires every pass" from
# "fires exactly once regardless", the actual behavior this scenario exists
# to prove.
Test-Assert ($pollCountB2.N -ge 3) ("-PollCallback fired at least 3 times across multiple dispatch-loop passes (got " + $pollCountB2.N + ")")
Write-Host ""

# ==============================================================================
#  Scenario D: a worker throws immediately - Invoke-ZipParallelProcessing must
#  catch it, log it, and return normally rather than crashing the batch.
# ==============================================================================
Write-Host "=== Scenario D: a worker throws - should be caught, not crash the batch ===" -ForegroundColor Cyan

$script:cts = [System.Threading.CancellationTokenSource]::new()
$resultsD = [System.Collections.Generic.List[hashtable]]::new()
$jobParamsD = [System.Collections.Generic.List[hashtable]]::new()
$jobParamsD.Add(@{ JobId = 1; DoFullLogging = $FullLogging; LogFile = $logFile; LogErrorFile = $logErrorFile; LogWarnFile = $logWarnFile })
$handlerD = { param($r) $resultsD.Add($r) }
# 2026-09-15 fix: -JobCrashedHandler is the only way a caller learns a
# worker's own runspace died mid-run at all (Controller.ps1's Full Pipeline
# treats one whole engine as a single long-lived "job" - losing it silently
# previously meant chapters that engine hadn't reported yet got zipped and
# deleted anyway by the leftover-merge pass, see Controller.Harness.ps1).
$crashedCountD = 0
$crashedHandlerD = { param($errorRecord) $script:crashedCountD++ }

$threwD = $false
try {
    $outcomeD = Invoke-ZipParallelProcessing -WorkerScript $fakeWorkerFail -JobParams $jobParamsD `
        -SharedFunctionNames @('Write-Log', 'Invoke-MutexGuardedWrite', 'Format-LogLine', 'Write-LogLineToHost', 'Write-LogLineToFile') -MaxParallel 2 -Cts $script:cts -ResultHandler $handlerD `
        -JobCrashedHandler $crashedHandlerD
} catch {
    $threwD = $true
}
$script:cts.Dispose()

Test-Assert (-not $threwD) "Invoke-ZipParallelProcessing itself did not throw when a worker threw"
Test-Assert ($resultsD.Count -eq 0) "no result was recorded for the failed worker (ResultHandler never invoked for it)"
Test-Assert ($script:crashedCountD -eq 1) ("-JobCrashedHandler fired exactly once for the worker that threw (got " + $script:crashedCountD + ")")
Write-Host ""

# ==============================================================================
#  Scenario D2 (2026-09-03 fix, Todo.md finding): a bug in the CALLER's own
#  -ResultHandler (not the runspace/worker) must propagate as ITS OWN real
#  exception, not get caught and mislabeled as "Error collecting runspace
#  result" - a genuine runspace failure and a caller-side ResultHandler bug
#  are different problems and need different messages to actually debug.
#  The worker itself succeeds normally here; only the handler is broken.
# ==============================================================================
Write-Host "=== Scenario D2: a throwing -ResultHandler propagates as its own exception, not mislabeled ===" -ForegroundColor Cyan

Initialize-LogMutex
$callerMutexD2 = $script:logMutex
$script:cts = [System.Threading.CancellationTokenSource]::new()
$jobParamsD2 = [System.Collections.Generic.List[hashtable]]::new()
$jobParamsD2.Add(@{ JobId = 1; DelayMs = 50; DoFullLogging = $FullLogging; LogFile = $logFile; LogErrorFile = $logErrorFile; LogWarnFile = $logWarnFile })
$handlerD2 = { param($r) throw "simulated bug inside the caller's own ResultHandler" }

$caughtD2 = $null
try {
    $null = Invoke-ZipParallelProcessing -WorkerScript $fakeWorkerOk -JobParams $jobParamsD2 `
        -SharedFunctionNames @('Write-Log', 'Invoke-MutexGuardedWrite', 'Format-LogLine', 'Write-LogLineToHost', 'Write-LogLineToFile') -MaxParallel 2 -Cts $script:cts -ResultHandler $handlerD2
} catch {
    $caughtD2 = $_
}
$script:cts.Dispose()

Test-Assert ($null -ne $caughtD2) "Invoke-ZipParallelProcessing DOES propagate a -ResultHandler's own exception, rather than swallowing it"
Test-Assert ($null -ne $caughtD2 -and $caughtD2.ToString() -like "*simulated bug inside the caller's own ResultHandler*") "the propagated exception is the CALLER's real message, not a generic 'Error collecting runspace result' one"
Test-Assert ([object]::ReferenceEquals($script:logMutex, $callerMutexD2)) "the caller's log mutex is still restored via the outer finally even when -ResultHandler throws"
Write-Host ""

# ==============================================================================
#  Scenario C (slow, ~65s): abort mid-run should gracefully drain fast jobs,
#  then force-stop anything still running after the 60s timeout.
#  Only runs with -RunSlowTest.
# ==============================================================================
if ($RunSlowTest) {
    Write-Host "=== Scenario C (slow, ~65s): abort mid-run forces stragglers after 60s ===" -ForegroundColor Cyan
    Write-Host "  (2 fast jobs should complete; 2 slow jobs should get force-stopped)" -ForegroundColor DarkGray

    Reset-HarnessAbortState
    $script:cts = [System.Threading.CancellationTokenSource]::new()
    # Test-AbortSignal (now AbortPipeline.ps1's real one) cancels every CTS
    # in its registry, not a hardcoded variable name - without this
    # registration, [ConsoleCtrl]::AbortRequested being set below would
    # never actually cancel $script:cts, and this scenario would just hang
    # for the full 120s instead of draining/force-stopping at 60s (the
    # exact bug class ImageConversionPipeline.ps1's own rework hit and
    # fixed this same session - see CHANGELOG.md).
    Register-AbortCancellationSource -Cts $script:cts

    $resultsC = [System.Collections.Generic.List[hashtable]]::new()
    $jobParamsC = [System.Collections.Generic.List[hashtable]]::new()
    $commonLogParams = @{ DoFullLogging = $FullLogging; LogFile = $logFile; LogErrorFile = $logErrorFile; LogWarnFile = $logWarnFile }
    $jobParamsC.Add((@{ JobId = 1; DelayMs = 1000   } + $commonLogParams))   # fast - should complete before/shortly after abort fires
    $jobParamsC.Add((@{ JobId = 2; DelayMs = 1500   } + $commonLogParams))   # fast - should complete
    $jobParamsC.Add((@{ JobId = 3; DelayMs = 120000 } + $commonLogParams))   # hangs well past the 60s drain timeout
    $jobParamsC.Add((@{ JobId = 4; DelayMs = 120000 } + $commonLogParams))   # hangs well past the 60s drain timeout
    $handlerC = { param($r) $resultsC.Add($r) }

    # Trigger abort ~2s in, from a separate in-process runspace (NOT our pool -
    # a real Ctrl+C would set this same static field via the P/Invoke handler;
    # this is the harness's stand-in for that, see the "KNOWN GAP" note above).
    $triggerPs = [PowerShell]::Create()
    $null = $triggerPs.AddScript({
        param($DelaySeconds)
        Start-Sleep -Seconds $DelaySeconds
        [ConsoleCtrl]::AbortRequested = $true
        [ConsoleCtrl]::IsCloseEvent   = $false
    })
    $null = $triggerPs.AddArgument(2)
    $triggerHandle = $triggerPs.BeginInvoke()

    $swC = [System.Diagnostics.Stopwatch]::StartNew()
    $outcomeC = Invoke-ZipParallelProcessing -WorkerScript $fakeWorkerOk -JobParams $jobParamsC `
        -SharedFunctionNames @('Write-Log', 'Invoke-MutexGuardedWrite', 'Format-LogLine', 'Write-LogLineToHost', 'Write-LogLineToFile') -MaxParallel 4 -Cts $script:cts -ResultHandler $handlerC
    $swC.Stop()

    $triggerPs.EndInvoke($triggerHandle)
    $triggerPs.Dispose()
    Unregister-AbortCancellationSource -Cts $script:cts
    $script:cts.Dispose()

    Test-Assert ($outcomeC.ForceStoppedCount -eq 2) ("expected 2 force-stopped jobs (the two 120s hangs), got " + $outcomeC.ForceStoppedCount)
    Test-Assert ((@($resultsC | Where-Object { $_.JobId -in @(1,2) })).Count -eq 2) "both fast jobs (1,2) completed and reported a result despite the abort"
    Test-Assert ($swC.Elapsed.TotalSeconds -ge 60 -and $swC.Elapsed.TotalSeconds -lt 90) ("total run time (" + [math]::Round($swC.Elapsed.TotalSeconds,1) + "s) is in the expected ~60-70s window (2s to abort + up to 60s drain, not the full 120s hang)")
    Test-Assert ([ConsoleCtrl]::DrainComplete.IsSet) "DrainComplete was signalled by Invoke-GracefulDrain (a real fix this migration picked up - the old inline drain never signalled it at all)"

    # Reset shared abort state so nothing leaks into a later run of this harness.
    Reset-HarnessAbortState

    Write-Host ""
} else {
    Write-Host "=== Scenario C skipped (pass -RunSlowTest to include it, ~65s) ===" -ForegroundColor DarkGray
    Write-Host ""
}

# ==============================================================================
#  Scenario E (2026-08-31 addition, project owner approved as an easy
#  fix; corrected the same day after a verification pass found the
#  original version could HANG the whole suite): -Cts/-WorkerScript/
#  -ResultHandler/-MaxParallel are now all [Parameter(Mandatory)] -
#  omitting -Cts specifically used to fail SILENTLY (no error at all):
#  $Cts.Token.IsCancellationRequested on a $null $Cts just evaluates
#  falsy, so a run with no -Cts was completely abort-deaf (no
#  cancellation ever noticed, DrainComplete never signalled). Every real
#  caller already passes all four, so this closes a latent gap rather
#  than fixing something live.
#
#  ORIGINAL VERSION of this scenario actually CALLED the function with
#  one parameter omitted and asserted the call threw. That only throws
#  when PowerShell's own missing-Mandatory-parameter prompt has nowhere
#  to read from (a fully non-interactive host, like Run-Harness.ps1's
#  own `powershell -NoProfile -File` invocation) - in a REAL interactive
#  console (a plain manual test run, or one of a review agent's own ad-
#  hoc verification commands), PowerShell instead shows "Supply values
#  for the following parameters:" and blocks forever waiting for input
#  that will never come, verified live. Checking the parameter METADATA
#  instead of actually invoking the function is host-independent - it
#  can never hang, in any invocation context.
# ==============================================================================
Write-Host "=== Scenario E: -Cts/-WorkerScript/-ResultHandler/-MaxParallel are Mandatory ===" -ForegroundColor Cyan
$paramsE = (Get-Command Invoke-ZipParallelProcessing).Parameters
function Test-ParamIsMandatory {
    param([string]$Name)
    $attr = $paramsE[$Name].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | Select-Object -First 1
    return [bool]$attr.Mandatory
}
Test-Assert (Test-ParamIsMandatory 'Cts') "-Cts is Mandatory, instead of silently running abort-deaf when omitted"
Test-Assert (Test-ParamIsMandatory 'WorkerScript') "-WorkerScript is Mandatory"
Test-Assert (Test-ParamIsMandatory 'ResultHandler') "-ResultHandler is Mandatory"
Test-Assert (Test-ParamIsMandatory 'MaxParallel') "-MaxParallel is Mandatory"
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

try { Remove-Item -LiteralPath $scratchDir -Recurse -Force } catch { }

if ($script:failCount -gt 0) { exit 1 } else { exit 0 }
