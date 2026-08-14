<#
.SYNOPSIS
    Standalone test harness for Invoke-ParallelFolderJobs, extracted from
    Convert_to_Jxl_14_4.ps1 v16.0.

.DESCRIPTION
    Exercises Invoke-ParallelFolderJobs in isolation, with fake workers that
    do no real conversion or zipping - just simulated delay/failure/hang -
    so it can be validated before any pipeline (mode 3, and eventually mode 4)
    is pointed at it for real.

    The functions below (ConsoleCtrl, Write-Log, Flush-ConsoleQueue,
    Test-AbortSignal, Invoke-ParallelFolderJobs) are copied VERBATIM from
    Convert_to_Jxl_14_4.ps1 - not retyped - so this is testing the actual
    code, not a reimplementation that could drift from it. If you change
    Invoke-ParallelFolderJobs in the main script, re-copy it here too (or
    ask Claude to regenerate this harness) before trusting these results
    again.

    Scenarios A, B, and D run in a few seconds. Scenario C (graceful-drain-
    then-force-stop after a real Ctrl+C-equivalent abort) takes about a
    minute by design, since it exercises the real 60-second timeout in
    Invoke-ParallelFolderJobs - run it with -RunSlowTest.

    KNOWN GAP: this harness simulates abort by setting
    [ConsoleCtrl]::AbortRequested directly from a background runspace,
    which exercises everything from Test-AbortSignal onward (this is the
    part Invoke-ParallelFolderJobs actually depends on) but does NOT
    exercise the real SetConsoleCtrlHandler P/Invoke registration or the
    OS-blocking-handler dance around it. A real Ctrl+C press during a real
    run is the only thing that tests that part end-to-end.

.PARAMETER RunSlowTest
    Also run Scenario C (~65 seconds). Omit to run only the fast scenarios
    (A, B, D - a few seconds total).

.EXAMPLE
    .\Test-InvokeParallelFolderJobs.ps1
    .\Test-InvokeParallelFolderJobs.ps1 -RunSlowTest
#>

param(
    [switch]$RunSlowTest
)

$ErrorActionPreference = "Stop"

# ==============================================================================
#  ConsoleCtrl - copied verbatim from Convert_to_Jxl_14_4.ps1
# ==============================================================================
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class ConsoleCtrl
{
    public delegate bool HandlerRoutine(uint ctrlType);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

    // Shared state set by the handler; polled by the main PowerShell thread.
    public static volatile bool AbortRequested = false;
    public static volatile bool IsCloseEvent   = false;   // true = X button, false = Ctrl+C

    // The handler signals this when abort is requested; the main thread calls
    // Set() when the graceful drain is complete so the handler can return.
    public static readonly ManualResetEventSlim DrainComplete = new ManualResetEventSlim(false);

    private static HandlerRoutine _handler;   // keep a strong ref so the GC can't collect it

    public static void Register()
    {
        _handler = new HandlerRoutine(Handler);
        SetConsoleCtrlHandler(_handler, true);
    }

    private static bool Handler(uint ctrlType)
    {
        // ctrlType: 0=CTRL_C, 1=CTRL_BREAK, 2=CTRL_CLOSE, 5=CTRL_LOGOFF, 6=CTRL_SHUTDOWN
        if (ctrlType == 0 || ctrlType == 1 || ctrlType == 2 || ctrlType == 5 || ctrlType == 6)
        {
            AbortRequested = true;
            IsCloseEvent   = (ctrlType == 2 || ctrlType == 5 || ctrlType == 6);
            // Block until the PowerShell main thread finishes the graceful drain
            // (or until Windows force-kills us after its timeout).
            DrainComplete.Wait(65000);   // 65 s > our 60 s job timeout
            return true;   // suppress default OS action
        }
        return false;
    }
}
'@ -Language CSharp
[ConsoleCtrl]::Register()

# ==============================================================================
#  Script-scope state Write-Log / Test-AbortSignal / Invoke-ParallelFolderJobs
#  expect to find - same variable names as the main script, minimal harness
#  stand-ins for the rest (no real -Path, no real log/state files).
# ==============================================================================
$script:logMutex           = $null
$script:workerConsoleQueue = $null
$script:abortRequested     = $false
$script:ctrlCloseAbort     = $false
$script:cts                = $null   # Invoke-ParallelFolderJobs assigns/uses this per-scenario

$FullLogging  = $true
$logFile      = Join-Path ([System.IO.Path]::GetTempPath()) ("pfj-harness-" + [guid]::NewGuid().ToString("N") + ".log")
$logErrorFile = $logFile
$logWarnFile  = $logFile
$pathHash     = "harness0001"   # stand-in for the real per-Path SHA256 hash; only used for a mutex name

