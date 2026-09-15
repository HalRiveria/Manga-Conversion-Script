# See Docs/module-descriptions.md for this module's full description.

function New-LibraryChapterProvider {
    param(
        [Parameter(Mandatory)]
        [string]$LibraryPath,
        [Parameter(Mandatory)]
        [string[]]$QualifyingExtensions,
        [System.Collections.Generic.HashSet[string]]$ExcludeStagingDirs = $null,
        [bool]$ForceRezip = $false
    )
    $seriesProvider = New-SeriesProvider -LibraryPath $LibraryPath
    $chapterQueue   = [System.Collections.Generic.Queue[hashtable]]::new()
    # Hashtable, not a plain scalar (2026-09-14 fix, Todo.md finding) - a
    # plain $seriesExhausted assigned inside this .GetNewClosure()'d
    # scriptblock resets to $false on every invocation instead of
    # latching, confirmed live. Currently harmless here (the caller stops
    # polling once this returns $null anyway), but it read as working
    # protection that wasn't. Matches LeafDirectoryDiscovery.ps1's
    # New-ZippableLeafDirProvider, which uses the same pattern for the
    # same reason.
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
        [int]$MaxQueueAhead = 3
    )

    $isSharedBudget = ($MaxConcurrent -is [System.Threading.SemaphoreSlim])

    $chapterStates      = [System.Collections.Generic.Dictionary[object,hashtable]]::new()
    $chapterResults     = [System.Collections.Generic.List[hashtable]]::new()
    $activeChapterCount = 0
    $providerExhausted  = $false

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

        while ((-not $providerExhausted) -and $activeChapterCount -lt $MaxQueueAhead -and (-not $CancelToken.IsCancellationRequested)) {
            $chapterInfo = & $ChapterProvider
            if ($null -eq $chapterInfo) { $providerExhausted = $true; break }
            $chapterKey = $chapterInfo
            $jobs = @(& $JobBuilder $chapterInfo)
            foreach ($j in $jobs) { $j.ChapterKey = $chapterKey; $pending.Enqueue($j) }
            $state = @{ ChapterInfo = $chapterInfo; Outstanding = $jobs.Count; Completed = $false }
            $chapterStates[$chapterKey] = $state
            $activeChapterCount++
            if ($state.Outstanding -le 0) {
                & $ChapterCompleteCallback $chapterInfo
                $state.Completed = $true
                $activeChapterCount--
                $chapterResults.Add(@{ ChapterInfo = $chapterInfo; Completed = $true; Aborted = $false })
            }
        }

        if ($AbortPollCallback) { & $AbortPollCallback @($running) }

        while ($pending.Count -gt 0 -and (-not $CancelToken.IsCancellationRequested) -and `
               $(if ($isSharedBudget) { $MaxConcurrent.Wait(0) } else { $running.Count -lt $MaxConcurrent })) {
            $job = $pending.Dequeue()
            try {
                $job = & $JobStarter $job
                $running.Add($job)
            } catch {
                Write-Log ("ChapterDispatch: JobStarter failed to start a job: " + $_) -Level Error
                $dispatchResult.JobStarterFailedCount++
                if ($isSharedBudget) { $null = $MaxConcurrent.Release() }
                $key = $job.ChapterKey
                if ($chapterStates.ContainsKey($key)) {
                    $state = $chapterStates[$key]
                    $state.Outstanding--
                    if ($state.Outstanding -le 0 -and -not $state.Completed) {
                        & $ChapterCompleteCallback $state.ChapterInfo
                        $state.Completed = $true
                        $activeChapterCount--
                        $chapterResults.Add(@{ ChapterInfo = $state.ChapterInfo; Completed = $true; Aborted = $false })
                    }
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
                            & $ChapterCompleteCallback $state.ChapterInfo
                            $state.Completed = $true
                            $activeChapterCount--
                            $chapterResults.Add(@{ ChapterInfo = $state.ChapterInfo; Completed = $true; Aborted = $false })
                        }
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
            try { if ($job.Proc) { $job.Proc.WaitForExit(5000) } } catch { }
            if (-not $job.SlotReleased) {
                try { & $JobAbortCleanup $job } catch { }
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
                                    & $ChapterCompleteCallback $state.ChapterInfo
                                    $state.Completed = $true
                                    $activeChapterCount--
                                    $chapterResults.Add(@{ ChapterInfo = $state.ChapterInfo; Completed = $true; Aborted = $false })
                                }
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
                                    & $ChapterCompleteCallback $state.ChapterInfo
                                    $state.Completed = $true
                                    $activeChapterCount--
                                    $chapterResults.Add(@{ ChapterInfo = $state.ChapterInfo; Completed = $true; Aborted = $false })
                                }
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
                    try { if ($job.Proc) { $job.Proc.WaitForExit(5000) } } catch { }
                    try { & $JobAbortCleanup $job } catch { }
                    try { if ($job.Proc) { $job.Proc.Dispose() } } catch { }
                    if ($isSharedBudget) { try { $null = $MaxConcurrent.Release() } catch { } }
                    $job.SlotReleased = $true
                }
            }
        } catch {
            foreach ($job in $running) {
                try { if ($job.Proc -and -not $job.Proc.HasExited) { $job.Proc.Kill() } } catch { }
                try { if ($job.Proc) { $job.Proc.WaitForExit(5000) } } catch { }
                if (-not $job.SlotReleased) {
                    try { & $JobAbortCleanup $job } catch { }
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
    # so it silently never completes at all (2026-09-15 finding - the
    # force-killed-chapter-undercounts-totals bug's own untested sibling
    # case). Treat them the same as a force-killed running job: cleanup,
    # decrement, let the loop below credit whatever real work the
    # chapter's OTHER jobs already finished.
    if ($pending.Count -gt 0) {
        foreach ($job in $pending) {
            try { & $JobAbortCleanup $job } catch { }
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
            # caller's totals. Skipping it here (the pre-2026-09-15
            # behavior) meant a chapter that converted+deleted N files
            # before being force-killed contributed ZERO to the run
            # summary, even though those N files are correctly on disk.
            # Wrapped in try/catch: this function is already in its own
            # cleanup/finalization phase, and a callback failure here
            # shouldn't prevent returning a result for every other
            # chapter.
            try { & $ChapterCompleteCallback $state.ChapterInfo } catch { }
            $state.Completed = $true
            $chapterResults.Add(@{ ChapterInfo = $state.ChapterInfo; Completed = $false; Aborted = $true })
        }
    }

    return $dispatchResult
}

function Get-ChapterDispatchSharedFunctionNames {
    return @('New-LibraryChapterProvider', 'Invoke-ChapterDispatch')
}
