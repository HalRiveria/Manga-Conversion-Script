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
        zip step, wired in via -PostChapterCallback (see
        Invoke-LooseImageConversionPipeline) rather than this module
        calling into ZipPipeline.ps1 directly - keeps this module decoupled
        from zip-domain logic, matching Convert-ImageBatch's own existing
        -AbortPollCallback precedent for the same kind of hook.
      - Mode 4 calls Convert-ImageBatch (PART 1) per-ZIP from inside its
        own worker - already the same shared function, nothing to change.
      - Mode 3 doesn't convert anything, not involved.

    CLEAN CONSOLE OUTPUT REWORK (2026-08-26): PART 2 now walks the library
    two-tier - New-SeriesProvider (lazy, one series at a time) then
    Get-SeriesChapters (eager, one series' worth of chapters) - and always
    batches per chapter, series by series. This replaced the old
    -PerFolderBatching toggle (which no longer exists) and its flat
    whole-library batch mode (mode 1's own worst hang case - it walked
    every FILE up front, not just every directory). The restructuring is
    unconditional, not gated behind the Clean Console Output toggle
    itself (see CLAUDE.md) - only the actual CCR calls
    (Start-SeriesProgress/Start-ChapterProgress/Complete-ChapterProgress/
    Complete-AllActiveSeriesProgress) are gated on
    $script:CleanConsoleOutputEnabled. Get-LooseImageCandidates is now
    called once per series (bounded scan) rather than once for the whole
    library, per CLAUDE.md's pre-flight note.

    A real bug fixed along the way, found while wiring this up rather
    than pre-existing in shipped behavior (this module was never merged
    or exercised before): the old code created its own $looseCts but
    never registered it with AbortPipeline.ps1's
    Register-AbortCancellationSource, so Test-AbortSignal could never
    actually cancel it - Convert-ImageBatch's own CancelToken check would
    never have fired on a real Ctrl+C. Now registered once per pipeline
    call and unregistered in the `finally` block, matching
    Register-AbortCancellationSource's own "call once per pipeline phase"
    contract.

    NOT owned here (see Summary.reference.ps1 instead): the mode 1/2
    abort-path summary text. This module's orchestration function returns
    enough structured data (last-completed/skipped paths, still-pending
    paths, per-category totals) for a future Summary module to build that
    text - it does not build the text itself, matching the reference
    extraction's explicit note on this.

    FORWARD REFERENCES (not defined in this module - callers must
    dot-source the owning module(s) first):
      - Write-Log (Logging.ps1)
      - $script:CleanConsoleOutputEnabled (Logging.ps1) - gates every CCR
        call below, same pattern AbortPipeline.ps1 uses; Write-Log calls
        themselves stay unconditional, since Logging.ps1 (not this
        module) is what suppresses their console echo when the toggle
        is on
      - Remove-Source, $script:PermanentDelete (FileDeletion.ps1)
      - Test-AbortSignal, Register-AbortCancellationSource,
        Unregister-AbortCancellationSource (AbortPipeline.ps1)
      - New-SeriesProvider, Get-SeriesChapters
        (LeafDirectoryDiscovery.ps1) - the two-tier discovery PART 2 now
        drives unconditionally (see CLAUDE.md's "Clean Console Output" -
        this replaced the old Get-ZippableLeafDirs + -PerFolderBatching
        toggle)
      - Start-SeriesProgress, Start-ChapterProgress,
        Complete-ChapterProgress, Complete-AllActiveSeriesProgress,
        Write-GatedConsoleMessage (CleanConsoleRendering.ps1) - the last
        one gates Convert-ImageBatch's own straggler-drain wait message,
        matching how AbortPipeline.ps1's Invoke-GracefulDrain already
        handles the same kind of message (this function has its own,
        separate drain implementation - see PART 1 NOTE below - so it
        needed the same CCR gate added explicitly). Write-GatedConsoleMessage
        takes the toggle as an explicit param rather than reading
        $script:CleanConsoleOutputEnabled itself (CleanConsoleRendering.ps1
        has no forward references of its own) - this call site supplies it.
      - Test-AvifAnimated (AnimatedConversionPipeline.ps1) - NEW
        2026-08-28, for the static-AVIF conversion path in
        Convert-ImageBatch (see "STATIC AVIF -> JXL" below). Spawns a
        real magick identify process - not a cheap byte read like the
        WebP animation check - so this module now genuinely depends on
        AnimatedConversionPipeline.ps1 being dot-sourced first, a real
        new coupling between the two, not just a docstring note.
    Modules\_Harness\ImageConversionPipeline.Harness.ps1 dot-sources the
    real Logging.ps1/FileDeletion.ps1/AbortPipeline.ps1/
    LeafDirectoryDiscovery.ps1/CleanConsoleRendering.ps1/
    AnimatedConversionPipeline.ps1 (the last one added 2026-08-28, for
    Test-AvifAnimated), and compiles a small real stand-in executable
    (via Add-Type -OutputType ConsoleApplication) to serve as
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

    STATIC AVIF -> JXL (2026-08-28, Phase 2 of the main-script-rewrite
    build plan, Todo.md): decided unconditionally, no toggle - convert
    static AVIF the same as everything else, for consistency with the
    rest of the library. Lives HERE, not AnimatedConversionPipeline.ps1,
    since it's a static-image concern - reuses the exact same "transcode
    to a temp PNG via magick, then hand that to cjxl" detour already
    built for WebP (the two now share one code path in the dispatch
    loop below, the WebP/AVIF-specific parts are only the pre-checks:
    the byte-level VP8X animation-flag read for WebP, a real
    Test-AvifAnimated call - a magick identify process spawn, NOT a
    cheap byte read - for AVIF). Animated AVIF is left untouched here,
    same as animated WebP - it has its own conversion pipeline
    (AnimatedConversionPipeline.ps1). A real Test-AvifAnimated failure
    (couldn't determine frame count) is its own outcome, NOT folded into
    FailedCount or SkippedCount - see the new InspectFailedCount field,
    matching Convert-AnimatedBatch's own field of the same name for the
    identical failure mode (this project's own "give it its own field,
    don't fold it into Fail" call, see Todo.md's Summary.ps1 decision -
    applied here preemptively for consistency, not just in Summary.ps1
    itself, ahead of the project owner's own requested cross-codebase
    naming/consistency review, Todo.md Phase 4).

    -ZIPSTEPCALLBACK (2026-08-28, Phase 2): mode 8's ("Image Conversion +
    Zip") decided CCR-fold mechanism - see .PARAMETER ZipStepCallback on
    Invoke-LooseImageConversionPipeline below and Docs/menu-design.md.
    Delays Complete-ChapterProgress until after the callback returns (if
    one was supplied and the chapter is zippable and conversion didn't
    already hit an Error), then merges both outcomes into ONE Detail/
    Status - mirrors Controller.ps1's Get-MergedChapterStatus merge
    shape (worst-of-two, concatenated sub-summaries) without importing
    that function directly, since the zip callback's own return shape
    (@{ Status; Detail }) is already simple enough not to need it. $null
    default (mode 2's existing behavior) leaves Get-ChapterProgressStatus's
    own Detail format completely unchanged - the "Convert: ... | Zip: ..."
    concatenation only ever appears when a real callback actually ran.

.NOTES
    Extracted from Conversion Script Main.ps1 - see
    Modules\_Reference\ImageConversionPipeline.reference.ps1 for the
    verbatim source this was built from, with original line numbers.
#>

# ==============================================================================
#  PART 1 - Convert-ImageBatch, the per-batch conversion engine
# ==============================================================================

function Invoke-IccStripRetryOrFail {
    <#
    .SYNOPSIS
        Private helper - the ICC-profile-mismatch retry step: strips the
        embedded profile via ImageMagick, and on success enqueues a retry
        job onto $Pending (a fresh TempPng, same Src/JxlPath) rather than
        counting the original job failed. Only ever called after the
        caller has already confirmed cjxl exited 1 with a "Getting pixel
        data failed" stderr and a real $MagickExe is available.
    .OUTPUTS
        $true if a retry was enqueued (caller should treat this job as
        "not yet decided" and skip its normal failure path); $false if
        the strip itself also failed (caller falls through to its normal
        failure path).
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Job,
        [Parameter(Mandatory)]
        [System.Collections.Queue]$Pending,
        [Parameter(Mandatory)]
        [string]$MagickExe
    )

    $strippedPng = [System.IO.Path]::Combine(
        [System.IO.Path]::GetDirectoryName($Job.SrcPath),
        [System.IO.Path]::GetFileNameWithoutExtension($Job.SrcPath) + "_tmp_iccstrip.png"
    )
    Write-Log ("ICC profile mismatch on '" + $Job.SrcPath + "' - stripping profile and retrying.") -Level Warn
    $stripPsi = New-Object System.Diagnostics.ProcessStartInfo
    $stripPsi.FileName               = $MagickExe
    $stripPsi.Arguments              = "`"" + $Job.SrcPath + "`" -colorspace Gray -strip `"" + $strippedPng + "`""
    $stripPsi.UseShellExecute        = $false
    $stripPsi.RedirectStandardOutput = $true
    $stripPsi.RedirectStandardError  = $true
    $stripPsi.CreateNoWindow         = $true
    $stripProc = [System.Diagnostics.Process]::Start($stripPsi)
    $stripProc.WaitForExit()
    $stripExitCode = $stripProc.ExitCode
    $stripProc.Dispose()

    if ($stripExitCode -eq 0 -and (Test-Path -LiteralPath $strippedPng)) {
        # Cancel/abort may be in progress - the dispatch loop won't run
        # again in that case, so this retry will simply be picked up by
        # the stragglers drain below (or left for the next run). Enqueue
        # unconditionally either way.
        $retryJob = @{
            SrcPath    = $Job.SrcPath
            JxlPath    = $Job.JxlPath
            Proc       = $null
            TempPng    = $strippedPng
            IccRetried = $true
        }
        $Pending.Enqueue($retryJob)
        # Deliberately does NOT delete $strippedPng here (a prior version
        # did, immediately after enqueuing this exact job as the retry's
        # only input - the retry could never succeed since cjxl would be
        # pointed at a file that no longer existed by the time it was
        # dequeued). Cleanup of TempPng happens once, after the retry job
        # itself finishes, via Complete-ImageConversionJob's own TempPng
        # cleanup (below) - same as every other TempPng-bearing job.
        return $true
    }

    Write-Log ("ICC strip failed for '" + $Job.SrcPath + "': magick exited " + $stripExitCode + " - counting as conversion failure.") -Level Error
    if (Test-Path -LiteralPath $strippedPng) { try { [System.IO.File]::Delete($strippedPng) } catch { } }
    return $false
}

function Complete-ImageConversionJob {
    <#
    .SYNOPSIS
        Private helper - handles one finished cjxl job's process cleanup,
        exit-code/output verification (including the ICC-profile-mismatch
        retry via Invoke-IccStripRetryOrFail), temp-PNG cleanup, and (on
        success) source deletion, mutating $BatchResult in place. Shared
        by Convert-ImageBatch's main dispatch loop and its straggler-
        drain loop, which previously each implemented this ~70-line block
        (job completion PLUS the ICC-retry step) almost verbatim - the
        largest duplication found in the improvement review. The only
        real differences were the drain copy skipping the -DoFullLogging
        stdout dump and the success log message (no byte count, "(abort
        drain)" wording instead), both captured via -IsAbortDrain.
    .OUTPUTS
        $true if this job was an ICC mismatch that got re-enqueued onto
        $Pending as a retry (the caller should `continue` its loop
        without counting a failure or running cleanup for THIS job - the
        retry is a new, separate job); $false for every other outcome
        (converted, failed, or a non-ICC failure) - caller's loop
        continues normally either way.
    .PARAMETER IsAbortDrain
        $true from the straggler-drain loop; $false (default) from the
        main dispatch loop - see SYNOPSIS for what this changes.
    #>
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
        [System.Threading.SemaphoreSlim]$SharedBudget,
        [bool]$IsAbortDrain = $false
    )

    $stdout = $Job.Proc.StandardOutput.ReadToEnd()
    $stderr = $Job.Proc.StandardError.ReadToEnd()
    $code   = $Job.Proc.ExitCode
    $Job.Proc.Dispose()
    # This job is leaving the caller's running list for good in every path
    # below (including the ICC-retry re-enqueue - the RETRY job acquires
    # its own fresh slot later when it's actually dispatched) - release
    # its slot exactly once, here, regardless of outcome.
    if ($SharedBudget) { $SharedBudget.Release() | Out-Null }

    if (-not $IsAbortDrain -and $DoFullLogging -and -not [string]::IsNullOrWhiteSpace($stdout)) {
        Write-Log ("cjxl stdout for '" + $Job.SrcPath + "': " + $stdout.Trim())
    }

    $convOk = $false
    try {
        if ($code -ne 0) {
            # -not $Job.IccRetried: a job that's ALREADY the ICC-strip
            # retry (its own SrcPath is the ORIGINAL source, not the
            # stripped PNG - see Invoke-IccStripRetryOrFail's retryJob
            # shape) hitting the same "Getting pixel data failed" signature
            # again must fall through to the normal failure path instead of
            # retrying forever - without this guard, a source that still
            # fails after stripping would re-strip-and-retry indefinitely.
            if ($code -eq 1 -and $stderr -imatch 'Getting pixel data failed' -and $MagickExe -and -not $Job.IccRetried) {
                if (Invoke-IccStripRetryOrFail -Job $Job -Pending $Pending -MagickExe $MagickExe) {
                    return $true
                }
            }
            throw ("cjxl exited with code " + $code + ". Stderr: " + $stderr)
        }
        if (-not (Test-Path -LiteralPath $Job.JxlPath)) { throw ("Output .jxl was not created: '" + $Job.JxlPath + "'") }
        $jxlSize = (Get-Item -LiteralPath $Job.JxlPath).Length
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
    }

    # Clean up the temporary PNG used for WebP/ICC-strip pre-conversion
    if ($Job.TempPng -and (Test-Path -LiteralPath $Job.TempPng)) {
        try { [System.IO.File]::Delete($Job.TempPng) } catch { }
    }

    if ($convOk) {
        try {
            $null = Remove-Source -ItemPath $Job.SrcPath
            $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
            Write-Log ("Deleted " + $SourceNoun + " (" + $deleteDesc + "): '" + $Job.SrcPath + "'")
            $BatchResult.DeletedCount++
        } catch {
            Write-Log ("FAILED to delete " + $SourceNoun + " '" + $Job.SrcPath + "': " + $_) -Level Error
            $BatchResult.DeleteFailedCount++
        }
    }

    return $false
}

function Convert-ImageBatch {
    <#
    .SYNOPSIS
        Converts a batch of image files to .jxl via $CjxlExe (WebP/static-
        AVIF inputs are pre-converted to PNG via $MagickExe first; a PNG
        whose ICC profile mismatches its actual pixel format is retried
        once with the profile stripped). Animated WebP/AVIF are skipped,
        not converted - AVIF has its own conversion pipeline
        (AnimatedConversionPipeline.ps1). Dispatches up to $MaxCjxlProcs
        processes in parallel, deletes each source on a successful
        conversion, and gracefully drains (then force-kills stragglers)
        on cancellation.
    .OUTPUTS
        @{ ConvertedCount; FailedCount; SkippedCount; DeletedCount;
           DeleteFailedCount; ConvertedPaths; SkippedPaths; PendingPaths;
           ForceKilledCount; InspectFailedCount } - InspectFailedCount is
        AVIF-only: a real magick identify failure (couldn't determine
        whether the file is animated), NOT folded into FailedCount -
        matches Convert-AnimatedBatch's own field of the same name for
        the identical failure mode.
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
        [int]$AbortTimeoutSeconds       = 60,
        [System.Threading.SemaphoreSlim]$SharedBudget = $null
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

        # Fill up to MaxCjxlProcs slots - or, when -SharedBudget is
        # supplied (Controller.ps1's Full Pipeline engine only), up to
        # however many slots the shared SemaphoreSlim currently has free,
        # ignoring $MaxCjxlProcs entirely (the shared budget IS the real
        # ceiling in that mode). Wait(0) is a non-blocking try-acquire -
        # it either grabs a slot and returns true, or returns false
        # immediately without consuming one - so this loop never stalls
        # waiting on a slot the OTHER engine's runspace is holding; it
        # just stops dispatching for this pass and the outer while-loop's
        # normal poll/sleep cycle tries again next time around. EVERY
        # early `continue` below (a job that never reaches
        # Process.Start/$running.Add) MUST release a slot it just
        # acquired here first - see each one.
        while ($pending.Count -gt 0 -and (-not $CancelToken.IsCancellationRequested) -and `
               $(if ($SharedBudget) { $SharedBudget.Wait(0) } else { $running.Count -lt $MaxCjxlProcs })) {
            $j   = $pending.Dequeue()
            # Everything from here through $running.Add($j) below is wrapped
            # in one try/catch (2026-08-31 fix) - a raw .NET exception from
            # either Process.Start() call in this block (magick's
            # pre-conversion spawn or cjxl's own spawn - a stale cached exe
            # path, a locked file, etc.) is NOT a terminating error in this
            # scriptblock (no $ErrorActionPreference = "Stop" is set here),
            # so without this it would print a non-terminating error and
            # keep going with $j.Proc left $null - $null.HasExited then
            # never becomes true, so that job sits in $running forever and
            # the WHOLE dispatch loop (and the chapter, and the run) hangs
            # indefinitely instead of failing that one job. Confirmed live:
            # a stale/bad -CjxlExe path hung indefinitely before this fix.
            $magickProcLocal = $null
            try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName               = $CjxlExe
            $psi.UseShellExecute        = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow         = $true

            # cjxl 0.11.x cannot read WebP or AVIF directly - transcode to a
            # temp PNG first. Animated WebP/AVIF are skipped entirely (cjxl
            # has no multi-frame support) - animated AVIF has its own
            # conversion pipeline, AnimatedConversionPipeline.ps1. The two
            # formats share this one transcode step; only the animation
            # pre-check differs (a cheap WebP byte read vs. a real magick
            # identify process spawn for AVIF - see this module's header,
            # "STATIC AVIF -> JXL").
            $isWebp = ($j.SrcPath -imatch '\.webp$')
            $isAvif = ($j.SrcPath -imatch '\.avif$')
            if ($isWebp -or $isAvif) {
                $formatLabel = if ($isAvif) { "AVIF" } else { "WebP" }
                if (-not $MagickExe) {
                    Write-Log ("SKIPPING " + $formatLabel + " '" + $j.SrcPath + "': ImageMagick not found. Install ImageMagick or pass -MagickPath.") -Level Error
                    $batchResult.FailedCount++
                    if ($SharedBudget) { $SharedBudget.Release() | Out-Null }
                    continue
                }

                if ($isWebp) {
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
                        if ($SharedBudget) { $SharedBudget.Release() | Out-Null }
                        continue
                    }
                    # --- End animated WebP check ---
                } else {
                    # --- Animated AVIF check (real magick identify spawn) ---
                    $isAnimatedAvif = $false
                    try {
                        $isAnimatedAvif = Test-AvifAnimated -AvifPath $j.SrcPath -MagickExe $MagickExe
                    } catch {
                        Write-Log ("Could not determine if AVIF '" + $j.SrcPath + "' is animated - skipping: " + $_) -Level Warn
                        $batchResult.InspectFailedCount++
                        if ($SharedBudget) { $SharedBudget.Release() | Out-Null }
                        continue
                    }
                    if ($isAnimatedAvif) {
                        Write-Log ("SKIPPING animated AVIF '" + $j.SrcPath + "': has its own conversion pipeline (AnimatedConversionPipeline.ps1) - not converted here.") -Level Warn
                        $batchResult.SkippedCount++
                        $batchResult.SkippedPaths.Add($j.SrcPath)
                        if ($SharedBudget) { $SharedBudget.Release() | Out-Null }
                        continue
                    }
                    # --- End animated AVIF check ---
                }

                $tempPng = [System.IO.Path]::Combine(
                    [System.IO.Path]::GetDirectoryName($j.SrcPath),
                    [System.IO.Path]::GetFileNameWithoutExtension($j.SrcPath) + "_tmp_" + $formatLabel.ToLowerInvariant() + "2png.png"
                )
                $magickPsi = New-Object System.Diagnostics.ProcessStartInfo
                $magickPsi.FileName               = $MagickExe
                $magickPsi.Arguments              = "`"" + $j.SrcPath + "[0]`" `"" + $tempPng + "`""
                $magickPsi.UseShellExecute        = $false
                $magickPsi.RedirectStandardOutput = $true
                $magickPsi.RedirectStandardError  = $true
                $magickPsi.CreateNoWindow         = $true
                $magickProc = [System.Diagnostics.Process]::Start($magickPsi)
                $magickProcLocal = $magickProc
                $magickProc.WaitForExit()
                $magickExitCode = $magickProc.ExitCode
                $magickProc.Dispose()
                $magickProcLocal = $null
                if ($magickExitCode -ne 0 -or -not (Test-Path -LiteralPath $tempPng)) {
                    Write-Log ("FAILED " + $formatLabel + "->PNG pre-conversion for '" + $j.SrcPath + "': magick exited " + $magickExitCode) -Level Error
                    $batchResult.FailedCount++
                    if (Test-Path -LiteralPath $tempPng) { try { [System.IO.File]::Delete($tempPng) } catch { } }
                    if ($SharedBudget) { $SharedBudget.Release() | Out-Null }
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
            } catch {
                Write-Log ("FAILED to start conversion process for '" + $j.SrcPath + "': " + $_) -Level Error
                $batchResult.FailedCount++
                if ($magickProcLocal) { try { if (-not $magickProcLocal.HasExited) { $magickProcLocal.Kill() }; $magickProcLocal.Dispose() } catch { } }
                if ($j.TempPng -and (Test-Path -LiteralPath $j.TempPng)) { try { [System.IO.File]::Delete($j.TempPng) } catch { } }
                if ($SharedBudget) { $SharedBudget.Release() | Out-Null }
            }
        }

        # Poll for finished processes
        $stillRunning = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($j in $running) {
            if ($j.Proc.HasExited) {
                # cjxl 0.11.x rejects PNGs whose embedded ICC profile declares
                # RGB colorspace but whose pixel data is grayscale (libpng
                # warning: "RGB color space not permitted on grayscale PNG",
                # followed by "Getting pixel data failed") - handled inside
                # Complete-ImageConversionJob via Invoke-IccStripRetryOrFail,
                # which re-enqueues a retry job onto $pending rather than
                # counting it failed; a $true return means that happened here.
                if (Complete-ImageConversionJob -Job $j -BatchResult $batchResult -Pending $pending -MagickExe $MagickExe -DoFullLogging $DoFullLogging -ItemNoun $ItemNoun -SourceNoun $SourceNoun -SharedBudget $SharedBudget) {
                    continue
                }
            } else {
                $stillRunning.Add($j)
            }
        }
        $running = $stillRunning

        # Always sleep briefly here - the outer while's own condition
        # ($pending.Count -gt 0 -or $running.Count -gt 0) already
        # guarantees there's work left every time execution reaches this
        # point, so a conditional check for "is dispatch actually blocked"
        # was redundant in the plain $MaxCjxlProcs case and outright wrong
        # for -SharedBudget: with a shared budget smaller than
        # $MaxCjxlProcs (the normal Full Pipeline case - Controller.ps1
        # passes -MaxCjxlProcs $Files.Count), $running.Count never reaches
        # $MaxCjxlProcs, so the old condition was false on every pass and
        # this loop busy-spun at ~100% CPU polling Wait(0)/HasExited
        # instead of sleeping between polls.
        Start-Sleep -Milliseconds 50
    }

    # ------------------------------------------------------------------
    #  Stragglers: if cancelled while jobs were still running, wait
    #  briefly (up to -AbortTimeoutSeconds) for them to finish, then
    #  force-kill any that remain. In the common case (cancel detected
    #  between polling passes) $running is already empty here and this
    #  is a no-op.
    # ------------------------------------------------------------------
    if ($CancelToken.IsCancellationRequested -and $running.Count -gt 0) {
        if ($AbortWaitMessage) {
            # Gated on Clean Console Output the same way AbortPipeline.ps1's
            # own Invoke-GracefulDrain already handles its own wait message -
            # a raw Write-Host here while CCR's live region is mid-redraw
            # would land wherever the cursor happens to be and get mangled
            # by the next redraw (see CleanConsoleRendering.ps1's header).
            # This function's own straggler drain is a separate, independent
            # implementation (not Invoke-GracefulDrain), so it needed this
            # gate added explicitly rather than inheriting it for free.
            Write-GatedConsoleMessage -Text $AbortWaitMessage -Color Yellow -CleanConsoleOutputEnabled ([bool]$script:CleanConsoleOutputEnabled)
        }
        $abortDeadline = [System.Diagnostics.Stopwatch]::StartNew()

        while ($running.Count -gt 0 -and $abortDeadline.Elapsed.TotalSeconds -lt $AbortTimeoutSeconds) {
            $stillWaiting = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($j in $running) {
                if ($j.Proc.HasExited) {
                    if (Complete-ImageConversionJob -Job $j -BatchResult $batchResult -Pending $pending -MagickExe $MagickExe -DoFullLogging $DoFullLogging -ItemNoun $ItemNoun -SourceNoun $SourceNoun -SharedBudget $SharedBudget -IsAbortDrain $true) {
                        continue
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
                if ($SharedBudget) { $SharedBudget.Release() | Out-Null }
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
    .PARAMETER ExcludeStagingDirs
        Directories (and anything under them) to skip entirely - same
        exclusion set Get-SeriesChapters/Get-ZippableLeafDirs apply, so a
        staging/extraction area a caller asked to leave alone can't have
        a "stale" source silently deleted out of it just because this
        function has no other concept of it.
    .OUTPUTS
        @{ NeedsConversion = List[FileInfo]; StaleSources = List[FileInfo] }
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ScanPath,
        [string[]]$LooseImageExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif"),
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

function Get-ChapterProgressStatus {
    <#
    .SYNOPSIS
        Maps a Convert-ImageBatch result to the Status/Detail pair
        Complete-ChapterProgress expects. A $null $ChapterResult (the
        chapter had nothing left to convert) always maps to a clean
        Success with no detail text.
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
    if ($ChapterResult.SkippedCount -gt 0) {
        return "Warning", ($ChapterResult.SkippedCount.ToString() + " image(s) skipped")
    }
    return "Success", $null
}

function Invoke-LooseImageConversionPipeline {
    <#
    .SYNOPSIS
        Mode 1 end to end (and mode 1's conversion half of mode 2): walks
        the library series by series (New-SeriesProvider), discovers each
        series' chapters (Get-SeriesChapters), and converts each chapter's
        loose images as its own batch - unconditional series/chapter
        batching, not a mode-1-vs-mode-2 toggle (see this module's header
        and CLAUDE.md's "Clean Console Output").

        Get-SeriesChapters alone is NOT the full picture of what gets
        converted: it's a thin wrapper on the zip-domain
        Get-ZippableLeafDirs, whose former-container/zip-staleness guards
        decide "is this worth re-zipping", not "does this need
        converting". Any directory holding a needs-conversion image that
        those guards excluded (a stray .zip alongside fresh loose images,
        or images sitting directly in the series root) is folded in as an
        extra chapter-equivalent entry BEFORE Start-SeriesProgress is
        called, so the progress total already accounts for it and nothing
        is ever silently skipped - see the in-line comment where
        $chapterEntries is built.
    .PARAMETER PostChapterCallback
        Invoked once per chapter with @{ SeriesName; ChapterName; Dir;
        ChapterResult; ZipOut; IsZippable } - $ChapterResult is $null when
        the chapter had nothing left to convert. IsZippable is $false (and
        ZipOut is $null) for an "extra" entry the merge above added
        because it held unconverted images but wasn't a real
        Get-SeriesChapters result (a former-container/zip-staleness guard
        exclusion, or a directory with no chapter subfolder at all, e.g.
        the series root) - a caller MUST check IsZippable before zipping,
        or an extra like the series root itself could get wrapper-zipped
        once every real chapter around it is already zipped and deleted,
        which is exactly the container-folder mess the former-container
        guard exists to prevent (caught in review). Intentionally
        decoupled from ZipPipeline.ps1 (this module has no direct
        dependency on it) - a caller wanting mode 2 behavior passes a
        closure that calls ZipPipeline.ps1's Invoke-LooseFolderZip itself
        ONLY when IsZippable is true, matching Convert-ImageBatch's own
        -AbortPollCallback precedent for this kind of hook.
    .PARAMETER ZipStepCallback
        Mode 8's ("Image Conversion + Zip") decided CCR-fold mechanism,
        2026-08-28 - see this module's header, "-ZIPSTEPCALLBACK".
        Invoked with @{ SeriesName; ChapterName; Dir; ChapterResult;
        ZipOut } ONLY when IsZippable is true AND conversion didn't
        already hit an Error - must return @{ Status =
        "Success"|"Fail"|"Skipped"; Detail = <string, or $null> } (or
        $null itself for "did nothing"). Its outcome is merged into the
        SAME Complete-ChapterProgress call conversion already makes
        (worst-of-two Status, concatenated "Convert: ... | Zip: ..."
        Detail) - NOT a second CCR transition. $null default (mode 2's
        existing behavior) leaves everything about this function
        completely unchanged. Deliberately dumb: this function only
        decides WHETHER to call it (IsZippable/Error gate); mode-8-
        specific business logic (e.g. ZipWithUnconvertedAnimated) belongs
        inside the callback Controller.ps1 builds, not here.
    .OUTPUTS
        @{ ConvertedSuccess; ConvertedFail; ConvertedSkipped;
           DeletedSuccess; DeletedFail; StaleCleanedSuccess;
           StaleCleanedFail; ForceKilledCount; InspectFailedCount;
           LastCompletedPaths; LastSkippedPaths; StillPendingPaths;
           SeriesCount; ChapterCount; Aborted } - InspectFailedCount is
        the sum of every chapter's Convert-ImageBatch InspectFailedCount
        (AVIF files whose animation status couldn't be determined).
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
        [string[]]$LooseImageExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif"),
        [string[]]$KnownZipPaths = @(),
        [string[]]$FolderQualifyingExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif"),
        [System.Collections.Generic.HashSet[string]]$FolderExcludeStagingDirs = $null,
        [scriptblock]$PostChapterCallback = $null,
        [scriptblock]$ZipStepCallback = $null,
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
        InspectFailedCount  = 0
        LastCompletedPaths  = [System.Collections.Generic.List[string]]::new()
        LastSkippedPaths    = [System.Collections.Generic.List[string]]::new()
        StillPendingPaths   = [System.Collections.Generic.List[string]]::new()
        SeriesCount         = 0
        ChapterCount        = 0
        Aborted             = $false
    }

    # Registered for the whole pipeline call (one phase), not per-series/
    # per-chapter - matches Register-AbortCancellationSource's own "call
    # once per pipeline phase" contract. Without this, Test-AbortSignal
    # would never actually cancel $looseCts, and Convert-ImageBatch's own
    # CancelToken check would never fire on a real Ctrl+C - see this
    # module's header for how that was caught.
    $looseCts = [System.Threading.CancellationTokenSource]::new()
    Register-AbortCancellationSource -Cts $looseCts
    try {
        $seriesProvider = New-SeriesProvider -LibraryPath $Path

        while ($true) {
            if (Test-AbortSignal) { $totals.Aborted = $true; break }

            $series = & $seriesProvider
            if ($null -eq $series) { break }
            $totals.SeriesCount++

            $chapters = Get-SeriesChapters -SeriesPath $series.FullName -QualifyingExtensions $FolderQualifyingExtensions `
                -ExcludeStagingDirs $FolderExcludeStagingDirs -ForceRezip $false

            # Bounded to this one series, not the whole library - see this
            # module's header and CLAUDE.md's pre-flight note. Computed
            # BEFORE Start-SeriesProgress (not after, as an earlier version
            # of this rework had it) - see the $chapterEntries merge below
            # for why the real per-series total needs this first.
            $seriesCandidates = Get-LooseImageCandidates -ScanPath $series.FullName -LooseImageExtensions $LooseImageExtensions -KnownZipPaths $KnownZipPaths -ExcludeStagingDirs $FolderExcludeStagingDirs

            $staleResult = Remove-StaleLooseSources -StaleSources $seriesCandidates.StaleSources
            $totals.StaleCleanedSuccess += $staleResult.Success
            $totals.StaleCleanedFail    += $staleResult.Fail

            # Get-SeriesChapters is a thin wrapper on the zip-domain
            # Get-ZippableLeafDirs (see LeafDirectoryDiscovery.ps1) - its
            # former-container guard (skip a dir with a stray .zip inside)
            # and zip-staleness guard (skip a dir whose same-named .zip is
            # already newer than every image in it) exist to decide "is
            # this worth re-zipping", not "does this need converting". Using
            # $chapters alone to decide what gets converted would silently
            # drop real unconverted images sitting in a directory those
            # guards happen to exclude (a leftover .zip alongside fresh
            # loose images, or images sitting directly in the series root
            # rather than a chapter subfolder) - a real regression against
            # the old flat whole-library scan, caught by review rather than
            # by the harness (see CHANGELOG.md). Fix: still use $chapters
            # for the declared per-chapter progress slots, but fold in any
            # OTHER directory that actually holds a needs-conversion image,
            # so conversion coverage can never silently regress just
            # because a directory doesn't currently look "zip-worthy".
            #
            # An EXTRA entry must NOT be treated as zippable: it carries
            # IsZippable=$false / ZipOut=$null (a real chapter keeps
            # $c.ZipOut) - a caller wiring -PostChapterCallback to
            # ZipPipeline.ps1's Invoke-LooseFolderZip (mode 2, exactly as
            # this function's own .PARAMETER text above describes) must
            # check IsZippable first. Without this, an extra like the
            # series root itself would get wrapper-zipped once every real
            # chapter around it is already zipped and deleted - precisely
            # the container-folder mess the former-container guard exists
            # to prevent in the first place, reached through the back door
            # (caught in review).
            #
            # $imagesByDir groups $seriesCandidates.NeedsConversion by
            # directory ONCE and is reused below both to find extras and to
            # look up each real chapter's own images - avoids both a
            # redundant Group-Object over every chapter's images just to
            # discard most of the groups, and the O(chapters x
            # images-in-series) rescan a separate per-chapter Where-Object
            # would otherwise do (also caught in review). -ExcludeStagingDirs
            # is now passed straight into Get-LooseImageCandidates above, so
            # $seriesCandidates.NeedsConversion already never contains a
            # staging-dir image in the first place - no second staging check
            # is needed here (a caught-in-review duplicate of
            # Test-ZippableLeafDirCandidate's own staging-prefix test used
            # to live in this loop).
            $imagesByDir = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[System.IO.FileInfo]]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($img in $seriesCandidates.NeedsConversion) {
                if (-not $imagesByDir.ContainsKey($img.DirectoryName)) {
                    $imagesByDir[$img.DirectoryName] = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
                }
                $imagesByDir[$img.DirectoryName].Add($img)
            }

            $chapterDirSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $chapterEntries = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($c in $chapters) {
                $null = $chapterDirSet.Add($c.Dir.FullName)
                $chapterEntries.Add(@{ Dir = $c.Dir; ZipOut = $c.ZipOut; IsZippable = $true })
            }
            foreach ($extraDirPath in $imagesByDir.Keys) {
                if ($chapterDirSet.Contains($extraDirPath)) { continue }

                $extraDir = $imagesByDir[$extraDirPath][0].Directory
                $chapterEntries.Add(@{ Dir = $extraDir; ZipOut = $null; IsZippable = $false })
                Write-Log ("Series '" + $series.Name + "': '" + $extraDir.Name + "' has unconverted image(s) but wasn't found by chapter discovery (e.g. a stray .zip sitting alongside it, or images outside a normal chapter folder) - converting it anyway, but NOT treating it as zippable.") -Level Warn
            }

            if ($script:CleanConsoleOutputEnabled) {
                Start-SeriesProgress -SeriesName $series.Name -TotalChapters $chapterEntries.Count
            }

            if ($chapterEntries.Count -eq 0) {
                Write-Log ("Series '" + $series.Name + "': no qualifying chapters found.") -Level Info
                continue
            }

            Write-Log ("=== Series '" + $series.Name + "': " + $chapterEntries.Count + " chapter(s) ===")

            foreach ($chapter in $chapterEntries) {
                if (Test-AbortSignal) { $totals.Aborted = $true; break }

                $chapterDir  = $chapter.Dir
                $chapterName = $chapterDir.Name
                $totals.ChapterCount++

                if ($script:CleanConsoleOutputEnabled) {
                    Start-ChapterProgress -SeriesName $series.Name -ChapterName $chapterName
                }

                $chapterImages = @()
                if ($imagesByDir.ContainsKey($chapterDir.FullName)) { $chapterImages = @($imagesByDir[$chapterDir.FullName]) }

                $chapterResult = $null
                if ($chapterImages.Count -gt 0) {
                    Write-Log ("Processing chapter: '" + $chapterDir.FullName + "' (" + $chapterImages.Count + " image(s))")

                    $localLastCompleted = $totals.LastCompletedPaths
                    # $alreadyAbortedBox (a hashtable, not a plain scalar) is
                    # how "was it already aborted last poll" survives across
                    # invocations of this closure - .GetNewClosure() puts the
                    # scriptblock in its OWN dynamic module, so a direct
                    # $script:abortRequested read/write here would silently
                    # read/mutate a frozen, disconnected copy, never
                    # AbortPipeline.ps1's real one (live-reproduced: read the
                    # real, current state through Test-AbortSignal's RETURN
                    # VALUE - a genuine function call, not a $script: access -
                    # and track the previous poll's result in a captured
                    # reference-type object instead, same discipline as the
                    # "closures mutating state" entry in CLAUDE.md's Lessons
                    # learned).
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

                    $chapterResult = Convert-ImageBatch -ImageFiles $chapterImages -CjxlExe $CjxlExe -MagickExe $MagickExe `
                        -DoJpegLossless $JpegLossless -DoJpegQuality $JpegQuality -MaxCjxlProcs $MaxCjxlProcs `
                        -DoFullLogging $FullLogging -CancelToken $looseCts.Token -ItemNoun "loose image" `
                        -SourceNoun "loose source image" -AbortPollCallback $abortPoll `
                        -AbortWaitMessage "[ABORT] Waiting for current loose-image jobs to finish (up to $AbortTimeoutSeconds s)..." `
                        -AbortTimeoutSeconds $AbortTimeoutSeconds

                    $totals.ConvertedSuccess    += $chapterResult.ConvertedCount
                    $totals.ConvertedFail       += $chapterResult.FailedCount
                    $totals.ConvertedSkipped    += $chapterResult.SkippedCount
                    $totals.DeletedSuccess      += $chapterResult.DeletedCount
                    $totals.DeletedFail         += $chapterResult.DeleteFailedCount
                    $totals.ForceKilledCount    += $chapterResult.ForceKilledCount
                    $totals.InspectFailedCount  += $chapterResult.InspectFailedCount
                    foreach ($p in $chapterResult.SkippedPaths) { $totals.LastSkippedPaths.Add($p) }
                    foreach ($p in $chapterResult.PendingPaths) { $totals.StillPendingPaths.Add($p) }
                    if ($looseCts.Token.IsCancellationRequested) { $totals.Aborted = $true }
                } else {
                    Write-Log ("Chapter '" + $chapterDir.FullName + "': no unconverted images - skipping conversion.")
                }

                # Computed unconditionally (not just when CCR is enabled) -
                # -ZipStepCallback's own IsZippable/Error gate below needs
                # $chapterStatus regardless of whether progress is being
                # displayed. Only the actual Complete-ChapterProgress CALL
                # stays gated on the toggle, same as everywhere else in
                # this module.
                $chapterStatus, $chapterDetail = Get-ChapterProgressStatus -ChapterResult $chapterResult

                # Mode 8's decided CCR-fold (Todo.md/Docs/menu-design.md,
                # 2026-08-28): delay Complete-ChapterProgress until after
                # the zip step returns, merge both outcomes into ONE
                # Detail/Status - not a second CCR transition. Gated on
                # IsZippable (an "extra" entry, e.g. the series root, is
                # never zippable - same rule Controller.ps1's Full Pipeline
                # zip step follows) AND $chapterStatus -ne 'Error' (don't
                # zip a chapter conversion already failed) - both checks
                # live HERE, in this module's own domain knowledge, not in
                # the callback itself, which stays a dumb "just zip or
                # don't" hook (mode-8-specific business logic like
                # ZipWithUnconvertedAnimated belongs in the callback
                # Controller.ps1 builds, not here).
                if ($null -ne $ZipStepCallback -and $chapter.IsZippable -and $chapterStatus -ne 'Error') {
                    $zipOutcome = & $ZipStepCallback @{ SeriesName = $series.Name; ChapterName = $chapterName; Dir = $chapterDir; ChapterResult = $chapterResult; ZipOut = $chapter.ZipOut }
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

                if ($script:CleanConsoleOutputEnabled) {
                    $null = Complete-ChapterProgress -SeriesName $series.Name -ChapterName $chapterName -Status $chapterStatus -Detail $chapterDetail
                }

                if ($null -ne $PostChapterCallback) {
                    & $PostChapterCallback @{ SeriesName = $series.Name; ChapterName = $chapterName; Dir = $chapterDir; ChapterResult = $chapterResult; ZipOut = $chapter.ZipOut; IsZippable = $chapter.IsZippable }
                }
            }
        }
    } finally {
        Unregister-AbortCancellationSource -Cts $looseCts
        $looseCts.Dispose()
        # Safety net for the abort/shutdown path - a series left mid-flight
        # (some chapters never reaching Complete-ChapterProgress) needs
        # force-resolving so it doesn't sit open in CCR's registry forever.
        # A no-op when nothing is still active (the common, non-aborted
        # case - every series already resolved itself as its last chapter
        # completed).
        if ($script:CleanConsoleOutputEnabled) {
            $null = Complete-AllActiveSeriesProgress
        }
    }

    return $totals
}

function Get-ImageConversionSharedFunctionNames {
    <#
    .SYNOPSIS
        The function names a caller must add to its own -SharedFunctionNames
        list (Invoke-ZipParallelProcessing) to safely call Convert-ImageBatch
        from inside a runspace worker - single source of truth for this
        group (see Logging.ps1's Get-LoggingSharedFunctionNames for why this
        exists). Includes Test-AvifAnimated (AnimatedConversionPipeline.ps1)
        since Convert-ImageBatch's own static-AVIF path calls it directly -
        a real cross-module dependency, not an oversight. Does NOT include
        Write-GatedConsoleMessage: Convert-ImageBatch's own straggler-drain
        can call it, but propagating it is unsafe (CleanConsoleRendering.ps1's
        module-scope state is never initialized inside a fresh runspace) -
        see CLAUDE.md's Known gaps / CHANGELOG.md 2026-08-29 for the real
        gap this leaves (deliberately, not an oversight either).
    #>
    return @('Convert-ImageBatch', 'Complete-ImageConversionJob', 'Invoke-IccStripRetryOrFail', 'Test-AvifAnimated')
}
