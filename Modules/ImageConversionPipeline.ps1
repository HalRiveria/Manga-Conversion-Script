# See module-descriptions.md for this module's full description.

# ==============================================================================
#  PART 1 - shared helpers used by PART 2's live conversion engine
# ==============================================================================

function Get-LooseImageExtensions {
    return @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif", ".gif", ".bmp", ".heic", ".heif")
}

function Test-OrphanedScratchFileName {
    # DOCUMENTED DUPLICATE: ZipPipeline.ps1's $script:zipOnlyWorker keeps its
    # own literal copy of this regex trio - keep both in sync.
    param([Parameter(Mandatory)][string]$Name)
    return (
        $Name -imatch '_tmp_iccstrip(-\d+)?\.png$' -or
        $Name -imatch '_tmp_(webp|avif|bmp|heic|heif|tiff)2png\.png$' -or
        $Name -imatch '_tmp_overwrite\.webp$'
    )
}

function Get-NeverConvertedExtensions {
    return @(".gif")
}

function Get-SeriesCoverConvertibleExtensions {
    return @(".webp", ".png", ".avif", ".bmp", ".tif", ".tiff", ".heic", ".heif", ".jxl")
}

function Invoke-SeriesCoverNormalization {
    param(
        [Parameter(Mandatory)]
        [string]$SeriesPath,
        [string]$MagickExe
    )
    $result = @{ Success = 0; Fail = 0 }

    $covers = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    try {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($SeriesPath, "*")) {
            $fi = [System.IO.FileInfo]::new($f)
            if ([System.IO.Path]::GetFileNameWithoutExtension($fi.Name) -ieq 'cover') { $covers.Add($fi) }
        }
    } catch {
        Write-Log ("Could not list series folder '" + $SeriesPath + "' to check for a cover - leaving any cover as it is: " + $_) -Level Warn
        return $result
    }
    if ($covers.Count -eq 0) { return $result }

    if ($covers.Count -gt 1) {
        $nameList = [System.Collections.Generic.List[string]]::new()
        foreach ($c in $covers) { $nameList.Add($c.Name) }
        $names = $nameList -join "', '"
        Write-Log ("Series folder '" + $SeriesPath + "' has more than one cover file ('" + $names + "') - left all of them alone. Keep one and delete the others.") -Level Warn
        return $result
    }

    $cover = $covers[0]
    $ext = $cover.Extension
    if ($ext -ieq '.jpg') { return $result }

    $target = [System.IO.Path]::Combine($SeriesPath, "cover.jpg")

    if ($ext -ieq '.jpeg') {
        try {
            [System.IO.File]::Move($cover.FullName, $target)
            Write-Log ("Renamed series cover '" + $cover.FullName + "' to 'cover.jpg'.")
            $result.Success++
        } catch {
            Write-Log ("FAILED to rename series cover '" + $cover.FullName + "' to 'cover.jpg': " + $_) -Level Error
            $result.Fail++
        }
        return $result
    }

    if ((Get-SeriesCoverConvertibleExtensions) -inotcontains $ext) {
        Write-Log ("Series cover '" + $cover.FullName + "' is not a format this project converts to cover.jpg - left alone.") -Level Warn
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($MagickExe)) {
        Write-Log ("FAILED to convert series cover '" + $cover.FullName + "' to cover.jpg: magick.exe was not found or configured. Original left in place.") -Level Error
        $result.Fail++
        return $result
    }
    if (Test-AbortSignal) { return $result }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $MagickExe
    # %% on the output path only, as in Invoke-IccStripRetryOrFail.
    $psi.Arguments              = "`"" + $cover.FullName + "[0]`" -background white -alpha remove -alpha off -quality 95 `"" + $target.Replace('%', '%%') + "`""
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $failure = $null
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $null = [ChildProcessJob]::Assign($proc)  # see AbortPipeline.ps1's ChildProcessJob
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        # DOCUMENTED DUPLICATE: the same raw-handle wait and bounded stream
        # read as Invoke-IccStripRetryOrFail in this module and
        # Test-AvifAnimated in AnimatedConversionPipeline.ps1 - keep all
        # three in sync.
        $waitHandle = [System.Threading.ManualResetEvent]::new($false)
        $origHandle = $waitHandle.SafeWaitHandle
        $waitHandle.SafeWaitHandle = (
            [Microsoft.Win32.SafeHandles.SafeWaitHandle]::new(
                $proc.Handle, $false
            )
        )
        try {
            $exited = $waitHandle.WaitOne(120000)
        } finally {
            $waitHandle.SafeWaitHandle = $origHandle
            $waitHandle.Dispose()
        }
        if (-not $exited) {
            try { $proc.Kill() } catch { }   # already exited or access denied; the failure is reported either way
            [System.Threading.Thread]::Sleep(200)
            $failure = "magick did not exit within 120s - killed"
        } elseif (-not [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 15000)) {
            $failure = "magick exited but its output streams did not finish reading within 15s"
        } else {
            $null = $stdoutTask.Result
            $stderrText = $stderrTask.Result
            $exitCode = $proc.ExitCode
            $outInfo = [System.IO.FileInfo]::new($target)
            if ($exitCode -ne 0) {
                $failure = "magick exited " + $exitCode
                if ($stderrText) { $failure += ": " + $stderrText.Trim() }
            } elseif (-not $outInfo.Exists -or $outInfo.Length -eq 0) {
                $failure = "magick reported success but cover.jpg is missing or empty"
            }
        }
    } catch {
        $failure = "could not run magick: " + $_
    } finally {
        if ($null -ne $proc) { $proc.Dispose() }
    }

    if ($null -ne $failure) {
        Write-Log ("FAILED to convert series cover '" + $cover.FullName + "' to cover.jpg: " + $failure + ". Original left in place.") -Level Error
        if ([System.IO.File]::Exists($target)) { try { [System.IO.File]::Delete($target) } catch { } }  # partial output; nothing else to do if it won't go
        $result.Fail++
        return $result
    }

    try {
        $removed = Remove-Source -ItemPath $cover.FullName
        if (-not $removed) {
            Write-Log ("Series cover '" + $cover.FullName + "' was already gone before it could be deleted.") -Level Warn
        }
        Write-Log ("Converted series cover '" + $cover.FullName + "' to 'cover.jpg'.")
        $result.Success++
    } catch {
        Write-Log ("Converted series cover '" + $cover.FullName + "' to 'cover.jpg', but FAILED to delete the original: " + $_ + ". Delete it by hand; until then the next run will see two covers and leave both alone.") -Level Error
        $result.Fail++
    }
    return $result
}

