<#
.SYNOPSIS
    Standalone test harness for Modules\ChapterDispatch.ps1.

.DESCRIPTION
    No compiled fake cjxl.exe/magick.exe needed here (unlike
    ImageConversionPipeline.Harness.ps1/AnimatedConversionPipeline.Harness.ps1) -
    Invoke-ChapterDispatch never spawns a process itself, it only calls
    JobStarter/JobPollCompleted/JobFinalize/JobAbortCleanup scriptblocks
    this harness fully controls. Fake jobs are plain hashtables with
    .Proc left $null (a valid, documented job shape per the module's own
    JOB CONTRACT) and a test-flippable "done" flag JobPollCompleted reads -
    cheaper and faster than every other harness in this project.

    Scenarios follow Docs\dispatch-redesign-design.md's own "Harness
    strategy" list (numbered to match that doc), plus one additional
    scenario (P) covering New-LibraryChapterProvider against a real
    folder structure - the design doc's numbered list is entirely about
    Invoke-ChapterDispatch.

    Stubs Write-Log (this module's only cross-module forward reference
    besides the compiled [ConsoleCtrl] type, which is dot-sourced for
    real from AbortPipeline.ps1 - matching
    ImageConversionPipeline.Harness.ps1's own convention for the identical
    dependency).

.EXAMPLE
    .\Modules\_Harness\ChapterDispatch.Harness.ps1
#>

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    # Silent stub - this harness only cares about Invoke-ChapterDispatch's
    # own control flow, not real logging output.
}

