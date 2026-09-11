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

    This file dot-sources Logging.ps1/AbortPipeline.ps1 rather than
    carrying its own inline ConsoleCtrl/Write-Log/Flush-ConsoleQueue/
    Test-AbortSignal copies. Pure definitions only - no top-level side
    effects. Dot-source
    AbortPipeline.ps1 and Logging.ps1 BEFORE this file (see FORWARD
    REFERENCES below); dot-source this file to get
    Invoke-ZipParallelProcessing itself.

    FORWARD REFERENCES (not defined in this module - callers must
    dot-source the owning module(s) first):
      - ConsoleCtrl (the type), Test-AbortSignal, Register-/Unregister-
        AbortCancellationSource, Invoke-GracefulDrain (AbortPipeline.ps1)
      - Write-Log, Flush-ConsoleQueue, Initialize-LogMutex, $script:pathHash
        (Logging.ps1)
    Modules\_Harness\ZipParallelProcessing.Harness.ps1 dot-sources both
    real modules now instead of stubbing this file's own former inline
    copies - re-verify against the real ordering rule ZipPipeline.ps1's
    own header already documents: dot-source Logging.ps1/FileDeletion.ps1
    BEFORE this file if anything else in the same session also dot-sources
    them, since -SharedFunctionNames captures whichever definition is
    CURRENTLY active in the caller's scope at call time.

    ABORT REGISTRATION IS THE CALLER'S JOB, NOT THIS FUNCTION'S: matching
    AbortPipeline.ps1's own documented contract (register once per
    pipeline phase, right after creating that phase's CTS; unregister
    when disposing it), Invoke-ZipParallelProcessing does NOT call
    Register-/Unregister-AbortCancellationSource on the -Cts it's handed
    - the caller that created that CTS (ZipPipeline.ps1's
    Invoke-ZipOnlyPipeline) owns that lifecycle, exactly like
    ImageConversionPipeline.ps1's own $looseCts. This replaces the OLD
    Test-AbortSignal's hardcoded three-variable cancellation
    ($script:cts/$script:looseCts/$script:zipOnlyCts) with the
    generalized registry - a caller no longer needs a magically-named
    script-scope CTS variable to participate in abort handling.

    THE GRACEFUL-DRAIN RACE CONDITION THIS MIGRATION FIXES: the old inline
    drain loop force-stopped stragglers immediately after its 60s timeout
    expired, with no final completion-check pass first - a job finishing
    in the ~250ms gap between the last poll and the timeout firing had its
    real result silently discarded and got miscounted as force-stopped
    (see CLAUDE.md "Known gaps" for the full history). AbortPipeline.ps1's
    Invoke-GracefulDrain already closes this (one final Receive-
    CompletedHandles pass before declaring anything force-stopped) -
    migrating onto it picks up that fix for mode 3 for the first time.
    Also newly fixed as a side effect: the old inline drain never signalled
    [ConsoleCtrl]::DrainComplete at all (a separate, already-documented gap
    - CTRL_CLOSE_EVENT gives the native handler only ~5s before Windows
    force-kills the process, risking a kill mid-drain) - Invoke-GracefulDrain
    always signals it now.

    Write-Log and Invoke-ZipParallelProcessing expect a handful of
    script-scope variables to already exist in the caller's scope (log file
    paths, a $pathHash for mutex naming, etc.) - see
    Modules\ZipParallelProcessing.Harness.ps1 for the minimal stand-ins a
    caller needs to provide, and for the actual test scenarios.
