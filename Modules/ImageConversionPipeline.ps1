<#
.SYNOPSIS
    ImageConversionPipeline - the shared image-conversion engine and mode
    1/2 orchestration. This module literally IS mode 1; mode 2 is this
    module plus an extra per-folder zip step layered on top (owned by
    ZipPipeline.ps1, not here - see that module's PART 2).

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules.

    ARCHITECTURE (per the reference extraction's explicit decision, and an
    earlier correction in this project's history - there is no separate
    "LooseConversionPipeline" module; don't recreate one):
      - Mode 1 (loose-only) IS this module, nothing else.
      - Mode 2 (loose+zip) is this module PLUS ZipPipeline.ps1's per-folder
        zip step, wired in via -PostBatchCallback (see
        Invoke-LooseImageConversionPipeline) rather than this module
        calling into ZipPipeline.ps1 directly - keeps this module decoupled
        from zip-domain logic, matching Convert-ImageBatch's own existing
        -AbortPollCallback precedent for the same kind of hook.
      - Mode 4 calls Convert-ImageBatch (PART 1) per-ZIP from inside its
        own worker - already the same shared function, nothing to change.
      - Mode 3 doesn't convert anything, not involved.

    NOT owned here (see Summary.reference.ps1 instead): the mode 1/2
    abort-path summary text. This module's orchestration function returns
    enough structured data (last-completed/skipped paths, still-pending
    paths, per-category totals) for a future Summary module to build that
    text - it does not build the text itself, matching the reference
    extraction's explicit note on this.

    FORWARD REFERENCES (not defined in this module - callers must
    dot-source the owning module(s) first):
      - Write-Log (Logging.ps1)
      - Remove-Source, $script:PermanentDelete (FileDeletion.ps1)
      - Test-AbortSignal (AbortPipeline.ps1)
      - Get-ZippableLeafDirs (LeafDirectoryDiscovery.ps1) - only needed
        when Invoke-LooseImageConversionPipeline is called with
        -PerFolderBatching $true (mode 2's per-folder scoping)
    Modules\_Harness\ImageConversionPipeline.Harness.ps1 dot-sources the
    real Logging.ps1/FileDeletion.ps1/AbortPipeline.ps1/
    LeafDirectoryDiscovery.ps1, and compiles a small real stand-in
    executable (via Add-Type -OutputType ConsoleApplication) to serve as
    $CjxlExe/$MagickExe - Convert-ImageBatch spawns real OS processes via
    System.Diagnostics.Process, so a genuine (if fake) executable is used
    rather than mocking the process layer away.

    PART 1 (Convert-ImageBatch) NOTE: its parallelism is its own, separate
    from ZipParallelProcessing.ps1 and AbortPipeline.ps1 - it dispatches
    raw cjxl.exe/magick.exe OS processes via ProcessStartInfo, not
    PowerShell runspaces, with its own independent wait-then-force-stop
    abort-drain (Process.Kill(), not PS.Stop()). This is a fourth distinct
    implementation of the same "wait then force-stop" shape in this
    codebase (the others: ZipParallelProcessing, the main script's inline
    mode-4 copy, AbortPipeline.ps1's rewrite) - cannot plug into
    Invoke-GracefulDrain as-is since that's built around [PowerShell]/
    Handle pairs, not System.Diagnostics.Process.

    -AbortTimeoutSeconds on Convert-ImageBatch is a small addition beyond
    the original extraction (which hardcoded 60s) - defaults to 60,
    preserving existing behavior, but lets a test harness use a short
    value instead of waiting out a real 60s drain, matching the same
    fix already applied to AbortPipeline.ps1's Invoke-GracefulDrain.

.NOTES
    Extracted from Conversion Script Main.ps1 - see
    Modules\_Reference\ImageConversionPipeline.reference.ps1 for the
    verbatim source this was built from, with original line numbers.
#>

# ==============================================================================
#  PART 1 - Convert-ImageBatch, the per-batch conversion engine
# ==============================================================================

function Convert-ImageBatch {
    <#
    .SYNOPSIS
        Converts a batch of image files to .jxl via $CjxlExe (WebP inputs
        are pre-converted to PNG via $MagickExe first; a PNG whose ICC
        profile mismatches its actual pixel format is retried once with
        the profile stripped). Dispatches up to $MaxCjxlProcs processes in
        parallel, deletes each source on a successful conversion, and
        gracefully drains (then force-kills stragglers) on cancellation.
    .OUTPUTS
        @{ ConvertedCount; FailedCount; SkippedCount; DeletedCount;
           DeleteFailedCount; ConvertedPaths; SkippedPaths; PendingPaths;
           ForceKilledCount }
    #>
    param(
        [System.IO.FileInfo[]]$ImageFiles,
        [Parameter(Mandatory)]
        [string]$CjxlExe,
        [string]$MagickExe,
        [bool]$DoJpegLossless,
        [int]$DoJpegQuality,
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
        [int]$AbortTimeoutSeconds       = 60
    )

    $batchResult = @{
        ConvertedCount    = 0
        FailedCount       = 0
        SkippedCount      = 0
        DeletedCount      = 0
        DeleteFailedCount = 0
        ConvertedPaths    = [System.Collections.Generic.List[string]]::new()
        SkippedPaths      = [System.Collections.Generic.List[string]]::new()
        PendingPaths      = [System.Collections.Generic.List[string]]::new()
        ForceKilledCount  = 0
    }

    if (-not $ImageFiles -or $ImageFiles.Count -eq 0) { return $batchResult }

    # Build job list, skipping output-path collisions (e.g. "photo.jpg" and
    # "photo.webp" both mapping to "photo.jxl" - converting both would let one
    # silently overwrite the other's output while both sources get deleted).
    $allJobs = foreach ($img in $ImageFiles) {
        @{
            SrcPath = $img.FullName
            JxlPath = [System.IO.Path]::ChangeExtension($img.FullName, ".jxl")
            Proc    = $null
            TempPng = $null
        }
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

    while (($pending.Count -gt 0 -or $running.Count -gt 0) -and (-not $CancelToken.IsCancellationRequested)) {

        if ($AbortPollCallback) {
            $inFlight = @($running | ForEach-Object { $_.SrcPath })
            & $AbortPollCallback $inFlight
        }

        # Fill up to MaxCjxlProcs slots
        while ($pending.Count -gt 0 -and $running.Count -lt $MaxCjxlProcs -and (-not $CancelToken.IsCancellationRequested)) {
            $j   = $pending.Dequeue()
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName               = $CjxlExe
            $psi.UseShellExecute        = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow         = $true

            # cjxl 0.11.x cannot read WebP directly - transcode to a temp PNG first.
            # Animated WebPs are skipped entirely (cjxl has no multi-frame support).
            $isWebp = ($j.SrcPath -imatch '\.webp$')
            if ($isWebp) {
                if (-not $MagickExe) {
                    Write-Log ("SKIPPING WebP '" + $j.SrcPath + "': ImageMagick not found. Install ImageMagick or pass -MagickPath.") -Level Error
                    $batchResult.FailedCount++
                    continue
                }

                # --- Animated WebP check (VP8X chunk, no process spawn) ---
                # Animated WebPs carry a VP8X extended-format chunk at offset 12.
                # Bit 1 (0x02) of its flags field (offset 20) is the Animation flag.
                # Simple lossy (VP8 ) and lossless (VP8L) files cannot be animated.
                $webpBytes  = [System.IO.File]::ReadAllBytes($j.SrcPath)
                $isAnimated = $false
                if ($webpBytes.Length -ge 24) {
                    $chunkId = [System.Text.Encoding]::ASCII.GetString($webpBytes, 12, 4)
                    if ($chunkId -eq 'VP8X') {
                        $flags      = [System.BitConverter]::ToUInt32($webpBytes, 20)
                        $isAnimated = ($flags -band 0x02) -ne 0
                    }
                }

                if ($isAnimated) {
                    Write-Log ("SKIPPING animated WebP '" + $j.SrcPath + "': Animation flag set in VP8X chunk - animated WebP cannot be converted to JXL (no multi-frame support). File left untouched.") -Level Warn
                    $batchResult.SkippedCount++
                    $batchResult.SkippedPaths.Add($j.SrcPath)
                    continue
                }
                # --- End animated WebP check ---

                $tempPng = [System.IO.Path]::Combine(
                    [System.IO.Path]::GetDirectoryName($j.SrcPath),
                    [System.IO.Path]::GetFileNameWithoutExtension($j.SrcPath) + "_tmp_webp2png.png"
                )
                $magickPsi = New-Object System.Diagnostics.ProcessStartInfo
                $magickPsi.FileName               = $MagickExe
                $magickPsi.Arguments              = "`"" + $j.SrcPath + "[0]`" `"" + $tempPng + "`""
                $magickPsi.UseShellExecute        = $false
                $magickPsi.RedirectStandardOutput = $true
                $magickPsi.RedirectStandardError  = $true
                $magickPsi.CreateNoWindow         = $true
                $magickProc = [System.Diagnostics.Process]::Start($magickPsi)
                $magickProc.WaitForExit()
                $magickExitCode = $magickProc.ExitCode
                $magickProc.Dispose()
                if ($magickExitCode -ne 0 -or -not (Test-Path -LiteralPath $tempPng)) {
                    Write-Log ("FAILED WebP->PNG pre-conversion for '" + $j.SrcPath + "': magick exited " + $magickExitCode) -Level Error
                    $batchResult.FailedCount++
                    if (Test-Path -LiteralPath $tempPng) { try { [System.IO.File]::Delete($tempPng) } catch { } }
                    continue
                }
                $j.TempPng = $tempPng
                $cjxlSrc   = $tempPng
            } elseif ($j.TempPng) {
                # Retry job: TempPng already points to a pre-processed PNG
                # (e.g. ICC-stripped). Use it directly as the cjxl source;
                # do not overwrite TempPng so cleanup logic still fires.
                $cjxlSrc = $j.TempPng
            } else {
                $j.TempPng = $null
                $cjxlSrc   = $j.SrcPath
            }

            # JPEG encoding: controlled by the -DoJpegLossless / -DoJpegQuality params.
            # Non-JPEGs (PNG/WebP/TIFF): always lossy at quality 90.
            $isJpeg = ($cjxlSrc -imatch '\.jpe?g$')
            if ($isJpeg -and $DoJpegLossless) {
                $psi.Arguments = "`"" + $cjxlSrc + "`" `"" + $j.JxlPath + "`" --lossless_jpeg=1"
            } elseif ($isJpeg) {
                $psi.Arguments = "`"" + $cjxlSrc + "`" `"" + $j.JxlPath + "`" --lossless_jpeg=0 --quality=$DoJpegQuality"
            } else {
                $psi.Arguments = "`"" + $cjxlSrc + "`" `"" + $j.JxlPath + "`" --lossless_jpeg=0 --quality=90"
            }

            Write-Log ("Converting " + $ItemNoun + ": '" + $j.SrcPath + "'")

            $j.Proc = [System.Diagnostics.Process]::Start($psi)
            $running.Add($j)
        }

        # Poll for finished processes
        $stillRunning = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($j in $running) {
            if ($j.Proc.HasExited) {
                $stdout = $j.Proc.StandardOutput.ReadToEnd()
                $stderr = $j.Proc.StandardError.ReadToEnd()
                $code   = $j.Proc.ExitCode
                $j.Proc.Dispose()

                if ($DoFullLogging -and -not [string]::IsNullOrWhiteSpace($stdout)) {
                    Write-Log ("cjxl stdout for '" + $j.SrcPath + "': " + $stdout.Trim())
                }

                $convOk = $false
                try {
                    if ($code -ne 0) {
                        # --- ICC profile mismatch retry ---
                        # cjxl 0.11.x rejects PNGs whose embedded ICC profile
                        # declares RGB colorspace but whose pixel data is
                        # grayscale (libpng warning: "RGB color space not
                        # permitted on grayscale PNG", followed by "Getting
                        # pixel data failed"). Strip the profile via ImageMagick
                        # and re-enqueue the job rather than counting it failed.
                        if ($code -eq 1 -and $stderr -imatch 'Getting pixel data failed' -and $MagickExe) {
                            $strippedPng = [System.IO.Path]::Combine(
                                [System.IO.Path]::GetDirectoryName($j.SrcPath),
                                [System.IO.Path]::GetFileNameWithoutExtension($j.SrcPath) + "_tmp_iccstrip.png"
                            )
                            Write-Log ("ICC profile mismatch on '" + $j.SrcPath + "' - stripping profile and retrying.") -Level Warn
                            $stripPsi = New-Object System.Diagnostics.ProcessStartInfo
                            $stripPsi.FileName               = $MagickExe
                            $stripPsi.Arguments              = "`"" + $j.SrcPath + "`" -colorspace Gray -strip `"" + $strippedPng + "`""
                            $stripPsi.UseShellExecute        = $false
                            $stripPsi.RedirectStandardOutput = $true
                            $stripPsi.RedirectStandardError  = $true
                            $stripPsi.CreateNoWindow         = $true
                            $stripProc = [System.Diagnostics.Process]::Start($stripPsi)
                            $stripProc.WaitForExit()
                            $stripExitCode = $stripProc.ExitCode
                            $stripProc.Dispose()
                            if ($stripExitCode -eq 0 -and (Test-Path -LiteralPath $strippedPng)) {
                                # Cancel/abort may be in progress - the dispatch loop won't
                                # run again in that case, so this retry will simply be
                                # picked up by the stragglers drain below (or left for the
                                # next run). Enqueue unconditionally either way.
                                $retryJob = @{
                                    SrcPath = $j.SrcPath
                                    JxlPath = $j.JxlPath
                                    Proc    = $null
                                    TempPng = $strippedPng
                                }
                                $pending.Enqueue($retryJob)
                                if (Test-Path -LiteralPath $strippedPng) { try { [System.IO.File]::Delete($strippedPng) } catch { } }
                                continue
                            } else {
                                Write-Log ("ICC strip failed for '" + $j.SrcPath + "': magick exited " + $stripExitCode + " - counting as conversion failure.") -Level Error
                                if (Test-Path -LiteralPath $strippedPng) { try { [System.IO.File]::Delete($strippedPng) } catch { } }
                            }
                        }
                        throw ("cjxl exited with code " + $code + ". Stderr: " + $stderr)
                    }
                    if (-not (Test-Path -LiteralPath $j.JxlPath)) { throw ("Output .jxl was not created: '" + $j.JxlPath + "'") }
                    $jxlSize = (Get-Item -LiteralPath $j.JxlPath).Length
                    if ($jxlSize -eq 0) { throw ("Output .jxl is 0 bytes: '" + $j.JxlPath + "'") }
                    Write-Log ("Conversion OK: '" + $j.JxlPath + "' (" + $jxlSize + " bytes)")
                    $batchResult.ConvertedCount++
                    $batchResult.ConvertedPaths.Add($j.SrcPath)
                    $convOk = $true
                } catch {
                    Write-Log ("FAILED conversion of " + $ItemNoun + " '" + $j.SrcPath + "': " + $_) -Level Error
                    $batchResult.FailedCount++
                }

                # Clean up the temporary PNG used for WebP/ICC-strip pre-conversion
                if ($j.TempPng -and (Test-Path -LiteralPath $j.TempPng)) {
                    try { [System.IO.File]::Delete($j.TempPng) } catch { }
                }

                if ($convOk) {
                    try {
                        $null = Remove-Source -ItemPath $j.SrcPath
                        $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
                        Write-Log ("Deleted " + $SourceNoun + " (" + $deleteDesc + "): '" + $j.SrcPath + "'")
                        $batchResult.DeletedCount++
                    } catch {
                        Write-Log ("FAILED to delete " + $SourceNoun + " '" + $j.SrcPath + "': " + $_) -Level Error
                        $batchResult.DeleteFailedCount++
                    }
                }
            } else {
                $stillRunning.Add($j)
            }
        }
        $running = $stillRunning

        if ($running.Count -ge $MaxCjxlProcs -or ($pending.Count -eq 0 -and $running.Count -gt 0)) {
            Start-Sleep -Milliseconds 50
        }
    }

    # ------------------------------------------------------------------
    #  Stragglers: if cancelled while jobs were still running, wait
    #  briefly (up to -AbortTimeoutSeconds) for them to finish, then
    #  force-kill any that remain. In the common case (cancel detected
    #  between polling passes) $running is already empty here and this
    #  is a no-op.
    # ------------------------------------------------------------------
    if ($CancelToken.IsCancellationRequested -and $running.Count -gt 0) {
        if ($AbortWaitMessage) { Write-Host $AbortWaitMessage -ForegroundColor Yellow }
        $abortDeadline = [System.Diagnostics.Stopwatch]::StartNew()

        while ($running.Count -gt 0 -and $abortDeadline.Elapsed.TotalSeconds -lt $AbortTimeoutSeconds) {
            $stillWaiting = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($j in $running) {
                if ($j.Proc.HasExited) {
                    $stdout = $j.Proc.StandardOutput.ReadToEnd()
                    $stderr = $j.Proc.StandardError.ReadToEnd()
                    $code   = $j.Proc.ExitCode
                    $j.Proc.Dispose()
                    $convOk = $false
                    try {
                        if ($code -ne 0) {
                            if ($code -eq 1 -and $stderr -imatch 'Getting pixel data failed' -and $MagickExe) {
                                $strippedPng = [System.IO.Path]::Combine(
                                    [System.IO.Path]::GetDirectoryName($j.SrcPath),
                                    [System.IO.Path]::GetFileNameWithoutExtension($j.SrcPath) + "_tmp_iccstrip.png"
                                )
                                Write-Log ("ICC profile mismatch on '" + $j.SrcPath + "' - stripping profile and retrying.") -Level Warn
                                $stripPsi = New-Object System.Diagnostics.ProcessStartInfo
                                $stripPsi.FileName               = $MagickExe
                                $stripPsi.Arguments              = "`"" + $j.SrcPath + "`" -colorspace Gray -strip `"" + $strippedPng + "`""
                                $stripPsi.UseShellExecute        = $false
                                $stripPsi.RedirectStandardOutput = $true
                                $stripPsi.RedirectStandardError  = $true
                                $stripPsi.CreateNoWindow         = $true
                                $stripProc = [System.Diagnostics.Process]::Start($stripPsi)
                                $stripProc.WaitForExit()
                                $stripExitCode = $stripProc.ExitCode
                                $stripProc.Dispose()
                                if ($stripExitCode -eq 0 -and (Test-Path -LiteralPath $strippedPng)) {
                                    $retryJob = @{
                                        SrcPath = $j.SrcPath
                                        JxlPath = $j.JxlPath
                                        Proc    = $null
                                        TempPng = $strippedPng
                                    }
                                    $pending.Enqueue($retryJob)
                                    if (Test-Path -LiteralPath $strippedPng) { try { [System.IO.File]::Delete($strippedPng) } catch { } }
                                    continue
                                } else {
                                    Write-Log ("ICC strip failed for '" + $j.SrcPath + "': magick exited " + $stripExitCode + " - counting as conversion failure.") -Level Error
                                    if (Test-Path -LiteralPath $strippedPng) { try { [System.IO.File]::Delete($strippedPng) } catch { } }
                                }
                            }
                            throw ("cjxl exited with code " + $code + ". Stderr: " + $stderr)
                        }
                        if (-not (Test-Path -LiteralPath $j.JxlPath)) { throw ("Output .jxl was not created: '" + $j.JxlPath + "'") }
                        $jxlSize = (Get-Item -LiteralPath $j.JxlPath).Length
                        if ($jxlSize -eq 0) { throw ("Output .jxl is 0 bytes: '" + $j.JxlPath + "'") }
                        Write-Log ("Conversion OK (abort drain): '" + $j.JxlPath + "'")
                        $batchResult.ConvertedCount++
                        $batchResult.ConvertedPaths.Add($j.SrcPath)
                        $convOk = $true
                    } catch {
                        Write-Log ("FAILED conversion of " + $ItemNoun + " '" + $j.SrcPath + "': " + $_) -Level Error
                        $batchResult.FailedCount++
                    }
                    if ($j.TempPng -and (Test-Path -LiteralPath $j.TempPng)) {
                        try { [System.IO.File]::Delete($j.TempPng) } catch { }
                    }
                    if ($convOk) {
                        try {
                            $null = Remove-Source -ItemPath $j.SrcPath
                            $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
                            Write-Log ("Deleted " + $SourceNoun + " (" + $deleteDesc + "): '" + $j.SrcPath + "'")
                            $batchResult.DeletedCount++
                        } catch {
                            Write-Log ("FAILED to delete " + $SourceNoun + " '" + $j.SrcPath + "': " + $_) -Level Error
                            $batchResult.DeleteFailedCount++
                        }
                    }
                } else {
                    $stillWaiting.Add($j)
                }
            }
            $running = $stillWaiting
            if ($running.Count -gt 0) { Start-Sleep -Milliseconds 250 }
        }

        # Force-kill anything still running past the timeout
        if ($running.Count -gt 0) {
            $batchResult.ForceKilledCount = $running.Count
            $labelSuffix = if ($BatchLabel) { " in '" + $BatchLabel + "'" } else { "" }
            Write-Log ("Force-stopping " + $running.Count + " job(s) that did not finish within " + $AbortTimeoutSeconds + "s" + $labelSuffix + ".") -Level Warn
            foreach ($j in $running) {
                try { if (-not $j.Proc.HasExited) { $j.Proc.Kill() } } catch { }
                try { $j.Proc.WaitForExit(5000) } catch { }
                if ($j.TempPng -and (Test-Path -LiteralPath $j.TempPng)) {
                    try { [System.IO.File]::Delete($j.TempPng) } catch { }
                }
                # Clean up any partial/corrupt .jxl left behind by the killed process
                if (Test-Path -LiteralPath $j.JxlPath) {
                    try { [System.IO.File]::Delete($j.JxlPath) } catch { }
                }
                $j.Proc.Dispose()
            }
        }
    }

    # Anything left un-dispatched (only possible if cancelled before it could
    # be started) - callers that surface a "still pending" count need this,
    # since $pending itself is local to this function.
    foreach ($j in $pending.ToArray()) { $batchResult.PendingPaths.Add($j.SrcPath) }

    return $batchResult
}

# ==============================================================================
#  PART 2 - mode 1/2 orchestration
# ==============================================================================

function Get-LooseImageCandidates {
    <#
    .SYNOPSIS
        Scans $ScanPath for loose image files (outside any known ZIP's
        staging/extraction directory), classifying each as needing
        conversion or stale (a valid non-zero-byte .jxl counterpart
        already exists - safe to delete without converting).
    .PARAMETER KnownZipPaths
        Full paths of ZIPs whose extraction staging directory (same
        parent dir, same base name) should be excluded from the scan -
        those files are the ZIP worker's concern, not this pipeline's.
    .OUTPUTS
        @{ NeedsConversion = List[FileInfo]; StaleSources = List[FileInfo] }
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ScanPath,
        [string[]]$LooseImageExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif"),
        [string[]]$KnownZipPaths = @()
    )

    $zipBaseDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($zp in $KnownZipPaths) {
        $null = $zipBaseDirs.Add([System.IO.Path]::Combine(
            [System.IO.Path]::GetDirectoryName($zp),
            [System.IO.Path]::GetFileNameWithoutExtension($zp)
        ))
    }

    $allCandidates = @(Get-ChildItem -LiteralPath $ScanPath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            if ($LooseImageExtensions -inotcontains $_.Extension) { return $false }
            $fileDir = $_.DirectoryName
            foreach ($stagingDir in $zipBaseDirs) {
                if ($fileDir.Equals($stagingDir, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $fileDir.StartsWith($stagingDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $false
                }
            }
            return $true
        })

    $needsConversion = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $staleSources     = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($img in $allCandidates) {
        $jxlCounterpart = [System.IO.Path]::ChangeExtension($img.FullName, ".jxl")
        if (Test-Path -LiteralPath $jxlCounterpart) {
            $existingJxlSize = (Get-Item -LiteralPath $jxlCounterpart).Length
            if ($existingJxlSize -gt 0) {
                $staleSources.Add($img)
            } else {
                Write-Log ("Existing .jxl counterpart for '" + $img.FullName + "' is 0 bytes - treating as incomplete and re-converting source.") -Level Warn
                $needsConversion.Add($img)
            }
        } else {
            $needsConversion.Add($img)
        }
    }

    return @{ NeedsConversion = $needsConversion; StaleSources = $staleSources }
}

function Remove-StaleLooseSources {
    <#
    .SYNOPSIS
        Deletes source files that already have a valid .jxl counterpart
        (per Get-LooseImageCandidates's classification). Runs regardless
        of abort state until an abort is actually detected mid-loop (does
        not invoke cjxl, completes essentially instantly per file).
    .OUTPUTS
        @{ Success = <int>; Fail = <int> }
    #>
    param(
        [System.IO.FileInfo[]]$StaleSources
    )
    $result = @{ Success = 0; Fail = 0 }
    if (-not $StaleSources -or $StaleSources.Count -eq 0) { return $result }

    Write-Log ("Found " + $StaleSources.Count + " loose source file(s) with an existing .jxl counterpart - cleaning up.")
    foreach ($stale in $StaleSources) {
        if (Test-AbortSignal) { break }
        try {
            $null = Remove-Source -ItemPath $stale.FullName
            $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
            Write-Log ("Deleted stale source image (" + $deleteDesc + ", .jxl already exists): '" + $stale.FullName + "'")
            $result.Success++
        } catch {
            Write-Log ("FAILED to delete stale source image '" + $stale.FullName + "': " + $_) -Level Error
            $result.Fail++
        }
    }
    return $result
}

function Invoke-LooseImageConversionPipeline {
    <#
    .SYNOPSIS
        Mode 1 end to end (or mode 1's conversion half of mode 2, when
        -PerFolderBatching is used): discovers loose images, cleans up
        stale ones, converts the rest in one or more batches, deleting
        each source on success.
    .PARAMETER PerFolderBatching
        $false (mode 1): one flat batch across every discovered image.
        $true (mode 2): one batch per leaf directory (via
        Get-ZippableLeafDirs), so a caller can zip each folder right
        after its own batch finishes via -PostBatchCallback.
    .PARAMETER PostBatchCallback
        Invoked once per batch with @{ Dir; BatchResult } - $Dir is $null
        in flat-batching mode. Intentionally decoupled from ZipPipeline.ps1
        (this module has no direct dependency on it) - a caller wanting
        mode 2 behavior passes a closure that calls
        ZipPipeline.ps1's Invoke-LooseFolderZip itself, matching
        Convert-ImageBatch's own -AbortPollCallback precedent for this
        kind of hook.
    .OUTPUTS
        @{ ConvertedSuccess; ConvertedFail; ConvertedSkipped;
           DeletedSuccess; DeletedFail; StaleCleanedSuccess;
           StaleCleanedFail; ForceKilledCount; LastCompletedPaths;
           LastSkippedPaths; StillPendingPaths; BatchCount; Aborted }
    #>
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
        [string[]]$LooseImageExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif"),
        [string[]]$KnownZipPaths = @(),
        [bool]$PerFolderBatching = $false,
        [string[]]$FolderQualifyingExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif"),
        [System.Collections.Generic.HashSet[string]]$FolderExcludeStagingDirs = $null,
        [scriptblock]$PostBatchCallback = $null,
        [int]$AbortTimeoutSeconds = 60
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
        LastCompletedPaths  = [System.Collections.Generic.List[string]]::new()
        LastSkippedPaths    = [System.Collections.Generic.List[string]]::new()
        StillPendingPaths   = [System.Collections.Generic.List[string]]::new()
        BatchCount          = 0
        Aborted             = $false
    }

    $candidates = Get-LooseImageCandidates -ScanPath $Path -LooseImageExtensions $LooseImageExtensions -KnownZipPaths $KnownZipPaths

    $staleResult = Remove-StaleLooseSources -StaleSources $candidates.StaleSources
    $totals.StaleCleanedSuccess = $staleResult.Success
    $totals.StaleCleanedFail    = $staleResult.Fail

    # ------------------------------------------------------------------
    #  Determine work batches: one flat batch (mode 1), or one per leaf
    #  directory (mode 2's per-folder scoping).
    # ------------------------------------------------------------------
    $workBatches = [System.Collections.Generic.List[hashtable]]::new()
    if ($PerFolderBatching) {
        $folderQualifyingExtsWithJxl = @($FolderQualifyingExtensions) + @(".jxl")
        $leafCandidates = Get-ZippableLeafDirs -ScanPath $Path -QualifyingExtensions $folderQualifyingExtsWithJxl `
            -ExcludeStagingDirs $FolderExcludeStagingDirs -ForceRezip $false
        if ($leafCandidates.Count -eq 0) {
            Write-Log "Loose folder zip: no qualifying leaf directories found." -Level Warn
        } else {
            Write-Log ("Loose folder zip: found " + $leafCandidates.Count + " leaf director(ies) to process (convert then zip each).")
        }
        foreach ($cand in $leafCandidates) {
            $folderImages = @($candidates.NeedsConversion | Where-Object { $_.DirectoryName.Equals($cand.Dir.FullName, [System.StringComparison]::OrdinalIgnoreCase) })
            $workBatches.Add(@{ Images = $folderImages; Dir = $cand.Dir })
        }
    } else {
        if ($candidates.NeedsConversion.Count -eq 0) {
            Write-Log "No loose image files found outside ZIPs." -Level Info
        } else {
            Write-Log ("Found " + $candidates.NeedsConversion.Count + " loose image file(s) to convert.")
        }
        if ($candidates.NeedsConversion.Count -gt 0) {
            $workBatches.Add(@{ Images = $candidates.NeedsConversion; Dir = $null })
        }
    }

    $looseCts = [System.Threading.CancellationTokenSource]::new()
    try {
        foreach ($batch in $workBatches) {
            if (Test-AbortSignal) { $totals.Aborted = $true; break }

            $batchImages = $batch.Images
            $batchDir    = $batch.Dir
            $totals.BatchCount++

            if ($batchDir) {
                Write-Log ("=== Processing folder: '" + $batchDir.FullName + "' ===")
                if ($batchImages.Count -eq 0) {
                    Write-Log "  No unconverted images in this folder - skipping conversion, proceeding to zip check."
                } else {
                    Write-Log ("  Found " + $batchImages.Count + " image(s) to convert.")
                }
            }

            $batchResult = $null
            if ($batchImages.Count -gt 0) {
                $localLastCompleted = $totals.LastCompletedPaths
                $abortPoll = {
                    param($InFlightPaths)
                    $wasAbortedBefore = $script:abortRequested
                    $null = Test-AbortSignal
                    if ($script:abortRequested -and -not $wasAbortedBefore) {
                        foreach ($p in $InFlightPaths) { $localLastCompleted.Add($p) }
                    }
                }.GetNewClosure()

                $batchResult = Convert-ImageBatch -ImageFiles $batchImages -CjxlExe $CjxlExe -MagickExe $MagickExe `
                    -DoJpegLossless $JpegLossless -DoJpegQuality $JpegQuality -MaxCjxlProcs $MaxCjxlProcs `
                    -DoFullLogging $FullLogging -CancelToken $looseCts.Token -ItemNoun "loose image" `
                    -SourceNoun "loose source image" -AbortPollCallback $abortPoll `
                    -AbortWaitMessage "[ABORT] Waiting for current loose-image jobs to finish (up to $AbortTimeoutSeconds s)..." `
                    -AbortTimeoutSeconds $AbortTimeoutSeconds

                $totals.ConvertedSuccess += $batchResult.ConvertedCount
                $totals.ConvertedFail    += $batchResult.FailedCount
                $totals.ConvertedSkipped += $batchResult.SkippedCount
                $totals.DeletedSuccess   += $batchResult.DeletedCount
                $totals.DeletedFail      += $batchResult.DeleteFailedCount
                $totals.ForceKilledCount += $batchResult.ForceKilledCount
                foreach ($p in $batchResult.SkippedPaths) { $totals.LastSkippedPaths.Add($p) }
                foreach ($p in $batchResult.PendingPaths) { $totals.StillPendingPaths.Add($p) }
                if ($looseCts.Token.IsCancellationRequested) { $totals.Aborted = $true }
            }

            if ($null -ne $PostBatchCallback) {
                & $PostBatchCallback @{ Dir = $batchDir; BatchResult = $batchResult }
            }
        }
    } finally {
        $looseCts.Dispose()
    }

    return $totals
}
