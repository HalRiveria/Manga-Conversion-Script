<#
.SYNOPSIS
    Invoke-ZipParallelProcessing - the parallel-dispatch engine for the
    zip-only pipeline (mode 3).

.DESCRIPTION
    This file IS the canonical definition of Invoke-ZipParallelProcessing -
    not a copy kept in sync with something else. Conversion Script Main.ps1
    currently still has its own separate inline copy of the same algorithm,
    under the older name Invoke-ParallelFolderJobs, wired into mode 3, that
    predates this module and this rename. Migrating mode 3 (and eventually
    mode 4) onto this module - replacing that inline copy with a dot-source
    of this file - is still open (see CLAUDE.md "Known gaps"). Until that
    migration happens, changes here do NOT need to be back-ported to the
    main script's inline copy, or vice versa - they're two independent
    implementations of the same proven algorithm, not mirrors, and this
    file's own historical notes about "copy X here if Y changes" no longer
    apply.

    Pure definitions only - no top-level side effects (ConsoleCtrl's
    Add-Type is guarded so this can be safely dot-sourced more than once,
    or alongside Modules\AbortPipeline.ps1, without erroring on a duplicate
    type). Dot-source this file to get ConsoleCtrl, Write-Log,
    Flush-ConsoleQueue, Test-AbortSignal, and Invoke-ZipParallelProcessing.

    Write-Log and Invoke-ZipParallelProcessing expect a handful of
    script-scope variables to already exist in the caller's scope (log file
    paths, a $pathHash for mutex naming, etc.) - see
    Modules\ZipParallelProcessing.Harness.ps1 for the minimal stand-ins a
    caller needs to provide, and for the actual test scenarios.
#>

# ==============================================================================
#  ConsoleCtrl - copied verbatim from Conversion Script Main.ps1
# ==============================================================================
if (-not ([System.Management.Automation.PSTypeName]'ConsoleCtrl').Type) {
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
}

# ==============================================================================
#  Write-Log / Flush-ConsoleQueue / Test-AbortSignal are copied verbatim from
#  Conversion Script Main.ps1. Invoke-ZipParallelProcessing below is this
#  file's own canonical definition - see the file-level .DESCRIPTION for what
#  that means for keeping it in sync (or not) with the main script's still-
#  separate, older-named inline copy.
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


function Invoke-ZipParallelProcessing {
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
        throw "Invoke-ZipParallelProcessing: must supply either -JobParams or -NextJobProvider."
    }
    if ($null -ne $JobParams -and $null -ne $NextJobProvider) {
        throw "Invoke-ZipParallelProcessing: supply only one of -JobParams or -NextJobProvider, not both."
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
