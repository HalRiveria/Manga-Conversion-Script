# See Docs/module-descriptions.md for this module's full description.

function Invoke-ZipParallelProcessing {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$WorkerScript,
        [System.Collections.Generic.List[hashtable]]$JobParams = $null,
        [scriptblock]$NextJobProvider = $null,
        [string[]]$SharedFunctionNames,
        [Parameter(Mandatory)]
        [int]$MaxParallel,
        [Parameter(Mandatory)]
        [System.Threading.CancellationTokenSource]$Cts,
        [Parameter(Mandatory)]
        [scriptblock]$ResultHandler,
        [string]$AbortWaitMessage = "[ABORT] Waiting for current jobs to finish (up to 60s)...",
        [scriptblock]$PollCallback = $null,
        [scriptblock]$JobCrashedHandler = $null
    )

    if ($null -eq $JobParams -and $null -eq $NextJobProvider) {
        throw "Invoke-ZipParallelProcessing: must supply either -JobParams or -NextJobProvider."
    }
    if ($null -ne $JobParams -and $null -ne $NextJobProvider) {
        throw "Invoke-ZipParallelProcessing: supply only one of -JobParams or -NextJobProvider, not both."
    }

    if ($null -ne $JobParams -and $JobParams.Count -eq 0) { return @{ ForceStoppedCount = 0 } }

    $fixedListIndex = 0

    $previousLogMutex  = $null
    $localLogMutex     = $null
    $localPool         = $null
    $localHandles      = [System.Collections.Generic.List[hashtable]]::new()
    $scanExhausted     = $false
    $forceStoppedCount = 0

    try {
        $previousLogMutex = $script:logMutex
        Initialize-LogMutex
        $localLogMutex = $script:logMutex
        $localConsoleQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

        $localIss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($sharedFn in $SharedFunctionNames) {
            try {
                $fnDef = (Get-Item ("Function:\" + $sharedFn) -ErrorAction Stop).Definition
            } catch {
                throw ("Invoke-ZipParallelProcessing: -SharedFunctionNames entry '" + $sharedFn + "' does not resolve to a defined function - check for a typo, or that the module defining it was dot-sourced before this call. Original error: " + $_)
            }
            $localIss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $sharedFn, $fnDef))
        }

        $localPool = [RunspaceFactory]::CreateRunspacePool(1, $MaxParallel, $localIss, $Host)
        $localPool.Open()

        while ((-not $scanExhausted -or $localHandles.Count -gt 0) -and -not $Cts.Token.IsCancellationRequested) {

            while (-not $scanExhausted -and $localHandles.Count -lt $MaxParallel -and -not $Cts.Token.IsCancellationRequested) {
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
                $null = $ps.AddParameter("CancelToken", $Cts.Token)
                $null = $ps.AddParameter("LogMutex", $localLogMutex)
                $null = $ps.AddParameter("ConsoleQueue", $localConsoleQueue)
                $localHandles.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
            }

            $null = Test-AbortSignal
            Flush-ConsoleQueue -Queue $localConsoleQueue
            if ($null -ne $PollCallback) { & $PollCallback }

            $localStillPending = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($h in $localHandles) {
                if ($h.Handle.IsCompleted) {
                    $localResults = $null
                    try {
                        $localResults = $h.PS.EndInvoke($h.Handle)
                        if ($h.PS.HadErrors) {
                            foreach ($e in $h.PS.Streams.Error) { Write-Log ("Runspace error: " + $e.ToString()) -Level Error }
                        }
                    } catch {
                        Write-Log ("Error collecting runspace result: " + $_) -Level Error
                        # An unhandled exception in the worker script itself
                        # (not just a non-terminating error in its output
                        # streams, above) lands here - EndInvoke rethrows it.
                        # -JobCrashedHandler exists so a caller whose "job" is
                        # a long-lived worker (Controller.ps1's Full Pipeline
                        # engines, one job = one whole engine) can react to
                        # losing that worker entirely - -ResultHandler is
                        # NEVER called for a job that lands here, since there
                        # is no result (2026-09-15 finding: a caller with no
                        # -JobCrashedHandler previously had no way to learn a
                        # worker died mid-run at all, not even via logging it
                        # noticed anything was wrong).
                        if ($null -ne $JobCrashedHandler) { try { & $JobCrashedHandler $_ } catch { } }
                    } finally {
                        $h.PS.Dispose()
                    }
                    if ($null -ne $localResults) {
                        foreach ($r in $localResults) { & $ResultHandler $r }
                    }
                } else {
                    $localStillPending.Add($h)
                }
            }
            $localHandles = $localStillPending
            if ($localHandles.Count -gt 0 -and ($scanExhausted -or $localHandles.Count -ge $MaxParallel)) { Start-Sleep -Milliseconds 100 }
        }

        if ($Cts.Token.IsCancellationRequested) {
            $drainResult = Invoke-GracefulDrain -Handles $localHandles -ResultHandler $ResultHandler `
                -ConsoleQueue $localConsoleQueue -TimeoutSeconds 60 -AbortWaitMessage $AbortWaitMessage `
                -ErrorHandler { param($msg) Write-Log $msg -Level Error }
            $forceStoppedCount = $drainResult.ForceStoppedCount
        }

        Flush-ConsoleQueue -Queue $localConsoleQueue
        if ($null -ne $PollCallback) { & $PollCallback }
    } finally {
        foreach ($h in $localHandles) {
            try { $h.PS.Stop() } catch { }
            try { $h.PS.Dispose() } catch { }
        }
        if ($null -ne $localPool) { try { $localPool.Close() } catch { }; try { $localPool.Dispose() } catch { } }
        $script:logMutex = $previousLogMutex
        if ($null -ne $localLogMutex) { try { $localLogMutex.Dispose() } catch { } }
    }

    return @{ ForceStoppedCount = $forceStoppedCount }
}
