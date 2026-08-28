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

    NOT BUILT HERE (see this module's own header intro and Todo.md):
    the top-level dispatcher role (running every mode, not just Full
    Pipeline) and Show-PostRunPrompt's run-loop - both confirmed in
    scope, deliberately not designed yet.

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
        Remove-StaleLooseSources, Get-ChapterProgressStatus
        (ImageConversionPipeline.ps1)
      - Convert-AnimatedBatch, Get-LooseAnimatedCandidates,
        Get-ChapterAnimatedStatus (AnimatedConversionPipeline.ps1)
      - Compress-FolderToZip (ZipCreation.ps1), Test-ZipArchive
        (ZipValidation.ps1) - called directly, NOT via ZipPipeline.ps1's
        Invoke-LooseFolderZip (see "ZIP-BLOCKING POLICY" above for why)
      - New-SeriesProvider, Get-SeriesChapters (LeafDirectoryDiscovery.ps1)
      - Invoke-ZipParallelProcessing (ZipParallelProcessing.ps1)
      - Register-AbortCancellationSource, Unregister-AbortCancellationSource,
        Test-AbortSignal (AbortPipeline.ps1)
      - $script:CleanConsoleOutputEnabled, Start-SeriesProgress,
        Start-ChapterProgress, Complete-ChapterProgress,
        Complete-AllActiveSeriesProgress (CleanConsoleRendering.ps1)
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
            # -RequireJxlEntry only when this chapter actually had image
            # files - an animated-only chapter's zip legitimately has
            # ZERO .jxl entries (just .webp), and Test-ZipArchive's own
            # default ($true) is built for the image-only world. Found
            # live via this module's own harness (Scenario E: a real,
            # fully-successful animated-only chapter's zip was rejected
            # by this exact default).
            $verify  = Test-ZipArchive -ZipPath $ZipOut -RequireJxlEntry ($ChapterImageFiles.Count -gt 0)

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
           ForceKilledCount; SeriesCount; ChapterCount; Aborted }
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
                }
                if ($null -ne $chapterOutcome.AnimatedResult) {
                    $ar = $chapterOutcome.AnimatedResult
                    $totals.ConvertedAnimatedSuccess += $ar.ConvertedCount
                    $totals.ConvertedAnimatedFail    += $ar.FailedCount
                    $totals.ConvertedAnimatedSkipped += $ar.SkippedCount
                    $totals.DeletedAnimatedSuccess   += $ar.DeletedCount
                    $totals.DeletedAnimatedFail      += $ar.DeleteFailedCount
                    $totals.ForceKilledCount         += $ar.ForceKilledCount
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