function Invoke-IccStripRetryOrFail {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Job,
        [Parameter(Mandatory)]
        [System.Collections.Queue]$Pending,
        [Parameter(Mandatory)]
        [string]$MagickExe,
        $ChapterKey = $null
    )

    $strippedPng = [System.IO.Path]::Combine(
        [System.IO.Path]::GetDirectoryName($Job.SrcPath),
        [System.IO.Path]::GetFileNameWithoutExtension($Job.SrcPath) + "_tmp_iccstrip.png"
    )
    Write-Log ("ICC profile mismatch on '" + $Job.SrcPath + "' - stripping profile and retrying.") -Level Warn
    $stripPsi = [System.Diagnostics.ProcessStartInfo]::new()
    $stripPsi.FileName               = $MagickExe
    # %% on the OUTPUT path only - see AnimatedConversionPipeline.ps1's jobStarter own
    # comment for the full story. The SOURCE does NOT need this - reading
    # an existing file with a literal % works fine unescaped, and escaping
    # it would break it (magick would look for a literal %% that doesn't
    # exist on disk).
    $escapedStrippedPng  = $strippedPng.Replace('%', '%%')
    $stripPsi.Arguments              = "`"" + $Job.SrcPath + "`" -strip `"" + $escapedStrippedPng + "`""
    $stripPsi.UseShellExecute        = $false
    $stripPsi.RedirectStandardOutput = $true
    $stripPsi.RedirectStandardError  = $true
    $stripPsi.CreateNoWindow         = $true
    try {
        $stripProc = [System.Diagnostics.Process]::Start($stripPsi)
        $null = [ChildProcessJob]::Assign($stripProc)  # see AbortPipeline.ps1's ChildProcessJob
    } catch {
        Write-Log ("Could not start ICC-strip retry process for '" + $Job.SrcPath + "': " + $_) -Level Error
        return $false
    }
    # DOCUMENTED DUPLICATE: Test-AvifAnimated in
    # AnimatedConversionPipeline.ps1 and Invoke-SeriesCoverNormalization in
    # this module use the identical raw-handle-wait pattern below - keep all
    # three in sync.
    try {
        $stripStdoutTask = $stripProc.StandardOutput.ReadToEndAsync()
        $stripStderrTask = $stripProc.StandardError.ReadToEndAsync()
        $stripWaitHandle = [System.Threading.ManualResetEvent]::new($false)
        $stripOrigHandle = $stripWaitHandle.SafeWaitHandle
        $stripWaitHandle.SafeWaitHandle = (
            [Microsoft.Win32.SafeHandles.SafeWaitHandle]::new(
                $stripProc.Handle, $false
            )
        )
        try {
            $stripExited = $stripWaitHandle.WaitOne(60000)
        } finally {
            $stripWaitHandle.SafeWaitHandle = $stripOrigHandle
            $stripWaitHandle.Dispose()
        }

        if (-not $stripExited) {
            try { $stripProc.Kill() } catch { }
            [System.Threading.Thread]::Sleep(200)
            Write-Log ("ICC-strip retry process for '" + $Job.SrcPath + "' did not exit within 60s - killed, counting as conversion failure.") -Level Error
            return $false
        }

        # DOCUMENTED DUPLICATE: Test-AvifAnimated in
        # AnimatedConversionPipeline.ps1 and Invoke-SeriesCoverNormalization
        # in this module use the identical bounded-stream-read pattern
        # below - keep all three in sync. 15s gives
        # margin (see that module's own matching comment).
        if (-not [System.Threading.Tasks.Task]::WaitAll(@($stripStdoutTask, $stripStderrTask), 15000)) {
            # Same reasoning as Test-AvifAnimated's own
            # matching comment - the process handle above only proves the
            # PROCESS exited, not that its redirected stdout/stderr pipes
            # reached EOF.
            Write-Log ("ICC-strip retry process for '" + $Job.SrcPath + "' exited but its output streams did not finish reading within 15s - counting as conversion failure.") -Level Error
            return $false
        }
        $null = $stripStdoutTask.Result
        $null = $stripStderrTask.Result
        $stripExitCode = $stripProc.ExitCode
    } finally {
        $stripProc.Dispose()
    }

    if ($stripExitCode -eq 0 -and [System.IO.File]::Exists($strippedPng)) {
        if ([System.IO.File]::Exists($Job.JxlPath)) { try { [System.IO.File]::Delete($Job.JxlPath) } catch { } }
        $retryJob = @{
            SrcPath    = $Job.SrcPath
            JxlPath    = $Job.JxlPath
            Proc       = $null
            TempPng    = $strippedPng
            IccRetried = $true
            ChapterKey = $ChapterKey
        }
        $Pending.Enqueue($retryJob)
        return $true
    }

    Write-Log ("ICC strip failed for '" + $Job.SrcPath + "': magick exited " + $stripExitCode + " - counting as conversion failure.") -Level Error
    if ([System.IO.File]::Exists($strippedPng)) { try { [System.IO.File]::Delete($strippedPng) } catch { } }
    return $false
}

