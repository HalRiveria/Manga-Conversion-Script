<#
.SYNOPSIS
    Controller - Full Pipeline's (mode 1) per-chapter engine: for each
    chapter, runs image conversion and animated conversion CONCURRENTLY
    (sharing one process budget), merges both outcomes into a single
    status, and zips the chapter only when neither engine reported a
    real failure.

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules.

    SCOPE - built against the design settled in Todo.md's
    "Full Pipeline (per-chapter controller design)" section (read that
    first for the full reasoning behind every decision below - this
    header summarizes, it doesn't replace it). This module is named
    generically ("Controller", not "FullPipeline") because it's expected
    to grow into the TOP-LEVEL DISPATCHER for every mode (not just Full
    Pipeline) once Menu.ps1's Get-SelectedMode resolves a choice - that
    role is confirmed in scope but deliberately NOT designed or built
    here. Today this module contains ONLY the Full Pipeline per-chapter
    engine, which is fully specified.

    ARCHITECTURE: this module owns the per-chapter walk itself (reusing
    New-SeriesProvider/Get-SeriesChapters, same two-tier discovery
    ImageConversionPipeline.ps1's PART 2 and
    AnimatedConversionPipeline.ps1's PART 2 already use) and calls the
    low-level batch primitives (Convert-ImageBatch, Convert-AnimatedBatch)
    directly, chapter by chapter - it does NOT call either module's own
    top-level orchestrator (Invoke-LooseImageConversionPipeline,
    Invoke-LooseAnimatedConversionPipeline) or ZipPipeline.ps1's
    Invoke-ZipOnlyPipeline in sequence. Calling the three existing
    top-level functions one after another would just be the already-
    rejected "three sequential whole-library passes" model wearing a
    controller costume - this module walks the library exactly ONCE and
    dispatches both engines per chapter.

    CONCURRENCY MECHANICS (dispatch redesign step 4
    of 4 - full design in the "DISPATCH-REDESIGN STEP 4" comment block
    right above Get-OrCreateFullPipelineSeriesBundle, below): TWO
    independent Invoke-ChapterDispatch (ChapterDispatch.ps1) engines -
    image, animated - each running its OWN chapter walk across the WHOLE
    library concurrently, not the one-chapter-at-a-time blocking dispatch
    this module used before. Still reuses Invoke-ZipParallelProcessing
    (ZipParallelProcessing.ps1) as the outer 2-runspace mixer - exactly
    the same mechanism as before, just called ONCE per Invoke-FullPipeline
    run instead of once per chapter, since each of the two runspaces now
    spans the whole library for its own engine rather than one chapter for
    either engine. $script:fullPipelineEngineWorker (replacing the old
    per-chapter $script:fullPipelineChapterWorker) is the shared worker
    scriptblock, picking Image vs Animated logic via -EngineType and
    calling Invoke-ChapterDispatch itself, not Convert-ImageBatch/
    Convert-AnimatedBatch directly (see "SHARED PROCESS BUDGET" below for
    what that means for those two functions' own -SharedBudget param).
    Idle concurrency in EITHER engine now picks up its own next chapter's
    jobs immediately - the actual point of the whole redesign - instead of
    the run blocking on one chapter's image AND animated conversion both
    finishing before the next chapter is even enumerated.

    SHARED PROCESS BUDGET: a single System.Threading.SemaphoreSlim, sized
    to -FullPipelineMaxConcurrentProcs, created once per Invoke-FullPipeline
    call and passed into BOTH engine workers (as a real object reference -
    the same .NET object crosses into each runspace, so both engines'
    Invoke-ChapterDispatch calls truly share one counter, via that
    primitive's own -MaxConcurrent param accepting a pre-built
    SemaphoreSlim instead of an owned int). Disposed in this function's own
    `finally`, alongside $fullCts.
    Convert-ImageBatch/Convert-AnimatedBatch (ImageConversionPipeline.ps1/
    AnimatedConversionPipeline.ps1) still HAVE their own optional
    -SharedBudget parameter (built for the OLD per-chapter design), but
    neither is called by this module anymore - Full Pipeline builds its
    own JobBuilder/JobStarter/JobFinalize per engine now (near-verbatim
    ports of modes 2/3's own migrated closures - see this module's
    "DISPATCH-REDESIGN STEP 4" block below), dispatched via
    Invoke-ChapterDispatch directly. -SharedBudget on those two functions
    is therefore unused dead code as of this migration - flagged in
    Todo.md rather than removed here, since removing a parameter from an
    already-tested, still-otherwise-correct function is a separate cleanup
    decision, not part of this one.

    MERGED CCR STATUS: Get-MergedChapterStatus combines an image
    ChapterResult and an animated ChapterResult (each possibly $null -
    nothing to convert for that engine this chapter) into ONE
    Status/Detail pair for a single Complete-ChapterProgress call per
    chapter - concatenates both engines' own sub-summaries
    ("Image: ... | Animated: ..."), Status is whichever of the two is
    worse (Error > Warning > Success). Reuses
    ImageConversionPipeline.ps1's Get-ChapterProgressStatus and
    AnimatedConversionPipeline.ps1's Get-ChapterAnimatedStatus directly -
    not a third reimplementation of that severity logic.

    ZIP-BLOCKING POLICY: a chapter is NEVER zipped if either engine's own
    Status (from the same two functions above) is "Error" -
    FailedCount > 0, ForceKilledCount > 0, or DeleteFailedCount > 0 for
    either engine. A Warning-tier outcome (something was skipped, but
    nothing failed) does NOT block zipping. The zip step calls
    ZipCreation.ps1's Compress-FolderToZip and ZipValidation.ps1's
    Test-ZipArchive DIRECTLY - NOT ZipPipeline.ps1's Invoke-LooseFolderZip,
    even though the confirmed design allowed either. Real reason, found
    live during this session's harness testing: Invoke-LooseFolderZip's
    own internal "any remaining $LooseImageExtensions file blocks
    zipping" guard treats .webp as an unconverted image SOURCE (correct
    for mode 2, where .webp only ever means that) - but in Full Pipeline,
    .webp is ALSO the animated engine's own successful OUTPUT, so that
    guard silently blocked zipping a chapter that had fully succeeded.
    This module's own merged Error-tier check (above) is already a
    correct, complete gate covering both engines, so Invoke-LooseFolderZip's
    guard was redundant even before the .webp collision was found. Also
    means this module never passes -SeriesName/-ChapterName to anything
    ZipPipeline.ps1 owns - it owns the chapter's one and only CCR
    transition (the merged one above) directly.

    CHAPTER-DISCOVERY COMPLETENESS: same fix as both engines' own solo
    orchestrators, extended to cover BOTH file types at once -
    Get-SeriesChapters's former-container/zip-staleness guards decide
    "is this worth re-zipping", not "does this hold unconverted content
    of either type" - a directory those guards exclude but that actually
    has unconverted images AND/OR unconverted animated files is folded in
    as an extra chapter-equivalent entry (IsZippable = $false, same
    convention as the two solo orchestrators) before Start-SeriesProgress
    is called.

    TOP-LEVEL DISPATCHER (Invoke-Mode). Runs whichever mode Menu.ps1's Resolve-ModeSelection resolved,
    translating one $Settings hashtable into each real pipeline entry
    point's own param list (they were never unified - each was built
    independently with its own flat param list), and returns
    Summary.ps1's canonical $stats shape (New-StatsTracker) instead of
    that pipeline's own differently-named raw counters, so a caller can
    hand the result straight to Get-SummaryLines. One shared
    try/catch around the whole dispatch calls Invoke-AbortOrFatalHandler
    on anything that escapes - this is the "shared top-level catch, not
    per-pipeline copies" decision (Todo.md), verified
    against all five real entry points' actual outer-scope structure
    before deciding: at the time, four of five only had try/finally at
    their outer scope (an exception already propagates this far as-is);
    Invoke-ZipOnlyPipeline was the one known outlier that swallowed its
    own. Fixed in the later codebase-review pass (CHANGELOG.md) - its
    outer catch-swallow was removed, so all five entry points now match.
    Each pipeline call is injectable via a
    named scriptblock parameter defaulting to the real function (same DI
    pattern as Show-CoverDeletionMenu's -RunHandler/-AddHandler,
    Menu.ps1) - the harness proves dispatch/translation/error-catch
    logic with fakes, never needing real cjxl/magick or a real
    ZipPipeline.ps1 dot-source, since every scenario overrides its handler
    explicitly (the real-function defaults only matter for an actual
    caller that doesn't override them).

    Mode 8 (ImageConversionZip) dispatches to Invoke-LooseImageConversionPipeline with a
    real -ZipStepCallback closure that owns mode 8's own business logic
    (which extensions block zipping, based on
    $Settings.ZipWithUnconvertedAnimated) and calls Invoke-LooseFolderZip
    (ZipPipeline.ps1) via the injectable -ZipFolderHandler. Deliberately
    was a stub through Phase 1 - built here only once Invoke-Mode itself
    was proven standalone, touching no other module.

    Invoke-MainLoop is the run loop that used to live inline
    in the main script: resolve a mode (Get-SelectedMode), run it
    (Invoke-Mode), report it (Format-ElapsedTime/Get-SummaryLines/
    Write-SummaryReport), prompt to continue or exit
    (Show-PostRunPrompt). All four real functions are injectable, same
    DI pattern as Invoke-Mode's own pipeline handlers - a harness proves
    the LOOP's own control flow (iteration count, when it stops) without
    a real interactive prompt or real pipeline. New forward reference
    this brings in: Menu.ps1 (Get-SelectedMode, Show-PostRunPrompt) -
    Controller.ps1 never needed Menu.ps1 before this.

    AVIF CLASSIFICATION exists to close a real race (the mechanism has
    been rewritten for the dispatch redesign, but the race itself and why
    it exists are unchanged, only where/when classification happens
    moved). Invoke-FullPipeline's own -LooseImageExtensions
    default includes .avif (previously excluded specifically to avoid this
    problem) - static AVIF gets converted here too, for the same
    "consistency across the whole library" reason ImageConversionPipeline.ps1
    already converts it in every other mode. Since Get-LooseImageCandidates
    and Get-LooseAnimatedCandidates are two INDEPENDENT scans, both
    discover the same .avif file, which would otherwise get dispatched to
    both engines at once - a real race (one engine converting+deleting a
    file the other is still identifying). Resolved per CHAPTER now (was
    per series), lazily, by whichever engine's own JobBuilder reaches that
    chapter FIRST - Get-OrCreateFullPipelineChapterClassification (below),
    NOT necessarily on the main thread anymore, since either engine's own
    worker runspace can be the one that gets there first; a
    Lazy<hashtable> with ExecutionAndPublication guarantees the real
    Test-AvifAnimated work happens at most once per chapter regardless of
    which engine wins the race. Ownership logic itself is unchanged: for
    every contested .avif, Test-AvifAnimated decides (static -> stays in
    the image list, animated -> stays in the animated list, removed from
    the other); a file that can't be classified is removed from BOTH
    lists, logged at -Level Error, and counted into InspectFailedCount via
    the shared -EventQueue (not through either engine's own
    ChapterResult counter, since the failure happens before either engine
    builds its own jobs for that file). Scoped ONLY to Full Pipeline -
    modes 2/3/8/9 call ImageConversionPipeline.ps1/
    AnimatedConversionPipeline.ps1 directly and keep their own existing
    internal checks unchanged; Full Pipeline is the only mode where two
    engines can reach the same candidate set at once, so it's the only one
    that needs this.

    FORWARD REFERENCES (not defined in this module - callers must
    dot-source the owning module(s) first):
      - Write-Log, Invoke-MutexGuardedWrite, Get-LoggingSharedFunctionNames
        (Logging.ps1)
      - Remove-Source, Move-ToRecycleBin, Remove-ItemPermanently,
        Get-FileDeletionSharedFunctionNames, $script:PermanentDelete,
        Initialize-FileDeletion (FileDeletion.ps1) - the middle two of the
        first three because Remove-Source itself calls one of them
        internally based on $script:PermanentDelete, and a fresh runspace
        needs BOTH propagated since it can't know ahead of time which
        branch a given deletion will take. Initialize-FileDeletion is
        called once per Invoke-MainLoop iteration (not just at bootstrap)
        so an options-menu PermanentDelete change takes effect on the
        very next run, not just the next process launch.
      - Get-ImageConversionSharedFunctionNames, Get-LooseImageCandidates,
        Remove-StaleLooseSources, Get-ChapterProgressStatus,
        Get-NeverConvertedExtensions, Test-WebPAnimated,
        Complete-ImageDispatchJob, Invoke-LooseImageConversionPipeline
        (ImageConversionPipeline.ps1) - NOT Convert-ImageBatch itself.
        Full Pipeline
        builds its own image-engine JobBuilder/JobStarter/JobFinalize now
        (see "DISPATCH-REDESIGN STEP 4" below) instead of calling that
        function directly; Convert-ImageBatch has no remaining real caller
        other than its own harness.
      - Get-AnimatedConversionSharedFunctionNames, Get-LooseAnimatedCandidates,
        Get-ChapterAnimatedStatus, Test-AvifAnimated, Complete-AnimatedDispatchJob,
        Invoke-LooseAnimatedConversionPipeline (AnimatedConversionPipeline.ps1) -
        same change, NOT Convert-AnimatedBatch itself (this module was that
        function's only real caller before this migration - now unused
        outside that module's own harness).
      - Invoke-ChapterDispatch, Get-ChapterDispatchSharedFunctionNames
        (ChapterDispatch.ps1) - the real dispatch primitive both engine
        workers now call; NOT New-LibraryChapterProvider (this module
        builds its own -ChapterProvider closures instead, same reasoning
        modes 2/3 already documented on their own copies of this same
        decision).
      - Get-*SharedFunctionNames (one per group above) are
        each module's own single source of truth for what a caller needs
        in -SharedFunctionNames to call into it from a runspace worker -
        $engineWorkerSharedFunctionNames below concatenates all of them
        instead of hand-typing every individual name, so a future new
        helper anywhere in this dependency chain only needs its own
        group's getter updated, not every caller across this codebase
        (see CHANGELOG.md for the real bug pattern this closes). Deliberately does NOT
        cover Write-GatedConsoleMessage - see
        Get-ImageConversionSharedFunctionNames's own docstring for why.
      - Compress-FolderToZip (ZipCreation.ps1), Test-ZipArchive
        (ZipValidation.ps1) - called directly, NOT via ZipPipeline.ps1's
        Invoke-LooseFolderZip (see "ZIP-BLOCKING POLICY" above for why)
      - Invoke-UnwantedImageScan (UnwantedImage.ps1) - Invoke-FullPipeline's
        RunCoverDeletionBeforeConversion pre-scan, main-thread-only (runs
        before any chapter dispatch starts, see that param's own comment)
      - New-SeriesProvider, Get-SeriesChapters,
        Get-LeafDirectoryDiscoverySharedFunctionNames
        (LeafDirectoryDiscovery.ps1) - the shared-function-names getter
        matters here in a way it doesn't for modes 2/3's own callers of
        these same two functions: both of THOSE run main-thread-only, but
        Full Pipeline's own two engine workers each call them from inside
        their own runspace (see "DISPATCH-REDESIGN STEP 4" below).
      - Invoke-ZipParallelProcessing (ZipParallelProcessing.ps1) - its
        -PollCallback param (built for this migration) is how this module
        drains cross-worker CCR events on the main thread, see
        "DISPATCH-REDESIGN STEP 4" below
      - Register-AbortCancellationSource, Unregister-AbortCancellationSource,
        Test-AbortSignal, Invoke-AbortOrFatalHandler, Reset-AbortState
        (AbortPipeline.ps1) - the last one for Invoke-MainLoop only,
        called once per loop iteration to clear any abort state left over
        from a previous run (see "Invoke-MainLoop" above)
      - $script:CleanConsoleOutputEnabled, Start-SeriesProgress,
        Start-ChapterProgress, Complete-ChapterProgress,
        Complete-AllActiveSeriesProgress (CleanConsoleRendering.ps1)
      - Initialize-CleanConsoleOutput (Logging.ps1) - same per-iteration
        re-sync reasoning as Initialize-FileDeletion above, for the Clean
        Console Output toggle
      - Invoke-ZipOnlyPipeline (ZipPipeline.ps1) - ONLY if a real caller
        of Invoke-Mode doesn't override -ZipFoldersHandler; not dot-
        sourced by this module's own harness, see above
      - Invoke-LooseFolderZip (ZipPipeline.ps1) - same caveat, for
        -ZipFolderHandler (mode 8's real zip step)
      - New-StatsTracker, Format-ElapsedTime, Get-SummaryLines,
        Write-SummaryReport (Summary.ps1) - the last three for
        Invoke-MainLoop specifically, needed unconditionally
      - Get-SelectedMode, Show-PostRunPrompt (Menu.ps1) - Invoke-MainLoop
        only, same caveat as the Invoke-Mode handlers above:
        only matters for a real caller that doesn't override
        -GetModeHandler/-PostRunPromptHandler
    Same dot-source ordering rule as ZipPipeline.ps1:
    Logging.ps1/FileDeletion.ps1 BEFORE ZipParallelProcessing.ps1, since
    -SharedFunctionNames captures whichever definition is CURRENTLY
    active in the caller's scope at call time.

.NOTES
    New module, no reference extraction (this coordination never existed
    in the original script - Full Pipeline is new functionality, see
    Menu.ps1's design). Built from the confirmed design in Todo.md's
    "Full Pipeline (per-chapter controller design)" section.
#>

# ==============================================================================
#  DISPATCH-REDESIGN STEP 4 - see Docs\dispatch-redesign-design.md
#  for the full design. Full Pipeline now runs two INDEPENDENT
#  Invoke-ChapterDispatch engines concurrently (one per file type), each
#  inside its own Invoke-ZipParallelProcessing worker runspace, sharing one
#  process budget (-SharedBudget, unchanged) - instead of the old design's
#  one Invoke-ZipParallelProcessing call PER CHAPTER, which blocked the next
#  chapter's own dispatch on both engines finishing the current one.
#
#  CHAPTER/SERIES IDENTITY IS SHARED, NOT PER-ENGINE (the one real design
#  refinement made during THIS build, past what Docs\dispatch-redesign-design.md's
#  own "Step 4 concrete implementation plan" had settled): rather than each
#  engine computing its own independent "which directories are chapters,
#  which are extras" answer (mirroring modes 2/3's own precedent too
#  literally), BOTH engines share one Get-OrCreateFullPipelineSeriesBundle
#  cache, keyed by series path - whichever engine's own walk reaches a
#  series FIRST computes that series' full chapter list ONCE (Lazy<T> with
#  ExecutionAndPublication guarantees exactly once, even under a real race -
#  same mechanism Problem 1 in the design doc called for, just scoped to the
#  whole series' bundle instead of one file's own AVIF classification),
#  including that series' per-chapter AVIF classification and naming-
#  collision detection - the other engine just reads the cached result.
#  This was a deliberate departure from independently-computed per-engine
#  "extra" entries: with two independent extra-computations, a directory
#  extra to BOTH engines (leftover images AND leftover animated files, not
#  a real Get-SeriesChapters chapter) would need Start-ChapterProgress/
#  Complete-ChapterProgress called TWICE for the "same" chapter under two
#  different chapterInfo object instances, once each - CCR's ActiveChapters
#  list tolerates the duplicate without crashing, but finalizing (zipping,
#  in particular) on the FIRST engine's own report would cut the SECOND
#  engine's still-running conversion off early for that shared directory, a
#  real correctness bug, not just a cosmetic one. Sharing chapter identity
#  (both engines read the IDENTICAL ChapterEntry object for a given
#  directory, from the SAME cached bundle) makes "wait for exactly 2 reports
#  before finalizing" true and simple for EVERY chapter, regular or extra,
#  with no separate case to reason about.
#
#  NEITHER ENGINE MAY CALL CLEAN CONSOLE OUTPUT DIRECTLY - both run inside
#  their own worker runspace (CleanConsoleRendering.ps1's own module-scope
#  state is per-runspace, not real script scope - see that module's own
#  "MUST be called from the main/orchestrating thread only" docstring).
#  Every CCR-facing moment (a series starting, a chapter starting, a
#  chapter's own merged completion) is instead enqueued onto a shared
#  ConcurrentQueue (-EventQueue below) and drained on the MAIN thread by
#  Invoke-FullPipeline's own -PollCallback (ZipParallelProcessing.ps1's new
#  param, built for exactly this) - see Complete-FullPipelineEvent below.
# ==============================================================================

function Add-FullPipelineZipBlockReason {
    <#
    .SYNOPSIS
        Records a real, unconverted-file reason a chapter must not be
        zipped this run (an AVIF classification failure, or a
        Get-LooseImageCandidates naming collision - same two reasons
        $failedClassificationDirs tracked in the old, single-threaded
        design) into a SHARED, thread-safe dictionary keyed by the
        chapter's own ChapterEntry object reference (matching
        ChapterDispatch.ps1's own chapter-identity convention, and
        Complete-MergedFullPipelineChapter's own read of this same
        dictionary below) - appends rather than overwrites when a chapter
        already has a reason recorded (mirrors the old code's own
        -notlike guard), since a chapter can hit both causes. Genuinely
        needs to be thread-safe here, unlike the old single-threaded
        version: Get-OrCreateFullPipelineSeriesBundle's own factory can run
        concurrently for two DIFFERENT series (one on each engine's own
        worker thread) at the same time, both potentially writing into
        this same dictionary.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Collections.Concurrent.ConcurrentDictionary[object,string]]$Dict,
        [Parameter(Mandatory)]
        $ChapterKey,
        [Parameter(Mandatory)]
        [string]$Reason
    )
    $updateFn = {
        param($key, $existing)
        if ($existing -like ("*" + $Reason + "*")) { $existing } else { $existing + ", " + $Reason }
    }.GetNewClosure()
    $null = $Dict.AddOrUpdate($ChapterKey, $Reason, [Func[object,string,string]]$updateFn)
}

function Get-OrCreateFullPipelineSeriesBundle {
    <#
    .SYNOPSIS
        Returns (computing and caching on first call, for this series) one
        series' full chapter list - the SAME per-series discovery work the
        old single-threaded Invoke-FullPipeline used to do inline, moved
        here so both engines' own -ChapterProvider closures can share one
        answer instead of computing two, possibly-disagreeing ones (see
        this module's own "DISPATCH-REDESIGN STEP 4" header above for why
        that matters). $Cache's own Lazy<T> (ExecutionAndPublication)
        guarantees this factory body runs to completion AT MOST ONCE per
        series, across both engines, even under a real race - real side
        effects inside it (Remove-StaleLooseSources' own deletions,
        Write-Log calls) are therefore also guaranteed to happen exactly
        once, safe from either engine's own thread.
    .OUTPUTS
        @{ ChapterEntries = List[hashtable] } - each entry:
        @{ SeriesName; ChapterName; Dir; ZipOut; IsZippable; IsExtra;
           Images = List[FileInfo] (post-AVIF-classification, this
           chapter's own image-engine job source); AnimatedFiles =
           List[FileInfo] (post-AVIF-classification, this chapter's own
           animated-engine job source) } - IsZippable is $false only for
        an IsExtra entry here; a naming collision or AVIF classification
        failure is recorded into -ZipBlockReasons instead (read by
        Complete-MergedFullPipelineChapter, not baked into this shape) -
        see Add-FullPipelineZipBlockReason's own header for why.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Collections.Concurrent.ConcurrentDictionary[string, System.Lazy[hashtable]]]$Cache,
        [Parameter(Mandatory)]
        [System.IO.DirectoryInfo]$Series,
        [string]$MagickExe,
        # NOT [Parameter(Mandatory)] on any of these three - see this
        # module's own harness Scenario S - PowerShell rejects an EMPTY array passed to a Mandatory
        # array-typed parameter outright ("Cannot bind argument... because
        # it is an empty array"), even though an empty list is a
        # perfectly legitimate, real value here (Scenario S deliberately
        # passes -AnimatedFileExtensions @() to isolate the image engine's
        # own classification path). Still effectively required - every
        # real caller always passes all three - just not enforced via the
        # attribute that also (incorrectly, for this case) bans "empty".
        [string[]]$LooseImageExtensions,
        [string[]]$AnimatedFileExtensions,
        [string[]]$KnownZipPaths = @(),
        [string[]]$FolderQualifyingExtensions,
        [System.Collections.Generic.HashSet[string]]$FolderExcludeStagingDirs,
        [Parameter(Mandatory)]
        [System.Collections.Concurrent.ConcurrentQueue[hashtable]]$EventQueue,
        [Parameter(Mandatory)]
        [System.Collections.Concurrent.ConcurrentDictionary[object,string]]$ZipBlockReasons
    )

    $factory = {
        # ---- Same per-series discovery as the old single-threaded code
        #      (chapters + candidate scans + extra-dir fold-in), just
        #      building a List[hashtable] instead of processing inline. ----
        $chapters = Get-SeriesChapters -SeriesPath $Series.FullName -QualifyingExtensions $FolderQualifyingExtensions `
            -ExcludeStagingDirs $FolderExcludeStagingDirs -ForceRezip $false

        $imageCandidates    = Get-LooseImageCandidates -ScanPath $Series.FullName -LooseImageExtensions $LooseImageExtensions `
            -KnownZipPaths $KnownZipPaths -ExcludeStagingDirs $FolderExcludeStagingDirs
        $animatedCandidates = Get-LooseAnimatedCandidates -ScanPath $Series.FullName -AnimatedFileExtensions $AnimatedFileExtensions `
            -KnownZipPaths $KnownZipPaths -ExcludeStagingDirs $FolderExcludeStagingDirs

        # Classification and stale-source cleanup are NOT done here, series-
        # wide, up front - see Get-OrCreateFullPipelineChapterClassification
        # below, called separately (lazily, per CHAPTER, not per series) by
        # each engine's own JobBuilder. Two real reasons, not one, both
        # caught live by this module's own harness before this migration
        # ever shipped:
        #   1. Correctness (Scenario C3): an animated .avif kept on purpose
        #      can look "stale" purely by basename match (see
        #      ImageConversionPipeline.ps1's own known gap), and must not
        #      be deleted before classification says it's safe to.
        #   2. Performance/responsiveness (Scenario Z4): classifying every chapter's avifs in ONE pass here,
        #      before this factory returns, would mean a huge series (the
        #      exact "100+ chapters, a few hundred avifs" case that fix was
        #      written for) blocks EVERY chapter's dispatch on classifying
        #      ALL of them first, reintroducing the tens-of-minutes-of-
        #      silence bug at per-SERIES granularity instead of per-
        #      LIBRARY. Get-OrCreateFullPipelineChapterClassification's own
        #      Lazy cache defers each chapter's own classification until
        #      whichever engine's JobBuilder actually reaches it, so
        #      chapter 1 can start converting while chapter 2's avifs are
        #      still unclassified.

        $inspectFailedCount = $imageCandidates.NamingCollisions.Count
        $namingCollisionDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($nc in $imageCandidates.NamingCollisions) { $null = $namingCollisionDirs.Add($nc.DirectoryName) }

        $imagesByDir = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[System.IO.FileInfo]]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($img in $imageCandidates.NeedsConversion) {
            if (-not $imagesByDir.ContainsKey($img.DirectoryName)) { $imagesByDir[$img.DirectoryName] = [System.Collections.Generic.List[System.IO.FileInfo]]::new() }
            $imagesByDir[$img.DirectoryName].Add($img)
        }
        $staleByDir = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[System.IO.FileInfo]]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($stale in $imageCandidates.StaleSources) {
            if (-not $staleByDir.ContainsKey($stale.DirectoryName)) { $staleByDir[$stale.DirectoryName] = [System.Collections.Generic.List[System.IO.FileInfo]]::new() }
            $staleByDir[$stale.DirectoryName].Add($stale)
        }
        $animatedByDir = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[System.IO.FileInfo]]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($af in $animatedCandidates) {
            if (-not $animatedByDir.ContainsKey($af.DirectoryName)) { $animatedByDir[$af.DirectoryName] = [System.Collections.Generic.List[System.IO.FileInfo]]::new() }
            $animatedByDir[$af.DirectoryName].Add($af)
        }

        $chapterEntries = [System.Collections.Generic.List[hashtable]]::new()
        $chapterDirSet  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($c in $chapters) {
            $null = $chapterDirSet.Add($c.Dir.FullName)
            $chImages   = @(); if ($imagesByDir.ContainsKey($c.Dir.FullName))   { $chImages   = @($imagesByDir[$c.Dir.FullName]) }
            $chAnimated = @(); if ($animatedByDir.ContainsKey($c.Dir.FullName)) { $chAnimated = @($animatedByDir[$c.Dir.FullName]) }
            $chStale    = @(); if ($staleByDir.ContainsKey($c.Dir.FullName))    { $chStale    = @($staleByDir[$c.Dir.FullName]) }
            $entry = @{
                SeriesName = $Series.Name; ChapterName = $c.Dir.Name; Dir = $c.Dir; ZipOut = $c.ZipOut
                IsZippable = $true; IsExtra = $false; Images = $chImages; AnimatedFiles = $chAnimated; StaleSources = $chStale
            }
            $chapterEntries.Add($entry)
            if ($namingCollisionDirs.Contains($c.Dir.FullName)) {
                Add-FullPipelineZipBlockReason -Dict $ZipBlockReasons -ChapterKey $entry -Reason "naming collision"
            }
        }
        $extraDirPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $imagesByDir.Keys)   { if (-not $chapterDirSet.Contains($k)) { $null = $extraDirPaths.Add($k) } }
        foreach ($k in $animatedByDir.Keys) { if (-not $chapterDirSet.Contains($k)) { $null = $extraDirPaths.Add($k) } }
        foreach ($extraDirPath in $extraDirPaths) {
            $extraDir = if ($imagesByDir.ContainsKey($extraDirPath)) { $imagesByDir[$extraDirPath][0].Directory } else { $animatedByDir[$extraDirPath][0].Directory }
            $chImages   = @(); if ($imagesByDir.ContainsKey($extraDirPath))   { $chImages   = @($imagesByDir[$extraDirPath]) }
            $chAnimated = @(); if ($animatedByDir.ContainsKey($extraDirPath)) { $chAnimated = @($animatedByDir[$extraDirPath]) }
            $chStale    = @(); if ($staleByDir.ContainsKey($extraDirPath))    { $chStale    = @($staleByDir[$extraDirPath]) }
            $chapterEntries.Add(@{
                SeriesName = $Series.Name; ChapterName = $extraDir.Name; Dir = $extraDir; ZipOut = $null
                IsZippable = $false; IsExtra = $true; Images = $chImages; AnimatedFiles = $chAnimated; StaleSources = $chStale
            })
            Write-Log ("Series '" + $Series.Name + "': '" + $extraDir.Name + "' has unconverted content but wasn't found by chapter discovery (e.g. a stray .zip sitting alongside it, or files outside a normal chapter folder) - converting it anyway, but NOT treating it as zippable.") -Level Warn
        }
        # A directory holding ONLY a stale leftover is excluded from
        # $extraDirPaths above (neither NeedsConversion nor animated), so
        # it would otherwise never reach the per-chapter stale-cleanup
        # loop below at all. No "converting it anyway" Warn for this case
        # (matches the old code) - stale-only extras are silent cleanup,
        # not unconverted content.
        foreach ($k in $staleByDir.Keys) {
            if ($chapterDirSet.Contains($k) -or $extraDirPaths.Contains($k)) { continue }
            $extraDir = $staleByDir[$k][0].Directory
            $chapterEntries.Add(@{
                SeriesName = $Series.Name; ChapterName = $extraDir.Name; Dir = $extraDir; ZipOut = $null
                IsZippable = $false; IsExtra = $true; Images = @(); AnimatedFiles = @(); StaleSources = @($staleByDir[$k])
            })
        }

        if ($chapterEntries.Count -gt 0) {
            Write-Log ("=== Series '" + $Series.Name + "': " + $chapterEntries.Count + " chapter(s) ===")
        } else {
            Write-Log ("Series '" + $Series.Name + "': no qualifying chapters found.") -Level Info
        }
        $EventQueue.Enqueue(@{
            Kind = 'SeriesReady'; SeriesName = $Series.Name; TotalChapters = $chapterEntries.Count
            InspectFailedCount = $inspectFailedCount
        })

        return @{ ChapterEntries = $chapterEntries }
    }.GetNewClosure()

    $freshLazy = [System.Lazy[hashtable]]::new([Func[hashtable]]$factory, [System.Threading.LazyThreadSafetyMode]::ExecutionAndPublication)
    $lazy = $Cache.GetOrAdd($Series.FullName, $freshLazy)
    return $lazy.Value
}

function Get-OrCreateFullPipelineChapterClassification {
    <#
    .SYNOPSIS
        Resolves ONE chapter's own AVIF ownership (which of its .avif
        files, if any, belong to the image engine vs the animated engine)
        and runs that chapter's own stale-source cleanup - lazily, on
        first access by whichever engine's own JobBuilder reaches this
        chapter FIRST (Lazy<T> with ExecutionAndPublication - same
        guarantee, same reasoning, as Get-OrCreateFullPipelineSeriesBundle
        above). Deliberately SEPARATE from that function (not folded into
        its own per-series factory) so a huge series' worth of chapters
        don't all have to be classified before the FIRST of them can
        dispatch - see Get-OrCreateFullPipelineSeriesBundle's own comment,
        right above where this used to run inline, for the regression
        this split fixes (caught by this module's
        own harness, Scenario Z4).
    .OUTPUTS
        @{ Images = List[FileInfo]; AnimatedFiles = List[FileInfo] } -
        both already filtered to whichever engine actually owns each file;
        an AVIF this run couldn't classify is excluded from BOTH lists
        (see Add-FullPipelineZipBlockReason, called here on a "Failed"
        classification).
    #>
    param(
        [Parameter(Mandatory)]
        [System.Collections.Concurrent.ConcurrentDictionary[object, System.Lazy[hashtable]]]$Cache,
        [Parameter(Mandatory)]
        [hashtable]$ChapterInfo,
        [string]$MagickExe,
        # NOT [Parameter(Mandatory)] - same PowerShell empty-array-rejection
        # quirk as Get-OrCreateFullPipelineSeriesBundle's own identically-
        # named param above (see that one's own comment).
        [string[]]$LooseImageExtensions,
        [Parameter(Mandatory)]
        [System.Collections.Concurrent.ConcurrentQueue[hashtable]]$EventQueue,
        [Parameter(Mandatory)]
        [System.Collections.Concurrent.ConcurrentDictionary[object,string]]$ZipBlockReasons
    )

    $factory = {
        if ($env:FP_DISPATCH_TRACE) { [Console]::Error.WriteLine("[TRACE $([DateTime]::Now.ToString('HH:mm:ss.fff')) tid=$([System.Threading.Thread]::CurrentThread.ManagedThreadId)] classification-factory ENTER " + $ChapterInfo.ChapterName) } # TEMP-TRACE
        $images       = $ChapterInfo.Images
        $animated     = $ChapterInfo.AnimatedFiles
        $staleSources = $ChapterInfo.StaleSources

        if ($MagickExe -and ($LooseImageExtensions -icontains ".avif") -and $animated.Count -gt 0) {
            $chAnimatedPathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($af in $animated) { $null = $chAnimatedPathSet.Add($af.FullName) }

            $chAvifClassification = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $inspectFailedCount = 0
            foreach ($img in (@($images) + @($staleSources))) {
                if (Test-AbortSignal) { break }
                if ($img.Extension -ine ".avif" -or -not $chAnimatedPathSet.Contains($img.FullName) -or $chAvifClassification.ContainsKey($img.FullName)) { continue }
                try {
                    if ($env:FP_DISPATCH_TRACE) { [Console]::Error.WriteLine("[TRACE $([DateTime]::Now.ToString('HH:mm:ss.fff')) tid=$([System.Threading.Thread]::CurrentThread.ManagedThreadId)] before Test-AvifAnimated " + $img.FullName) } # TEMP-TRACE
                    $isAnimated = Test-AvifAnimated -AvifPath $img.FullName -MagickExe $MagickExe
                    if ($env:FP_DISPATCH_TRACE) { [Console]::Error.WriteLine("[TRACE $([DateTime]::Now.ToString('HH:mm:ss.fff')) tid=$([System.Threading.Thread]::CurrentThread.ManagedThreadId)] after Test-AvifAnimated") } # TEMP-TRACE
                    $chAvifClassification[$img.FullName] = if ($isAnimated) { "Animated" } else { "Static" }
                } catch {
                    Write-Log ("Could not determine if AVIF '" + $img.FullName + "' is animated - excluding it from BOTH engines this run: " + $_) -Level Error
                    $inspectFailedCount++
                    $chAvifClassification[$img.FullName] = "Failed"
                }
            }
            if ($inspectFailedCount -gt 0) {
                $EventQueue.Enqueue(@{ Kind = 'ChapterInspectFailed'; Count = $inspectFailedCount })
            }

            if ($chAvifClassification.Count -gt 0) {
                # Static is safe to keep either way (safe to convert if in
                # Images, safe to delete as stale if in StaleSources, since
                # its own .jxl already exists); only Animated/Failed need
                # pulling OUT so the stale cleanup below doesn't delete a
                # file the animated engine (Animated) or neither engine
                # (Failed, ownership unresolved) should be touching.
                # Plain foreach, not Where-Object - Where-Object
                # is ALSO a real hang risk under the same runspace-race bug
                # LeafDirectoryDiscovery.ps1's Get-FilesRecursiveSafe/
                # Get-ZippableLeafDirs/Test-ZippableLeafDirCandidate were
                # fixed for (see those functions' own NOTES) - not just
                # filesystem cmdlets, ANY cmdlet's first invocation racing
                # across two runspaces is suspect. This factory runs inside
                # that exact same per-chapter race window.
                $keepIfStatic = { param($f) (-not $chAvifClassification.ContainsKey($f.FullName)) -or $chAvifClassification[$f.FullName] -eq "Static" }
                $newImages = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
                foreach ($f in $images) { if (& $keepIfStatic $f) { $newImages.Add($f) } }
                $images = $newImages
                $newStale = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
                foreach ($f in $staleSources) { if (& $keepIfStatic $f) { $newStale.Add($f) } }
                $staleSources = $newStale
                $newAnimated = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
                foreach ($f in $animated) {
                    if ((-not $chAvifClassification.ContainsKey($f.FullName)) -or $chAvifClassification[$f.FullName] -eq "Animated") { $newAnimated.Add($f) }
                }
                $animated = $newAnimated
                foreach ($avifEntry in $chAvifClassification.GetEnumerator()) {
                    if ($avifEntry.Value -eq "Failed") {
                        Add-FullPipelineZipBlockReason -Dict $ZipBlockReasons -ChapterKey $ChapterInfo -Reason "AVIF classification failure"
                    }
                }
            }
        }

        # Re-checked here, not just inside the classification loop above -
        # an abort raised
        # mid-classification must also stop THIS chapter's own stale-
        # source deletion from running at all, not just stop classifying
        # further contested files.
        if ($staleSources.Count -gt 0 -and -not (Test-AbortSignal)) {
            $chStaleResult = Remove-StaleLooseSources -StaleSources $staleSources
            $EventQueue.Enqueue(@{ Kind = 'ChapterStaleCleanup'; Success = $chStaleResult.Success; Fail = $chStaleResult.Fail })
        }

        if ($env:FP_DISPATCH_TRACE) { [Console]::Error.WriteLine("[TRACE $([DateTime]::Now.ToString('HH:mm:ss.fff')) tid=$([System.Threading.Thread]::CurrentThread.ManagedThreadId)] classification-factory EXIT " + $ChapterInfo.ChapterName) } # TEMP-TRACE
        return @{ Images = $images; AnimatedFiles = $animated }
    }.GetNewClosure()

    $freshLazy = [System.Lazy[hashtable]]::new([Func[hashtable]]$factory, [System.Threading.LazyThreadSafetyMode]::ExecutionAndPublication)
    $lazy = $Cache.GetOrAdd($ChapterInfo, $freshLazy)
    if ($env:FP_DISPATCH_TRACE) { [Console]::Error.WriteLine("[TRACE $([DateTime]::Now.ToString('HH:mm:ss.fff')) tid=$([System.Threading.Thread]::CurrentThread.ManagedThreadId)] before lazy.Value " + $ChapterInfo.ChapterName) } # TEMP-TRACE
    $result = $lazy.Value
    if ($env:FP_DISPATCH_TRACE) { [Console]::Error.WriteLine("[TRACE $([DateTime]::Now.ToString('HH:mm:ss.fff')) tid=$([System.Threading.Thread]::CurrentThread.ManagedThreadId)] after lazy.Value") } # TEMP-TRACE
    return $result
}

function Complete-MergedFullPipelineChapter {
    <#
    .SYNOPSIS
        Merges an image ChapterResult and an animated ChapterResult (each
        possibly $null - nothing to convert for that engine this chapter)
        into one Status/Detail via Get-MergedChapterStatus, then zips the
        chapter (Compress-FolderToZip/Test-ZipArchive directly - see this
        module's own header for why not Invoke-LooseFolderZip) if
        -IsZippable and neither engine reported an Error-tier failure.
        DOCUMENTED DUPLICATE of nothing - this is the exact same merge/zip
        decision the old, single-threaded Invoke-FullPipelineChapter made
        after its own per-chapter dispatch returned (that function's own
        lines after both engines' results were known), extracted into its
        own function now that dispatch and merge happen on different
        threads/at different times (Invoke-ChapterDispatch calls this
        chapter's own JobFinalize/ChapterCompleteCallback from inside a
        worker runspace; only the MAIN thread, draining -EventQueue, can
        safely call this). The old function's own synthetic "engine never
        returned a result - treat as a crash" detection is NOT carried
        over - it existed only to cover the old per-chapter
        Invoke-ZipParallelProcessing call's own silent-crash/force-stop
        case, which has no equivalent here: Invoke-ChapterDispatch's own
        JobFinalize/ChapterCompleteCallback contract means a genuine
        JobStarter failure is already counted into that engine's own
        ChapterResult.FailedCount directly, and a chapter still in flight
        when the run is aborted simply never reaches this function at all
        (self-healing on the next run, same as every other loose file left
        mid-conversion - see the old code's own identical reasoning, still
        true here).
    .OUTPUTS
        @{ ImageResult; AnimatedResult; Status; Detail; Zipped; ZipResult }
        - ZipResult is @{ Status; ZipSize; EntryCount; FolderDeleted;
        FolderDeleteFailed }, or $null if Zipped is $false.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ChapterDir,
        [string]$ZipOut = $null,
        [bool]$IsZippable = $false,
        [hashtable]$ImageResult = $null,
        [hashtable]$AnimatedResult = $null,
        [Parameter(Mandatory)]
        [System.Threading.CancellationTokenSource]$Cts
    )

    $status, $detail = Get-MergedChapterStatus -ImageResult $ImageResult -AnimatedResult $AnimatedResult

    $zipped    = $false
    $zipResult = $null
    if ($IsZippable -and $status -ne 'Error' -and -not $Cts.Token.IsCancellationRequested) {
        # Compress-FolderToZip/Test-ZipArchive directly, NOT
        # Invoke-LooseFolderZip - see this module's own header, "ZIP-
        # BLOCKING POLICY", for the full .webp-collision reasoning.
        $zipResult = @{ Status = $null; ZipSize = 0; EntryCount = 0; FolderDeleted = $false; FolderDeleteFailed = $false }
        try {
            $orphanedScratchFiles = @(Get-ChildItem -LiteralPath $ChapterDir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { Test-OrphanedScratchFileName -Name $_.Name })
            foreach ($orphan in $orphanedScratchFiles) {
                try {
                    [System.IO.File]::Delete($orphan.FullName)
                    Write-Log ("Deleted orphaned scratch file (its owning cleanup could not run earlier): '" + $orphan.FullName + "'") -Level Warn
                } catch {
                    Write-Log ("Could not delete orphaned scratch file '" + $orphan.FullName + "' - it will be archived into this chapter's zip: " + $_) -Level Error
                }
            }

            Write-Log ("Zipping '" + $ChapterDir + "' -> '" + $ZipOut + "'")
            $zipSize = Compress-FolderToZip -SourceDir $ChapterDir -ZipOut $ZipOut
            $imageActuallyConverted = ($null -ne $ImageResult -and $ImageResult.ConvertedCount -gt 0)
            $verify  = Test-ZipArchive -ZipPath $ZipOut -RequireJxlEntry $imageActuallyConverted

            Write-Log ("ZIP OK: '" + $ZipOut + "' (" + $zipSize + " bytes, " + $verify.EntryCount + " entries)")
            $zipResult.Status     = 'Success'
            $zipResult.ZipSize    = $zipSize
            $zipResult.EntryCount = $verify.EntryCount

            try {
                $removed = Remove-Source -ItemPath $ChapterDir
                if ($removed) {
                    $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
                    Write-Log ("Deleted folder (" + $deleteDesc + "): '" + $ChapterDir + "'")
                    $zipResult.FolderDeleted = $true
                } else {
                    Write-Log ("Folder already gone before deletion (not counted as deleted): '" + $ChapterDir + "'") -Level Warn
                }
            } catch {
                Write-Log ("FAILED to delete folder '" + $ChapterDir + "': " + $_) -Level Error
                $zipResult.FolderDeleteFailed = $true
            }
        } catch {
            Write-Log ("FAILED to zip '" + $ChapterDir + "': " + $_) -Level Error
            $zipResult.Status = 'Fail'
            try {
                if (Test-Path -LiteralPath $ZipOut) { [System.IO.File]::Delete($ZipOut) }
            } catch { }
        }
        $zipped = $true
    }

    return @{
        ImageResult    = $ImageResult
        AnimatedResult = $AnimatedResult
        Status         = $status
        Detail         = $detail
        Zipped         = $zipped
        ZipResult      = $zipResult
    }
}

function Get-MergedChapterStatus {
    <#
    .SYNOPSIS
        Merges an image ChapterResult and an animated ChapterResult (each
        possibly $null - nothing to convert for that engine this
        chapter) into ONE Status/Detail pair for Complete-ChapterProgress -
        concatenates both engines' own
        sub-summaries into one Detail string, Status is whichever of the
        two is worse (Error > Warning > Success). Reuses
        Get-ChapterProgressStatus/Get-ChapterAnimatedStatus directly -
        not a third copy of that severity logic.
    .OUTPUTS
        Two values: Status ("Success"/"Warning"/"Error"), Detail (string,
        or $null when both engines are clean).
    #>
    param(
        [hashtable]$ImageResult,
        [hashtable]$AnimatedResult
    )

    $imgStatus, $imgDetail   = Get-ChapterProgressStatus -ChapterResult $ImageResult
    $animStatus, $animDetail = Get-ChapterAnimatedStatus -ChapterResult $AnimatedResult

    $rank = @{ Success = 0; Warning = 1; Error = 2 }
    $mergedStatus = if ($rank[$animStatus] -gt $rank[$imgStatus]) { $animStatus } else { $imgStatus }

    $parts = [System.Collections.Generic.List[string]]::new()
    if ($imgDetail)  { $parts.Add("Image: " + $imgDetail) }
    if ($animDetail) { $parts.Add("Animated: " + $animDetail) }

    if ($parts.Count -eq 0) { return $mergedStatus, $null }
    return $mergedStatus, ($parts -join " | ")
}

# Get-ZipBlockedStatusOverride is NOT redefined here - it used to be a
# "documented duplicate" of
# ImageConversionPipeline.ps1's own copy, but both files are dot-sourced
# into the same script scope on every real run (and in this module's own
# harness, which dot-sources ImageConversionPipeline.ps1 before
# Controller.ps1), so two same-named function definitions don't coexist -
# whichever is dot-sourced LAST silently wins for every caller in the
# session, making the "other" copy dead code that only its own harness
# ever actually exercised. Since Controller.ps1 already unconditionally
# depends on ImageConversionPipeline.ps1 being loaded first (see the
# dot-source order both here and in Controller.Harness.ps1), the single
# real definition lives there instead - see that file's own copy for the
# full docstring.

# ---- Shared worker scriptblock, dispatched via Invoke-ZipParallelProcessing -
#      exactly ONE job per real caller (this file's Invoke-FullPipeline
#      dispatches exactly 2: one 'Image', one 'Animated'), each running its
#      OWN Invoke-ChapterDispatch across the WHOLE library for its own file
#      type, concurrently, sharing one process budget. Replaces the old
#      per-chapter $script:fullPipelineChapterWorker (dispatched once PER
#      CHAPTER, blocking) - see this module's own "DISPATCH-REDESIGN STEP 4"
#      header comment above Get-OrCreateFullPipelineSeriesBundle for the
#      full design. Must declare CancelToken/LogMutex/ConsoleQueue per ZPP's
#      own contract, plus everything both engines' own closures need. ----
$script:fullPipelineEngineWorker = {
    param(
        [string]$EngineType,
        [string]$Path,
        [string]$CjxlExe,
        [string]$MagickExe,
        [bool]$DoJpegLossless,
        [int]$DoJpegQuality = 90,
        [bool]$DoAnimatedLossless,
        [int]$AnimatedQuality = 90,
        [bool]$DoAnimatedOverwrite,
        [bool]$DoAnimatedDeleteSource = $true,
        [bool]$DoFullLogging,
        [string]$LogFile,
        [string]$LogErrorFile,
        [string]$LogWarnFile,
        [bool]$DoPermanentDelete,
        [bool]$CleanConsoleOutputEnabled,
        [System.Threading.SemaphoreSlim]$SharedBudget,
        [System.Collections.Concurrent.ConcurrentDictionary[string, System.Lazy[hashtable]]]$SeriesBundleCache,
        [System.Collections.Concurrent.ConcurrentDictionary[object, System.Lazy[hashtable]]]$ChapterClassificationCache,
        [System.Collections.Concurrent.ConcurrentDictionary[object,string]]$ZipBlockReasons,
        [System.Collections.Concurrent.ConcurrentDictionary[object,byte]]$AnnouncedChapters,
        [System.Collections.Concurrent.ConcurrentQueue[hashtable]]$EventQueue,
        [string[]]$LooseImageExtensions,
        [string[]]$AnimatedFileExtensions,
        [string[]]$KnownZipPaths,
        [string[]]$FolderQualifyingExtensions,
        [System.Collections.Generic.HashSet[string]]$FolderExcludeStagingDirs,
        [int]$AbortTimeoutSeconds,
        [int]$MaxQueueAhead,
        [System.Threading.Mutex]$LogMutex,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ConsoleQueue,
        [System.Threading.CancellationToken]$CancelToken
    )

    # Same fresh-runspace bootstrap as every other Invoke-ZipParallelProcessing
    # worker in this codebase - see the old $script:fullPipelineChapterWorker's
    # own identical comments for why each of these is needed.
    $null = [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.VisualBasic")
    $script:logMutex                  = $LogMutex
    $script:workerConsoleQueue        = $ConsoleQueue
    $script:FullLogging               = $DoFullLogging
    $script:logFile                   = $LogFile
    $script:logErrorFile              = $LogErrorFile
    $script:logWarnFile               = $LogWarnFile
    $script:PermanentDelete           = $DoPermanentDelete
    $script:CleanConsoleOutputEnabled = $CleanConsoleOutputEnabled

    $seriesProvider  = New-SeriesProvider -LibraryPath $Path
    $chapterQueue    = [System.Collections.Generic.Queue[hashtable]]::new()
    $seriesExhausted = $false

    # -ChapterProvider: shared with the OTHER engine's own instance of this
    # same worker only via $SeriesBundleCache (see
    # Get-OrCreateFullPipelineSeriesBundle's own header) - each engine still
    # walks -SeriesProvider independently, so an idle engine keeps pulling
    # ahead into the NEXT series without waiting on the other engine at all.
    $chapterProvider = {
        while ($chapterQueue.Count -eq 0 -and -not $seriesExhausted) {
            if (Test-AbortSignal) { $seriesExhausted = $true; break }
            $series = & $seriesProvider
            if ($null -eq $series) { $seriesExhausted = $true; break }

            if ($env:FP_DISPATCH_TRACE) { [Console]::Error.WriteLine("[TRACE $([DateTime]::Now.ToString('HH:mm:ss.fff')) tid=$([System.Threading.Thread]::CurrentThread.ManagedThreadId) engine=$EngineType] before Get-OrCreateFullPipelineSeriesBundle " + $series.Name) } # TEMP-TRACE
            $bundle = Get-OrCreateFullPipelineSeriesBundle -Cache $SeriesBundleCache -Series $series -MagickExe $MagickExe `
                -LooseImageExtensions $LooseImageExtensions -AnimatedFileExtensions $AnimatedFileExtensions -KnownZipPaths $KnownZipPaths `
                -FolderQualifyingExtensions $FolderQualifyingExtensions -FolderExcludeStagingDirs $FolderExcludeStagingDirs `
                -EventQueue $EventQueue -ZipBlockReasons $ZipBlockReasons
            if ($env:FP_DISPATCH_TRACE) { [Console]::Error.WriteLine("[TRACE $([DateTime]::Now.ToString('HH:mm:ss.fff')) tid=$([System.Threading.Thread]::CurrentThread.ManagedThreadId) engine=$EngineType] after Get-OrCreateFullPipelineSeriesBundle, chapters=" + $bundle.ChapterEntries.Count) } # TEMP-TRACE

            foreach ($entry in $bundle.ChapterEntries) { $chapterQueue.Enqueue($entry) }
        }
        if ($chapterQueue.Count -gt 0) { return $chapterQueue.Dequeue() }
        return $null
    }.GetNewClosure()

    # Per-chapter accumulator, keyed by the exact chapterInfo object each
    # -ChapterProvider call above returned (the SAME object both engines'
    # own workers may hold a reference to, for a chapter neither engine's
    # own scan skipped) - matches ChapterDispatch.ps1's own chapter-identity
    # contract. Built by JobBuilder, mutated by JobStarter/JobFinalize, read
    # and removed by ChapterCompleteCallback - all scoped to just THIS
    # worker's own engine; the OTHER engine has its own, separate instance
    # of this same dictionary inside its own worker call.
    $chapterResults = [System.Collections.Generic.Dictionary[object,hashtable]]::new()

    if ($EngineType -eq 'Image') {
        # --- JobBuilder: near-verbatim port of
        #     ImageConversionPipeline.ps1's own mode-2 JobBuilder - see that
        #     function's own header for why this was already a clean
        #     pre-pass, nothing to restructure. Reads .Images (this entry's
        #     own post-AVIF-classification image list, already resolved by
        #     Get-OrCreateFullPipelineSeriesBundle) instead of scanning for
        #     WebP/AVIF status itself for AVIF specifically - WebP still
        #     needs its own Test-WebPAnimated check here (not part of AVIF
        #     classification). Does NOT call Start-ChapterProgress directly
        #     (unlike mode 2's own JobBuilder) - this worker runs inside a
        #     runspace, and CCR is main-thread-only (see this module's own
        #     header) - enqueues a 'ChapterStarted' event instead, guarded
        #     by $AnnouncedChapters so only whichever engine reaches a given
        #     chapter FIRST announces it once, not twice. ---
        $jobBuilder = {
            param($chapterInfo)
            # Resolves THIS chapter's own AVIF ownership + stale-source
            # cleanup lazily, on whichever engine's JobBuilder reaches it
            # first - see Get-OrCreateFullPipelineChapterClassification's
            # own header for why this is a separate, per-chapter cache
            # rather than folded into Get-OrCreateFullPipelineSeriesBundle.
            if ($env:FP_DISPATCH_TRACE) { [Console]::Error.WriteLine("[TRACE $([DateTime]::Now.ToString('HH:mm:ss.fff')) tid=$([System.Threading.Thread]::CurrentThread.ManagedThreadId) engine=image] before classification " + $chapterInfo.ChapterName) } # TEMP-TRACE
            $classified = Get-OrCreateFullPipelineChapterClassification -Cache $ChapterClassificationCache -ChapterInfo $chapterInfo `
                -MagickExe $MagickExe -LooseImageExtensions $LooseImageExtensions -EventQueue $EventQueue -ZipBlockReasons $ZipBlockReasons
            if ($env:FP_DISPATCH_TRACE) { [Console]::Error.WriteLine("[TRACE $([DateTime]::Now.ToString('HH:mm:ss.fff')) tid=$([System.Threading.Thread]::CurrentThread.ManagedThreadId) engine=image] after classification") } # TEMP-TRACE

            $cr = @{
                ConvertedCount = 0; FailedCount = 0; SkippedCount = 0; DeletedCount = 0; DeleteFailedCount = 0
                InspectFailedCount = 0
                SkippedPaths = [System.Collections.Generic.List[string]]::new()
                TotalFiles = $classified.Images.Count
            }
            $chapterResults[$chapterInfo] = $cr

            if ($AnnouncedChapters.TryAdd($chapterInfo, 0)) {
                $EventQueue.Enqueue(@{ Kind = 'ChapterStarted'; SeriesName = $chapterInfo.SeriesName; ChapterName = $chapterInfo.ChapterName })
            }

            if ($cr.TotalFiles -eq 0) { return @() }
            Write-Log ("Processing chapter (image engine): '" + $chapterInfo.Dir.FullName + "' (" + $cr.TotalFiles + " image(s))")

            $allJobs = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($img in $classified.Images) {
                $srcPath = $img.FullName
                if ((Get-NeverConvertedExtensions) -icontains [System.IO.Path]::GetExtension($srcPath)) {
                    Write-Log ("SKIPPING '" + $srcPath + "': not converted by this project (see Get-NeverConvertedExtensions's own comment for why). File left untouched.") -Level Warn
                    $cr.SkippedCount++
                    $cr.SkippedPaths.Add($srcPath)
                    continue
                }
                if ($MagickExe -and $srcPath -imatch '\.webp$') {
                    $isAnimatedWebp = $false
                    try {
                        $isAnimatedWebp = Test-WebPAnimated -WebPPath $srcPath
                    } catch {
                        Write-Log ("FAILED to read '" + $srcPath + "' to check for WebP animation: " + $_) -Level Error
                        $cr.FailedCount++
                        continue
                    }
                    if ($isAnimatedWebp) {
                        Write-Log ("SKIPPING animated WebP '" + $srcPath + "': Animation flag set in VP8X chunk - animated WebP cannot be converted to JXL (no multi-frame support). File left untouched.") -Level Warn
                        $cr.SkippedCount++
                        $cr.SkippedPaths.Add($srcPath)
                        continue
                    }
                }
                # No AVIF branch here (unlike mode 2's own JobBuilder) -
                # Get-OrCreateFullPipelineSeriesBundle already resolved AVIF
                # ownership for the whole chapter before this ever ran; an
                # AVIF reaching .Images here is already known-Static.
                $allJobs.Add(@{
                    SrcPath = $srcPath
                    JxlPath = [System.IO.Path]::ChangeExtension($srcPath, ".jxl")
                    Proc    = $null
                    TempPng = $null
                })
            }

            $jxlPathCounts = [System.Collections.Generic.Dictionary[string,int]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($j in $allJobs) {
                if ($jxlPathCounts.ContainsKey($j.JxlPath)) { $jxlPathCounts[$j.JxlPath]++ } else { $jxlPathCounts[$j.JxlPath] = 1 }
            }
            $jobs = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($j in $allJobs) {
                if ($jxlPathCounts[$j.JxlPath] -gt 1) {
                    Write-Log ("SKIPPING '" + $j.SrcPath + "': output path '" + $j.JxlPath + "' collides with another source image of the same name (different extension). Resolve the name clash manually.") -Level Error
                    $cr.FailedCount++
                } else {
                    $jobs.Add($j)
                }
            }
            return $jobs
        }.GetNewClosure()

        # --- JobStarter: near-verbatim port of mode 2's own JobStarter
        #     (WebP/BMP/HEIC/HEIF pre-conversion via magick, then cjxl
        #     dispatch) - kept separate from JobBuilder for the same
        #     interleaving reason mode 2's own migration already
        #     documented. ---
        $jobStarter = {
            param($job)
            $cr = $chapterResults[$job.ChapterKey]
            $tempPngLocal = $null
            $magickProcLocal = $null
            $failureAlreadyAccounted = $false
            try {
                # [System.Diagnostics.ProcessStartInfo]::new(), not
                # New-Object - a real bug found live-catching a
                # Controller.Harness.ps1 hang with NO subprocess alive at
                # all - ruling out every prior "magick.exe/cjxl.exe itself
                # hung" theory and pointing at pure PowerShell-side code
                # instead). New-Object is a cmdlet like any other, and this
                # is the FIRST cmdlet call of any kind in each engine's
                # JobStarter - called for the very first time in each
                # engine's own fresh worker runspace, on literally the very
                # first job either engine ever dispatches, with both
                # engines' first dispatch landing within milliseconds of
                # each other (Invoke-ZipParallelProcessing starts both
                # runspaces back to back). Same species as the
                # cmdlet-first-invocation-in-a-fresh-runspace race already
                # fixed for Test-Path/Get-ChildItem/Where-Object/
                # Sort-Object/Select-Object/Join-Path/Get-Item (see
                # LeafDirectoryDiscovery.ps1's functions' own NOTES) - never
                # audited for New-Object specifically before now, despite it
                # running on literally every single conversion job in both
                # engines.
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName               = $CjxlExe
                $psi.UseShellExecute        = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $psi.CreateNoWindow         = $true

                $isWebp = ($job.SrcPath -imatch '\.webp$')
                $isAvif = ($job.SrcPath -imatch '\.avif$')
                $isBmp  = ($job.SrcPath -imatch '\.bmp$')
                $isHeic = ($job.SrcPath -imatch '\.heic$')
                $isHeif = ($job.SrcPath -imatch '\.heif$')
                if ($job.TempPng) {
                    $cjxlSrc = $job.TempPng
                } elseif ($isWebp -or $isAvif -or $isBmp -or $isHeic -or $isHeif) {
                    $formatLabel = if ($isAvif) { "AVIF" } elseif ($isWebp) { "WebP" } elseif ($isBmp) { "BMP" } elseif ($isHeic) { "HEIC" } else { "HEIF" }
                    if (-not $MagickExe) {
                        Write-Log ("SKIPPING " + $formatLabel + " '" + $job.SrcPath + "': ImageMagick not found. Install ImageMagick or pass -MagickPath.") -Level Error
                        $cr.FailedCount++
                        $failureAlreadyAccounted = $true
                        throw ("ImageMagick not found for " + $formatLabel + " pre-conversion")
                    }

                    $tempPng = [System.IO.Path]::Combine(
                        [System.IO.Path]::GetDirectoryName($job.SrcPath),
                        [System.IO.Path]::GetFileNameWithoutExtension($job.SrcPath) + "_tmp_" + $formatLabel.ToLowerInvariant() + "2png.png"
                    )
                    $tempPngLocal = $tempPng
                    # [System.Diagnostics.ProcessStartInfo]::new(), not
                    # New-Object - same fix, same reasoning, as this
                    # JobStarter's own $psi above.
                    $magickPsi = [System.Diagnostics.ProcessStartInfo]::new()
                    $magickPsi.FileName               = $MagickExe
                    $magickPsi.Arguments              = "`"" + $job.SrcPath + "[0]`" `"" + $tempPng + "`""
                    $magickPsi.UseShellExecute        = $false
                    $magickPsi.RedirectStandardOutput = $true
                    $magickPsi.RedirectStandardError  = $true
                    $magickPsi.CreateNoWindow         = $true
                    $magickProc = [System.Diagnostics.Process]::Start($magickPsi)
                    $magickProcLocal = $magickProc
                    $magickStdoutTask = $magickProc.StandardOutput.ReadToEndAsync()
                    $magickStderrTask = $magickProc.StandardError.ReadToEndAsync()
                    # Raw OS handle wait, not WaitForExit (same race as
                    # Test-AvifAnimated - see
                    # full-pipeline-hang-investigation.md). This is the
                    # image engine's own inline magick pre-conversion for
                    # WebP/AVIF/BMP/HEIC/HEIF, running inside a fresh
                    # worker runspace.
                    $preConvWaitHandle = [System.Threading.ManualResetEvent]::new($false)
                    $preConvOrigHandle = $preConvWaitHandle.SafeWaitHandle
                    $preConvWaitHandle.SafeWaitHandle = (
                        [Microsoft.Win32.SafeHandles.SafeWaitHandle]::new(
                            $magickProc.Handle, $false
                        )
                    )
                    try {
                        $preConvExited = $preConvWaitHandle.WaitOne(120000)
                    } finally {
                        $preConvWaitHandle.SafeWaitHandle = $preConvOrigHandle
                        $preConvWaitHandle.Dispose()
                    }
                    if (-not $preConvExited) {
                        try { $magickProc.Kill() } catch { }
                        [System.Threading.Thread]::Sleep(200)
                        $magickProc.Dispose()
                        $magickProcLocal = $null
                        throw ("magick pre-conversion did not exit within 120s - killed")
                    }
                    $null = $magickStdoutTask.GetAwaiter().GetResult()
                    $null = $magickStderrTask.GetAwaiter().GetResult()
                    $magickExitCode = $magickProc.ExitCode
                    $magickProc.Dispose()
                    $magickProcLocal = $null
                    # [System.IO.File]::Exists, not Test-Path - this whole JobStarter is
                    # the hot per-file path for Full Pipeline's image
                    # engine, called from inside a fresh worker runspace -
                    # an unswept instance of the same
                    # cmdlet-first-invocation-in-a-fresh-runspace race
                    # LeafDirectoryDiscovery.ps1's functions were fixed for
                    # (see those functions' own NOTES) - a sibling Test-Path
                    # a few lines below this one (the animated engine's own
                    # webp-exists check) was already converted for exactly
                    # this reason; these four were missed at the time.
                    if ($magickExitCode -ne 0 -or -not [System.IO.File]::Exists($tempPng)) {
                        Write-Log ("FAILED " + $formatLabel + "->PNG pre-conversion for '" + $job.SrcPath + "': magick exited " + $magickExitCode) -Level Error
                        $cr.FailedCount++
                        $failureAlreadyAccounted = $true
                        if ([System.IO.File]::Exists($tempPng)) { try { [System.IO.File]::Delete($tempPng) } catch { } }
                        throw ($formatLabel + "->PNG pre-conversion failed")
                    }
                    $job.TempPng = $tempPng
                    $cjxlSrc     = $tempPng
                } else {
                    $job.TempPng = $null
                    $cjxlSrc     = $job.SrcPath
                }

                $isJpeg = ($cjxlSrc -imatch '\.jpe?g$')
                if ($isJpeg -and $DoJpegLossless) {
                    $psi.Arguments = "`"" + $cjxlSrc + "`" `"" + $job.JxlPath + "`" --lossless_jpeg=1 --num_threads=1"
                } elseif ($isJpeg) {
                    $psi.Arguments = "`"" + $cjxlSrc + "`" `"" + $job.JxlPath + "`" --lossless_jpeg=0 --quality=$DoJpegQuality --num_threads=1"
                } else {
                    $psi.Arguments = "`"" + $cjxlSrc + "`" `"" + $job.JxlPath + "`" --lossless_jpeg=0 --quality=90 --num_threads=1"
                }

                Write-Log ("Converting loose image: '" + $job.SrcPath + "'")

                $job.Proc       = [System.Diagnostics.Process]::Start($psi)
                $job.StdoutTask = $job.Proc.StandardOutput.ReadToEndAsync()
                $job.StderrTask = $job.Proc.StandardError.ReadToEndAsync()
                return $job
            } catch {
                if (-not $failureAlreadyAccounted) {
                    Write-Log ("FAILED to start conversion process for '" + $job.SrcPath + "': " + $_) -Level Error
                    $cr.FailedCount++
                }
                if ($magickProcLocal) { try { if (-not $magickProcLocal.HasExited) { $magickProcLocal.Kill() }; $magickProcLocal.Dispose() } catch { } }
                if ($job.TempPng -and [System.IO.File]::Exists($job.TempPng)) { try { [System.IO.File]::Delete($job.TempPng) } catch { } }
                elseif ($tempPngLocal -and [System.IO.File]::Exists($tempPngLocal)) { try { [System.IO.File]::Delete($tempPngLocal) } catch { } }
                throw
            }
        }.GetNewClosure()

        $jobPollCompleted = { param($job) return $job.Proc.HasExited }

        $jobFinalize = {
            param($job, $pendingQueue)
            $cr = $chapterResults[$job.ChapterKey]
            return Complete-ImageDispatchJob -Job $job -ChapterResult $cr -PendingQueue $pendingQueue -MagickExe $MagickExe -DoFullLogging $DoFullLogging -ItemNoun "loose image" -SourceNoun "loose source image"
        }.GetNewClosure()

        $jobAbortCleanup = {
            param($job)
            if ($job.TempPng) { try { [System.IO.File]::Delete($job.TempPng) } catch { } }
            try { [System.IO.File]::Delete($job.JxlPath) } catch { }
        }
    } else {
        # --- Animated engine: near-verbatim port of
        #     AnimatedConversionPipeline.ps1's own mode-3 JobBuilder/
        #     JobStarter/JobFinalize - same shape as the image engine
        #     above, reading .AnimatedFiles instead of .Images, no AVIF
        #     classification of its own (already resolved by
        #     Get-OrCreateFullPipelineSeriesBundle). ---
        $jobBuilder = {
            param($chapterInfo)
            # Same per-chapter lazy classification as the image engine's
            # own JobBuilder above - see that one's own comment.
            if ($env:FP_DISPATCH_TRACE) { [Console]::Error.WriteLine("[TRACE $([DateTime]::Now.ToString('HH:mm:ss.fff')) tid=$([System.Threading.Thread]::CurrentThread.ManagedThreadId) engine=animated] before classification " + $chapterInfo.ChapterName) } # TEMP-TRACE
            $classified = Get-OrCreateFullPipelineChapterClassification -Cache $ChapterClassificationCache -ChapterInfo $chapterInfo `
                -MagickExe $MagickExe -LooseImageExtensions $LooseImageExtensions -EventQueue $EventQueue -ZipBlockReasons $ZipBlockReasons
            if ($env:FP_DISPATCH_TRACE) { [Console]::Error.WriteLine("[TRACE $([DateTime]::Now.ToString('HH:mm:ss.fff')) tid=$([System.Threading.Thread]::CurrentThread.ManagedThreadId) engine=animated] after classification") } # TEMP-TRACE

            $cr = @{
                ConvertedCount = 0; FailedCount = 0; SkippedCount = 0; StaticSkippedCount = 0
                InspectFailedCount = 0; DeletedCount = 0; DeleteFailedCount = 0
                SkippedPaths = [System.Collections.Generic.List[string]]::new()
                StaticSkippedPaths = [System.Collections.Generic.List[string]]::new()
                TotalFiles = $classified.AnimatedFiles.Count
            }
            $chapterResults[$chapterInfo] = $cr

            if ($AnnouncedChapters.TryAdd($chapterInfo, 0)) {
                $EventQueue.Enqueue(@{ Kind = 'ChapterStarted'; SeriesName = $chapterInfo.SeriesName; ChapterName = $chapterInfo.ChapterName })
            }

            if ($cr.TotalFiles -eq 0) { return @() }
            Write-Log ("Processing chapter (animated engine): '" + $chapterInfo.Dir.FullName + "' (" + $cr.TotalFiles + " animated file(s))")

            $jobs = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($f in $classified.AnimatedFiles) {
                $srcPath  = $f.FullName
                $webpPath = [System.IO.Path]::ChangeExtension($srcPath, ".webp")

                # [System.IO.File]::Exists, not Test-Path -
                # same reasoning as LeafDirectoryDiscovery.ps1's NOTES -
                # this runs once per animated file, on the very first
                # chapter either engine dispatches, right after both
                # engines' own series-bundle discovery succeeds - a real
                # candidate for the same runspace-race hang.
                $webpPathExists = [System.IO.File]::Exists($webpPath)
                if ($webpPathExists -and -not $DoAnimatedOverwrite) {
                    Write-Log ("SKIPPING '" + $srcPath + "': output '" + $webpPath + "' already exists (Overwrite is off).")
                    $cr.SkippedCount++
                    $cr.SkippedPaths.Add($srcPath)
                    continue
                }
                # No Test-AvifAnimated call here (unlike mode 3's own
                # JobBuilder) - an AVIF reaching .AnimatedFiles here is
                # already known-Animated, resolved once for the whole
                # chapter by Get-OrCreateFullPipelineSeriesBundle.

                $tempOverwritePath = if ($webpPathExists) {
                    [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($webpPath), [System.IO.Path]::GetFileNameWithoutExtension($webpPath) + "_tmp_overwrite.webp")
                } else {
                    $null
                }
                $magickOutputPath = if ($tempOverwritePath) { $tempOverwritePath } else { $webpPath }

                $jobs.Add(@{
                    SrcPath = $srcPath; WebpPath = $webpPath
                    TempOverwritePath = $tempOverwritePath; MagickOutputPath = $magickOutputPath
                    Proc = $null
                })
            }
            return $jobs
        }.GetNewClosure()

        $jobStarter = {
            param($job)
            # [System.Diagnostics.ProcessStartInfo]::new(), not New-Object -
            # same fix, same reasoning, as the image engine's own JobStarter
            # above (this is the animated engine's own first-dispatch
            # equivalent).
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $MagickExe
            $qualityArg = if ($DoAnimatedLossless) { "-define webp:lossless=true" } else { "-quality " + $AnimatedQuality }
            $psi.Arguments = "`"" + $job.SrcPath + "`" -coalesce -loop 0 " + $qualityArg + " `"" + $job.MagickOutputPath + "`""
            $psi.UseShellExecute        = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow         = $true

            Write-Log ("Converting animated: '" + $job.SrcPath + "'")

            $job.Proc       = [System.Diagnostics.Process]::Start($psi)
            $job.StdoutTask = $job.Proc.StandardOutput.ReadToEndAsync()
            $job.StderrTask = $job.Proc.StandardError.ReadToEndAsync()
            return $job
        }.GetNewClosure()

        $jobPollCompleted = { param($job) return $job.Proc.HasExited }

        $jobFinalize = {
            param($job, $pendingQueue)
            $cr = $chapterResults[$job.ChapterKey]
            return Complete-AnimatedDispatchJob -Job $job -ChapterResult $cr -DoFullLogging $DoFullLogging -DoAnimatedDeleteSource $DoAnimatedDeleteSource
        }.GetNewClosure()

        $jobAbortCleanup = {
            param($job)
            if ($job.TempOverwritePath) { try { [System.IO.File]::Delete($job.TempOverwritePath) } catch { } }
            try { [System.IO.File]::Delete($job.MagickOutputPath) } catch { }
        }
    }

    # --- ChapterCompleteCallback: shared shape for both engines - neither
    #     may call CCR/zip directly (worker runspace, see this module's own
    #     header), so this just hands the chapter's own accumulated result
    #     (or $null if nothing to convert, matching the old per-engine
    #     $null-means-clean convention) to the main thread via -EventQueue. ---
    $chapterCompleteCallback = {
        param($chapterInfo)
        $cr = $chapterResults[$chapterInfo]
        $resultForCallback = if ($cr.TotalFiles -eq 0) { $null } else { $cr }
        $EventQueue.Enqueue(@{
            Kind = 'EngineChapterDone'; EngineType = $EngineType; ChapterKey = $chapterInfo
            SeriesName = $chapterInfo.SeriesName; ChapterName = $chapterInfo.ChapterName
            Dir = $chapterInfo.Dir; ZipOut = $chapterInfo.ZipOut; IsZippable = $chapterInfo.IsZippable
            Result = $resultForCallback
        })
        $chapterResults.Remove($chapterInfo)
    }.GetNewClosure()

    # Does NOT call Write-GatedConsoleMessage directly (unlike modes 2/3's
    # own -AbortPollCallback, which run main-thread-only and can) - this
    # worker runs inside its own runspace, and Write-GatedConsoleMessage's
    # CleanConsoleOutputEnabled=$true branch touches
    # CleanConsoleRendering.ps1's own module-scope render state, which is
    # never initialized inside a fresh runspace (see
    # Get-ImageConversionSharedFunctionNames's own docstring for why that
    # function is deliberately excluded from -SharedFunctionNames
    # everywhere else in this codebase too) - caught live by this module's
    # own harness (Scenario Z6) before this ever shipped: propagating it
    # anyway threw "Write-GatedConsoleMessage is not recognized" inside
    # the runspace the first time a real abort actually reached this
    # callback. Routed through -EventQueue instead, same pattern as every
    # other CCR-adjacent moment in this worker.
    $abortMessagePrinted = $false
    $abortPollCallback = {
        param($runningJobs)
        $aborted = Test-AbortSignal
        if ($aborted -and -not $abortMessagePrinted) {
            $abortMessagePrinted = $true
            if ($runningJobs.Count -gt 0) {
                $EventQueue.Enqueue(@{ Kind = 'AbortMessage'; EngineType = $EngineType; AbortTimeoutSeconds = $AbortTimeoutSeconds })
            }
        }
    }.GetNewClosure()

    $dispatchResult = Invoke-ChapterDispatch -ChapterProvider $chapterProvider -JobBuilder $jobBuilder `
        -JobStarter $jobStarter -JobPollCompleted $jobPollCompleted -JobFinalize $jobFinalize `
        -JobAbortCleanup $jobAbortCleanup -ChapterCompleteCallback $chapterCompleteCallback `
        -MaxConcurrent $SharedBudget -AbortPollCallback $abortPollCallback -CancelToken $CancelToken `
        -AbortTimeoutSeconds $AbortTimeoutSeconds -MaxQueueAhead $MaxQueueAhead

    return @{ EngineType = $EngineType; ForceKilledCount = $dispatchResult.ForceKilledCount; Aborted = $dispatchResult.Aborted }
}

