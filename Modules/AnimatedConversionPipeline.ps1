# See Docs/module-descriptions.md for this module's full description.

# ==============================================================================
#  PART 1 - Convert-AnimatedBatch, the per-batch conversion engine
# ==============================================================================

function Test-AvifAnimated {
    param(
        [Parameter(Mandatory)]
        [string]$AvifPath,
        [Parameter(Mandatory)]
        [string]$MagickExe
    )

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

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
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

function Complete-AnimatedConversionJob {
    # DOCUMENTED DUPLICATE: everything below the try/finally is copied,
    # not shared, into PART 2's Complete-AnimatedDispatchJob - see that
    # function's own header for why. Keep both in sync if either changes.
    param(
        [Parameter(Mandatory)]
        [hashtable]$Job,
        [Parameter(Mandatory)]
        [hashtable]$BatchResult,
        [bool]$DoFullLogging,
        [bool]$DoAnimatedDeleteSource,
        [bool]$IsAbortDrain = $false
    )

    try {
        $stdout = if ($Job.StdoutTask) { $Job.StdoutTask.GetAwaiter().GetResult() } else { $Job.Proc.StandardOutput.ReadToEnd() }
        $stderr = if ($Job.StderrTask) { $Job.StderrTask.GetAwaiter().GetResult() } else { $Job.Proc.StandardError.ReadToEnd() }
        $code   = $Job.Proc.ExitCode
    } finally {
        $Job.Proc.Dispose()
        $Job.SlotReleased = $true
    }

    if (-not $IsAbortDrain -and $DoFullLogging -and -not [string]::IsNullOrWhiteSpace($stdout)) {
        Write-Log ("magick stdout for '" + $Job.SrcPath + "': " + $stdout.Trim())
    }

    $convOk = $false
    # DOCUMENTED DUPLICATE (2026-09-14 fix, Todo.md finding): this
    # explicit-$null initialization was missing here while
    # Complete-AnimatedDispatchJob's own copy had it - harmless in
    # practice (an undeclared PowerShell variable just reads as $null),
    # but a real drift in a pair of functions under an explicit
    # keep-in-sync contract. Keep both in sync if this changes again.
    $webpReplaceBackup = $null
    try {
        if ($code -ne 0) { throw ("magick exited with code " + $code + ". Stderr: " + $stderr) }
        $webpItem = [System.IO.FileInfo]::new($Job.MagickOutputPath)
        if (-not $webpItem.Exists) { throw ("Output .webp was not created: '" + $Job.MagickOutputPath + "'") }
        $webpSize = $webpItem.Length
        if ($webpSize -eq 0) { throw ("Output .webp is 0 bytes: '" + $Job.MagickOutputPath + "'") }
        if ($Job.MagickOutputPath -ne $Job.WebpPath) {
            $webpReplaceBackup = $Job.WebpPath + "_replace_backup.tmp"
            [System.IO.File]::Replace($Job.MagickOutputPath, $Job.WebpPath, $webpReplaceBackup)
            try { [System.IO.File]::Delete($webpReplaceBackup) } catch { }
        }
        if ($IsAbortDrain) {
            Write-Log ("Conversion OK (abort drain): '" + $Job.WebpPath + "'")
        } else {
            Write-Log ("Conversion OK: '" + $Job.WebpPath + "' (" + $webpSize + " bytes)")
        }
        $BatchResult.ConvertedCount++
        $BatchResult.ConvertedPaths.Add($Job.SrcPath)
        $convOk = $true
    } catch {
        Write-Log ("FAILED conversion of animated AVIF '" + $Job.SrcPath + "': " + $_) -Level Error
        $BatchResult.FailedCount++
        try { [System.IO.File]::Delete($Job.MagickOutputPath) } catch { }
        if ($webpReplaceBackup) { try { [System.IO.File]::Delete($webpReplaceBackup) } catch { } }
    }

    if ($convOk -and $DoAnimatedDeleteSource) {
        try {
            $removed = Remove-Source -ItemPath $Job.SrcPath
            if ($removed) {
                $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
                Write-Log ("Deleted source (" + $deleteDesc + "): '" + $Job.SrcPath + "'")
                $BatchResult.DeletedCount++
            } else {
                Write-Log ("Source already gone before deletion (not counted as deleted): '" + $Job.SrcPath + "'") -Level Warn
            }
        } catch {
            Write-Log ("FAILED to delete source '" + $Job.SrcPath + "': " + $_) -Level Error
            $BatchResult.DeleteFailedCount++
        }
    }
}

function Convert-AnimatedBatch {
    param(
        [System.IO.FileInfo[]]$AnimatedFiles,
        [Parameter(Mandatory)]
        [string]$MagickExe,
        [bool]$DoAnimatedLossless,
        [int]$AnimatedQuality = 90,
        [Parameter(Mandatory)]
        [int]$AnimatedThreads,
        [bool]$DoAnimatedOverwrite,
        [bool]$DoAnimatedDeleteSource = $true,
        [bool]$DoFullLogging,
        [Parameter(Mandatory)]
        [System.Threading.CancellationToken]$CancelToken,
        [string]$BatchLabel             = $null,
        [string]$AbortWaitMessage       = $null,
        [scriptblock]$AbortPollCallback = $null,
        [int]$AbortTimeoutSeconds       = 60,
        [int]$HeartbeatIntervalSeconds  = 30,
        [System.Collections.Generic.HashSet[string]]$KnownAnimatedPaths = $null
    )

    $batchResult = @{
        ConvertedCount      = 0
        FailedCount         = 0
        SkippedCount        = 0
        StaticSkippedCount  = 0
        InspectFailedCount  = 0
        DeletedCount        = 0
        DeleteFailedCount   = 0
        ConvertedPaths      = [System.Collections.Generic.List[string]]::new()
        SkippedPaths        = [System.Collections.Generic.List[string]]::new()
        StaticSkippedPaths  = [System.Collections.Generic.List[string]]::new()
        PendingPaths        = [System.Collections.Generic.List[string]]::new()
        ForceKilledCount    = 0
    }

    if (-not $AnimatedFiles -or $AnimatedFiles.Count -eq 0) { return $batchResult }

    $totalFiles = $AnimatedFiles.Count

    $pending = [System.Collections.Queue]::new()
    foreach ($f in $AnimatedFiles) {
        $pending.Enqueue(@{
            SrcPath       = $f.FullName
            WebpPath      = [System.IO.Path]::ChangeExtension($f.FullName, ".webp")
            Proc          = $null
            StartTime     = $null
            LastHeartbeat = $null
        })
    }
    $running = [System.Collections.Generic.List[hashtable]]::new()

    try {
    while (($pending.Count -gt 0 -or $running.Count -gt 0) -and (-not $CancelToken.IsCancellationRequested)) {

        if ($AbortPollCallback) {
            $inFlightList = [System.Collections.Generic.List[string]]::new()
            foreach ($r in $running) { $inFlightList.Add($r.SrcPath) }
            $inFlight = @($inFlightList)
            & $AbortPollCallback $inFlight
        }

        while ($pending.Count -gt 0 -and (-not $CancelToken.IsCancellationRequested) -and `
               $running.Count -lt $AnimatedThreads) {
            $j = $pending.Dequeue()
            try {

            $webpPathExists = [System.IO.File]::Exists($j.WebpPath)
            if ($webpPathExists -and -not $DoAnimatedOverwrite) {
                Write-Log ("SKIPPING '" + $j.SrcPath + "': output '" + $j.WebpPath + "' already exists (Overwrite is off).")
                $batchResult.SkippedCount++
                $batchResult.SkippedPaths.Add($j.SrcPath)
                continue
            }

            $isAnimated = $false
            if ($KnownAnimatedPaths -and $KnownAnimatedPaths.Contains($j.SrcPath)) {
                $isAnimated = $true
            } else {
                try {
                    $isAnimated = Test-AvifAnimated -AvifPath $j.SrcPath -MagickExe $MagickExe
                } catch {
                    Write-Log ("Could not determine if '" + $j.SrcPath + "' is animated - skipping: " + $_) -Level Warn
                    $batchResult.InspectFailedCount++
                    continue
                }
            }

            if (-not $isAnimated) {
                Write-Log ("'" + $j.SrcPath + "' is a static AVIF (not animated) - left unconverted.")
                $batchResult.StaticSkippedCount++
                $batchResult.StaticSkippedPaths.Add($j.SrcPath)
                continue
            }

            $j.TempOverwritePath = if ($webpPathExists) {
                [System.IO.Path]::Combine(
                    [System.IO.Path]::GetDirectoryName($j.WebpPath),
                    [System.IO.Path]::GetFileNameWithoutExtension($j.WebpPath) + "_tmp_overwrite.webp"
                )
            } else {
                $null
            }
            $j.MagickOutputPath = if ($j.TempOverwritePath) { $j.TempOverwritePath } else { $j.WebpPath }

            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $MagickExe
            $qualityArg = if ($DoAnimatedLossless) { "-define webp:lossless=true" } else { "-quality " + $AnimatedQuality }
            $psi.Arguments = "`"" + $j.SrcPath + "`" -coalesce -loop 0 " + $qualityArg + " `"" + $j.MagickOutputPath + "`""
            $psi.UseShellExecute        = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow         = $true

            Write-Log ("Converting animated: '" + $j.SrcPath + "'")

            $j.Proc          = [System.Diagnostics.Process]::Start($psi)
            $j.StdoutTask    = $j.Proc.StandardOutput.ReadToEndAsync()
            $j.StderrTask    = $j.Proc.StandardError.ReadToEndAsync()
            $j.StartTime     = [System.Diagnostics.Stopwatch]::StartNew()
            $j.LastHeartbeat = [timespan]::Zero
            $running.Add($j)
            } catch {
                Write-Log ("FAILED to start conversion process for '" + $j.SrcPath + "': " + $_) -Level Error
                $batchResult.FailedCount++
            }
        }

        $stillRunning = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($j in $running) {
            if ($j.Proc.HasExited) {
                Complete-AnimatedConversionJob -Job $j -BatchResult $batchResult -DoFullLogging $DoFullLogging -DoAnimatedDeleteSource $DoAnimatedDeleteSource
            } else {
                if ($HeartbeatIntervalSeconds -gt 0 -and
                    ($j.StartTime.Elapsed - $j.LastHeartbeat).TotalSeconds -ge $HeartbeatIntervalSeconds) {
                    $doneSoFar = $batchResult.ConvertedCount + $batchResult.FailedCount + $batchResult.SkippedCount + $batchResult.StaticSkippedCount + $batchResult.InspectFailedCount
                    $labelSuffix = if ($BatchLabel) { " in '" + $BatchLabel + "'" } else { "" }
                    Write-Log ("Still converting '" + $j.SrcPath + "'" + $labelSuffix + " (" + [int]$j.StartTime.Elapsed.TotalSeconds + "s elapsed) - batch progress: " + $doneSoFar + "/" + $totalFiles + " done.")
                    $j.LastHeartbeat = $j.StartTime.Elapsed
                }
                $stillRunning.Add($j)
            }
        }
        $running = $stillRunning

        [System.Threading.Thread]::Sleep(50)
    }
    } catch {
        foreach ($j in $running) {
            try { if ($j.Proc -and -not $j.Proc.HasExited) { $j.Proc.Kill() } } catch { }
            try { if ($j.Proc) { $j.Proc.WaitForExit(5000) } } catch { }
            if ($j.TempOverwritePath) {
                try { [System.IO.File]::Delete($j.TempOverwritePath) } catch { }
            }
            if (-not $j.SlotReleased) {
                try { [System.IO.File]::Delete($j.MagickOutputPath) } catch { }
            }
            try { if ($j.Proc) { $j.Proc.Dispose() } } catch { }
        }
        throw
    }

    if ($CancelToken.IsCancellationRequested -and $running.Count -gt 0) {
        if ($AbortWaitMessage) {
            Write-GatedConsoleMessage -Text $AbortWaitMessage -Color Yellow -CleanConsoleOutputEnabled ([bool]$script:CleanConsoleOutputEnabled)
        }
        $abortDeadline = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            while ($running.Count -gt 0 -and -not [ConsoleCtrl]::IsCloseEvent -and $abortDeadline.Elapsed.TotalSeconds -lt $AbortTimeoutSeconds) {
                $stillWaiting = [System.Collections.Generic.List[hashtable]]::new()
                foreach ($j in $running) {
                    if ($j.Proc.HasExited) {
                        Complete-AnimatedConversionJob -Job $j -BatchResult $batchResult -DoFullLogging $DoFullLogging -DoAnimatedDeleteSource $DoAnimatedDeleteSource -IsAbortDrain $true
                    } else {
                        $stillWaiting.Add($j)
                    }
                }
                $running = $stillWaiting
                if ($running.Count -gt 0) { [System.Threading.Thread]::Sleep(250) }
            }

            if ($running.Count -gt 0) {
                $stillWaiting = [System.Collections.Generic.List[hashtable]]::new()
                foreach ($j in $running) {
                    if ($j.Proc.HasExited) {
                        Complete-AnimatedConversionJob -Job $j -BatchResult $batchResult -DoFullLogging $DoFullLogging -DoAnimatedDeleteSource $DoAnimatedDeleteSource -IsAbortDrain $true
                    } else {
                        $stillWaiting.Add($j)
                    }
                }
                $running = $stillWaiting
            }

            if ($running.Count -gt 0) {
                $batchResult.ForceKilledCount = $running.Count
                $labelSuffix = if ($BatchLabel) { " in '" + $BatchLabel + "'" } else { "" }
                Write-Log ("Force-stopping " + $running.Count + " job(s) that did not finish within " + $AbortTimeoutSeconds + "s" + $labelSuffix + ".") -Level Warn
                foreach ($j in $running) {
                    try { if (-not $j.Proc.HasExited) { $j.Proc.Kill() } } catch { }
                    try { $j.Proc.WaitForExit(5000) } catch { }
                    try { [System.IO.File]::Delete($j.MagickOutputPath) } catch { }
                    $j.Proc.Dispose()
                    $j.SlotReleased = $true
                }
            }
        } catch {
            foreach ($j in $running) {
                try { if ($j.Proc -and -not $j.Proc.HasExited) { $j.Proc.Kill() } } catch { }
                try { if ($j.Proc) { $j.Proc.WaitForExit(5000) } } catch { }
                if ($j.TempOverwritePath) {
                    try { [System.IO.File]::Delete($j.TempOverwritePath) } catch { }
                }
                if ((-not $j.SlotReleased) -and $j.MagickOutputPath) {
                    try { [System.IO.File]::Delete($j.MagickOutputPath) } catch { }
                }
                try { if ($j.Proc) { $j.Proc.Dispose() } } catch { }
            }
            throw
        }
    }

    foreach ($j in $pending.ToArray()) { $batchResult.PendingPaths.Add($j.SrcPath) }

    return $batchResult
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
    # DOCUMENTED DUPLICATE, not a call-through, of
    # Complete-AnimatedConversionJob's own exit-code/File.Replace/
    # delete-source logic - see that function's own header. Keep both
    # in sync if either changes.
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
    # DOCUMENTED DUPLICATE: Complete-AnimatedConversionJob's own copy of
    # this function has the identical $webpReplaceBackup init - keep both
    # in sync.
    $webpReplaceBackup = $null
    try {
        if ($code -ne 0) { throw ("magick exited with code " + $code + ". Stderr: " + $stderr) }
        if (-not [System.IO.File]::Exists($Job.MagickOutputPath)) { throw ("Output .webp was not created: '" + $Job.MagickOutputPath + "'") }
        $webpSize = [System.IO.FileInfo]::new($Job.MagickOutputPath).Length
        if ($webpSize -eq 0) { throw ("Output .webp is 0 bytes: '" + $Job.MagickOutputPath + "'") }
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
                $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
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
                InspectFailedCount = 0; DeletedCount = 0; DeleteFailedCount = 0
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

                $webpPathExists = [System.IO.File]::Exists($webpPath)
                if ($webpPathExists -and -not $AnimatedOverwrite) {
                    Write-Log ("SKIPPING '" + $srcPath + "': output '" + $webpPath + "' already exists (Overwrite is off).")
                    $cr.SkippedCount++
                    $cr.SkippedPaths.Add($srcPath)
                    continue
                }

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
                $psi.Arguments = "`"" + $job.SrcPath + "`" -coalesce -loop 0 " + $qualityArg + " `"" + $job.MagickOutputPath + "`""
                $psi.UseShellExecute        = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $psi.CreateNoWindow         = $true

                Write-Log ("Converting animated: '" + $job.SrcPath + "'")

                $job.Proc          = [System.Diagnostics.Process]::Start($psi)
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
        }

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
    return @('Convert-AnimatedBatch', 'Complete-AnimatedConversionJob', 'Test-AvifAnimated')
}
