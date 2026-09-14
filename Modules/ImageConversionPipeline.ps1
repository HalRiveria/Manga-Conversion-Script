# See Docs/module-descriptions.md for this module's full description.

# ==============================================================================
#  PART 1 - Convert-ImageBatch, the per-batch conversion engine
# ==============================================================================

function Get-LooseImageExtensions {
    return @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif", ".gif", ".bmp", ".heic", ".heif")
}

function Test-OrphanedScratchFileName {
    param([Parameter(Mandatory)][string]$Name)
    return (
        $Name -imatch '_tmp_iccstrip(-\d+)?\.png$' -or
        $Name -imatch '_tmp_(webp|avif|bmp|heic|heif)2png\.png$' -or
        $Name -imatch '_tmp_overwrite\.webp$'
    )
}

function Get-NeverConvertedExtensions {
    return @(".gif")
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
    $stripPsi.Arguments              = "`"" + $Job.SrcPath + "`" -strip `"" + $strippedPng + "`""
    $stripPsi.UseShellExecute        = $false
    $stripPsi.RedirectStandardOutput = $true
    $stripPsi.RedirectStandardError  = $true
    $stripPsi.CreateNoWindow         = $true
    try {
        $stripProc = [System.Diagnostics.Process]::Start($stripPsi)
    } catch {
        Write-Log ("Could not start ICC-strip retry process for '" + $Job.SrcPath + "': " + $_) -Level Error
        return $false
    }
    # DOCUMENTED DUPLICATE: Test-AvifAnimated in
    # AnimatedConversionPipeline.ps1 uses the identical raw-handle-wait
    # pattern below - keep both in sync.
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

        $null = $stripStdoutTask.GetAwaiter().GetResult()
        $null = $stripStderrTask.GetAwaiter().GetResult()
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

function Complete-ImageConversionJob {
    # DOCUMENTED DUPLICATE: everything below the try/finally is copied,
    # not shared, into Complete-ImageDispatchJob - see that function's
    # own header. Keep both in sync if either changes.
    param(
        [Parameter(Mandatory)]
        [hashtable]$Job,
        [Parameter(Mandatory)]
        [hashtable]$BatchResult,
        [Parameter(Mandatory)]
        [System.Collections.Queue]$Pending,
        [string]$MagickExe,
        [bool]$DoFullLogging,
        [string]$ItemNoun   = "image",
        [string]$SourceNoun = "source image",
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
        Write-Log ("cjxl stdout for '" + $Job.SrcPath + "': " + $stdout.Trim())
    }

    $convOk = $false
    try {
        if ($code -ne 0) {
            if ($code -eq 1 -and $stderr -imatch 'Getting pixel data failed' -and $MagickExe -and -not $Job.IccRetried) {
                if (Invoke-IccStripRetryOrFail -Job $Job -Pending $Pending -MagickExe $MagickExe) {
                    if ($Job.TempPng -and [System.IO.File]::Exists($Job.TempPng)) { try { [System.IO.File]::Delete($Job.TempPng) } catch { } }
                    return $true
                }
            }
            throw ("cjxl exited with code " + $code + ". Stderr: " + $stderr)
        }
        if (-not [System.IO.File]::Exists($Job.JxlPath)) { throw ("Output .jxl was not created: '" + $Job.JxlPath + "'") }
        $jxlSize = [System.IO.FileInfo]::new($Job.JxlPath).Length
        if ($jxlSize -eq 0) { throw ("Output .jxl is 0 bytes: '" + $Job.JxlPath + "'") }
        if ($IsAbortDrain) {
            Write-Log ("Conversion OK (abort drain): '" + $Job.JxlPath + "'")
        } else {
            Write-Log ("Conversion OK: '" + $Job.JxlPath + "' (" + $jxlSize + " bytes)")
        }
        $BatchResult.ConvertedCount++
        $BatchResult.ConvertedPaths.Add($Job.SrcPath)
        $convOk = $true
    } catch {
        Write-Log ("FAILED conversion of " + $ItemNoun + " '" + $Job.SrcPath + "': " + $_) -Level Error
        $BatchResult.FailedCount++
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
                $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
                Write-Log ("Deleted " + $SourceNoun + " (" + $deleteDesc + "): '" + $Job.SrcPath + "'")
                $BatchResult.DeletedCount++
            } else {
                Write-Log ($SourceNoun.Substring(0,1).ToUpperInvariant() + $SourceNoun.Substring(1) + " already gone before deletion (not counted as deleted): '" + $Job.SrcPath + "'") -Level Warn
            }
        } catch {
            Write-Log ("FAILED to delete " + $SourceNoun + " '" + $Job.SrcPath + "': " + $_) -Level Error
            $BatchResult.DeleteFailedCount++
        }
    }

    return $false
}