function Complete-ImageDispatchJob {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Job,
        [Parameter(Mandatory)]
        [hashtable]$ChapterResult,
        [System.Collections.Generic.Queue[hashtable]]$PendingQueue,
        [string]$MagickExe,
        [bool]$DoFullLogging,
        [string]$ItemNoun   = "image",
        [string]$SourceNoun = "source image",
        [int]$StreamReadTimeoutMs = 15000
    )

    # DOCUMENTED DUPLICATE of AnimatedConversionPipeline.ps1's Complete-AnimatedDispatchJob
    # (same bounded, failure-tolerant read of the finished process's output) -
    # keep both in sync. The 15s default is the same bound Test-AvifAnimated,
    # Invoke-IccStripRetryOrFail and both pre-conversion detours use - all
    # bumped together.
    $streamText = @{ Stdout = ""; Stderr = "" }
    if ($Job.StdoutTask -and $Job.StderrTask) {
        # A faulted read makes WaitAll throw; each task is judged on its own below.
        try { $null = [System.Threading.Tasks.Task]::WaitAll(@($Job.StdoutTask, $Job.StderrTask), $StreamReadTimeoutMs) } catch { }
        foreach ($streamName in @('Stdout', 'Stderr')) {
            $streamTask = $Job[$streamName + 'Task']
            if ($streamTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                $streamText[$streamName] = $streamTask.Result
            } elseif ($streamTask.IsFaulted) {
                Write-Log ("Reading cjxl " + $streamName.ToLowerInvariant() + " failed for '" + $Job.SrcPath + "' - judging the conversion by exit code and output file only: " + $streamTask.Exception.GetBaseException().Message) -Level Warn
            } else {
                Write-Log ("cjxl exited but its " + $streamName.ToLowerInvariant() + " did not finish reading within " + [int]($StreamReadTimeoutMs / 1000) + "s for '" + $Job.SrcPath + "' - judging the conversion by exit code and output file only.") -Level Warn
            }
        }
    } else {
        try {
            $streamText.Stdout = $Job.Proc.StandardOutput.ReadToEnd()
            $streamText.Stderr = $Job.Proc.StandardError.ReadToEnd()
        } catch {
            Write-Log ("Reading cjxl output failed for '" + $Job.SrcPath + "' - judging the conversion by exit code and output file only: " + $_) -Level Warn
        }
    }
    $stdout = $streamText.Stdout
    $stderr = $streamText.Stderr
    $code   = $Job.Proc.ExitCode

    if ($DoFullLogging -and -not [string]::IsNullOrWhiteSpace($stdout)) {
        Write-Log ("cjxl stdout for '" + $Job.SrcPath + "': " + $stdout.Trim())
    }

    $convOk = $false
    try {
        if ($code -ne 0) {
            if ($code -eq 1 -and $stderr -imatch 'Getting pixel data failed' -and $MagickExe -and -not $Job.IccRetried) {
                $iccRetryLanding = [System.Collections.Queue]::new()
                if (Invoke-IccStripRetryOrFail -Job $Job -Pending $iccRetryLanding -MagickExe $MagickExe -ChapterKey $Job.ChapterKey) {
                    foreach ($retryJob in $iccRetryLanding) { $PendingQueue.Enqueue($retryJob) }
                    if ($Job.TempPng -and [System.IO.File]::Exists($Job.TempPng)) { try { [System.IO.File]::Delete($Job.TempPng) } catch { } }
                    return @{ Requeued = $true }
                }
            }
            throw ("cjxl exited with code " + $code + ". Stderr: " + $stderr)
        }
        # Exit code and stderr included even on these two throws
        # (same reasoning as AnimatedConversionPipeline.ps1's
        # matching throws - cjxl exiting 0 while failing to produce real
        # output shouldn't leave the log with no diagnostic detail).
        if (-not [System.IO.File]::Exists($Job.JxlPath)) { throw ("Output .jxl was not created (cjxl exited " + $code + "): '" + $Job.JxlPath + "'. Stderr: " + $stderr) }
        $jxlSize = [System.IO.FileInfo]::new($Job.JxlPath).Length
        if ($jxlSize -eq 0) { throw ("Output .jxl is 0 bytes (cjxl exited " + $code + "): '" + $Job.JxlPath + "'. Stderr: " + $stderr) }
        Write-Log ("Conversion OK: '" + $Job.JxlPath + "' (" + $jxlSize + " bytes)")
        $ChapterResult.ConvertedCount++
        $convOk = $true
    } catch {
        Write-Log ("FAILED conversion of " + $ItemNoun + " '" + $Job.SrcPath + "': " + $_) -Level Error
        $ChapterResult.FailedCount++
        if ([System.IO.File]::Exists($Job.JxlPath)) {
            try { [System.IO.File]::Delete($Job.JxlPath) } catch { }
        }
    }

    if ($Job.TempPng -and [System.IO.File]::Exists($Job.TempPng)) {
        try { [System.IO.File]::Delete($Job.TempPng) } catch { }
    }

    if ($convOk) {
        try {
            $removed = Remove-Source -ItemPath $Job.SrcPath
            if ($removed) {
                $deleteDesc = if (Get-WorkerRunspaceValue -Name PermanentDelete) { "permanently" } else { "Recycle Bin" }
                Write-Log ("Deleted " + $SourceNoun + " (" + $deleteDesc + "): '" + $Job.SrcPath + "'")
                $ChapterResult.DeletedCount++
            } else {
                Write-Log ($SourceNoun.Substring(0,1).ToUpperInvariant() + $SourceNoun.Substring(1) + " already gone before deletion (not counted as deleted): '" + $Job.SrcPath + "'") -Level Warn
            }
        } catch {
            Write-Log ("FAILED to delete " + $SourceNoun + " '" + $Job.SrcPath + "': " + $_) -Level Error
            $ChapterResult.DeleteFailedCount++
        }
    }

    return @{ Success = $convOk }
}

