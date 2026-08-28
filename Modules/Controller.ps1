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
    before deciding: four of five only have try/finally at their outer
    scope (an exception already propagates this far as-is);
    Invoke-ZipOnlyPipeline is the one known outlier that currently
    swallows its own (ZipPipeline.ps1, tracked in Todo.md as a follow-up,
    NOT fixed by this change). Each pipeline call is injectable via a
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

    FORWARD REFERENCES (not defined in this module - callers must
    dot-source the owning module(s) first):
      - Write-Log, Invoke-MutexGuardedWrite (Logging.ps1)
      - Remove-Source, Move-ToRecycleBin, Remove-ItemPermanently,
        $script:PermanentDelete (FileDeletion.ps1) - the latter two
        because Remove-Source itself calls one of them internally based
        on $script:PermanentDelete, and a fresh runspace needs BOTH
        propagated since it can't know ahead of time which branch a
        given deletion will take
      - Convert-ImageBatch, Get-LooseImageCandidates,
        Remove-StaleLooseSources, Get-ChapterProgressStatus,
        Invoke-LooseImageConversionPipeline (ImageConversionPipeline.ps1)
      - Convert-AnimatedBatch, Get-LooseAnimatedCandidates,
        Get-ChapterAnimatedStatus, Invoke-LooseAnimatedConversionPipeline
        (AnimatedConversionPipeline.ps1)
      - Compress-FolderToZip (ZipCreation.ps1), Test-ZipArchive
        (ZipValidation.ps1) - called directly, NOT via ZipPipeline.ps1's
        Invoke-LooseFolderZip (see "ZIP-BLOCKING POLICY" above for why)
      - New-SeriesProvider, Get-SeriesChapters (LeafDirectoryDiscovery.ps1)
      - Invoke-ZipParallelProcessing (ZipParallelProcessing.ps1)
      - Register-AbortCancellationSource, Unregister-AbortCancellationSource,
        Test-AbortSignal, Invoke-AbortOrFatalHandler (AbortPipeline.ps1)
      - $script:CleanConsoleOutputEnabled, Start-SeriesProgress,
        Start-ChapterProgress, Complete-ChapterProgress,
        Complete-AllActiveSeriesProgress (CleanConsoleRendering.ps1)
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
        [int]$DoJpegQuality,
        [bool]$DoAnimatedLossless,
        [int]$AnimatedQuality,
        [bool]$DoAnimatedOverwrite,
        [bool]$DoAnimatedDeleteSource,
        [bool]$DoFullLogging,
        [string]$LogFile,
        [string]$LogErrorFile,
        [string]$LogWarnFile,
        [bool]$DoPermanentDelete,
        [bool]$CleanConsoleOutputEnabled,
        [System.Threading.SemaphoreSlim]$SharedBudget,
        [System.Threading.Mutex]$LogMutex,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ConsoleQueue,
        [System.Threading.CancellationToken]$CancelToken
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
            -SourceNoun "loose source image" -SharedBudget $SharedBudget
        return @{ EngineType = 'Image'; Result = $r }
    } else {
        $r = Convert-AnimatedBatch -AnimatedFiles $Files -MagickExe $MagickExe `
            -DoAnimatedLossless $DoAnimatedLossless -AnimatedQuality $AnimatedQuality -AnimatedThreads $Files.Count `
            -DoAnimatedOverwrite $DoAnimatedOverwrite -DoAnimatedDeleteSource $DoAnimatedDeleteSource `
            -DoFullLogging $DoFullLogging -CancelToken $CancelToken -SharedBudget $SharedBudget
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
        [System.Threading.CancellationTokenSource]$Cts
    )

    $jobParams = [System.Collections.Generic.List[hashtable]]::new()
    $ccrEnabled = [bool]$script:CleanConsoleOutputEnabled

    if ($ChapterImageFiles.Count -gt 0) {
        $jobParams.Add(@{
            EngineType = 'Image'; Files = $ChapterImageFiles
            CjxlExe = $CjxlExe; MagickExe = $MagickExe
            DoJpegLossless = $JpegLossless; DoJpegQuality = $JpegQuality
            DoAnimatedLossless = $false; AnimatedQuality = 90; DoAnimatedOverwrite = $false; DoAnimatedDeleteSource = $true
            DoFullLogging = $FullLogging; LogFile = $LogFile; LogErrorFile = $LogErrorFile; LogWarnFile = $LogWarnFile
            DoPermanentDelete = $PermanentDelete; CleanConsoleOutputEnabled = $ccrEnabled
            SharedBudget = $SharedBudget
        })
    }
    if ($ChapterAnimatedFiles.Count -gt 0) {
        $jobParams.Add(@{
            EngineType = 'Animated'; Files = $ChapterAnimatedFiles
            CjxlExe = $CjxlExe; MagickExe = $MagickExe
            DoJpegLossless = $false; DoJpegQuality = 90
            DoAnimatedLossless = $AnimatedLossless; AnimatedQuality = $AnimatedQuality
            DoAnimatedOverwrite = $AnimatedOverwrite; DoAnimatedDeleteSource = $AnimatedDeleteSource
            DoFullLogging = $FullLogging; LogFile = $LogFile; LogErrorFile = $LogErrorFile; LogWarnFile = $LogWarnFile
            DoPermanentDelete = $PermanentDelete; CleanConsoleOutputEnabled = $ccrEnabled
            SharedBudget = $SharedBudget
        })
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
            if ($r.EngineType -eq 'Image') { $resultBox.Image = $r.Result } else { $resultBox.Animated = $r.Result }
        }.GetNewClosure()

        $null = Invoke-ZipParallelProcessing -WorkerScript $script:fullPipelineChapterWorker -JobParams $jobParams `
            -SharedFunctionNames @('Write-Log', 'Invoke-MutexGuardedWrite', 'Remove-Source', 'Move-ToRecycleBin', 'Remove-ItemPermanently', 'Convert-ImageBatch', 'Convert-AnimatedBatch', 'Test-AvifAnimated') `
            -MaxParallel 2 -Cts $Cts -ResultHandler $resultHandler `
            -AbortWaitMessage "[ABORT] Waiting for current image/animated jobs to finish (up to 60s)..."

        $imageResult    = $resultBox.Image
        $animatedResult = $resultBox.Animated
    }

    $status, $detail = Get-MergedChapterStatus -ImageResult $imageResult -AnimatedResult $animatedResult

    $zipped    = $false
    $zipResult = $null
    if ($IsZippable -and $status -ne 'Error') {
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
           ZipCreatedSuccess; ZipCreatedFail; ZipSkippedDueToError;
           FolderDeletedSuccess; FolderDeletedFail;
           ForceKilledCount; InspectFailedCount; SeriesCount; ChapterCount;
           Aborted } - InspectFailedCount (added 2026-08-28) sums BOTH
        engines' own field of the same name (a real Test-AvifAnimated
        failure inside Convert-ImageBatch's new static-AVIF path, or
        Convert-AnimatedBatch's pre-existing one) - matches Summary.ps1's
        new InspectFailed row, which reads from either engine.
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
        [string[]]$LooseImageExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif"),
        [string[]]$AnimatedFileExtensions = @(".avif"),
        [string[]]$KnownZipPaths = @(),
        [string[]]$FolderQualifyingExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif"),
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

    $sharedBudget = [System.Threading.SemaphoreSlim]::new($FullPipelineMaxConcurrentProcs, $FullPipelineMaxConcurrentProcs)
    $fullCts = [System.Threading.CancellationTokenSource]::new()
    Register-AbortCancellationSource -Cts $fullCts
    try {
        $seriesProvider = New-SeriesProvider -LibraryPath $Path

        while ($true) {
            if (Test-AbortSignal) { $totals.Aborted = $true; break }

            $series = & $seriesProvider
            if ($null -eq $series) { break }
            $totals.SeriesCount++

            $chapters = Get-SeriesChapters -SeriesPath $series.FullName -QualifyingExtensions $FolderQualifyingExtensions `
                -ExcludeStagingDirs $FolderExcludeStagingDirs -ForceRezip $false

            $imageCandidates    = Get-LooseImageCandidates -ScanPath $series.FullName -LooseImageExtensions $LooseImageExtensions `
                -KnownZipPaths $KnownZipPaths -ExcludeStagingDirs $FolderExcludeStagingDirs
            $animatedCandidates = Get-LooseAnimatedCandidates -ScanPath $series.FullName -AnimatedFileExtensions $AnimatedFileExtensions `
                -KnownZipPaths $KnownZipPaths -ExcludeStagingDirs $FolderExcludeStagingDirs

            $staleResult = Remove-StaleLooseSources -StaleSources $imageCandidates.StaleSources
            $totals.StaleImageCleanedSuccess += $staleResult.Success
            $totals.StaleImageCleanedFail    += $staleResult.Fail

            $imagesByDir = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[System.IO.FileInfo]]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($img in $imageCandidates.NeedsConversion) {
                if (-not $imagesByDir.ContainsKey($img.DirectoryName)) { $imagesByDir[$img.DirectoryName] = [System.Collections.Generic.List[System.IO.FileInfo]]::new() }
                $imagesByDir[$img.DirectoryName].Add($img)
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
                $chapterEntries.Add(@{ Dir = $c.Dir; ZipOut = $c.ZipOut; IsZippable = $true })
            }
            $extraDirPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($k in $imagesByDir.Keys)    { if (-not $chapterDirSet.Contains($k)) { $null = $extraDirPaths.Add($k) } }
            foreach ($k in $animatedByDir.Keys)  { if (-not $chapterDirSet.Contains($k)) { $null = $extraDirPaths.Add($k) } }
            foreach ($extraDirPath in $extraDirPaths) {
                $extraDir = if ($imagesByDir.ContainsKey($extraDirPath)) { $imagesByDir[$extraDirPath][0].Directory } else { $animatedByDir[$extraDirPath][0].Directory }
                $chapterEntries.Add(@{ Dir = $extraDir; ZipOut = $null; IsZippable = $false })
                Write-Log ("Series '" + $series.Name + "': '" + $extraDir.Name + "' has unconverted content but wasn't found by chapter discovery (e.g. a stray .zip sitting alongside it, or files outside a normal chapter folder) - converting it anyway, but NOT treating it as zippable.") -Level Warn
            }

            if ($script:CleanConsoleOutputEnabled) {
                Start-SeriesProgress -SeriesName $series.Name -TotalChapters $chapterEntries.Count
            }

            if ($chapterEntries.Count -eq 0) {
                Write-Log ("Series '" + $series.Name + "': no qualifying chapters found.") -Level Info
                continue
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

                if ($chImages.Count -eq 0 -and $chAnimated.Count -eq 0) {
                    Write-Log ("Chapter '" + $chapterDir.FullName + "': no unconverted content - skipping conversion.")
                    $chapterOutcome = @{ ImageResult = $null; AnimatedResult = $null; Status = 'Success'; Detail = $null; Zipped = $false; ZipResult = $null }
                } else {
                    Write-Log ("Processing chapter: '" + $chapterDir.FullName + "' (" + $chImages.Count + " image(s), " + $chAnimated.Count + " animated file(s))")
                    $chapterOutcome = Invoke-FullPipelineChapter -ChapterDir $chapterDir.FullName -ChapterImageFiles $chImages -ChapterAnimatedFiles $chAnimated `
                        -IsZippable $chapter.IsZippable -ZipOut $chapter.ZipOut -CjxlExe $CjxlExe -MagickExe $MagickExe `
                        -JpegLossless $JpegLossless -JpegQuality $JpegQuality -AnimatedLossless $AnimatedLossless -AnimatedQuality $AnimatedQuality `
                        -AnimatedOverwrite $AnimatedOverwrite -AnimatedDeleteSource $AnimatedDeleteSource -FullLogging $FullLogging `
                        -LogFile $LogFile -LogErrorFile $LogErrorFile -LogWarnFile $LogWarnFile -PermanentDelete $PermanentDelete `
                        -SharedBudget $sharedBudget -Cts $fullCts
                }

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
                } elseif ($chapter.IsZippable -and $chapterOutcome.Status -eq 'Error') {
                    $totals.ZipSkippedDueToError++
                }

                if ($fullCts.Token.IsCancellationRequested) { $totals.Aborted = $true }

                if ($script:CleanConsoleOutputEnabled) {
                    $null = Complete-ChapterProgress -SeriesName $series.Name -ChapterName $chapterName -Status $chapterOutcome.Status -Detail $chapterOutcome.Detail
                }
            }
        }
    } finally {
        Unregister-AbortCancellationSource -Cts $fullCts
        $fullCts.Dispose()
        $sharedBudget.Dispose()
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
                $r = & $ImageConversionHandler -Path $TargetPath -CjxlExe $CjxlExe -MagickExe $MagickExe `
                    -JpegLossless $Settings.JpegLossless -JpegQuality $Settings.JpegQuality -MaxCjxlProcs $Settings.MaxCjxlProcs -FullLogging $Settings.FullLogging
                $stats.LooseImgConverted.Success = $r.ConvertedSuccess; $stats.LooseImgConverted.Fail = $r.ConvertedFail; $stats.LooseImgConverted.Skipped = $r.ConvertedSkipped
                $stats.LooseImgDeleted.Success   = $r.DeletedSuccess;   $stats.LooseImgDeleted.Fail   = $r.DeletedFail
                $stats.LooseStaleCleaned.Success = $r.StaleCleanedSuccess; $stats.LooseStaleCleaned.Fail = $r.StaleCleanedFail
                $stats.InspectFailed.Count       = $r.InspectFailedCount
            }
            'AnimatedConversion' {
                $r = & $AnimatedConversionHandler -Path $TargetPath -MagickExe $MagickExe `
                    -AnimatedLossless $Settings.AnimatedLossless -AnimatedQuality $Settings.AnimatedQuality -AnimatedThreads $Settings.AnimatedThreads `
                    -AnimatedOverwrite $Settings.AnimatedOverwrite -AnimatedDeleteSource $Settings.AnimatedDeleteSource -FullLogging $Settings.FullLogging
                $stats.LooseAnimatedConverted.Success = $r.ConvertedSuccess; $stats.LooseAnimatedConverted.Fail = $r.ConvertedFail; $stats.LooseAnimatedConverted.Skipped = $r.ConvertedSkipped
                $stats.LooseAnimatedDeleted.Success   = $r.DeletedSuccess;   $stats.LooseAnimatedDeleted.Fail   = $r.DeletedFail
                $stats.InspectFailed.Count            = $r.InspectFailedCount
            }
            'ZipFolders' {
                $r = & $ZipFoldersHandler -Path $TargetPath -MaxParallel $Settings.ZipParallelThreads -DeleteFolders $true `
                    -FullLogging $Settings.FullLogging -LogFile $LogFile -LogErrorFile $LogErrorFile -LogWarnFile $LogWarnFile -PermanentDelete $Settings.PermanentDelete
                $stats.ZipOnlyZipped.Success        = $r.ZippedSuccess;        $stats.ZipOnlyZipped.Fail        = $r.ZippedFail
                $stats.ZipOnlyFolderDeleted.Success = $r.FolderDeletedSuccess; $stats.ZipOnlyFolderDeleted.Fail = $r.FolderDeletedFail
            }
            'ConvertZipped' {
                $r = & $ConvertZippedHandler -Path $TargetPath -MaxParallel $Settings.ZipParallelThreads -DeleteFolders $Settings.DeleteExtractedFoldersAfterRezip `
                    -FullLogging $Settings.FullLogging -LogFile $LogFile -LogErrorFile $LogErrorFile -LogWarnFile $LogWarnFile -PermanentDelete $Settings.PermanentDelete `
                    -CjxlExe $CjxlExe -MagickExe $MagickExe -MaxCjxlProcs $Settings.MaxCjxlProcs -JpegLossless $Settings.JpegLossless -JpegQuality $Settings.JpegQuality
                $stats.ZipExtracted.Success  = $r.ZipExtractedSuccess;  $stats.ZipExtracted.Fail  = $r.ZipExtractedFail
                $stats.ImgConverted.Success  = $r.ImgConvertedSuccess; $stats.ImgConverted.Fail  = $r.ImgConvertedFail; $stats.ImgConverted.Skipped = $r.ImgConvertedSkipped
                $stats.ImgDeleted.Success    = $r.ImgDeletedSuccess;   $stats.ImgDeleted.Fail    = $r.ImgDeletedFail
                $stats.ZipCreated.Success    = $r.ZipCreatedSuccess;   $stats.ZipCreated.Fail    = $r.ZipCreatedFail
                $stats.FolderDeleted.Success = $r.FolderDeletedSuccess; $stats.FolderDeleted.Fail = $r.FolderDeletedFail
            }
            'FullPipeline' {
                $r = & $FullPipelineHandler -Path $TargetPath -CjxlExe $CjxlExe -MagickExe $MagickExe `
                    -JpegLossless $Settings.JpegLossless -JpegQuality $Settings.JpegQuality -AnimatedLossless $Settings.AnimatedLossless -AnimatedQuality $Settings.AnimatedQuality `
                    -AnimatedOverwrite $Settings.AnimatedOverwrite -AnimatedDeleteSource $Settings.AnimatedDeleteSource -FullPipelineMaxConcurrentProcs $Settings.MaxCjxlProcs `
                    -FullLogging $Settings.FullLogging -LogFile $LogFile -LogErrorFile $LogErrorFile -LogWarnFile $LogWarnFile -PermanentDelete $Settings.PermanentDelete
                $stats.LooseImgConverted.Success      = $r.ConvertedImageSuccess;    $stats.LooseImgConverted.Fail      = $r.ConvertedImageFail;    $stats.LooseImgConverted.Skipped = $r.ConvertedImageSkipped
                $stats.LooseImgDeleted.Success        = $r.DeletedImageSuccess;      $stats.LooseImgDeleted.Fail        = $r.DeletedImageFail
                $stats.LooseStaleCleaned.Success      = $r.StaleImageCleanedSuccess; $stats.LooseStaleCleaned.Fail      = $r.StaleImageCleanedFail
                $stats.LooseAnimatedConverted.Success = $r.ConvertedAnimatedSuccess; $stats.LooseAnimatedConverted.Fail = $r.ConvertedAnimatedFail; $stats.LooseAnimatedConverted.Skipped = $r.ConvertedAnimatedSkipped
                $stats.LooseAnimatedDeleted.Success   = $r.DeletedAnimatedSuccess;   $stats.LooseAnimatedDeleted.Fail   = $r.DeletedAnimatedFail
                $stats.LooseFolderZipped.Success      = $r.ZipCreatedSuccess;        $stats.LooseFolderZipped.Fail      = $r.ZipCreatedFail;        $stats.LooseFolderZipped.Skipped = $r.ZipSkippedDueToError
                $stats.LooseFolderDeleted.Success     = $r.FolderDeletedSuccess;     $stats.LooseFolderDeleted.Fail     = $r.FolderDeletedFail
                $stats.InspectFailed.Count            = $r.InspectFailedCount
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
                $zipLooseExtensions = if ($Settings.ZipWithUnconvertedAnimated) {
                    @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif")
                } else {
                    @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif")
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

                $r = & $ImageConversionHandler -Path $TargetPath -CjxlExe $CjxlExe -MagickExe $MagickExe `
                    -JpegLossless $Settings.JpegLossless -JpegQuality $Settings.JpegQuality -MaxCjxlProcs $Settings.MaxCjxlProcs -FullLogging $Settings.FullLogging `
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
        [string]$LogFile,
        [string]$LogErrorFile,
        [string]$LogWarnFile,
        [scriptblock]$GetModeHandler = ${function:Get-SelectedMode},
        [scriptblock]$InvokeModeHandler = ${function:Invoke-Mode},
        [scriptblock]$PostRunPromptHandler = ${function:Show-PostRunPrompt}
    )

    while ($true) {
        $resolved = & $GetModeHandler -Settings $Settings -SettingsPath $SettingsPath

        $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $stats = & $InvokeModeHandler -Resolved $resolved -TargetPath $TargetPath -Settings $Settings -CjxlExe $CjxlExe -MagickExe $MagickExe `
            -LogFile $LogFile -LogErrorFile $LogErrorFile -LogWarnFile $LogWarnFile
        $runStopwatch.Stop()

        if ($null -eq $stats) {
            # Invoke-Mode's own shared catch already logged the real cause
            # (Invoke-AbortOrFatalHandler) - a $null return means the run
            # did NOT complete, so there is no real $stats to report.
            Write-Log "Run did not complete - see the error above." -Level Warn
        } else {
            $elapsedString = Format-ElapsedTime -Elapsed $runStopwatch.Elapsed
            $summaryLines = Get-SummaryLines -Stats $stats -ElapsedString $elapsedString -ModeFlags $resolved
            Write-SummaryReport -Lines $summaryLines -FullLogging $Settings.FullLogging
        }

        $postRun = & $PostRunPromptHandler
        if ($postRun -eq 'Exit') { break }
        Write-Host ""
    }
}