function Complete-ImageDispatchJob {
    # DOCUMENTED DUPLICATE, not a call-through, of
    # Complete-ImageConversionJob's own exit-code/ICC-retry-decision/
    # delete-source logic - see that function's own header. Keep both
    # in sync if either changes.
    param(
        [Parameter(Mandatory)]
        [hashtable]$Job,
        [Parameter(Mandatory)]
        [hashtable]$ChapterResult,
        [System.Collections.Generic.Queue[hashtable]]$PendingQueue,
        [string]$MagickExe,
        [bool]$DoFullLogging,
        [string]$ItemNoun   = "image",
        [string]$SourceNoun = "source image"
    )

    $stdout = if ($Job.StdoutTask) { $Job.StdoutTask.GetAwaiter().GetResult() } else { $Job.Proc.StandardOutput.ReadToEnd() }
    $stderr = if ($Job.StderrTask) { $Job.StderrTask.GetAwaiter().GetResult() } else { $Job.Proc.StandardError.ReadToEnd() }
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
        if (-not [System.IO.File]::Exists($Job.JxlPath)) { throw ("Output .jxl was not created: '" + $Job.JxlPath + "'") }
        $jxlSize = [System.IO.FileInfo]::new($Job.JxlPath).Length
        if ($jxlSize -eq 0) { throw ("Output .jxl is 0 bytes: '" + $Job.JxlPath + "'") }
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
                $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
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

function Convert-ImageBatch {
    param(
        [System.IO.FileInfo[]]$ImageFiles,
        [Parameter(Mandatory)]
        [string]$CjxlExe,
        [string]$MagickExe,
        [bool]$DoJpegLossless,
        [int]$DoJpegQuality = 90,
        [Parameter(Mandatory)]
        [int]$MaxCjxlProcs,
        [bool]$DoFullLogging,
        [Parameter(Mandatory)]
        [System.Threading.CancellationToken]$CancelToken,
        [string]$ItemNoun               = "image",
        [string]$SourceNoun             = "source image",
        [string]$BatchLabel             = $null,
        [string]$AbortWaitMessage       = $null,
        [scriptblock]$AbortPollCallback = $null,
        [int]$AbortTimeoutSeconds       = 60,
        [System.Collections.Generic.HashSet[string]]$KnownStaticPaths = $null
    )

    $batchResult = @{
        ConvertedCount     = 0
        FailedCount        = 0
        SkippedCount       = 0
        DeletedCount       = 0
        DeleteFailedCount  = 0
        ConvertedPaths     = [System.Collections.Generic.List[string]]::new()
        SkippedPaths       = [System.Collections.Generic.List[string]]::new()
        PendingPaths       = [System.Collections.Generic.List[string]]::new()
        ForceKilledCount   = 0
        InspectFailedCount = 0
    }

    if (-not $ImageFiles -or $ImageFiles.Count -eq 0) { return $batchResult }

    $allJobs = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($img in $ImageFiles) {
        $srcPath = $img.FullName
        if ($CancelToken.IsCancellationRequested) {
            $batchResult.PendingPaths.Add($srcPath)
            continue
        }
        if ((Get-NeverConvertedExtensions) -icontains [System.IO.Path]::GetExtension($srcPath)) {
            Write-Log ("SKIPPING '" + $srcPath + "': not converted by this project (see Get-NeverConvertedExtensions's own comment for why). File left untouched.") -Level Warn
            $batchResult.SkippedCount++
            $batchResult.SkippedPaths.Add($srcPath)
            continue
        }
        if ($MagickExe -and $srcPath -imatch '\.webp$') {
            $isAnimatedWebp = $false
            try {
                $isAnimatedWebp = Test-WebPAnimated -WebPPath $srcPath
            } catch {
                Write-Log ("FAILED to read '" + $srcPath + "' to check for WebP animation: " + $_) -Level Error
                $batchResult.FailedCount++
                continue
            }
            if ($isAnimatedWebp) {
                Write-Log ("SKIPPING animated WebP '" + $srcPath + "': Animation flag set in VP8X chunk - animated WebP cannot be converted to JXL (no multi-frame support). File left untouched.") -Level Warn
                $batchResult.SkippedCount++
                $batchResult.SkippedPaths.Add($srcPath)
                continue
            }
        } elseif ($MagickExe -and $srcPath -imatch '\.avif$') {
            if (-not ($KnownStaticPaths -and $KnownStaticPaths.Contains($srcPath))) {
                try {
                    $isAnimatedAvif = Test-AvifAnimated -AvifPath $srcPath -MagickExe $MagickExe
                } catch {
                    Write-Log ("Could not determine if AVIF '" + $srcPath + "' is animated - skipping: " + $_) -Level Warn
                    $batchResult.InspectFailedCount++
                    continue
                }
                if ($isAnimatedAvif) {
                    Write-Log ("SKIPPING animated AVIF '" + $srcPath + "': has its own conversion pipeline (AnimatedConversionPipeline.ps1) - not converted here.") -Level Warn
                    $batchResult.SkippedCount++
                    $batchResult.SkippedPaths.Add($srcPath)
                    continue
                }
            }
        }
        # DOCUMENTED DUPLICATE: this same format-label switch is copied at
        # job-build time in Invoke-LooseImageConversionPipeline's own
        # JobBuilder (ImageConversionPipeline.ps1) and in Controller.ps1's
        # image-engine JobBuilder - keep all three in sync if the set of
        # magick-detour formats ever changes.
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
            $batchResult.FailedCount++
        } else {
            $jobs.Add($j)
        }
    }

    $pending = [System.Collections.Queue]::new()
    foreach ($j in $jobs) { $pending.Enqueue($j) }
    $running = [System.Collections.Generic.List[hashtable]]::new()

    try {
    while (($pending.Count -gt 0 -or $running.Count -gt 0) -and (-not $CancelToken.IsCancellationRequested)) {

        if ($AbortPollCallback) {
            $inFlight = [System.Collections.Generic.List[string]]::new()
            foreach ($r in $running) { $inFlight.Add($r.SrcPath) }
            & $AbortPollCallback $inFlight
        }

        while ($pending.Count -gt 0 -and (-not $CancelToken.IsCancellationRequested) -and `
               $running.Count -lt $MaxCjxlProcs) {
            $j   = $pending.Dequeue()
            $magickProcLocal = $null
            $tempPngLocal = $null
            try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName               = $CjxlExe
            $psi.UseShellExecute        = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow         = $true

            if ($j.TempPng) {
                $cjxlSrc = $j.TempPng
            } elseif ($j.FormatLabel) {
                $formatLabel = $j.FormatLabel
                if (-not $MagickExe) {
                    Write-Log ("SKIPPING " + $formatLabel + " '" + $j.SrcPath + "': ImageMagick not found. Install ImageMagick or pass -MagickPath.") -Level Error
                    $batchResult.FailedCount++
                    continue
                }

                $tempPng = [System.IO.Path]::Combine(
                    [System.IO.Path]::GetDirectoryName($j.SrcPath),
                    [System.IO.Path]::GetFileNameWithoutExtension($j.SrcPath) + "_tmp_" + $formatLabel.ToLowerInvariant() + "2png.png"
                )
                $tempPngLocal = $tempPng
                $magickPsi = [System.Diagnostics.ProcessStartInfo]::new()
                $magickPsi.FileName               = $MagickExe
                $magickPsi.Arguments              = "`"" + $j.SrcPath + "[0]`" `"" + $tempPng + "`""
                $magickPsi.UseShellExecute        = $false
                $magickPsi.RedirectStandardOutput = $true
                $magickPsi.RedirectStandardError  = $true
                $magickPsi.CreateNoWindow         = $true
                $magickProc = [System.Diagnostics.Process]::Start($magickPsi)
                $magickProcLocal = $magickProc
                $magickStdoutTask = $magickProc.StandardOutput.ReadToEndAsync()
                $magickStderrTask = $magickProc.StandardError.ReadToEndAsync()
                $magickProc.WaitForExit()
                $null = $magickStdoutTask.GetAwaiter().GetResult()
                $null = $magickStderrTask.GetAwaiter().GetResult()
                $magickExitCode = $magickProc.ExitCode
                $magickProc.Dispose()
                $magickProcLocal = $null
                if ($magickExitCode -ne 0 -or -not ([System.IO.File]::Exists($tempPng))) {
                    Write-Log ("FAILED " + $formatLabel + "->PNG pre-conversion for '" + $j.SrcPath + "': magick exited " + $magickExitCode) -Level Error
                    $batchResult.FailedCount++
                    if ([System.IO.File]::Exists($tempPng)) { try { [System.IO.File]::Delete($tempPng) } catch { } }
                    continue
                }
                $j.TempPng = $tempPng
                $cjxlSrc   = $tempPng
            } else {
                $j.TempPng = $null
                $cjxlSrc   = $j.SrcPath
            }

            $isJpeg = ($cjxlSrc -imatch '\.jpe?g$')
            if ($isJpeg -and $DoJpegLossless) {
                $psi.Arguments = "`"" + $cjxlSrc + "`" `"" + $j.JxlPath + "`" --lossless_jpeg=1 --num_threads=1"
            } elseif ($isJpeg) {
                $psi.Arguments = "`"" + $cjxlSrc + "`" `"" + $j.JxlPath + "`" --lossless_jpeg=0 --quality=$DoJpegQuality --num_threads=1"
            } else {
                $psi.Arguments = "`"" + $cjxlSrc + "`" `"" + $j.JxlPath + "`" --lossless_jpeg=0 --quality=90 --num_threads=1"
            }

            Write-Log ("Converting " + $ItemNoun + ": '" + $j.SrcPath + "'")

            $j.Proc = [System.Diagnostics.Process]::Start($psi)
            $j.StdoutTask = $j.Proc.StandardOutput.ReadToEndAsync()
            $j.StderrTask = $j.Proc.StandardError.ReadToEndAsync()
            $running.Add($j)
            } catch {
                Write-Log ("FAILED to start conversion process for '" + $j.SrcPath + "': " + $_) -Level Error
                $batchResult.FailedCount++
                if ($magickProcLocal) { try { if (-not $magickProcLocal.HasExited) { $magickProcLocal.Kill() }; $magickProcLocal.Dispose() } catch { } }
                if ($j.TempPng -and ([System.IO.File]::Exists($j.TempPng))) { try { [System.IO.File]::Delete($j.TempPng) } catch { } }
                elseif ($tempPngLocal -and ([System.IO.File]::Exists($tempPngLocal))) { try { [System.IO.File]::Delete($tempPngLocal) } catch { } }
            }
        }

        $stillRunning = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($j in $running) {
            if ($j.Proc.HasExited) {
                if (Complete-ImageConversionJob -Job $j -BatchResult $batchResult -Pending $pending -MagickExe $MagickExe -DoFullLogging $DoFullLogging -ItemNoun $ItemNoun -SourceNoun $SourceNoun) {
                    continue
                }
            } else {
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
            if ($j.TempPng -and ([System.IO.File]::Exists($j.TempPng))) {
                try { [System.IO.File]::Delete($j.TempPng) } catch { }
            }
            if ((-not $j.SlotReleased) -and ([System.IO.File]::Exists($j.JxlPath))) {
                try { [System.IO.File]::Delete($j.JxlPath) } catch { }
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
                        if (Complete-ImageConversionJob -Job $j -BatchResult $batchResult -Pending $pending -MagickExe $MagickExe -DoFullLogging $DoFullLogging -ItemNoun $ItemNoun -SourceNoun $SourceNoun -IsAbortDrain $true) {
                            continue
                        }
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
                        if (Complete-ImageConversionJob -Job $j -BatchResult $batchResult -Pending $pending -MagickExe $MagickExe -DoFullLogging $DoFullLogging -ItemNoun $ItemNoun -SourceNoun $SourceNoun -IsAbortDrain $true) {
                            continue
                        }
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
                    if ($j.TempPng -and ([System.IO.File]::Exists($j.TempPng))) {
                        try { [System.IO.File]::Delete($j.TempPng) } catch { }
                    }
                    if ([System.IO.File]::Exists($j.JxlPath)) {
                        try { [System.IO.File]::Delete($j.JxlPath) } catch { }
                    }
                    $j.Proc.Dispose()
                    $j.SlotReleased = $true
                }
            }
        } catch {
            foreach ($j in $running) {
                try { if ($j.Proc -and -not $j.Proc.HasExited) { $j.Proc.Kill() } } catch { }
                try { if ($j.Proc) { $j.Proc.WaitForExit(5000) } } catch { }
                if ($j.TempPng -and ([System.IO.File]::Exists($j.TempPng))) {
                    try { [System.IO.File]::Delete($j.TempPng) } catch { }
                }
                if ((-not $j.SlotReleased) -and ([System.IO.File]::Exists($j.JxlPath))) {
                    try { [System.IO.File]::Delete($j.JxlPath) } catch { }
                }
                try { if ($j.Proc) { $j.Proc.Dispose() } } catch { }
            }
            throw
        }
    }

    foreach ($j in $pending.ToArray()) {
        $batchResult.PendingPaths.Add($j.SrcPath)
        if ($j.TempPng -and ([System.IO.File]::Exists($j.TempPng))) { try { [System.IO.File]::Delete($j.TempPng) } catch { } }
    }

    return $batchResult
}

