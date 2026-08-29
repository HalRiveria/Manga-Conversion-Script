<#
.SYNOPSIS
    AnimatedConversionPipeline - PART 1: Convert-AnimatedBatch, the
    shared per-batch AVIF->WebP conversion engine (mirrors
    ImageConversionPipeline.ps1's Convert-ImageBatch, one animated
    conversion at a time per magick.exe process, up to -AnimatedThreads
    concurrent). PART 2: Invoke-LooseAnimatedConversionPipeline, mode 3
    ("Animated Conversion") end to end - the library-walking orchestrator
    mirroring ImageConversionPipeline.ps1's PART 2
    (Invoke-LooseImageConversionPipeline), built 2026-08-28 once Full
    Pipeline's per-chapter coordination was settled (see Todo.md) removed
    the "would be built twice" concern that deferred it originally.

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules.

    SCOPE: originally just the batch-conversion PRIMITIVE (PART 1),
    deliberately deferring the library-walking orchestrator until Full
    Pipeline's real "image + animated conversion per chapter, then zip"
    coordination was decided, so this wouldn't be built twice. That
    coordination is now settled (`Controller.ps1`, per Todo.md) - and
    critically, Controller does NOT call this module's PART 2 at all; it
    walks its own per-chapter loop and calls Convert-AnimatedBatch (PART
    1) directly, concurrently with Convert-ImageBatch, sharing one
    process budget. That means PART 2 here is safe to build purely for
    mode 3 ("Animated Conversion" alone, no zip, no Full Pipeline
    involvement) without any risk of duplicating Controller's own logic -
    the two are independent consumers of the same PART 1 primitive, not
    one built on top of the other.

    PART 2 mirrors ImageConversionPipeline.ps1's PART 2
    (Invoke-LooseImageConversionPipeline) closely, with two real
    differences, not oversights:
      - No "stale source" pre-filtering pass. Get-LooseImageCandidates
        splits NeedsConversion vs. StaleSources (a valid .jxl counterpart
        already exists) so the image pipeline can proactively delete
        stale sources before batching. Convert-AnimatedBatch already
        makes its own skip-vs-convert decision per file (an existing
        .webp with -DoAnimatedOverwrite off is a skip, not a
        pre-filtered deletion) - duplicating that check in
        Get-LooseAnimatedCandidates would just be a second, possibly-
        drifting copy of logic PART 1 already owns and already tests.
      - No ZipOut/IsZippable/-PostChapterCallback zip-domain fields. Mode
        3 never zips (no "Animated Conversion + Zip" mode exists in the
        current menu design), so -PostChapterCallback's payload here is
        just @{ SeriesName; ChapterName; Dir; ChapterResult } - the image
        pipeline's IsZippable distinction exists specifically for mode
        2's benefit and has no equivalent need here.

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
      - $script:CleanConsoleOutputEnabled, Write-CleanConsoleMessage
        (Modules\CleanConsoleRendering.ps1) - PART 1's own
        Convert-AnimatedBatch needs these too now, to gate its straggler-
        drain wait message the same way ImageConversionPipeline.ps1's
        Convert-ImageBatch does (a raw Write-Host there would corrupt
        CCR's live region mid-redraw).
      - PART 2 only: Test-AbortSignal, Register-AbortCancellationSource,
        Unregister-AbortCancellationSource (Modules\AbortPipeline.ps1);
        New-SeriesProvider, Get-SeriesChapters
        (Modules\LeafDirectoryDiscovery.ps1); Start-SeriesProgress,
        Start-ChapterProgress, Complete-ChapterProgress,
        Complete-AllActiveSeriesProgress (Modules\CleanConsoleRendering.ps1) -
        same set ImageConversionPipeline.ps1's PART 2 forward-references,
        for the same reasons.

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

# ==============================================================================
#  PART 1 - Convert-AnimatedBatch, the per-batch conversion engine
# ==============================================================================

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
        [int]$HeartbeatIntervalSeconds  = 30,
        [System.Threading.SemaphoreSlim]$SharedBudget = $null
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

        # Fill up to AnimatedThreads slots - or, when -SharedBudget is
        # supplied (Controller.ps1's Full Pipeline engine only), up to
        # however many slots the shared SemaphoreSlim currently has free,
        # ignoring $AnimatedThreads entirely - same non-blocking Wait(0)
        # shape and same "every early continue must release" contract as
        # Convert-ImageBatch's own dispatch loop - see that function's
        # comment for the full reasoning.
        while ($pending.Count -gt 0 -and (-not $CancelToken.IsCancellationRequested) -and `
               $(if ($SharedBudget) { $SharedBudget.Wait(0) } else { $running.Count -lt $AnimatedThreads })) {
            $j = $pending.Dequeue()

            if ((Test-Path -LiteralPath $j.WebpPath) -and -not $DoAnimatedOverwrite) {
                Write-Log ("SKIPPING '" + $j.SrcPath + "': output '" + $j.WebpPath + "' already exists (Overwrite is off).")
                $batchResult.SkippedCount++
                $batchResult.SkippedPaths.Add($j.SrcPath)
                if ($SharedBudget) { $SharedBudget.Release() | Out-Null }
                continue
            }

            $isAnimated = $false
            try {
                $isAnimated = Test-AvifAnimated -AvifPath $j.SrcPath -MagickExe $MagickExe
            } catch {
                Write-Log ("Could not determine if '" + $j.SrcPath + "' is animated - skipping: " + $_) -Level Warn
                $batchResult.InspectFailedCount++
                if ($SharedBudget) { $SharedBudget.Release() | Out-Null }
                continue
            }

            if (-not $isAnimated) {
                Write-Log ("'" + $j.SrcPath + "' is a static AVIF (not animated) - left unconverted.")
                $batchResult.StaticSkippedCount++
                $batchResult.StaticSkippedPaths.Add($j.SrcPath)
                if ($SharedBudget) { $SharedBudget.Release() | Out-Null }
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
                if ($SharedBudget) { $SharedBudget.Release() | Out-Null }

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
        if ($AbortWaitMessage) {
            # Same CCR gate as ImageConversionPipeline.ps1's Convert-ImageBatch
            # straggler drain - see that function's own comment for why (a
            # raw Write-Host here would corrupt CCR's live region mid-redraw).
            if ($script:CleanConsoleOutputEnabled) {
                Write-CleanConsoleMessage -Text $AbortWaitMessage -Color Yellow
            } else {
                Write-Host $AbortWaitMessage -ForegroundColor Yellow
            }
        }
        $abortDeadline = [System.Diagnostics.Stopwatch]::StartNew()

        while ($running.Count -gt 0 -and $abortDeadline.Elapsed.TotalSeconds -lt $AbortTimeoutSeconds) {
            $stillWaiting = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($j in $running) {
                if ($j.Proc.HasExited) {
                    $stdout = $j.Proc.StandardOutput.ReadToEnd()
                    $stderr = $j.Proc.StandardError.ReadToEnd()
                    $code   = $j.Proc.ExitCode
                    $j.Proc.Dispose()
                    if ($SharedBudget) { $SharedBudget.Release() | Out-Null }

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
                if ($SharedBudget) { $SharedBudget.Release() | Out-Null }
            }
        }
    }

    foreach ($j in $pending.ToArray()) { $batchResult.PendingPaths.Add($j.SrcPath) }

    return $batchResult
}

# ==============================================================================
#  PART 2 - mode 3 orchestration
# ==============================================================================

function Get-LooseAnimatedCandidates {
    <#
    .SYNOPSIS
        Scans $ScanPath for loose animated-source files (.avif by
        default, outside any known ZIP's staging/extraction directory).
        Unlike Get-LooseImageCandidates, there is no NeedsConversion/
        StaleSources split here - Convert-AnimatedBatch (PART 1) already
        decides skip-vs-convert per file itself, see this module's
        header for why duplicating that here would be wrong.
    .PARAMETER KnownZipPaths / -ExcludeStagingDirs
        Same staging-exclusion contract as Get-LooseImageCandidates.
    .OUTPUTS
        List[System.IO.FileInfo]
    #>
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
    Get-ChildItem -LiteralPath $ScanPath -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($AnimatedFileExtensions -inotcontains $_.Extension) { return }
        $fileDir = $_.DirectoryName
        foreach ($stagingDir in $zipBaseDirs) {
            if ($fileDir.Equals($stagingDir, [System.StringComparison]::OrdinalIgnoreCase) -or
                $fileDir.StartsWith($stagingDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                return
            }
        }
        $candidates.Add($_)
    }

    # Leading comma - same collection-collapse trap as every other
    # List<T>-returning function in this project (see
    # Docs/lessons-learned.md); a 0- or 1-element $candidates would
    # otherwise unwrap on return.
    return ,$candidates
}

function Get-ChapterAnimatedStatus {
    <#
    .SYNOPSIS
        Maps a Convert-AnimatedBatch result to the Status/Detail pair
        Complete-ChapterProgress expects - mirrors
        Get-ChapterProgressStatus's severity ordering exactly (Error >
        Warning > Success). A $null $ChapterResult (nothing left to
        convert) always maps to a clean Success. StaticSkippedCount does
        NOT count toward Warning - a static AVIF being left untouched is
        expected, deliberate behavior (see this module's header), not a
        problem worth surfacing on the CCR line.
    .OUTPUTS
        Two values: Status ("Success"/"Warning"/"Error"), Detail (string,
        or $null for a clean Success).
    #>
    param(
        [hashtable]$ChapterResult
    )
    if ($null -eq $ChapterResult) { return "Success", $null }

    if ($ChapterResult.FailedCount -gt 0 -or $ChapterResult.ForceKilledCount -gt 0 -or $ChapterResult.DeleteFailedCount -gt 0) {
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($ChapterResult.FailedCount -gt 0)       { $parts.Add($ChapterResult.FailedCount.ToString() + " failed") }
        if ($ChapterResult.ForceKilledCount -gt 0)  { $parts.Add($ChapterResult.ForceKilledCount.ToString() + " force-stopped") }
        if ($ChapterResult.DeleteFailedCount -gt 0) { $parts.Add($ChapterResult.DeleteFailedCount.ToString() + " source delete(s) failed") }
        return "Error", ($parts -join ", ")
    }
    if ($ChapterResult.SkippedCount -gt 0 -or $ChapterResult.InspectFailedCount -gt 0) {
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($ChapterResult.SkippedCount -gt 0)       { $parts.Add($ChapterResult.SkippedCount.ToString() + " skipped (output already exists)") }
        if ($ChapterResult.InspectFailedCount -gt 0) { $parts.Add($ChapterResult.InspectFailedCount.ToString() + " inspect failure(s)") }
        return "Warning", ($parts -join ", ")
    }
    return "Success", $null
}

function Invoke-LooseAnimatedConversionPipeline {
    <#
    .SYNOPSIS
        Mode 3 ("Animated Conversion") end to end: walks the library
        series by series (New-SeriesProvider), discovers each series'
        chapters (Get-SeriesChapters), and converts each chapter's loose
        .avif files as its own batch via Convert-AnimatedBatch - same
        two-tier walk, per-chapter batching, and CCR wiring as
        Invoke-LooseImageConversionPipeline (ImageConversionPipeline.ps1),
        mirrored deliberately. See this module's header for the two real
        differences (no stale-source pass, no zip-domain fields) and why
        this is safe to build independently of Controller.ps1.

        Same chapter-discovery completeness handling as
        Invoke-LooseImageConversionPipeline: Get-SeriesChapters's
        former-container/zip-staleness guards decide "is this worth
        re-zipping", not "does this hold unconverted animated files" - a
        directory those guards exclude but that actually has .avif files
        needing conversion is folded in as an extra chapter-equivalent
        entry before Start-SeriesProgress is called, so coverage can
        never silently regress the way it once did for images (see that
        module's own header for the real bug this already caught once
        there).
    .PARAMETER PostChapterCallback
        Invoked once per chapter with @{ SeriesName; ChapterName; Dir;
        ChapterResult } - $ChapterResult is $null when the chapter had no
        animated files to convert.
    .OUTPUTS
        @{ ConvertedSuccess; ConvertedFail; ConvertedSkipped;
           StaticSkippedCount; InspectFailedCount; DeletedSuccess;
           DeletedFail; ForceKilledCount; LastCompletedPaths;
           LastSkippedPaths; LastStaticSkippedPaths; StillPendingPaths;
           SeriesCount; ChapterCount; Aborted }
    #>
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
        [string[]]$FolderQualifyingExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif"),
        [System.Collections.Generic.HashSet[string]]$FolderExcludeStagingDirs = $null,
        [scriptblock]$PostChapterCallback = $null,
        [int]$AbortTimeoutSeconds = 60,
        [int]$HeartbeatIntervalSeconds = 30
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

    # Registered for the whole pipeline call (one phase) - same contract
    # as Invoke-LooseImageConversionPipeline's own $looseCts, and the
    # same bug that registration omission caused there (Test-AbortSignal
    # would never actually cancel this token) - registered from day one
    # here rather than needing a later fix.
    $animatedCts = [System.Threading.CancellationTokenSource]::new()
    Register-AbortCancellationSource -Cts $animatedCts
    try {
        $seriesProvider = New-SeriesProvider -LibraryPath $Path

        while ($true) {
            if (Test-AbortSignal) { $totals.Aborted = $true; break }

            $series = & $seriesProvider
            if ($null -eq $series) { break }
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

            if ($script:CleanConsoleOutputEnabled) {
                Start-SeriesProgress -SeriesName $series.Name -TotalChapters $chapterDirs.Count
            }

            if ($chapterDirs.Count -eq 0) {
                Write-Log ("Series '" + $series.Name + "': no qualifying chapters found.") -Level Info
                continue
            }

            Write-Log ("=== Series '" + $series.Name + "': " + $chapterDirs.Count + " chapter(s) ===")

            foreach ($chapterDir in $chapterDirs) {
                if (Test-AbortSignal) { $totals.Aborted = $true; break }

                $chapterName = $chapterDir.Name
                $totals.ChapterCount++

                if ($script:CleanConsoleOutputEnabled) {
                    Start-ChapterProgress -SeriesName $series.Name -ChapterName $chapterName
                }

                $chapterFiles = @()
                if ($filesByDir.ContainsKey($chapterDir.FullName)) { $chapterFiles = @($filesByDir[$chapterDir.FullName]) }

                $chapterResult = $null
                if ($chapterFiles.Count -gt 0) {
                    Write-Log ("Processing chapter: '" + $chapterDir.FullName + "' (" + $chapterFiles.Count + " animated file(s))")

                    $localLastCompleted = $totals.LastCompletedPaths
                    # Same closure-safety discipline as
                    # Invoke-LooseImageConversionPipeline's own
                    # $abortPoll - see CLAUDE.md's Lessons learned.
                    $alreadyAbortedBox = @{ Value = $false }
                    $abortPoll = {
                        param($InFlightPaths)
                        $wasAbortedBefore = $alreadyAbortedBox.Value
                        $isAbortedNow = Test-AbortSignal
                        if ($isAbortedNow -and -not $wasAbortedBefore) {
                            foreach ($p in $InFlightPaths) { $localLastCompleted.Add($p) }
                        }
                        $alreadyAbortedBox.Value = $isAbortedNow
                    }.GetNewClosure()

                    $chapterResult = Convert-AnimatedBatch -AnimatedFiles $chapterFiles -MagickExe $MagickExe `
                        -DoAnimatedLossless $AnimatedLossless -AnimatedQuality $AnimatedQuality -AnimatedThreads $AnimatedThreads `
                        -DoAnimatedOverwrite $AnimatedOverwrite -DoAnimatedDeleteSource $AnimatedDeleteSource `
                        -DoFullLogging $FullLogging -CancelToken $animatedCts.Token -AbortPollCallback $abortPoll `
                        -AbortWaitMessage "[ABORT] Waiting for current animated jobs to finish (up to $AbortTimeoutSeconds s)..." `
                        -AbortTimeoutSeconds $AbortTimeoutSeconds -HeartbeatIntervalSeconds $HeartbeatIntervalSeconds

                    $totals.ConvertedSuccess   += $chapterResult.ConvertedCount
                    $totals.ConvertedFail      += $chapterResult.FailedCount
                    $totals.ConvertedSkipped   += $chapterResult.SkippedCount
                    $totals.StaticSkippedCount += $chapterResult.StaticSkippedCount
                    $totals.InspectFailedCount += $chapterResult.InspectFailedCount
                    $totals.DeletedSuccess     += $chapterResult.DeletedCount
                    $totals.DeletedFail        += $chapterResult.DeleteFailedCount
                    $totals.ForceKilledCount   += $chapterResult.ForceKilledCount
                    foreach ($p in $chapterResult.SkippedPaths)       { $totals.LastSkippedPaths.Add($p) }
                    foreach ($p in $chapterResult.StaticSkippedPaths) { $totals.LastStaticSkippedPaths.Add($p) }
                    foreach ($p in $chapterResult.PendingPaths)       { $totals.StillPendingPaths.Add($p) }
                    if ($animatedCts.Token.IsCancellationRequested) { $totals.Aborted = $true }
                } else {
                    Write-Log ("Chapter '" + $chapterDir.FullName + "': no unconverted animated files - skipping conversion.")
                }

                if ($script:CleanConsoleOutputEnabled) {
                    $chapterStatus, $chapterDetail = Get-ChapterAnimatedStatus -ChapterResult $chapterResult
                    $null = Complete-ChapterProgress -SeriesName $series.Name -ChapterName $chapterName -Status $chapterStatus -Detail $chapterDetail
                }

                if ($null -ne $PostChapterCallback) {
                    & $PostChapterCallback @{ SeriesName = $series.Name; ChapterName = $chapterName; Dir = $chapterDir; ChapterResult = $chapterResult }
                }
            }
        }
    } finally {
        Unregister-AbortCancellationSource -Cts $animatedCts
        $animatedCts.Dispose()
        # Safety net for the abort/shutdown path - same reasoning as
        # Invoke-LooseImageConversionPipeline's own finally block.
        if ($script:CleanConsoleOutputEnabled) {
            $null = Complete-AllActiveSeriesProgress
        }
    }

    return $totals
}
