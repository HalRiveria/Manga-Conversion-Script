<#
.SYNOPSIS
    Standalone test harness for Invoke-ZipParallelProcessing
    (Modules\ZipParallelProcessing.ps1).

.DESCRIPTION
    Dot-sources the real module (not a reimplementation) and exercises it
    with fake workers that do no real conversion or zipping - just
    simulated delay/failure/hang - so it can be validated before any
    pipeline is pointed at it for real.

    Scenarios A, B, and D run in a few seconds. Scenario C (graceful-drain-
    then-force-stop after a real Ctrl+C-equivalent abort) takes about a
    minute by design, since it exercises the real 60-second timeout in
    Invoke-ZipParallelProcessing - run it with -RunSlowTest.

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

. (Join-Path $PSScriptRoot "..\ZipParallelProcessing.ps1")

# ==============================================================================
#  Script-scope state Write-Log / Test-AbortSignal / Invoke-ZipParallelProcessing
#  expect to find - same variable names as the main script, minimal harness
#  stand-ins for the rest (no real -Path, no real log/state files).
# ==============================================================================
$script:logMutex           = $null
$script:workerConsoleQueue = $null
$script:abortRequested     = $false
$script:ctrlCloseAbort     = $false
$script:cts                = $null   # Invoke-ZipParallelProcessing assigns/uses this per-scenario

$FullLogging  = $true
$logFile      = Join-Path ([System.IO.Path]::GetTempPath()) ("pfj-harness-" + [guid]::NewGuid().ToString("N") + ".log")
$logErrorFile = $logFile
$logWarnFile  = $logFile
$pathHash     = "harness0001"   # stand-in for the real per-Path SHA256 hash; only used for a mutex name

Write-Host ("Harness log file: " + $logFile) -ForegroundColor DarkGray
Write-Host ""

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
    -SharedFunctionNames @('Write-Log') -MaxParallel 3 -Cts $script:cts -ResultHandler $handlerA
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
    -SharedFunctionNames @('Write-Log') -MaxParallel 4 -Cts $script:cts -ResultHandler $handlerB
$script:cts.Dispose()

Test-Assert ($stateB.Index -eq $bTotal) "provider was called through to full exhaustion"
Test-Assert ($stateB.SkippedCount -eq 4) ("expected 4 skips (indices 0,3,6,9), got " + $stateB.SkippedCount)
Test-Assert ($resultsB.Count -eq $stateB.DispatchedCount) ("dispatched count (" + $stateB.DispatchedCount + ") matches results collected (" + $resultsB.Count + ")")
Test-Assert ($outcomeB.ForceStoppedCount -eq 0) "ForceStoppedCount is 0 on a clean run"
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

$threwD = $false
try {
    $outcomeD = Invoke-ZipParallelProcessing -WorkerScript $fakeWorkerFail -JobParams $jobParamsD `
        -SharedFunctionNames @('Write-Log') -MaxParallel 2 -Cts $script:cts -ResultHandler $handlerD
} catch {
    $threwD = $true
}
$script:cts.Dispose()

Test-Assert (-not $threwD) "Invoke-ZipParallelProcessing itself did not throw when a worker threw"
Test-Assert ($resultsD.Count -eq 0) "no result was recorded for the failed worker (ResultHandler never invoked for it)"
Write-Host ""

# ==============================================================================
#  Scenario C (slow, ~65s): abort mid-run should gracefully drain fast jobs,
#  then force-stop anything still running after the 60s timeout.
#  Only runs with -RunSlowTest.
# ==============================================================================
if ($RunSlowTest) {
    Write-Host "=== Scenario C (slow, ~65s): abort mid-run forces stragglers after 60s ===" -ForegroundColor Cyan
    Write-Host "  (2 fast jobs should complete; 2 slow jobs should get force-stopped)" -ForegroundColor DarkGray

    [ConsoleCtrl]::AbortRequested = $false
    [ConsoleCtrl]::IsCloseEvent   = $false
    $script:abortRequested = $false
    $script:ctrlCloseAbort = $false
    $script:cts = [System.Threading.CancellationTokenSource]::new()

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
        -SharedFunctionNames @('Write-Log') -MaxParallel 4 -Cts $script:cts -ResultHandler $handlerC
    $swC.Stop()

    $triggerPs.EndInvoke($triggerHandle)
    $triggerPs.Dispose()
    $script:cts.Dispose()

    Test-Assert ($outcomeC.ForceStoppedCount -eq 2) ("expected 2 force-stopped jobs (the two 120s hangs), got " + $outcomeC.ForceStoppedCount)
    Test-Assert ((@($resultsC | Where-Object { $_.JobId -in @(1,2) })).Count -eq 2) "both fast jobs (1,2) completed and reported a result despite the abort"
    Test-Assert ($swC.Elapsed.TotalSeconds -ge 60 -and $swC.Elapsed.TotalSeconds -lt 90) ("total run time (" + [math]::Round($swC.Elapsed.TotalSeconds,1) + "s) is in the expected ~60-70s window (2s to abort + up to 60s drain, not the full 120s hang)")

    # Reset shared abort state so nothing leaks into a later run of this harness.
    [ConsoleCtrl]::AbortRequested = $false
    $script:abortRequested = $false
    $script:ctrlCloseAbort = $false

    Write-Host ""
} else {
    Write-Host "=== Scenario C skipped (pass -RunSlowTest to include it, ~65s) ===" -ForegroundColor DarkGray
    Write-Host ""
}

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

if (Test-Path -LiteralPath $logFile) { try { Remove-Item -LiteralPath $logFile -Force } catch { } }

if ($script:failCount -gt 0) { exit 1 } else { exit 0 }