# ==============================================================================
#  PART 2 - mode 1/2 orchestration
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
                $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
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
        [scriptblock]$ZipStepCallback = $null,
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

        $seriesProvider  = New-SeriesProvider -LibraryPath $Path
        $chapterQueue    = [System.Collections.Generic.Queue[hashtable]]::new()
        $seriesExhausted = $false
        $chapterProvider = {
            while ($chapterQueue.Count -eq 0 -and -not $seriesExhausted) {
                if (Test-AbortSignal) { $seriesExhausted = $true; break }

                $series = & $seriesProvider
                if ($null -eq $series) { $seriesExhausted = $true; break }
                $totals.SeriesCount++

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
                        SeriesName = $series.Name; ChapterName = $c.Dir.Name; Dir = $c.Dir; ZipOut = $c.ZipOut
                        IsZippable = (-not $namingCollisionDirs.Contains($c.Dir.FullName)); IsExtra = $false
                        Images = $chapterImages
                    })
                    $seriesChapterCount++
                }
                foreach ($extraDirPath in $imagesByDir.Keys) {
                    if ($chapterDirSet.Contains($extraDirPath)) { continue }
                    $extraDir = $imagesByDir[$extraDirPath][0].Directory
                    $chapterQueue.Enqueue(@{
                        SeriesName = $series.Name; ChapterName = $extraDir.Name; Dir = $extraDir; ZipOut = $null
                        IsZippable = $false; IsExtra = $true
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
                InspectFailedCount = 0
                SkippedPaths = [System.Collections.Generic.List[string]]::new()
                TotalFiles = $chapterInfo.Images.Count
            }
            $chapterResults[$chapterInfo] = $cr

            if ($cleanConsoleOutputEnabled) {
                Start-ChapterProgress -SeriesName $chapterInfo.SeriesName -ChapterName $chapterInfo.ChapterName
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
                } elseif ($MagickExe -and $srcPath -imatch '\.avif$') {
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
                # copied at job-build time in Convert-ImageBatch's own
                # pre-pass (ImageConversionPipeline.ps1) and in
                # Controller.ps1's image-engine JobBuilder - keep all
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
                    $magickProc.WaitForExit()
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
        }

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

            if ($null -ne $ZipStepCallback -and $chapterInfo.IsZippable -and $chapterStatus -ne 'Error') {
                $zipOutcome = & $ZipStepCallback @{ SeriesName = $chapterInfo.SeriesName; ChapterName = $chapterInfo.ChapterName; Dir = $chapterInfo.Dir; ChapterResult = $chapterResultForCallback; ZipOut = $chapterInfo.ZipOut }
                if ($null -ne $zipOutcome) {
                    $zipSeverity = switch ($zipOutcome.Status) { 'Fail' { 2 }; 'Skipped' { 1 }; default { 0 } }
                    $chapterRank = @{ Success = 0; Warning = 1; Error = 2 }
                    if ($zipSeverity -gt $chapterRank[$chapterStatus]) {
                        $chapterStatus = switch ($zipSeverity) { 2 { 'Error' }; 1 { 'Warning' }; default { 'Success' } }
                    }
                    $convertDetailPart = if ($chapterDetail) { "Convert: " + $chapterDetail } else { "Convert: OK" }
                    $zipDetailPart     = "Zip: " + $(if ($zipOutcome.Detail) { $zipOutcome.Detail } else { $zipOutcome.Status })
                    $chapterDetail     = $convertDetailPart + " | " + $zipDetailPart
                }
            }

            if ((-not $chapterInfo.IsZippable) -and (-not $chapterInfo.IsExtra)) {
                $chapterStatus, $chapterDetail = Get-ZipBlockedStatusOverride -Status $chapterStatus -Detail $chapterDetail -BlockedReason "naming collision"
            }

            if ($cleanConsoleOutputEnabled) {
                $null = Complete-ChapterProgress -SeriesName $chapterInfo.SeriesName -ChapterName $chapterInfo.ChapterName -Status $chapterStatus -Detail $chapterDetail
            }
            if ($null -ne $PostChapterCallback) {
                & $PostChapterCallback @{ SeriesName = $chapterInfo.SeriesName; ChapterName = $chapterInfo.ChapterName; Dir = $chapterInfo.Dir; ChapterResult = $chapterResultForCallback; ZipOut = $chapterInfo.ZipOut; IsZippable = $chapterInfo.IsZippable }
            }
            $null = $chapterResults.Remove($chapterInfo)
        }.GetNewClosure()

        $abortMessagePrinted = $false
        $abortPollCallback = {
            param($runningJobs)
            $aborted = Test-AbortSignal
            if ($aborted -and -not $abortMessagePrinted) {
                $abortMessagePrinted = $true
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
    return @('Convert-ImageBatch', 'Complete-ImageConversionJob', 'Invoke-IccStripRetryOrFail', 'Test-AvifAnimated', 'Get-NeverConvertedExtensions', 'Test-WebPAnimated')
}
