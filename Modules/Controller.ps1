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
    while ($true) {
        if ($Dict.TryAdd($ChapterKey, $Reason)) { return }
        $existing = $null
        if ($Dict.TryGetValue($ChapterKey, [ref]$existing)) {
            if ($existing -like ("*" + $Reason + "*")) { return }
            if ($Dict.TryUpdate($ChapterKey, $existing + ", " + $Reason, $existing)) { return }
        }
    }
}

function Get-OrCreateFullPipelineCacheEntry {
    param(
        [Parameter(Mandatory)]
        $Cache,
        [Parameter(Mandatory)]
        $Key,
        [Parameter(Mandatory)]
        [scriptblock]$Factory
    )
    $slot = $Cache.GetOrAdd($Key, @{ Gate = [object]::new(); Done = $false; Value = $null; Error = $null })
    [System.Threading.Monitor]::Enter($slot.Gate)
    try {
        if (-not $slot.Done) {
            try { $slot.Value = & $Factory } catch { $slot.Error = $_ }
            $slot.Done = $true
        }
    } finally {
        [System.Threading.Monitor]::Exit($slot.Gate)
    }
    if ($null -ne $slot.Error) { throw $slot.Error }
    return $slot.Value
}

function Get-OrCreateFullPipelineSeriesBundle {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Concurrent.ConcurrentDictionary[string, hashtable]]$Cache,
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

    return Get-OrCreateFullPipelineCacheEntry -Cache $Cache -Key $Series.FullName -Factory $factory
}

