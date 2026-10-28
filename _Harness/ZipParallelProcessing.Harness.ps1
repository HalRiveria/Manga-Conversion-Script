<#
.SYNOPSIS
    Standalone test harness for Invoke-ZipParallelProcessing
    (Modules\ZipParallelProcessing.ps1).

.DESCRIPTION
    Dot-sources the REAL dependency modules - AbortPipeline.ps1 and
    Logging.ps1 - rather than hand-rolling stand-ins for
    ConsoleCtrl/Write-Log/Flush-ConsoleQueue/Test-AbortSignal. The module
    forward-references the real ones, so testing against stand-ins would
    not prove anything real; this is the same real-dependency
    pattern ZipPipeline.Harness.ps1 uses.

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
    .\_Harness\ZipParallelProcessing.Harness.ps1
    .\_Harness\ZipParallelProcessing.Harness.ps1 -RunSlowTest
#>

param(
    [switch]$RunSlowTest
)

$ErrorActionPreference = "Stop"

$modulesDir = Join-Path $PSScriptRoot "..\Modules"
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
#  Mirrors how the zip-only pipeline (mode 4) calls this.
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
#  Scenario A2: the caller's own $script:logMutex (e.g.
#  the bootstrap's, from Initialize-LogMutex) must be RESTORED after the
#  call, not left $null - Invoke-ZipParallelProcessing creates its own
#  fresh, LOCAL mutex object to seed the worker runspaces' initial state;
#  nulling out $script:logMutex afterward instead of putting the caller's
#  own reference back would silently unsynchronize every main-thread
#  Write-Log/Write-SummaryLog call for the rest of the run
#  (Invoke-MutexGuardedWrite no-ops the locking on a $null mutex rather
#  than erroring, so it would never be visibly broken).
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
#  Scenario A3: the mutex save/restore must hold even
#  when the call throws BEFORE the runspace pool is ever built - a bad
#  -SharedFunctionNames entry (not a real defined function) makes the
#  Get-Item ("Function:\" + $sharedFn) lookup throw. That line must sit
#  INSIDE the try/finally that restores $script:logMutex, or an
#  exception there would leave it pointed at this call's own local mutex
#  forever (a handle leak - still a valid reference to the same NAMED
#  mutex, so not a correctness break, but the invariant wouldn't hold).
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
# The raw Get-Item failure would otherwise propagate as a bare
# "cannot find path" error with no mention of -SharedFunctionNames, the
# offending name, or a dot-sourcing-order hint - so it is re-thrown with
# that context (messages should say what's wrong and what to do about it).
Test-Assert ($errMsgA3 -match "SharedFunctionNames" -and $errMsgA3 -match "This-Function-Does-Not-Exist") ("the error message names both -SharedFunctionNames and the offending function name, not a bare 'cannot find path' (got: " + $errMsgA3 + ")")
Write-Host ""

# ==============================================================================
#  Scenario B: -NextJobProvider, some items skipped inside the provider, no
#  abort. Mirrors a provider that peeks an
#  item, decide to skip or dispatch, loop internally past skips.
# ==============================================================================
Write-Host "=== Scenario B: -NextJobProvider, some skipped, no abort ===" -ForegroundColor Cyan

