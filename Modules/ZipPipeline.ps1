# See module-descriptions.md for this module's full description.

# ==============================================================================
#  PART 1 - Zip Folders (menu 4)
# ==============================================================================

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
    return [bool]$script:CleanConsoleOutputEnabled
}

function Get-ZipChapterProgressStatus {
    param(
        [hashtable]$ZipResult
    )
    if ($ZipResult.Cancelled -eq 1) { return "Warning", "cancelled before starting - not zipped" }
    if ($ZipResult.PairBlocked -eq 1) { return "Warning", "zip skipped: animated originals kept (.avif and .webp both present)" }
    if ($ZipResult.Failed -eq 1) { return "Error", "zip failed" }
    if ($ZipResult.FolderDeleteFailed -eq 1) { return "Warning", "zipped OK, but source folder delete failed" }
    return "Success", $null
}

$script:zipOnlyWorker = {
    param(
        [string]$FolderPath,
        [string]$ZipOutPath,
        [string]$SeriesName,
        [bool]$DeleteFolders,
        [bool]$DoPermanentDelete,
        [System.Threading.Mutex]$LogMutex,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ConsoleQueue,
        [System.Threading.CancellationToken]$CancelToken
    )

    $null = [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.VisualBasic")
    $null = [System.Reflection.Assembly]::LoadWithPartialName("System.IO.Compression.FileSystem")

    # Only these two - worker log lines go through the queue; see Get-WorkerRunspaceValue.
    $script:workerConsoleQueue = $ConsoleQueue
    $script:PermanentDelete    = $DoPermanentDelete

    $folderName = [System.IO.Path]::GetFileName($FolderPath)
    $result = @{
        FolderName         = $folderName
        SeriesName         = $SeriesName
        Success            = 0
        Failed             = 0
        FolderDeleted      = 0
        FolderDeleteFailed = 0
        Cancelled          = 0
        PairBlocked        = 0
    }

    if ($CancelToken.IsCancellationRequested) {
        Write-Log ("Cancelled before starting '" + $folderName + "'") -Level Warn
        $result.Cancelled = 1
        return $result
    }

    # DOCUMENTED DUPLICATE of AnimatedConversionPipeline.ps1's Test-AvifWebpPairPresent
    # (inline because this module's harness doesn't dot-source that module) - keep both in sync.
    $pairFound = $false
    try {
        foreach ($avif in [System.IO.Directory]::EnumerateFiles($FolderPath, "*.avif")) {
            $webp = [System.IO.Path]::ChangeExtension($avif, ".webp")
            if ([System.IO.File]::Exists($webp) -and ([System.IO.FileInfo]::new($webp).Length -gt 0)) { $pairFound = $true; break }
        }
    } catch {
        # Folder unreadable/gone - no pair can be proven; the zip step below reports the real failure.
        $pairFound = $false
    }
    if ($pairFound) {
        Write-Log ("Not zipping '" + $FolderPath + "': it holds an .avif and its converted .webp (animated originals kept). Delete one of each pair, then zip again.") -Level Warn
        $result.PairBlocked = 1
        return $result
    }

    try {
        # DOCUMENTED DUPLICATE of ImageConversionPipeline.ps1's
        # Test-OrphanedScratchFileName regex trio, kept as a literal because
        # this module's harness doesn't dot-source that module (ImageConversionPipeline.Harness.ps1's
        # Scenario A0b checks this copy hasn't drifted) - keep both in sync.
        $orphanedScratchFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        foreach ($f in (Get-FilesRecursiveSafe -ScanPath $FolderPath)) {
            if ($f.Name -imatch '_tmp_iccstrip(-\d+)?\.png$' -or
                $f.Name -imatch '_tmp_(webp|avif|bmp|heic|heif|tiff)2png\.png$' -or
                $f.Name -imatch '_tmp_overwrite\.webp$') {
                $orphanedScratchFiles.Add($f)
            }
        }
        foreach ($orphan in $orphanedScratchFiles) {
            try {
                [System.IO.File]::Delete($orphan.FullName)
                Write-Log ("Deleted orphaned scratch file (its owning cleanup could not run earlier): '" + $orphan.FullName + "'") -Level Warn
            } catch {
                Write-Log ("Could not delete orphaned scratch file '" + $orphan.FullName + "' - it will be archived into this folder's zip: " + $_) -Level Warn
            }
        }

        Write-Log ("Zipping '" + $FolderPath + "' -> '" + $ZipOutPath + "'")

        $zipSize = Compress-FolderToZip -SourceDir $FolderPath -ZipOut $ZipOutPath
        $verify  = Test-ZipArchive -ZipPath $ZipOutPath -RequireJxlEntry $false

        Write-Log ("ZIP OK: '" + $ZipOutPath + "' (" + $zipSize + " bytes, " + $verify.EntryCount + " entries)")
        $result.Success = 1
    } catch {
        Write-Log ("FAILED to zip '" + $folderName + "': " + $_) -Level Error
        $result.Failed = 1
        try {
            if ([System.IO.File]::Exists($ZipOutPath)) { [System.IO.File]::Delete($ZipOutPath) }
        } catch { }
        return $result
    }

    # Deliberately OUTSIDE the try/catch above:
    # that block's own catch treats ANY exception as "the zip failed" and
    # deletes $ZipOutPath - correct for a failure during zip creation, but
    # this step runs only AFTER the zip is already built and verified. If
    # this step's own Write-Log calls (or anything else here) had thrown
    # while still inside that try, the outer catch would have logged a
    # false "FAILED to zip", set BOTH Success=1 and Failed=1, and deleted
    # the zip it had just finished verifying - discarding a good archive
    # over an unrelated post-success logging hiccup. This step already has
    # its own inner try/catch for the one call that can legitimately fail
    # (Remove-Source) - it doesn't need the outer one too.
    if ($DeleteFolders -and $CancelToken.IsCancellationRequested) {
        # No source delete once an abort is in.
        Write-Log ("Abort requested - left the source folder in place (its zip is complete and verified): '" + $FolderPath + "'") -Level Warn
    } elseif ($DeleteFolders) {
        try {
            $removed = Remove-Source -ItemPath $FolderPath
            if ($removed) {
                $deleteDesc = if ($DoPermanentDelete) { "permanently" } else { "Recycle Bin" }
                Write-Log ("Deleted source folder (" + $deleteDesc + "): '" + $FolderPath + "'")
                $result.FolderDeleted = 1
            } else {
                Write-Log ("Source folder already gone before deletion (not counted as deleted): '" + $FolderPath + "'") -Level Warn
            }
        } catch {
            Write-Log ("FAILED to delete folder '" + $FolderPath + "': " + $_) -Level Error
            $result.FolderDeleteFailed = 1
        }
    }

    return $result
}

function Invoke-ZipOnlyPipeline {
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
        [bool]$PermanentDelete
    )

    $totals = @{
        CandidateCount       = 0
        ZippedSuccess        = 0
        ZippedFail           = 0
        PairBlocked          = 0
        FolderDeletedSuccess = 0
        FolderDeletedFail    = 0
        ForceStoppedCount    = 0
        Aborted              = $false
    }

    try {
        Write-Log ("Zip-only: scanning and zipping leaf directories incrementally (up to " + $MaxParallel + " in parallel)...")

        $leafProvider = New-ZippableLeafDirProvider -ScanPath $Path -QualifyingExtensions $QualifyingExtensions -ForceRezip $false

        $zoSeenSeriesNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $zoCategoryCache   = [System.Collections.Generic.Dictionary[string,bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $trimmedPath = $Path.TrimEnd([System.IO.Path]::DirectorySeparatorChar)

        $zoJobProvider = {
            $next = & $leafProvider
            if ($null -eq $next) { return $null }
            $totals.CandidateCount++

            $dirFullName = $next.Dir.FullName
            if ($dirFullName.StartsWith($trimmedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $relativePath = $dirFullName.Substring($trimmedPath.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar)
                $segments = @($relativePath -split [regex]::Escape([System.IO.Path]::DirectorySeparatorChar))
                if ([string]::IsNullOrEmpty($segments[0])) {
                    $seriesName = $next.Dir.Name
                    $seriesRoot = $dirFullName
                } else {
                    $seriesRoot = [System.IO.Path]::Combine($trimmedPath, $segments[0])
                    for ($i = 1; $i -lt ($segments.Count - 1); $i++) {
                        if (-not $zoCategoryCache.ContainsKey($seriesRoot)) {
                            $zoCategoryCache[$seriesRoot] = Test-SeriesCategoryFolder -Path $seriesRoot -QualifyingExtensions $QualifyingExtensions
                        }
                        if (-not $zoCategoryCache[$seriesRoot]) { break }
                        $seriesRoot = [System.IO.Path]::Combine($seriesRoot, $segments[$i])
                    }
                    $seriesName = [System.IO.Path]::GetFileName($seriesRoot)
                }
            } else {
                Write-Log ("Zip-only: '" + $dirFullName + "' does not start with the scan root '" + $trimmedPath + "' as expected - using its own folder name for the Clean Console Output series display instead of deriving one.") -Level Warn
                $seriesName = $next.Dir.Name
                $seriesRoot = $dirFullName
            }

            # Wrapped in try/catch - this whole
            # block is pure Clean Console Output bookkeeping (a side-scan
            # to count a series' own chapters for the progress display),
            # not real zip work. It runs inside $zoJobProvider, which
            # Invoke-ZipParallelProcessing calls with no try/catch of its
            # own around -NextJobProvider - an unguarded throw here (the
            # side-scan's own Get-ZippableLeafDirs hitting a real TOCTOU
            # if $seriesRoot vanishes between the Test-Path check and the
            # scan, or CCR rendering itself throwing) would kill the
            # ENTIRE Zip Folders run over a display-only concern.
            try {
                if ((Test-CcrEnabledForZipOnly) -and -not $zoSeenSeriesNames.Contains($seriesName)) {
                    $null = $zoSeenSeriesNames.Add($seriesName)
                    $seriesTotal = 1
                    if (Test-Path -LiteralPath $seriesRoot -PathType Container) {
                        $seriesLeaves = Get-ZippableLeafDirs -ScanPath $seriesRoot -QualifyingExtensions $QualifyingExtensions -ForceRezip $false
                        $seriesTotal  = [Math]::Max($seriesLeaves.Count, 1)
                    }
                    Start-CcrSeriesProgressIfEnabled -SeriesName $seriesName -TotalChapters $seriesTotal
                }
                Start-CcrChapterProgressIfEnabled -SeriesName $seriesName -ChapterName $next.Dir.Name
            } catch {
                Write-Log ("Zip-only: Clean Console Output bookkeeping failed for series '" + $seriesName + "' - continuing without it for this chapter: " + $_) -Level Warn
            }

            return @{
                FolderPath        = $next.Dir.FullName
                ZipOutPath        = $next.ZipOut
                SeriesName        = $seriesName
                DeleteFolders     = $DeleteFolders
                DoPermanentDelete = $PermanentDelete
            }
        }.GetNewClosure()

        $script:zipOnlyCts = [System.Threading.CancellationTokenSource]::new()
        Register-AbortCancellationSource -Cts $script:zipOnlyCts
        try {
            $zoResultHandler = {
                param($r)
                $totals.ZippedSuccess        += $r.Success
                $totals.ZippedFail           += $r.Failed
                $totals.PairBlocked          += $r.PairBlocked
                $totals.FolderDeletedSuccess += $r.FolderDeleted
                $totals.FolderDeletedFail    += $r.FolderDeleteFailed
                $zipStatus, $zipDetail = Get-ZipChapterProgressStatus -ZipResult $r
                Complete-CcrChapterProgressIfEnabled -SeriesName $r.SeriesName -ChapterName $r.FolderName -Status $zipStatus -Detail $zipDetail
            }.GetNewClosure()

            $zipOnlyWorkerSharedFunctionNames = @(Get-LoggingSharedFunctionNames) + @(Get-FileDeletionSharedFunctionNames) + @(Get-ZipCreationSharedFunctionNames) + @(Get-ZipValidationSharedFunctionNames) + @('Get-FilesRecursiveSafe')
            $zoOutcome = Invoke-ZipParallelProcessing -WorkerScript $script:zipOnlyWorker -NextJobProvider $zoJobProvider `
                -SharedFunctionNames $zipOnlyWorkerSharedFunctionNames `
                -MaxParallel $MaxParallel -Cts $script:zipOnlyCts -ResultHandler $zoResultHandler

            $totals.ForceStoppedCount = $zoOutcome.ForceStoppedCount
            $totals.Aborted = $script:zipOnlyCts.Token.IsCancellationRequested
        } finally {
            Unregister-AbortCancellationSource -Cts $script:zipOnlyCts
            $script:zipOnlyCts.Dispose()
            $script:zipOnlyCts = $null
        }

        if ($totals.CandidateCount -eq 0) {
            # Check Aborted first - an abort
            # before the very first candidate was ever found would otherwise log
            # the same "no qualifying leaf directories found" message as
            # a genuinely empty library, pointing the user at their
            # folder layout instead of telling them the run was
            # cancelled. $totals.Aborted is already correctly set above.
            if ($totals.Aborted) {
                Write-Log "Zip-only: aborted before any leaf directory was found." -Level Warn
            } else {
                Write-Log "Zip-only: no qualifying leaf directories found." -Level Warn
            }
            return $totals
        }

        $zoCompleteMsg = "Zip-only processing complete: " + $totals.ZippedSuccess + " zipped, " + $totals.ZippedFail + " failed."
        if ($totals.ForceStoppedCount -gt 0) {
            $zoCompleteMsg += (" " + $totals.ForceStoppedCount + " job(s) force-stopped on abort.")
        }
        Write-Log $zoCompleteMsg -Level Summary
    } finally {
        Complete-CcrAllSeriesProgressIfEnabled
    }

    return $totals
}
