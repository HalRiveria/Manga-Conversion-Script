<#
.SYNOPSIS
    ZipPipeline - all zip-domain orchestration that isn't the parallel-
    dispatch engine itself: mode 3 (zip-only) end to end, and mode 8's
    per-folder zip step.

.DESCRIPTION
    Pure definitions only - no top-level side effects (assigning the
    $script:zipOnlyWorker scriptblock literal is inert, same category as
    AbortPipeline.ps1's $script:abortCancellationSources list init) -
    safe to dot-source more than once or alongside other modules.

    Per the reference extraction's ARCHITECTURE decision: any zip logic
    lives here, not scattered across whichever mode happens to need it.
    Covers PART 1 (mode 3, zip-only pipeline) and PART 2 (mode 8's
    per-folder zip step, which runs right after ImageConversionPipeline
    converts each batch - see that module's own PART 2 for the orchestration
    this was pulled out of). PART 2 was built against an earlier menu
    design where this was called "mode 2" - the menu was renumbered
    (Menu.ps1) before PART 2 got wired up for real, so every "mode 2"
    reference below actually means what's now mode 8 ("Image Conversion +
    Zip") - see Controller.ps1's Invoke-Mode, the real -ZipFolderHandler
    caller.

    NOT YET DECIDED (explicitly flagged, not acted on): whether
    RezipPipeline (mode 4) should call into this module instead of
    duplicating zip creation/validation inline. See RezipPipeline's own
    reference file and CLAUDE.md.

    FORWARD REFERENCES (not defined in this module - callers must
    dot-source the owning module(s) first):
      - Write-Log, Get-LoggingSharedFunctionNames (Logging.ps1)
      - Move-ToRecycleBin, Remove-ItemPermanently, Remove-Source,
        Get-FileDeletionSharedFunctionNames (FileDeletion.ps1)
      - Compress-FolderToZip, Get-ZipCreationSharedFunctionNames (ZipCreation.ps1)
      - Test-ZipArchive, Get-ZipValidationSharedFunctionNames (ZipValidation.ps1)
      - Get-*SharedFunctionNames (2026-08-29) are each module's own single
        source of truth for what a caller needs in -SharedFunctionNames -
        see Controller.ps1's own header for the full reasoning.
      - New-ZippableLeafDirProvider (LeafDirectoryDiscovery.ps1) -
        incremental leaf discovery, not the full-scan Get-ZippableLeafDirs
        (see "INCREMENTAL SCANNING" below)
      - Invoke-ZipParallelProcessing (ZipParallelProcessing.ps1) - mode 3
        is ZPP's one current caller; this is where that wiring lives.
      - Register-AbortCancellationSource, Unregister-AbortCancellationSource
        (AbortPipeline.ps1) - added 2026-08-27 once ZPP migrated onto
        AbortPipeline.ps1's registry (see "ABORT WIRING NOTE" below);
        ZPP itself also now forward-references AbortPipeline.ps1/
        Logging.ps1 directly, so both must be dot-sourced before ZPP.
    Modules\_Harness\ZipPipeline.Harness.ps1 dot-sources all of the above
    real, already-built modules (this is the first module built with
    enough real dependencies available to test against the genuine
    things instead of stubs for most of them - only Write-Log is stubbed,
    so log output can be inspected by the harness).

    IMPORTANT ordering note for any caller: dot-source Logging.ps1 (and
    FileDeletion.ps1) BEFORE ZipParallelProcessing.ps1. ZipParallelProcessing.ps1
    has its own inline (and currently stale - see CLAUDE.md "Known gaps")
    copies of Write-Log/Move-ToRecycleBin/etc. Invoke-ZipParallelProcessing's
    -SharedFunctionNames mechanism captures whichever definition is
    CURRENTLY active in the caller's scope at call time - dot-sourcing
    Logging.ps1/FileDeletion.ps1 after ZipParallelProcessing.ps1 (or not
    at all) means ZPP's own stale inline copies would silently win instead.

    REAL BUG FOUND AND FIXED (2026-08-27, while adding CCR test coverage
    for a real zip failure - Scenario K): -SharedFunctionNames was missing
    'Invoke-MutexGuardedWrite', which Write-Log itself calls internally
    for every Warn/Error-level line (and every line at all in full-logging
    mode). Since that helper wasn't propagated into the worker runspace's
    InitialSessionState, ANY Write-Log call at Warn/Error level from
    inside $script:zipOnlyWorker (e.g. "FAILED to zip '...'") crashed the
    entire worker with an unhandled "term not recognized" error - the
    job's real result was never returned at all, silently miscounted as
    neither a success nor a failure. Fully latent until now: no harness
    scenario had ever exercised a real zip failure from inside the
    worker before Scenario K. A second, compounding gap the same fix
    exposed: this harness's own Invoke-ZipOnlyPipeline calls never
    forwarded -LogFile/-LogErrorFile/-LogWarnFile at all (defaulting to
    empty strings - PS 5.1 binds an omitted [string] parameter to "",
    never $null, see Docs/lessons-learned.md), so even with the shared-
    function fix, Write-Log's Out-File would still throw on an empty
    -FilePath the first time an Error/Warn line was ever attempted from a
    worker. Fixed in the harness too (now forwards the real
    $script:logFile/logErrorFile/logWarnFile paths Initialize-LogPaths
    already set up, matching what any real caller must do).

    ABORT WIRING NOTE (updated 2026-08-27): now that ZipParallelProcessing.ps1
    has migrated onto AbortPipeline.ps1 (see that module's own header),
    Invoke-ZipOnlyPipeline registers $script:zipOnlyCts with
    Register-AbortCancellationSource right after creating it, and
    unregisters it in the same finally block that disposes it - matching
    ImageConversionPipeline.ps1's own $looseCts pattern exactly. It still
    keeps the name $script:zipOnlyCts (harmless, just a local variable
    name at this point, not a magic name anything else depends on) rather
    than renaming it, since nothing about the registry cares what the
    caller calls its own CTS.

    INCREMENTAL SCANNING (2026-08-17): Invoke-ZipOnlyPipeline dispatches
    via LeafDirectoryDiscovery.ps1's New-ZippableLeafDirProvider +
    Invoke-ZipParallelProcessing's -NextJobProvider, not
    Get-ZippableLeafDirs's full-tree scan + -JobParams. The whole point
    of -NextJobProvider (built for exactly this, see CHANGELOG.md v16.1,
    never wired up anywhere until now) is that dispatch can begin on the
    first qualifying folder while the rest of a large library is still
    being walked - scanning the ENTIRE tree before doing any work at all
    is what actually caused the "hangs while it searches every folder at
    once" symptom on large libraries. One real consequence: this
    function's own CandidateCount is no longer known before dispatch
    starts, so the old "found N folder(s), running..." log line before
    dispatch is gone - the total only exists once the whole run finishes.

    CLEAN CONSOLE OUTPUT (2026-08-27): mode 3 does NOT switch onto
    New-SeriesProvider/Get-SeriesChapters the way ImageConversionPipeline.ps1
    did - deliberately. Those two enforce the FIXED Library > Series >
    Chapter > Images layout (series exactly one level below the root,
    chapters found by a recursive scan bounded to one series). Mode 3's
    OWN existing, already-tested behavior (ZipPipeline.Harness.ps1
    Scenario A) has leaf directories sitting DIRECTLY under -Path with no
    series folder at all - "zip-only handles arbitrary already-ready
    content" per this function's own docstring, not necessarily a manga
    library. Porting the strict two-tier model here would have silently
    broken that. Instead: New-ZippableLeafDirProvider (unchanged,
    arbitrary depth, still the real incremental job source) drives
    dispatch exactly as before; for CCR display purposes only, each
    discovered leaf's "series" is derived as its own top-level ancestor
    directory name relative to -Path (falls back to the leaf's own name
    when the leaf sits directly under -Path - a degenerate one-chapter
    "series"). The first time a given top-level ancestor is seen, ONE
    bounded Get-ZippableLeafDirs scan of just that top-level folder
    (same guards as the incremental scan, via the same
    Test-ZippableLeafDirCandidate helper) gets a real chapter count for
    Start-SeriesProgress - bounded per series, not a whole-library
    up-front scan, matching the exact principle that made the two-tier
    approach safe elsewhere without requiring its strict layout
    assumption here. CCR calls are gated on
    $script:CleanConsoleOutputEnabled through small ordinary (non-
    closure) wrapper functions below - reading that flag, or calling any
    CCR function, directly inside a .GetNewClosure()'d scriptblock would
    reproduce the exact frozen-scope bug ImageConversionPipeline.ps1's
    Opus review caught (see CHANGELOG.md) - $script: inside a closure
    resolves to that closure's own disconnected dynamic module, not
    Logging.ps1's real one.

.NOTES
    Extracted from Conversion Script Main.ps1 - see
    Modules\_Reference\ZipPipeline.reference.ps1 for the verbatim source
    this was built from, with original line numbers.
#>

# ==============================================================================
#  PART 1 - mode 3 (zip-only pipeline)
# ==============================================================================

# ---- CCR helpers: plain functions, deliberately NOT closures - see this
#      module's header ("CLEAN CONSOLE OUTPUT") for why $script:
#      CleanConsoleOutputEnabled (owned by Logging.ps1) must only ever be
#      read from an ordinary function, never inline inside a
#      .GetNewClosure()'d scriptblock. Shared by both mode 3's dispatch
#      loop and PART 2's Invoke-LooseFolderZip. ----
function Start-CcrSeriesProgressIfEnabled {
    param([string]$SeriesName, [int]$TotalChapters)
    if ($script:CleanConsoleOutputEnabled) { Start-SeriesProgress -SeriesName $SeriesName -TotalChapters $TotalChapters }
}
function Start-CcrChapterProgressIfEnabled {
    param([string]$SeriesName, [string]$ChapterName)
    if ($script:CleanConsoleOutputEnabled) { Start-ChapterProgress -SeriesName $SeriesName -ChapterName $ChapterName }
}
function Complete-CcrChapterProgressIfEnabled {
    param([string]$SeriesName, [string]$ChapterName, [string]$Status, [string]$Detail = $null)
    if ($script:CleanConsoleOutputEnabled) { $null = Complete-ChapterProgress -SeriesName $SeriesName -ChapterName $ChapterName -Status $Status -Detail $Detail }
}
function Complete-CcrAllSeriesProgressIfEnabled {
    if ($script:CleanConsoleOutputEnabled) { $null = Complete-AllActiveSeriesProgress }
}
function Test-CcrEnabledForZipOnly {
    <#
    .SYNOPSIS
        Ordinary function wrapper around $script:CleanConsoleOutputEnabled
        (2026-08-31 addition, caught by a same-day /code-review
        full-codebase pass) - same reason the four IfEnabled wrappers
        above exist: mode 3's own -NextJobProvider closure
        (.GetNewClosure()'d, see this module's header) needs to gate its
        per-series chapter-count side-scan on this flag too, and an
        inline $script: read inside that closure is exactly the pattern
        this module's header already calls out as unsafe - an ordinary
        function call is not.
    #>
    return [bool]$script:CleanConsoleOutputEnabled
}

function Get-ZipChapterProgressStatus {
    <#
    .SYNOPSIS
        Maps $script:zipOnlyWorker's own result hashtable to CCR's
        Status/Detail pair - same plain-language convention
        ImageConversionPipeline.ps1's Get-ChapterProgressStatus already
        established (see CLAUDE.md's "-Detail string shape" note), not a
        different shape invented here.
    .OUTPUTS
        Two values: Status ("Success"/"Warning"/"Error"), Detail (string
        or $null for a clean Success).
    #>
    param(
        [hashtable]$ZipResult
    )
    # Checked before Failed/FolderDeleteFailed since a cancelled-before-start
    # job's result is otherwise indistinguishable from a real clean success
    # (Success=0/Failed=0/FolderDeleteFailed=0 all fall through to Success) -
    # 2026-08-31 fix: a Ctrl+C mid-run left an already-queued worker's
    # "nothing attempted" result reported as a clean Success in Clean
    # Console Output instead of flagging that the folder was never zipped.
    if ($ZipResult.Cancelled -eq 1) { return "Warning", "cancelled before starting - not zipped" }
    if ($ZipResult.Failed -eq 1) { return "Error", "zip failed" }
    if ($ZipResult.FolderDeleteFailed -eq 1) { return "Warning", "zipped OK, but source folder delete failed" }
    return "Success", $null
}

# ---- Worker scriptblock, dispatched once per qualifying leaf folder via
#      Invoke-ZipParallelProcessing. Must declare CancelToken/LogMutex/
#      ConsoleQueue per ZPP's contract - see ZipParallelProcessing.ps1's
#      own docstring. ----
$script:zipOnlyWorker = {
    param(
        [string]$FolderPath,
        [string]$ZipOutPath,
        [string]$SeriesName,
        [string]$LogFile,
        [string]$LogErrorFile,
        [string]$LogWarnFile,
        [bool]$DoFullLogging,
        [bool]$DeleteFolders,
        [bool]$DoPermanentDelete,
        [System.Threading.Mutex]$LogMutex,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ConsoleQueue,
        [System.Threading.CancellationToken]$CancelToken
    )

    Add-Type -AssemblyName "Microsoft.VisualBasic"
    Add-Type -AssemblyName "System.IO.Compression.FileSystem"

    # Bootstrap: this runspace has its own independent script scope, so
    # the shared functions (registered via -SharedFunctionNames) need
    # these same-named script-scope variables set here, matching the
    # established pattern (see ZipParallelProcessing.ps1's own docstring).
    $script:logMutex           = $LogMutex
    $script:workerConsoleQueue = $ConsoleQueue
    $script:FullLogging        = $DoFullLogging
    $script:logFile            = $LogFile
    $script:logErrorFile       = $LogErrorFile
    $script:logWarnFile        = $LogWarnFile
    $script:PermanentDelete    = $DoPermanentDelete

    # SeriesName is pass-through only - this runspace never touches CCR
    # (every CCR call is main-thread-only, see this module's header) - it
    # rides along in the result purely so the main thread's -ResultHandler
    # can call Complete-ChapterProgress with the right SeriesName/
    # ChapterName pair without having to keep its own FolderPath->Series
    # lookup in sync with what actually got dispatched.
    $folderName = [System.IO.Path]::GetFileName($FolderPath)
    $result = @{
        FolderName         = $folderName
        SeriesName         = $SeriesName
        Success            = 0
        Failed             = 0
        FolderDeleted      = 0
        FolderDeleteFailed = 0
        Cancelled          = 0
    }

    if ($CancelToken.IsCancellationRequested) {
        Write-Log ("Cancelled before starting '" + $folderName + "'") -Level Warn
        $result.Cancelled = 1
        return $result
    }

    try {
        Write-Log ("Zipping '" + $FolderPath + "' -> '" + $ZipOutPath + "'")

        $zipSize = Compress-FolderToZip -SourceDir $FolderPath -ZipOut $ZipOutPath
        $verify  = Test-ZipArchive -ZipPath $ZipOutPath -RequireJxlEntry $false

        Write-Log ("ZIP OK: '" + $ZipOutPath + "' (" + $zipSize + " bytes, " + $verify.EntryCount + " entries)")
        $result.Success = 1

        if ($DeleteFolders) {
            try {
                $null = Remove-Source -ItemPath $FolderPath
                $deleteDesc = if ($DoPermanentDelete) { "permanently" } else { "Recycle Bin" }
                Write-Log ("Deleted source folder (" + $deleteDesc + "): '" + $FolderPath + "'")
                $result.FolderDeleted = 1
            } catch {
                Write-Log ("FAILED to delete folder '" + $FolderPath + "': " + $_) -Level Error
                $result.FolderDeleteFailed = 1
            }
        }
    } catch {
        Write-Log ("FAILED to zip '" + $folderName + "': " + $_) -Level Error
        $result.Failed = 1
        # Remove the broken partial zip if it was created
        try {
            if (Test-Path -LiteralPath $ZipOutPath) { [System.IO.File]::Delete($ZipOutPath) }
        } catch { }
    }

    return $result
}

function Invoke-ZipOnlyPipeline {
    <#
    .SYNOPSIS
        Mode 3 end to end: discovers zippable leaf folders under $Path,
        zips each one in parallel (via Invoke-ZipParallelProcessing), and
        optionally deletes each source folder after a successful zip.
    .PARAMETER QualifyingExtensions
        Defaults to this module's own broad list (images, video,
        document/archive formats) since zip-only handles arbitrary
        already-ready content, not just images awaiting conversion.
    .OUTPUTS
        @{ CandidateCount; ZippedSuccess; ZippedFail; FolderDeletedSuccess;
           FolderDeletedFail; ForceStoppedCount } - a plain result object,
        not a mutation of an external $stats hashtable (unlike the
        original main-script code this was extracted from) - the caller
        folds this into whatever stats shape it uses.
    .NOTES
        Discovers and dispatches INCREMENTALLY (LeafDirectoryDiscovery.ps1's
        New-ZippableLeafDirProvider + Invoke-ZipParallelProcessing's
        -NextJobProvider), not via a full up-front scan - work starts on
        the first qualifying folder while the rest of a large library is
        still being walked. CandidateCount therefore isn't known until
        the whole run finishes (it's a running count of what was actually
        found and dispatched, not a pre-scan total) - the "N folder(s)
        found, running..." log line this function used to print before
        dispatch started no longer applies for the same reason.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string[]]$QualifyingExtensions = @(
            ".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".jxl", ".bmp", ".tiff", ".tif",
            ".heic", ".heif", ".mp4", ".mkv", ".webm", ".avi", ".mov", ".wmv",
            ".cbz", ".cbr", ".epub", ".pdf"
        ),
        [Parameter(Mandatory)]
        [int]$MaxParallel,
        [bool]$DeleteFolders = $false,
        [Parameter(Mandatory)]
        [bool]$FullLogging,
        [string]$LogFile,
        [string]$LogErrorFile,
        [string]$LogWarnFile,
        [Parameter(Mandatory)]
        [bool]$PermanentDelete
    )

    $totals = @{
        CandidateCount       = 0
        ZippedSuccess        = 0
        ZippedFail           = 0
        FolderDeletedSuccess = 0
        FolderDeletedFail    = 0
        ForceStoppedCount    = 0
    }

    # No outer catch here (2026-08-28, Phase 2 of the main-script-rewrite
    # build plan) - this used to swallow any exception into a generic
    # "Zip-only pipeline error: ..." Write-Log call, the one real outlier
    # among all five real pipeline entry points (the other four only have
    # try/finally at this level, letting a genuine exception propagate to
    # the caller). Controller.ps1's Invoke-Mode owns the shared top-level
    # catch now (Todo.md's decided design) - swallowing here would have
    # made that catch permanently unreachable for this pipeline. Expected
    # per-item failures (a single zip failing) were never affected either
    # way - those are already fully handled inside $script:zipOnlyWorker's
    # own try/catch, folded into $r.Failed, never thrown this far.
    try {
        Write-Log ("Zip-only: scanning and zipping leaf directories incrementally (up to " + $MaxParallel + " in parallel)...")

        # Incremental discovery (LeafDirectoryDiscovery.ps1's
        # New-ZippableLeafDirProvider), not Get-ZippableLeafDirs's full
        # up-front scan - lets dispatch start on the first qualifying
        # folder while the rest of a large library is still being walked,
        # instead of the whole tree needing to finish scanning first (see
        # CLAUDE.md - this was the actual cause of the "hangs while it
        # searches every folder at once" symptom on large libraries).
        # UNCHANGED by Clean Console Output - see this module's header for
        # why the strict two-tier series/chapter model isn't used here.
        $leafProvider = New-ZippableLeafDirProvider -ScanPath $Path -QualifyingExtensions $QualifyingExtensions -ForceRezip $false

        # Tracks which top-level ancestor directories (this function's own
        # notion of "series" for CCR display) have already had their
        # bounded Get-ZippableLeafDirs side-scan run - see header.
        $zoSeenSeriesNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $trimmedPath = $Path.TrimEnd([System.IO.Path]::DirectorySeparatorChar)

        # Translates the leaf provider's @{ Dir; ZipOut } shape into
        # $script:zipOnlyWorker's own bound parameter names, and counts
        # how many candidates were actually found - with incremental
        # discovery the total isn't known upfront the way it was with the
        # old full-scan-then-dispatch approach, so this is the only place
        # left to count it. Also derives/emits this leaf's CCR series and
        # chapter events - both helper calls are ordinary functions (not
        # inline $script: reads), safe from inside this .GetNewClosure()'d
        # scriptblock - see header.
        $zoJobProvider = {
            $next = & $leafProvider
            if ($null -eq $next) { return $null }
            $totals.CandidateCount++

            $relativePath = $next.Dir.FullName.Substring($trimmedPath.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar)
            $topLevelName = ($relativePath -split [regex]::Escape([System.IO.Path]::DirectorySeparatorChar))[0]
            $seriesName = if ([string]::IsNullOrEmpty($topLevelName)) { $next.Dir.Name } else { $topLevelName }

            # Gated on Test-CcrEnabledForZipOnly (2026-08-31 fix, caught by
            # a same-day /code-review full-codebase pass) - this whole
            # block exists ONLY to compute -TotalChapters for
            # Start-CcrSeriesProgressIfEnabled, which itself no-ops when
            # Clean Console Output is off (the default). Without this
            # gate, the bounded Get-ZippableLeafDirs side-scan below ran
            # unconditionally on every default-settings mode-3 run -
            # doubled directory I/O (a full second recursive walk of every
            # series folder, synchronously, right before that series'
            # first job dispatches) and duplicated every Test-
            # ZippableLeafDirCandidate skip-reason Warn in the log
            # (verified live: an up-to-date-zip skip logged twice), for a
            # value nothing ever consumed.
            if ((Test-CcrEnabledForZipOnly) -and -not $zoSeenSeriesNames.Contains($seriesName)) {
                $null = $zoSeenSeriesNames.Add($seriesName)
                $seriesRoot  = Join-Path $trimmedPath $seriesName
                $seriesTotal = 1
                if (Test-Path -LiteralPath $seriesRoot -PathType Container) {
                    $seriesLeaves = Get-ZippableLeafDirs -ScanPath $seriesRoot -QualifyingExtensions $QualifyingExtensions -ForceRezip $false
                    $seriesTotal  = [Math]::Max($seriesLeaves.Count, 1)
                }
                Start-CcrSeriesProgressIfEnabled -SeriesName $seriesName -TotalChapters $seriesTotal
            }
            Start-CcrChapterProgressIfEnabled -SeriesName $seriesName -ChapterName $next.Dir.Name

            return @{
                FolderPath        = $next.Dir.FullName
                ZipOutPath        = $next.ZipOut
                SeriesName        = $seriesName
                LogFile           = $LogFile
                LogErrorFile      = $LogErrorFile
                LogWarnFile       = $LogWarnFile
                DoFullLogging     = $FullLogging
                DeleteFolders     = $DeleteFolders
                DoPermanentDelete = $PermanentDelete
            }
        }.GetNewClosure()

        # Registered for the whole mode-3 call (one phase), not per-job -
        # see this module's own header ("ABORT WIRING NOTE") and matches
        # Register-AbortCancellationSource's own "call once per pipeline
        # phase" contract, same pattern ImageConversionPipeline.ps1 uses
        # for its own $looseCts.
        $script:zipOnlyCts = [System.Threading.CancellationTokenSource]::new()
        Register-AbortCancellationSource -Cts $script:zipOnlyCts
        try {
            $zoResultHandler = {
                param($r)
                $totals.ZippedSuccess        += $r.Success
                $totals.ZippedFail           += $r.Failed
                $totals.FolderDeletedSuccess += $r.FolderDeleted
                $totals.FolderDeletedFail    += $r.FolderDeleteFailed
                $zipStatus, $zipDetail = Get-ZipChapterProgressStatus -ZipResult $r
                Complete-CcrChapterProgressIfEnabled -SeriesName $r.SeriesName -ChapterName $r.FolderName -Status $zipStatus -Detail $zipDetail
            }.GetNewClosure()

            $zipOnlyWorkerSharedFunctionNames = @(Get-LoggingSharedFunctionNames) + @(Get-FileDeletionSharedFunctionNames) + @(Get-ZipCreationSharedFunctionNames) + @(Get-ZipValidationSharedFunctionNames)
            $zoOutcome = Invoke-ZipParallelProcessing -WorkerScript $script:zipOnlyWorker -NextJobProvider $zoJobProvider `
                -SharedFunctionNames $zipOnlyWorkerSharedFunctionNames `
                -MaxParallel $MaxParallel -Cts $script:zipOnlyCts -ResultHandler $zoResultHandler

            $totals.ForceStoppedCount = $zoOutcome.ForceStoppedCount
        } finally {
            Unregister-AbortCancellationSource -Cts $script:zipOnlyCts
            $script:zipOnlyCts.Dispose()
            $script:zipOnlyCts = $null
        }

        if ($totals.CandidateCount -eq 0) {
            Write-Log "Zip-only: no qualifying leaf directories found." -Level Warn
            return $totals
        }

        $zoCompleteMsg = "Zip-only processing complete: " + $totals.ZippedSuccess + " zipped, " + $totals.ZippedFail + " failed."
        if ($totals.ForceStoppedCount -gt 0) {
            $zoCompleteMsg += (" " + $totals.ForceStoppedCount + " job(s) force-stopped on abort.")
        }
        Write-Log $zoCompleteMsg -Level Summary
    } finally {
        # Safety net for the abort/shutdown path, same as
        # ImageConversionPipeline.ps1's own finally block - force-resolves
        # any series left mid-flight. A no-op when nothing is still active.
        Complete-CcrAllSeriesProgressIfEnabled
    }

    return $totals
}

