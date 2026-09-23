# See Docs/module-descriptions.md for this module's full description.

# ==============================================================================
#  PART 1 - shared helpers used by PART 2's live conversion engine
# ==============================================================================

function Test-AvifAnimated {
    param(
        [Parameter(Mandatory)]
        [string]$AvifPath,
        [Parameter(Mandatory)]
        [string]$MagickExe
    )

    # 2026-09-16: a literal % in an INPUT path does NOT need escaping -
    # confirmed live (reading works fine either way; a real % is only
    # misread by ImageMagick when WRITING multiple images/frames to one
    # output path - see Complete-AnimatedDispatchJob's own jobStarter for
    # where the real fix belongs). An earlier version of this fix
    # mistakenly escaped this read path too, which broke it outright
    # (magick looking for a literal %% that doesn't exist on disk,
    # live-reported the same day).
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $MagickExe
    $psi.Arguments              = "identify -ping -format `"%T\n`" `"" + $AvifPath + "[0]`""
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    # DOCUMENTED DUPLICATE: Invoke-IccStripRetryOrFail in
    # ImageConversionPipeline.ps1 uses the identical raw-handle-wait
    # pattern below - keep both in sync.
    $proc = [System.Diagnostics.Process]::Start($psi)
    $null = [ChildProcessJob]::Assign($proc)  # see AbortPipeline.ps1's ChildProcessJob
    try {
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $procWaitHandle = [System.Threading.ManualResetEvent]::new($false)
        $origSafeHandle = $procWaitHandle.SafeWaitHandle
        $procWaitHandle.SafeWaitHandle = (
            [Microsoft.Win32.SafeHandles.SafeWaitHandle]::new(
                $proc.Handle, $false
            )
        )
        try {
            $exited = $procWaitHandle.WaitOne(30000)
        } finally {
            $procWaitHandle.SafeWaitHandle = $origSafeHandle
            $procWaitHandle.Dispose()
        }

        if (-not $exited) {
            try { $proc.Kill() } catch { }
            [System.Threading.Thread]::Sleep(200)
            throw "magick identify did not exit within 30s - killed"
        }

        # DOCUMENTED DUPLICATE: Invoke-IccStripRetryOrFail in
        # ImageConversionPipeline.ps1 uses the identical bounded-stream-read
        # pattern below - keep both in sync.
        # 15s, not 5s (2026-09-16 band-aid). The real cause of the "pretty
        # frequent" timeouts turned out to be thread-pool starvation, not a
        # CPU-starved process (2026-09-22, see ChapterDispatch.ps1's
        # Initialize-ChildProcessReadThreadPool) - 15s kept as margin.
        # DOCUMENTED DUPLICATE: keep in sync
        # with ImageConversionPipeline.ps1's Invoke-IccStripRetryOrFail and
        # its own pre-conversion detour, and Controller.ps1's matching
        # pre-conversion detour - all four bumped together.
        if (-not [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 15000)) {
            # 2026-09-16 fix: the process handle above only proves the
            # PROCESS exited, not that its redirected stdout/stderr pipes
            # reached EOF - an inherited handle in the process tree (a
            # delegate ImageMagick can spawn) could keep a pipe open after
            # the process itself is gone, and an un-timed GetResult() below
            # would then wait forever. Bounded the same way the process-exit
            # wait above already is.
            throw "magick identify exited but its output streams did not finish reading within 15s."
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $code = $proc.ExitCode
    } finally {
        $proc.Dispose()
    }

    if ($code -ne 0) {
        throw ("magick identify exited " + $code + ". Stderr: " + $stderr.Trim())
    }

    $firstLine = $null
    foreach ($line in $stdout.Split([char[]]@("`r", "`n"), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $firstLine = $line
        break
    }
    $delay = 0
    if ($null -eq $firstLine -or -not [int]::TryParse($firstLine.Trim(), [ref]$delay)) {
        throw ("magick identify returned a non-numeric delay value: '" + $stdout.Trim() + "'")
    }

    return ($delay -gt 0)
}

# ==============================================================================
#  PART 2 - mode 3 orchestration
# ==============================================================================

function Get-LooseAnimatedCandidates {
    param(
        [Parameter(Mandatory)]
        [string]$ScanPath,
        [string[]]$AnimatedFileExtensions = @(".avif"),
        [string[]]$KnownZipPaths = @(),
        [System.Collections.Generic.HashSet[string]]$ExcludeStagingDirs = $null
    )

    $zipBaseDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($zp in $KnownZipPaths) {
        $null = $zipBaseDirs.Add([System.IO.Path]::Combine(
            [System.IO.Path]::GetDirectoryName($zp),
            [System.IO.Path]::GetFileNameWithoutExtension($zp)
        ))
    }
    if ($ExcludeStagingDirs) {
        foreach ($stagingDir in $ExcludeStagingDirs) { $null = $zipBaseDirs.Add($stagingDir) }
    }

    $candidates = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($file in (Get-FilesRecursiveSafe -ScanPath $ScanPath)) {
        if ($AnimatedFileExtensions -inotcontains $file.Extension) { continue }
        $fileDir = $file.DirectoryName
        $isStaged = $false
        foreach ($stagingDir in $zipBaseDirs) {
            if ($fileDir.Equals($stagingDir, [System.StringComparison]::OrdinalIgnoreCase) -or
                $fileDir.StartsWith($stagingDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isStaged = $true
                break
            }
        }
        if ($isStaged) { continue }
        $candidates.Add($file)
    }

    return ,$candidates
}

function Get-ChapterAnimatedStatus {
    param(
        [hashtable]$ChapterResult
    )
    if ($null -eq $ChapterResult) { return "Success", $null }

    # DOCUMENTED DUPLICATE of ImageConversionPipeline.ps1's
    # Get-ChapterProgressStatus (same four fields, same severity
    # ordering) - keep both in sync.
    if ($ChapterResult.FailedCount -gt 0 -or $ChapterResult.ForceKilledCount -gt 0 -or $ChapterResult.DeleteFailedCount -gt 0 -or $ChapterResult.InspectFailedCount -gt 0) {
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($ChapterResult.FailedCount -gt 0)        { $parts.Add($ChapterResult.FailedCount.ToString() + " failed") }
        if ($ChapterResult.ForceKilledCount -gt 0)   { $parts.Add($ChapterResult.ForceKilledCount.ToString() + " force-stopped") }
        if ($ChapterResult.DeleteFailedCount -gt 0)  { $parts.Add($ChapterResult.DeleteFailedCount.ToString() + " source delete(s) failed") }
        if ($ChapterResult.InspectFailedCount -gt 0) { $parts.Add($ChapterResult.InspectFailedCount.ToString() + " inspect failure(s)") }
        return "Error", ($parts -join ", ")
    }
    if ($ChapterResult.SkippedCount -gt 0) {
        return "Warning", ($ChapterResult.SkippedCount.ToString() + " skipped (output already exists)")
    }
    return "Success", $null
}

function Complete-AnimatedDispatchJob {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Job,
        [Parameter(Mandatory)]
        [hashtable]$ChapterResult,
        [bool]$DoFullLogging,
        [bool]$DoAnimatedDeleteSource
    )

    $stdout = if ($Job.StdoutTask) { $Job.StdoutTask.GetAwaiter().GetResult() } else { $Job.Proc.StandardOutput.ReadToEnd() }
    $stderr = if ($Job.StderrTask) { $Job.StderrTask.GetAwaiter().GetResult() } else { $Job.Proc.StandardError.ReadToEnd() }
    $code   = $Job.Proc.ExitCode

    if ($DoFullLogging -and -not [string]::IsNullOrWhiteSpace($stdout)) {
        Write-Log ("magick stdout for '" + $Job.SrcPath + "': " + $stdout.Trim())
    }

    $convOk = $false
    $webpReplaceBackup = $null
    try {
        if ($code -ne 0) { throw ("magick exited with code " + $code + ". Stderr: " + $stderr) }
        # Exit code and stderr included even on these two throws
        # (2026-09-16 fix, real gap found live) - magick can exit 0
        # (clean success) while still failing to produce real output
        # (observed live: a -quality 100 WebP encode that ran for minutes
        # then left no output file, exit code 0, cause unconfirmed) -
        # without this, the log gave no way to tell what magick actually
        # said on its way out.
        if (-not [System.IO.File]::Exists($Job.MagickOutputPath)) { throw ("Output .webp was not created (magick exited " + $code + "): '" + $Job.MagickOutputPath + "'. Stderr: " + $stderr) }
        $webpSize = [System.IO.FileInfo]::new($Job.MagickOutputPath).Length
        if ($webpSize -eq 0) { throw ("Output .webp is 0 bytes (magick exited " + $code + "): '" + $Job.MagickOutputPath + "'. Stderr: " + $stderr) }
        if ($Job.MagickOutputPath -ne $Job.WebpPath) {
            $webpReplaceBackup = $Job.WebpPath + "_replace_backup.tmp"
            [System.IO.File]::Replace($Job.MagickOutputPath, $Job.WebpPath, $webpReplaceBackup)
            try { [System.IO.File]::Delete($webpReplaceBackup) } catch { }
        }
        Write-Log ("Conversion OK: '" + $Job.WebpPath + "' (" + $webpSize + " bytes)")
        $ChapterResult.ConvertedCount++
        $convOk = $true
    } catch {
        Write-Log ("FAILED conversion of animated AVIF '" + $Job.SrcPath + "': " + $_) -Level Error
        $ChapterResult.FailedCount++
        try { [System.IO.File]::Delete($Job.MagickOutputPath) } catch { }
        if ($webpReplaceBackup) { try { [System.IO.File]::Delete($webpReplaceBackup) } catch { } }
    }

    if ($convOk -and $DoAnimatedDeleteSource) {
        try {
            $removed = Remove-Source -ItemPath $Job.SrcPath
            if ($removed) {
                $deleteDesc = if (Get-WorkerRunspaceValue -Name PermanentDelete) { "permanently" } else { "Recycle Bin" }
                Write-Log ("Deleted source (" + $deleteDesc + "): '" + $Job.SrcPath + "'")
                $ChapterResult.DeletedCount++
            } else {
                Write-Log ("Source already gone before deletion (not counted as deleted): '" + $Job.SrcPath + "'") -Level Warn
            }
        } catch {
            Write-Log ("FAILED to delete source '" + $Job.SrcPath + "': " + $_) -Level Error
            $ChapterResult.DeleteFailedCount++
        }
    }

    return @{ Success = $convOk }
}

function Invoke-LooseAnimatedConversionPipeline {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$MagickExe,
        [bool]$AnimatedLossless = $false,
        [int]$AnimatedQuality = 90,
        [Parameter(Mandatory)]
        [int]$AnimatedThreads,
        [bool]$AnimatedOverwrite = $false,
        [bool]$AnimatedDeleteSource = $true,
        [Parameter(Mandatory)]
        [bool]$FullLogging,
        [string[]]$AnimatedFileExtensions = @(".avif"),
        [string[]]$KnownZipPaths = @(),
        [string[]]$FolderQualifyingExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif", ".gif", ".bmp", ".heic", ".heif"),
        [System.Collections.Generic.HashSet[string]]$FolderExcludeStagingDirs = $null,
        [scriptblock]$PostChapterCallback = $null,
        [int]$AbortTimeoutSeconds = 60,
        [int]$HeartbeatIntervalSeconds = 30,
        [int]$MaxQueueAhead = 3
    )

    $totals = @{
        ConvertedSuccess       = 0
        ConvertedFail          = 0
        ConvertedSkipped       = 0
        StaticSkippedCount     = 0
        InspectFailedCount     = 0
        DeletedSuccess         = 0
        DeletedFail            = 0
        ForceKilledCount       = 0
        LastCompletedPaths     = [System.Collections.Generic.List[string]]::new()
        LastSkippedPaths       = [System.Collections.Generic.List[string]]::new()
        LastStaticSkippedPaths = [System.Collections.Generic.List[string]]::new()
        StillPendingPaths      = [System.Collections.Generic.List[string]]::new()
        SeriesCount            = 0
        ChapterCount           = 0
        Aborted                = $false
    }

    $chapterResults = [System.Collections.Generic.Dictionary[object,hashtable]]::new()

    $cleanConsoleOutputEnabled = [bool]$script:CleanConsoleOutputEnabled

    try {
        $animatedCts = [System.Threading.CancellationTokenSource]::new()
        Register-AbortCancellationSource -Cts $animatedCts

        $seriesProvider  = New-SeriesProvider -LibraryPath $Path
        $chapterQueue    = [System.Collections.Generic.Queue[hashtable]]::new()
        # Hashtable, not a plain scalar (2026-09-14 code-review finding - a
        # second, unfixed instance of the same closure-latch bug this
        # session's audit already fixed in 5 other places; see
        # ChapterDispatch.ps1's New-LibraryChapterProvider for the full
        # explanation of why a plain scalar doesn't latch here).
        $chapterProviderState = @{ SeriesExhausted = $false }
        $chapterProvider = {
            while ($chapterQueue.Count -eq 0 -and -not $chapterProviderState.SeriesExhausted) {
                $series = & $seriesProvider
                if ($null -eq $series) { $chapterProviderState.SeriesExhausted = $true; break }
                $totals.SeriesCount++

                $chapters = Get-SeriesChapters -SeriesPath $series.FullName -QualifyingExtensions $FolderQualifyingExtensions `
                    -ExcludeStagingDirs $FolderExcludeStagingDirs -ForceRezip $false

                $seriesFiles = Get-LooseAnimatedCandidates -ScanPath $series.FullName -AnimatedFileExtensions $AnimatedFileExtensions `
                    -KnownZipPaths $KnownZipPaths -ExcludeStagingDirs $FolderExcludeStagingDirs

                $filesByDir = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[System.IO.FileInfo]]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($f in $seriesFiles) {
                    if (-not $filesByDir.ContainsKey($f.DirectoryName)) {
                        $filesByDir[$f.DirectoryName] = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
                    }
                    $filesByDir[$f.DirectoryName].Add($f)
                }

                $chapterDirSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                $chapterDirs = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
                foreach ($c in $chapters) {
                    $null = $chapterDirSet.Add($c.Dir.FullName)
                    $chapterDirs.Add($c.Dir)
                }
                foreach ($extraDirPath in $filesByDir.Keys) {
                    if ($chapterDirSet.Contains($extraDirPath)) { continue }
                    $extraDir = $filesByDir[$extraDirPath][0].Directory
                    $chapterDirs.Add($extraDir)
                    Write-Log ("Series '" + $series.Name + "': '" + $extraDir.Name + "' has unconverted animated file(s) but wasn't found by chapter discovery (e.g. a stray .zip sitting alongside it, or files outside a normal chapter folder) - converting it anyway.") -Level Warn
                }

                if ($chapterDirs.Count -eq 0) {
                    Write-Log ("Series '" + $series.Name + "': no qualifying chapters found.") -Level Info
                    continue
                }

                if ($cleanConsoleOutputEnabled) {
                    Start-SeriesProgress -SeriesName $series.Name -TotalChapters $chapterDirs.Count
                }
                Write-Log ("=== Series '" + $series.Name + "': " + $chapterDirs.Count + " chapter(s) ===")

                foreach ($chapterDir in $chapterDirs) {
                    $chapterFiles = @()
                    if ($filesByDir.ContainsKey($chapterDir.FullName)) { $chapterFiles = @($filesByDir[$chapterDir.FullName]) }
                    $chapterQueue.Enqueue(@{ SeriesName = $series.Name; ChapterName = $chapterDir.Name; Dir = $chapterDir; AnimatedFiles = $chapterFiles })
                }
            }
            if ($chapterQueue.Count -gt 0) { return $chapterQueue.Dequeue() }
            return $null
        }.GetNewClosure()

        $jobBuilder = {
            param($chapterInfo)

            $totals.ChapterCount++
            $cr = @{
                ConvertedCount = 0; FailedCount = 0; SkippedCount = 0; StaticSkippedCount = 0
                InspectFailedCount = 0; DeletedCount = 0; DeleteFailedCount = 0; ForceKilledCount = 0
                SkippedPaths = [System.Collections.Generic.List[string]]::new()
                StaticSkippedPaths = [System.Collections.Generic.List[string]]::new()
                TotalFiles = $chapterInfo.AnimatedFiles.Count
            }
            $chapterResults[$chapterInfo] = $cr

            if ($cleanConsoleOutputEnabled) {
                Start-ChapterProgress -SeriesName $chapterInfo.SeriesName -ChapterName $chapterInfo.ChapterName
            }

            if ($cr.TotalFiles -eq 0) {
                Write-Log ("Chapter '" + $chapterInfo.Dir.FullName + "': no unconverted animated files - skipping conversion.")
                return @()
            }
            Write-Log ("Processing chapter: '" + $chapterInfo.Dir.FullName + "' (" + $cr.TotalFiles + " animated file(s))")

            $jobs = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($f in $chapterInfo.AnimatedFiles) {
                $srcPath  = $f.FullName
                $webpPath = [System.IO.Path]::ChangeExtension($srcPath, ".webp")

                # A 0-byte webp is a leftover from a force-killed/interrupted
                # run, not a real conversion - treating it as "already
                # converted" would skip the source AVIF forever with no way
                # to tell it apart from a genuine success.
                $webpPathExists = [System.IO.File]::Exists($webpPath) -and ([System.IO.FileInfo]::new($webpPath).Length -gt 0)
                if ($webpPathExists -and -not $AnimatedOverwrite) {
                    Write-Log ("SKIPPING '" + $srcPath + "': output '" + $webpPath + "' already exists (Overwrite is off).")
                    $cr.SkippedCount++
                    $cr.SkippedPaths.Add($srcPath)
                    continue
                }

                # DOCUMENTED DUPLICATE: the same Test-AbortSignal check before each
                # per-file Test-AvifAnimated spawn also lives in
                # ImageConversionPipeline.ps1's jobBuilder and Controller.ps1's
                # Get-OrCreateFullPipelineChapterClassification - keep all three in sync.
                if (-not (Test-AbortSignal)) {
                    try {
                        $isAnimated = Test-AvifAnimated -AvifPath $srcPath -MagickExe $MagickExe
                    } catch {
                        Write-Log ("Could not determine if '" + $srcPath + "' is animated - skipping: " + $_) -Level Warn
                        $cr.InspectFailedCount++
                        continue
                    }
                    if (-not $isAnimated) {
                        Write-Log ("'" + $srcPath + "' is a static AVIF (not animated) - left unconverted.")
                        $cr.StaticSkippedCount++
                        $cr.StaticSkippedPaths.Add($srcPath)
                        continue
                    }
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
                    Proc = $null; StartTime = $null; LastHeartbeat = $null
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
                $qualityArg = if ($AnimatedLossless) { "-define webp:lossless=true" } else { "-quality " + $AnimatedQuality }
                # %% on the OUTPUT path only (2026-09-16 fix, real bug,
                # live-reported and confirmed by the project owner testing
                # with/without a "100%" folder name, then confirmed again
                # live here: a literal % anywhere in the path of a
                # MULTI-FRAME output write - exactly this call's own
                # -coalesce/animated-webp write - gets read by ImageMagick
                # as its own percent-escape syntax, and when it can't
                # resolve the destination as one literal filename, it
                # falls back to its own per-scene auto-numbered output
                # instead (observed live: a real, correctly-sized file
                # with "-0" appended, not the expected clean path).
                # Doubling it is ImageMagick's own documented escape for a
                # literal %. The SOURCE path does NOT need this - reading
                # an existing file with a literal % works fine unescaped;
                # an earlier version of this fix mistakenly escaped the
                # source too, which broke it outright (magick looking for
                # a literal %% that doesn't exist on disk, live-reported
                # the same day).
                $escapedOutPath = $job.MagickOutputPath.Replace('%', '%%')
                $psi.Arguments = "`"" + $job.SrcPath + "`" -coalesce -loop 0 " + $qualityArg + " `"" + $escapedOutPath + "`""
                $psi.UseShellExecute        = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $psi.CreateNoWindow         = $true

                Write-Log ("Converting animated: '" + $job.SrcPath + "'")

                $job.Proc          = [System.Diagnostics.Process]::Start($psi)
                $null = [ChildProcessJob]::Assign($job.Proc)  # see AbortPipeline.ps1's ChildProcessJob
                $job.StdoutTask    = $job.Proc.StandardOutput.ReadToEndAsync()
                $job.StderrTask    = $job.Proc.StandardError.ReadToEndAsync()
                $job.StartTime     = [System.Diagnostics.Stopwatch]::StartNew()
                $job.LastHeartbeat = [timespan]::Zero
                return $job
            } catch {
                # Bare Process.Start() throws a NON-terminating error when
                # uncaught (Docs/lessons-learned.md's 7th entry) - without
                # this try/catch, $job.Proc stays $null and jobPollCompleted's
                # $job.Proc.HasExited is falsy forever, hanging the whole
                # dispatch loop. Rethrow so ChapterDispatch's own JobStarter
                # catch accounts for it and moves on. DOCUMENTED DUPLICATE:
                # Controller.ps1's animated-engine jobStarter has the same
                # try/catch around the same call - keep both in sync.
                Write-Log ("FAILED to start animated conversion process for '" + $job.SrcPath + "': " + $_) -Level Error
                $cr.FailedCount++
                throw
            }
        }.GetNewClosure()

        $jobPollCompleted = {
            param($job)
            if ($job.Proc.HasExited) { return $true }
            if ($HeartbeatIntervalSeconds -gt 0 -and
                ($job.StartTime.Elapsed - $job.LastHeartbeat).TotalSeconds -ge $HeartbeatIntervalSeconds) {
                $cr = $chapterResults[$job.ChapterKey]
                $doneSoFar = $cr.ConvertedCount + $cr.FailedCount + $cr.SkippedCount + $cr.StaticSkippedCount + $cr.InspectFailedCount
                Write-Log ("Still converting '" + $job.SrcPath + "' (" + [int]$job.StartTime.Elapsed.TotalSeconds + "s elapsed) - batch progress: " + $doneSoFar + "/" + $cr.TotalFiles + " done.")
                $job.LastHeartbeat = $job.StartTime.Elapsed
            }
            return $false
        }.GetNewClosure()

        $jobFinalize = {
            param($job, $pendingQueue)
            $cr = $chapterResults[$job.ChapterKey]
            return Complete-AnimatedDispatchJob -Job $job -ChapterResult $cr -DoFullLogging $FullLogging -DoAnimatedDeleteSource $AnimatedDeleteSource
        }.GetNewClosure()

        $jobAbortCleanup = {
            param($job)
            if ($job.TempOverwritePath) { try { [System.IO.File]::Delete($job.TempOverwritePath) } catch { } }
            try { [System.IO.File]::Delete($job.MagickOutputPath) } catch { }
            # DOCUMENTED DUPLICATE of ImageConversionPipeline.ps1's own
            # jobAbortCleanup ForceKilledCount increment - keep both in
            # sync. Feeds Get-ChapterAnimatedStatus so a force-killed/
            # never-started chapter reports as "N force-stopped" instead
            # of a false clean Success once ChapterDispatch.ps1 invokes
            # $ChapterCompleteCallback for it (2026-09-15 fix).
            $cr = $chapterResults[$job.ChapterKey]
            if ($null -ne $cr) { $cr.ForceKilledCount++ }
        }.GetNewClosure()

        $chapterCompleteCallback = {
            param($chapterInfo)
            $cr = $chapterResults[$chapterInfo]
            $chapterResultForCallback = if ($cr.TotalFiles -eq 0) { $null } else { $cr }

            $totals.ConvertedSuccess   += $cr.ConvertedCount
            $totals.ConvertedFail      += $cr.FailedCount
            $totals.ConvertedSkipped   += $cr.SkippedCount
            $totals.StaticSkippedCount += $cr.StaticSkippedCount
            $totals.InspectFailedCount += $cr.InspectFailedCount
            $totals.DeletedSuccess     += $cr.DeletedCount
            $totals.DeletedFail        += $cr.DeleteFailedCount
            foreach ($p in $cr.SkippedPaths)       { $totals.LastSkippedPaths.Add($p) }
            foreach ($p in $cr.StaticSkippedPaths) { $totals.LastStaticSkippedPaths.Add($p) }

            if ($cleanConsoleOutputEnabled) {
                $chapterStatus, $chapterDetail = Get-ChapterAnimatedStatus -ChapterResult $chapterResultForCallback
                $null = Complete-ChapterProgress -SeriesName $chapterInfo.SeriesName -ChapterName $chapterInfo.ChapterName -Status $chapterStatus -Detail $chapterDetail
            }
            if ($null -ne $PostChapterCallback) {
                & $PostChapterCallback @{ SeriesName = $chapterInfo.SeriesName; ChapterName = $chapterInfo.ChapterName; Dir = $chapterInfo.Dir; ChapterResult = $chapterResultForCallback }
            }
            $null = $chapterResults.Remove($chapterInfo)
        }.GetNewClosure()

        # Hashtable, not a plain scalar (2026-09-14 fix, Todo.md finding) -
        # a plain $abortMessagePrinted assigned inside this
        # .GetNewClosure()'d scriptblock resets to $false on every
        # invocation instead of latching, confirmed live - the once-only
        # guard below never actually held. Currently harmless (the
        # dispatch loop stops polling within an iteration or two of
        # Test-AbortSignal first returning true), but a real bug if this
        # poll callback is ever invoked more times after an abort than it
        # is today. DOCUMENTED DUPLICATE: the identical pattern (same
        # fields, same reasoning) also appears in Controller.ps1's and
        # ImageConversionPipeline.ps1's own abort-poll callbacks - keep all
        # three in sync.
        $abortState = @{ MessagePrinted = $false }
        $abortPollCallback = {
            param($runningJobs)
            $aborted = Test-AbortSignal
            if ($aborted -and -not $abortState.MessagePrinted) {
                $abortState.MessagePrinted = $true
                if ($runningJobs.Count -gt 0) {
                    Write-GatedConsoleMessage -Text ("[ABORT] Waiting for current animated jobs to finish (up to " + $AbortTimeoutSeconds + "s)...") -Color Yellow -CleanConsoleOutputEnabled $cleanConsoleOutputEnabled
                }
            }
        }.GetNewClosure()

        $dispatchResult = Invoke-ChapterDispatch -ChapterProvider $chapterProvider -JobBuilder $jobBuilder `
            -JobStarter $jobStarter -JobPollCompleted $jobPollCompleted -JobFinalize $jobFinalize `
            -JobAbortCleanup $jobAbortCleanup -ChapterCompleteCallback $chapterCompleteCallback `
            -MaxConcurrent $AnimatedThreads -AbortPollCallback $abortPollCallback -CancelToken $animatedCts.Token `
            -AbortTimeoutSeconds $AbortTimeoutSeconds -MaxQueueAhead $MaxQueueAhead

        $totals.ForceKilledCount = $dispatchResult.ForceKilledCount
        $totals.Aborted          = $dispatchResult.Aborted
    } finally {
        if ($animatedCts) {
            Unregister-AbortCancellationSource -Cts $animatedCts
            $animatedCts.Dispose()
        }
        if ($script:CleanConsoleOutputEnabled) {
            $null = Complete-AllActiveSeriesProgress
        }
    }

    return $totals
}

function Get-AnimatedConversionSharedFunctionNames {
    return @('Test-AvifAnimated')
}