#>


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
        # $null default = unchanged behavior for every existing caller.
        # Invoked once per dispatch-loop pass, right after
        # Flush-ConsoleQueue below - same cadence, same reasoning: a
        # caller running two Invoke-ChapterDispatch instances
        # concurrently inside this function's own two worker runspaces
        # needs a way to drain a SEPARATE cross-worker event queue (Clean
        # Console Output updates neither worker can safely call directly -
        # see Docs/dispatch-redesign-design.md's Problem 3) on the main
        # thread, at a real cadence, without this function needing to know
        # anything about what that queue holds or what draining it means.
        # Takes no parameters - a caller with per-pass state closes over it
        # the same way -ResultHandler/-NextJobProvider already do.
        [scriptblock]$PollCallback = $null
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

    # $previousLogMutex declared here (outside the try) so the `finally`
    # below can always see it, even if something inside the try throws
    # before ever reaching the assignment - left $null in that case, which
    # is what $script:logMutex should become anyway (nothing valid was
    # ever saved to restore).
    $previousLogMutex  = $null
    $localLogMutex     = $null
    $localPool         = $null
    $localHandles      = [System.Collections.Generic.List[hashtable]]::new()
    $scanExhausted     = $false
    $forceStoppedCount = 0

    try {
        # Uses Logging.ps1's Initialize-LogMutex rather than an inline
        # "JxlLogMutex_" + $pathHash construction - single implementation
        # instead of a third copy of it. $previousLogMutex is saved
        # before overwriting: this call always creates a brand-new Mutex
        # object regardless of what was already there, so the caller's
        # own (e.g. bootstrap's) mutex reference needs to be restored
        # afterward, not discarded - see the `finally` block below. This
        # line and everything through $localPool.Open() below sit inside
        # the try on purpose, so an exception here (or from the
        # -SharedFunctionNames Get-Item lookup, or from
        # CreateRunspacePool/Open() failing) still reaches `finally`
        # instead of leaving $script:logMutex pointed at this call's own
        # local mutex forever with its handle never disposed.
        $previousLogMutex = $script:logMutex
        Initialize-LogMutex
        $localLogMutex = $script:logMutex
        $localConsoleQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

        $localIss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($sharedFn in $SharedFunctionNames) {
            # A misspelled name, or one whose owning module wasn't
            # dot-sourced before this call, would otherwise throw a bare
            # ItemNotFoundException with no mention of -SharedFunctionNames
            # or a dot-sourcing-order problem - re-thrown here with that
            # context so the actual cause is obvious instead of a generic
            # "cannot find path" message.
            try {
                $fnDef = (Get-Item ("Function:\" + $sharedFn)).Definition
            } catch {
                throw ("Invoke-ZipParallelProcessing: -SharedFunctionNames entry '" + $sharedFn + "' does not resolve to a defined function - check for a typo, or that the module defining it was dot-sourced before this call. Original error: " + $_)
            }
            $localIss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $sharedFn, $fnDef))
        }

        $localPool = [RunspaceFactory]::CreateRunspacePool(1, $MaxParallel, $localIss, $Host)
        $localPool.Open()

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
                    } finally {
                        $h.PS.Dispose()
                    }
                    # -ResultHandler runs outside the try/catch above on
                    # purpose. A bug in the caller's own -ResultHandler
                    # would otherwise be caught here too and mislabeled as
                    # "Error collecting runspace result," silently
                    # dropping any remaining results from this same job
                    # with no indication the real bug was in the caller's
                    # own code, not the runspace. Letting it propagate
                    # uncaught surfaces the real exception with its own
                    # message and stack; this function's own outer
                    # `finally` still tears down the pool/mutex normally,
                    # and $h.PS is already disposed above either way.
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

        # Graceful drain after abort: wait up to 60s for in-flight jobs to
        # finish naturally, then force-stop anything still running. Jobs the
        # provider hadn't yet produced (or hadn't been dispatched due to a
        # full pool) are simply never dispatched - nothing to drain for those.
        # Uses AbortPipeline.ps1's Invoke-GracefulDrain rather than an
        # inline copy of this loop - it fixes a real race (a job finishing
        # in the gap between the last poll and the timeout firing was
        # silently discarded and miscounted as force-stopped) and signals
        # [ConsoleCtrl]::DrainComplete. This stays gated on
        # $Cts.Token.IsCancellationRequested - Invoke-GracefulDrain must
        # not run, and must not signal DrainComplete, on a normal,
        # non-aborted completion. Reset-AbortState resets DrainComplete
        # once per loop iteration (Controller.ps1's Invoke-MainLoop,
        # before the next mode is resolved), so within a single run,
        # signalling it here unconditionally would make a later, real
        # Ctrl+C's own drain wait return instantly for the rest of that
        # run, risking the OS force-killing the process before the real
        # drain has actually happened.
        if ($Cts.Token.IsCancellationRequested) {
            $drainResult = Invoke-GracefulDrain -Handles $localHandles -ResultHandler $ResultHandler `
                -ConsoleQueue $localConsoleQueue -TimeoutSeconds 60 -AbortWaitMessage $AbortWaitMessage `
                -ErrorHandler { param($msg) Write-Log $msg -Level Error }
            $forceStoppedCount = $drainResult.ForceStoppedCount
        }

        Flush-ConsoleQueue -Queue $localConsoleQueue
        # One final drain: a job that completed on the very last pass
        # through the loop above can leave a PollCallback-relevant event
        # enqueued with no further pass ever coming to drain it otherwise -
        # mirrors this exact function's own final Flush-ConsoleQueue call
        # immediately above, for the same reason.
        if ($null -ne $PollCallback) { & $PollCallback }
    } finally {
        # Dispose any $localHandles left over. On the normal completion
        # path this list is already empty (the collection loop above
        # drains it). On the abort path it's usually not empty here -
        # Invoke-GracefulDrain takes a snapshot of $localHandles (its own
        # `$localHandles = $Handles` parameter binding) and disposes that
        # list as jobs complete, but never writes back into this
        # function's own `$localHandles` variable, so this loop still
        # runs over every handle that was in flight when the drain
        # started. That's harmless, since `Stop()`/`Dispose()` are both
        # wrapped in try/catch here and `Dispose()` is idempotent. The
        # case this loop actually exists for is something throwing before
        # the drain ever gets a chance to run at all (-NextJobProvider
        # itself throwing, or Test-AbortSignal/Flush-ConsoleQueue
        # failing) - contained even without this (the pool close/process
        # exit below still cleans up eventually) but matches this
        # project's own "resource lifecycle matches acquisition,
        # including the error path" review checklist item.
        foreach ($h in $localHandles) {
            try { $h.PS.Stop() } catch { }
            try { $h.PS.Dispose() } catch { }
        }
        # Always torn down, even if the provider, worker collection, or
        # -ResultHandler throws - the previous version of this function had
        # no such guarantee and could leak the pool/mutex on an exception.
        if ($null -ne $localPool) { try { $localPool.Close() } catch { }; try { $localPool.Dispose() } catch { } }
        # Restore the caller's own mutex reference rather than nulling
        # it - this function's own $localLogMutex is disposed
        # below (it was only ever needed to seed the worker runspaces'
        # InitialSessionState), but $script:logMutex is shared, main-thread
        # state the CALLER still needs for its own Write-Log calls after
        # this function returns (e.g. Controller.ps1's zip/delete steps
        # between chapters, or the run's final summary write). Nulling it
        # unconditionally left every main-thread log write after the FIRST
        # parallel phase in a run silently unsynchronized -
        # Invoke-MutexGuardedWrite no-ops the locking on a $null mutex
        # rather than erroring, so this was never visibly broken, just
        # quietly unprotected against another concurrent instance writing
        # to the same log/summary file.
        $script:logMutex = $previousLogMutex
        if ($null -ne $localLogMutex) { try { $localLogMutex.Dispose() } catch { } }
    }

    return @{ ForceStoppedCount = $forceStoppedCount }
}
