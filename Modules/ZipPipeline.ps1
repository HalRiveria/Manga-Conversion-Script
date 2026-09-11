# See Docs/module-descriptions.md for this module's full description.

# ==============================================================================
#  PART 1 - mode 3 (zip-only pipeline)
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
    if ($ZipResult.Failed -eq 1) { return "Error", "zip failed" }
    if ($ZipResult.FolderDeleteFailed -eq 1) { return "Warning", "zipped OK, but source folder delete failed" }
    return "Success", $null
}

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
        [bool]$CleanConsoleOutputEnabled,
        [System.Threading.Mutex]$LogMutex,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ConsoleQueue,
        [System.Threading.CancellationToken]$CancelToken
    )

    Add-Type -AssemblyName "Microsoft.VisualBasic"
    Add-Type -AssemblyName "System.IO.Compression.FileSystem"

    $script:logMutex           = $LogMutex
    $script:workerConsoleQueue = $ConsoleQueue
    $script:FullLogging        = $DoFullLogging
    $script:logFile            = $LogFile
    $script:logErrorFile       = $LogErrorFile
    $script:logWarnFile        = $LogWarnFile
    $script:PermanentDelete    = $DoPermanentDelete
    $script:CleanConsoleOutputEnabled = $CleanConsoleOutputEnabled

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
        # Same orphaned-scratch-file regex trio as Invoke-LooseFolderZip's
        # own sweep below in this file - keep both in sync if either changes.
        $orphanedScratchFiles = @(Get-ChildItem -LiteralPath $FolderPath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -imatch '_tmp_iccstrip(-\d+)?\.png$' -or
                $_.Name -imatch '_tmp_(webp|avif|bmp|heic|heif)2png\.png$' -or
                $_.Name -imatch '_tmp_overwrite\.webp$'
            })
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

        if ($DeleteFolders) {
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
    } catch {
        Write-Log ("FAILED to zip '" + $folderName + "': " + $_) -Level Error
        $result.Failed = 1
        try {
            if (Test-Path -LiteralPath $ZipOutPath) { [System.IO.File]::Delete($ZipOutPath) }
        } catch { }
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
        Aborted              = $false
    }

    try {
        Write-Log ("Zip-only: scanning and zipping leaf directories incrementally (up to " + $MaxParallel + " in parallel)...")

        $leafProvider = New-ZippableLeafDirProvider -ScanPath $Path -QualifyingExtensions $QualifyingExtensions -ForceRezip $false

        $zoSeenSeriesNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $trimmedPath = $Path.TrimEnd([System.IO.Path]::DirectorySeparatorChar)

        $zoJobProvider = {
            $next = & $leafProvider
            if ($null -eq $next) { return $null }
            $totals.CandidateCount++

            $dirFullName = $next.Dir.FullName
            if ($dirFullName.StartsWith($trimmedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $relativePath = $dirFullName.Substring($trimmedPath.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar)
                $topLevelName = ($relativePath -split [regex]::Escape([System.IO.Path]::DirectorySeparatorChar))[0]
                $seriesName = if ([string]::IsNullOrEmpty($topLevelName)) { $next.Dir.Name } else { $topLevelName }
            } else {
                Write-Log ("Zip-only: '" + $dirFullName + "' does not start with the scan root '" + $trimmedPath + "' as expected - using its own folder name for the Clean Console Output series display instead of deriving one.") -Level Warn
                $seriesName = $next.Dir.Name
            }

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
                CleanConsoleOutputEnabled = (Test-CcrEnabledForZipOnly)
            }
        }.GetNewClosure()

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
            $totals.Aborted = $script:zipOnlyCts.Token.IsCancellationRequested
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
        Complete-CcrAllSeriesProgressIfEnabled
    }

    return $totals
}

# ==============================================================================
#  PART 2 - mode 2's per-folder zip step
# ==============================================================================

function Invoke-LooseFolderZip {
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
    $reportCcr  = ($PSBoundParameters.ContainsKey('SeriesName') -and $PSBoundParameters.ContainsKey('ChapterName'))
    if ($reportCcr) { Start-CcrChapterProgressIfEnabled -SeriesName $SeriesName -ChapterName $ChapterName }

    try {
        # Same orphaned-scratch-file regex trio as $script:zipOnlyWorker's
        # own sweep above in this file - keep both in sync if either changes.
        # Kept as this module's own literal rather than calling
        # ImageConversionPipeline.ps1's Test-OrphanedScratchFileName since
        # this module's own harness deliberately doesn't dot-source that
        # module - see Docs/function-notes.md.
        $orphanedScratchFiles = @(Get-ChildItem -LiteralPath $FolderPath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -imatch '_tmp_iccstrip(-\d+)?\.png$' -or
                $_.Name -imatch '_tmp_(webp|avif|bmp|heic|heif)2png\.png$' -or
                $_.Name -imatch '_tmp_overwrite\.webp$'
            })
        foreach ($orphan in $orphanedScratchFiles) {
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
                $removed = Remove-Source -ItemPath $FolderPath
                if ($removed) {
                    $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
                    Write-Log ("Deleted folder (" + $deleteDesc + "): '" + $FolderPath + "'")
                    $result.FolderDeleted = $true
                } else {
                    Write-Log ("Folder already gone before deletion (not counted as deleted): '" + $FolderPath + "'") -Level Warn
                }
            } catch {
                Write-Log ("FAILED to delete folder '" + $FolderPath + "': " + $_) -Level Error
                $result.FolderDeleteFailed = $true
            }
        } catch {
            Write-Log ("FAILED to zip folder '" + $FolderPath + "': " + $_) -Level Error
            $result.Status = "Fail"
            try {
                if (Test-Path -LiteralPath $ZipOut) { [System.IO.File]::Delete($ZipOut) }
            } catch { }
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