Write-Host ("Harness log file: " + $logFile) -ForegroundColor DarkGray
Write-Host ""

# ==============================================================================
#  Write-Log / Flush-ConsoleQueue / Test-AbortSignal / Invoke-ParallelFolderJobs
#  - copied verbatim from Convert_to_Jxl_14_4.ps1
# ==============================================================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info","Warn","Error","Summary")][string]$Level = "Info"
    )

    $line = (Get-Date -Format "yyyy-MM-dd HHmmss") + " [" + $Level + "] " + $Message
    $safeLine = [System.Text.RegularExpressions.Regex]::Replace($line, "[^\x00-\x7F]", "?")

    $mtx = $script:logMutex

    if ($FullLogging) {
        # Full-logging mode: every level goes to the single timestamped file
        try   {
            if ($null -ne $mtx) { $null = $mtx.WaitOne() }
            $safeLine | Out-File -FilePath $logFile -Append -Encoding ASCII
        }
        finally { if ($null -ne $mtx) { $mtx.ReleaseMutex() } }
    } else {
        # Split-log mode
        if ($Level -eq "Error") {
            try   {
                if ($null -ne $mtx) { $null = $mtx.WaitOne() }
                $safeLine | Out-File -FilePath $logErrorFile -Append -Encoding ASCII
            }
            finally { if ($null -ne $mtx) { $mtx.ReleaseMutex() } }
        } elseif ($Level -eq "Warn") {
            try   {
                if ($null -ne $mtx) { $null = $mtx.WaitOne() }
                $safeLine | Out-File -FilePath $logWarnFile -Append -Encoding ASCII
            }
            finally { if ($null -ne $mtx) { $mtx.ReleaseMutex() } }
        } elseif ($Level -eq "Summary") {
            # Summary is written later in block form; nothing to do per-line here
        }
        # Info lines are not written in split-log mode
    }

    # Inside a runspace worker, $script:workerConsoleQueue is set (see $zipWorker) and
    # cross-thread Write-Host is unsafe, so queue for the main thread to drain
    # via Flush-ConsoleQueue instead of writing directly.
    if ($null -ne $script:workerConsoleQueue) {
        $script:workerConsoleQueue.Enqueue([pscustomobject]@{ Message = $Message; Level = $Level })
    } else {
        switch ($Level) {
            "Error"   { Write-Host $line -ForegroundColor Red    }
            "Warn"    { Write-Host $line -ForegroundColor Yellow }
            "Summary" { Write-Host $line -ForegroundColor Cyan   }
            default   { Write-Host $line }
        }
    }
}

function Flush-ConsoleQueue {
    param([System.Collections.Concurrent.ConcurrentQueue[object]]$Queue)

    $item = $null
    while ($Queue.TryDequeue([ref]$item)) {
        $line = (Get-Date -Format "yyyy-MM-dd HHmmss") + " [" + $item.Level + "] " + $item.Message
        switch ($item.Level) {
            "Error"   { Write-Host $line -ForegroundColor Red    }
            "Warn"    { Write-Host $line -ForegroundColor Yellow }
            "Summary" { Write-Host $line -ForegroundColor Cyan   }
            default   { Write-Host $line }
        }
    }
}

function Test-AbortSignal {
    if ([ConsoleCtrl]::AbortRequested -and -not $script:abortRequested) {
        $script:abortRequested = $true
        $script:ctrlCloseAbort = [ConsoleCtrl]::IsCloseEvent
        if ($null -ne $script:cts)        { try { $script:cts.Cancel()        } catch { } }
        if ($null -ne $script:looseCts)   { try { $script:looseCts.Cancel()   } catch { } }
        if ($null -ne $script:zipOnlyCts) { try { $script:zipOnlyCts.Cancel() } catch { } }
        if (-not $script:ctrlCloseAbort) {
            Write-Host "`n[ABORT] Ctrl+C detected - finishing current jobs, please wait..." -ForegroundColor Yellow
        } else {
            Write-Host "`n[ABORT] Window close detected - finishing current jobs, please wait..." -ForegroundColor Yellow
        }
    }
    return $script:abortRequested
}