function Test-WebPAnimated {
    param(
        [Parameter(Mandatory)]
        [string]$WebPPath
    )

    $bytes = [byte[]]::new(24)
    $bytesRead = 0
    $stream = [System.IO.File]::OpenRead($WebPPath)
    try { $bytesRead = $stream.Read($bytes, 0, 24) } finally { $stream.Dispose() }

    if ($bytesRead -lt 24) { return $false }
    $chunkId = [System.Text.Encoding]::ASCII.GetString($bytes, 12, 4)
    if ($chunkId -ne 'VP8X') { return $false }
    $flags = [System.BitConverter]::ToUInt32($bytes, 20)
    return ($flags -band 0x02) -ne 0
}

# ==============================================================================
#  PART 2 - Image Conversion (menu 2) orchestration
# ==============================================================================

function Get-LooseImageCandidates {
    param(
        [Parameter(Mandatory)]
        [string]$ScanPath,
        [string[]]$LooseImageExtensions = (Get-LooseImageExtensions),
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

    $allCandidates = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($file in (Get-FilesRecursiveSafe -ScanPath $ScanPath)) {
        if ($LooseImageExtensions -inotcontains $file.Extension) { continue }
        if (Test-SeriesCoverFile -File $file -SeriesPath $ScanPath) { continue }
        if (Test-OrphanedScratchFileName -Name $file.Name) { continue }
        if ((Get-NeverConvertedExtensions) -icontains $file.Extension) {
            Write-Log ("SKIPPING '" + $file.FullName + "': not converted by this project (see Get-NeverConvertedExtensions's own comment for why). File left untouched.") -Level Warn
            continue
        }
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
        $allCandidates.Add($file)
    }

    $needsConversion = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $staleSources     = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $namingCollisions = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($img in $allCandidates) {
        $jxlCounterpart = [System.IO.Path]::ChangeExtension($img.FullName, ".jxl")
        $jxlItem = [System.IO.FileInfo]::new($jxlCounterpart)
        if ($jxlItem.Exists) {
            if ($jxlItem.Length -eq 0) {
                Write-Log ("Existing .jxl counterpart for '" + $img.FullName + "' is 0 bytes - treating as incomplete and re-converting source.") -Level Warn
                $needsConversion.Add($img)
            } elseif ($img.LastWriteTimeUtc -ge $jxlItem.LastWriteTimeUtc) {
                Write-Log ("'" + $img.FullName + "' shares a basename with an existing '" + $jxlCounterpart + "' it did not produce (this source is not older than it) - a real naming collision, not a stale leftover. Left untouched - neither converted (would silently overwrite the existing .jxl) nor deleted (would lose an unconverted source). Rename one of the two files to resolve.") -Level Error
                $namingCollisions.Add($img)
            } else {
                $staleSources.Add($img)
            }
        } else {
            $needsConversion.Add($img)
        }
    }

    return @{ NeedsConversion = $needsConversion; StaleSources = $staleSources; NamingCollisions = $namingCollisions }
}

function Remove-StaleLooseSources {
    param(
        [System.IO.FileInfo[]]$StaleSources
    )
    $result = @{ Success = 0; Fail = 0 }
    if (-not $StaleSources -or $StaleSources.Count -eq 0) { return $result }

    Write-Log ("Found " + $StaleSources.Count + " loose source file(s) with an existing .jxl counterpart - cleaning up.")
    foreach ($stale in $StaleSources) {
        if (Test-AbortSignal) { break }
        try {
            $removed = Remove-Source -ItemPath $stale.FullName
            if ($removed) {
                $deleteDesc = if (Get-WorkerRunspaceValue -Name PermanentDelete) { "permanently" } else { "Recycle Bin" }
                Write-Log ("Deleted stale source image (" + $deleteDesc + ", .jxl already exists): '" + $stale.FullName + "'")
                $result.Success++
            } else {
                Write-Log ("Stale source image already gone before deletion (not counted as deleted): '" + $stale.FullName + "'") -Level Warn
            }
        } catch {
            Write-Log ("FAILED to delete stale source image '" + $stale.FullName + "': " + $_) -Level Error
            $result.Fail++
        }
    }
    return $result
}

function Get-ChapterProgressStatus {
    param(
        [hashtable]$ChapterResult
    )
    if ($null -eq $ChapterResult) { return "Success", $null }

    # DOCUMENTED DUPLICATE of AnimatedConversionPipeline.ps1's
    # Get-ChapterAnimatedStatus (same four fields, same severity
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
        return "Warning", ($ChapterResult.SkippedCount.ToString() + " image(s) skipped")
    }
    return "Success", $null
}