$script:cts = [System.Threading.CancellationTokenSource]::new()
$resultsB = [System.Collections.Generic.List[hashtable]]::new()
$bTotal = 10
# A hashtable, not three separate scalars: property mutation on a shared
# object reliably persists across separate & $providerB invocations, unlike
# a plain "$x++" scalar reassignment inside the closure (see the [ref]
# note in Invoke-ZipParallelProcessing for why).
$stateB = @{ Index = 0; SkippedCount = 0; DispatchedCount = 0 }
$providerB = {
    while ($stateB.Index -lt $bTotal) {
        $i = $stateB.Index
        $stateB.Index++
        if ($i % 3 -eq 0) {
            # Simulates a provider skipping an already-completed item"
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
#  Scenario B2: -PollCallback fires at least once per dispatch-loop pass, and at least
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
# -JobCrashedHandler is the only way a caller learns a
# worker's own runspace died mid-run at all (Controller.ps1's Full Pipeline
# treats one whole engine as a single long-lived "job" - losing it silently
# would mean chapters that engine hadn't reported yet got zipped and
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
#  Scenario D2: a bug in the CALLER's own
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
    # for the full 120s instead of draining/force-stopping at 60s.
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
    Test-Assert ([ConsoleCtrl]::DrainComplete.IsSet) "DrainComplete was signalled by Invoke-GracefulDrain"

    # Reset shared abort state so nothing leaks into a later run of this harness.
    Reset-HarnessAbortState

    Write-Host ""
} else {
    Write-Host "=== Scenario C skipped (pass -RunSlowTest to include it, ~65s) ===" -ForegroundColor DarkGray
    Write-Host ""
}

# ==============================================================================
#  Scenario E: -Cts/-WorkerScript/
#  -ResultHandler/-MaxParallel are all [Parameter(Mandatory)] -
#  a missing -Cts would otherwise fail SILENTLY (no error at all):
#  $Cts.Token.IsCancellationRequested on a $null $Cts just evaluates
#  falsy, so a run with no -Cts would be completely abort-deaf (no
#  cancellation ever noticed, DrainComplete never signalled). Every real
#  caller passes all four.
#
#  This scenario checks the parameter METADATA rather than calling the
#  function with one parameter omitted: a call only throws when
#  PowerShell's own missing-Mandatory-parameter prompt has nowhere to
#  read from (a fully non-interactive host, like Run-Harness.ps1's own
#  `powershell -NoProfile -File` invocation) - in a REAL interactive
#  console, PowerShell instead shows "Supply values for the following
#  parameters:" and blocks forever waiting for input that will never
#  come. Checking metadata is host-independent - it can never hang.
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
#  Scenario F: teardown does not wait for a worker stuck in a
#  blocking .NET call. A throwing -ResultHandler sends the call straight to
#  its finally while a second worker is still inside Thread.Sleep; a
#  blocking Stop()/Close()/Dispose() there would wait until that call returned. The
#  caller's token is cancelled too, so the abandoned worker can see it.
# ==============================================================================
Write-Host "=== Scenario F: teardown does not wait for a worker stuck in a .NET call ===" -ForegroundColor Cyan
Reset-HarnessAbortState
$ctsF = [System.Threading.CancellationTokenSource]::new()
$stuckWorkerF = {
    param([int]$JobId, [int]$DelayMs, $LogMutex, $ConsoleQueue, $CancelToken)
    [System.Threading.Thread]::Sleep($DelayMs)
    return @{ JobId = $JobId }
}
$jobParamsF = [System.Collections.Generic.List[hashtable]]::new()
$jobParamsF.Add(@{ JobId = 1; DelayMs = 0 })
$jobParamsF.Add(@{ JobId = 2; DelayMs = 8000 })
$caughtF = $null
$swF = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $null = Invoke-ZipParallelProcessing -WorkerScript $stuckWorkerF -JobParams $jobParamsF -SharedFunctionNames @() `
        -MaxParallel 2 -Cts $ctsF -ResultHandler { param($r) throw "simulated ResultHandler failure" }
} catch {
    $caughtF = $_
}
$swF.Stop()
Test-Assert ($null -ne $caughtF -and $caughtF.ToString() -like "*simulated ResultHandler failure*") "sanity check: the handler's exception propagated"
Test-Assert ($swF.Elapsed.TotalSeconds -lt 5) ("the call returned without waiting out the other worker's 8s blocking call (took " + [math]::Round($swF.Elapsed.TotalSeconds, 2) + "s)")
Test-Assert ($ctsF.Token.IsCancellationRequested) "the caller's token was cancelled so the abandoned worker can see it"
$ctsF.Dispose()
Reset-HarnessAbortState
Write-Host ""

# ==============================================================================
#  Scenario G: output emitted by -ResultHandler/-PollCallback
#  does not leak into Invoke-ZipParallelProcessing's own return value.
# ==============================================================================
Write-Host "=== Scenario G: chatty callbacks do not leak into the return value ===" -ForegroundColor Cyan
Reset-HarnessAbortState
$ctsG = [System.Threading.CancellationTokenSource]::new()
$jobParamsG = [System.Collections.Generic.List[hashtable]]::new()
$jobParamsG.Add(@{ JobId = 1; DelayMs = 0 })
$jobParamsG.Add(@{ JobId = 2; DelayMs = 0 })
$outcomeG = Invoke-ZipParallelProcessing -WorkerScript $stuckWorkerF -JobParams $jobParamsG -SharedFunctionNames @() `
    -MaxParallel 2 -Cts $ctsG -ResultHandler { param($r) "leaked from ResultHandler"; $true } -PollCallback { "leaked from PollCallback" }
$ctsG.Dispose()
Test-Assert ($outcomeG -is [hashtable]) ("the return is exactly one hashtable (got " + $(if ($null -eq $outcomeG) { "null" } else { $outcomeG.GetType().Name + " x" + @($outcomeG).Count }) + ")")
Test-Assert ($outcomeG -is [hashtable] -and $outcomeG.ForceStoppedCount -eq 0) "ForceStoppedCount is still readable on it"
Write-Host ""

# ==============================================================================
#  Scenario H: a scriptblock job value is refused before any worker runs.
#  A scriptblock belongs to the runspace that created it; run inside a worker
#  it can deadlock or crash the process.
# ==============================================================================
Write-Host "=== Scenario H: scriptblock job values are refused ===" -ForegroundColor Cyan
Reset-HarnessAbortState
$sharedH = @(Get-LoggingSharedFunctionNames)
function Invoke-ScenarioHJobs {
    param($Job, [switch]$UseProvider)
    $results = [System.Collections.Generic.List[hashtable]]::new()
    $cts = [System.Threading.CancellationTokenSource]::new()
    $err = $null
    try {
        if ($UseProvider) {
            $state = @{ Given = $false }
            $provider = { if ($state.Given) { return $null }; $state.Given = $true; return $Job }.GetNewClosure()
            $null = Invoke-ZipParallelProcessing -WorkerScript $fakeWorkerOk -NextJobProvider $provider -SharedFunctionNames $sharedH `
                -MaxParallel 1 -Cts $cts -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
        } else {
            $list = [System.Collections.Generic.List[hashtable]]::new()
            $list.Add($Job)
            $null = Invoke-ZipParallelProcessing -WorkerScript $fakeWorkerOk -JobParams $list -SharedFunctionNames $sharedH `
                -MaxParallel 1 -Cts $cts -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
        }
    } catch { $err = $_.ToString() }
    $cts.Dispose()
    return @{ Error = $err; Results = $results.Count }
}
$baseH = @{ JobId = 1; DelayMs = 0; DoFullLogging = $FullLogging; LogFile = $logFile; LogErrorFile = $logErrorFile; LogWarnFile = $logWarnFile }
function New-ScenarioHJob { param([hashtable]$Extra) $j = $baseH.Clone(); foreach ($k in $Extra.Keys) { $j[$k] = $Extra[$k] }; return $j }

$h1 = Invoke-ScenarioHJobs -Job (New-ScenarioHJob @{ Callback = { 1 } })
Test-Assert ($null -ne $h1.Error -and $h1.Error -match "'Callback'" -and $h1.Error -match '\[scriptblock\]::Create') ("a -JobParams scriptblock value throws, naming the key and the workaround (got: " + $h1.Error + ")")
Test-Assert ($h1.Results -eq 0) "no worker ran for the refused -JobParams list"
$h2 = Invoke-ScenarioHJobs -Job (New-ScenarioHJob @{ Steps = @('a', { 2 }) })
Test-Assert ($null -ne $h2.Error -and $h2.Error -match "'Steps'") "a scriptblock inside an array job value is refused"
$h3 = Invoke-ScenarioHJobs -Job (New-ScenarioHJob @{ Options = @{ OnDone = { 3 } } })
Test-Assert ($null -ne $h3.Error -and $h3.Error -match "'Options'") "a scriptblock inside a hashtable job value is refused"
$h4 = Invoke-ScenarioHJobs -Job (New-ScenarioHJob @{ Hook = { 4 } }) -UseProvider
Test-Assert ($null -ne $h4.Error -and $h4.Error -match "'Hook'" -and $h4.Results -eq 0) "a scriptblock in a -NextJobProvider job is refused before that job runs"
$h5 = Invoke-ScenarioHJobs -Job (New-ScenarioHJob @{ Code = '{ 5 }'; Names = @('x', 'y'); Map = @{ K = 'v' } })
Test-Assert ($null -eq $h5.Error -and $h5.Results -eq 1) ("plain data, including code passed as a string, still runs (error: " + $h5.Error + ", results: " + $h5.Results + ")")
$h6 = Invoke-ScenarioHJobs -Job (New-ScenarioHJob @{ Steps = @(@{ Run = { 6 } }) })
Test-Assert ($null -ne $h6.Error -and $h6.Error -match "'Steps'") "a scriptblock two levels down (an array of hashtables) is refused"
$h7 = Invoke-ScenarioHJobs -Job (New-ScenarioHJob @{ Config = [pscustomobject]@{ Name = 'x'; OnDone = { 7 } } })
Test-Assert ($null -ne $h7.Error -and $h7.Error -match "'Config'") "a scriptblock held in a [pscustomobject] property is refused"

# Test doubles as PowerShell classes (built in memory - no Add-Type compile).
class ZppCountingCollection : System.Collections.ICollection {
    [int]$Enumerations
    [int] get_Count() { return 2 }
    [bool] get_IsSynchronized() { return $false }
    [object] get_SyncRoot() { return $this }
    [void] CopyTo([System.Array]$array, [int]$index) { }
    [System.Collections.IEnumerator] GetEnumerator() { $this.Enumerations++; return @('a', 'b').GetEnumerator() }
}
class ZppThrowingCollection : System.Collections.ICollection {
    [bool]$AsModified
    ZppThrowingCollection([bool]$asModified) { $this.AsModified = $asModified }
    [int] get_Count() { return 1 }
    [bool] get_IsSynchronized() { return $false }
    [object] get_SyncRoot() { return $this }
    [void] CopyTo([System.Array]$array, [int]$index) { }
    [System.Collections.IEnumerator] GetEnumerator() {
        if ($this.AsModified) { throw [System.InvalidOperationException]::new('Collection was modified; enumeration operation may not execute.') }
        throw [System.UnauthorizedAccessException]::new('simulated read failure')
    }
}

# A collection shared by reference across jobs is read once per run, not
# once per job: later jobs may run while workers are writing to it.
$counterH = [ZppCountingCollection]::new()
$seenH = [System.Collections.Generic.HashSet[object]]::new()
$keysH = @(@(foreach ($i in 1..3) { Get-ZipJobScriptBlockKey -Job @{ JobId = $i; Shared = $counterH } -Seen $seenH }) | Where-Object { $null -ne $_ })
Test-Assert ($keysH.Count -eq 0 -and $counterH.Enumerations -eq 1) ("a collection shared by three jobs is enumerated once, not per job (enumerated " + $counterH.Enumerations + " times)")

# Same for a shared [pscustomobject]: its properties are read once.
$probeH = @{ Reads = 0 }
$sharedObjH = [pscustomobject]@{ Name = 'shared' }
$sharedObjH | Add-Member -MemberType ScriptProperty -Name Probe -Value { $probeH.Reads++; 'x' }.GetNewClosure()
$seenH2 = [System.Collections.Generic.HashSet[object]]::new()
foreach ($i in 1..3) { $null = Get-ZipJobScriptBlockKey -Job @{ JobId = $i; State = $sharedObjH } -Seen $seenH2 }
Test-Assert ($probeH.Reads -eq 1) ("a [pscustomobject] shared by three jobs is read once, not per job (read " + $probeH.Reads + " times)")

# A consuming enumerable is left alone - reading it would take the items
# the worker is meant to get.
$queueH = [System.Collections.Concurrent.BlockingCollection[object]]::new()
$queueH.Add('first'); $queueH.Add('second'); $queueH.CompleteAdding()
$null = Get-ZipJobScriptBlockKey -Job @{ JobId = 1; Work = $queueH.GetConsumingEnumerable() } -Seen ([System.Collections.Generic.HashSet[object]]::new())
Test-Assert ($queueH.Count -eq 2) ("checking a job doesn't consume a GetConsumingEnumerable() value (" + $queueH.Count + " of 2 items left)")

# Scriptblocks inside struct entries (KeyValuePair) are found.
$pairsH = [System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,object]]]::new()
$pairsH.Add([System.Collections.Generic.KeyValuePair[string,object]]::new('plain', 1))
$pairsH.Add([System.Collections.Generic.KeyValuePair[string,object]]::new('hook', { 10 }))
$kvpKeyH = Get-ZipJobScriptBlockKey -Job @{ JobId = 1; Pairs = $pairsH } -Seen ([System.Collections.Generic.HashSet[object]]::new())
Test-Assert ($kvpKeyH -eq 'Pairs') ("a scriptblock in a KeyValuePair's value is found (got: " + $kvpKeyH + ")")

