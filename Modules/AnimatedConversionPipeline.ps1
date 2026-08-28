<#
.SYNOPSIS
    AnimatedConversionPipeline - Convert-AnimatedBatch, the shared
    per-batch AVIF->WebP conversion engine (mirrors
    ImageConversionPipeline.ps1's Convert-ImageBatch, one animated
    conversion at a time per magick.exe process, up to -AnimatedThreads
    concurrent).

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules.

    SCOPE, decided explicitly with the project owner before this was
    built (not guessed at): this module is the batch-conversion PRIMITIVE
    only - the equivalent of Convert-ImageBatch alone, not a full
    Series/Chapter-aware library-walking orchestrator (the equivalent of
    ImageConversionPipeline.ps1's PART 2,
    Invoke-LooseImageConversionPipeline). Building that orchestrator now
    would mean guessing at how Full Pipeline's real "run image + animated
    conversion per chapter, then zip" coordination should work - that
    coordination doesn't exist as real code anywhere yet (Menu.ps1's
    Resolve-ModeSelection only returns flags; nothing wires them together
    yet). Left for when that's actually decided, so it isn't built twice.

    STATIC AVIF, decided explicitly: a real animation check
    (Test-AvifAnimated, via `magick identify -format "%n"` - the frame
    count) runs before each file is dispatched. A static AVIF (1 frame)
    is left untouched entirely - not converted, not deleted, not
    recorded as a failure. FLAGGED FOR FUTURE REVIEW, not decided or
    built: whether static AVIF should eventually be converted to JXL
    instead of being left alone forever - the project owner wants to
    evaluate whether that's actually worth doing before any code gets
    written for it (see Todo.md).

    HEARTBEAT LOGGING, decided explicitly: build the primitive now (a
    "still converting (Xs elapsed)" line per job exceeding
    -HeartbeatIntervalSeconds, via -Level Info Write-Log calls), and
    include BATCH-level progress in it (N of Total files done so far -
    trivially available from this function's own counters) since that
    was asked for and cheap to add. PER-FILE progress (percent complete
    of one magick.exe conversion) is NOT included - magick.exe doesn't
    expose that, and figuring out a real way to get it (tailing some
    progress-monitor output, if one even exists) wasn't worth the time
    for this pass - flagged in Todo.md as a real future exploration, not
    silently dropped.

    NOT VERIFIED AGAINST A REAL AVIF FILE OR A REAL ImageMagick BINARY -
    said honestly, not implied otherwise: `magick identify -format "%n"`
    reporting the correct frame count for an animated AVIF is the
    standard technique (same idea used elsewhere for animated GIF/WebP
    inspection), but this module's harness uses a compiled fake
    magick.exe stand-in (same technique as
    ImageConversionPipeline.Harness.ps1's fake cjxl.exe) to test the
    branching LOGIC (parse frame count, static vs. animated, convert vs.
    skip) - it does not prove the real ImageMagick binary's actual AVIF
    delegate behaves this way on a real animated/static AVIF file. Worth
    a manual sanity check against a real file once this gets wired into
    an actual run.

    REAL DELETION SEMANTICS, ported deliberately from the disregarded
    JXL-approach script rather than the WebP script this module's own
    approach is otherwise based on (see
    Modules\_Reference\AnimatedConversionPipeline.reference.ps1's own
    header - both were flagged there as worth porting): the source .avif
    is deleted via Remove-Source (respecting $script:PermanentDelete,
    same as every other deletion in this project) only when
    -AnimatedDeleteSource is true AND the conversion is verified
    successful - exit code 0 AND the output .webp exists AND is
    non-zero-byte, not just exit code alone (the WebP script only checked
    exit code; the JXL script's stricter check is what's used here).

    FORWARD REFERENCES (not defined in this module - callers must
    dot-source the owning module(s) first):
      - Write-Log (Modules\Logging.ps1)
      - Remove-Source, $script:PermanentDelete (Modules\FileDeletion.ps1)

.NOTES
    Built from Backups\Old Scripts\Convert-AnimatedAvifToWebp.ps1 (the
    approach actually used - see Modules\_Reference\AnimatedConversionPipeline.reference.ps1
    for the full reasoning) plus two specific improvements ported from
    the disregarded Convert-AnimatedToJxl.ps1 (delete-on-success,
    stricter success verification) per that reference file's own
    explicit recommendation. The PS7-only `ForEach-Object -Parallel`
    path in the old WebP script does not exist on PS 5.1 (this project's
    hard constraint) - replaced here with the same N-concurrent-process
    pattern Convert-ImageBatch already established, not a runspace-pool
    rewrite (unnecessary - external processes, not PowerShell code, do
    the real work in both cases).
#>

function Test-AvifAnimated {
    <#
    .SYNOPSIS
        True if $AvifPath has more than one frame (a real magick identify
        call - `magick identify -format "%n" <path>` - reports the frame
        count; a static AVIF reports 1). Throws if magick itself fails or
        the output can't be parsed as an integer - callers decide how to
        treat that (this project's convention: log a Warn and skip,
        matching how a corrupt/unreadable file is treated elsewhere in
        this project, e.g. RezipPipeline.ps1's ZIP inspection).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$AvifPath,
        [Parameter(Mandatory)]
        [string]$MagickExe
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $MagickExe
    $psi.Arguments              = "identify -format `"%n`" `"" + $AvifPath + "`""
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $code = $proc.ExitCode
    $proc.Dispose()

    if ($code -ne 0) {
        throw ("magick identify exited " + $code + ". Stderr: " + $stderr.Trim())
    }

    $frameCount = 0
    if (-not [int]::TryParse($stdout.Trim(), [ref]$frameCount)) {
        throw ("magick identify returned a non-numeric frame count: '" + $stdout.Trim() + "'")
    }

    return ($frameCount -gt 1)
}

function Convert-AnimatedBatch {
    <#
    .SYNOPSIS
        Converts a batch of animated AVIF files to animated WebP via
        $MagickExe. Dispatches up to $AnimatedThreads processes in
        parallel, skips static (non-animated) AVIF files entirely,
        deletes each source on a verified-successful conversion (when
        -AnimatedDeleteSource is true), and gracefully drains (then
        force-kills stragglers) on cancellation.
    .OUTPUTS
        @{ ConvertedCount; FailedCount; SkippedCount; StaticSkippedCount;
           InspectFailedCount; DeletedCount; DeleteFailedCount;
           ConvertedPaths; SkippedPaths; StaticSkippedPaths;
           PendingPaths; ForceKilledCount }
    #>
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
        [int]$HeartbeatIntervalSeconds  = 30
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

    while (($pending.Count -gt 0 -or $running.Count -gt 0) -and (-not $CancelToken.IsCancellationRequested)) {

        if ($AbortPollCallback) {
            $inFlight = @($running | ForEach-Object { $_.SrcPath })
            & $AbortPollCallback $inFlight
        }

        # Fill up to AnimatedThreads slots
        while ($pending.Count -gt 0 -and $running.Count -lt $AnimatedThreads -and (-not $CancelToken.IsCancellationRequested)) {
            $j = $pending.Dequeue()

            if ((Test-Path -LiteralPath $j.WebpPath) -and -not $DoAnimatedOverwrite) {
                Write-Log ("SKIPPING '" + $j.SrcPath + "': output '" + $j.WebpPath + "' already exists (Overwrite is off).")
                $batchResult.SkippedCount++
                $batchResult.SkippedPaths.Add($j.SrcPath)
                continue
            }

            $isAnimated = $false
            try {
                $isAnimated = Test-AvifAnimated -AvifPath $j.SrcPath -MagickExe $MagickExe
            } catch {
                Write-Log ("Could not determine if '" + $j.SrcPath + "' is animated - skipping: " + $_) -Level Warn
                $batchResult.InspectFailedCount++
                continue
            }

            if (-not $isAnimated) {
                Write-Log ("'" + $j.SrcPath + "' is a static AVIF (not animated) - left unconverted.")
                $batchResult.StaticSkippedCount++
                $batchResult.StaticSkippedPaths.Add($j.SrcPath)
                continue
            }

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $MagickExe
            $qualityArg = if ($DoAnimatedLossless) { "-define webp:lossless=true" } else { "-quality " + $AnimatedQuality }
            $psi.Arguments = "`"" + $j.SrcPath + "`" -coalesce -loop 0 " + $qualityArg + " `"" + $j.WebpPath + "`""
            $psi.UseShellExecute        = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow         = $true

            Write-Log ("Converting animated: '" + $j.SrcPath + "'")

            $j.Proc          = [System.Diagnostics.Process]::Start($psi)
            $j.StartTime     = [System.Diagnostics.Stopwatch]::StartNew()
            $j.LastHeartbeat = [timespan]::Zero
            $running.Add($j)
        }

        # Poll for finished processes; heartbeat any still running past the threshold
        $stillRunning = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($j in $running) {
            if ($j.Proc.HasExited) {
                $stdout = $j.Proc.StandardOutput.ReadToEnd()
                $stderr = $j.Proc.StandardError.ReadToEnd()
                $code   = $j.Proc.ExitCode
                $j.Proc.Dispose()

                if ($DoFullLogging -and -not [string]::IsNullOrWhiteSpace($stdout)) {
                    Write-Log ("magick stdout for '" + $j.SrcPath + "': " + $stdout.Trim())
                }

                $convOk = $false
                try {
                    if ($code -ne 0) { throw ("magick exited with code " + $code + ". Stderr: " + $stderr) }
                    if (-not (Test-Path -LiteralPath $j.WebpPath)) { throw ("Output .webp was not created: '" + $j.WebpPath + "'") }
                    $webpSize = (Get-Item -LiteralPath $j.WebpPath).Length
                    if ($webpSize -eq 0) { throw ("Output .webp is 0 bytes: '" + $j.WebpPath + "'") }
                    Write-Log ("Conversion OK: '" + $j.WebpPath + "' (" + $webpSize + " bytes)")
                    $batchResult.ConvertedCount++
                    $batchResult.ConvertedPaths.Add($j.SrcPath)
                    $convOk = $true
                } catch {
                    Write-Log ("FAILED conversion of animated AVIF '" + $j.SrcPath + "': " + $_) -Level Error
                    $batchResult.FailedCount++
                    if (Test-Path -LiteralPath $j.WebpPath) { try { [System.IO.File]::Delete($j.WebpPath) } catch { } }
                }

                if ($convOk -and $DoAnimatedDeleteSource) {
                    try {
                        $null = Remove-Source -ItemPath $j.SrcPath
                        $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
                        Write-Log ("Deleted source (" + $deleteDesc + "): '" + $j.SrcPath + "'")
                        $batchResult.DeletedCount++
                    } catch {
                        Write-Log ("FAILED to delete source '" + $j.SrcPath + "': " + $_) -Level Error
                        $batchResult.DeleteFailedCount++
                    }
                }
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

        if ($running.Count -ge $AnimatedThreads -or ($pending.Count -eq 0 -and $running.Count -gt 0)) {
            Start-Sleep -Milliseconds 50
        }
    }

    # ------------------------------------------------------------------
    #  Stragglers: cancelled while jobs were still running - wait up to
    #  -AbortTimeoutSeconds, then force-kill anything left. Mirrors
    #  Convert-ImageBatch's own drain shape (no ICC-retry logic here -
    #  that's cjxl/PNG-specific, not applicable to magick WebP output).
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
                        if ($code -ne 0) { throw ("magick exited with code " + $code + ". Stderr: " + $stderr) }
                        if (-not (Test-Path -LiteralPath $j.WebpPath)) { throw ("Output .webp was not created: '" + $j.WebpPath + "'") }
                        $webpSize = (Get-Item -LiteralPath $j.WebpPath).Length
                        if ($webpSize -eq 0) { throw ("Output .webp is 0 bytes: '" + $j.WebpPath + "'") }
                        Write-Log ("Conversion OK (abort drain): '" + $j.WebpPath + "'")
                        $batchResult.ConvertedCount++
                        $batchResult.ConvertedPaths.Add($j.SrcPath)
                        $convOk = $true
                    } catch {
                        Write-Log ("FAILED conversion of animated AVIF '" + $j.SrcPath + "': " + $_) -Level Error
                        $batchResult.FailedCount++
                        if (Test-Path -LiteralPath $j.WebpPath) { try { [System.IO.File]::Delete($j.WebpPath) } catch { } }
                    }

                    if ($convOk -and $DoAnimatedDeleteSource) {
                        try {
                            $null = Remove-Source -ItemPath $j.SrcPath
                            $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
                            Write-Log ("Deleted source (" + $deleteDesc + "): '" + $j.SrcPath + "'")
                            $batchResult.DeletedCount++
                        } catch {
                            Write-Log ("FAILED to delete source '" + $j.SrcPath + "': " + $_) -Level Error
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
                if (Test-Path -LiteralPath $j.WebpPath) { try { [System.IO.File]::Delete($j.WebpPath) } catch { } }
                $j.Proc.Dispose()
            }
        }
    }

    foreach ($j in $pending.ToArray()) { $batchResult.PendingPaths.Add($j.SrcPath) }

    return $batchResult
}
