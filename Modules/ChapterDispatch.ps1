<#
.SYNOPSIS
    ChapterDispatch - New-LibraryChapterProvider (flattens
    New-SeriesProvider + Get-SeriesChapters into one continuous lazy
    chapter feed) and Invoke-ChapterDispatch (the generalized process-
    dispatch/abort/drain loop, extracted from Convert-ImageBatch's own
    $pending/$running/SemaphoreSlim engine and generalized to span
    multiple chapters instead of one chapter's file list). See
    Docs\dispatch-redesign-design.md for the full design and reasoning -
    this module implements that doc's "New module: ChapterDispatch.ps1"
    section as written, filling in only the details that doc left open
    (documented inline below, at each such point).

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules.

    STANDALONE PRIMITIVE, NOT YET WIRED IN (2026-09-09): built and fully
    harness-tested per the dispatch-redesign design doc's own migration
    order (step 1 of 4 - "Build ChapterDispatch.ps1 standalone, fully
    tested against fakes - no real caller touches it yet"). Nothing in
    Controller.ps1/ImageConversionPipeline.ps1/AnimatedConversionPipeline.ps1
    calls this yet, and Conversion Script Main.ps1 does not dot-source it
    yet either. Intended load position once wired in: right after
    LeafDirectoryDiscovery.ps1, before ZipParallelProcessing.ps1/
    ZipPipeline.ps1/ImageConversionPipeline.ps1/
    AnimatedConversionPipeline.ps1/Controller.ps1 - see that script's own
    dot-source order.

    FORWARD REFERENCES: Write-Log (Logging.ps1), [ConsoleCtrl]
    (AbortPipeline.ps1, a compiled type - visible from a runspace worker
    without -SharedFunctionNames propagation, same as every other module
    that already uses it, e.g. ImageConversionPipeline.ps1's own straggler
    drain). Not defined here - this module's own harness stubs Write-Log
    and dot-sources AbortPipeline.ps1 for the real [ConsoleCtrl] type,
    matching ImageConversionPipeline.Harness.ps1's own convention.

    DOMAIN-AGNOSTIC BY DESIGN: this module never spawns a process itself
    and never knows what a "job" actually does - JobBuilder/JobStarter/
    JobPollCompleted/JobFinalize/JobAbortCleanup (all caller-supplied
    scriptblocks) own every piece of real domain logic (cjxl vs magick,
    AVIF/WebP classification, source deletion, temp-file cleanup) exactly
    where it already lives. What THIS module owns generically (extracted
    from Convert-ImageBatch's real code, not reinvented - see that
    function's own comments for the live-bug history behind each piece):
      - The abort/drain TIMING sequence: [ConsoleCtrl]::IsCloseEvent fast
        path (a window-close force-kills the whole process in ~5s
        regardless, so waiting out any part of -AbortTimeoutSeconds there
        is pointless), a 250ms poll interval during the drain wait, and a
        mandatory FINAL completion-check pass immediately before force-
        killing anything (a job that finished in the last few
        milliseconds must not have its real, valid output torn down by
        JobAbortCleanup as if it were a killed process's garbage - a
        real, live-caught bug class in the original code).
      - Releasing exactly one -MaxConcurrent slot (when it's a
        SemaphoreSlim - see JOB CONTRACT below) per job on every exit
        path a job can take (normal finalize, Requeued finalize,
        JobStarter throwing, force-kill) - guarded by a per-job
        SlotReleased marker so a job already finalized earlier in the
        same poll pass can't have its slot released (or its
        JobAbortCleanup run) a second time by a later job's throw -
        mirrors Convert-ImageBatch's own SlotReleased invariant exactly.
      - Killing/waiting/disposing a job's own .Proc (see JOB CONTRACT)
        when it's still running at force-kill time.

    JOB CONTRACT: every job is a [hashtable]. This module tags each job
    with its own .ChapterKey (added internally, right after JobBuilder
    returns - JobBuilder itself never sets it) - the exact chapterInfo
    value that chapter's own -ChapterProvider call returned, not a
    derived path string, compared using .NET's default equality for
    whatever type chapterInfo actually is (reference equality for a
    hashtable - the normal case, since a real chapterInfo is always the
    SAME instance from -ChapterProvider through to
    -ChapterCompleteCallback - or value equality for something like a
    plain string, the common shape in this module's own harness). This is
    what makes Invoke-ChapterDispatch domain-agnostic about chapter
    identity too, not just job identity - it never needs to know chapters
    have a ".Dir.FullName" or any other specific shape at all.
    JobFinalize's -PendingQueue contract (below) MUST copy the original
    job's .ChapterKey onto any newly-enqueued retry job itself, since this
    module has no other way to know a requeued job belongs to the same
    chapter as the job that requeued it. JobStarter is expected to set a
    .Proc property (a System.Diagnostics.Process) on the job it returns -
    this module's own generic Kill()/WaitForExit()/Dispose() calls on
    force-kill, and its Dispose() call after every normal JobFinalize,
    are all .Proc-nullchecked, so a caller whose job represents no real
    OS process at all (or a harness fake) can safely leave .Proc $null to
    opt out of that machinery - JobPollCompleted then owns deciding
    "done" some other way (e.g. its own flag on the job hashtable).

    CHAPTER COMPLETION: JobBuilder is called exactly once per chapter, up
    front, returning that chapter's FULL job list at once (confirmed
    correct against Convert-ImageBatch's own naming-collision pre-pass,
    which needs a whole chapter's file list to detect a collision - see
    the design doc's "Extraction findings"). ChapterCompleteCallback
    fires exactly once per chapter, the moment every one of its jobs has
    reached a non-Requeued JobFinalize outcome (a zero-job chapter
    completes immediately, before any job ever dispatches) - never for a
    chapter still holding an outstanding job when the run is cancelled or
    force-killed. The design doc left the OUTPUTS' ChapterResults shape
    unspecified beyond its name - this implementation returns one entry
    per chapter JobBuilder was ever called for:
    @{ ChapterInfo; Completed = [bool]; Aborted = [bool] } - Completed
    mirrors whether ChapterCompleteCallback actually fired for it; Aborted
    is true only for a chapter still incomplete when this function
    returns (always the mirror image of Completed in practice, kept as
    its own field so a caller doesn't have to infer it).

    Two other choices this implementation made that the design doc left
    open: a JobStarter that throws is counted into a new
    JobStarterFailedCount output field (mirroring ForceKilledCount's
    shape) rather than silently folded into anything else - "counted,
    budget released, loop continues" per the design doc's own wording,
    just needed a place to land; and -AbortPollCallback receives the raw
    $running job list (not a projected field like Convert-ImageBatch's
    own SrcPath-only array) since a generic job hashtable has no
    guaranteed field name for the caller to want.
#>

function New-LibraryChapterProvider {
    <#
    .SYNOPSIS
        Flattens New-SeriesProvider (lazy, one series at a time) +
        Get-SeriesChapters (eager, per series) - both unchanged - into
        one continuous lazy chapter feed, so Invoke-ChapterDispatch's
        caller doesn't need to nest two loops itself. Same two-tier walk
        as today (lazy across series, eager within one series) - see
        Docs\dispatch-redesign-design.md's "Decisions already made" #3.
    .OUTPUTS
        [scriptblock] - call repeatedly; each call returns the next
        chapter as @{ SeriesName; ChapterName; Dir; ZipOut }, or $null
        once the whole library is exhausted.
    #>
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
    $seriesExhausted = $false

    return {
        while ($chapterQueue.Count -eq 0 -and -not $seriesExhausted) {
            $series = & $seriesProvider
            if ($null -eq $series) { $seriesExhausted = $true; break }
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
    <#
    .SYNOPSIS
        The generalized drain loop - see this module's own header for the
        full design. Pulls chapters from -ChapterProvider (bounded by
        -MaxQueueAhead), builds each chapter's job list via -JobBuilder,
        dispatches jobs up to -MaxConcurrent (a private [int] ceiling or a
        shared [SemaphoreSlim]) via -JobStarter, polls them via
        -JobPollCompleted, finalizes each via -JobFinalize, and fires
        -ChapterCompleteCallback once per chapter once all its jobs are
        done. On cancellation, drains gracefully up to -AbortTimeoutSeconds
        (skipped entirely on a window-close event, which force-kills the
        whole process in ~5s regardless) then force-kills anything left,
        running -JobAbortCleanup on each.
    .OUTPUTS
        @{ ChapterResults = List[hashtable]; Aborted = [bool];
           ForceKilledCount = [int]; JobStarterFailedCount = [int] } -
        see this module's own header for ChapterResults' shape and the
        two output fields the design doc itself didn't specify.
    #>
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

    # Dictionary[object,hashtable], not [string,hashtable] - a chapter's
    # own KEY is the chapterInfo value itself (see this module's header,
    # JOB CONTRACT), not a derived path string. This is what makes
    # Invoke-ChapterDispatch domain-agnostic about chapter identity too,
    # not just job identity: a real caller's chapterInfo is always the
    # SAME hashtable instance from -ChapterProvider through to
    # -ChapterCompleteCallback, so .NET's default reference equality is
    # exactly right (two hashtables with identical content are never the
    # same chapter unless they're the same instance); a test harness
    # using a plain string chapterInfo gets correct value equality for
    # free from the same default.
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

    # Same reasoning as Convert-ImageBatch's own outer try/catch (see that
    # function's header): an unexpected throw from inside this loop
    # (a callback, or Write-Log on a locked file) must not leak every
    # running job's process handle and -MaxConcurrent slot.
    try {
    while ((-not $CancelToken.IsCancellationRequested) -and `
           (-not $providerExhausted -or $activeChapterCount -gt 0 -or $pending.Count -gt 0 -or $running.Count -gt 0)) {

        # Pull ahead up to -MaxQueueAhead chapters - bounds memory on a
        # huge library instead of enumerating everything upfront (see
        # this module's own header / the design doc's own reasoning for
        # -MaxQueueAhead).
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

        # Fill up to -MaxConcurrent slots - Wait(0) is a non-blocking
        # try-acquire (grabs a slot and returns true, or returns false
        # immediately without consuming one), same as Convert-ImageBatch's
        # own -SharedBudget handling, so this loop never stalls waiting on
        # a slot another concurrent caller is holding.
        while ($pending.Count -gt 0 -and (-not $CancelToken.IsCancellationRequested) -and `
               $(if ($isSharedBudget) { $MaxConcurrent.Wait(0) } else { $running.Count -lt $MaxConcurrent })) {
            $job = $pending.Dequeue()
            try {
                $job = & $JobStarter $job
                $running.Add($job)
            } catch {
                Write-Log ("ChapterDispatch: JobStarter failed to start a job: " + $_) -Level Error
                $dispatchResult.JobStarterFailedCount++
                if ($isSharedBudget) { $MaxConcurrent.Release() | Out-Null }
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

        # Poll for finished jobs.
        $stillRunning = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($job in $running) {
            if (& $JobPollCompleted $job) {
                $result = & $JobFinalize $job $pending
                # Generic cleanup, every exit path (2026-09-09 design -
                # moved OUT of JobFinalize, unlike the original
                # Complete-ImageConversionJob, which did this inline -
                # see this module's own header).
                try { if ($job.Proc) { $job.Proc.Dispose() } } catch { }
                if ($isSharedBudget) { $MaxConcurrent.Release() | Out-Null }
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

        Start-Sleep -Milliseconds 50
    }
    } catch {
        foreach ($job in $running) {
            try { if ($job.Proc -and -not $job.Proc.HasExited) { $job.Proc.Kill() } } catch { }
            try { if ($job.Proc) { $job.Proc.WaitForExit(5000) } } catch { }
            if (-not $job.SlotReleased) {
                try { & $JobAbortCleanup $job } catch { }
                if ($isSharedBudget) { try { $MaxConcurrent.Release() | Out-Null } catch { } }
            }
            try { if ($job.Proc) { $job.Proc.Dispose() } } catch { }
        }
        throw
    }

    # ------------------------------------------------------------------
    #  Stragglers: same shape as Convert-ImageBatch's own straggler drain
    #  (see this module's header) - graceful wait up to
    #  -AbortTimeoutSeconds (skipped on a window-close event), a mandatory
    #  final completion-check pass, then force-kill anything left.
    # ------------------------------------------------------------------
    if ($CancelToken.IsCancellationRequested -and $running.Count -gt 0) {
        try {
            $abortDeadline = [System.Diagnostics.Stopwatch]::StartNew()
            while ($running.Count -gt 0 -and -not [ConsoleCtrl]::IsCloseEvent -and $abortDeadline.Elapsed.TotalSeconds -lt $AbortTimeoutSeconds) {
                $stillWaiting = [System.Collections.Generic.List[hashtable]]::new()
                foreach ($job in $running) {
                    if (& $JobPollCompleted $job) {
                        $result = & $JobFinalize $job $pending
                        try { if ($job.Proc) { $job.Proc.Dispose() } } catch { }
                        if ($isSharedBudget) { $MaxConcurrent.Release() | Out-Null }
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
                if ($running.Count -gt 0) { Start-Sleep -Milliseconds 250 }
            }

            # Mandatory final completion-check pass (see this module's own
            # header) - [ConsoleCtrl]::IsCloseEvent can exit the while loop
            # above on its very first condition check, before even one
            # poll of $running has happened.
            if ($running.Count -gt 0) {
                $stillWaiting = [System.Collections.Generic.List[hashtable]]::new()
                foreach ($job in $running) {
                    if (& $JobPollCompleted $job) {
                        $result = & $JobFinalize $job $pending
                        try { if ($job.Proc) { $job.Proc.Dispose() } } catch { }
                        if ($isSharedBudget) { $MaxConcurrent.Release() | Out-Null }
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
                    if ($isSharedBudget) { try { $MaxConcurrent.Release() | Out-Null } catch { } }
                    $job.SlotReleased = $true
                }
            }
        } catch {
            foreach ($job in $running) {
                try { if ($job.Proc -and -not $job.Proc.HasExited) { $job.Proc.Kill() } } catch { }
                try { if ($job.Proc) { $job.Proc.WaitForExit(5000) } } catch { }
                if (-not $job.SlotReleased) {
                    try { & $JobAbortCleanup $job } catch { }
                    if ($isSharedBudget) { try { $MaxConcurrent.Release() | Out-Null } catch { } }
                }
                try { if ($job.Proc) { $job.Proc.Dispose() } } catch { }
            }
            throw
        }
    }

    $dispatchResult.Aborted = $CancelToken.IsCancellationRequested
    foreach ($state in $chapterStates.Values) {
        if (-not $state.Completed) {
            $chapterResults.Add(@{ ChapterInfo = $state.ChapterInfo; Completed = $false; Aborted = $true })
        }
    }

    return $dispatchResult
}

function Get-ChapterDispatchSharedFunctionNames {
    <#
    .SYNOPSIS
        Single source of truth for this module's own propagatable
        function names, for a future -SharedFunctionNames caller running
        Invoke-ChapterDispatch inside a runspace worker (Full Pipeline's
        two-concurrent-engine case - see the design doc's "Full
        Pipeline's two-engine problem"). Not used by anything yet, same
        as the rest of this module - added now so a future consumer has
        one place to pull from, per this project's own established
        convention (CLAUDE.md's "-SharedFunctionNames: single source of
        truth per group").
    #>
    return @('New-LibraryChapterProvider', 'Invoke-ChapterDispatch')
}
