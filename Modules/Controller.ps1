# See Docs/module-descriptions.md for this module's full description.

# ==============================================================================
#  DISPATCH-REDESIGN STEP 4 - see Docs/module-descriptions.md's Controller.ps1
#  section for the full design.
# ==============================================================================

function Add-FullPipelineZipBlockReason {
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
    param(
        [Parameter(Mandatory)]
        [System.Collections.Concurrent.ConcurrentDictionary[string, System.Lazy[hashtable]]]$Cache,
        [Parameter(Mandatory)]
        [System.IO.DirectoryInfo]$Series,
        [string]$MagickExe,
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
        $chapters = Get-SeriesChapters -SeriesPath $Series.FullName -QualifyingExtensions $FolderQualifyingExtensions `
            -ExcludeStagingDirs $FolderExcludeStagingDirs -ForceRezip $false

        $imageCandidates    = Get-LooseImageCandidates -ScanPath $Series.FullName -LooseImageExtensions $LooseImageExtensions `
            -KnownZipPaths $KnownZipPaths -ExcludeStagingDirs $FolderExcludeStagingDirs
        $animatedCandidates = Get-LooseAnimatedCandidates -ScanPath $Series.FullName -AnimatedFileExtensions $AnimatedFileExtensions `
            -KnownZipPaths $KnownZipPaths -ExcludeStagingDirs $FolderExcludeStagingDirs

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
    param(
        [Parameter(Mandatory)]
        [System.Collections.Concurrent.ConcurrentDictionary[object, System.Lazy[hashtable]]]$Cache,
        [Parameter(Mandatory)]
        [hashtable]$ChapterInfo,
        [string]$MagickExe,
        [string[]]$LooseImageExtensions,
        [Parameter(Mandatory)]
        [System.Collections.Concurrent.ConcurrentQueue[hashtable]]$EventQueue,
        [Parameter(Mandatory)]
        [System.Collections.Concurrent.ConcurrentDictionary[object,string]]$ZipBlockReasons
    )

    $factory = {
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
                    $isAnimated = Test-AvifAnimated -AvifPath $img.FullName -MagickExe $MagickExe
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

        if ($staleSources.Count -gt 0 -and -not (Test-AbortSignal)) {
            $chStaleResult = Remove-StaleLooseSources -StaleSources $staleSources
            $EventQueue.Enqueue(@{ Kind = 'ChapterStaleCleanup'; Success = $chStaleResult.Success; Fail = $chStaleResult.Fail })
        }

        return @{ Images = $images; AnimatedFiles = $animated }
    }.GetNewClosure()

    $freshLazy = [System.Lazy[hashtable]]::new([Func[hashtable]]$factory, [System.Threading.LazyThreadSafetyMode]::ExecutionAndPublication)
    $lazy = $Cache.GetOrAdd($ChapterInfo, $freshLazy)
    $result = $lazy.Value
    return $result
}

function Complete-MergedFullPipelineChapter {
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
            # Swallowed deliberately - best-effort cleanup of a zip that
            # failed to build; a failure to delete it shouldn't mask the
            # real zip error already logged above.
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

# Get-ZipBlockedStatusOverride is intentionally NOT redefined here - the
# real definition lives in ImageConversionPipeline.ps1 (dot-sourced
# before this module on every real path). See Docs/function-notes.md's
# Controller.ps1 section for why.

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
    # Hashtable, not a plain scalar (2026-09-14 fix, Todo.md finding) - see
    # ChapterDispatch.ps1's New-LibraryChapterProvider for why a plain
    # scalar assigned inside this .GetNewClosure()'d scriptblock doesn't
    # latch across invocations.
    $chapterProviderState = @{ SeriesExhausted = $false }

    $chapterProvider = {
        while ($chapterQueue.Count -eq 0 -and -not $chapterProviderState.SeriesExhausted) {
            if (Test-AbortSignal) { $chapterProviderState.SeriesExhausted = $true; break }
            $series = & $seriesProvider
            if ($null -eq $series) { $chapterProviderState.SeriesExhausted = $true; break }

            $bundle = Get-OrCreateFullPipelineSeriesBundle -Cache $SeriesBundleCache -Series $series -MagickExe $MagickExe `
                -LooseImageExtensions $LooseImageExtensions -AnimatedFileExtensions $AnimatedFileExtensions -KnownZipPaths $KnownZipPaths `
                -FolderQualifyingExtensions $FolderQualifyingExtensions -FolderExcludeStagingDirs $FolderExcludeStagingDirs `
                -EventQueue $EventQueue -ZipBlockReasons $ZipBlockReasons

            foreach ($entry in $bundle.ChapterEntries) { $chapterQueue.Enqueue($entry) }
        }
        if ($chapterQueue.Count -gt 0) { return $chapterQueue.Dequeue() }
        return $null
    }.GetNewClosure()

    $chapterResults = [System.Collections.Generic.Dictionary[object,hashtable]]::new()

    if ($EngineType -eq 'Image') {
        $jobBuilder = {
            param($chapterInfo)
            $classified = Get-OrCreateFullPipelineChapterClassification -Cache $ChapterClassificationCache -ChapterInfo $chapterInfo `
                -MagickExe $MagickExe -LooseImageExtensions $LooseImageExtensions -EventQueue $EventQueue -ZipBlockReasons $ZipBlockReasons

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
                # DOCUMENTED DUPLICATE: this same format-label switch is
                # copied at job-build time in Convert-ImageBatch's own
                # pre-pass and Invoke-LooseImageConversionPipeline's own
                # JobBuilder (both ImageConversionPipeline.ps1) - keep all
                # three in sync if the set of magick-detour formats ever
                # changes.
                $formatLabel = switch -Regex ($srcPath) {
                    '\.avif$' { "AVIF"; break }
                    '\.webp$' { "WebP"; break }
                    '\.bmp$'  { "BMP";  break }
                    '\.heic$' { "HEIC"; break }
                    '\.heif$' { "HEIF"; break }
                    default   { $null }
                }
                $allJobs.Add(@{
                    SrcPath     = $srcPath
                    JxlPath     = [System.IO.Path]::ChangeExtension($srcPath, ".jxl")
                    Proc        = $null
                    TempPng     = $null
                    FormatLabel = $formatLabel
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

        $jobStarter = {
            param($job)
            $cr = $chapterResults[$job.ChapterKey]
            $tempPngLocal = $null
            $magickProcLocal = $null
            $failureAlreadyAccounted = $false
            try {
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName               = $CjxlExe
                $psi.UseShellExecute        = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $psi.CreateNoWindow         = $true

                if ($job.TempPng) {
                    $cjxlSrc = $job.TempPng
                } elseif ($job.FormatLabel) {
                    $formatLabel = $job.FormatLabel
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
                        try { $magickProc.Kill() } catch { }   # already-exited/access-denied races are fine to ignore - Dispose() right below runs regardless
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
                    if ($magickExitCode -ne 0 -or -not [System.IO.File]::Exists($tempPng)) {
                        Write-Log ("FAILED " + $formatLabel + "->PNG pre-conversion for '" + $job.SrcPath + "': magick exited " + $magickExitCode) -Level Error
                        $cr.FailedCount++
                        $failureAlreadyAccounted = $true
                        if ([System.IO.File]::Exists($tempPng)) { try { [System.IO.File]::Delete($tempPng) } catch { } }   # best-effort cleanup of the failed temp PNG - a delete failure shouldn't mask the real pre-conversion error thrown right below
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
                # Best-effort cleanup on the way out - a process kill/dispose or
                # temp-file delete failing here shouldn't mask the real error
                # already logged above and being rethrown right below.
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
        $jobBuilder = {
            param($chapterInfo)
            $classified = Get-OrCreateFullPipelineChapterClassification -Cache $ChapterClassificationCache -ChapterInfo $chapterInfo `
                -MagickExe $MagickExe -LooseImageExtensions $LooseImageExtensions -EventQueue $EventQueue -ZipBlockReasons $ZipBlockReasons

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

                $webpPathExists = [System.IO.File]::Exists($webpPath)
                if ($webpPathExists -and -not $DoAnimatedOverwrite) {
                    Write-Log ("SKIPPING '" + $srcPath + "': output '" + $webpPath + "' already exists (Overwrite is off).")
                    $cr.SkippedCount++
                    $cr.SkippedPaths.Add($srcPath)
                    continue
                }

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
            $cr = $chapterResults[$job.ChapterKey]
            try {
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
            } catch {
                # Bare Process.Start() throws a NON-terminating error when
                # uncaught (Docs/lessons-learned.md's 7th entry) - without
                # this try/catch, $job.Proc stays $null and $job.Proc.HasExited
                # (jobPollCompleted below) is falsy forever, hanging the whole
                # engine. Rethrow so ChapterDispatch's own JobStarter catch
                # accounts for it and moves on, same shape as the image
                # engine's jobStarter above. DOCUMENTED DUPLICATE:
                # AnimatedConversionPipeline.ps1's Invoke-LooseAnimatedConversionPipeline
                # (mode 3) has the same try/catch around the same call -
                # keep both in sync.
                Write-Log ("FAILED to start animated conversion process for '" + $job.SrcPath + "': " + $_) -Level Error
                $cr.FailedCount++
                throw
            }
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
        $null = $chapterResults.Remove($chapterInfo)
    }.GetNewClosure()

    # Hashtable, not a plain scalar (2026-09-14 fix, Todo.md finding) - a
    # plain $abortMessagePrinted assigned inside this .GetNewClosure()'d
    # scriptblock resets to $false on every invocation instead of
    # latching, confirmed live - the once-only guard below never actually
    # held. Currently harmless (the dispatch loop stops polling within an
    # iteration or two of Test-AbortSignal first returning true), but a
    # real bug if this poll callback is ever invoked more times after an
    # abort than it is today.
    $abortState = @{ MessagePrinted = $false }
    $abortPollCallback = {
        param($runningJobs)
        $aborted = Test-AbortSignal
        if ($aborted -and -not $abortState.MessagePrinted) {
            $abortState.MessagePrinted = $true
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
              'Test-AbortSignal', 'Get-LooseImageCandidates', 'Remove-StaleLooseSources', 'Get-LooseAnimatedCandidates',
              'Get-LooseImageExtensions', 'Test-OrphanedScratchFileName')

        $null = Invoke-ZipParallelProcessing -WorkerScript $script:fullPipelineEngineWorker -JobParams $jobParamsWorker `
            -SharedFunctionNames $engineWorkerSharedFunctionNames -MaxParallel 2 -Cts $fullCts -ResultHandler $engineResultHandler `
            -AbortWaitMessage "[ABORT] Waiting for current image/animated jobs to finish (up to 60s)..." -PollCallback $pollCallback

        foreach ($leftoverKey in @($mergeState.Keys)) {
            & $finalizeChapterEntry $leftoverKey $mergeState[$leftoverKey]
        }
        $mergeState.Clear()
    } finally {
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
#  TOP-LEVEL DISPATCHER - Invoke-Mode
# ==============================================================================

function Invoke-Mode {
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
        if ($Resolved.Mode -in @('AnimatedConversion', 'FullPipeline') -and [string]::IsNullOrWhiteSpace($MagickExe)) {
            throw ("Mode '" + $Resolved.Mode + "' requires magick.exe, which was not found or configured.")
        }

        $stats = New-StatsTracker

        switch ($Resolved.Mode) {
            'ImageConversion' {
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
                $r = & $ZipFoldersHandler -Path $TargetPath -MaxParallel $Settings.ZipParallelThreads -DeleteFolders $true `
                    -FullLogging $script:FullLogging -LogFile $LogFile -LogErrorFile $LogErrorFile -LogWarnFile $LogWarnFile -PermanentDelete ([bool]$Settings.PermanentDelete)
                $stats.ZipOnlyZipped.Success        = $r.ZippedSuccess;        $stats.ZipOnlyZipped.Fail        = $r.ZippedFail
                $stats.ZipOnlyFolderDeleted.Success = $r.FolderDeletedSuccess; $stats.ZipOnlyFolderDeleted.Fail = $r.FolderDeletedFail
                $stats.Aborted           = $r.Aborted
                $stats.ForceKilledCount  = $r.ForceStoppedCount
            }
            'FullPipeline' {
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
                $zipLooseExtensions = if ($Settings.ZipWithUnconvertedAnimated) {
                    @((Get-LooseImageExtensions) | Where-Object { $_ -ne ".avif" -and (Get-NeverConvertedExtensions) -inotcontains $_ })
                } else {
                    @((Get-LooseImageExtensions) | Where-Object { (Get-NeverConvertedExtensions) -inotcontains $_ })
                }
                $zipStatsBox = @{ Success = 0; Fail = 0; Skipped = 0; FolderDeletedSuccess = 0; FolderDeletedFail = 0 }
                $zipStep = {
                    param($Info)
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

                $r = & $ImageConversionHandler -Path $TargetPath -CjxlExe $CjxlExe -MagickExe $MagickExe `
                    -JpegLossless ([bool]$Settings.JpegLossless) -JpegQuality $Settings.JpegQuality -MaxCjxlProcs $Settings.MaxCjxlProcs -FullLogging $script:FullLogging `
                    -ZipStepCallback $zipStep
                $stats.LooseImgConverted.Success = $r.ConvertedSuccess; $stats.LooseImgConverted.Fail = $r.ConvertedFail; $stats.LooseImgConverted.Skipped = $r.ConvertedSkipped
                $stats.LooseImgDeleted.Success   = $r.DeletedSuccess;   $stats.LooseImgDeleted.Fail   = $r.DeletedFail
                $stats.LooseStaleCleaned.Success = $r.StaleCleanedSuccess; $stats.LooseStaleCleaned.Fail = $r.StaleCleanedFail
                $stats.InspectFailed.Count       = $r.InspectFailedCount
                $stats.LooseFolderZipped.Success  = $zipStatsBox.Success
                $stats.LooseFolderZipped.Fail      = $zipStatsBox.Fail
                $stats.LooseFolderZipped.Skipped   = $zipStatsBox.Skipped
                $stats.LooseFolderDeleted.Success  = $zipStatsBox.FolderDeletedSuccess
                $stats.LooseFolderDeleted.Fail      = $zipStatsBox.FolderDeletedFail
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

    $lastFullLogging        = [bool]$Settings.FullLogging
    $lastDisableSummaryFile = [bool]$Settings.DisableSummaryFile

    # Passed into Get-SelectedMode/Show-ModeMenu so Cover Deletion (menu
    # option 5, which runs BEFORE this loop's own re-init check below ever
    # sees a Full Logging/Disable Summary File toggle made in the SAME menu
    # visit) can re-init log paths itself instead of logging into stale
    # Errors/Warnings files (2026-09-14 fix, Todo.md finding). Reading
    # $Settings live (closure, not params) means this loop's own check
    # below will see the same already-current values and just no-op its
    # own re-init - redundant but harmless, not worth threading state back
    # across the Get-SelectedMode call boundary to avoid.
    $reinitLogPathsHandler = {
        & $InitializeLogPathsHandler -TargetPath $TargetPath -FullLogging ([bool]$Settings.FullLogging) -DisableSummaryFile ([bool]$Settings.DisableSummaryFile) -ScriptDir $ScriptDir
        $previousLogMutexForDispose = $script:logMutex
        & $InitializeLogMutexHandler
        # A failed Dispose() on the OLD mutex is harmless - a fresh one was
        # just created above, and .NET will finalize the old handle eventually.
        if ($null -ne $previousLogMutexForDispose) { try { $previousLogMutexForDispose.Dispose() } catch { } }
    }.GetNewClosure()

    while ($true) {
        & $ResetAbortHandler

        $resolved = $null
        try {
            $resolved = & $GetModeHandler -Settings $Settings -SettingsPath $SettingsPath -ReinitLogPathsHandler $reinitLogPathsHandler
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

        $currentFullLogging        = [bool]$Settings.FullLogging
        $currentDisableSummaryFile = [bool]$Settings.DisableSummaryFile
        if ($currentFullLogging -ne $lastFullLogging -or $currentDisableSummaryFile -ne $lastDisableSummaryFile) {
            & $InitializeLogPathsHandler -TargetPath $TargetPath -FullLogging $currentFullLogging -DisableSummaryFile $currentDisableSummaryFile -ScriptDir $ScriptDir
            $previousLogMutexForDispose = $script:logMutex
            & $InitializeLogMutexHandler
            # A failed Dispose() on the OLD mutex is harmless - see $reinitLogPathsHandler above for the same pattern/reasoning.
            if ($null -ne $previousLogMutexForDispose) { try { $previousLogMutexForDispose.Dispose() } catch { } }
            $LogFile        = $script:logFile
            $LogErrorFile   = $script:logErrorFile
            $LogWarnFile    = $script:logWarnFile
            $lastFullLogging        = $currentFullLogging
            $lastDisableSummaryFile = $currentDisableSummaryFile
        }
        Initialize-CleanConsoleOutput -Enabled ([bool]$Settings.CleanConsoleOutputEnabled)
        Initialize-FileDeletion -PermanentDelete ([bool]$Settings.PermanentDelete)

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

        if ($null -eq $stats) {
            Write-Log "Run did not complete - see the error above." -Level Warn
            & $CompleteLogRunHandler
        } else {
            $elapsedString = Format-ElapsedTime -Elapsed $runStopwatch.Elapsed
            $summaryLines = Get-SummaryLines -Stats $stats -ElapsedString $elapsedString -ModeFlags $resolved
            Write-SummaryReport -Lines $summaryLines -FullLogging $script:FullLogging
            & $CompleteLogRunHandler
        }

        $postRun = & $PostRunPromptHandler
        if ($postRun -eq 'Exit') { break }
        Write-Host ""
    }
}