function Invoke-FullPipeline {
    <#
    .SYNOPSIS
        Mode 1 ("Full Pipeline") end to end, migrated onto
        ChapterDispatch.ps1's Invoke-ChapterDispatch (step 4 of
        Docs\dispatch-redesign-design.md's 4-step migration order, the
        last and hardest - two engines instead of one) - idle concurrency
        in EITHER engine now picks up its own next chapter's jobs
        immediately, instead of the whole run blocking on one chapter's
        image AND animated conversion both finishing before the next
        chapter is even enumerated. See this module's own "DISPATCH-
        REDESIGN STEP 4" header comment (above Get-OrCreateFullPipelineSeriesBundle)
        for the full design, including the one real deviation made during
        this build from Docs\dispatch-redesign-design.md's own "Step 4
        concrete implementation plan": chapter/series identity is SHARED
        between the two engines (Get-OrCreateFullPipelineSeriesBundle),
        not computed independently per engine.

        Runs two Invoke-ChapterDispatch engines concurrently via
        Invoke-ZipParallelProcessing as a 2-job mixer (same mechanism the
        old per-chapter design already used, just now spanning the WHOLE
        library per call instead of one chapter) - $script:fullPipelineEngineWorker
        is the shared worker scriptblock, picking Image vs Animated logic
        via -EngineType, exactly like the old $script:fullPipelineChapterWorker
        it replaces. -PollCallback (ZipParallelProcessing.ps1's own new
        param, built for this) drains -EventQueue on the MAIN thread once
        per dispatch-loop pass - every CCR call, and the actual zip/merge
        decision itself, happens ONLY there; neither engine's own worker
        runspace ever touches Clean Console Output or the zip step
        directly (see this module's own header for why).
    .OUTPUTS
        Same shape as before - see the old version's own docstring,
        preserved here: @{ ConvertedImageSuccess; ConvertedImageFail;
        ConvertedImageSkipped; DeletedImageSuccess; DeletedImageFail;
        StaleImageCleanedSuccess; StaleImageCleanedFail;
        ConvertedAnimatedSuccess; ConvertedAnimatedFail;
        ConvertedAnimatedSkipped; DeletedAnimatedSuccess;
        DeletedAnimatedFail; ZipCreatedSuccess; ZipCreatedFail;
        ZipSkippedDueToError; FolderDeletedSuccess; FolderDeletedFail;
        ForceKilledCount; InspectFailedCount; SeriesCount; ChapterCount;
        Aborted }. ForceKilledCount is now the sum of each engine's own
        Invoke-ChapterDispatch-level total (that dispatch primitive's own
        output field), not folded per-chapter - the per-chapter
        ChapterResult shape this migration's JobBuilders build (mirroring
        modes 2/3's own, see this module's own header) never tracked
        force-kills per chapter to begin with. ChapterCount now counts a
        chapter once it's actually FINALIZED (both engines reported in),
        not once it's merely discovered - arguably more correct than the
        old "counted the moment Invoke-FullPipelineChapter was called"
        timing, though the two are the same number on any run that
        completes normally (the only real difference shows up on an abort
        that cuts a chapter off mid-flight, which the old code also never
        finished processing either).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$CjxlExe,
        [string]$MagickExe,
        [bool]$JpegLossless = $false,
        [int]$JpegQuality = 90,
        [bool]$AnimatedLossless = $false,
        [int]$AnimatedQuality = 90,
        [bool]$AnimatedOverwrite = $false,
        [bool]$AnimatedDeleteSource = $true,
        [Parameter(Mandatory)]
        [int]$FullPipelineMaxConcurrentProcs,
        [Parameter(Mandatory)]
        [bool]$FullLogging,
        [string]$LogFile,
        [string]$LogErrorFile,
        [string]$LogWarnFile,
        [Parameter(Mandatory)]
        [bool]$PermanentDelete,
        [string[]]$LooseImageExtensions = (Get-LooseImageExtensions),
        [string[]]$AnimatedFileExtensions = @(".avif"),
        [string[]]$KnownZipPaths = @(),
        [string[]]$FolderQualifyingExtensions = ((Get-LooseImageExtensions) + @(".jxl")),
        [System.Collections.Generic.HashSet[string]]$FolderExcludeStagingDirs = $null,
        [int]$AbortTimeoutSeconds = 60,
        [int]$MaxQueueAhead = 3,
        [bool]$RunCoverDeletionBeforeConversion = $false,
        [scriptblock]$CoverDeletionScanHandler = ${function:Invoke-UnwantedImageScan},
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message }
    )

    $totals = @{
        ConvertedImageSuccess    = 0; ConvertedImageFail    = 0; ConvertedImageSkipped    = 0
        DeletedImageSuccess      = 0; DeletedImageFail      = 0
        StaleImageCleanedSuccess = 0; StaleImageCleanedFail = 0
        ConvertedAnimatedSuccess = 0; ConvertedAnimatedFail = 0; ConvertedAnimatedSkipped = 0
        DeletedAnimatedSuccess   = 0; DeletedAnimatedFail   = 0
        ZipCreatedSuccess        = 0; ZipCreatedFail        = 0; ZipSkippedDueToError = 0
        FolderDeletedSuccess     = 0; FolderDeletedFail     = 0
        ForceKilledCount         = 0
        InspectFailedCount       = 0
        SeriesCount              = 0
        ChapterCount             = 0
        Aborted                  = $false
    }

    # Cover Deletion pre-scan (RunCoverDeletionBeforeConversion
    # toggle - see Todo.md's "Run Cover Deletion automatically before Full
    # Pipeline conversion" entry). Deliberately runs BEFORE any chapter
    # discovery/dispatch starts - nothing else is running yet (no
    # runspaces, no CancellationTokenSource registered below), so a
    # blocking -PromptFunc call here is safe in a way it wouldn't be once
    # the two ChapterDispatch engines are actually mid-run. Uses the SAME
    # Invoke-UnwantedImageScan the Cover Deletion menu option calls -
    # deletes real matches, respects $script:PermanentDelete, logs via
    # Write-Log same as always (log-only for now, no summary field - see
    # Todo.md). A per-file hash mismatch/failure inside the scan is
    # already handled (logged, not thrown) by Invoke-UnwantedImageScan
    # itself and never reaches this catch - only a scan that couldn't run
    # at ALL (bad path, permissions, etc.) does. Default (blank/anything
    # but Y) on the resulting prompt is ABORT, not continue - project
    # owner's own call: don't silently plow into conversion after
    # something already went wrong.
    if ($RunCoverDeletionBeforeConversion) {
        try {
            $null = & $CoverDeletionScanHandler -Path $Path
        } catch {
            $exMessage = $_.Exception.Message
            Write-Log ("Cover deletion pre-scan failed: " + $exMessage) -Level Error -ForceConsole
            $answer = (& $PromptFunc ("Cover deletion scan failed: " + $exMessage + ". Continue with conversion anyway? (Y/N)")).Trim()
            if ($answer -ne 'Y' -and $answer -ne 'y') {
                $totals.Aborted = $true
                return $totals
            }
        }
    }

    # Main-thread-only state (the merge dictionary keyed by chapterInfo
    # object reference, matching ChapterDispatch.ps1's own identity
    # convention - see this module's own header) - never touched by either
    # engine's own worker runspace, so a plain Dictionary is safe here
    # (same reasoning as Docs\dispatch-redesign-design.md's own Problem 2).
    $mergeState = [System.Collections.Generic.Dictionary[object,hashtable]]::new()
    $cleanConsoleOutputEnabled = [bool]$script:CleanConsoleOutputEnabled

    try {
        $sharedBudget      = [System.Threading.SemaphoreSlim]::new($FullPipelineMaxConcurrentProcs, $FullPipelineMaxConcurrentProcs)
        $seriesBundleCache = [System.Collections.Concurrent.ConcurrentDictionary[string, System.Lazy[hashtable]]]::new()
        $chapterClassificationCache = [System.Collections.Concurrent.ConcurrentDictionary[object, System.Lazy[hashtable]]]::new()
        $zipBlockReasons   = [System.Collections.Concurrent.ConcurrentDictionary[object,string]]::new()
        $announcedChapters = [System.Collections.Concurrent.ConcurrentDictionary[object,byte]]::new()
        $eventQueue        = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
        $fullCts = [System.Threading.CancellationTokenSource]::new()
        Register-AbortCancellationSource -Cts $fullCts

        # Finalizes ONE chapter's own merge entry: totals aggregation,
        # zip-block-reason resolution, the actual Complete-MergedFullPipelineChapter
        # call, and the live CCR transition. Called from two places: the
        # normal case (both engines reported in, from inside -PollCallback
        # below) AND a final sweep after Invoke-ZipParallelProcessing
        # returns, for any chapter that only ever got ONE report - a real,
        # legitimate case, not a bug to paper over: an engine that aborts
        # before its own -ChapterProvider ever reaches a chapter the OTHER
        # engine already started (and possibly finished) converting never
        # calls JobBuilder for it at all, so ChapterCompleteCallback never
        # fires on that side - see this module's own header and
        # CHANGELOG.md's matching entry for the live scenario (Scenario C6)
        # that caught this before it shipped. The missing side's own
        # ImageResult/AnimatedResult simply stays $null - Get-MergedChapterStatus
        # already treats that as "nothing to report for that engine",
        # correct here for the SAME reason it's correct for a chapter that
        # genuinely never had any files of that type.
        $finalizeChapterEntry = {
            param($key, $entry)
            $totals.ChapterCount++

            if ($null -ne $entry.ImageResult) {
                $ir = $entry.ImageResult
                $totals.ConvertedImageSuccess += $ir.ConvertedCount
                $totals.ConvertedImageFail    += $ir.FailedCount
                $totals.ConvertedImageSkipped += $ir.SkippedCount
                $totals.DeletedImageSuccess   += $ir.DeletedCount
                $totals.DeletedImageFail      += $ir.DeleteFailedCount
                $totals.InspectFailedCount    += $ir.InspectFailedCount
            }
            if ($null -ne $entry.AnimatedResult) {
                $ar = $entry.AnimatedResult
                $totals.ConvertedAnimatedSuccess += $ar.ConvertedCount
                $totals.ConvertedAnimatedFail    += $ar.FailedCount
                $totals.ConvertedAnimatedSkipped += $ar.SkippedCount
                $totals.DeletedAnimatedSuccess   += $ar.DeletedCount
                $totals.DeletedAnimatedFail      += $ar.DeleteFailedCount
                $totals.InspectFailedCount       += $ar.InspectFailedCount
            }

            $isExtra = -not $entry.IsZippable
            $blockedReasonForChapter = $null
            $hasBlockReason = $zipBlockReasons.TryGetValue($key, [ref]$blockedReasonForChapter)
            # A blocked reason (naming collision / AVIF classification
            # failure) vetoes zipping the same way the old code's
            # $failedClassificationDirs did - folded into -IsZippable
            # HERE, at finalize time, not baked into the chapter entry
            # itself (see Get-OrCreateFullPipelineSeriesBundle's own
            # header).
            $isZippableNow = $entry.IsZippable -and -not $hasBlockReason

            $chapterOutcome = Complete-MergedFullPipelineChapter -ChapterDir $entry.Dir.FullName -ZipOut $entry.ZipOut `
                -IsZippable $isZippableNow -ImageResult $entry.ImageResult -AnimatedResult $entry.AnimatedResult -Cts $fullCts

            $displayStatus = $chapterOutcome.Status
            $displayDetail = $chapterOutcome.Detail

            if ($chapterOutcome.Zipped) {
                if ($chapterOutcome.ZipResult.Status -eq 'Success') {
                    $totals.ZipCreatedSuccess++
                    if ($chapterOutcome.ZipResult.FolderDeleted)      { $totals.FolderDeletedSuccess++ }
                    if ($chapterOutcome.ZipResult.FolderDeleteFailed) { $totals.FolderDeletedFail++ }
                } else {
                    $totals.ZipCreatedFail++
                }
            } elseif ($isZippableNow -and ($chapterOutcome.Status -eq 'Error' -or $fullCts.Token.IsCancellationRequested)) {
                $totals.ZipSkippedDueToError++
                $displayStatus, $displayDetail = Get-ZipBlockedStatusOverride -Status $chapterOutcome.Status -Detail $chapterOutcome.Detail -BlockedReason "run aborted"
            } elseif ((-not $isZippableNow) -and $hasBlockReason) {
                $totals.ZipSkippedDueToError++
                if (-not $isExtra) {
                    $displayStatus, $displayDetail = Get-ZipBlockedStatusOverride -Status $chapterOutcome.Status -Detail $chapterOutcome.Detail -BlockedReason $blockedReasonForChapter
                }
            }

            if ($fullCts.Token.IsCancellationRequested) { $totals.Aborted = $true }

            if ($cleanConsoleOutputEnabled) {
                $null = Complete-ChapterProgress -SeriesName $entry.SeriesName -ChapterName $entry.ChapterName -Status $displayStatus -Detail $displayDetail
            }
        }.GetNewClosure()

        # -PollCallback: drains -EventQueue on the MAIN thread, once per
        # Invoke-ZipParallelProcessing dispatch-loop pass (and once more
        # after its own final drain - see that function's own new
        # -PollCallback param). Every CCR call and the actual zip/merge
        # decision live here, and ONLY here - see this module's own header.
        $pollCallback = {
            $evt = $null
            while ($eventQueue.TryDequeue([ref]$evt)) {
                switch ($evt.Kind) {
                    'SeriesReady' {
                        $totals.SeriesCount++
                        $totals.InspectFailedCount += $evt.InspectFailedCount
                        if ($evt.TotalChapters -gt 0 -and $cleanConsoleOutputEnabled) {
                            Start-SeriesProgress -SeriesName $evt.SeriesName -TotalChapters $evt.TotalChapters
                        }
                    }
                    'ChapterInspectFailed' {
                        $totals.InspectFailedCount += $evt.Count
                    }
                    'ChapterStaleCleanup' {
                        $totals.StaleImageCleanedSuccess += $evt.Success
                        $totals.StaleImageCleanedFail    += $evt.Fail
                    }
                    'ChapterStarted' {
                        if ($cleanConsoleOutputEnabled) {
                            Start-ChapterProgress -SeriesName $evt.SeriesName -ChapterName $evt.ChapterName
                        }
                    }
                    # Known, accepted limitation: -PollCallback only runs
                    # inside Invoke-ZipParallelProcessing's own main
                    # dispatch-loop pass and once more after its final
                    # drain - not continuously DURING
                    # Invoke-GracefulDrain's own (up to
                    # -AbortTimeoutSeconds) wait. An abort raised right as
                    # the dispatch loop is exiting can leave this message
                    # queued until the drain finishes, instead of printing
                    # the instant the abort is noticed like the old
                    # single-threaded code did - a cosmetic delay only,
                    # not a correctness issue (the message still prints,
                    # and $totals.Aborted is unaffected either way).
                    'AbortMessage' {
                        Write-GatedConsoleMessage -Text ("[ABORT] Waiting for current " + $evt.EngineType.ToLowerInvariant() + " jobs to finish (up to " + $evt.AbortTimeoutSeconds + "s)...") -Color Yellow -CleanConsoleOutputEnabled $cleanConsoleOutputEnabled
                    }
                    'EngineChapterDone' {
                        $key = $evt.ChapterKey
                        if (-not $mergeState.ContainsKey($key)) {
                            $mergeState[$key] = @{
                                SeriesName = $evt.SeriesName; ChapterName = $evt.ChapterName; Dir = $evt.Dir
                                ZipOut = $evt.ZipOut; IsZippable = $evt.IsZippable
                                ImageResult = $null; AnimatedResult = $null; GotImage = $false; GotAnimated = $false
                            }
                        }
                        $entry = $mergeState[$key]
                        if ($evt.EngineType -eq 'Image') { $entry.ImageResult = $evt.Result; $entry.GotImage = $true }
                        else                              { $entry.AnimatedResult = $evt.Result; $entry.GotAnimated = $true }

                        if (-not ($entry.GotImage -and $entry.GotAnimated)) { continue }
                        $mergeState.Remove($key)
                        & $finalizeChapterEntry $key $entry
                    }
                }
            }
        }.GetNewClosure()

        $jobParamsWorker = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($engineType in @('Image', 'Animated')) {
            $jobParamsWorker.Add(@{
                EngineType = $engineType; Path = $Path; CjxlExe = $CjxlExe; MagickExe = $MagickExe
                DoJpegLossless = $JpegLossless; DoJpegQuality = $JpegQuality
                DoAnimatedLossless = $AnimatedLossless; AnimatedQuality = $AnimatedQuality
                DoAnimatedOverwrite = $AnimatedOverwrite; DoAnimatedDeleteSource = $AnimatedDeleteSource
                DoFullLogging = $FullLogging; LogFile = $LogFile; LogErrorFile = $LogErrorFile; LogWarnFile = $LogWarnFile
                DoPermanentDelete = $PermanentDelete; CleanConsoleOutputEnabled = $cleanConsoleOutputEnabled
                SharedBudget = $sharedBudget; SeriesBundleCache = $seriesBundleCache; ChapterClassificationCache = $chapterClassificationCache; ZipBlockReasons = $zipBlockReasons
                AnnouncedChapters = $announcedChapters; EventQueue = $eventQueue
                LooseImageExtensions = $LooseImageExtensions; AnimatedFileExtensions = $AnimatedFileExtensions
                KnownZipPaths = $KnownZipPaths; FolderQualifyingExtensions = $FolderQualifyingExtensions
                FolderExcludeStagingDirs = $FolderExcludeStagingDirs
                AbortTimeoutSeconds = $AbortTimeoutSeconds; MaxQueueAhead = $MaxQueueAhead
            })
        }

        $engineResultHandler = {
            param($r)
            $totals.ForceKilledCount += $r.ForceKilledCount
            if ($r.Aborted) { $totals.Aborted = $true }
        }.GetNewClosure()

        $engineWorkerSharedFunctionNames = @(Get-LoggingSharedFunctionNames) + @(Get-FileDeletionSharedFunctionNames) +
            @(Get-ImageConversionSharedFunctionNames) + @(Get-AnimatedConversionSharedFunctionNames) +
            @(Get-LeafDirectoryDiscoverySharedFunctionNames) + @(Get-ChapterDispatchSharedFunctionNames) +
            @('Get-OrCreateFullPipelineSeriesBundle', 'Get-OrCreateFullPipelineChapterClassification', 'Add-FullPipelineZipBlockReason', 'Complete-ImageDispatchJob', 'Complete-AnimatedDispatchJob',
              # Test-AbortSignal (AbortPipeline.ps1, no Get-XSharedFunctionNames
              # getter of its own) - called directly by both
              # $chapterProvider (inside the worker) and
              # Get-OrCreateFullPipelineSeriesBundle's own classification
              # loop, neither of which modes 2/3 needed to propagate this
              # for, since THEIR equivalent callers run main-thread-only,
              # never inside a runspace. Get-LooseImageCandidates/
              # Remove-StaleLooseSources/Get-LooseAnimatedCandidates -
              # called by Get-OrCreateFullPipelineSeriesBundle's own
              # factory, same reason: mode 2/3's own top-level pipelines
              # call these directly too, but also always on the main
              # thread, so neither of their own Get-*SharedFunctionNames
              # getters (built only for Convert-ImageBatch/
              # Convert-AnimatedBatch's own runspace needs) ever needed to
              # cover them. All four caught by Lint.Harness.ps1's Rule 5
              # before this ever ran against real content.
              'Test-AbortSignal', 'Get-LooseImageCandidates', 'Remove-StaleLooseSources', 'Get-LooseAnimatedCandidates',
              'Get-LooseImageExtensions', 'Test-OrphanedScratchFileName')

        $null = Invoke-ZipParallelProcessing -WorkerScript $script:fullPipelineEngineWorker -JobParams $jobParamsWorker `
            -SharedFunctionNames $engineWorkerSharedFunctionNames -MaxParallel 2 -Cts $fullCts -ResultHandler $engineResultHandler `
            -AbortWaitMessage "[ABORT] Waiting for current image/animated jobs to finish (up to 60s)..." -PollCallback $pollCallback

        # Final sweep: both engine workers have now fully returned (normal
        # completion or post-abort drain) - anything still left in
        # $mergeState only ever got ONE engine's own report, not two (see
        # $finalizeChapterEntry's own header for the real, legitimate
        # reason this happens under an abort). Finalize each one now,
        # treating the missing side as $null - the SAME merge/zip/CCR path
        # every normally-completed chapter already went through.
        foreach ($leftoverKey in @($mergeState.Keys)) {
            & $finalizeChapterEntry $leftoverKey $mergeState[$leftoverKey]
        }
        $mergeState.Clear()
    } finally {
        if ($fullCts) {
            Unregister-AbortCancellationSource -Cts $fullCts
            $fullCts.Dispose()
        }
        # $sharedBudget disposal matters here - without it, a
        # SemaphoreSlim handle leaks every real run. Guarded
        # like $fullCts above, same reason: construction itself is inside
        # the try, so a throw before it ever runs leaves this unset.
        if ($sharedBudget) { $sharedBudget.Dispose() }
        if ($script:CleanConsoleOutputEnabled) {
            $null = Complete-AllActiveSeriesProgress
        }
    }

    return $totals
}


# ==============================================================================
#  TOP-LEVEL DISPATCHER - Invoke-Mode (see this module's header, "TOP-LEVEL
#  DISPATCHER" section, for the full design reasoning)
# ==============================================================================

function Invoke-Mode {
    <#
    .SYNOPSIS
        Runs whichever mode $Resolved.Mode names (Menu.ps1's
        Resolve-ModeSelection output), translating $Settings into that
        pipeline's own param list, and returns Summary.ps1's canonical
        $stats shape (New-StatsTracker) - not that pipeline's own raw
        result - so a caller can pass this straight to Get-SummaryLines
        alongside $Resolved itself as -ModeFlags (Resolve-ModeSelection's
        shape IS the ModeFlags shape Get-SummaryLines expects).
    .PARAMETER Resolved
        Menu.ps1's Resolve-ModeSelection output - @{ Mode; ... }.
    .PARAMETER ImageConversionHandler
    .PARAMETER AnimatedConversionHandler
    .PARAMETER ZipFoldersHandler
    .PARAMETER FullPipelineHandler
        Each real pipeline entry point, injectable for testing with
        fakes - default to the real function. A harness scenario that
        overrides every handler it exercises never needs the default to
        resolve at all, so it never needs Invoke-Mode's own harness to
        dot-source ZipPipeline.ps1 - see this module's header.
    .PARAMETER ZipFolderHandler
        Mode 8's real zip step - defaults to
        Invoke-LooseFolderZip (ZipPipeline.ps1), same injectable/caveat-
        gated shape as the handlers above. The closure built for mode 8's
        -ZipStepCallback calls this WITHOUT -SeriesName/-ChapterName
        (Invoke-LooseFolderZip would start its own CCR transition
        otherwise - see ImageConversionPipeline.ps1's -ZipStepCallback
        contract) and owns mode 8's own business logic - which extensions
        block zipping, based on $Settings.ZipWithUnconvertedAnimated.
    .PARAMETER LogHandler
        Passed straight to Invoke-AbortOrFatalHandler on a caught
        exception. Defaults to a real Write-Log Error call (this module
        already forward-references Logging.ps1 for everything else it
        does), NOT AbortPipeline.ps1's own raw-Write-Host default - a
        real caller of Invoke-Mode always has Logging.ps1 available.
    .OUTPUTS
        Summary.ps1's New-StatsTracker shape on a normal completion, or
        $null if the dispatch itself threw (a genuine crash, or the rare
        abort-exception race - see Invoke-AbortOrFatalHandler) - a $null
        return means the run did NOT complete, never treat it as a
        clean, zero-activity result.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Resolved,
        [Parameter(Mandatory)]
        [string]$TargetPath,
        [Parameter(Mandatory)]
        [hashtable]$Settings,
        [Parameter(Mandatory)]
        [string]$CjxlExe,
        [string]$MagickExe,
        [string]$LogFile,
        [string]$LogErrorFile,
        [string]$LogWarnFile,
        [scriptblock]$ImageConversionHandler = ${function:Invoke-LooseImageConversionPipeline},
        [scriptblock]$AnimatedConversionHandler = ${function:Invoke-LooseAnimatedConversionPipeline},
        [scriptblock]$ZipFoldersHandler = ${function:Invoke-ZipOnlyPipeline},
        [scriptblock]$FullPipelineHandler = ${function:Invoke-FullPipeline},
        [scriptblock]$ZipFolderHandler = ${function:Invoke-LooseFolderZip},
        [scriptblock]$LogHandler = { param($m) Write-Log $m -Level Error }
    )

    try {
        # Every mode that unconditionally runs the animated engine needs
        # a real magick.exe - AVIF conversion has no cjxl-only path.
        # Modes that only MIGHT need it (a WebP file happens to show up)
        # are deliberately NOT gated here - they already fail per-file,
        # inside the pipeline, exactly where that failure is meaningful.
        if ($Resolved.Mode -in @('AnimatedConversion', 'FullPipeline') -and [string]::IsNullOrWhiteSpace($MagickExe)) {
            throw ("Mode '" + $Resolved.Mode + "' requires magick.exe, which was not found or configured.")
        }

        $stats = New-StatsTracker

        switch ($Resolved.Mode) {
            'ImageConversion' {
                # [bool](...) cast (2026-08-31 fix, from a same-day
                # /code-review re-review) - same reasoning as the
                # ZipFolders/FullPipeline cases below, missed here in the
                # original pass: FullLogging is
                # [Parameter(Mandatory)][bool] on
                # Invoke-LooseImageConversionPipeline.
                #
                # $script:FullLogging, NOT [bool]$Settings.FullLogging
                # (2026-08-31 fix, caught by a same-day /code-review
                # full-codebase pass): every -FullLogging/-DoFullLogging
                # argument in this switch (and Write-SummaryReport's own
                # call, further down) now reads the FROZEN value
                # Initialize-LogPaths set in $script:FullLogging at
                # bootstrap, not the LIVE $Settings.FullLogging - because
                # $LogFile/$LogErrorFile/$LogWarnFile (passed alongside,
                # unchanged) are ALSO frozen bootstrap snapshots
                # (Conversion Script Main.ps1 computes them once, before
                # this loop exists, and this loop deliberately never
                # re-runs Initialize-LogPaths mid-session - see this
                # function's own Invoke-MainLoop header comment for why).
                # Reading the FullLogging flag live while the paths stay
                # frozen let them drift out of sync the moment a user
                # toggled Full Logging in the Options menu mid-session: a
                # worker runspace (Convert-ImageBatch/Convert-AnimatedBatch,
                # dispatched by Invoke-FullPipelineChapter) sets its OWN
                # fresh $script:FullLogging from whatever value THIS
                # switch passed it, so a live, post-toggle value there
                # paired with the OLD, pre-toggle paths - live-reproduced:
                # every worker-side Write-Log call after a toggle went to
                # a $null path (split-mode's $logFile is never set) and
                # was silently dropped, with no error, no console line,
                # nothing on disk. Using the same frozen source for both
                # keeps them consistent, matching this project's own
                # already-documented, deliberate design: the toggle
                # doesn't take effect until the next relaunch, rather than
                # partially applying and breaking logging outright.
                $r = & $ImageConversionHandler -Path $TargetPath -CjxlExe $CjxlExe -MagickExe $MagickExe `
                    -JpegLossless ([bool]$Settings.JpegLossless) -JpegQuality $Settings.JpegQuality -MaxCjxlProcs $Settings.MaxCjxlProcs -FullLogging $script:FullLogging
                $stats.LooseImgConverted.Success = $r.ConvertedSuccess; $stats.LooseImgConverted.Fail = $r.ConvertedFail; $stats.LooseImgConverted.Skipped = $r.ConvertedSkipped
                $stats.LooseImgDeleted.Success   = $r.DeletedSuccess;   $stats.LooseImgDeleted.Fail   = $r.DeletedFail
                $stats.LooseStaleCleaned.Success = $r.StaleCleanedSuccess; $stats.LooseStaleCleaned.Fail = $r.StaleCleanedFail
                $stats.InspectFailed.Count       = $r.InspectFailedCount
                $stats.Aborted                   = $r.Aborted
                $stats.ForceKilledCount          = $r.ForceKilledCount
            }
            'AnimatedConversion' {
                # [bool](...) casts (2026-08-31 fix, from a FOURTH same-day
                # /code-review pass): NOT limited to Mandatory params -
                # confirmed directly that a non-Mandatory [bool]$X = $false
                # parameter ALSO throws on an explicitly-passed $null (the
                # Mandatory attribute only affects whether OMITTING the
                # param is allowed; the [bool] type coercion runs
                # regardless of Mandatory once a value - even $null - is
                # actually passed). Every bool-typed $Settings property
                # passed as a param anywhere in this switch needed the
                # same cast, not just the ones already flagged as
                # Mandatory on the receiving end.
                $r = & $AnimatedConversionHandler -Path $TargetPath -MagickExe $MagickExe `
                    -AnimatedLossless ([bool]$Settings.AnimatedLossless) -AnimatedQuality $Settings.AnimatedQuality -AnimatedThreads $Settings.AnimatedThreads `
                    -AnimatedOverwrite ([bool]$Settings.AnimatedOverwrite) -AnimatedDeleteSource ([bool]$Settings.AnimatedDeleteSource) -FullLogging $script:FullLogging
                $stats.LooseAnimatedConverted.Success = $r.ConvertedSuccess; $stats.LooseAnimatedConverted.Fail = $r.ConvertedFail; $stats.LooseAnimatedConverted.Skipped = $r.ConvertedSkipped
                $stats.LooseAnimatedDeleted.Success   = $r.DeletedSuccess;   $stats.LooseAnimatedDeleted.Fail   = $r.DeletedFail
                $stats.InspectFailed.Count            = $r.InspectFailedCount
                $stats.Aborted                        = $r.Aborted
                $stats.ForceKilledCount               = $r.ForceKilledCount
            }
            'ZipFolders' {
                # [bool](...) casts (2026-08-31 fix, from a same-day
                # /code-review): FullLogging/PermanentDelete are both
                # [Parameter(Mandatory)][bool] on the receiving function -
                # a $Settings missing either key would otherwise fail
                # PowerShell's own boolean coercion with a hard crash, the
                # same species already fixed at other call sites today.
                $r = & $ZipFoldersHandler -Path $TargetPath -MaxParallel $Settings.ZipParallelThreads -DeleteFolders $true `
                    -FullLogging $script:FullLogging -LogFile $LogFile -LogErrorFile $LogErrorFile -LogWarnFile $LogWarnFile -PermanentDelete ([bool]$Settings.PermanentDelete)
                $stats.ZipOnlyZipped.Success        = $r.ZippedSuccess;        $stats.ZipOnlyZipped.Fail        = $r.ZippedFail
                $stats.ZipOnlyFolderDeleted.Success = $r.FolderDeletedSuccess; $stats.ZipOnlyFolderDeleted.Fail = $r.FolderDeletedFail
                # Aborted/ForceKilledCount (2026-09-03 fix, real bug caught
                # by a same-session /code-review pass): Invoke-ZipOnlyPipeline
                # gained a real Aborted field the same day (previously it had
                # only ForceStoppedCount, with no way to distinguish "the run
                # was cancelled" from "the run finished with a slow drain") -
                # $r.ForceStoppedCount maps onto Stats' ForceKilledCount name.
                $stats.Aborted           = $r.Aborted
                $stats.ForceKilledCount  = $r.ForceStoppedCount
            }
            'FullPipeline' {
                # [bool](...) casts - same reasoning as the ZipFolders case above.
                $r = & $FullPipelineHandler -Path $TargetPath -CjxlExe $CjxlExe -MagickExe $MagickExe `
                    -JpegLossless ([bool]$Settings.JpegLossless) -JpegQuality $Settings.JpegQuality -AnimatedLossless ([bool]$Settings.AnimatedLossless) -AnimatedQuality $Settings.AnimatedQuality `
                    -AnimatedOverwrite ([bool]$Settings.AnimatedOverwrite) -AnimatedDeleteSource ([bool]$Settings.AnimatedDeleteSource) -FullPipelineMaxConcurrentProcs $Settings.FullPipelineMaxConcurrentProcs `
                    -FullLogging $script:FullLogging -LogFile $LogFile -LogErrorFile $LogErrorFile -LogWarnFile $LogWarnFile -PermanentDelete ([bool]$Settings.PermanentDelete) `
                    -RunCoverDeletionBeforeConversion ([bool]$Settings.RunCoverDeletionBeforeConversion)
                $stats.LooseImgConverted.Success      = $r.ConvertedImageSuccess;    $stats.LooseImgConverted.Fail      = $r.ConvertedImageFail;    $stats.LooseImgConverted.Skipped = $r.ConvertedImageSkipped
                $stats.LooseImgDeleted.Success        = $r.DeletedImageSuccess;      $stats.LooseImgDeleted.Fail        = $r.DeletedImageFail
                $stats.LooseStaleCleaned.Success      = $r.StaleImageCleanedSuccess; $stats.LooseStaleCleaned.Fail      = $r.StaleImageCleanedFail
                $stats.LooseAnimatedConverted.Success = $r.ConvertedAnimatedSuccess; $stats.LooseAnimatedConverted.Fail = $r.ConvertedAnimatedFail; $stats.LooseAnimatedConverted.Skipped = $r.ConvertedAnimatedSkipped
                $stats.LooseAnimatedDeleted.Success   = $r.DeletedAnimatedSuccess;   $stats.LooseAnimatedDeleted.Fail   = $r.DeletedAnimatedFail
                $stats.LooseFolderZipped.Success      = $r.ZipCreatedSuccess;        $stats.LooseFolderZipped.Fail      = $r.ZipCreatedFail;        $stats.LooseFolderZipped.Skipped = $r.ZipSkippedDueToError
                $stats.LooseFolderDeleted.Success     = $r.FolderDeletedSuccess;     $stats.LooseFolderDeleted.Fail     = $r.FolderDeletedFail
                $stats.InspectFailed.Count            = $r.InspectFailedCount
                $stats.Aborted                        = $r.Aborted
                $stats.ForceKilledCount               = $r.ForceKilledCount
            }
            'ImageConversionZip' {
                # Mode 8's real zip-step wiring (2026-08-28, Phase 2 of the
                # build plan) - the -ZipStepCallback contract ImageConversionPipeline.ps1
                # decided: this closure owns ALL of mode 8's own business
                # logic (which extensions block zipping, based on
                # ZipWithUnconvertedAnimated), while ImageConversionPipeline.ps1
                # itself only decides WHETHER to call it (IsZippable/Error
                # gate) and folds its @{ Status; Detail } return into the
                # SAME Complete-ChapterProgress call conversion already
                # makes - see that module's own header/docstring.
                # Deliberately does NOT pass -SeriesName/-ChapterName to
                # -ZipFolderHandler - that would make Invoke-LooseFolderZip
                # start its OWN CCR transition, which is exactly the
                # second-transition shape this design rejected.
                # Derived from Get-LooseImageExtensions() (2026-09-02 fix,
                # from a same-day review), not a hand-retyped literal - the
                # literal was a snapshot of the canonical list minus
                # ".avif" (this toggle's own, literal, documented scope -
                # "ZipWithUnconvertedAnimated" - never widened to cover
                # ".webp", a pre-existing asymmetry this fix doesn't touch)
                # taken BEFORE ".gif"/".bmp"/".heic"/".heif" were added to
                # the canonical list - it silently never picked those up,
                # so with the toggle ON, an unconverted BMP/HEIC/HEIF
                # (magick missing, a future conversion failure) sailed
                # past this gate and got zipped raw.
                #
                # Get-NeverConvertedExtensions() is ALSO subtracted here
                # (2026-09-02 follow-up fix, same day, caught by a second
                # full-codebase review) - an EARLIER version of this same
                # fix deliberately kept ".gif" as a blocker in BOTH toggle
                # branches, reasoning it "counts as unconverted content" so
                # should always block. That reasoning was wrong in
                # practice: Convert-ImageBatch never even attempts to
                # convert a never-converted extension, and
                # Get-LooseImageCandidates never returns it as a
                # NeedsConversion candidate either - there is no failure
                # for the user to ever resolve, so a chapter containing a
                # ".gif" could NEVER be zipped by mode 8, on any run,
                # forever, live-confirmed. Full Pipeline has no such gate
                # at all (Controller.ps1's own Invoke-FullPipelineChapter
                # calls Compress-FolderToZip directly, see that function's
                # own comment for why) and simply sweeps a never-converted
                # file into the zip alongside everything else - that's the
                # already-validated-correct behavior this now matches.
                # ".bmp"/".heic"/".heif" are NOT subtracted - those really
                # do convert, so a leftover one really is a resolvable
                # failure and should keep blocking.
                $zipLooseExtensions = if ($Settings.ZipWithUnconvertedAnimated) {
                    @((Get-LooseImageExtensions) | Where-Object { $_ -ne ".avif" -and (Get-NeverConvertedExtensions) -inotcontains $_ })
                } else {
                    @((Get-LooseImageExtensions) | Where-Object { (Get-NeverConvertedExtensions) -inotcontains $_ })
                }
                # Boxed, not a bare/$script: var - .GetNewClosure() puts
                # $zipStep in its own dynamic module, so a plain
                # "$zipStatsBox = ..." reassignment inside it would silently
                # write to a disconnected copy this scope never sees (the
                # exact trap Controller.Harness.ps1's own Scenario O test
                # hit while proving this callback - see CLAUDE.md's Lessons
                # learned). Mutating an existing hashtable's keys, not
                # reassigning the variable, is what makes this safe.
                $zipStatsBox = @{ Success = 0; Fail = 0; Skipped = 0; FolderDeletedSuccess = 0; FolderDeletedFail = 0 }
                $zipStep = {
                    param($Info)
                    # -RequireJxlEntry, computed the same way Invoke-FullPipelineChapter
                    # computes $imageActuallyConverted (2026-09-04 fix, real bug): a
                    # chapter whose only images are never-converted formats (e.g. all
                    # .gif) or all-animated-avif-routed-elsewhere has $Info.ChapterResult
                    # with ConvertedCount 0 (or $null when Get-ChapterProgressStatus's own
                    # $null-ChapterResult "nothing needed converting" case applies) -
                    # legitimately zero .jxl entries. Without this, Invoke-LooseFolderZip's
                    # $true default rejected every such zip via Test-ZipArchive, forever.
                    $imageActuallyConverted = ($null -ne $Info.ChapterResult -and $Info.ChapterResult.ConvertedCount -gt 0)
                    $zipResult = & $ZipFolderHandler -FolderPath $Info.Dir.FullName -ZipOut $Info.ZipOut -LooseImageExtensions $zipLooseExtensions -RequireJxlEntry $imageActuallyConverted
                    switch ($zipResult.Status) {
                        'Success' { $zipStatsBox.Success++ }
                        'Fail'    { $zipStatsBox.Fail++ }
                        'Skipped' { $zipStatsBox.Skipped++ }
                    }
                    if ($zipResult.FolderDeleted)      { $zipStatsBox.FolderDeletedSuccess++ }
                    if ($zipResult.FolderDeleteFailed) { $zipStatsBox.FolderDeletedFail++ }
                    $detail = switch ($zipResult.Status) {
                        'Success' { $zipResult.EntryCount.ToString() + " entries" }
                        'Skipped' { "unconverted source(s) remain" }
                        default   { $null }
                    }
                    return @{ Status = $zipResult.Status; Detail = $detail }
                }.GetNewClosure()

                # [bool](...) cast (2026-08-31 fix, from a THIRD same-day
                # /code-review pass) - same reasoning as every other
                # switch case in this function; this one (mode 8) was
                # missed by both earlier passes.
                $r = & $ImageConversionHandler -Path $TargetPath -CjxlExe $CjxlExe -MagickExe $MagickExe `
                    -JpegLossless ([bool]$Settings.JpegLossless) -JpegQuality $Settings.JpegQuality -MaxCjxlProcs $Settings.MaxCjxlProcs -FullLogging $script:FullLogging `
                    -ZipStepCallback $zipStep
                $stats.LooseImgConverted.Success = $r.ConvertedSuccess; $stats.LooseImgConverted.Fail = $r.ConvertedFail; $stats.LooseImgConverted.Skipped = $r.ConvertedSkipped
                $stats.LooseImgDeleted.Success   = $r.DeletedSuccess;   $stats.LooseImgDeleted.Fail   = $r.DeletedFail
                $stats.LooseStaleCleaned.Success = $r.StaleCleanedSuccess; $stats.LooseStaleCleaned.Fail = $r.StaleCleanedFail
                $stats.InspectFailed.Count       = $r.InspectFailedCount
                # LooseFolderZipped/LooseFolderDeleted - fixed 2026-08-28.
                # Invoke-LooseImageConversionPipeline's own $totals has no
                # zip-step counters (ZipPipeline.ps1's domain, deliberately
                # kept decoupled - see this module's header), so mode 8's
                # zip outcomes are only ever visible through $zipStatsBox,
                # accumulated across every chapter's -ZipStepCallback call.
                $stats.LooseFolderZipped.Success  = $zipStatsBox.Success
                $stats.LooseFolderZipped.Fail      = $zipStatsBox.Fail
                $stats.LooseFolderZipped.Skipped   = $zipStatsBox.Skipped
                $stats.LooseFolderDeleted.Success  = $zipStatsBox.FolderDeletedSuccess
                $stats.LooseFolderDeleted.Fail      = $zipStatsBox.FolderDeletedFail
                # Aborted/ForceKilledCount (2026-09-03 fix, real bug caught
                # by a same-session /code-review pass - missed when the
                # 'ImageConversion'/'AnimatedConversion'/'FullPipeline'
                # branches got these two lines): mode 8 calls the same
                # $ImageConversionHandler as 'ImageConversion' above, and
                # $r carries the identical two fields.
                $stats.Aborted           = $r.Aborted
                $stats.ForceKilledCount  = $r.ForceKilledCount
            }
            default {
                throw ("Invoke-Mode: unrecognized mode '" + $Resolved.Mode + "'.")
            }
        }

        return $stats
    } catch {
        $null = Invoke-AbortOrFatalHandler -ErrorRecord $_ -LogHandler $LogHandler
        return $null
    }
}

function Invoke-MainLoop {
    <#
    .SYNOPSIS
        The run loop that used to live inline in the main script's own
        `while` block (moved here 2026-08-28, per the "Show-PostRunPrompt's
        run loop lives in Controller.ps1" decision, Todo.md): resolve a
        mode, run it via Invoke-Mode, report the result, prompt to
        continue or exit. Loops until Show-PostRunPrompt (or its
        injected fake) returns 'Exit'.
    .PARAMETER GetModeHandler
    .PARAMETER InvokeModeHandler
    .PARAMETER PostRunPromptHandler
        Injectable, same DI pattern as Invoke-Mode's own pipeline
        handlers - default to the real Get-SelectedMode/Invoke-Mode/
        Show-PostRunPrompt. A harness overriding all three never needs a
        real interactive prompt, real pipeline, or real keypress to test
        the loop's own control flow (how many iterations, when it stops).
    .PARAMETER ResetAbortHandler
        Injectable, defaults to the real AbortPipeline.ps1's
        Reset-AbortState - called once per loop iteration, BEFORE
        resolving the next mode. Closes a real bug (Todo.md/CHANGELOG.md):
        nothing ever reset $script:abortRequested/[ConsoleCtrl]::AbortRequested/
        DrainComplete between runs, so a single Ctrl+C (even one that fired
        while idle at the menu, before any pipeline was running) left the
        REST of the session's runs aborting immediately on their first
        Test-AbortSignal poll, with no new Ctrl+C from the user. Resetting
        here, at the top of every iteration, means every real dispatched
        run starts from a genuinely clean slate.
    .PARAMETER SetRunActiveHandler
        Injectable, defaults to the real AbortPipeline.ps1's
        Set-AbortHandlerRunActive. Called $true right before, $false
        right after (try/finally) InvokeModeHandler - tells the native
        Ctrl+C handler a real run is in progress, so Ctrl+C at the menu
        (between calls) falls through to the OS's own default action
        instead of being caught and leaking into the next iteration's
        run (project owner's own explicit decision, 2026-08-31).
    .PARAMETER SetQuickEditHandler
        Injectable, defaults to the real AbortPipeline.ps1's
        Set-ConsoleQuickEditEnabled. Called $false right before, $true
        right after (try/finally) InvokeModeHandler, same bracketing as
        SetRunActiveHandler - Windows Console QuickEdit mode (highlighting
        text pauses all console output; a stray right-click afterward
        pastes the clipboard back in as keystrokes) is a real hazard while
        a run is actually dispatching work, but harmless - and useful, for
        copying real output - once a run has finished (project owner's
        own live report, 2026-09-08).
    .PARAMETER ScriptDir
        Where log files live - threaded through so a mid-session
        FullLogging/DisableSummaryFile re-sync (see below) can call
        Initialize-LogPaths with the right directory. Without this,
        Initialize-LogPaths' own $PSScriptRoot fallback would resolve to
        Modules\ (where Logging.ps1 lives) when called from here, not the
        main script's own directory.
    .PARAMETER StartLogRunHandler
        Injectable, defaults to the real Logging.ps1 Start-LogRun. Called
        every iteration, right before dispatch - unlike
        InitializeLogPathsHandler below (only re-called when the log
        PATHS actually change), each run needs its own header/prior-
        content snapshot captured fresh, paired with CompleteLogRunHandler
        at the end of the same iteration.
    .PARAMETER InitializeLogPathsHandler
    .PARAMETER InitializeLogMutexHandler
        Injectable, default to the real Initialize-LogPaths/
        Initialize-LogMutex. Called mid-loop (2026-09-03 fix, Todo.md's
        mid-session-toggle finding) only when FullLogging or
        DisableSummaryFile actually changed since the last call - now
        safe to re-call at all only because neither logging mode
        deletes/clears anything on a repeat call anymore (see Logging.ps1).
        $LogFile/$LogErrorFile/$LogWarnFile are refreshed from the
        resulting $script: state right after, so THIS iteration's
        dispatch (and every worker it spawns) sees the new paths, not the
        ones frozen at bootstrap.
    .OUTPUTS
        None - runs until exit, same as the main script's old inline loop.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$TargetPath,
        [Parameter(Mandatory)]
        [hashtable]$Settings,
        [Parameter(Mandatory)]
        [string]$SettingsPath,
        [Parameter(Mandatory)]
        [string]$CjxlExe,
        [string]$MagickExe,
        [string]$ScriptDir,
        [string]$LogFile,
        [string]$LogErrorFile,
        [string]$LogWarnFile,
        [scriptblock]$GetModeHandler = ${function:Get-SelectedMode},
        [scriptblock]$InvokeModeHandler = ${function:Invoke-Mode},
        [scriptblock]$PostRunPromptHandler = ${function:Show-PostRunPrompt},
        [scriptblock]$ResetAbortHandler = ${function:Reset-AbortState},
        [scriptblock]$SetRunActiveHandler = ${function:Set-AbortHandlerRunActive},
        [scriptblock]$SetQuickEditHandler = ${function:Set-ConsoleQuickEditEnabled},
        [scriptblock]$LogHandler = { param($m) Write-Log $m -Level Error },
        [scriptblock]$CompleteLogRunHandler = ${function:Complete-LogRun},
        [scriptblock]$StartLogRunHandler = ${function:Start-LogRun},
        [scriptblock]$InitializeLogPathsHandler = ${function:Initialize-LogPaths},
        [scriptblock]$InitializeLogMutexHandler = ${function:Initialize-LogMutex}
    )

    # Tracks the FullLogging/DisableSummaryFile values Initialize-LogPaths
    # was last actually called with, so the re-sync below (2026-09-03 fix -
    # see Todo.md's mid-session-toggle finding) only re-calls it when either
    # one has genuinely changed since the LAST iteration, not on every
    # single one - now safe to re-call at all only because neither logging
    # mode deletes/clears anything on a repeat call anymore (see
    # Logging.ps1's Initialize-LogPaths header). Seeded from $Settings'
    # current values since the bootstrap's own Initialize-LogPaths call
    # (Conversion Script Main.ps1) already used them for whatever produced
    # the $LogFile/$LogErrorFile/$LogWarnFile passed in here.
    $lastFullLogging        = [bool]$Settings.FullLogging
    $lastDisableSummaryFile = [bool]$Settings.DisableSummaryFile

    while ($true) {
        & $ResetAbortHandler

        # try/catch around $GetModeHandler (2026-09-02 review fix): mode 5
        # (Cover Deletion)'s own real, destructive work runs INSIDE this
        # call (Get-SelectedMode -> Show-ModeMenu -> Show-CoverDeletionMenu),
        # unlike every other mode, which runs inside $InvokeModeHandler
        # below - already wrapped, and Invoke-Mode has its own further
        # internal catch besides. Before this fix, an uncaught throw
        # anywhere under mode 5 (e.g. Test-UnwantedImageMatch's own
        # Get-FileHash call, fixed the same day) had nothing between it
        # and the bootstrap's top-level catch - it took down the entire
        # script (a FATAL ERROR message, keypress, exit) instead of being
        # reported and returning to the menu like every other mode's own
        # crash already does. Same containment/-LogHandler shape as
        # Invoke-Mode's own catch, for the same reason.
        $resolved = $null
        try {
            $resolved = & $GetModeHandler -Settings $Settings -SettingsPath $SettingsPath
        } catch {
            $null = Invoke-AbortOrFatalHandler -ErrorRecord $_ -LogHandler $LogHandler
        }
        if ($null -eq $resolved) {
            Write-Log "Run did not complete - see the error above." -Level Warn
            $postRun = & $PostRunPromptHandler
            if ($postRun -eq 'Exit') { break }
            Write-Host ""
            continue
        }

        # Re-sync the two options-menu toggles that are cheap, idempotent
        # $script: assignments with no other side effect, so a change made
        # in the options menu just now (Get-SelectedMode's own Show-
        # OptionsMenuLevel flow mutates $Settings in place) takes effect on
        # THIS iteration's run, not just the next process launch. Bug: these
        # were only ever applied once, at bootstrap, before this loop
        # existed - turning Permanent Delete off here did nothing until the
        # whole script was relaunched, and worse, main-thread deletions kept
        # using the stale bootstrap value while worker-runspace deletions
        # (which read $Settings.PermanentDelete fresh per dispatch) already
        # picked up the change, so a single run could silently mix
        # Recycle-Bin and permanent deletions.
        #
        # FullLogging/DisableSummaryFile get the SAME re-sync treatment now
        # (2026-09-03 fix - Todo.md's mid-session-toggle finding), gated on
        # an actual change since Initialize-LogPaths' own $lastFullLogging/
        # $lastDisableSummaryFile were last updated: neither logging mode
        # deletes/clears anything on a repeat call anymore (Logging.ps1),
        # so re-calling it is safe, but it's still only called when the
        # toggle genuinely changed - not every iteration - since full-
        # logging mode gets a FRESH timestamped file on every
        # Initialize-LogPaths call, and a toggle that hasn't changed
        # shouldn't fragment one run's-worth of full-logging output across
        # a new file for every single menu round-trip.
        $currentFullLogging        = [bool]$Settings.FullLogging
        $currentDisableSummaryFile = [bool]$Settings.DisableSummaryFile
        if ($currentFullLogging -ne $lastFullLogging -or $currentDisableSummaryFile -ne $lastDisableSummaryFile) {
            & $InitializeLogPathsHandler -TargetPath $TargetPath -FullLogging $currentFullLogging -DisableSummaryFile $currentDisableSummaryFile -ScriptDir $ScriptDir
            # Dispose the PREVIOUS mutex before re-creating (2026-09-03
            # fix, real bug caught by a same-session /code-review pass) -
            # Initialize-LogMutex's own docstring deliberately does NOT
            # dispose it (ZipParallelProcessing.ps1's own save/restore
            # pattern depends on that old reference staying valid) and
            # says a caller that DOESN'T need the old reference back - this
            # one doesn't, $TargetPath/$script:pathHash never change mid-
            # session, so the new mutex always has the identical
            # "JxlLogMutex_<hash>" name - is responsible for disposing it
            # first itself. Without this, every FullLogging/
            # DisableSummaryFile toggle flip during a long session
            # abandoned one OS mutex handle to the finalizer for no
            # functional gain.
            $previousLogMutexForDispose = $script:logMutex
            & $InitializeLogMutexHandler
            if ($null -ne $previousLogMutexForDispose) { try { $previousLogMutexForDispose.Dispose() } catch { } }
            $LogFile        = $script:logFile
            $LogErrorFile   = $script:logErrorFile
            $LogWarnFile    = $script:logWarnFile
            $lastFullLogging        = $currentFullLogging
            $lastDisableSummaryFile = $currentDisableSummaryFile
        }
        # [bool](...) casts (2026-08-31 fix, caught by a same-day
        # /code-review): both -Enabled/-PermanentDelete are
        # [Parameter(Mandatory)][bool] - a $Settings hashtable missing
        # either key passes $null, which fails PowerShell's own boolean
        # type coercion with a hard, uncaught terminating error (this
        # loop has no local try/catch), killing the WHOLE run loop
        # instead of just degrading gracefully. Config.ps1 always defaults
        # both keys today, so this can't fire against a real settings
        # file - but any future caller building $Settings by hand (a
        # test, a script, a partial hashtable) hit a hard crash on the
        # very first iteration instead of a graceful $false. [bool]$null
        # correctly coerces to $false, same as PowerShell's own default
        # falsy treatment of a missing/null value everywhere else in this
        # project.
        Initialize-CleanConsoleOutput -Enabled ([bool]$Settings.CleanConsoleOutputEnabled)
        Initialize-FileDeletion -PermanentDelete ([bool]$Settings.PermanentDelete)

        # Set-AbortHandlerRunActive $true/$false around the actual run
        # (2026-08-31 addition, project owner's own explicit decision -
        # see AbortPipeline.ps1's ConsoleCtrl.RunActive comment for the
        # full reasoning): Ctrl+C is the dedicated abort key for an
        # active run, but at the menu there's nothing to abort - the
        # native handler now falls through to the OS's own default
        # Ctrl+C action there instead of catching it, closing a real leak
        # (a menu-time Ctrl+C used to set AbortRequested, which then
        # aborted THIS SAME iteration's freshly-dispatched run on its
        # very first poll, with no new Ctrl+C from the user) and a real
        # waste (the handler thread blocking up to 65s on a drain that
        # was never going to happen). try/finally so a crash inside the
        # run still clears it - Reset-AbortState's own defensive reset at
        # the top of the NEXT iteration is the second layer, not the
        # only one.
        # Start-LogRun (2026-09-03 fix, real bug caught by a same-session
        # /code-review pass - see Start-LogRun's own header for the full
        # story): must run EVERY iteration, not just when the
        # FullLogging/DisableSummaryFile re-sync above fires - unlike
        # Initialize-LogPaths (which only needs recomputing when the log
        # PATHS actually change), each run needs its own header and prior-
        # content snapshot captured fresh, or Complete-LogRun below has
        # nothing correct to reorder against for the 2nd+ run in a session.
        & $StartLogRunHandler
        & $SetRunActiveHandler -Active $true
        & $SetQuickEditHandler -Enabled $false
        $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $stats = & $InvokeModeHandler -Resolved $resolved -TargetPath $TargetPath -Settings $Settings -CjxlExe $CjxlExe -MagickExe $MagickExe `
                -LogFile $LogFile -LogErrorFile $LogErrorFile -LogWarnFile $LogWarnFile
        } finally {
            & $SetQuickEditHandler -Enabled $true
            & $SetRunActiveHandler -Active $false
        }
        $runStopwatch.Stop()

        # Complete-LogRun (2026-09-03 addition - split-log Errors/Warnings
        # now accumulate across runs, newest on top): every worker runspace
        # this run dispatched has already joined back by the time
        # $InvokeModeHandler returns, so it's safe to do the reorder here,
        # unconditionally, regardless of whether $stats came back $null - a
        # crashed/aborted run's own logged Errors/Warnings still deserve to
        # be promoted to the top like a normal run's would. Moved to AFTER
        # the $stats-null Warn below (2026-09-04 fix, real bug) - it used to
        # run BEFORE that Warn was logged, so the Warn landed appended at
        # the bottom of Warnings.txt, detached from its own run's just-
        # reordered header, and the NEXT run's Start-LogRun then captured it
        # as stale prior content, so it was never correctly reordered on any
        # later pass either - exactly the failure path a user is most
        # likely to go check the warnings file for.
        if ($null -eq $stats) {
            # Invoke-Mode's own shared catch already logged the real cause
            # (Invoke-AbortOrFatalHandler) - a $null return means the run
            # did NOT complete, so there is no real $stats to report.
            Write-Log "Run did not complete - see the error above." -Level Warn
            & $CompleteLogRunHandler
        } else {
            $elapsedString = Format-ElapsedTime -Elapsed $runStopwatch.Elapsed
            $summaryLines = Get-SummaryLines -Stats $stats -ElapsedString $elapsedString -ModeFlags $resolved
            # [bool](...) cast (2026-08-31 fix, from a THIRD same-day
            # /code-review pass) - Write-SummaryReport's -FullLogging is
            # also [Parameter(Mandatory)][bool] (Summary.ps1); missed by
            # both earlier passes even though the two calls right above
            # this one (Initialize-CleanConsoleOutput/Initialize-FileDeletion)
            # already got this exact cast.
            Write-SummaryReport -Lines $summaryLines -FullLogging $script:FullLogging
            & $CompleteLogRunHandler
        }

        $postRun = & $PostRunPromptHandler
        if ($postRun -eq 'Exit') { break }
        Write-Host ""
    }
}