function Invoke-ParallelFolderJobs {
    param(
        [scriptblock]$WorkerScript,
        [System.Collections.Generic.List[hashtable]]$JobParams = $null,
        [scriptblock]$NextJobProvider = $null,
        [string[]]$SharedFunctionNames,
        [int]$MaxParallel,
        [System.Threading.CancellationTokenSource]$Cts,
        [scriptblock]$ResultHandler,
        [string]$AbortWaitMessage = "[ABORT] Waiting for current jobs to finish (up to 60s)..."
    )

    if ($null -eq $JobParams -and $null -eq $NextJobProvider) {
        throw "Invoke-ParallelFolderJobs: must supply either -JobParams or -NextJobProvider."
    }
    if ($null -ne $JobParams -and $null -ne $NextJobProvider) {
        throw "Invoke-ParallelFolderJobs: supply only one of -JobParams or -NextJobProvider, not both."
    }

    if ($null -ne $JobParams -and $JobParams.Count -eq 0) { return @{ ForceStoppedCount = 0 } }

    # Plain counter, only used when -JobParams was supplied; read and
    # incremented directly in the dispatch loop below (not inside any nested
    # scriptblock/closure - see the CRITICAL note above -NextJobProvider in
    # the docstring for why that distinction matters here).
    $fixedListIndex = 0

    $localLogMutex   = [System.Threading.Mutex]::new($false, ("JxlLogMutex_" + $pathHash))
    $script:logMutex = $localLogMutex
    $localConsoleQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

    $localIss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($sharedFn in $SharedFunctionNames) {
        $fnDef = (Get-Item ("Function:\" + $sharedFn)).Definition
        $localIss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $sharedFn, $fnDef))
    }

    $localPool = [RunspaceFactory]::CreateRunspacePool(1, $MaxParallel, $localIss, $Host)
    $localPool.Open()

    $localHandles      = [System.Collections.Generic.List[hashtable]]::new()
    $scanExhausted     = $false
    $forceStoppedCount = 0

    try {
        # ==================================================================
        #  Combined get-next-job + dispatch + collect loop. Exits once the
        #  job source is exhausted and every dispatched job has returned, or
        #  once the abort flag is set (the graceful drain below takes over).
        # ==================================================================
        while ((-not $scanExhausted -or $localHandles.Count -gt 0) -and -not $Cts.Token.IsCancellationRequested) {

            while (-not $scanExhausted -and $localHandles.Count -lt $MaxParallel -and -not $Cts.Token.IsCancellationRequested) {
                # -JobParams handled directly here (plain local counter, no
                # closure); -NextJobProvider is the caller's own closure,
                # invoked via & - see the docstring's CRITICAL note on that
                # for what a provider's own internal state must do instead.
                if ($null -ne $JobParams) {
                    if ($fixedListIndex -lt $JobParams.Count) {
                        $nextJob = $JobParams[$fixedListIndex]
                        $fixedListIndex++
                    } else {
                        $nextJob = $null
                    }
                } else {
                    $nextJob = & $NextJobProvider
                }
                if ($null -eq $nextJob) { $scanExhausted = $true; break }

                $ps = [PowerShell]::Create()
                $ps.RunspacePool = $localPool
                $null = $ps.AddScript($WorkerScript)
                foreach ($key in $nextJob.Keys) { $null = $ps.AddParameter($key, $nextJob[$key]) }
                # See docstring: every worker must declare these three; bound
                # here automatically rather than requiring each job (whether
                # from -JobParams or a -NextJobProvider) to include them.
                $null = $ps.AddParameter("CancelToken", $Cts.Token)
                $null = $ps.AddParameter("LogMutex", $localLogMutex)
                $null = $ps.AddParameter("ConsoleQueue", $localConsoleQueue)
                $localHandles.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
            }

            $null = Test-AbortSignal
            Flush-ConsoleQueue -Queue $localConsoleQueue

            $localStillPending = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($h in $localHandles) {
                if ($h.Handle.IsCompleted) {
                    try {
                        $localResults = $h.PS.EndInvoke($h.Handle)
                        foreach ($r in $localResults) { & $ResultHandler $r }
                        if ($h.PS.HadErrors) {
                            foreach ($e in $h.PS.Streams.Error) { Write-Log ("Runspace error: " + $e.ToString()) -Level Error }
                        }
                    } catch {
                        Write-Log ("Error collecting runspace result: " + $_) -Level Error
                    } finally {
                        $h.PS.Dispose()
                    }
                } else {
                    $localStillPending.Add($h)
                }
            }
            $localHandles = $localStillPending
            if ($localHandles.Count -gt 0 -and ($scanExhausted -or $localHandles.Count -ge $MaxParallel)) { Start-Sleep -Milliseconds 100 }
        }

        # Graceful drain after abort: wait up to 60s for in-flight jobs to
        # finish naturally, then force-stop anything still running. Jobs the
        # provider hadn't yet produced (or hadn't been dispatched due to a
        # full pool) are simply never dispatched - nothing to drain for those.
        if ($Cts.Token.IsCancellationRequested -and $localHandles.Count -gt 0) {
            if ($AbortWaitMessage) { Write-Host $AbortWaitMessage -ForegroundColor Yellow }
            $abortDeadline = [System.Diagnostics.Stopwatch]::StartNew()

            while ($localHandles.Count -gt 0 -and $abortDeadline.Elapsed.TotalSeconds -lt 60) {
                $localStillActive = [System.Collections.Generic.List[hashtable]]::new()
                foreach ($h in $localHandles) {
                    if ($h.Handle.IsCompleted) {
                        try {
                            $localResults = $h.PS.EndInvoke($h.Handle)
                            foreach ($r in $localResults) { & $ResultHandler $r }
                        } catch { }
                        finally { $h.PS.Dispose() }
                    } else {
                        $localStillActive.Add($h)
                    }
                }
                $localHandles = $localStillActive
                Flush-ConsoleQueue -Queue $localConsoleQueue
                if ($localHandles.Count -gt 0) { Start-Sleep -Milliseconds 250 }
            }

            if ($localHandles.Count -gt 0) {
                $forceStoppedCount = $localHandles.Count
                Write-Host ("[ABORT] Force-stopping " + $forceStoppedCount + " job(s) that did not finish within 60s.") -ForegroundColor Red
                foreach ($h in $localHandles) {
                    try { $h.PS.Stop() } catch { }
                    try { $h.PS.Dispose() } catch { }
                }
                $localHandles = [System.Collections.Generic.List[hashtable]]::new()
            }
        }

        Flush-ConsoleQueue -Queue $localConsoleQueue
    } finally {
        # Always torn down, even if the provider, worker collection, or
        # -ResultHandler throws - the previous version of this function had
        # no such guarantee and could leak the pool/mutex on an exception.
        if ($null -ne $localPool) { try { $localPool.Close() } catch { }; try { $localPool.Dispose() } catch { } }
        $script:logMutex = $null   # stop Write-Log from acquiring a disposed mutex
        if ($null -ne $localLogMutex) { try { $localLogMutex.Dispose() } catch { } }
    }

    return @{ ForceStoppedCount = $forceStoppedCount }
}