# A collection being modified is let through; any other read failure is
# reported, naming the key, instead of silently passing.
$modifiedKeyH = Get-ZipJobScriptBlockKey -Job @{ JobId = 1; Busy = [ZppThrowingCollection]::new($true) } -Seen ([System.Collections.Generic.HashSet[object]]::new())
Test-Assert ($null -eq $modifiedKeyH) "a collection that's being modified (InvalidOperationException) is let through"
$readErrH = $null
try { $null = Get-ZipJobScriptBlockKey -Job @{ JobId = 1; Broken = [ZppThrowingCollection]::new($false) } -Seen ([System.Collections.Generic.HashSet[object]]::new()) } catch { $readErrH = $_.ToString() }
Test-Assert ($null -ne $readErrH -and $readErrH -match "'Broken'" -and $readErrH -match 'simulated read failure') ("any other read failure is reported with the key and the cause (got: " + $readErrH + ")")

# A provider job refused mid-run lets the jobs already running finish
# normally, then throws - it doesn't stop them or cancel the caller's token.
$resultsH9 = [System.Collections.Generic.List[hashtable]]::new()
$ctsH9 = [System.Threading.CancellationTokenSource]::new()
$stateH9 = @{ N = 0 }
$providerH9 = {
    $stateH9.N++
    if ($stateH9.N -eq 1) { return (New-ScenarioHJob @{ JobId = 1; DelayMs = 800 }) }
    if ($stateH9.N -eq 2) { return (New-ScenarioHJob @{ JobId = 2; Hook = { 9 } }) }
    return $null
}
$errH9 = $null
try {
    $null = Invoke-ZipParallelProcessing -WorkerScript $fakeWorkerOk -NextJobProvider $providerH9 -SharedFunctionNames $sharedH `
        -MaxParallel 2 -Cts $ctsH9 -ResultHandler { param($r) $resultsH9.Add($r) }
} catch { $errH9 = $_.ToString() }
Test-Assert ($null -ne $errH9 -and $errH9 -match "'Hook'") "a provider job refused mid-run still makes the call throw"
Test-Assert ($resultsH9.Count -eq 1 -and -not $ctsH9.Token.IsCancellationRequested) ("the job already running finished and reported, and the caller's token wasn't cancelled (results " + $resultsH9.Count + ", cancelled " + $ctsH9.Token.IsCancellationRequested + ")")
$ctsH9.Dispose()
Reset-HarnessAbortState
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