function Get-ZipBlockedStatusOverride {
    param(
        [Parameter(Mandatory)]
        [string]$Status,
        [string]$Detail,
        [Parameter(Mandatory)]
        [string]$BlockedReason
    )
    if ($Status -eq 'Error') { return $Status, $Detail }
    $newDetail = if ($Detail) { $Detail + " | zip skipped: " + $BlockedReason } else { "zip skipped: " + $BlockedReason }
    return 'Warning', $newDetail
}

function Invoke-LooseImageConversionPipeline {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$CjxlExe,
        [string]$MagickExe,
        [bool]$JpegLossless = $false,
        [int]$JpegQuality = 90,
        [Parameter(Mandatory)]
        [int]$MaxCjxlProcs,
        [Parameter(Mandatory)]
        [bool]$FullLogging,
        [string[]]$LooseImageExtensions = (Get-LooseImageExtensions),
        [string[]]$KnownZipPaths = @(),
        [string[]]$FolderQualifyingExtensions = ((Get-LooseImageExtensions) + @(".jxl")),
        [System.Collections.Generic.HashSet[string]]$FolderExcludeStagingDirs = $null,
        [scriptblock]$PostChapterCallback = $null,
        [int]$AbortTimeoutSeconds = 60,
        [int]$MaxQueueAhead = 3
    )

    $totals = @{
        ConvertedSuccess    = 0
        ConvertedFail       = 0
        ConvertedSkipped    = 0
        DeletedSuccess      = 0
        DeletedFail         = 0
        StaleCleanedSuccess = 0
        StaleCleanedFail    = 0
        CoverNormalizedSuccess = 0
        CoverNormalizedFail    = 0
        ForceKilledCount    = 0
        InspectFailedCount  = 0
        LastCompletedPaths  = [System.Collections.Generic.List[string]]::new()
        LastSkippedPaths    = [System.Collections.Generic.List[string]]::new()
        StillPendingPaths   = [System.Collections.Generic.List[string]]::new()
        SeriesCount         = 0
        ChapterCount        = 0
        Aborted             = $false
    }

    $chapterResults = [System.Collections.Generic.Dictionary[object,hashtable]]::new()

    $cleanConsoleOutputEnabled = [bool]$script:CleanConsoleOutputEnabled

    try {
        $looseCts = [System.Threading.CancellationTokenSource]::new()
        Register-AbortCancellationSource -Cts $looseCts

        $seriesProvider  = New-SeriesProvider -LibraryPath $Path -QualifyingExtensions $FolderQualifyingExtensions
        $chapterQueue    = [System.Collections.Generic.Queue[hashtable]]::new()
        # Hashtable, not a plain scalar (a plain scalar assigned inside a
        # closure doesn't latch; see
        # ChapterDispatch.ps1's New-LibraryChapterProvider for the full
        # explanation).
        $chapterProviderState = @{ SeriesExhausted = $false }
        $chapterProvider = {
            while ($chapterQueue.Count -eq 0 -and -not $chapterProviderState.SeriesExhausted) {
                if (Test-AbortSignal) { $chapterProviderState.SeriesExhausted = $true; break }

                $series = & $seriesProvider
                if ($null -eq $series) { $chapterProviderState.SeriesExhausted = $true; break }
                $totals.SeriesCount++

                # Before the candidate scan, so a converted cover is never seen as a loose image.
                $coverResult = Invoke-SeriesCoverNormalization -SeriesPath $series.FullName -MagickExe $MagickExe
                $totals.CoverNormalizedSuccess += $coverResult.Success
                $totals.CoverNormalizedFail    += $coverResult.Fail

                $chapters = Get-SeriesChapters -SeriesPath $series.FullName -QualifyingExtensions $FolderQualifyingExtensions `
                    -ExcludeStagingDirs $FolderExcludeStagingDirs -ForceRezip $false

                $seriesCandidates = Get-LooseImageCandidates -ScanPath $series.FullName -LooseImageExtensions $LooseImageExtensions -KnownZipPaths $KnownZipPaths -ExcludeStagingDirs $FolderExcludeStagingDirs

                $staleResult = Remove-StaleLooseSources -StaleSources $seriesCandidates.StaleSources
                $totals.StaleCleanedSuccess += $staleResult.Success
                $totals.StaleCleanedFail    += $staleResult.Fail

                $totals.InspectFailedCount += $seriesCandidates.NamingCollisions.Count
                $namingCollisionDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($nc in $seriesCandidates.NamingCollisions) { $null = $namingCollisionDirs.Add($nc.DirectoryName) }

                $imagesByDir = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[System.IO.FileInfo]]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($img in $seriesCandidates.NeedsConversion) {
                    if (-not $imagesByDir.ContainsKey($img.DirectoryName)) {
                        $imagesByDir[$img.DirectoryName] = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
                    }
                    $imagesByDir[$img.DirectoryName].Add($img)
                }

                $chapterDirSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                $seriesChapterCount = 0
                foreach ($c in $chapters) {
                    $null = $chapterDirSet.Add($c.Dir.FullName)
                    $chapterImages = @()
                    if ($imagesByDir.ContainsKey($c.Dir.FullName)) { $chapterImages = @($imagesByDir[$c.Dir.FullName]) }
                    $chapterQueue.Enqueue(@{
                        SeriesName = $series.Name; ChapterName = $c.Dir.Name; Dir = $c.Dir
                        HasNamingCollision = $namingCollisionDirs.Contains($c.Dir.FullName)
                        Images = $chapterImages
                    })
                    $seriesChapterCount++
                }
                foreach ($extraDirPath in $imagesByDir.Keys) {
                    if ($chapterDirSet.Contains($extraDirPath)) { continue }
                    $extraDir = $imagesByDir[$extraDirPath][0].Directory
                    $chapterQueue.Enqueue(@{
                        SeriesName = $series.Name; ChapterName = $extraDir.Name; Dir = $extraDir
                        HasNamingCollision = $namingCollisionDirs.Contains($extraDir.FullName)
                        Images = $imagesByDir[$extraDirPath]
                    })
                    $seriesChapterCount++
                    Write-Log ("Series '" + $series.Name + "': '" + $extraDir.Name + "' has unconverted image(s) but wasn't found by chapter discovery (e.g. a stray .zip sitting alongside it, or images outside a normal chapter folder) - converting it anyway, but NOT treating it as zippable.") -Level Warn
                }

                if ($seriesChapterCount -eq 0) {
                    Write-Log ("Series '" + $series.Name + "': no qualifying chapters found.") -Level Info
                    continue
                }

                if ($cleanConsoleOutputEnabled) {
                    Start-SeriesProgress -SeriesName $series.Name -TotalChapters $seriesChapterCount
                }
                Write-Log ("=== Series '" + $series.Name + "': " + $seriesChapterCount + " chapter(s) ===")
            }
            if ($chapterQueue.Count -gt 0) { return $chapterQueue.Dequeue() }
            return $null
        }.GetNewClosure()

        $jobBuilder = {
            param($chapterInfo)

            $totals.ChapterCount++
            $cr = @{
                ConvertedCount = 0; FailedCount = 0; SkippedCount = 0; DeletedCount = 0; DeleteFailedCount = 0
                InspectFailedCount = 0; ForceKilledCount = 0
                SkippedPaths = [System.Collections.Generic.List[string]]::new()
                TotalFiles = $chapterInfo.Images.Count
            }
            $chapterResults[$chapterInfo] = $cr

            if ($cleanConsoleOutputEnabled) {
                Start-ChapterProgress -SeriesName $chapterInfo.SeriesName -ChapterName $chapterInfo.ChapterName -Queued
            }

            if ($cr.TotalFiles -eq 0) {
                Write-Log ("Chapter '" + $chapterInfo.Dir.FullName + "': no unconverted images - skipping conversion.")
                return @()
            }
            Write-Log ("Processing chapter: '" + $chapterInfo.Dir.FullName + "' (" + $cr.TotalFiles + " image(s))")

            $allJobs = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($img in $chapterInfo.Images) {
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
                } elseif ($MagickExe -and $srcPath -imatch '\.avif$' -and -not (Test-AbortSignal)) {
                    # DOCUMENTED DUPLICATE: the same Test-AbortSignal check before each
                    # per-file Test-AvifAnimated spawn also lives in
                    # AnimatedConversionPipeline.ps1's jobBuilder and Controller.ps1's
                    # Get-OrCreateFullPipelineChapterClassification - keep all three in sync.
                    try {
                        $isAnimatedAvif = Test-AvifAnimated -AvifPath $srcPath -MagickExe $MagickExe
                    } catch {
                        Write-Log ("Could not determine if AVIF '" + $srcPath + "' is animated - skipping: " + $_) -Level Warn
                        $cr.InspectFailedCount++
                        continue
                    }
                    if ($isAnimatedAvif) {
                        Write-Log ("SKIPPING animated AVIF '" + $srcPath + "': has its own conversion pipeline (AnimatedConversionPipeline.ps1) - not converted here.") -Level Warn
                        $cr.SkippedCount++
                        $cr.SkippedPaths.Add($srcPath)
                        continue
                    }
                }
                # DOCUMENTED DUPLICATE: this same format-label switch is
                # also copied at job-build time in Controller.ps1's
                # image-engine JobBuilder - keep both in sync if the set
                # of magick-detour formats ever changes.
                $formatLabel = switch -Regex ($srcPath) {
                    '\.avif$' { "AVIF"; break }
                    '\.webp$' { "WebP"; break }
                    '\.bmp$'  { "BMP";  break }
                    '\.heic$' { "HEIC"; break }
                    '\.heif$' { "HEIF"; break }
                    '\.tiff?$' { "TIFF"; break }   # cjxl can't read TIFF at all
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
            # progress flip is in AnimatedConversionPipeline.ps1's jobStarter and (via a
            # 'ChapterRunning' event) both of Controller.ps1's jobStarters -
            # keep all four in sync.
            if (-not $cr.CcrRunning) {
                $cr.CcrRunning = $true
                if ($cleanConsoleOutputEnabled) { Set-ChapterInProgress -SeriesName $job.ChapterKey.SeriesName -ChapterName $job.ChapterKey.ChapterName }
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
                    # %% on the OUTPUT path only (DOCUMENTED DUPLICATE of
                    # Controller.ps1's own matching jobStarter, keep both
                    # in sync). The SOURCE does NOT need this - reading an
                    # existing file with a literal % works fine unescaped,
                    # and escaping it would break it (magick would look for
                    # a literal %% that doesn't exist on disk).
                    $escapedTempPng2    = $tempPng.Replace('%', '%%')
                    $magickPsi.Arguments              = "`"" + $job.SrcPath + "[0]`" `"" + $escapedTempPng2 + "`""
                    $magickPsi.UseShellExecute        = $false
                    $magickPsi.RedirectStandardOutput = $true
                    $magickPsi.RedirectStandardError  = $true
                    $magickPsi.CreateNoWindow         = $true
                    $magickProc = [System.Diagnostics.Process]::Start($magickPsi)
                    $null = [ChildProcessJob]::Assign($magickProc)  # see AbortPipeline.ps1's ChildProcessJob
                    $magickProcLocal = $magickProc
                    $magickStdoutTask = $magickProc.StandardOutput.ReadToEndAsync()
                    $magickStderrTask = $magickProc.StandardError.ReadToEndAsync()
                    # DOCUMENTED DUPLICATE of Controller.ps1's own image-engine
                    # JobStarter's identical PNG pre-conversion wait - keep
                    # both in sync. A bare WaitForExit() here has no timeout, and this jobStarter runs on
                    # the main thread inside the dispatch loop - a wedged
                    # magick.exe would freeze the entire Image Conversion run with no
                    # Ctrl+C escape (the cancel token is only checked between
                    # dispatch loop passes). Raw-handle ManualResetEvent
                    # instead of Process.WaitForExit(int), which can't be
                    # trusted to return reliably here.
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
                        Write-Log ("FAILED " + $formatLabel + "->PNG pre-conversion for '" + $job.SrcPath + "': magick did not exit within 120s - killed") -Level Error
                        $cr.FailedCount++
                        $failureAlreadyAccounted = $true
                        if ([System.IO.File]::Exists($tempPng)) { try { [System.IO.File]::Delete($tempPng) } catch { } }
                        throw ($formatLabel + "->PNG pre-conversion did not exit within 120s - killed")
                    }
                    # Bounded the same way Test-AvifAnimated/
                    # Invoke-IccStripRetryOrFail already are (this pre-conversion
                    # detour and Controller.ps1's own documented-duplicate
                    # copy above follow the same rule). The
                    # WaitOne above only proves the PROCESS exited, not that
                    # its redirected stdout/stderr pipes reached EOF.
                    if (-not [System.Threading.Tasks.Task]::WaitAll(@($magickStdoutTask, $magickStderrTask), 15000)) {
                        $magickProc.Dispose()
                        $magickProcLocal = $null
                        Write-Log ("FAILED " + $formatLabel + "->PNG pre-conversion for '" + $job.SrcPath + "': magick exited but its output streams did not finish reading within 15s") -Level Error
                        $cr.FailedCount++
                        $failureAlreadyAccounted = $true
                        if ([System.IO.File]::Exists($tempPng)) { try { [System.IO.File]::Delete($tempPng) } catch { } }
                        throw ($formatLabel + "->PNG pre-conversion's output streams did not finish reading within 15s")
                    }
                    $null = $magickStdoutTask.GetAwaiter().GetResult()
                    $null = $magickStderrTask.GetAwaiter().GetResult()
                    $magickExitCode = $magickProc.ExitCode
                    $magickProc.Dispose()
                    $magickProcLocal = $null
                    if ($magickExitCode -ne 0 -or -not ([System.IO.File]::Exists($tempPng))) {
                        Write-Log ("FAILED " + $formatLabel + "->PNG pre-conversion for '" + $job.SrcPath + "': magick exited " + $magickExitCode) -Level Error
                        $cr.FailedCount++
                        $failureAlreadyAccounted = $true
                        if ([System.IO.File]::Exists($tempPng)) { try { [System.IO.File]::Delete($tempPng) } catch { } }
                        throw ($formatLabel + "->PNG pre-conversion failed")
                    }
                    $job.TempPng = $tempPng
                    $cjxlSrc     = $tempPng
                } else {
                    $job.TempPng = $null
                    $cjxlSrc     = $job.SrcPath
                }

                $isJpeg = ($cjxlSrc -imatch '\.jpe?g$')
                if ($isJpeg -and $JpegLossless) {
                    $psi.Arguments = "`"" + $cjxlSrc + "`" `"" + $job.JxlPath + "`" --lossless_jpeg=1 --num_threads=1"
                } elseif ($isJpeg) {
                    $psi.Arguments = "`"" + $cjxlSrc + "`" `"" + $job.JxlPath + "`" --lossless_jpeg=0 --quality=$JpegQuality --num_threads=1"
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
                if ($magickProcLocal) { try { if (-not $magickProcLocal.HasExited) { $magickProcLocal.Kill() }; $magickProcLocal.Dispose() } catch { } }
                if ($job.TempPng -and ([System.IO.File]::Exists($job.TempPng))) { try { [System.IO.File]::Delete($job.TempPng) } catch { } }
                elseif ($tempPngLocal -and ([System.IO.File]::Exists($tempPngLocal))) { try { [System.IO.File]::Delete($tempPngLocal) } catch { } }
                throw
            }
        }.GetNewClosure()

        $jobPollCompleted = { param($job) return $job.Proc.HasExited }

        $jobFinalize = {
            param($job, $pendingQueue)
            $cr = $chapterResults[$job.ChapterKey]
            return Complete-ImageDispatchJob -Job $job -ChapterResult $cr -PendingQueue $pendingQueue -MagickExe $MagickExe -DoFullLogging $FullLogging -ItemNoun "loose image" -SourceNoun "loose source image"
        }.GetNewClosure()

        $jobAbortCleanup = {
            param($job)
            if ($job.TempPng) { try { [System.IO.File]::Delete($job.TempPng) } catch { } }
            try { [System.IO.File]::Delete($job.JxlPath) } catch { }
            # DOCUMENTED DUPLICATE of AnimatedConversionPipeline.ps1's own
            # jobAbortCleanup ForceKilledCount increment - keep both in
            # sync. Feeds Get-ChapterProgressStatus (this file) so a
            # force-killed/never-started chapter reports as "N
            # force-stopped" instead of a false clean Success once
            # ChapterDispatch.ps1 invokes $ChapterCompleteCallback for it
            # (without this increment the force-stopped status branch below
            # would be dead code).
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
            $totals.DeletedSuccess     += $cr.DeletedCount
            $totals.DeletedFail        += $cr.DeleteFailedCount
            $totals.InspectFailedCount += $cr.InspectFailedCount
            foreach ($p in $cr.SkippedPaths) { $totals.LastSkippedPaths.Add($p) }

            $chapterStatus, $chapterDetail = Get-ChapterProgressStatus -ChapterResult $chapterResultForCallback

            if ($chapterInfo.HasNamingCollision -and $chapterStatus -ne 'Error') {
                $chapterStatus = 'Warning'
                $collisionNote = "naming collision: a source was left unconverted (see log)"
                $chapterDetail = if ($chapterDetail) { $chapterDetail + " | " + $collisionNote } else { $collisionNote }
            }

            if ($cleanConsoleOutputEnabled) {
                $null = Complete-ChapterProgress -SeriesName $chapterInfo.SeriesName -ChapterName $chapterInfo.ChapterName -Status $chapterStatus -Detail $chapterDetail
            }
            if ($null -ne $PostChapterCallback) {
                & $PostChapterCallback @{ SeriesName = $chapterInfo.SeriesName; ChapterName = $chapterInfo.ChapterName; Dir = $chapterInfo.Dir; ChapterResult = $chapterResultForCallback; HasNamingCollision = $chapterInfo.HasNamingCollision }
            }
            $null = $chapterResults.Remove($chapterInfo)
        }.GetNewClosure()

        # Hashtable, not a plain scalar - a plain $abortMessagePrinted
        # assigned inside this .GetNewClosure()'d scriptblock resets to
        # $false on every invocation instead of latching, so the once-only
        # guard wouldn't hold. Currently harmless either way (the
        # dispatch loop stops polling within an iteration or two of
        # Test-AbortSignal first returning true), but it would matter if
        # this poll callback were invoked more times after an abort. DOCUMENTED DUPLICATE: the identical pattern (same
        # fields, same reasoning) also appears in Controller.ps1's and
        # AnimatedConversionPipeline.ps1's own abort-poll callbacks - keep
        # all three in sync.
        $abortState = @{ MessagePrinted = $false }
        $abortPollCallback = {
            param($runningJobs)
            $aborted = Test-AbortSignal
            if ($aborted -and -not $abortState.MessagePrinted) {
                $abortState.MessagePrinted = $true
                if ($runningJobs.Count -gt 0) {
                    Write-GatedConsoleMessage -Text ("[ABORT] Waiting for current loose-image jobs to finish (up to " + $AbortTimeoutSeconds + "s)...") -Color Yellow -CleanConsoleOutputEnabled $cleanConsoleOutputEnabled
                }
            }
        }.GetNewClosure()

        $dispatchResult = Invoke-ChapterDispatch -ChapterProvider $chapterProvider -JobBuilder $jobBuilder `
            -JobStarter $jobStarter -JobPollCompleted $jobPollCompleted -JobFinalize $jobFinalize `
            -JobAbortCleanup $jobAbortCleanup -ChapterCompleteCallback $chapterCompleteCallback `
            -MaxConcurrent $MaxCjxlProcs -AbortPollCallback $abortPollCallback -CancelToken $looseCts.Token `
            -AbortTimeoutSeconds $AbortTimeoutSeconds -MaxQueueAhead $MaxQueueAhead

        $totals.ForceKilledCount = $dispatchResult.ForceKilledCount
        $totals.Aborted          = $dispatchResult.Aborted
    } finally {
        if ($looseCts) {
            Unregister-AbortCancellationSource -Cts $looseCts
            $looseCts.Dispose()
        }
        if ($script:CleanConsoleOutputEnabled) {
            $null = Complete-AllActiveSeriesProgress
        }
    }

    return $totals
}

function Get-ImageConversionSharedFunctionNames {
    return @('Invoke-IccStripRetryOrFail', 'Test-AvifAnimated', 'Get-NeverConvertedExtensions', 'Test-WebPAnimated',
             'Invoke-SeriesCoverNormalization', 'Get-SeriesCoverConvertibleExtensions')
}