. (Join-Path $PSScriptRoot "..\AbortPipeline.ps1")
. (Join-Path $PSScriptRoot "..\LeafDirectoryDiscovery.ps1")
. (Join-Path $PSScriptRoot "..\ChapterDispatch.ps1")

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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("chapterdispatch-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray
Write-Host ""

function New-FakeJob {
    <#
    .SYNOPSIS
        A minimal fake job: .Proc stays $null throughout (this harness
        never needs a real process - see this file's own header), .Done
        is the flag a scenario's own JobPollCompleted reads.
    #>
    param([string]$Id, [string]$ChapterKeyHint = $null)
    return @{ Id = $Id; Proc = $null; Done = $false; Started = $false; StartCount = 0 }
}

# Default callback set - most scenarios override one or two of these.
function New-DefaultCallbacks {
    param([System.Collections.Generic.List[string]]$EventLog = $null)
    $jobStarter = {
        param($job)
        $job.Started = $true
        return $job
    }
    $jobPollCompleted = { param($job) return [bool]$job.Done }
    $jobFinalize = {
        param($job, $pendingQueue)
        return @{ Success = $true }
    }
    $jobAbortCleanup = { param($job) }
    return @{ JobStarter = $jobStarter; JobPollCompleted = $jobPollCompleted; JobFinalize = $jobFinalize; JobAbortCleanup = $jobAbortCleanup }
}

function New-ManualChapterFeed {
    <#
    .SYNOPSIS
        Test helper - returns a matched @{ ChapterProvider; JobBuilder }
        pair backed by a shared queue/map of pre-built chapter
        descriptors. Not New-LibraryChapterProvider (that gets its own
        dedicated scenario, P, against a real folder) - most scenarios
        below are testing Invoke-ChapterDispatch in isolation and don't
        need real filesystem discovery.

        Both scriptblocks are built here, in THIS function's own local
        scope, and captured via .GetNewClosure() so $queue/$jobMap
        survive after this function returns (same reasoning as
        LeafDirectoryDiscovery.ps1's own New-SeriesProvider) - deliberately
        NOT $script: variables. A $script:-prefixed variable read/written
        from inside a .GetNewClosure()'d scriptblock resolves against that
        closure's own private, isolated scope, not the real script scope -
        confirmed live while building this harness (a real instance of
        this project's own documented "closures that lose mutated state"
        lesson, CLAUDE.md's "Lessons learned") - local-variable capture
        (a hashtable/queue, both reference types) is the correct pattern
        here, matching every other scriptblock-returning function in this
        codebase.
    .PARAMETER Chapters
        Array of @{ ChapterInfo = <anything>; Jobs = [hashtable[]] }.
    #>
    param([array]$Chapters)
    $queue  = [System.Collections.Generic.Queue[hashtable]]::new()
    foreach ($c in $Chapters) { $queue.Enqueue($c) }
    $jobMap = @{}
    $provider = {
        if ($queue.Count -eq 0) { return $null }
        $next = $queue.Dequeue()
        $jobMap[$next.ChapterInfo] = $next.Jobs
        return $next.ChapterInfo
    }.GetNewClosure()
    $builder = { param($chapterInfo) return $jobMap[$chapterInfo] }.GetNewClosure()
    return @{ ChapterProvider = $provider; JobBuilder = $builder }
}

# ==============================================================================
#  Scenario 1: single chapter drains correctly end to end (baseline).
# ==============================================================================
Write-Host "=== Scenario 1: single chapter drains correctly end to end ===" -ForegroundColor Cyan
$job1a = New-FakeJob -Id "1a"
$job1b = New-FakeJob -Id "1b"
$job1c = New-FakeJob -Id "1c"
$chapter1 = "Chapter1"
$feed1 = New-ManualChapterFeed -Chapters @(@{ ChapterInfo = $chapter1; Jobs = @($job1a, $job1b, $job1c) })
$cb1 = New-DefaultCallbacks
$completedChapters1 = [System.Collections.Generic.List[object]]::new()
$chapterCompleteCallback1 = { param($chapterInfo) $completedChapters1.Add($chapterInfo) }.GetNewClosure()
$jobPollCompleted1 = {
    param($job)
    if (-not $job.Started) { return $false }
    $job.Done = $true
    return $true
}
$cts1 = [System.Threading.CancellationTokenSource]::new()
$result1 = Invoke-ChapterDispatch -ChapterProvider $feed1.ChapterProvider -JobBuilder $feed1.JobBuilder `
    -JobStarter $cb1.JobStarter -JobPollCompleted $jobPollCompleted1 -JobFinalize $cb1.JobFinalize `
    -JobAbortCleanup $cb1.JobAbortCleanup -ChapterCompleteCallback $chapterCompleteCallback1 `
    -MaxConcurrent 4 -CancelToken $cts1.Token

Test-Assert ($completedChapters1.Count -eq 1 -and $completedChapters1[0] -eq $chapter1) "ChapterCompleteCallback fired exactly once, for the right chapter"
Test-Assert ($job1a.Started -and $job1b.Started -and $job1c.Started) "all three jobs were started"
Test-Assert ($result1.ChapterResults.Count -eq 1 -and $result1.ChapterResults[0].Completed -eq $true -and $result1.ChapterResults[0].Aborted -eq $false) "ChapterResults reports one completed, non-aborted entry"
Test-Assert (-not $result1.Aborted -and $result1.ForceKilledCount -eq 0) "run was not aborted, nothing force-killed"
Write-Host ""

# ==============================================================================
#  Scenario 2 (2026-09-09 - THE point of the whole redesign, tested
#  directly): an idle slot from one chapter picks up ANOTHER chapter's job
#  before the first chapter has fully finished - not after. Chapter A gets
#  a fast job and a slow job; Chapter B gets one fast job. With
#  -MaxConcurrent 2, A's two jobs fill both slots first; the instant A's
#  fast job finishes, B's job must start immediately, WHILE A's slow job
#  is still running - not wait for A to complete first.
# ==============================================================================
Write-Host "=== Scenario 2: an idle slot picks up the NEXT chapter's job while the current chapter still has work outstanding ===" -ForegroundColor Cyan
$eventLog2 = [System.Collections.Generic.List[string]]::new()
$jobAFast = New-FakeJob -Id "A-fast"
$jobASlow = New-FakeJob -Id "A-slow"
$jobBFast = New-FakeJob -Id "B-fast"
$feed2 = New-ManualChapterFeed -Chapters @(
    @{ ChapterInfo = "A"; Jobs = @($jobAFast, $jobASlow) },
    @{ ChapterInfo = "B"; Jobs = @($jobBFast) }
)
$jobStarter2 = { param($job) $job.Started = $true; $eventLog2.Add("start:" + $job.Id); return $job }.GetNewClosure()
$jobPollCompleted2 = {
    param($job)
    if (-not $job.Started) { return $false }
    if ($job.Id -eq "A-slow") {
        $job.StartCount++
        return ($job.StartCount -ge 4)   # takes a few poll passes to finish
    }
    $job.Done = $true
    return $true
}
$jobFinalize2 = { param($job, $pendingQueue) $eventLog2.Add("finalize:" + $job.Id); return @{ Success = $true } }.GetNewClosure()
$chapterCompleteCallback2 = { param($chapterInfo) $eventLog2.Add("chapterComplete:" + $chapterInfo) }.GetNewClosure()
$cts2 = [System.Threading.CancellationTokenSource]::new()
$result2 = Invoke-ChapterDispatch -ChapterProvider $feed2.ChapterProvider -JobBuilder $feed2.JobBuilder `
    -JobStarter $jobStarter2 -JobPollCompleted $jobPollCompleted2 -JobFinalize $jobFinalize2 `
    -JobAbortCleanup { param($job) } -ChapterCompleteCallback $chapterCompleteCallback2 `
    -MaxConcurrent 2 -MaxQueueAhead 2 -CancelToken $cts2.Token

$idxBStart    = $eventLog2.IndexOf("start:B-fast")
$idxASlowDone = $eventLog2.IndexOf("finalize:A-slow")
Test-Assert ($idxBStart -ge 0 -and $idxASlowDone -ge 0 -and $idxBStart -lt $idxASlowDone) ("chapter B's job started BEFORE chapter A's slow job finished - real interleaving, not one-chapter-at-a-time (event log: " + ($eventLog2 -join " -> ") + ")")
Write-Host ""

# ==============================================================================
#  Scenario 3: -MaxQueueAhead bounds how far ahead -ChapterProvider gets
#  pulled - proves the walk-ahead behavior doesn't silently become a full
#  upfront enumeration. Five chapters; chapter 1's one job stays
#  outstanding for several poll passes while chapters 2-5 each have one
#  instant-complete job. At every point chapter 1's job is polled, the
#  number of chapters PULLED-BUT-NOT-YET-COMPLETE must never exceed
#  -MaxQueueAhead (2).
# ==============================================================================
Write-Host "=== Scenario 3: -MaxQueueAhead bounds the walk-ahead ===" -ForegroundColor Cyan
$script:providerPullCount3    = 0
$script:completedChapterCount3 = 0
$script:observedActive3       = [System.Collections.Generic.List[int]]::new()
$chapterDescs3 = @(1..5 | ForEach-Object {
    $n = $_
    $job = New-FakeJob -Id ("C" + $n)
    @{ ChapterInfo = "Chapter" + $n; Jobs = @($job) }
})
$queue3 = [System.Collections.Generic.Queue[hashtable]]::new()
foreach ($c in $chapterDescs3) { $queue3.Enqueue($c) }
$jobMap3 = @{}
$provider3 = {
    if ($queue3.Count -eq 0) { return $null }
    $next = $queue3.Dequeue()
    $jobMap3[$next.ChapterInfo] = $next.Jobs
    $script:providerPullCount3++
    return $next.ChapterInfo
}
$jobBuilder3 = { param($chapterInfo) return $jobMap3[$chapterInfo] }
$jobStarter3 = { param($job) $job.Started = $true; return $job }
$jobPollCompleted3 = {
    param($job)
    if (-not $job.Started) { return $false }
    if ($job.Id -eq "C1") {
        $job.StartCount++
        $active = $script:providerPullCount3 - $script:completedChapterCount3
        $script:observedActive3.Add($active)
        return ($job.StartCount -ge 5)
    }
    $job.Done = $true
    return $true
}
$chapterCompleteCallback3 = { param($chapterInfo) $script:completedChapterCount3++ }
$cts3 = [System.Threading.CancellationTokenSource]::new()
$result3 = Invoke-ChapterDispatch -ChapterProvider $provider3 -JobBuilder $jobBuilder3 `
    -JobStarter $jobStarter3 -JobPollCompleted $jobPollCompleted3 -JobFinalize { param($job, $pendingQueue) return @{ Success = $true } } `
    -JobAbortCleanup { param($job) } -ChapterCompleteCallback $chapterCompleteCallback3 `
    -MaxConcurrent 10 -MaxQueueAhead 2 -CancelToken $cts3.Token

$maxObservedActive3 = if ($script:observedActive3.Count -gt 0) { ($script:observedActive3 | Measure-Object -Maximum).Maximum } else { -1 }
Test-Assert ($script:observedActive3.Count -gt 0) "sanity check: chapter 1's slow job was actually polled more than once"
Test-Assert ($maxObservedActive3 -le 2) ("the number of pulled-but-incomplete chapters never exceeded -MaxQueueAhead (2) at any observed point (max seen: " + $maxObservedActive3 + ")")
Test-Assert ($script:providerPullCount3 -eq 5) ("all 5 chapters were eventually pulled once capacity freed up (got " + $script:providerPullCount3 + ")")
Write-Host ""

# ==============================================================================
#  Scenario 4: abort mid-run - graceful drain within -AbortTimeoutSeconds,
#  then force-kill after. -MaxConcurrent (a real SemaphoreSlim here)
#  released exactly once per job on every exit path: job A finishes
#  gracefully during the drain window (normal JobFinalize path), job B
#  never finishes and gets force-killed (JobAbortCleanup path) once
#  -AbortTimeoutSeconds elapses.
# ==============================================================================
Write-Host "=== Scenario 4: abort mid-run - graceful drain then force-kill, budget released exactly once per job either way ===" -ForegroundColor Cyan
$budget4 = [System.Threading.SemaphoreSlim]::new(2, 2)
$jobA4 = New-FakeJob -Id "A4"
$jobB4 = New-FakeJob -Id "B4"
$feed4 = New-ManualChapterFeed -Chapters @(@{ ChapterInfo = "Chapter4"; Jobs = @($jobA4, $jobB4) })
$cts4 = [System.Threading.CancellationTokenSource]::new()
$finalizedCount4 = 0
$abortCleanupCount4 = 0
$abortCleanupIds4 = [System.Collections.Generic.List[string]]::new()
$pollPassCount4 = 0
$jobStarter4 = { param($job) $job.Started = $true; return $job }
$jobPollCompleted4 = {
    param($job)
    if (-not $job.Started) { return $false }
    if ($job.Id -eq "A4") {
        $job.StartCount++
        return ($job.StartCount -ge 2)   # finishes gracefully during the drain
    }
    return $false   # B4 never finishes - forces a force-kill
}
$jobFinalize4 = { param($job, $pendingQueue) $script:finalizedCount4++; return @{ Success = $true } }
$jobAbortCleanup4 = { param($job) $script:abortCleanupCount4++; $script:abortCleanupIds4.Add($job.Id) }
$abortPollCallback4 = {
    param($runningJobs)
    $script:pollPassCount4++
    if ($script:pollPassCount4 -eq 2) { $cts4.Cancel() }
}
$chapterCompleteCallback4 = { param($chapterInfo) }
$result4 = Invoke-ChapterDispatch -ChapterProvider $feed4.ChapterProvider -JobBuilder $feed4.JobBuilder `
    -JobStarter $jobStarter4 -JobPollCompleted $jobPollCompleted4 -JobFinalize $jobFinalize4 `
    -JobAbortCleanup $jobAbortCleanup4 -ChapterCompleteCallback $chapterCompleteCallback4 `
    -MaxConcurrent $budget4 -AbortPollCallback $abortPollCallback4 -AbortTimeoutSeconds 1 -CancelToken $cts4.Token

Test-Assert ($result4.Aborted -eq $true) "run reports Aborted=true"
Test-Assert ($script:finalizedCount4 -eq 1) ("job A4 finished gracefully through the normal JobFinalize path exactly once (got " + $script:finalizedCount4 + ")")
Test-Assert ($script:abortCleanupCount4 -eq 1 -and $script:abortCleanupIds4[0] -eq "B4") ("only job B4 (the one that never finished) got JobAbortCleanup, not job A4 (got count=" + $script:abortCleanupCount4 + ", ids=" + ($script:abortCleanupIds4 -join ",") + ")")
Test-Assert ($result4.ForceKilledCount -eq 1) ("exactly one job (B4) was force-killed (got " + $result4.ForceKilledCount + ")")
Test-Assert ($budget4.CurrentCount -eq 2) ("both jobs' budget slots were released exactly once each - semaphore back to its full count of 2 (got " + $budget4.CurrentCount + ")")
Write-Host ""

# ==============================================================================
#  Scenario 5: the final-completion-check-before-force-kill race
#  specifically - a job whose JobPollCompleted flips $true right as the
#  timeout elapses must still be finalized normally, not force-killed.
#  This is the exact live-caught bug class from the real code (see this
#  module's own header) - worth a dedicated scenario, not just trusting
#  the generalization by inspection.
#
#  Made fully deterministic (2026-09-09, fixing a real flaky-test bug -
#  an earlier version raced two independent wall clocks: an absolute
#  "finish at" timestamp set once at test setup, against
#  -AbortTimeoutSeconds measured from whenever cancellation actually got
#  detected - the two weren't tightly coupled, so under real timing
#  jitter the job sometimes finished too late to prove anything and was
#  genuinely, correctly force-killed instead, an intermittent failure
#  with no bug behind it). -AbortTimeoutSeconds 0 makes the timed drain
#  while loop's own condition (Elapsed.TotalSeconds -lt 0) permanently
#  false, so that loop runs ZERO iterations, guaranteed, regardless of
#  timing - the ONLY code path left that can ever poll this job again is
#  the mandatory final completion-check pass. JobPollCompleted counts its
#  own calls and only reports done on the 3rd (1st: normal dispatch pass
#  before cancellation; 2nd: the pass where -AbortPollCallback cancels,
#  same pass's own poll step still runs; 3rd: the drain's mandatory final
#  check) - a fixed call count, not a clock, so no race is possible.
# ==============================================================================
Write-Host "=== Scenario 5: a job finishing right at the abort-timeout boundary is finalized normally, not force-killed ===" -ForegroundColor Cyan
$jobC5 = New-FakeJob -Id "C5"
$feed5 = New-ManualChapterFeed -Chapters @(@{ ChapterInfo = "Chapter5"; Jobs = @($jobC5) })
$cts5 = [System.Threading.CancellationTokenSource]::new()
$finalizedCount5 = 0
$abortCleanupCount5 = 0
$jobStarter5 = { param($job) $job.Started = $true; return $job }
$jobPollCompleted5 = {
    param($job)
    if (-not $job.Started) { return $false }
    $job.StartCount++
    return ($job.StartCount -ge 3)
}
$jobFinalize5 = { param($job, $pendingQueue) $script:finalizedCount5++; return @{ Success = $true } }
$jobAbortCleanup5 = { param($job) $script:abortCleanupCount5++ }
$abortPollCallback5 = { param($runningJobs) if ($runningJobs.Count -gt 0 -and -not $cts5.Token.IsCancellationRequested) { $cts5.Cancel() } }
$result5 = Invoke-ChapterDispatch -ChapterProvider $feed5.ChapterProvider -JobBuilder $feed5.JobBuilder `
    -JobStarter $jobStarter5 -JobPollCompleted $jobPollCompleted5 -JobFinalize $jobFinalize5 `
    -JobAbortCleanup $jobAbortCleanup5 -ChapterCompleteCallback { param($chapterInfo) } `
    -MaxConcurrent 4 -AbortPollCallback $abortPollCallback5 -AbortTimeoutSeconds 0 -CancelToken $cts5.Token

Test-Assert ($script:finalizedCount5 -eq 1) ("the job that finished right at the timeout boundary was finalized normally (got finalize count=" + $script:finalizedCount5 + ")")
Test-Assert ($script:abortCleanupCount5 -eq 0) ("it was NOT force-killed / JobAbortCleanup'd despite finishing after the timed drain loop's own deadline (got abort-cleanup count=" + $script:abortCleanupCount5 + ")")
Test-Assert ($result5.ForceKilledCount -eq 0) ("ForceKilledCount is 0 - the final completion-check pass caught it before force-kill (got " + $result5.ForceKilledCount + ")")
Write-Host ""

# ==============================================================================
#  Scenario 6: -JobStarter throwing (mirrors Process.Start() failing on a
#  stale exe path) - counted, budget released, loop continues.
# ==============================================================================
Write-Host "=== Scenario 6: JobStarter throwing is counted, budget released, loop continues ===" -ForegroundColor Cyan
$budget6 = [System.Threading.SemaphoreSlim]::new(2, 2)
$jobBad6 = New-FakeJob -Id "Bad6"
$jobGood6 = New-FakeJob -Id "Good6"
$feed6 = New-ManualChapterFeed -Chapters @(@{ ChapterInfo = "Chapter6"; Jobs = @($jobBad6, $jobGood6) })
$cts6 = [System.Threading.CancellationTokenSource]::new()
$jobStarter6 = {
    param($job)
    if ($job.Id -eq "Bad6") { throw "simulated Process.Start() failure" }
    $job.Started = $true
    return $job
}
$jobPollCompleted6 = { param($job) if (-not $job.Started) { return $false }; $job.Done = $true; return $true }
$finalizedCount6 = 0
$jobFinalize6 = { param($job, $pendingQueue) $script:finalizedCount6++; return @{ Success = $true } }
$completed6 = [System.Collections.Generic.List[object]]::new()
$chapterCompleteCallback6 = { param($chapterInfo) $completed6.Add($chapterInfo) }.GetNewClosure()
$result6 = Invoke-ChapterDispatch -ChapterProvider $feed6.ChapterProvider -JobBuilder $feed6.JobBuilder `
    -JobStarter $jobStarter6 -JobPollCompleted $jobPollCompleted6 -JobFinalize $jobFinalize6 `
    -JobAbortCleanup { param($job) } -ChapterCompleteCallback $chapterCompleteCallback6 `
    -MaxConcurrent $budget6 -CancelToken $cts6.Token

Test-Assert ($result6.JobStarterFailedCount -eq 1) ("the throwing job was counted into JobStarterFailedCount (got " + $result6.JobStarterFailedCount + ")")
Test-Assert ($script:finalizedCount6 -eq 1) "the OTHER job in the same chapter still dispatched and finalized normally"
Test-Assert ($completed6.Count -eq 1 -and $completed6[0] -eq "Chapter6") "the chapter still completed once its one real job finished, despite the other one failing to start"
Test-Assert ($budget6.CurrentCount -eq 2) ("the failed job's budget slot was still released - semaphore back to full count of 2 (got " + $budget6.CurrentCount + ")")
Write-Host ""

# ==============================================================================
#  Scenario 7: -JobFinalize returning @{ Requeued = $true } - the new job
#  reaches the same pending queue and gets dispatched like any other,
#  without counting a spurious result for the original job.
# ==============================================================================
Write-Host "=== Scenario 7: JobFinalize returning Requeued re-enqueues a new job, doesn't count a result for the original ===" -ForegroundColor Cyan
$jobOrig7 = New-FakeJob -Id "Orig7"
$feed7 = New-ManualChapterFeed -Chapters @(@{ ChapterInfo = "Chapter7"; Jobs = @($jobOrig7) })
$cts7 = [System.Threading.CancellationTokenSource]::new()
$finalizeCallCount7 = 0
$normalFinalizeCount7 = 0
$jobStarter7 = { param($job) $job.Started = $true; return $job }
$jobPollCompleted7 = { param($job) if (-not $job.Started) { return $false }; $job.Done = $true; return $true }
$jobFinalize7 = {
    param($job, $pendingQueue)
    $script:finalizeCallCount7++
    if ($job.Id -eq "Orig7") {
        $retry = New-FakeJob -Id "Retry7"
        $retry.ChapterKey = $job.ChapterKey   # JobFinalize's own responsibility - see this module's JOB CONTRACT
        $pendingQueue.Enqueue($retry)
        return @{ Requeued = $true }
    }
    $script:normalFinalizeCount7++
    return @{ Success = $true }
}
$completed7 = [System.Collections.Generic.List[object]]::new()
$chapterCompleteCallback7 = { param($chapterInfo) $completed7.Add($chapterInfo) }.GetNewClosure()
$result7 = Invoke-ChapterDispatch -ChapterProvider $feed7.ChapterProvider -JobBuilder $feed7.JobBuilder `
    -JobStarter $jobStarter7 -JobPollCompleted $jobPollCompleted7 -JobFinalize $jobFinalize7 `
    -JobAbortCleanup { param($job) } -ChapterCompleteCallback $chapterCompleteCallback7 `
    -MaxConcurrent 4 -CancelToken $cts7.Token

Test-Assert ($script:finalizeCallCount7 -eq 2) ("JobFinalize was called twice - once for the original (Requeued), once for the retry (got " + $script:finalizeCallCount7 + ")")
Test-Assert ($script:normalFinalizeCount7 -eq 1) "exactly one normal (non-Requeued) finalize happened - for the retry job, not the original"
Test-Assert ($completed7.Count -eq 1 -and $completed7[0] -eq "Chapter7") "the chapter still completed exactly once, after the retry finished - the Requeue didn't cause a premature or duplicate completion"
Write-Host ""

# ==============================================================================
#  Scenario 8: ChapterCompleteCallback fires exactly once per chapter,
#  only once all its jobs are finalized AND the provider confirms nothing
#  more is coming for it - including jobs from several different chapters
#  finishing in a shuffled order.
# ==============================================================================
Write-Host "=== Scenario 8: ChapterCompleteCallback fires exactly once per chapter, even with shuffled cross-chapter completion order ===" -ForegroundColor Cyan
$jX1 = New-FakeJob -Id "X1"; $jX2 = New-FakeJob -Id "X2"
$jY1 = New-FakeJob -Id "Y1"
$jZ1 = New-FakeJob -Id "Z1"; $jZ2 = New-FakeJob -Id "Z2"; $jZ3 = New-FakeJob -Id "Z3"
$feed8 = New-ManualChapterFeed -Chapters @(
    @{ ChapterInfo = "X"; Jobs = @($jX1, $jX2) },
    @{ ChapterInfo = "Y"; Jobs = @($jY1) },
    @{ ChapterInfo = "Z"; Jobs = @($jZ1, $jZ2, $jZ3) }
)
$cts8 = [System.Threading.CancellationTokenSource]::new()
# Deliberately shuffled per-job "finish after N polls" so completion order
# crosses chapter boundaries: Y1(1), X1(1), Z1(2), X2(3), Z2(3), Z3(5).
$finishAfter8 = @{ "X1" = 1; "X2" = 3; "Y1" = 1; "Z1" = 2; "Z2" = 3; "Z3" = 5 }
$jobStarter8 = { param($job) $job.Started = $true; return $job }
$jobPollCompleted8 = {
    param($job)
    if (-not $job.Started) { return $false }
    $job.StartCount++
    return ($job.StartCount -ge $finishAfter8[$job.Id])
}.GetNewClosure()
$jobFinalize8 = { param($job, $pendingQueue) return @{ Success = $true } }
$completeCallCounts8 = @{}
$chapterCompleteCallback8 = {
    param($chapterInfo)
    if (-not $completeCallCounts8.ContainsKey($chapterInfo)) { $completeCallCounts8[$chapterInfo] = 0 }
    $completeCallCounts8[$chapterInfo]++
}.GetNewClosure()
$result8 = Invoke-ChapterDispatch -ChapterProvider $feed8.ChapterProvider -JobBuilder $feed8.JobBuilder `
    -JobStarter $jobStarter8 -JobPollCompleted $jobPollCompleted8 -JobFinalize $jobFinalize8 `
    -JobAbortCleanup { param($job) } -ChapterCompleteCallback $chapterCompleteCallback8 `
    -MaxConcurrent 10 -MaxQueueAhead 3 -CancelToken $cts8.Token

Test-Assert ($script:completeCallCounts8["X"] -eq 1 -and $script:completeCallCounts8["Y"] -eq 1 -and $script:completeCallCounts8["Z"] -eq 1) ("every chapter's callback fired exactly once despite shuffled cross-chapter completion order (got X=" + $script:completeCallCounts8["X"] + ", Y=" + $script:completeCallCounts8["Y"] + ", Z=" + $script:completeCallCounts8["Z"] + ")")
Test-Assert ($result8.ChapterResults.Count -eq 3 -and ($result8.ChapterResults | Where-Object { $_.Completed }).Count -eq 3) "all three chapters reported Completed=true in ChapterResults"
Write-Host ""

# ==============================================================================
#  Scenario 9: a shared -MaxConcurrent SemaphoreSlim (not just a private
#  [int]) - basic coverage of the primitive's own handling of a pre-built
#  SemaphoreSlim vs. an owned counter (full two-worker-sharing coverage is
#  mode 1's own migration work later, per the design doc).
# ==============================================================================
Write-Host "=== Scenario 9: a pre-built shared SemaphoreSlim budget is respected as the real concurrency ceiling ===" -ForegroundColor Cyan
$budget9 = [System.Threading.SemaphoreSlim]::new(1, 1)   # only ONE slot - proves jobs serialize, not the -MaxConcurrent int path
$jobD1 = New-FakeJob -Id "D1"; $jobD2 = New-FakeJob -Id "D2"; $jobD3 = New-FakeJob -Id "D3"
$feed9 = New-ManualChapterFeed -Chapters @(@{ ChapterInfo = "Chapter9"; Jobs = @($jobD1, $jobD2, $jobD3) })
$cts9 = [System.Threading.CancellationTokenSource]::new()
$maxConcurrentObserved9 = 0
$currentlyRunning9 = 0
$jobStarter9 = { param($job) $job.Started = $true; $script:currentlyRunning9++; if ($script:currentlyRunning9 -gt $script:maxConcurrentObserved9) { $script:maxConcurrentObserved9 = $script:currentlyRunning9 }; return $job }
$jobPollCompleted9 = { param($job) if (-not $job.Started) { return $false }; $job.Done = $true; return $true }
$jobFinalize9 = { param($job, $pendingQueue) $script:currentlyRunning9--; return @{ Success = $true } }
$result9 = Invoke-ChapterDispatch -ChapterProvider $feed9.ChapterProvider -JobBuilder $feed9.JobBuilder `
    -JobStarter $jobStarter9 -JobPollCompleted $jobPollCompleted9 -JobFinalize $jobFinalize9 `
    -JobAbortCleanup { param($job) } -ChapterCompleteCallback { param($chapterInfo) } `
    -MaxConcurrent $budget9 -CancelToken $cts9.Token

Test-Assert ($jobD1.Started -and $jobD2.Started -and $jobD3.Started) "all three jobs eventually dispatched despite only one budget slot"
Test-Assert ($maxConcurrentObserved9 -le 1) ("never more than 1 job was concurrently running, matching the SemaphoreSlim(1,1) budget - not -MaxConcurrent as a plain int (got max observed=" + $maxConcurrentObserved9 + ")")
Test-Assert ($budget9.CurrentCount -eq 1) ("the shared budget is back to its full count of 1 after the run (got " + $budget9.CurrentCount + ")")
Write-Host ""

# ==============================================================================
#  Scenario 10 (2026-09-14, dead-code-removal triage - see Todo.md's
#  matching entry): an unrelated exception from INSIDE the main dispatch
#  loop (here, -AbortPollCallback throwing on its second pass, once a job
#  is genuinely still running - NOT a caught -JobStarter failure, that's
#  Scenario 6's own case) must still release the still-running job via
#  -JobAbortCleanup and the shared budget before rethrowing. Same bug
#  species ImageConversionPipeline.Harness.ps1's Scenario AB used to
#  prove against Convert-ImageBatch's own now-deleted copy of this same
#  try/catch shape - this is the one, shared copy that replaced it
#  (AnimatedConversionPipeline.Harness.ps1 never had a scenario for this
#  exact species - its own same-pass-throw scenario, Scenario X, is the
#  SlotReleased-double-clean species instead, covered by Scenario 11
#  below).
# ==============================================================================
Write-Host "=== Scenario 10: an unrelated throw mid-dispatch still releases a genuinely-running job ===" -ForegroundColor Cyan
$budget10 = [System.Threading.SemaphoreSlim]::new(2, 2)
$job10 = New-FakeJob -Id "J10"
$feed10 = New-ManualChapterFeed -Chapters @(@{ ChapterInfo = "Chapter10"; Jobs = @($job10) })
$cts10 = [System.Threading.CancellationTokenSource]::new()
$jobStarter10 = { param($job) $job.Started = $true; return $job }
$jobPollCompleted10 = { param($job) return $false }   # never finishes - stays genuinely "running"
$abortCleanupIds10 = [System.Collections.Generic.List[string]]::new()
$jobAbortCleanup10 = { param($job) $abortCleanupIds10.Add($job.Id) }.GetNewClosure()
$script:pollPassCount10 = 0
$abortPollCallback10 = {
    param($runningJobs)
    $script:pollPassCount10++
    if ($script:pollPassCount10 -ge 2) { throw "simulated unrelated AbortPollCallback failure" }
}
$threw10 = $false
try {
    $null = Invoke-ChapterDispatch -ChapterProvider $feed10.ChapterProvider -JobBuilder $feed10.JobBuilder `
        -JobStarter $jobStarter10 -JobPollCompleted $jobPollCompleted10 -JobFinalize { param($job, $pendingQueue) return @{ Success = $true } } `
        -JobAbortCleanup $jobAbortCleanup10 -ChapterCompleteCallback { param($chapterInfo) } `
        -MaxConcurrent $budget10 -AbortPollCallback $abortPollCallback10 -CancelToken $cts10.Token
} catch {
    $threw10 = $true
}

Test-Assert $threw10 "the injected failure propagated out of Invoke-ChapterDispatch, not silently swallowed"
Test-Assert ($abortCleanupIds10.Count -eq 1 -and $abortCleanupIds10[0] -eq "J10") ("the genuinely-still-running job was released via JobAbortCleanup before the rethrow (got count=" + $abortCleanupIds10.Count + ", ids=" + ($abortCleanupIds10 -join ",") + ")")
Test-Assert ($budget10.CurrentCount -eq 2) ("the running job's budget slot was released too - semaphore back to full count of 2 (got " + $budget10.CurrentCount + ")")
Write-Host ""

# ==============================================================================
#  Scenario 11 (2026-09-14, dead-code-removal triage): a same-pass throw
#  (here, -JobFinalize throwing for the SECOND job in this poll pass) must
#  not double-clean an EARLIER job in the same pass that already finished
#  normally (SlotReleased already true) - the outer catch's own
#  -JobAbortCleanup call is gated on "not SlotReleased" for exactly this
#  reason. Same bug species ImageConversionPipeline.Harness.ps1's Scenario
#  AF and AnimatedConversionPipeline.Harness.ps1's Scenario X used to prove
#  against Convert-ImageBatch/Convert-AnimatedBatch's own now-deleted copy
#  of this same try/catch shape (Animated Scenario Y is unrelated - it
#  tests a force-killed job's JobAbortCleanup, the same species as image
#  Scenario AG, and was ported rather than deleted - see
#  AnimatedConversionPipeline.Harness.ps1's own header on that scenario).
# ==============================================================================
Write-Host "=== Scenario 11: a same-pass throw does not double-clean an earlier job that already finished normally ===" -ForegroundColor Cyan
$budget11 = [System.Threading.SemaphoreSlim]::new(2, 2)
$jobA11 = New-FakeJob -Id "A11"
$jobB11 = New-FakeJob -Id "B11"
$feed11 = New-ManualChapterFeed -Chapters @(@{ ChapterInfo = "Chapter11"; Jobs = @($jobA11, $jobB11) })
$cts11 = [System.Threading.CancellationTokenSource]::new()
$jobStarter11 = { param($job) $job.Started = $true; return $job }
$jobPollCompleted11 = { param($job) return $job.Started }
$normalFinalizeIds11 = [System.Collections.Generic.List[string]]::new()
$jobFinalize11 = {
    param($job, $pendingQueue)
    if ($job.Id -eq "B11") { throw "simulated JobFinalize failure for B11" }
    $normalFinalizeIds11.Add($job.Id)
    return @{ Success = $true }
}.GetNewClosure()
$abortCleanupIds11 = [System.Collections.Generic.List[string]]::new()
$jobAbortCleanup11 = { param($job) $abortCleanupIds11.Add($job.Id) }.GetNewClosure()
$threw11 = $false
try {
    $null = Invoke-ChapterDispatch -ChapterProvider $feed11.ChapterProvider -JobBuilder $feed11.JobBuilder `
        -JobStarter $jobStarter11 -JobPollCompleted $jobPollCompleted11 -JobFinalize $jobFinalize11 `
        -JobAbortCleanup $jobAbortCleanup11 -ChapterCompleteCallback { param($chapterInfo) } `
        -MaxConcurrent $budget11 -CancelToken $cts11.Token
} catch {
    $threw11 = $true
}

Test-Assert $threw11 "the injected JobFinalize failure propagated out of Invoke-ChapterDispatch"
Test-Assert ($normalFinalizeIds11.Count -eq 1 -and $normalFinalizeIds11[0] -eq "A11") "sanity check: A11 finalized normally before B11's throw"
Test-Assert ($abortCleanupIds11.Count -eq 1 -and $abortCleanupIds11[0] -eq "B11") ("only B11 (the one that threw mid-finalize) was released via JobAbortCleanup - A11 (already finalized normally, SlotReleased) was NOT double-cleaned (got count=" + $abortCleanupIds11.Count + ", ids=" + ($abortCleanupIds11 -join ",") + ")")
Test-Assert ($budget11.CurrentCount -eq 2) ("both jobs' budget slots were released exactly once each despite the throw - semaphore back to full count of 2 (got " + $budget11.CurrentCount + ")")
Write-Host ""

# ==============================================================================
#  Scenario 12 (2026-09-14, dead-code-removal triage): [ConsoleCtrl]::IsCloseEvent
#  skips the graceful-wait drain loop entirely and goes straight to
#  force-kill - a window-close abort force-kills the whole process ~5s
#  later regardless, so waiting out any part of -AbortTimeoutSeconds can
#  never fit. Same bug species ImageConversionPipeline.Harness.ps1's
#  Scenario AK and AnimatedConversionPipeline.Harness.ps1's Scenario AB
#  used to prove against Convert-ImageBatch/Convert-AnimatedBatch's own
#  now-deleted copy of this same drain-loop shape.
# ==============================================================================
Write-Host "=== Scenario 12: IsCloseEvent skips the graceful drain wait entirely, force-kills immediately ===" -ForegroundColor Cyan
$job12 = New-FakeJob -Id "J12"
$feed12 = New-ManualChapterFeed -Chapters @(@{ ChapterInfo = "Chapter12"; Jobs = @($job12) })
$cts12 = [System.Threading.CancellationTokenSource]::new()
$jobStarter12 = { param($job) $job.Started = $true; return $job }
$jobPollCompleted12 = { param($job) return $false }   # never finishes
$script:abortCleanupCount12 = 0
$jobAbortCleanup12 = { param($job) $script:abortCleanupCount12++ }
$abortPollCallback12 = { param($runningJobs) if ($runningJobs.Count -gt 0) { $cts12.Cancel() } }.GetNewClosure()

[ConsoleCtrl]::IsCloseEvent = $true
$sw12 = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $result12 = Invoke-ChapterDispatch -ChapterProvider $feed12.ChapterProvider -JobBuilder $feed12.JobBuilder `
        -JobStarter $jobStarter12 -JobPollCompleted $jobPollCompleted12 -JobFinalize { param($job, $pendingQueue) return @{ Success = $true } } `
        -JobAbortCleanup $jobAbortCleanup12 -ChapterCompleteCallback { param($chapterInfo) } `
        -MaxConcurrent 4 -AbortPollCallback $abortPollCallback12 -AbortTimeoutSeconds 30 -CancelToken $cts12.Token
} finally {
    $sw12.Stop()
    [ConsoleCtrl]::IsCloseEvent = $false
}

Test-Assert ($sw12.Elapsed.TotalSeconds -lt 5) ("returned in under 5s despite a 30s -AbortTimeoutSeconds (took " + [int]$sw12.Elapsed.TotalSeconds + "s)")
Test-Assert ($result12.ForceKilledCount -eq 1) ("the never-finishing job was force-killed, not waited for (got ForceKilledCount=" + $result12.ForceKilledCount + ")")
Test-Assert ($script:abortCleanupCount12 -eq 1) ("JobAbortCleanup fired once for the force-killed job (got " + $script:abortCleanupCount12 + ")")
Write-Host ""

# ==============================================================================
#  Scenario 13 (2026-09-14, dead-code-removal triage): an unrelated
#  exception from INSIDE the drain's own force-kill step (here, the
#  "force-stopping N job(s)..." Write-Log call itself, which sits OUTSIDE
#  each job's own per-job try/catch in that loop) must still kill/dispose/
#  JobAbortCleanup every job still in $running via that block's own catch,
#  not leave them dangling. Same bug species
#  ImageConversionPipeline.Harness.ps1's Scenario AH and
#  AnimatedConversionPipeline.Harness.ps1's Scenario AA used to prove
#  against Convert-ImageBatch/Convert-AnimatedBatch's own now-deleted
#  copy of this same drain-loop shape.
# ==============================================================================
Write-Host "=== Scenario 13: an unrelated throw during the drain's force-stop logging still cleans up every remaining job ===" -ForegroundColor Cyan
$job13a = New-FakeJob -Id "A13"
$job13b = New-FakeJob -Id "B13"
$feed13 = New-ManualChapterFeed -Chapters @(@{ ChapterInfo = "Chapter13"; Jobs = @($job13a, $job13b) })
$cts13 = [System.Threading.CancellationTokenSource]::new()
$jobStarter13 = { param($job) $job.Started = $true; return $job }
$jobPollCompleted13 = { param($job) return $false }   # neither ever finishes
$abortCleanupIds13 = [System.Collections.Generic.List[string]]::new()
$jobAbortCleanup13 = { param($job) $abortCleanupIds13.Add($job.Id) }.GetNewClosure()
$abortPollCallback13 = { param($runningJobs) if ($runningJobs.Count -gt 0) { $cts13.Cancel() } }.GetNewClosure()

$realWriteLogFn13 = ${function:Write-Log}
function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    if ($Message -like "*force-stopping*") { throw "simulated Write-Log failure during the drain's own force-stop logging" }
}
$threw13 = $false
try {
    $null = Invoke-ChapterDispatch -ChapterProvider $feed13.ChapterProvider -JobBuilder $feed13.JobBuilder `
        -JobStarter $jobStarter13 -JobPollCompleted $jobPollCompleted13 -JobFinalize { param($job, $pendingQueue) return @{ Success = $true } } `
        -JobAbortCleanup $jobAbortCleanup13 -ChapterCompleteCallback { param($chapterInfo) } `
        -MaxConcurrent 4 -AbortPollCallback $abortPollCallback13 -AbortTimeoutSeconds 0 -CancelToken $cts13.Token
} catch {
    $threw13 = $true
} finally {
    ${function:Write-Log} = $realWriteLogFn13
}

Test-Assert $threw13 "the injected Write-Log failure propagated out of Invoke-ChapterDispatch"
Test-Assert ($abortCleanupIds13.Count -eq 2 -and $abortCleanupIds13.Contains("A13") -and $abortCleanupIds13.Contains("B13")) ("both jobs still in `$running were cleaned up via the outer catch despite the throw happening before either could be individually processed (got: " + ($abortCleanupIds13 -join ", ") + ")")
Write-Host ""

# ==============================================================================
#  Scenario P: New-LibraryChapterProvider flattens New-SeriesProvider +
#  Get-SeriesChapters (both real, unchanged) into one continuous lazy feed
#  over a real folder structure - two series, several chapters each.
# ==============================================================================
Write-Host "=== Scenario P: New-LibraryChapterProvider flattens a real two-series library into one chapter feed ===" -ForegroundColor Cyan
$libRoot = Join-Path $scratchDir "library-p"
foreach ($pair in @(
    @("Series A", "Chapter 1"), @("Series A", "Chapter 2"),
    @("Series B", "Chapter 1"), @("Series B", "Chapter 2"), @("Series B", "Chapter 3")
)) {
    $dir = Join-Path $libRoot (Join-Path $pair[0] $pair[1])
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir "page1.jpg"), "fake pixels")
}

$providerP = New-LibraryChapterProvider -LibraryPath $libRoot -QualifyingExtensions @(".jpg")
$yielded = [System.Collections.Generic.List[hashtable]]::new()
while ($true) {
    $next = & $providerP
    if ($null -eq $next) { break }
    $yielded.Add($next)
}

Test-Assert ($yielded.Count -eq 5) ("all 5 chapters across both series were yielded (got " + $yielded.Count + ")")
Test-Assert (($yielded | Where-Object { $_.SeriesName -eq "Series A" }).Count -eq 2) "Series A's 2 chapters were both yielded, with SeriesName set correctly"
Test-Assert (($yielded | Where-Object { $_.SeriesName -eq "Series B" }).Count -eq 3) "Series B's 3 chapters were all yielded, with SeriesName set correctly"
Test-Assert (($yielded | Select-Object -First 2 | ForEach-Object { $_.SeriesName }) -notcontains "Series B") "Series A's chapters are yielded before Series B's - lazy, series-by-series order preserved (not shuffled/parallel)"
Test-Assert ($null -eq (& $providerP)) "calling again after exhaustion keeps returning `$null, not an error"
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
