# See module-descriptions.md for this module's full description.

function New-LibraryChapterProvider {
    param(
        [Parameter(Mandatory)]
        [string]$LibraryPath,
        [Parameter(Mandatory)]
        [string[]]$QualifyingExtensions,
        [System.Collections.Generic.HashSet[string]]$ExcludeStagingDirs = $null,
        [bool]$ForceRezip = $false
    )
    $seriesProvider = New-SeriesProvider -LibraryPath $LibraryPath -QualifyingExtensions $QualifyingExtensions
    $chapterQueue   = [System.Collections.Generic.Queue[hashtable]]::new()
    # Hashtable, not a plain scalar - a plain $seriesExhausted assigned
    # inside this .GetNewClosure()'d scriptblock resets to $false on every
    # invocation instead of latching. Currently harmless here (the caller
    # stops polling once this returns $null anyway), but a plain scalar
    # would read as working protection that isn't. Matches
    # LeafDirectoryDiscovery.ps1's New-ZippableLeafDirProvider, which uses
    # the same pattern for the same reason.
    $state = @{ SeriesExhausted = $false }

    return {
        while ($chapterQueue.Count -eq 0 -and -not $state.SeriesExhausted) {
            $series = & $seriesProvider
            if ($null -eq $series) { $state.SeriesExhausted = $true; break }
            $chapters = Get-SeriesChapters -SeriesPath $series.FullName -QualifyingExtensions $QualifyingExtensions `
                -ExcludeStagingDirs $ExcludeStagingDirs -ForceRezip $ForceRezip
            foreach ($ch in $chapters) {
                $chapterQueue.Enqueue(@{ SeriesName = $series.Name; ChapterName = $ch.Dir.Name; Dir = $ch.Dir; ZipOut = $ch.ZipOut })
            }
        }
        if ($chapterQueue.Count -gt 0) { return $chapterQueue.Dequeue() }
        return $null
    }.GetNewClosure()
}

function Invoke-ChapterDispatch {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ChapterProvider,
        [Parameter(Mandatory)]
        [scriptblock]$JobBuilder,
        [Parameter(Mandatory)]
        [scriptblock]$JobStarter,
        [Parameter(Mandatory)]
        [scriptblock]$JobPollCompleted,
        [Parameter(Mandatory)]
        [scriptblock]$JobFinalize,
        [Parameter(Mandatory)]
        [scriptblock]$JobAbortCleanup,
        [Parameter(Mandatory)]
        [scriptblock]$ChapterCompleteCallback,
        [Parameter(Mandatory)]
        $MaxConcurrent,
        [scriptblock]$AbortPollCallback = $null,
        [Parameter(Mandatory)]
        [System.Threading.CancellationToken]$CancelToken,
        [int]$AbortTimeoutSeconds = 60,
        [int]$MaxQueueAhead = 3,
        [scriptblock]$ChapterReleaseCheck = $null
    )

    $isSharedBudget = ($MaxConcurrent -is [System.Threading.SemaphoreSlim])

    $chapterStates      = [System.Collections.Generic.Dictionary[object,hashtable]]::new()
    $chapterResults     = [System.Collections.Generic.List[hashtable]]::new()
    $activeChapterCount = 0
    $providerExhausted  = $false
    $heldChapters       = [System.Collections.Generic.List[object]]::new()

    $pending = [System.Collections.Generic.Queue[hashtable]]::new()
    $running = [System.Collections.Generic.List[hashtable]]::new()

    $dispatchResult = @{
        ChapterResults        = $chapterResults
        Aborted                = $false
        ForceKilledCount       = 0
        JobStarterFailedCount  = 0
    }

    try {
    while ((-not $CancelToken.IsCancellationRequested) -and `
           (-not $providerExhausted -or $activeChapterCount -gt 0 -or $pending.Count -gt 0 -or $running.Count -gt 0)) {

        for ($h = $heldChapters.Count - 1; $h -ge 0; $h--) {
            if ([bool](& $ChapterReleaseCheck $heldChapters[$h])) {
                $heldChapters.RemoveAt($h)
                $activeChapterCount--
            }
        }

        while ((-not $providerExhausted) -and $activeChapterCount -lt $MaxQueueAhead -and (-not $CancelToken.IsCancellationRequested)) {
            $chapterInfo = & $ChapterProvider
            if ($null -eq $chapterInfo) { $providerExhausted = $true; break }
            $chapterKey = $chapterInfo
            # @($null) is a 1-element array containing $null, not an empty
            # array - a $JobBuilder returning $null for "nothing to do" (the
            # documented zero-job-chapter contract every builder is supposed
            # to satisfy with @() instead) would crash on $null.ChapterKey
            # below rather than taking that path. All 3 production builders
            # already return @(), so this only matters for a manually-built
            # feed - explicit $null-to-empty-array normalization either way.
            $rawJobs = & $JobBuilder $chapterInfo
            # Statement-form assignment inside each branch, NOT
            # `$jobs = if (...) { @() } else { @($rawJobs) }` (a separate
            # PowerShell trap from the $null one above: when an if/else block's
            # own tail expression is what's captured by an OUTER
            # assignment, a single Hashtable emitted from inside that
            # block gets enumerated into its individual DictionaryEntry
            # pairs by the outer capture - @()'s usual one-object
            # protection doesn't survive that extra layer. Assigning
            # $jobs directly inside each branch instead of capturing the
            # if/else's own return value avoids the extra layer entirely.
            if ($null -eq $rawJobs) { $jobs = @() } else { $jobs = @($rawJobs) }
            foreach ($j in $jobs) { $j.ChapterKey = $chapterKey; $pending.Enqueue($j) }
            $state = @{ ChapterInfo = $chapterInfo; Outstanding = $jobs.Count; Completed = $false }
            $chapterStates[$chapterKey] = $state
            $activeChapterCount++
            if ($state.Outstanding -le 0) {
                $null = & $ChapterCompleteCallback $chapterInfo
                $state.Completed = $true
                if ($null -ne $ChapterReleaseCheck) { $heldChapters.Add($chapterInfo) } else { $activeChapterCount-- }
                $chapterResults.Add(@{ ChapterInfo = $chapterInfo; Completed = $true; Aborted = $false })
            }
        }

        if ($AbortPollCallback) { $null = & $AbortPollCallback @($running) }

        while ($pending.Count -gt 0 -and (-not $CancelToken.IsCancellationRequested) -and `
               $(if ($isSharedBudget) { $MaxConcurrent.Wait(0) } else { $running.Count -lt $MaxConcurrent })) {
            $job = $pending.Dequeue()
            try {
                $job = & $JobStarter $job
                $running.Add($job)
            } catch {
                # Release BEFORE Write-Log: if Write-Log itself throws (a
                # locked Errors log file), releasing afterwards would leak
                # this job's semaphore slot permanently - it was never added
                # to $running, so the outer
                # catch's own cleanup (which only walks $running) can't
                # find it either. In Full Pipeline the semaphore is SHARED
                # between both engines, so a leak here would have shrunk
                # the surviving engine's own ceiling too.
                if ($isSharedBudget) { $null = $MaxConcurrent.Release() }
                Write-Log ("ChapterDispatch: JobStarter failed to start a job: " + $_) -Level Error
                $dispatchResult.JobStarterFailedCount++
                $key = $job.ChapterKey
                if ($chapterStates.ContainsKey($key)) {
                    $state = $chapterStates[$key]
                    $state.Outstanding--
                    if ($state.Outstanding -le 0 -and -not $state.Completed) {
                        $null = & $ChapterCompleteCallback $state.ChapterInfo
                        $state.Completed = $true
                        $activeChapterCount--
                        $chapterResults.Add(@{ ChapterInfo = $state.ChapterInfo; Completed = $true; Aborted = $false })
                    }
                } else {
                    # Invariant violation - should never
                    # happen (every job's ChapterKey is set from a key this
                    # function itself just registered), but if it ever did,
                    # this chapter's Outstanding count would never reach 0
                    # and the dispatch loop would spin forever with no
                    # error. Log loudly rather than fail silently.
                    Write-Log ("ChapterDispatch: invariant violation - job's ChapterKey is not in `$chapterStates (JobStarter failure path). This should be unreachable; the dispatch loop may now hang.") -Level Error
                }
            }
        }

        # ---- BLOCK: main dispatch loop's poll pass ----
        # Same poll/finalize/completion-callback sequence as the
        # graceful-wait loop and the mandatory final pass below (both in
        # the straggler-drain section further down this function) - keep
        # all three in sync if this one changes.
        $stillRunning = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($job in $running) {
            if (& $JobPollCompleted $job) {
                $result = & $JobFinalize $job $pending
                try { if ($job.Proc) { $job.Proc.Dispose() } } catch { }
                if ($isSharedBudget) { $null = $MaxConcurrent.Release() }
                $job.SlotReleased = $true
                if (-not ($result -and $result.Requeued)) {
                    $key = $job.ChapterKey
                    if ($chapterStates.ContainsKey($key)) {
                        $state = $chapterStates[$key]
                        $state.Outstanding--
                        if ($state.Outstanding -le 0 -and -not $state.Completed) {
                            $null = & $ChapterCompleteCallback $state.ChapterInfo
                            $state.Completed = $true
                            $activeChapterCount--
                            $chapterResults.Add(@{ ChapterInfo = $state.ChapterInfo; Completed = $true; Aborted = $false })
                        }
                    } else {
                        # Invariant violation - see the
                        # JobStarter-failure catch above for the full
                        # explanation. DOCUMENTED DUPLICATE, keep in sync
                        # with the other two copies of this same block.
                        Write-Log ("ChapterDispatch: invariant violation - job's ChapterKey is not in `$chapterStates (main dispatch loop poll pass). This should be unreachable; the dispatch loop may now hang.") -Level Error
                    }
                }
            } else {
                $stillRunning.Add($job)
            }
        }
        $running = $stillRunning

        [System.Threading.Thread]::Sleep(50)
    }
    } catch {
        foreach ($job in $running) {
            try { if ($job.Proc -and -not $job.Proc.HasExited) { $job.Proc.Kill() } } catch { }
            try { if ($job.Proc) { $null = $job.Proc.WaitForExit(5000) } } catch { }
            if (-not $job.SlotReleased) {
                try { $null = & $JobAbortCleanup $job } catch { }
                if ($isSharedBudget) { try { $null = $MaxConcurrent.Release() } catch { } }
            }
            try { if ($job.Proc) { $job.Proc.Dispose() } } catch { }
        }
        throw
    }

    if ($CancelToken.IsCancellationRequested -and $running.Count -gt 0) {
        try {
            $abortDeadline = [System.Diagnostics.Stopwatch]::StartNew()
            while ($running.Count -gt 0 -and -not [ConsoleCtrl]::IsCloseEvent -and $abortDeadline.Elapsed.TotalSeconds -lt $AbortTimeoutSeconds) {
                # ---- BLOCK: graceful-wait loop ----
                # Same poll/finalize/completion-callback sequence as the
                # main dispatch loop's poll pass above and the mandatory
                # final pass just below - keep all three in sync if this
                # one changes.
                $stillWaiting = [System.Collections.Generic.List[hashtable]]::new()
                foreach ($job in $running) {
                    if (& $JobPollCompleted $job) {
                        $result = & $JobFinalize $job $pending
                        try { if ($job.Proc) { $job.Proc.Dispose() } } catch { }
                        if ($isSharedBudget) { $null = $MaxConcurrent.Release() }
                        $job.SlotReleased = $true
                        if (-not ($result -and $result.Requeued)) {
                            $key = $job.ChapterKey
                            if ($chapterStates.ContainsKey($key)) {
                                $state = $chapterStates[$key]
                                $state.Outstanding--
                                if ($state.Outstanding -le 0 -and -not $state.Completed) {
                                    $null = & $ChapterCompleteCallback $state.ChapterInfo
                                    $state.Completed = $true
                                    $activeChapterCount--
                                    $chapterResults.Add(@{ ChapterInfo = $state.ChapterInfo; Completed = $true; Aborted = $false })
                                }
                            } else {
                                # Invariant violation - see
                                # the JobStarter-failure catch earlier in
                                # this function for the full explanation.
                                # DOCUMENTED DUPLICATE, keep in sync with
                                # the other two copies of this same block.
                                Write-Log ("ChapterDispatch: invariant violation - job's ChapterKey is not in `$chapterStates (graceful-wait loop). This should be unreachable; the dispatch loop may now hang.") -Level Error
                            }
                        }
                    } else {
                        $stillWaiting.Add($job)
                    }
                }
                $running = $stillWaiting
                if ($running.Count -gt 0) { [System.Threading.Thread]::Sleep(250) }
            }

            # ---- BLOCK: mandatory final completion-check pass ----
            # [ConsoleCtrl]::IsCloseEvent can exit the while loop above on
            # its very first condition check, before even one poll of
            # $running has happened. Same poll/finalize/completion-callback
            # sequence as the main dispatch loop's poll pass and the
            # graceful-wait loop just above - keep all three in sync if
            # this one changes.
            if ($running.Count -gt 0) {
                $stillWaiting = [System.Collections.Generic.List[hashtable]]::new()
                foreach ($job in $running) {
                    if (& $JobPollCompleted $job) {
                        $result = & $JobFinalize $job $pending
                        try { if ($job.Proc) { $job.Proc.Dispose() } } catch { }
                        if ($isSharedBudget) { $null = $MaxConcurrent.Release() }
                        $job.SlotReleased = $true
                        if (-not ($result -and $result.Requeued)) {
                            $key = $job.ChapterKey
                            if ($chapterStates.ContainsKey($key)) {
                                $state = $chapterStates[$key]
                                $state.Outstanding--
                                if ($state.Outstanding -le 0 -and -not $state.Completed) {
                                    $null = & $ChapterCompleteCallback $state.ChapterInfo
                                    $state.Completed = $true
                                    $activeChapterCount--
                                    $chapterResults.Add(@{ ChapterInfo = $state.ChapterInfo; Completed = $true; Aborted = $false })
                                }
                            } else {
                                # Invariant violation - see
                                # the JobStarter-failure catch earlier in
                                # this function for the full explanation.
                                # DOCUMENTED DUPLICATE, keep in sync with
                                # the other two copies of this same block.
                                Write-Log ("ChapterDispatch: invariant violation - job's ChapterKey is not in `$chapterStates (mandatory final completion-check pass). This should be unreachable; the dispatch loop may now hang.") -Level Error
                            }
                        }
                    } else {
                        $stillWaiting.Add($job)
                    }
                }
                $running = $stillWaiting
            }

            if ($running.Count -gt 0) {
                $dispatchResult.ForceKilledCount = $running.Count
                Write-Log ("ChapterDispatch: force-stopping " + $running.Count + " job(s) that did not finish within " + $AbortTimeoutSeconds + "s.") -Level Warn
                foreach ($job in $running) {
                    try { if ($job.Proc -and -not $job.Proc.HasExited) { $job.Proc.Kill() } } catch { }
                    try { if ($job.Proc) { $null = $job.Proc.WaitForExit(5000) } } catch { }
                    try { $null = & $JobAbortCleanup $job } catch { }
                    try { if ($job.Proc) { $job.Proc.Dispose() } } catch { }
                    if ($isSharedBudget) { try { $null = $MaxConcurrent.Release() } catch { } }
                    $job.SlotReleased = $true
                }
            }
        } catch {
            foreach ($job in $running) {
                try { if ($job.Proc -and -not $job.Proc.HasExited) { $job.Proc.Kill() } } catch { }
                try { if ($job.Proc) { $null = $job.Proc.WaitForExit(5000) } } catch { }
                if (-not $job.SlotReleased) {
                    try { $null = & $JobAbortCleanup $job } catch { }
                    if ($isSharedBudget) { try { $null = $MaxConcurrent.Release() } catch { } }
                }
                try { if ($job.Proc) { $job.Proc.Dispose() } } catch { }
            }
            throw
        }
    }

    # A chapter's jobs still sitting in $pending when the loop above exits
    # (only reachable via cancellation - the outer while loop otherwise
    # keeps running until $pending drains) were never started, so
    # $JobStarter's own try/catch and the running-job force-stop block
    # below never see them - nothing decrements their chapter's
    # Outstanding or calls $JobAbortCleanup on them. Left unhandled, a
    # chapter with any never-started job can never reach Outstanding=0,
    # so it silently never completes at all (the never-started sibling of
    # the force-killed-chapter case). Treat them the same as a force-killed running job: cleanup,
    # decrement, let the loop below credit whatever real work the
    # chapter's OTHER jobs already finished.
    if ($pending.Count -gt 0) {
        foreach ($job in $pending) {
            try { $null = & $JobAbortCleanup $job } catch { }
            $key = $job.ChapterKey
            if ($chapterStates.ContainsKey($key)) { $chapterStates[$key].Outstanding-- }
        }
        $pending.Clear()
    }

    $dispatchResult.Aborted = $CancelToken.IsCancellationRequested
    foreach ($state in $chapterStates.Values) {
        if (-not $state.Completed) {
            # A chapter that was force-killed or aborted mid-flight still
            # needs $ChapterCompleteCallback invoked - it's the only thing
            # that merges this chapter's real, already-finished work (jobs
            # that completed via $JobFinalize before the kill) into the
            # caller's totals. Skipping it here would mean a chapter that converted+deleted N files
            # before being force-killed contributed ZERO to the run
            # summary, even though those N files are correctly on disk.
            # Wrapped in try/catch: this function is already in its own
            # cleanup/finalization phase, and a callback failure here
            # shouldn't prevent returning a result for every other
            # chapter.
            try { $null = & $ChapterCompleteCallback $state.ChapterInfo } catch { }
            $state.Completed = $true
            $chapterResults.Add(@{ ChapterInfo = $state.ChapterInfo; Completed = $false; Aborted = $true })
        }
    }

    return $dispatchResult
}

function Initialize-ChildProcessReadThreadPool {
    param([int]$MaxConcurrentProcesses = 0)
    $clampedProcs = [Math]::Min([Math]::Max($MaxConcurrentProcesses, 0), 16000)
    $MinimumWorkerThreads = [Math]::Max(128, (2 * $clampedProcs) + 32)
    $worker = 0; $io = 0
    [System.Threading.ThreadPool]::GetMinThreads([ref]$worker, [ref]$io)
    if ($worker -ge $MinimumWorkerThreads) { return $true }
    return [System.Threading.ThreadPool]::SetMinThreads($MinimumWorkerThreads, $io)
}

function Get-ChapterDispatchSharedFunctionNames {
    return @('New-LibraryChapterProvider', 'Invoke-ChapterDispatch')
}
