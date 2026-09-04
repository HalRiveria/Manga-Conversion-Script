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

    SCOPE - built 2026-08-28 against the design settled in Todo.md's
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

    CONCURRENCY MECHANICS: for each chapter, this module reuses
    Invoke-ZipParallelProcessing (ZipParallelProcessing.ps1) as the
    two-runspace dispatcher - NOT a hand-rolled runspace pool. Its
    -JobParams is a 1-or-2-entry list (one entry per engine that
    actually has files for this chapter - an engine with nothing to do
    is never dispatched at all, no runspace spun up for no work),
    -MaxParallel is always 2, and a single shared worker scriptblock
    ($script:fullPipelineChapterWorker) picks which engine to run based
    on an -EngineType job parameter. This reuses ALL of
    Invoke-ZipParallelProcessing's already-proven machinery (the
    InitialSessionState/SessionStateFunctionEntry function-propagation
    technique, the log-mutex/console-queue wiring, the graceful-drain/
    force-stop abort handling) rather than re-inventing a second, riskier
    copy of it from scratch - directly satisfying the confirmed design's
    "using the SAME function-propagation technique already proven in
    ZipParallelProcessing.ps1/RezipPipeline.ps1" language, not just its
    low-level ISS mechanism in isolation. Invoke-ZipParallelProcessing is
    called once PER CHAPTER (not once for the whole library) - real
    overhead (a fresh runspace pool + named log mutex per chapter), but
    the confirmed design is "always exactly two runspaces, not a general
    N-worker pool," and per-chapter granularity is what makes the
    simplest, most-reused-code version of that true.

    SHARED PROCESS BUDGET: a single System.Threading.SemaphoreSlim,
    sized to -FullPipelineMaxConcurrentProcs, created once per
    Invoke-FullPipeline call and passed into BOTH engines for EVERY
    chapter (as a real object reference - the same .NET object crosses
    into each runspace, so both dispatch loops truly share one counter).
    Convert-ImageBatch/Convert-AnimatedBatch (ImageConversionPipeline.ps1/
    AnimatedConversionPipeline.ps1, both gained an optional -SharedBudget
    parameter for this) each acquire a slot (non-blocking
    SemaphoreSlim.Wait(0)) before spawning a process and release it when
    that process exits, IGNORING their own -MaxCjxlProcs/-AnimatedThreads
    entirely whenever -SharedBudget is supplied - the shared budget IS
    the real ceiling in that mode. When -SharedBudget is $null (every
    existing solo mode - 2/3/8/9), both functions are byte-for-byte
    unchanged from before this session. Secondary process spawns (WebP
    pre-conversion, ICC-strip retry) do NOT get their own slot - already
    true and already shipped in solo mode (a slot's process is briefly a
    magick.exe THEN a cjxl.exe, sequentially, never two at once for that
    slot) - carrying that same behavior into the shared-budget case
    introduces no new risk.

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

    TOP-LEVEL DISPATCHER (Invoke-Mode) - built 2026-08-28, second build
    pass. Runs whichever mode Menu.ps1's Resolve-ModeSelection resolved,
    translating one $Settings hashtable into each real pipeline entry
    point's own param list (they were never unified - each was built
    independently with its own flat param list), and returns
    Summary.ps1's canonical $stats shape (New-StatsTracker) instead of
    that pipeline's own differently-named raw counters, so a caller can
    hand the result straight to Get-SummaryLines. One shared
    try/catch around the whole dispatch calls Invoke-AbortOrFatalHandler
    on anything that escapes - this is the "shared top-level catch, not
    per-pipeline copies" decision (Todo.md, 2026-08-28), verified
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
    ZipPipeline.ps1/RezipPipeline.ps1 dot-source, since every scenario
    overrides its handler explicitly (the real-function defaults only
    matter for an actual caller that doesn't override them).

    Mode 8 (ImageConversionZip) - real, built 2026-08-28 (Phase 2 of the
    build plan): dispatches to Invoke-LooseImageConversionPipeline with a
    real -ZipStepCallback closure that owns mode 8's own business logic
    (which extensions block zipping, based on
    $Settings.ZipWithUnconvertedAnimated) and calls Invoke-LooseFolderZip
    (ZipPipeline.ps1) via the injectable -ZipFolderHandler. Deliberately
    was a stub through Phase 1 - built here only once Invoke-Mode itself
    was proven standalone, touching no other module.

    Invoke-MainLoop (2026-08-28) - the run loop that used to live inline
    in the main script: resolve a mode (Get-SelectedMode), run it
    (Invoke-Mode), report it (Format-ElapsedTime/Get-SummaryLines/
    Write-SummaryReport), prompt to continue or exit
    (Show-PostRunPrompt). All four real functions are injectable, same
    DI pattern as Invoke-Mode's own pipeline handlers - a harness proves
    the LOOP's own control flow (iteration count, when it stops) without
    a real interactive prompt or real pipeline. New forward reference
    this brings in: Menu.ps1 (Get-SelectedMode, Show-PostRunPrompt) -
    Controller.ps1 never needed Menu.ps1 before this.

    AVIF CLASSIFICATION (2026-08-28, the Full-Pipeline AVIF race fix -
    see Todo.md's "Full-Pipeline AVIF race" entry for the full decision
    record). Invoke-FullPipeline's own -LooseImageExtensions default now
    includes .avif (previously excluded specifically to avoid this
    problem) - static AVIF gets converted here now too, for the same
    "consistency across the whole library" reason ImageConversionPipeline.ps1
    already converts it in every other mode. Since Get-LooseImageCandidates
    and Get-LooseAnimatedCandidates are two INDEPENDENT scans, both now
    discover the same .avif file, which would otherwise get dispatched
    to both engines' concurrently-running runspaces at once - a real
    race (one engine converting+deleting a file the other is still
    identifying). Fixed with a per-series reconciliation step, run once
    on the main thread BEFORE either engine's dispatch begins for that
    series: for every .avif file both scans agree on, Test-AvifAnimated
    decides ownership (static -> stays in the image list, animated ->
    stays in the animated list, removed from the other) - reuses
    Test-AvifAnimated UNCHANGED (a real magick identify process spawn;
    decided explicitly NOT to replace it with a cheap byte-level check
    for this fix). A file that can't be classified is removed from BOTH
    lists for that run (never guessed at, never left in either engine's
    hands), logged at -Level Error, and counted directly in
    Invoke-FullPipeline's own InspectFailedCount - not through either
    engine's own counter, since the failure happens here, before either
    engine ever sees the file. Scoped ONLY to Invoke-FullPipeline's own
    discovery - modes 2/3/8/9 call ImageConversionPipeline.ps1/
    AnimatedConversionPipeline.ps1 directly and keep their own existing
    internal checks unchanged; Full Pipeline is the only mode where two
    engines run concurrently over the same candidate set, so it's the
    only one that needs this. Written to classify by a Dictionary keyed
    on file path (Static/Animated/Failed) rather than two separate
    filter passes, so a file's classification can never disagree between
    the image-side filter and the animated-side filter - a real
    consideration, not just tidiness, since disagreeing filters would
    silently reopen the exact race this fix exists to close.

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
      - Convert-ImageBatch, Get-ImageConversionSharedFunctionNames,
        Get-LooseImageCandidates, Remove-StaleLooseSources,
        Get-ChapterProgressStatus, Invoke-LooseImageConversionPipeline
        (ImageConversionPipeline.ps1)
      - Convert-AnimatedBatch, Get-AnimatedConversionSharedFunctionNames,
        Get-LooseAnimatedCandidates, Get-ChapterAnimatedStatus,
        Invoke-LooseAnimatedConversionPipeline
        (AnimatedConversionPipeline.ps1)
      - Get-*SharedFunctionNames (2026-08-29, one per group above) are
        each module's own single source of truth for what a caller needs
        in -SharedFunctionNames to call into it from a runspace worker -
        $chapterWorkerSharedFunctionNames below concatenates all four
        instead of hand-typing every individual name, so a future new
        helper anywhere in this dependency chain only needs its own
        group's getter updated, not every caller across this codebase
        (the exact bug pattern that bit this project four times in one
        session - see CHANGELOG.md 2026-08-29). Deliberately does NOT
        cover Write-GatedConsoleMessage - see
        Get-ImageConversionSharedFunctionNames's own docstring for why.
      - Compress-FolderToZip (ZipCreation.ps1), Test-ZipArchive
        (ZipValidation.ps1) - called directly, NOT via ZipPipeline.ps1's
        Invoke-LooseFolderZip (see "ZIP-BLOCKING POLICY" above for why)
      - New-SeriesProvider, Get-SeriesChapters (LeafDirectoryDiscovery.ps1)
      - Invoke-ZipParallelProcessing (ZipParallelProcessing.ps1)
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
      - Invoke-RezipPipeline (RezipPipeline.ps1) - same caveat, for
        -ConvertZippedHandler
      - Invoke-LooseFolderZip (ZipPipeline.ps1) - same caveat, for
        -ZipFolderHandler (mode 8's real zip step, built 2026-08-28)
      - New-StatsTracker, Format-ElapsedTime, Get-SummaryLines,
        Write-SummaryReport (Summary.ps1) - the last three for
        Invoke-MainLoop specifically (2026-08-28), needed unconditionally
      - Get-SelectedMode, Show-PostRunPrompt (Menu.ps1) - Invoke-MainLoop
        only (2026-08-28), same caveat as the Invoke-Mode handlers above:
        only matters for a real caller that doesn't override
        -GetModeHandler/-PostRunPromptHandler
    Same dot-source ordering rule as ZipPipeline.ps1/RezipPipeline.ps1:
    Logging.ps1/FileDeletion.ps1 BEFORE ZipParallelProcessing.ps1, since
    -SharedFunctionNames captures whichever definition is CURRENTLY
    active in the caller's scope at call time.

.NOTES
    New module, no reference extraction (this coordination never existed
    in the original script - Full Pipeline is new functionality, see
    Menu.ps1's design). Built from the confirmed design in Todo.md's
    "Full Pipeline (per-chapter controller design)" section.
#>

# ---- Worker scriptblock, dispatched via Invoke-ZipParallelProcessing -
#      exactly 1 or 2 jobs per chapter (one per engine that has files
#      this chapter), never a general pool. Must declare
#      CancelToken/LogMutex/ConsoleQueue per ZPP's contract, plus this
#      chapter's own job parameters. Picks which engine to run via
#      -EngineType - one shared worker, not two near-identical copies. ----
$script:fullPipelineChapterWorker = {
    param(
        [string]$EngineType,
        [System.IO.FileInfo[]]$Files,
        [string]$CjxlExe,
        [string]$MagickExe,
        [bool]$DoJpegLossless,
        # = 90 on both quality params (2026-09-02 review fix): this
        # worker forwards each explicitly to Convert-ImageBatch/
        # Convert-AnimatedBatch's own -DoJpegQuality/-AnimatedQuality
        # (below), each of which already defaults to 90 - an omitted key
        # in the caller's job-params hashtable used to bind $0 here
        # instead, silently OVERRIDING that safe default with
        # maximum-loss encoding. Latent, not live (both real job-params
        # builders below always set both explicitly), but this worker's
        # own header comment documents "the worker's own $false/0
        # defaults apply to whatever a job's hashtable omits" as the
        # deliberate fallback contract - for these two fields specifically,
        # 0 was never a safe value for that contract to fall back to.
        [int]$DoJpegQuality = 90,
        [bool]$DoAnimatedLossless,
        [int]$AnimatedQuality = 90,
        [bool]$DoAnimatedOverwrite,
        # = $true (2026-09-02 review fix, same species as the two quality
        # defaults above): Convert-AnimatedBatch's own -DoAnimatedDeleteSource
        # already defaults to $true - an omitted key here used to bind
        # $false instead, silently flipping the module's real default
        # from delete-on-success to keep-the-source. Latent, not live
        # (Invoke-FullPipelineChapter always sets this key explicitly),
        # but a source .avif left behind gets swept into the chapter's
        # zip alongside its own .webp output, permanently, once the
        # folder is deleted after a successful zip.
        [bool]$DoAnimatedDeleteSource = $true,
        [bool]$DoFullLogging,
        [string]$LogFile,
        [string]$LogErrorFile,
        [string]$LogWarnFile,
        [bool]$DoPermanentDelete,
        [bool]$CleanConsoleOutputEnabled,
        [System.Threading.SemaphoreSlim]$SharedBudget,
        [System.Threading.Mutex]$LogMutex,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ConsoleQueue,
        [System.Threading.CancellationToken]$CancelToken,
        [System.Collections.Generic.HashSet[string]]$KnownAnimatedPaths,
        [System.Collections.Generic.HashSet[string]]$KnownStaticPaths
    )

    # A fresh runspace has no assemblies pre-loaded beyond the CLR
    # defaults - [Microsoft.VisualBasic.FileIO.FileSystem] (what
    # Move-ToRecycleBin, FileDeletion.ps1, actually calls) does NOT
    # resolve without this, confirmed by a live repro (a fresh runspace
    # pool, no Add-Type, throws "Unable to find type"). Same fix
    # RezipPipeline.ps1's own worker already needed and applied - Remove-
    # Source only calls Move-ToRecycleBin when $script:PermanentDelete is
    # $false (Recycle Bin, this project's DEFAULT), so this was a live
    # bug on the default settings, just never exercised by a harness
    # scenario (every Controller.Harness.ps1 run used -PermanentDelete
    # $true).
    Add-Type -AssemblyName "Microsoft.VisualBasic"

    # A fresh runspace shares nothing with the caller's scope - every
    # $script: value Write-Log/Remove-Source/Convert-*Batch need has to
    # be set here explicitly, same pattern RezipPipeline.ps1's own
    # worker already established.
    $script:logMutex                  = $LogMutex
    $script:workerConsoleQueue        = $ConsoleQueue
    $script:FullLogging               = $DoFullLogging
    $script:logFile                   = $LogFile
    $script:logErrorFile              = $LogErrorFile
    $script:logWarnFile               = $LogWarnFile
    $script:PermanentDelete           = $DoPermanentDelete
    $script:CleanConsoleOutputEnabled = $CleanConsoleOutputEnabled

    if ($EngineType -eq 'Image') {
        $r = Convert-ImageBatch -ImageFiles $Files -CjxlExe $CjxlExe -MagickExe $MagickExe `
            -DoJpegLossless $DoJpegLossless -DoJpegQuality $DoJpegQuality -MaxCjxlProcs $Files.Count `
            -DoFullLogging $DoFullLogging -CancelToken $CancelToken -ItemNoun "loose image" `
            -SourceNoun "loose source image" -SharedBudget $SharedBudget -KnownStaticPaths $KnownStaticPaths
        return @{ EngineType = 'Image'; Result = $r }
    } else {
        $r = Convert-AnimatedBatch -AnimatedFiles $Files -MagickExe $MagickExe `
            -DoAnimatedLossless $DoAnimatedLossless -AnimatedQuality $AnimatedQuality -AnimatedThreads $Files.Count `
            -DoAnimatedOverwrite $DoAnimatedOverwrite -DoAnimatedDeleteSource $DoAnimatedDeleteSource `
            -DoFullLogging $DoFullLogging -CancelToken $CancelToken -SharedBudget $SharedBudget -KnownAnimatedPaths $KnownAnimatedPaths
        return @{ EngineType = 'Animated'; Result = $r }
    }
}

function Get-MergedChapterStatus {
    <#
    .SYNOPSIS
        Merges an image ChapterResult and an animated ChapterResult (each
        possibly $null - nothing to convert for that engine this
        chapter) into ONE Status/Detail pair for Complete-ChapterProgress
        - confirmed 2026-08-28 design: concatenate both engines' own
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

function Invoke-FullPipelineChapter {
    <#
    .SYNOPSIS
        Runs ONE chapter's image + animated conversion concurrently
        (sharing -SharedBudget), merges both results into a single
        Status/Detail, and zips the chapter (via Compress-FolderToZip/
        Test-ZipArchive directly - see this module's header for why not
        Invoke-LooseFolderZip) only when -IsZippable is true AND neither
        engine reported an Error-tier failure. An engine with an empty
        file list for this chapter is never dispatched - no runspace
        spun up for nothing to do.
    .OUTPUTS
        @{ ImageResult; AnimatedResult; Status; Detail; Zipped;
           ZipResult } - ZipResult is @{ Status; ZipSize; EntryCount;
        FolderDeleted; FolderDeleteFailed }, or $null if Zipped is
        $false.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ChapterDir,
        [System.IO.FileInfo[]]$ChapterImageFiles = @(),
        [System.IO.FileInfo[]]$ChapterAnimatedFiles = @(),
        [bool]$IsZippable = $false,
        [string]$ZipOut = $null,
        [Parameter(Mandatory)]
        [string]$CjxlExe,
        [string]$MagickExe,
        [bool]$JpegLossless,
        [int]$JpegQuality = 90,
        [bool]$AnimatedLossless,
        [int]$AnimatedQuality = 90,
        [bool]$AnimatedOverwrite,
        [bool]$AnimatedDeleteSource = $true,
        [Parameter(Mandatory)]
        [bool]$FullLogging,
        [string]$LogFile,
        [string]$LogErrorFile,
        [string]$LogWarnFile,
        [Parameter(Mandatory)]
        [bool]$PermanentDelete,
        [Parameter(Mandatory)]
        [System.Threading.SemaphoreSlim]$SharedBudget,
        [Parameter(Mandatory)]
        [System.Threading.CancellationTokenSource]$Cts,
        [System.Collections.Generic.HashSet[string]]$KnownAnimatedPaths = $null,
        [System.Collections.Generic.HashSet[string]]$KnownStaticPaths = $null
    )

    $jobParams = [System.Collections.Generic.List[hashtable]]::new()
    $ccrEnabled = [bool]$script:CleanConsoleOutputEnabled

    # Shared base fields both engines need (2026-08-31 simplification -
    # was two hashtable literals each repeating every shared field AND
    # padding the OTHER engine's own fields with unused defaults, e.g. the
    # Image entry setting DoAnimatedLossless/AnimatedQuality/... it never
    # uses - already redundant even before this fix, since those padding
    # values matched what the worker's own unset-parameter defaults would
    # be anyway). Cloned per engine, then each adds only the fields it
    # actually uses - no padding needed since the worker's own $false/0
    # defaults apply to whatever a job's hashtable omits.
    $baseJobParams = @{
        CjxlExe = $CjxlExe; MagickExe = $MagickExe
        DoFullLogging = $FullLogging; LogFile = $LogFile; LogErrorFile = $LogErrorFile; LogWarnFile = $LogWarnFile
        DoPermanentDelete = $PermanentDelete; CleanConsoleOutputEnabled = $ccrEnabled
        SharedBudget = $SharedBudget
    }

    if ($ChapterImageFiles.Count -gt 0) {
        $imageJobParams = $baseJobParams.Clone()
        $imageJobParams.EngineType = 'Image'; $imageJobParams.Files = $ChapterImageFiles
        $imageJobParams.DoJpegLossless = $JpegLossless; $imageJobParams.DoJpegQuality = $JpegQuality
        $imageJobParams.KnownStaticPaths = $KnownStaticPaths
        $jobParams.Add($imageJobParams)
    }
    if ($ChapterAnimatedFiles.Count -gt 0) {
        $animatedJobParams = $baseJobParams.Clone()
        $animatedJobParams.EngineType = 'Animated'; $animatedJobParams.Files = $ChapterAnimatedFiles
        $animatedJobParams.DoAnimatedLossless = $AnimatedLossless; $animatedJobParams.AnimatedQuality = $AnimatedQuality
        $animatedJobParams.DoAnimatedOverwrite = $AnimatedOverwrite; $animatedJobParams.DoAnimatedDeleteSource = $AnimatedDeleteSource
        $animatedJobParams.KnownAnimatedPaths = $KnownAnimatedPaths
        $jobParams.Add($animatedJobParams)
    }

    $imageResult    = $null
    $animatedResult = $null

    if ($jobParams.Count -gt 0) {
        # Boxed in a hashtable, not a plain closed-over variable -
        # .GetNewClosure() puts $resultHandler in its own dynamic
        # module, so a plain "$imageResult = ..." write inside it would
        # silently mutate a disconnected copy the outer scope never
        # sees (see Docs/lessons-learned.md) - same discipline every
        # other closure in this project already follows.
        $resultBox = @{ Image = $null; Animated = $null }
        $resultHandler = {
            param($r)
            # elseif, not else (2026-08-31 fix, caught by a same-day
            # /code-review): Invoke-ZipParallelProcessing's own dispatch
            # loop passes EVERY object a worker's runspace emits to
            # -ResultHandler, not just its own explicit `return` value -
            # any stray, unsuppressed object anywhere in Convert-ImageBatch's
            # call chain would land here too. A bare `else` treated ANY
            # non-Image object as the animated result, silently overwriting
            # $resultBox.Animated (with $null, since a stray object's own
            # .Result is typically $null) - harmless-looking before today's
            # other fix, but that fix now turns a $null Animated result
            # into a synthesized "crashed" failure that blocks the
            # chapter's zip, so a false positive here got a real
            # consequence. No live repro exists (nothing today emits stray
            # output) - a pure robustness hardening, not a demonstrated bug.
            if ($r.EngineType -eq 'Image') { $resultBox.Image = $r.Result } elseif ($r.EngineType -eq 'Animated') { $resultBox.Animated = $r.Result }
        }.GetNewClosure()

        $chapterWorkerSharedFunctionNames = @(Get-LoggingSharedFunctionNames) + @(Get-FileDeletionSharedFunctionNames) + @(Get-ImageConversionSharedFunctionNames) + @(Get-AnimatedConversionSharedFunctionNames)
        $null = Invoke-ZipParallelProcessing -WorkerScript $script:fullPipelineChapterWorker -JobParams $jobParams `
            -SharedFunctionNames $chapterWorkerSharedFunctionNames `
            -MaxParallel 2 -Cts $Cts -ResultHandler $resultHandler `
            -AbortWaitMessage "[ABORT] Waiting for current image/animated jobs to finish (up to 60s)..."

        $imageResult    = $resultBox.Image
        $animatedResult = $resultBox.Animated

        # A DISPATCHED engine (Files.Count -gt 0, i.e. it has an entry in
        # $jobParams above) whose result never arrived means its runspace
        # was force-stopped past the graceful-drain timeout, or crashed
        # with an uncaught exception that ZipParallelProcessing.ps1's own
        # EndInvoke() try/catch swallowed into a log line without ever
        # calling -ResultHandler - NOT "nothing to convert", which is the
        # only legitimate reason Get-ChapterProgressStatus/
        # Get-ChapterAnimatedStatus treat a $null result as a clean
        # Success (an engine that was never dispatched at all because this
        # chapter had zero files for it). Without this check, a crashed or
        # force-stopped engine reads as a clean Success, so
        # $imageActuallyConverted below reads $false, Test-ZipArchive
        # doesn't even require a .jxl entry, and the chapter gets zipped
        # with that engine's files completely untouched while the run
        # silently reports success - see Todo.md.
        # -not $Cts.Token.IsCancellationRequested guard on the "treat as a
        # failure" branch (2026-08-31 fix): a Ctrl+C landing right at/before
        # this chapter's dispatch is a THIRD, legitimate reason a result
        # can be $null - Invoke-ZipParallelProcessing's own dispatch loop
        # never even starts a job once cancellation is already signaled,
        # and Invoke-GracefulDrain only drains what's already running, not
        # what was never dispatched. That's a normal, expected outcome of
        # a user-requested abort, not a crash - without this guard, a
        # clean cancellation was logged as a false "-Level Error" crash
        # and inflated ConvertedImageFail/ConvertedAnimatedFail for a run
        # that was never actually broken. The zip gate below already has
        # its own independent Cts check, so leaving $imageResult/
        # $animatedResult at $null here (mapped to a clean Status by
        # Get-MergedChapterStatus) doesn't risk a cancelled chapter
        # getting zipped anyway.
        if ($ChapterImageFiles.Count -gt 0 -and $null -eq $imageResult) {
            if ($Cts.Token.IsCancellationRequested) {
                Write-Log ("Image engine for chapter '" + $ChapterDir + "' never returned a result because the run was aborted before/during dispatch - not counted as a failure.") -Level Warn
            } else {
                Write-Log ("Image engine for chapter '" + $ChapterDir + "' never returned a result (crashed or force-stopped) - treating as a failure.") -Level Error
                $imageResult = @{ FailedCount = 1 }
            }
        }
        if ($ChapterAnimatedFiles.Count -gt 0 -and $null -eq $animatedResult) {
            if ($Cts.Token.IsCancellationRequested) {
                Write-Log ("Animated engine for chapter '" + $ChapterDir + "' never returned a result because the run was aborted before/during dispatch - not counted as a failure.") -Level Warn
            } else {
                Write-Log ("Animated engine for chapter '" + $ChapterDir + "' never returned a result (crashed or force-stopped) - treating as a failure.") -Level Error
                $animatedResult = @{ FailedCount = 1 }
            }
        }
    }

    $status, $detail = Get-MergedChapterStatus -ImageResult $imageResult -AnimatedResult $animatedResult

    $zipped    = $false
    $zipResult = $null
    # -not $Cts.Token.IsCancellationRequested (2026-08-31 fix): a Ctrl+C
    # landing between conversion finishing and this gate (or mid-batch,
    # draining cleanly with 0 failures - Convert-ImageBatch returns
    # normally either way) previously still zipped a chapter that's only
    # partially converted, then deleted its source folder - the abort
    # produced a misleadingly "successful", permanently-archived
    # half-converted chapter. Self-healing without this: any file left
    # loose (not yet converted) is picked up correctly on the next run's
    # scan (it's not .jxl yet, so it's still a NeedsConversion candidate);
    # already-converted files just aren't loose anymore, so a later run
    # with nothing left to convert zips the (by-then fully converted)
    # chapter normally.
    if ($IsZippable -and $status -ne 'Error' -and -not $Cts.Token.IsCancellationRequested) {
        # Compress-FolderToZip/Test-ZipArchive directly, NOT
        # Invoke-LooseFolderZip - its own "any remaining
        # $LooseImageExtensions file blocks zipping" guard treats .webp
        # as an unconverted image SOURCE (correct for mode 2, where .webp
        # only ever means that), but in Full Pipeline .webp is ALSO the
        # animated engine's own successful OUTPUT - a real, live-caught
        # collision (Scenario A's harness run: a chapter that fully
        # succeeded got its zip silently skipped, guard-blocked by its
        # own freshly-created anim1.webp). This module already has a
        # correct, complete gate (the merged Error-tier check above,
        # covering both engines) - re-scanning the folder for leftover
        # image extensions would be redundant even without the .webp
        # collision. Mirrors Invoke-LooseFolderZip's own success/delete/
        # fail shape, minus its guard and its own CCR wiring (this
        # function owns the chapter's one merged CCR transition itself).
        $zipResult = @{ Status = $null; ZipSize = 0; EntryCount = 0; FolderDeleted = $false; FolderDeleteFailed = $false }
        try {
            # Orphaned "_tmp_*" scratch files are deleted before zipping
            # here too (2026-08-31 fix, caught by verifying a same-day
            # /code-review 4th pass on ImageConversionPipeline.ps1, which
            # added the identical sweep to ZipPipeline.ps1's
            # Invoke-LooseFolderZip - Full Pipeline calls Compress-FolderToZip
            # DIRECTLY, per this function's own comment above, so it never
            # goes through that sweep) - job-generated intermediates (their
            # owning cleanup couldn't run - a force-killed process, a
            # locked file swallowed by a bare `catch {}`), always safe to
            # delete permanently regardless of $PermanentDelete, per this
            # project's own established deletion semantics. Without this,
            # Compress-FolderToZip below (a raw archive of the WHOLE
            # folder) permanently embeds the debris as a junk page, and the
            # only mode that produces "_tmp_overwrite.webp" in the first
            # place (-DoAnimatedOverwrite) only ever runs here.
            # Test-OrphanedScratchFileName (ImageConversionPipeline.ps1,
            # single source of truth, 2026-09-03 cleanup) - see its own
            # header for the full pattern reasoning.
            $orphanedScratchFiles = @(Get-ChildItem -LiteralPath $ChapterDir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { Test-OrphanedScratchFileName -Name $_.Name })
            foreach ($orphan in $orphanedScratchFiles) {
                # A failed delete (locked file, AV hold) is logged
                # explicitly rather than swallowed silently (2026-08-31
                # fix, caught by verifying a same-day /code-review pass -
                # CLAUDE.md's own review checklist: "no silent catches
                # without a reason"). Unlike ZipPipeline.ps1's own sibling
                # sweep, Full Pipeline has NO remaining-source guard after
                # this point - a failed delete here means the orphan gets
                # silently archived into the zip below and the folder
                # deleted right after, exactly the outcome this whole
                # sweep exists to prevent. The original "Deleting..." line
                # asserted success regardless of outcome.
                try {
                    [System.IO.File]::Delete($orphan.FullName)
                    Write-Log ("Deleted orphaned scratch file (its owning cleanup could not run earlier): '" + $orphan.FullName + "'") -Level Warn
                } catch {
                    Write-Log ("Could not delete orphaned scratch file '" + $orphan.FullName + "' - it will be archived into this chapter's zip: " + $_) -Level Error
                }
            }

            Write-Log ("Zipping '" + $ChapterDir + "' -> '" + $ZipOut + "'")
            $zipSize = Compress-FolderToZip -SourceDir $ChapterDir -ZipOut $ZipOut
            # -RequireJxlEntry only when the image engine actually
            # CONVERTED something to .jxl - NOT just "did this chapter
            # have image files queued". An animated-only chapter
            # legitimately has zero .jxl entries (just .webp), matching
            # Test-ZipArchive's own default ($true) being built for the
            # image-only world (found live via Scenario E). Checking
            # queued-count alone is a distinct, narrower bug: a chapter
            # whose only "image" files are all animated WebP (cjxl has
            # no multi-frame support, so Convert-ImageBatch SKIPS them,
            # not fails them - a legitimate Warning, not an Error) would
            # have ChapterImageFiles.Count > 0 but ConvertedCount == 0 -
            # genuinely zero .jxl entries despite "having image files" -
            # the old check would have wrongly required one and thrown.
            $imageActuallyConverted = ($null -ne $imageResult -and $imageResult.ConvertedCount -gt 0)
            $verify  = Test-ZipArchive -ZipPath $ZipOut -RequireJxlEntry $imageActuallyConverted

            Write-Log ("ZIP OK: '" + $ZipOut + "' (" + $zipSize + " bytes, " + $verify.EntryCount + " entries)")
            $zipResult.Status     = 'Success'
            $zipResult.ZipSize    = $zipSize
            $zipResult.EntryCount = $verify.EntryCount

            try {
                $null = Remove-Source -ItemPath $ChapterDir
                $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
                Write-Log ("Deleted folder (" + $deleteDesc + "): '" + $ChapterDir + "'")
                $zipResult.FolderDeleted = $true
            } catch {
                Write-Log ("FAILED to delete folder '" + $ChapterDir + "': " + $_) -Level Error
                $zipResult.FolderDeleteFailed = $true
            }
        } catch {
            Write-Log ("FAILED to zip '" + $ChapterDir + "': " + $_) -Level Error
            $zipResult.Status = 'Fail'
            # Remove a broken/partial zip left on disk (2026-09-02 review
            # fix, same species as the 2026-09-01 .jxl-discovery bug, and
            # the identical fix applied to ZipPipeline.ps1's own
            # Invoke-LooseFolderZip the same day): Compress-FolderToZip
            # cleans up after ITSELF on its own throw, but Test-ZipArchive
            # runs AFTER it, on an already-written file - a verification
            # failure left a real, complete-looking zip on disk with
            # nothing to delete it. Test-ZippableLeafDirCandidate's own
            # staleness guard then saw that fresh zip, newer than every
            # file in the folder, and skipped the chapter forever on
            # every later run - live-reproduced.
            try {
                if (Test-Path -LiteralPath $ZipOut) { [System.IO.File]::Delete($ZipOut) }
            } catch { }
        }
        $zipped = $true
    }

    return @{
        ImageResult    = $imageResult
        AnimatedResult = $animatedResult
        Status         = $status
        Detail         = $detail
        Zipped         = $zipped
        ZipResult      = $zipResult
    }
}

function Invoke-FullPipeline {
    <#
    .SYNOPSIS
        Mode 1 ("Full Pipeline") end to end: walks the library series by
        series (New-SeriesProvider), discovers each series' chapters
        (Get-SeriesChapters) plus any extra directory holding unconverted
        content of either type that discovery excluded (same coverage-
        completeness fix as both engines' own solo orchestrators, see
        this module's header), and runs each chapter through
        Invoke-FullPipelineChapter - image + animated conversion
        concurrently, sharing one process budget, zipped only on a clean
        (non-Error) outcome.
    .OUTPUTS
        @{ ConvertedImageSuccess; ConvertedImageFail; ConvertedImageSkipped;
           DeletedImageSuccess; DeletedImageFail;
           StaleImageCleanedSuccess; StaleImageCleanedFail;
           ConvertedAnimatedSuccess; ConvertedAnimatedFail; ConvertedAnimatedSkipped;
           DeletedAnimatedSuccess; DeletedAnimatedFail;
           ZipCreatedSuccess; ZipCreatedFail; ZipSkippedDueToError (despite
           the name, also counts a zippable chapter skipped because the run
           was aborted, AND a chapter forced un-zippable by an AVIF
           classification failure - neither is a genuine Error-tier
           chapter outcome, but both mean a chapter that should have
           zipped didn't - see this function's own 2026-08-31 fix notes
           below);
           FolderDeletedSuccess; FolderDeletedFail;
           ForceKilledCount; InspectFailedCount; SeriesCount; ChapterCount;
           Aborted } - InspectFailedCount (added 2026-08-28) sums BOTH
        engines' own field of the same name (a real Test-AvifAnimated
        failure inside Convert-ImageBatch's new static-AVIF path, or
        Convert-AnimatedBatch's pre-existing one) PLUS any AVIF
        classification failure this function's own per-series
        reconciliation hits directly (see "AVIF CLASSIFICATION" in this
        module's header) PLUS any Get-LooseImageCandidates
        NamingCollisions this run hit directly (2026-08-31) - matches
        Summary.ps1's new InspectFailed row, which reads from this one
        combined total either way.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$CjxlExe,
        # Deliberately NOT [Parameter(Mandatory)] (reviewed 2026-08-31): the
        # AVIF-ownership classification step below silently no-ops when
        # this is null/empty, which only matters if `.avif` is actually in
        # -LooseImageExtensions AND an ambiguous file is present. The real
        # guard against that combination is Invoke-Mode's own check
        # (`$Resolved.Mode -in @('AnimatedConversion','FullPipeline') -and
        # [string]::IsNullOrWhiteSpace($MagickExe)` -> throws before
        # dispatch) - CLAUDE.md's "validate at real trust boundaries, not
        # everywhere" argues against duplicating that check here too. A
        # caller that bypasses Invoke-Mode entirely (a direct call, a
        # future refactor) is responsible for its own MagickExe validation,
        # same as any other precondition Invoke-Mode enforces on this
        # function's behalf.
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
        # Get-LooseImageExtensions() PLUS ".jxl" (2026-09-01 live-shakedown
        # fix), not the bare loose list: that list is the "still needs
        # converting" set, correct for deciding what to CONVERT, but wrong
        # here - here it decides whether a chapter directory is even
        # DISCOVERED as real, zippable content (Get-SeriesChapters ->
        # Get-ZippableLeafDirs -> Test-ZippableLeafDirCandidate). A chapter
        # that Full Pipeline already finished converting has ONLY .jxl
        # files left (no loose source images remain) - with the bare loose
        # list, Test-ZippableLeafDirCandidate's qualifying-file check saw
        # zero matches and silently treated the whole chapter as "empty,
        # or nothing recognized", forever - confirmed live: a chapter
        # left with only .jxl content (e.g. a prior run's conversion step
        # finished but its zip step didn't) was never zipped by Full
        # Pipeline on a later run, no warning logged, while mode 3
        # (ZipPipeline.ps1's Invoke-ZipOnlyPipeline, whose own
        # -QualifyingExtensions default already includes ".jxl") zipped
        # the identical folder correctly. ".webp" needs no separate
        # addition - it's already in Get-LooseImageExtensions() and
        # doubles as the animated engine's own output extension.
        [string[]]$FolderQualifyingExtensions = ((Get-LooseImageExtensions) + @(".jxl")),
        [System.Collections.Generic.HashSet[string]]$FolderExcludeStagingDirs = $null
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

    # Construction/registration moved INSIDE the try (2026-08-31 fix, same
    # species as ZipParallelProcessing.ps1's mutex-leak fix earlier today) -
    # if either constructor or Register-AbortCancellationSource throws, the
    # finally block below still runs and disposes whichever of these two
    # was actually created (guarded, since a throw here can leave one or
    # both variables unset).
    try {
        $sharedBudget = [System.Threading.SemaphoreSlim]::new($FullPipelineMaxConcurrentProcs, $FullPipelineMaxConcurrentProcs)
        $fullCts = [System.Threading.CancellationTokenSource]::new()
        Register-AbortCancellationSource -Cts $fullCts
        $seriesProvider = New-SeriesProvider -LibraryPath $Path

        while ($true) {
            if (Test-AbortSignal) { $totals.Aborted = $true; break }

            $series = & $seriesProvider
            if ($null -eq $series) { break }
            $totals.SeriesCount++

            # Directories holding a file this series couldn't safely act
            # on - either the per-chapter AVIF classification step below
            # couldn't resolve it, OR Get-LooseImageCandidates flagged it
            # as an unresolvable naming collision (see its own
            # NamingCollisions field). Consulted when building
            # $chapterEntries further down to force IsZippable=$false for
            # any chapter affected by a naming collision (known up front,
            # series-wide); a classification failure adds to this same
            # set from INSIDE the per-chapter loop instead, once that
            # chapter's own avifs are actually classified - same
            # reasoning for both: a real, unconverted file that must not
            # be zipped, and this run has no safe way to fix it
            # automatically. Reset per series.
            $failedClassificationDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

            $chapters = Get-SeriesChapters -SeriesPath $series.FullName -QualifyingExtensions $FolderQualifyingExtensions `
                -ExcludeStagingDirs $FolderExcludeStagingDirs -ForceRezip $false

            $imageCandidates    = Get-LooseImageCandidates -ScanPath $series.FullName -LooseImageExtensions $LooseImageExtensions `
                -KnownZipPaths $KnownZipPaths -ExcludeStagingDirs $FolderExcludeStagingDirs
            $animatedCandidates = Get-LooseAnimatedCandidates -ScanPath $series.FullName -AnimatedFileExtensions $AnimatedFileExtensions `
                -KnownZipPaths $KnownZipPaths -ExcludeStagingDirs $FolderExcludeStagingDirs

            # NamingCollisions (2026-08-31 fix, from a same-day
            # /code-review): counted into the same combined
            # InspectFailedCount field the per-chapter AVIF classification
            # failure case below also uses, and its directory added to
            # $failedClassificationDirs so the chapter holding it isn't
            # treated as zippable - see that variable's own comment above,
            # and ImageConversionPipeline.ps1's Get-LooseImageCandidates
            # docstring for the full "why" of this exclusion.
            $totals.InspectFailedCount += $imageCandidates.NamingCollisions.Count
            foreach ($nc in $imageCandidates.NamingCollisions) { $null = $failedClassificationDirs.Add($nc.DirectoryName) }

            # AVIF CLASSIFICATION moved to per-chapter (2026-09-03 fix, real
            # bug, live-reported and quantified via two real user logs):
            # this used to be one series-wide pre-pass here, classifying
            # EVERY .avif across the WHOLE series (via Test-AvifAnimated,
            # a real synchronous `magick identify` process spawn taking
            # ~10-17s each) before any chapter began converting or logging
            # anything - a 100+-chapter series with a few hundred avifs
            # meant tens of minutes of complete silence before the first
            # chapter even started. Classification itself (what it does,
            # why it's needed - the image and animated engines' own
            # independent scans both discover the SAME .avif file, and
            # ownership must be resolved before either engine's dispatch
            # begins so neither ever sees a file that isn't theirs) is
            # unchanged - see the per-chapter block inside the loop below,
            # right before each chapter's own dispatch, scoped to just
            # that chapter's own avifs. This block now only builds the
            # RAW (unclassified) per-directory groupings the per-chapter
            # block reads from - no Test-AvifAnimated calls happen here.
            $imagesByDir = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[System.IO.FileInfo]]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($img in $imageCandidates.NeedsConversion) {
                if (-not $imagesByDir.ContainsKey($img.DirectoryName)) { $imagesByDir[$img.DirectoryName] = [System.Collections.Generic.List[System.IO.FileInfo]]::new() }
                $imagesByDir[$img.DirectoryName].Add($img)
            }
            # StaleSources grouped the same way (2026-09-03 addition) - used
            # to be deleted in one series-wide Remove-StaleLooseSources call
            # right here; now deleted per-chapter, right after that
            # chapter's own avifs (which may include a stale one) are
            # classified, for the same reason NeedsConversion moved: an
            # animated .avif kept on purpose (AnimatedDeleteSource=$false)
            # can look "stale" purely by basename match (see
            # ImageConversionPipeline.ps1's own known gap) and must not be
            # deleted before classification says it's safe to.
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

            # Same completeness fix as ImageConversionPipeline.ps1's own
            # PART 2, extended to cover BOTH file types: a directory
            # Get-SeriesChapters's guards excluded but that actually
            # holds unconverted content of either type is folded in as
            # an extra (IsZippable=$false/ZipOut=$null), deduped against
            # both maps at once so a dir with BOTH image and animated
            # leftovers isn't added twice.
            $chapterDirSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $chapterEntries = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($c in $chapters) {
                $null = $chapterDirSet.Add($c.Dir.FullName)
                # A chapter holding a file the AVIF classification step
                # above couldn't resolve must not be zipped this run -
                # see that step's own comment for why (a real bug this
                # fix's own harness caught: the unclassified source was
                # otherwise swept into the zip and its folder deleted
                # anyway, since neither engine's merged status has any
                # visibility into a failure that happened before either
                # of them ran).
                $isChapterZippable = -not $failedClassificationDirs.Contains($c.Dir.FullName)
                $chapterEntries.Add(@{ Dir = $c.Dir; ZipOut = $c.ZipOut; IsZippable = $isChapterZippable })
            }
            $extraDirPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($k in $imagesByDir.Keys)    { if (-not $chapterDirSet.Contains($k)) { $null = $extraDirPaths.Add($k) } }
            foreach ($k in $animatedByDir.Keys)  { if (-not $chapterDirSet.Contains($k)) { $null = $extraDirPaths.Add($k) } }
            # $staleByDir.Keys included too (2026-09-03 fix, real bug found by
            # code review): a directory already fully converted/zipped (so
            # excluded from $chapters by Get-SeriesChapters' own "up to date"
            # guard) but still holding a leftover stale source (e.g. a prior
            # run's delete failed on a locked file) was never folded in as an
            # extra dir before this - $chapterEntries only looked at
            # $imagesByDir/$animatedByDir, so that directory's own $chStale
            # entry (built further down, per chapter) was never reached and
            # its stale file was never passed to Remove-StaleLooseSources,
            # on this run or any future run (the same "up to date" gate
            # reproduces identically every time). No log line for THIS
            # reason specifically - stale-only extras are silent cleanup,
            # not "unconverted content", so the existing Warn below (written
            # for the image/animated case) would be misleading here.
            $staleOnlyExtraDirPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($k in $staleByDir.Keys) {
                if (-not $chapterDirSet.Contains($k) -and -not $extraDirPaths.Contains($k)) { $null = $staleOnlyExtraDirPaths.Add($k) }
            }
            foreach ($extraDirPath in $extraDirPaths) {
                $extraDir = if ($imagesByDir.ContainsKey($extraDirPath)) { $imagesByDir[$extraDirPath][0].Directory } else { $animatedByDir[$extraDirPath][0].Directory }
                $chapterEntries.Add(@{ Dir = $extraDir; ZipOut = $null; IsZippable = $false })
                Write-Log ("Series '" + $series.Name + "': '" + $extraDir.Name + "' has unconverted content but wasn't found by chapter discovery (e.g. a stray .zip sitting alongside it, or files outside a normal chapter folder) - converting it anyway, but NOT treating it as zippable.") -Level Warn
            }
            foreach ($extraDirPath in $staleOnlyExtraDirPaths) {
                $extraDir = $staleByDir[$extraDirPath][0].Directory
                $chapterEntries.Add(@{ Dir = $extraDir; ZipOut = $null; IsZippable = $false })
            }

            # Empty-series check moved BEFORE Start-SeriesProgress (2026-09-03
            # fix, real bug, live-reported): a series with zero qualifying
            # chapters (e.g. already fully converted and zipped - nothing
            # left but the zips + an info file) used to still register a
            # 0/0-chapter entry with CCR, which then sat on the live display
            # forever, never completed (the loop below never runs, so
            # Complete-ChapterProgress is never called for it either) -
            # project owner's own call: a series with nothing to convert
            # shouldn't show up on the console at all.
            if ($chapterEntries.Count -eq 0) {
                Write-Log ("Series '" + $series.Name + "': no qualifying chapters found.") -Level Info
                continue
            }

            if ($script:CleanConsoleOutputEnabled) {
                Start-SeriesProgress -SeriesName $series.Name -TotalChapters $chapterEntries.Count
            }

            Write-Log ("=== Series '" + $series.Name + "': " + $chapterEntries.Count + " chapter(s) ===")

            foreach ($chapter in $chapterEntries) {
                if (Test-AbortSignal) { $totals.Aborted = $true; break }

                $chapterDir  = $chapter.Dir
                $chapterName = $chapterDir.Name
                $totals.ChapterCount++

                if ($script:CleanConsoleOutputEnabled) {
                    Start-ChapterProgress -SeriesName $series.Name -ChapterName $chapterName
                }

                $chImages   = @(); if ($imagesByDir.ContainsKey($chapterDir.FullName))   { $chImages   = @($imagesByDir[$chapterDir.FullName]) }
                $chAnimated = @(); if ($animatedByDir.ContainsKey($chapterDir.FullName)) { $chAnimated = @($animatedByDir[$chapterDir.FullName]) }
                $chStale    = @(); if ($staleByDir.ContainsKey($chapterDir.FullName))    { $chStale    = @($staleByDir[$chapterDir.FullName]) }

                # PER-CHAPTER AVIF CLASSIFICATION (2026-09-03 fix - moved
                # from a series-wide pre-pass, see this function's own
                # header comment above $imagesByDir for the full "why").
                # Identical logic to the old series-wide block, just
                # scoped to this one chapter's own $chImages/$chAnimated/
                # $chStale instead of the whole series' candidate lists -
                # resolves ownership of any .avif both engines' scans
                # agree on, BEFORE this chapter's own dispatch begins, so
                # neither engine ever sees a file that isn't theirs.
                $chKnownAnimatedPaths = $null
                $chKnownStaticPaths   = $null
                $chapterClassificationFailed = $false
                if ($MagickExe -and ($LooseImageExtensions -icontains ".avif") -and $chAnimated.Count -gt 0) {
                    $chAnimatedPathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($af in $chAnimated) { $null = $chAnimatedPathSet.Add($af.FullName) }

                    $chAvifClassification = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($img in (@($chImages) + @($chStale))) {
                        if ($img.Extension -ine ".avif" -or -not $chAnimatedPathSet.Contains($img.FullName) -or $chAvifClassification.ContainsKey($img.FullName)) {
                            continue   # not .avif, not claimed by both scans, or already classified
                        }
                        try {
                            $isAnimated = Test-AvifAnimated -AvifPath $img.FullName -MagickExe $MagickExe
                            $chAvifClassification[$img.FullName] = if ($isAnimated) { "Animated" } else { "Static" }
                        } catch {
                            Write-Log ("Could not determine if AVIF '" + $img.FullName + "' is animated - excluding it from BOTH engines this run: " + $_) -Level Error
                            $totals.InspectFailedCount++
                            $chAvifClassification[$img.FullName] = "Failed"
                        }
                    }

                    if ($chAvifClassification.Count -gt 0) {
                        # Static is safe to keep in either list (safe to
                        # convert if in $chImages, safe to delete as stale
                        # if in $chStale, since its own .jxl already
                        # exists); only Animated/Failed need to be pulled
                        # OUT so the stale-cleanup below doesn't delete a
                        # file the animated engine (Animated) or neither
                        # engine (Failed, ownership unresolved) should be
                        # touching.
                        $keepIfStatic = { -not $chAvifClassification.ContainsKey($_.FullName) -or $chAvifClassification[$_.FullName] -eq "Static" }
                        $chImages = @($chImages | Where-Object $keepIfStatic)
                        $chStale  = @($chStale  | Where-Object $keepIfStatic)
                        $chAnimated = @($chAnimated | Where-Object {
                            -not $chAvifClassification.ContainsKey($_.FullName) -or $chAvifClassification[$_.FullName] -eq "Animated"
                        })
                        $chKnownAnimatedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                        $chKnownStaticPaths   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                        foreach ($entry in $chAvifClassification.GetEnumerator()) {
                            if ($entry.Value -eq "Failed") {
                                $chapterClassificationFailed = $true
                                $null = $failedClassificationDirs.Add($chapterDir.FullName)
                            } elseif ($entry.Value -eq "Animated") {
                                $null = $chKnownAnimatedPaths.Add($entry.Key)
                            } elseif ($entry.Value -eq "Static") {
                                $null = $chKnownStaticPaths.Add($entry.Key)
                            }
                        }
                    }
                }

                # A chapter holding a file this chapter's own classification
                # step just above couldn't resolve, OR a naming collision
                # (known series-wide, before this loop) must NOT be zipped
                # this run - live-caught via this fix's own harness: without
                # this, the unclassified source got swept into the zip in
                # its raw, unconverted form and its loose folder deleted
                # anyway, since neither engine's own merged status has any
                # visibility into a failure that happened before either of
                # them ran. $isZippableNow, not $chapter.IsZippable, is used
                # for the rest of this iteration - $chapter.IsZippable was
                # computed before this chapter's own classification ran, so
                # it can't yet reflect a failure discovered just above.
                $isZippableNow = $chapter.IsZippable -and -not $chapterClassificationFailed

                $staleResult = Remove-StaleLooseSources -StaleSources $chStale
                $totals.StaleImageCleanedSuccess += $staleResult.Success
                $totals.StaleImageCleanedFail    += $staleResult.Fail

                # Always calls Invoke-FullPipelineChapter, even with zero
                # files for both engines (2026-08-31 fix) - it already
                # handles that case correctly on its own (both engines stay
                # undispatched, $imageResult/$animatedResult stay $null,
                # which Get-MergedChapterStatus correctly reads as a clean
                # Success), and STILL attempts the zip step when
                # -IsZippable is true. The removed special case here used
                # to shortcut straight to `Zipped = $false` without ever
                # trying - harmless for a chapter that had never been
                # touched, but wrong for one that a PRIOR, Ctrl+C-interrupted
                # run had already fully converted: with nothing left to
                # convert, this branch always fired and the chapter was
                # never zipped, on ANY future run, permanently stranding it
                # loose - the "self-healing" claim this session's earlier
                # Cts-based zip-gate fix made was false. Removing the
                # special case in favor of the one general code path (which
                # already gets this right) closes it for good instead of
                # teaching the special case the same lesson twice.
                if ($chImages.Count -eq 0 -and $chAnimated.Count -eq 0) {
                    Write-Log ("Chapter '" + $chapterDir.FullName + "': no unconverted content - checking whether it still needs zipping.")
                } else {
                    Write-Log ("Processing chapter: '" + $chapterDir.FullName + "' (" + $chImages.Count + " image(s), " + $chAnimated.Count + " animated file(s))")
                }
                $chapterOutcome = Invoke-FullPipelineChapter -ChapterDir $chapterDir.FullName -ChapterImageFiles $chImages -ChapterAnimatedFiles $chAnimated `
                    -IsZippable $isZippableNow -ZipOut $chapter.ZipOut -CjxlExe $CjxlExe -MagickExe $MagickExe `
                    -JpegLossless $JpegLossless -JpegQuality $JpegQuality -AnimatedLossless $AnimatedLossless -AnimatedQuality $AnimatedQuality `
                    -AnimatedOverwrite $AnimatedOverwrite -AnimatedDeleteSource $AnimatedDeleteSource -FullLogging $FullLogging `
                    -LogFile $LogFile -LogErrorFile $LogErrorFile -LogWarnFile $LogWarnFile -PermanentDelete $PermanentDelete `
                    -SharedBudget $sharedBudget -Cts $fullCts -KnownAnimatedPaths $chKnownAnimatedPaths -KnownStaticPaths $chKnownStaticPaths

                if ($null -ne $chapterOutcome.ImageResult) {
                    $ir = $chapterOutcome.ImageResult
                    $totals.ConvertedImageSuccess += $ir.ConvertedCount
                    $totals.ConvertedImageFail    += $ir.FailedCount
                    $totals.ConvertedImageSkipped += $ir.SkippedCount
                    $totals.DeletedImageSuccess   += $ir.DeletedCount
                    $totals.DeletedImageFail      += $ir.DeleteFailedCount
                    $totals.ForceKilledCount      += $ir.ForceKilledCount
                    $totals.InspectFailedCount    += $ir.InspectFailedCount
                }
                if ($null -ne $chapterOutcome.AnimatedResult) {
                    $ar = $chapterOutcome.AnimatedResult
                    $totals.ConvertedAnimatedSuccess += $ar.ConvertedCount
                    $totals.ConvertedAnimatedFail    += $ar.FailedCount
                    $totals.ConvertedAnimatedSkipped += $ar.SkippedCount
                    $totals.DeletedAnimatedSuccess   += $ar.DeletedCount
                    $totals.DeletedAnimatedFail      += $ar.DeleteFailedCount
                    $totals.ForceKilledCount         += $ar.ForceKilledCount
                    $totals.InspectFailedCount       += $ar.InspectFailedCount
                }

                if ($chapterOutcome.Zipped) {
                    if ($chapterOutcome.ZipResult.Status -eq 'Success') {
                        $totals.ZipCreatedSuccess++
                        if ($chapterOutcome.ZipResult.FolderDeleted)     { $totals.FolderDeletedSuccess++ }
                        if ($chapterOutcome.ZipResult.FolderDeleteFailed) { $totals.FolderDeletedFail++ }
                    } else {
                        $totals.ZipCreatedFail++
                    }
                } elseif ($isZippableNow -and ($chapterOutcome.Status -eq 'Error' -or $fullCts.Token.IsCancellationRequested)) {
                    # -or $fullCts.Token.IsCancellationRequested (2026-08-31
                    # fix, caught by a same-day /code-review): the Cts-based
                    # zip gate added earlier today blocks a zip whenever the
                    # run is aborted, even when the chapter's own Status is
                    # a clean 'Success' (the engines finished normally
                    # before the abort was noticed) - that case fell through
                    # this elseif entirely before, so an abort-blocked
                    # chapter was invisible in the run's own summary beyond
                    # the overall $totals.Aborted flag. Counted into the
                    # SAME field as an Error-tier skip rather than a new one
                    # - the two combined ($totals.Aborted also being set)
                    # still correctly distinguishes "N zippable chapters
                    # didn't get zipped, and the run was aborted" from a
                    # genuine Error found on some chapter in a normal run.
                    $totals.ZipSkippedDueToError++
                } elseif (-not $isZippableNow -and $failedClassificationDirs.Contains($chapterDir.FullName)) {
                    # 2026-08-31 fix: a chapter forced un-zippable because
                    # $failedClassificationDirs contains its directory
                    # (IsZippable was already $false, so the elseif above
                    # never fires for it - it requires IsZippable) was
                    # invisible in every one of this run's own zip-outcome
                    # counters, even though the underlying failure itself IS
                    # independently counted in InspectFailedCount. Despite
                    # the field's own name, $failedClassificationDirs now
                    # collects TWO distinct reasons (an AVIF classification
                    # failure, or a Get-LooseImageCandidates naming
                    # collision - see where each is added to this set,
                    # above) - both mean the same thing here: a real,
                    # unconverted file this chapter can't safely zip.
                    # Counted into the same ZipSkippedDueToError field, same
                    # reasoning as the abort case above - it correctly
                    # reflects "this chapter should have zipped and didn't,"
                    # regardless of which of the two reasons caused it.
                    $totals.ZipSkippedDueToError++
                }

                if ($fullCts.Token.IsCancellationRequested) { $totals.Aborted = $true }

                if ($script:CleanConsoleOutputEnabled) {
                    $null = Complete-ChapterProgress -SeriesName $series.Name -ChapterName $chapterName -Status $chapterOutcome.Status -Detail $chapterOutcome.Detail
                }
            }
        }
    } finally {
        # $fullCts/$sharedBudget can be unset if construction/registration
        # itself threw (now inside the try above) - guard each disposal
        # independently rather than assuming both exist.
        if ($fullCts) {
            Unregister-AbortCancellationSource -Cts $fullCts
            $fullCts.Dispose()
        }
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
    .PARAMETER ConvertZippedHandler
    .PARAMETER FullPipelineHandler
        Each real pipeline entry point, injectable for testing with
        fakes - default to the real function. A harness scenario that
        overrides every handler it exercises never needs the default to
        resolve at all, so it never needs Invoke-Mode's own harness to
        dot-source ZipPipeline.ps1/RezipPipeline.ps1 - see this module's
        header.
    .PARAMETER ZipFolderHandler
        Mode 8's real zip step (2026-08-28, Phase 2) - defaults to
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
        [scriptblock]$ConvertZippedHandler = ${function:Invoke-RezipPipeline},
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
                # ZipFolders/ConvertZipped/FullPipeline cases below,
                # missed here in the original pass: FullLogging is
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
            'ConvertZipped' {
                # Deliberately NOT given the Aborted/ForceKilledCount mapping
                # its 'ZipFolders'/'ImageConversionZip' siblings got
                # 2026-09-03 - RezipPipeline.ps1 (this mode's handler) has no
                # Aborted field at all (same gap ZipPipeline.ps1 had until
                # today), and mode 9 is hidden from the live menu (deprecated/
                # minimal-effort direction, see RezipPipeline.ps1's own
                # header) - not worth adding a new field to a deprioritized,
                # unreachable-from-the-menu pipeline.
                # [bool](...) casts - same reasoning as the ZipFolders case above.
                $r = & $ConvertZippedHandler -Path $TargetPath -MaxParallel $Settings.ZipParallelThreads -DeleteFolders ([bool]$Settings.DeleteExtractedFoldersAfterRezip) `
                    -FullLogging $script:FullLogging -LogFile $LogFile -LogErrorFile $LogErrorFile -LogWarnFile $LogWarnFile -PermanentDelete ([bool]$Settings.PermanentDelete) `
                    -CjxlExe $CjxlExe -MagickExe $MagickExe -MaxCjxlProcs $Settings.MaxCjxlProcs -JpegLossless ([bool]$Settings.JpegLossless) -JpegQuality $Settings.JpegQuality
                $stats.ZipExtracted.Success  = $r.ZipExtractedSuccess;  $stats.ZipExtracted.Fail  = $r.ZipExtractedFail
                $stats.ImgConverted.Success  = $r.ImgConvertedSuccess; $stats.ImgConverted.Fail  = $r.ImgConvertedFail; $stats.ImgConverted.Skipped = $r.ImgConvertedSkipped
                $stats.ImgDeleted.Success    = $r.ImgDeletedSuccess;   $stats.ImgDeleted.Fail    = $r.ImgDeletedFail
                $stats.ZipCreated.Success    = $r.ZipCreatedSuccess;   $stats.ZipCreated.Fail    = $r.ZipCreatedFail
                $stats.FolderDeleted.Success = $r.FolderDeletedSuccess; $stats.FolderDeleted.Fail = $r.FolderDeletedFail
            }
            'FullPipeline' {
                # [bool](...) casts - same reasoning as the ZipFolders case above.
                $r = & $FullPipelineHandler -Path $TargetPath -CjxlExe $CjxlExe -MagickExe $MagickExe `
                    -JpegLossless ([bool]$Settings.JpegLossless) -JpegQuality $Settings.JpegQuality -AnimatedLossless ([bool]$Settings.AnimatedLossless) -AnimatedQuality $Settings.AnimatedQuality `
                    -AnimatedOverwrite ([bool]$Settings.AnimatedOverwrite) -AnimatedDeleteSource ([bool]$Settings.AnimatedDeleteSource) -FullPipelineMaxConcurrentProcs $Settings.FullPipelineMaxConcurrentProcs `
                    -FullLogging $script:FullLogging -LogFile $LogFile -LogErrorFile $LogErrorFile -LogWarnFile $LogWarnFile -PermanentDelete ([bool]$Settings.PermanentDelete)
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
                    $zipResult = & $ZipFolderHandler -FolderPath $Info.Dir.FullName -ZipOut $Info.ZipOut -LooseImageExtensions $zipLooseExtensions
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
        $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $stats = & $InvokeModeHandler -Resolved $resolved -TargetPath $TargetPath -Settings $Settings -CjxlExe $CjxlExe -MagickExe $MagickExe `
                -LogFile $LogFile -LogErrorFile $LogErrorFile -LogWarnFile $LogWarnFile
        } finally {
            & $SetRunActiveHandler -Active $false
        }
        $runStopwatch.Stop()

        # Complete-LogRun (2026-09-03 addition - split-log Errors/Warnings
        # now accumulate across runs, newest on top): every worker runspace
        # this run dispatched has already joined back by the time
        # $InvokeModeHandler returns, so it's safe to do the reorder here,
        # unconditionally, regardless of whether $stats came back $null - a
        # crashed/aborted run's own logged Errors/Warnings still deserve to
        # be promoted to the top like a normal run's would.
        & $CompleteLogRunHandler

        if ($null -eq $stats) {
            # Invoke-Mode's own shared catch already logged the real cause
            # (Invoke-AbortOrFatalHandler) - a $null return means the run
            # did NOT complete, so there is no real $stats to report.
            Write-Log "Run did not complete - see the error above." -Level Warn
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
        }

        $postRun = & $PostRunPromptHandler
        if ($postRun -eq 'Exit') { break }
        Write-Host ""
    }
}
