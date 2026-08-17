<#
.SYNOPSIS
    ZipPipeline - all zip-domain orchestration that isn't the parallel-
    dispatch engine itself: mode 3 (zip-only) end to end, and mode 2's
    per-folder zip step.

.DESCRIPTION
    Pure definitions only - no top-level side effects (assigning the
    $script:zipOnlyWorker scriptblock literal is inert, same category as
    AbortPipeline.ps1's $script:abortCancellationSources list init) -
    safe to dot-source more than once or alongside other modules.

    Per the reference extraction's ARCHITECTURE decision: any zip logic
    lives here, not scattered across whichever mode happens to need it.
    Covers PART 1 (mode 3, zip-only pipeline) and PART 2 (mode 2's
    per-folder zip step, which runs right after ImageConversionPipeline
    converts each batch - see that module's own PART 2 for the orchestration
    this was pulled out of).

    NOT YET DECIDED (explicitly flagged, not acted on): whether
    RezipPipeline (mode 4) should call into this module instead of
    duplicating zip creation/validation inline. See RezipPipeline's own
    reference file and CLAUDE.md.

    FORWARD REFERENCES (not defined in this module - callers must
    dot-source the owning module(s) first):
      - Write-Log (Logging.ps1)
      - Move-ToRecycleBin, Remove-ItemPermanently, Remove-Source
        (FileDeletion.ps1)
      - Compress-FolderToZip (ZipCreation.ps1)
      - Test-ZipArchive (ZipValidation.ps1)
      - New-ZippableLeafDirProvider (LeafDirectoryDiscovery.ps1) -
        incremental leaf discovery, not the full-scan Get-ZippableLeafDirs
        (see "INCREMENTAL SCANNING" below)
      - Invoke-ZipParallelProcessing (ZipParallelProcessing.ps1) - mode 3
        is ZPP's one current caller; this is where that wiring lives.
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

    ABORT WIRING NOTE: Invoke-ZipOnlyPipeline sets $script:zipOnlyCts (not
    AbortPipeline.ps1's Register-AbortCancellationSource registry) purely
    because ZipParallelProcessing.ps1's own Test-AbortSignal is still on
    the OLD hardcoded-three-variable pattern (see CLAUDE.md "Known gaps") -
    a CTS registered only via the new registry would never actually get
    cancelled by ZPP's current abort check. Revisit once ZPP migrates onto
    AbortPipeline.ps1 - this is current-reality compatibility, not an
    endorsement of the old pattern.

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

.NOTES
    Extracted from Conversion Script Main.ps1 - see
    Modules\_Reference\ZipPipeline.reference.ps1 for the verbatim source
    this was built from, with original line numbers.
#>

# ==============================================================================
#  PART 1 - mode 3 (zip-only pipeline)
# ==============================================================================

# ---- Worker scriptblock, dispatched once per qualifying leaf folder via
#      Invoke-ZipParallelProcessing. Must declare CancelToken/LogMutex/
#      ConsoleQueue per ZPP's contract - see ZipParallelProcessing.ps1's
#      own docstring. ----
$script:zipOnlyWorker = {
    param(
        [string]$FolderPath,
        [string]$ZipOutPath,
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

    $folderName = [System.IO.Path]::GetFileName($FolderPath)
    $result = @{
        FolderName         = $folderName
        Success            = 0
        Failed             = 0
        FolderDeleted      = 0
        FolderDeleteFailed = 0
    }

    if ($CancelToken.IsCancellationRequested) {
        Write-Log ("Cancelled before starting '" + $folderName + "'") -Level Warn
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

    try {
        Write-Log ("Zip-only: scanning and zipping leaf directories incrementally (up to " + $MaxParallel + " in parallel)...")

        # Incremental discovery (LeafDirectoryDiscovery.ps1's
        # New-ZippableLeafDirProvider), not Get-ZippableLeafDirs's full
        # up-front scan - lets dispatch start on the first qualifying
        # folder while the rest of a large library is still being walked,
        # instead of the whole tree needing to finish scanning first (see
        # CLAUDE.md - this was the actual cause of the "hangs while it
        # searches every folder at once" symptom on large libraries).
        $leafProvider = New-ZippableLeafDirProvider -ScanPath $Path -QualifyingExtensions $QualifyingExtensions -ForceRezip $false

        # Translates the leaf provider's @{ Dir; ZipOut } shape into
        # $script:zipOnlyWorker's own bound parameter names, and counts
        # how many candidates were actually found - with incremental
        # discovery the total isn't known upfront the way it was with the
        # old full-scan-then-dispatch approach, so this is the only place
        # left to count it.
        $zoJobProvider = {
            $next = & $leafProvider
            if ($null -eq $next) { return $null }
            $totals.CandidateCount++
            return @{
                FolderPath        = $next.Dir.FullName
                ZipOutPath        = $next.ZipOut
                LogFile           = $LogFile
                LogErrorFile      = $LogErrorFile
                LogWarnFile       = $LogWarnFile
                DoFullLogging     = $FullLogging
                DeleteFolders     = $DeleteFolders
                DoPermanentDelete = $PermanentDelete
            }
        }.GetNewClosure()

        # See this module's own header ("ABORT WIRING NOTE") for why this
        # is the old hardcoded-variable pattern rather than
        # AbortPipeline.ps1's registry.
        $script:zipOnlyCts = [System.Threading.CancellationTokenSource]::new()
        try {
            $zoResultHandler = {
                param($r)
                $totals.ZippedSuccess        += $r.Success
                $totals.ZippedFail           += $r.Failed
                $totals.FolderDeletedSuccess += $r.FolderDeleted
                $totals.FolderDeletedFail    += $r.FolderDeleteFailed
            }.GetNewClosure()

            $zoOutcome = Invoke-ZipParallelProcessing -WorkerScript $script:zipOnlyWorker -NextJobProvider $zoJobProvider `
                -SharedFunctionNames @('Write-Log', 'Move-ToRecycleBin', 'Remove-ItemPermanently', 'Remove-Source', 'Compress-FolderToZip', 'Test-ZipArchive') `
                -MaxParallel $MaxParallel -Cts $script:zipOnlyCts -ResultHandler $zoResultHandler

            $totals.ForceStoppedCount = $zoOutcome.ForceStoppedCount
        } finally {
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
    } catch {
        Write-Log ("Zip-only pipeline error: " + $_) -Level Error
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
        [bool]$RequireJxlEntry = $true
    )

    $result = @{
        Status            = $null
        ZipSize           = 0
        EntryCount        = 0
        FolderDeleted     = $false
        FolderDeleteFailed = $false
    }

    $folderName = Split-Path -Path $FolderPath -Leaf

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
}