function Get-OrCreateFullPipelineChapterClassification {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Concurrent.ConcurrentDictionary[object, hashtable]]$Cache,
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
                # DOCUMENTED DUPLICATE: the same Test-AbortSignal check before each
                # per-file Test-AvifAnimated spawn also lives in
                # ImageConversionPipeline.ps1's and AnimatedConversionPipeline.ps1's
                # jobBuilders - keep all three in sync.
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

    return Get-OrCreateFullPipelineCacheEntry -Cache $Cache -Key $ChapterInfo -Factory $factory
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
            # Get-FilesRecursiveSafe, not Get-ChildItem -Recurse | Where-Object
            # (2026-09-16 fix) - this runs on the MAIN thread, concurrently
            # with both engine worker runspaces still processing later
            # chapters (called from $pollCallback/$finalizeChapterEntry
            # above). Never proven to hit this project's own confirmed PS
            # 5.1 concurrent-runspace cmdlet-race (that class needs two
            # FRESH runspaces racing on their own first invocation - the
            # main thread's own Get-ChildItem/Where-Object use is not
            # "fresh" by the time a real run gets here), but reuses
            # already-tested, already-.NET-only infrastructure either way,
            # and closes a real, independent gap this raw Get-ChildItem
            # call had: no reparse-point guard, unlike every other
            # recursive tree walk in this codebase since the 2026-09-15
            # junction-cycle fix (see LeafDirectoryDiscovery.ps1).
            $orphanedScratchFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
            foreach ($f in (Get-FilesRecursiveSafe -ScanPath $ChapterDir)) {
                if (Test-OrphanedScratchFileName -Name $f.Name) { $orphanedScratchFiles.Add($f) }
            }
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
        [bool]$DoPermanentDelete,
        [System.Threading.SemaphoreSlim]$SharedBudget,
        [System.Collections.Concurrent.ConcurrentDictionary[string, hashtable]]$SeriesBundleCache,
        [System.Collections.Concurrent.ConcurrentDictionary[object, hashtable]]$ChapterClassificationCache,
        [System.Collections.Concurrent.ConcurrentDictionary[object,string]]$ZipBlockReasons,
        [System.Collections.Concurrent.ConcurrentDictionary[object,byte]]$AnnouncedChapters,
        [System.Collections.Concurrent.ConcurrentDictionary[object,byte]]$RunningChapters,
        [bool]$AnimatedEnabled = $true,
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
    # Only these two - worker log lines go through the queue; see Docs/function-notes.md (Get-WorkerRunspaceValue).
    $script:workerConsoleQueue = $ConsoleQueue
    $script:PermanentDelete    = $DoPermanentDelete

    $seriesProvider  = New-SeriesProvider -LibraryPath $Path -QualifyingExtensions $FolderQualifyingExtensions
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

            $skippedAnimated = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
            if (-not $AnimatedEnabled) {
                $imagePathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($f in $classified.Images) { $null = $imagePathSet.Add($f.FullName) }
                foreach ($f in $classified.AnimatedFiles) { if (-not $imagePathSet.Contains($f.FullName)) { $skippedAnimated.Add($f) } }
            }

            $cr = @{
                ConvertedCount = 0; FailedCount = 0; SkippedCount = 0; DeletedCount = 0; DeleteFailedCount = 0
                InspectFailedCount = 0; ForceKilledCount = 0
                SkippedPaths = [System.Collections.Generic.List[string]]::new()
                TotalFiles = $classified.Images.Count + $skippedAnimated.Count
            }
            $chapterResults[$chapterInfo] = $cr

            if ($cr.TotalFiles -eq 0) { return @() }

            # Announce only once this engine has real work - see Docs/function-notes.md (Invoke-FullPipeline, "CCR announcement pacing").
            # DOCUMENTED DUPLICATE: same move in the animated jobBuilder below - keep both in sync.
            if ($AnnouncedChapters.TryAdd($chapterInfo, 0)) {
                $EventQueue.Enqueue(@{ Kind = 'ChapterStarted'; ChapterKey = $chapterInfo; SeriesName = $chapterInfo.SeriesName; ChapterName = $chapterInfo.ChapterName })
            }
            Write-Log ("Processing chapter (image engine): '" + $chapterInfo.Dir.FullName + "' (" + $cr.TotalFiles + " image(s))")

            foreach ($f in $skippedAnimated) {
                Write-Log ("SKIPPING animated AVIF '" + $f.FullName + "': animated conversion is turned off for Full Pipeline - file left as-is (it will be zipped unconverted).") -Level Warn
                $cr.SkippedCount++
                $cr.SkippedPaths.Add($f.FullName)
            }

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
                # also copied at job-build time in
                # Invoke-LooseImageConversionPipeline's own JobBuilder
                # (ImageConversionPipeline.ps1) - keep both in sync if the
                # set of magick-detour formats ever changes.
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
            # DOCUMENTED DUPLICATE: the same once-per-chapter queued -> in
            # progress flip is in this file's other engine jobStarter and
            # (called directly, main thread) ImageConversionPipeline.ps1's/
            # AnimatedConversionPipeline.ps1's jobStarters - keep all four in sync.
            if ($RunningChapters.TryAdd($job.ChapterKey, 0)) {
                $EventQueue.Enqueue(@{ Kind = 'ChapterRunning'; SeriesName = $job.ChapterKey.SeriesName; ChapterName = $job.ChapterKey.ChapterName })
            }
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
                    # %% on the OUTPUT path only (2026-09-16 fix, real bug,
                    # live-reported and confirmed - DOCUMENTED DUPLICATE of
                    # AnimatedConversionPipeline.ps1's matching jobStarter
                    # comment, keep all copies in sync). The SOURCE does
                    # NOT need this - reading an existing file with a
                    # literal % works fine unescaped; an earlier version of
                    # this fix mistakenly escaped it too, which broke it
                    # outright (magick looking for a literal %% that
                    # doesn't exist on disk, live-reported the same day).
                    $escapedTempPng    = $tempPng.Replace('%', '%%')
                    $magickPsi.Arguments              = "`"" + $job.SrcPath + "[0]`" `"" + $escapedTempPng + "`""
                    $magickPsi.UseShellExecute        = $false
                    $magickPsi.RedirectStandardOutput = $true
                    $magickPsi.RedirectStandardError  = $true
                    $magickPsi.CreateNoWindow         = $true
                    $magickProc = [System.Diagnostics.Process]::Start($magickPsi)
                    $null = [ChildProcessJob]::Assign($magickProc)  # see AbortPipeline.ps1's ChildProcessJob
                    $magickProcLocal = $magickProc
                    $magickStdoutTask = $magickProc.StandardOutput.ReadToEndAsync()
                    $magickStderrTask = $magickProc.StandardError.ReadToEndAsync()
                    # DOCUMENTED DUPLICATE of ImageConversionPipeline.ps1's own
                    # jobStarter's identical PNG pre-conversion wait (ported
                    # there 2026-09-15, after a full line-by-line review found
                    # it was still using a bare, unbounded WaitForExit() - the
                    # exact bug this codebase already fixed here) - keep both
                    # in sync.
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
                    # Bounded the same way Test-AvifAnimated/
                    # Invoke-IccStripRetryOrFail already are (2026-09-16 fix,
                    # real bug found by a Gemini review - this pre-conversion
                    # detour and ImageConversionPipeline.ps1's own copy were
                    # missed during that same pass). The WaitOne above only
                    # proves the PROCESS exited, not that its redirected
                    # stdout/stderr pipes reached EOF - a process tree where
                    # something else inherited the handle could still hang
                    # the un-timed GetResult() forever.
                    if (-not [System.Threading.Tasks.Task]::WaitAll(@($magickStdoutTask, $magickStderrTask), 15000)) {
                        $magickProc.Dispose()
                        $magickProcLocal = $null
                        throw ("magick pre-conversion exited but its output streams did not finish reading within 15s")
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
                $null = [ChildProcessJob]::Assign($job.Proc)  # see AbortPipeline.ps1's ChildProcessJob
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
            # DOCUMENTED DUPLICATE of this same function's own animated-
            # engine jobAbortCleanup below, and of
            # ImageConversionPipeline.ps1/AnimatedConversionPipeline.ps1's
            # own copies - keep all four in sync. Feeds
            # Get-ChapterProgressStatus/Get-MergedChapterStatus so a
            # force-killed/never-started chapter reports as "N
            # force-stopped" (and, critically, NOT a plain 'Success' that
            # Complete-MergedFullPipelineChapter would then zip and
            # delete) instead of silently disappearing (2026-09-15 fix).
            $cr = $chapterResults[$job.ChapterKey]
            if ($null -ne $cr) { $cr.ForceKilledCount++ }
        }.GetNewClosure()
    } else {
        $jobBuilder = {
            param($chapterInfo)
            $classified = Get-OrCreateFullPipelineChapterClassification -Cache $ChapterClassificationCache -ChapterInfo $chapterInfo `
                -MagickExe $MagickExe -LooseImageExtensions $LooseImageExtensions -EventQueue $EventQueue -ZipBlockReasons $ZipBlockReasons

            $cr = @{
                ConvertedCount = 0; FailedCount = 0; SkippedCount = 0; StaticSkippedCount = 0
                InspectFailedCount = 0; DeletedCount = 0; DeleteFailedCount = 0; ForceKilledCount = 0
                SkippedPaths = [System.Collections.Generic.List[string]]::new()
                StaticSkippedPaths = [System.Collections.Generic.List[string]]::new()
                TotalFiles = $classified.AnimatedFiles.Count
            }
            $chapterResults[$chapterInfo] = $cr

            if ($cr.TotalFiles -eq 0) { return @() }

            # Announce only once this engine has real work. DOCUMENTED DUPLICATE: same move
            # in the image jobBuilder above - keep both in sync.
            if ($AnnouncedChapters.TryAdd($chapterInfo, 0)) {
                $EventQueue.Enqueue(@{ Kind = 'ChapterStarted'; ChapterKey = $chapterInfo; SeriesName = $chapterInfo.SeriesName; ChapterName = $chapterInfo.ChapterName })
            }
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
            # DOCUMENTED DUPLICATE: the same once-per-chapter queued -> in
            # progress flip is in this file's other engine jobStarter and
            # (called directly, main thread) ImageConversionPipeline.ps1's/
            # AnimatedConversionPipeline.ps1's jobStarters - keep all four in sync.
            if ($RunningChapters.TryAdd($job.ChapterKey, 0)) {
                $EventQueue.Enqueue(@{ Kind = 'ChapterRunning'; SeriesName = $job.ChapterKey.SeriesName; ChapterName = $job.ChapterKey.ChapterName })
            }
            try {
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName = $MagickExe
                $qualityArg = if ($DoAnimatedLossless) { "-define webp:lossless=true" } else { "-quality " + $AnimatedQuality }
                # %% on the OUTPUT path only (2026-09-16 fix, real bug,
                # live-reported and confirmed - DOCUMENTED DUPLICATE of
                # AnimatedConversionPipeline.ps1's own matching jobStarter,
                # keep both in sync). The SOURCE does NOT need this -
                # reading an existing file with a literal % works fine
                # unescaped; an earlier version of this fix mistakenly
                # escaped it too, which broke it outright (magick looking
                # for a literal %% that doesn't exist on disk, live-
                # reported the same day).
                $escapedOutPathAnim = $job.MagickOutputPath.Replace('%', '%%')
                $psi.Arguments = "`"" + $job.SrcPath + "`" -coalesce -loop 0 " + $qualityArg + " `"" + $escapedOutPathAnim + "`""
                $psi.UseShellExecute        = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $psi.CreateNoWindow         = $true

                Write-Log ("Converting animated: '" + $job.SrcPath + "'")

                $job.Proc       = [System.Diagnostics.Process]::Start($psi)
                $null = [ChildProcessJob]::Assign($job.Proc)  # see AbortPipeline.ps1's ChildProcessJob
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
            # DOCUMENTED DUPLICATE - see this same function's own image-
            # engine jobAbortCleanup above for the full explanation; keep
            # all four copies (that one, this one,
            # ImageConversionPipeline.ps1, AnimatedConversionPipeline.ps1)
            # in sync.
            $cr = $chapterResults[$job.ChapterKey]
            if ($null -ne $cr) { $cr.ForceKilledCount++ }
        }.GetNewClosure()
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
    # abort than it is today. DOCUMENTED DUPLICATE: the identical pattern
    # (same fields, same reasoning) also appears in
    # ImageConversionPipeline.ps1's and AnimatedConversionPipeline.ps1's own
    # abort-poll callbacks - keep all three in sync.
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
        [bool]$CoverDeletionDryRun = $true,
        [bool]$AnimatedConversionEnabled = $true,
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message },
        # Injectable (2026-09-16, Todo.md's own tracked gap) - lets a test
        # substitute a scriptblock that deliberately throws, to genuinely
        # exercise -JobCrashedHandler's real code path end-to-end. Real
        # callers never pass this; it defaults to the real engine worker.
        [scriptblock]$EngineWorkerScript = $script:fullPipelineEngineWorker
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
            $null = & $CoverDeletionScanHandler -Path $Path -DryRun $CoverDeletionDryRun
        } catch {
            $exMessage = $_.Exception.Message
            Write-Log ("Cover deletion pre-scan failed: " + $exMessage) -Level Error -ForceConsole
            # Null-checked before .Trim() (2026-09-16 fix, real bug found by
            # a Gemini review, confirmed live) - Read-Host (the real
            # default -PromptFunc) returns $null, not "", when stdin is
            # genuinely closed/at EOF rather than just an empty line -
            # every other prompt call in this codebase already guards this
            # (Menu.ps1, UnwantedImage.ps1, Conversion Script Main.ps1);
            # this was the one that didn't, and would otherwise crash the
            # whole run with a NullReferenceException instead of the
            # graceful abort this catch block exists to provide.
            $rawAnswer = & $PromptFunc ("Cover deletion scan failed: " + $exMessage + ". Continue with conversion anyway? (Y/N)")
            $answer = if ($null -ne $rawAnswer) { $rawAnswer.Trim() } else { "" }
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
        $seriesBundleCache = [System.Collections.Concurrent.ConcurrentDictionary[string, hashtable]]::new()
        $chapterClassificationCache = [System.Collections.Concurrent.ConcurrentDictionary[object, hashtable]]::new()
        $zipBlockReasons   = [System.Collections.Concurrent.ConcurrentDictionary[object,string]]::new()
        $announcedChapters = [System.Collections.Concurrent.ConcurrentDictionary[object,byte]]::new()
        $runningChapters   = [System.Collections.Concurrent.ConcurrentDictionary[object,byte]]::new()
        $eventQueue        = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
        $fullCts = [System.Threading.CancellationTokenSource]::new()
        Register-AbortCancellationSource -Cts $fullCts

        # Deferred series start - see Docs/function-notes.md (Invoke-FullPipeline, "CCR announcement pacing").
        $seriesChapterTotals = @{}
        $startedSeries       = [System.Collections.Generic.HashSet[string]]::new()
        $ensureSeriesStarted = {
            param($seriesName)
            if (-not $cleanConsoleOutputEnabled) { return }
            if ($startedSeries.Contains($seriesName)) { return }
            $total = 0
            if ($seriesChapterTotals.ContainsKey($seriesName)) { $total = $seriesChapterTotals[$seriesName] }
            if ($total -gt 0) {
                Start-SeriesProgress -SeriesName $seriesName -TotalChapters $total
                $null = $startedSeries.Add($seriesName)
            }
        }.GetNewClosure()

        $finalizeChapterEntry = {
            param($key, $entry)
            $totals.ChapterCount++

            # Zip-only chapter: announce it now - see Docs/function-notes.md (Invoke-FullPipeline, "CCR announcement pacing").
            if ($cleanConsoleOutputEnabled -and $announcedChapters.TryAdd($key, 0)) {
                & $ensureSeriesStarted $entry.SeriesName
                Start-ChapterProgress -SeriesName $entry.SeriesName -ChapterName $entry.ChapterName
            }

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
            } elseif ($isZippableNow -and $fullCts.Token.IsCancellationRequested) {
                # Split from the genuine-error case below (2026-09-15 fix,
                # real bug, latent) - the original combined condition
                # conflated "this chapter's conversion genuinely errored"
                # with "the whole run was aborted," and would have labeled
                # a real conversion failure on a non-aborted run as "zip
                # skipped: run aborted". Currently masked -
                # Get-ZipBlockedStatusOverride (ImageConversionPipeline.ps1)
                # short-circuits `if ($Status -eq 'Error') { return $Status,
                # $Detail }` before the "run aborted" text is ever appended,
                # so today this branch is genuinely only reachable when the
                # run really was aborted. Splitting it removes the latent
                # trap rather than relying on that short-circuit staying in
                # place forever.
                $totals.ZipSkippedDueToError++
                $displayStatus, $displayDetail = Get-ZipBlockedStatusOverride -Status $chapterOutcome.Status -Detail $chapterOutcome.Detail -BlockedReason "run aborted"
            } elseif ($isZippableNow -and $chapterOutcome.Status -eq 'Error') {
                $totals.ZipSkippedDueToError++
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
                        # Record the total only; Start-SeriesProgress is deferred to $ensureSeriesStarted.
                        if ($evt.TotalChapters -gt 0) {
                            $seriesChapterTotals[$evt.SeriesName] = $evt.TotalChapters
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
                            & $ensureSeriesStarted $evt.SeriesName
                            Start-ChapterProgress -SeriesName $evt.SeriesName -ChapterName $evt.ChapterName -Queued:(-not $runningChapters.ContainsKey($evt.ChapterKey))
                        }
                    }
                    'ChapterRunning' {
                        if ($cleanConsoleOutputEnabled) {
                            Set-ChapterInProgress -SeriesName $evt.SeriesName -ChapterName $evt.ChapterName
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
                                ImageResult = $null; AnimatedResult = $null; GotImage = $false; GotAnimated = (-not $AnimatedConversionEnabled)
                            }
                        }
                        $entry = $mergeState[$key]
                        if ($evt.EngineType -eq 'Image') { $entry.ImageResult = $evt.Result; $entry.GotImage = $true }
                        else                              { $entry.AnimatedResult = $evt.Result; $entry.GotAnimated = $true }

                        if (-not ($entry.GotImage -and $entry.GotAnimated)) { continue }
                        # $null = (2026-09-15 fix) - Dictionary.Remove
                        # returns bool; the identical call at this
                        # function's own :697 (chapterCompleteCallback)
                        # already captures it correctly. Doesn't print
                        # today only because this whole poll callback is
                        # invoked bare and its output stream discarded by
                        # ZipParallelProcessing's own caller - not a reason
                        # to leave it uncaptured.
                        $null = $mergeState.Remove($key)
                        & $finalizeChapterEntry $key $entry
                    }
                }
            }
        }.GetNewClosure()

        $jobParamsWorker = [System.Collections.Generic.List[hashtable]]::new()
        $engineTypes = @('Image')
        if ($AnimatedConversionEnabled) { $engineTypes += 'Animated' }
        foreach ($engineType in $engineTypes) {
            $jobParamsWorker.Add(@{
                EngineType = $engineType; Path = $Path; CjxlExe = $CjxlExe; MagickExe = $MagickExe
                DoJpegLossless = $JpegLossless; DoJpegQuality = $JpegQuality
                DoAnimatedLossless = $AnimatedLossless; AnimatedQuality = $AnimatedQuality
                DoAnimatedOverwrite = $AnimatedOverwrite; DoAnimatedDeleteSource = $AnimatedDeleteSource
                DoFullLogging = $FullLogging; DoPermanentDelete = $PermanentDelete
                SharedBudget = $sharedBudget; SeriesBundleCache = $seriesBundleCache; ChapterClassificationCache = $chapterClassificationCache; ZipBlockReasons = $zipBlockReasons
                AnnouncedChapters = $announcedChapters; RunningChapters = $runningChapters; EventQueue = $eventQueue
                AnimatedEnabled = $AnimatedConversionEnabled
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

        # 2026-09-15 fix (real bug, HIGH severity - full line-by-line review
        # series): if one engine's runspace throws an unhandled exception,
        # -ResultHandler above is NEVER called for it (there is no result -
        # EndInvoke rethrows) - previously that meant $totals.Aborted never
        # got set from a crash alone, the surviving engine just kept going,
        # and every chapter the crashed engine hadn't yet reported on sat in
        # $mergeState forever with that engine's Got<Engine> flag still
        # false. The leftover-merge loop below used to hand those straight
        # to $finalizeChapterEntry anyway, and Get-ChapterProgressStatus($null)
        # (ImageConversionPipeline.ps1) returns a bare "Success" for a $null
        # result - indistinguishable from "this engine legitimately had
        # nothing to do here" - so Complete-MergedFullPipelineChapter would
        # zip and DELETE the folder, discarding whatever the crashed engine
        # hadn't finished, and report the run as clean. Cancelling here stops
        # the surviving engine from wandering further into the same
        # uncertain state; the leftover loop below is what actually stops
        # the zip+delete for chapters already caught in it.
        # $totals.Aborted set directly here, not via a local
        # $anyEngineCrashed flag checked after the call (2026-09-16 fix,
        # real bug) - the old version wrote `$script:anyEngineCrashed =
        # $true` inside this .GetNewClosure()'d handler while the check
        # below read the local, unprefixed `$anyEngineCrashed` - two
        # different variables in two different scopes, so the local one
        # never updated and `if ($anyEngineCrashed)` was always $false.
        # Confirmed live in isolation. $totals is a hashtable already in
        # this closure's lexical scope, and mutating a captured
        # reference's own properties works fine through .GetNewClosure()
        # (unlike a `$script:`-prefixed write, or rebinding a scalar) -
        # the exact pattern $finalizeChapterEntry above already uses for
        # the same $totals object.
        $jobCrashedHandler = {
            param($errorRecord)
            $totals.Aborted = $true
            Write-Log ("Full Pipeline: an engine's runspace threw an unhandled exception and stopped - " + $errorRecord + ". The other engine will finish its own remaining work, then the run will abort; any chapter left incomplete because of this will NOT be zipped or have its folder touched.") -Level Error -ForceConsole
            try { $fullCts.Cancel() } catch { }
        }.GetNewClosure()

        $engineWorkerSharedFunctionNames = @(Get-LoggingSharedFunctionNames) + @(Get-FileDeletionSharedFunctionNames) +
            @(Get-ImageConversionSharedFunctionNames) + @(Get-AnimatedConversionSharedFunctionNames) +
            @(Get-LeafDirectoryDiscoverySharedFunctionNames) + @(Get-ChapterDispatchSharedFunctionNames) +
            @('Get-OrCreateFullPipelineSeriesBundle', 'Get-OrCreateFullPipelineChapterClassification', 'Get-OrCreateFullPipelineCacheEntry', 'Add-FullPipelineZipBlockReason', 'Complete-ImageDispatchJob', 'Complete-AnimatedDispatchJob',
              'Test-AbortSignal', 'Get-LooseImageCandidates', 'Remove-StaleLooseSources', 'Get-LooseAnimatedCandidates',
              'Get-LooseImageExtensions', 'Test-OrphanedScratchFileName')

        $null = Invoke-ZipParallelProcessing -WorkerScript $EngineWorkerScript -JobParams $jobParamsWorker `
            -SharedFunctionNames $engineWorkerSharedFunctionNames -MaxParallel $engineTypes.Count -Cts $fullCts -ResultHandler $engineResultHandler `
            -AbortWaitMessage "[ABORT] Waiting for current image/animated jobs to finish (up to 60s)..." -PollCallback $pollCallback `
            -JobCrashedHandler $jobCrashedHandler

        foreach ($leftoverKey in @($mergeState.Keys)) {
            $leftoverEntry = $mergeState[$leftoverKey]
            # A chapter can only be a genuine "both engines reported nothing
            # more to say, but never actually paired up" leftover if at
            # least one engine's Got<Engine> flag is still false - every
            # chapter BOTH engines actually finished reporting on already
            # got removed from $mergeState and finalized live, above, in the
            # 'EngineChapterDone' handler. A still-false flag here means
            # that engine never told us anything about this chapter at all -
            # either it crashed before reaching it, or the run was aborted
            # before its own dispatch got that far. Distinct from a
            # legitimate $null ImageResult/AnimatedResult (an engine that DID
            # report but had zero files for this chapter) - that case
            # already has its Got<Engine> flag correctly set true. Do NOT
            # zip/delete a chapter we have incomplete information about -
            # 2026-09-15 fix, the most severe finding in the full review
            # series (a crashed engine's leftover chapters were previously
            # zipped and deleted anyway, reported as a clean run).
            if (-not ($leftoverEntry.GotImage -and $leftoverEntry.GotAnimated)) {
                $totals.Aborted = $true
                # Warn only for a chapter that was actually started - see Docs/function-notes.md (Invoke-FullPipeline, "CCR announcement pacing").
                if ($announcedChapters.ContainsKey($leftoverKey)) {
                    Write-Log ("Full Pipeline: '" + $leftoverEntry.Dir.FullName + "' was left incomplete (an engine never finished reporting on it, likely due to the run stopping mid-way) - NOT zipped, NOT deleted, left exactly as-is for a future run to pick back up.") -Level Warn -ForceConsole
                }
                # Credit whichever engine's result DID arrive before
                # skipping zip/delete (2026-09-16 fix, real bug found by a
                # Gemini review). $finalizeChapterEntry above is the ONLY
                # place in this function that adds to these totals - since
                # every entry that reaches this branch skips it entirely
                # (by construction: $mergeState.Remove only ever runs once
                # BOTH engines have reported, so a leftover entry can never
                # have both flags true), real completed conversions and
                # deletions from whichever engine DID finish this chapter
                # before the crash/abort were silently dropped from the
                # run's own summary - the exact undercount bug this same
                # 2026-09-15 fix was supposed to have closed everywhere,
                # reintroduced one level up in this same function the same
                # day.
                $totals.ChapterCount++
                if ($null -ne $leftoverEntry.ImageResult) {
                    $ir = $leftoverEntry.ImageResult
                    $totals.ConvertedImageSuccess += $ir.ConvertedCount
                    $totals.ConvertedImageFail    += $ir.FailedCount
                    $totals.ConvertedImageSkipped += $ir.SkippedCount
                    $totals.DeletedImageSuccess   += $ir.DeletedCount
                    $totals.DeletedImageFail      += $ir.DeleteFailedCount
                    $totals.InspectFailedCount    += $ir.InspectFailedCount
                }
                if ($null -ne $leftoverEntry.AnimatedResult) {
                    $ar = $leftoverEntry.AnimatedResult
                    $totals.ConvertedAnimatedSuccess += $ar.ConvertedCount
                    $totals.ConvertedAnimatedFail    += $ar.FailedCount
                    $totals.ConvertedAnimatedSkipped += $ar.SkippedCount
                    $totals.DeletedAnimatedSuccess   += $ar.DeletedCount
                    $totals.DeletedAnimatedFail      += $ar.DeleteFailedCount
                    $totals.InspectFailedCount       += $ar.InspectFailedCount
                }
                # Complete only an announced chapter (else Complete-ChapterProgress throws) - see Docs/function-notes.md (Invoke-FullPipeline, "CCR announcement pacing").
                if ($cleanConsoleOutputEnabled -and $announcedChapters.ContainsKey($leftoverKey)) {
                    $null = Complete-ChapterProgress -SeriesName $leftoverEntry.SeriesName -ChapterName $leftoverEntry.ChapterName -Status 'Warning' -Detail "left incomplete - run stopped before both engines finished"
                }
                continue
            }
            & $finalizeChapterEntry $leftoverKey $leftoverEntry
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
        [scriptblock]$ImageConversionHandler = ${function:Invoke-LooseImageConversionPipeline},
        [scriptblock]$AnimatedConversionHandler = ${function:Invoke-LooseAnimatedConversionPipeline},
        [scriptblock]$ZipFoldersHandler = ${function:Invoke-ZipOnlyPipeline},
        [scriptblock]$FullPipelineHandler = ${function:Invoke-FullPipeline},
        [scriptblock]$LogHandler = { param($m) Write-Log $m -Level Error }
    )

    # Every mode deletes something except animated conversion with source deletion off.
    if (-not ($Resolved.Mode -eq 'AnimatedConversion' -and -not [bool]$Settings.AnimatedDeleteSource)) {
        $refusal = Get-RecycleBinRefusalMessage -TargetPath $TargetPath -PermanentDelete ([bool]$Settings.PermanentDelete)
        if ($refusal) {
            Write-Log $refusal -Level Error -ForceConsole
            return $null
        }
    }

    try {
        if ($Resolved.Mode -in @('AnimatedConversion', 'FullPipeline') -and [string]::IsNullOrWhiteSpace($MagickExe)) {
            throw ("Mode '" + $Resolved.Mode + "' requires magick.exe, which was not found or configured.")
        }

        $maxProcs = [Math]::Max([int]$Settings.FullPipelineMaxConcurrentProcs, [Math]::Max([int]$Settings.MaxCjxlProcs, [int]$Settings.AnimatedThreads))
        $null = Initialize-ChildProcessReadThreadPool -MaxConcurrentProcesses $maxProcs

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
                    -PermanentDelete ([bool]$Settings.PermanentDelete)
                $stats.ZipOnlyZipped.Success        = $r.ZippedSuccess;        $stats.ZipOnlyZipped.Fail        = $r.ZippedFail
                $stats.ZipOnlyFolderDeleted.Success = $r.FolderDeletedSuccess; $stats.ZipOnlyFolderDeleted.Fail = $r.FolderDeletedFail
                $stats.Aborted           = $r.Aborted
                $stats.ForceKilledCount  = $r.ForceStoppedCount
            }
            'FullPipeline' {
                $r = & $FullPipelineHandler -Path $TargetPath -CjxlExe $CjxlExe -MagickExe $MagickExe `
                    -JpegLossless ([bool]$Settings.JpegLossless) -JpegQuality $Settings.JpegQuality -AnimatedLossless ([bool]$Settings.AnimatedLossless) -AnimatedQuality $Settings.AnimatedQuality `
                    -AnimatedOverwrite ([bool]$Settings.AnimatedOverwrite) -AnimatedDeleteSource ([bool]$Settings.AnimatedDeleteSource) -FullPipelineMaxConcurrentProcs $Settings.FullPipelineMaxConcurrentProcs `
                    -FullLogging $script:FullLogging -PermanentDelete ([bool]$Settings.PermanentDelete) `
                    -RunCoverDeletionBeforeConversion ([bool]$Settings.RunCoverDeletionBeforeConversion) -CoverDeletionDryRun $(if ($Settings.ContainsKey('CoverDeletionDryRun')) { [bool]$Settings.CoverDeletionDryRun } else { $true }) `
                    -AnimatedConversionEnabled $(if ($Settings.ContainsKey('FullPipelineAnimatedConversion')) { [bool]$Settings.FullPipelineAnimatedConversion } else { $true })
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
        [scriptblock]$InitializeLogMutexHandler = ${function:Initialize-LogMutex},
        [scriptblock]$GetLogMutexHandler = ${function:Get-LogMutex},
        [scriptblock]$CompleteAbortDrainHandler = ${function:Complete-AbortDrain}
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
        # Read via $GetLogMutexHandler, NOT a direct $script:logMutex read -
        # this scriptblock is .GetNewClosure()'d (needed so $TargetPath/
        # $Settings/etc. resolve correctly once passed into Show-ModeMenu),
        # and a $script:-prefixed read inside a .GetNewClosure()'d block
        # doesn't see the real script-scope value (confirmed live - resolves
        # to $null, not the current mutex - Docs/lessons-learned.md's 9th
        # entry). Without this indirection, $previousLogMutexForDispose was
        # always $null and the old mutex was never disposed, leaking a
        # handle on every Full-Logging-toggle-then-Cover-Deletion cycle
        # (2026-09-14 code-review finding).
        $previousLogMutexForDispose = & $GetLogMutexHandler
        & $InitializeLogMutexHandler
        # A failed Dispose() on the OLD mutex is harmless - a fresh one was
        # just created above, and .NET will finalize the old handle eventually.
        if ($null -ne $previousLogMutexForDispose) { try { $previousLogMutexForDispose.Dispose() } catch { } }
    }.GetNewClosure()

    while ($true) {
        & $ResetAbortHandler

        $resolved = $null
        try {
            $resolved = & $GetModeHandler -Settings $Settings -SettingsPath $SettingsPath -ReinitLogPathsHandler $reinitLogPathsHandler -TargetPath $TargetPath
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
            & $reinitLogPathsHandler
            $lastFullLogging        = $currentFullLogging
            $lastDisableSummaryFile = $currentDisableSummaryFile
        }
        Initialize-CleanConsoleOutput -Enabled ([bool]$Settings.CleanConsoleOutputEnabled)
        Initialize-FileDeletion -PermanentDelete ([bool]$Settings.PermanentDelete)

        & $StartLogRunHandler
        & $SetRunActiveHandler -Active $true
        # $null = : -SetQuickEditHandler's default (Set-ConsoleQuickEditEnabled)
        # returns [ConsoleQuickEdit]::SetEnabled's own bool (the PREVIOUS
        # enabled state) - uncaptured, & prints it straight to the console
        # (confirmed live: "True" at the start of a run, "False" right after
        # it finishes - 2026-09-14).
        $null = & $SetQuickEditHandler -Enabled $false
        $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $stats = & $InvokeModeHandler -Resolved $resolved -TargetPath $TargetPath -Settings $Settings -CjxlExe $CjxlExe -MagickExe $MagickExe
        } finally {
            $null = & $SetQuickEditHandler -Enabled $true
            & $SetRunActiveHandler -Active $false
            # 2026-09-15 fix, real bug: Complete-AbortDrain (the only thing
            # that sets [ConsoleCtrl]::DrainComplete, unblocking the native
            # Ctrl+C handler thread) previously had only two callers -
            # Invoke-AbortOrFatalHandler (needs a real exception) and
            # Invoke-GracefulDrain (reached only via
            # Invoke-ZipParallelProcessing - modes 1/4 only). Modes 2/3/8
            # return normally with Aborted=$true and nothing ever set
            # DrainComplete, so a window-close abort in those modes hung
            # the OS handler thread for the full 65s wait every time.
            # Invoke-MainLoop is the one place that brackets every mode -
            # calling it here unconditionally (idempotent, safe even on a
            # non-aborted run) closes the gap for all of them at once.
            & $CompleteAbortDrainHandler
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