# ==============================================================================
#  PART 2 - mode 2's per-folder zip step
# ==============================================================================

function Invoke-LooseFolderZip {
    <#
    .SYNOPSIS
        Zips one already-converted folder (mode 2's per-folder step,
        called right after ImageConversionPipeline finishes converting
        that folder), then deletes the source folder on a successful zip.
        Guards against zipping a folder that still has unconverted source
        images - partial-failure protection, never locks a partial result
        into a ZIP.
    .PARAMETER LooseImageExtensions
        Extensions checked for "still unconverted" - typically the
        original source image extensions (not .jxl).
    .PARAMETER SeriesName
    .PARAMETER ChapterName
        OPTIONAL - only pass both when THIS call is meant to be the
        chapter's one and only CCR transition (Start-ChapterProgress here,
        Complete-ChapterProgress on every exit path including Skipped).
        This function does NOT call Start-SeriesProgress itself - it has
        no way to know that series' real total chapter count, so the
        CALLER must have already started that series (exactly like
        ImageConversionPipeline.ps1 already does when it walks a series'
        chapters) before passing -SeriesName here, or CCR throws ("not an
        active series"). Mode 8's real caller (Controller.ps1's Invoke-Mode)
        does NOT pass -SeriesName/-ChapterName here - it merges this
        function's outcome into ImageConversionPipeline.ps1's own single
        Complete-ChapterProgress call instead (see that module's
        -ZipStepCallback), so this parameter pair stays unused by the one
        real caller today. Left optional and self-contained for a future
        caller that might want a second, standalone CCR transition
        instead.
    .OUTPUTS
        @{ Status = "Success"|"Fail"|"Skipped"; ZipSize; EntryCount;
           FolderDeleted; FolderDeleteFailed } - a plain result object,
        the caller folds this into whatever stats shape it uses.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FolderPath,
        [Parameter(Mandatory)]
        [string]$ZipOut,
        [Parameter(Mandatory)]
        [string[]]$LooseImageExtensions,
        [bool]$RequireJxlEntry = $true,
        [string]$SeriesName = $null,
        [string]$ChapterName = $null
    )

    $result = @{
        Status            = $null
        ZipSize           = 0
        EntryCount        = 0
        FolderDeleted     = $false
        FolderDeleteFailed = $false
    }

    $folderName = Split-Path -Path $FolderPath -Leaf
    # $PSBoundParameters.ContainsKey(...), not "$null -ne $SeriesName" - an
    # omitted [string] parameter binds to "", never $null (this project's
    # own documented lessons-learned trap #5), so the $null-based check was
    # $true for EVERY caller, including the one real caller (Controller.ps1)
    # that deliberately omits both names to avoid a second CCR transition -
    # crashing the whole run the first time it zipped a chapter with Clean
    # Console Output on, since Start-CcrChapterProgressIfEnabled then got
    # called with -SeriesName "".
    $reportCcr  = ($PSBoundParameters.ContainsKey('SeriesName') -and $PSBoundParameters.ContainsKey('ChapterName'))
    if ($reportCcr) { Start-CcrChapterProgressIfEnabled -SeriesName $SeriesName -ChapterName $ChapterName }

    try {
        # Orphaned "_tmp_*" scratch files are actually DELETED here, not
        # just excluded from the guard below (2026-08-31 fix, corrected
        # after a same-day /code-review 4th pass verification found that a
        # plain exclusion let the debris survive to get zipped: this
        # function's own Compress-FolderToZip call archives the WHOLE
        # folder, and a successful zip deletes the source folder right
        # after, so an excluded-but-not-deleted scratch file ended up
        # permanently embedded in the .cbz as a junk page with no record
        # anywhere it happened). These are job-generated intermediates -
        # always safe to delete permanently regardless of $PermanentDelete,
        # per this project's own established deletion semantics (only
        # ORIGINAL/source files respect that toggle) - the owning module
        # (ImageConversionPipeline.ps1's Invoke-IccStripRetryOrFail, its
        # WebP/AVIF pre-conversion detour, and
        # AnimatedConversionPipeline.ps1's -DoAnimatedOverwrite staging)
        # already has its own cleanup for every real leak path; this is the
        # boundary-level backstop for when that cleanup couldn't run (a
        # force-killed process, a locked file swallowed by a bare
        # `catch {}`).
        $orphanedScratchFiles = @(Get-ChildItem -LiteralPath $FolderPath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -imatch '_tmp_iccstrip\.png$' -or
                $_.Name -imatch '_tmp_(webp|avif)2png\.png$' -or
                $_.Name -imatch '_tmp_overwrite\.webp$'
            })
        foreach ($orphan in $orphanedScratchFiles) {
            # A failed delete (locked file, AV hold) is logged explicitly
            # rather than swallowed silently (2026-08-31 fix, caught by
            # verifying a same-day /code-review pass - CLAUDE.md's own
            # review checklist: "no silent catches without a reason") -
            # the original "Deleting..." line asserted success regardless
            # of outcome, and a failure here means the orphan survives
            # into the `$remainingSrcImages` check right below, which
            # blocks the zip with its own separate Warn - visible, but
            # this makes the ROOT cause visible too, not just the symptom.
            try {
                [System.IO.File]::Delete($orphan.FullName)
                Write-Log ("Deleted orphaned scratch file (its owning cleanup could not run earlier): '" + $orphan.FullName + "'") -Level Warn
            } catch {
                Write-Log ("Could not delete orphaned scratch file '" + $orphan.FullName + "' - it may still block this chapter's zip: " + $_) -Level Warn
            }
        }

        $remainingSrcImages = @(Get-ChildItem -LiteralPath $FolderPath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $LooseImageExtensions -icontains $_.Extension })

        if ($remainingSrcImages.Count -gt 0) {
            $nameList = ($remainingSrcImages | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ", "
            if ($remainingSrcImages.Count -gt 5) { $nameList += ", ..." }
            Write-Log ("SKIPPING zip of '" + $folderName + "': " + $remainingSrcImages.Count + " unconverted source image(s) still present (" + $nameList + "). Resolve conversion failures before zipping.") -Level Warn
            $result.Status = "Skipped"
            return $result
        }

        try {
            Write-Log ("Re-zipping '" + $FolderPath + "' -> '" + $ZipOut + "'")

            $zipSize = Compress-FolderToZip -SourceDir $FolderPath -ZipOut $ZipOut
            $verify  = Test-ZipArchive -ZipPath $ZipOut -RequireJxlEntry $RequireJxlEntry

            Write-Log ("ZIP OK: '" + $ZipOut + "' (" + $zipSize + " bytes, " + $verify.EntryCount + " entries)")
            $result.Status     = "Success"
            $result.ZipSize    = $zipSize
            $result.EntryCount = $verify.EntryCount

            try {
                $null = Remove-Source -ItemPath $FolderPath
                $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
                Write-Log ("Deleted folder (" + $deleteDesc + "): '" + $FolderPath + "'")
                $result.FolderDeleted = $true
            } catch {
                Write-Log ("FAILED to delete folder '" + $FolderPath + "': " + $_) -Level Error
                $result.FolderDeleteFailed = $true
            }
        } catch {
            Write-Log ("FAILED to zip folder '" + $FolderPath + "': " + $_) -Level Error
            $result.Status = "Fail"
        }

        return $result
    } finally {
        if ($reportCcr) {
            $ccrStatus = switch ($result.Status) {
                "Success" { if ($result.FolderDeleteFailed) { "Warning" } else { "Success" } }
                "Skipped" { "Warning" }
                default   { "Error" }
            }
            $ccrDetail = switch ($result.Status) {
                "Success" { if ($result.FolderDeleteFailed) { "zipped OK, but source folder delete failed" } else { $null } }
                "Skipped" { "zip skipped: unconverted source image(s) still present" }
                default   { "zip failed" }
            }
            Complete-CcrChapterProgressIfEnabled -SeriesName $SeriesName -ChapterName $ChapterName -Status $ccrStatus -Detail $ccrDetail
        }
    }
}