# ==============================================================================
#  Fake workers - no real conversion/zipping, just simulated delay/failure.
#  Every worker used with Invoke-ParallelFolderJobs must declare CancelToken,
#  LogMutex, and ConsoleQueue - see the docstring on Invoke-ParallelFolderJobs.
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

$outcomeA = Invoke-ParallelFolderJobs -WorkerScript $fakeWorkerOk -JobParams $jobParamsA `
    -SharedFunctionNames @('Write-Log') -MaxParallel 3 -Cts $script:cts -ResultHandler $handlerA
$script:cts.Dispose()

Test-Assert ($resultsA.Count -eq 6) ("all 6 jobs returned a result (got " + $resultsA.Count + ")")
Test-Assert ($outcomeA.ForceStoppedCount -eq 0) "ForceStoppedCount is 0 on a clean run"
Test-Assert ((@($resultsA | Where-Object { $_.Ok })).Count -eq 6) "all 6 results report Ok"
Test-Assert ((@($resultsA | Sort-Object JobId -Unique)).Count -eq 6) "all 6 JobIds are distinct (no duplicate/dropped dispatch)"
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
# and its docstring note in Invoke-ParallelFolderJobs for why - this harness
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

$outcomeB = Invoke-ParallelFolderJobs -WorkerScript $fakeWorkerOk -NextJobProvider $providerB `
    -SharedFunctionNames @('Write-Log') -MaxParallel 4 -Cts $script:cts -ResultHandler $handlerB
$script:cts.Dispose()

Test-Assert ($stateB.Index -eq $bTotal) "provider was called through to full exhaustion"
Test-Assert ($stateB.SkippedCount -eq 4) ("expected 4 skips (indices 0,3,6,9), got " + $stateB.SkippedCount)
Test-Assert ($resultsB.Count -eq $stateB.DispatchedCount) ("dispatched count (" + $stateB.DispatchedCount + ") matches results collected (" + $resultsB.Count + ")")
Test-Assert ($outcomeB.ForceStoppedCount -eq 0) "ForceStoppedCount is 0 on a clean run"
Write-Host ""

# ==============================================================================
#  Scenario D: a worker throws immediately - Invoke-ParallelFolderJobs must
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
    $outcomeD = Invoke-ParallelFolderJobs -WorkerScript $fakeWorkerFail -JobParams $jobParamsD `
        -SharedFunctionNames @('Write-Log') -MaxParallel 2 -Cts $script:cts -ResultHandler $handlerD
} catch {
    $threwD = $true
}
$script:cts.Dispose()

Test-Assert (-not $threwD) "Invoke-ParallelFolderJobs itself did not throw when a worker threw"
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
    $outcomeC = Invoke-ParallelFolderJobs -WorkerScript $fakeWorkerOk -JobParams $jobParamsC `
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