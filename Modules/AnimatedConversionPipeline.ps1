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
      - $script:CleanConsoleOutputEnabled, Write-GatedConsoleMessage
        (Modules\CleanConsoleRendering.ps1) - PART 1's own
        Convert-AnimatedBatch needs these too now, to gate its straggler-
        drain wait message the same way ImageConversionPipeline.ps1's
        Convert-ImageBatch does (a raw Write-Host there would corrupt
        CCR's live region mid-redraw). Write-GatedConsoleMessage takes
        the toggle as an explicit param rather than reading
        $script:CleanConsoleOutputEnabled itself (CleanConsoleRendering.ps1
        has no forward references of its own) - this call site supplies it.
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

    # Format string includes a trailing \n (2026-09-01 live-shakedown fix):
    # `identify` runs its -format string once PER FRAME in the sequence,
    # with no separator between repetitions unless the format string
    # supplies one. On a real multi-frame AVIF (confirmed live against
    # this machine's actual libjxl/ImageMagick install, not just the
    # harness's fake magick.exe), a bare "%n" therefore produced e.g. a
    # 96-frame file's stdout as "96" repeated 96 times concatenated with
    # no boundary ("96969696...", 192 chars) - un-parseable as an int, so
    # this function threw on EVERY genuinely animated AVIF on this
    # system, misclassifying every one as unclassifiable. Since %n (total
    # frame count) is identical on every repetition, adding "\n" lets us
    # split on newlines and just read the first line - correct for any
    # frame count, including the single-frame/static case (one "1\n").
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $MagickExe
    $psi.Arguments              = "identify -format `"%n\n`" `"" + $AvifPath + "`""
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    # ReadToEndAsync (2026-08-31 fix, from a same-day /code-review) - both
    # streams redirected, both read synchronously to completion BEFORE
    # WaitForExit(), used to risk the classic Process redirect deadlock:
    # magick identify on a malformed/corrupt AVIF (a real, expected input
    # here, since this function exists specifically to classify
    # ambiguous files) can write enough to stderr to fill the OS pipe
    # buffer before closing stdout - the child then blocks writing to a
    # full, unread stderr pipe while this synchronous ReadToEnd() blocks
    # waiting for stdout to close, a true deadlock hanging the entire
    # calling thread (this function runs inline in the main dispatch
    # loop's slot-filling loop, so a hang here stalls the whole batch).
    # Every OTHER completion path in this project's two conversion
    # pipelines only reads output after HasExited is already observed
    # true, so the child's pipes can't still be filling - this was the
    # one place reading while the process could still be running. Fixed
    # by draining both streams asynchronously (so neither pipe can fill
    # up unread) before WaitForExit(), the standard .NET-recommended
    # pattern for this exact problem.
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $code = $proc.ExitCode
    } finally {
        # try/finally (2026-08-31 fix): Dispose() used to only run after
        # every read/wait call above succeeded - a throw from any of them
        # (e.g. an I/O error reading a redirected stream) skipped it
        # entirely, leaking the process handle.
        $proc.Dispose()
    }

    if ($code -ne 0) {
        throw ("magick identify exited " + $code + ". Stderr: " + $stderr.Trim())
    }

    $firstLine = ($stdout -split "`r?`n" | Where-Object { $_ -ne "" } | Select-Object -First 1)
    $frameCount = 0
    if ($null -eq $firstLine -or -not [int]::TryParse($firstLine.Trim(), [ref]$frameCount)) {
        throw ("magick identify returned a non-numeric frame count: '" + $stdout.Trim() + "'")
    }

    return ($frameCount -gt 1)
}

function Complete-AnimatedConversionJob {
    <#
    .SYNOPSIS
        Private helper - handles one finished job's process cleanup,
        exit-code/output verification, and (on success) source deletion,
        mutating $BatchResult in place. Shared by Convert-AnimatedBatch's
        main dispatch loop and its straggler-drain loop, which previously
        each implemented this ~35-line block almost verbatim - the only
        real differences were the drain copy skipping the -DoFullLogging
        stdout dump and the success log message (no byte count, "(abort
        drain)" wording instead), both captured here via -IsAbortDrain.
    .PARAMETER IsAbortDrain
        $true from the straggler-drain loop; $false (default) from the
        main dispatch loop - see SYNOPSIS for what this changes.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Job,
        [Parameter(Mandatory)]
        [hashtable]$BatchResult,
        [bool]$DoFullLogging,
        [bool]$DoAnimatedDeleteSource,
        [System.Threading.SemaphoreSlim]$SharedBudget,
        [bool]$IsAbortDrain = $false
    )

    # try/finally (2026-08-31 fix, caught by verifying this same day's
    # /code-review 4th pass on the sibling ImageConversionPipeline.ps1,
    # which found and fixed the identical gap in its own
    # Complete-ImageConversionJob first): this is the one place a RUNNING
    # job's process handle and SharedBudget slot get released - unlike
    # every other resource-release path in this file, it wasn't guarded.
    # A throw from ReadToEnd/ExitCode (unlikely on an already-exited
    # process, but not impossible) used to skip Dispose() AND Release()
    # entirely and propagate straight out of Convert-AnimatedBatch - a
    # permanently leaked SemaphoreSlim slot for the rest of the run under
    # Controller.ps1's Full Pipeline, where the budget is shared with the
    # image engine.
    try {
        $stdout = $Job.Proc.StandardOutput.ReadToEnd()
        $stderr = $Job.Proc.StandardError.ReadToEnd()
        $code   = $Job.Proc.ExitCode
    } finally {
        $Job.Proc.Dispose()
        if ($SharedBudget) { $SharedBudget.Release() | Out-Null }
        # SlotReleased marker (2026-08-31 fix, mirrors the sibling module's
        # identical fix, INCLUDING the data-loss correction a later
        # verification pass found there - see Convert-AnimatedBatch's own
        # outer catch below for the full reasoning) - lets that catch tell
        # a job whose own cleanup already ran apart from one genuinely
        # still running, both for the SharedBudget double-release risk AND
        # for not deleting an already-converted job's real output.
        $Job.SlotReleased = $true
    }

    if (-not $IsAbortDrain -and $DoFullLogging -and -not [string]::IsNullOrWhiteSpace($stdout)) {
        Write-Log ("magick stdout for '" + $Job.SrcPath + "': " + $stdout.Trim())
    }

    $convOk = $false
    try {
        if ($code -ne 0) { throw ("magick exited with code " + $code + ". Stderr: " + $stderr) }
        # Get-Item -ErrorAction SilentlyContinue instead of a separate
        # Test-Path + Get-Item pair (2026-08-31 efficiency fix) - one stat
        # instead of two, for every completed job.
        $webpItem = Get-Item -LiteralPath $Job.MagickOutputPath -ErrorAction SilentlyContinue
        if ($null -eq $webpItem) { throw ("Output .webp was not created: '" + $Job.MagickOutputPath + "'") }
        $webpSize = $webpItem.Length
        if ($webpSize -eq 0) { throw ("Output .webp is 0 bytes: '" + $Job.MagickOutputPath + "'") }
        # Move the verified-good temp file into place (2026-08-31 fix) -
        # only when magick was pointed at a temp path in the first place
        # (an overwrite of a pre-existing file - see $j.MagickOutputPath's
        # own comment in Convert-AnimatedBatch for why). The real WebpPath
        # is only ever replaced HERE, after full verification, never by
        # magick itself - so a crash/force-kill mid-encode can no longer
        # damage the original.
        #
        # [System.IO.File]::Replace, NOT Move-Item -Force (2026-08-31
        # correction, found by a same-day /code-review re-review):
        # confirmed directly against PowerShell's own real source
        # (FileSystemProvider's MoveFileInfoItem) that Move-Item -Force
        # onto an EXISTING destination is NOT atomic - it deletes the
        # destination, then makes a SEPARATE MoveTo call to rename the
        # source into place. A crash, kill, or a locked-file/out-of-space
        # error landing in that gap deletes the original good .webp
        # without ever completing the rename - BOTH files gone, strictly
        # worse than the in-place-corruption bug this whole mechanism
        # exists to prevent. File.Replace wraps the Win32 ReplaceFile API,
        # which performs the swap as one atomic operation on NTFS - always
        # safe here since $Job.MagickOutputPath is always in the same
        # directory (and therefore volume) as $Job.WebpPath, and this
        # branch is only reached when WebpPath is already known to exist
        # (that's the entire reason a temp path was used in the first
        # place).
        #
        # A real (non-$null) -destinationBackupFileName is required
        # (verified directly on this machine's real PowerShell 5.1/.NET
        # Framework): passing $null throws "The path is not of a legal
        # form", even though .NET's own documentation says null should be
        # accepted to skip the backup. A throwaway backup path is used and
        # then best-effort deleted immediately after - it's a byte-for-byte
        # copy of the .webp being replaced, which is exactly the file
        # already fully verified above, so there's nothing worth keeping
        # once the atomic swap has actually completed.
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
        # Always safe to delete $Job.MagickOutputPath on failure now
        # (2026-08-31 fix): it's either a dedicated temp path magick wrote
        # to (an overwrite case - never the original file, safe
        # unconditionally) or, when there was no pre-existing file to
        # protect, it's $Job.WebpPath itself, which is exactly the
        # "genuine partial/corrupt file this attempt itself created" case
        # that was already safe to delete before this fix. Either way,
        # the ORIGINAL good .webp (when one existed) was never touched by
        # magick in the first place, so there's nothing to preserve here
        # the way the old WebpExistedBeforeJob check on $Job.WebpPath had
        # to. The inner catch is swallowed deliberately - best-effort
        # cleanup of a temp/partial file; a locked-file delete failure
        # here just leaves that harmless leftover for a later run to
        # pick up, not worth failing the whole batch over. No Test-Path
        # guard needed (2026-08-31 efficiency fix) - File.Delete on a
        # missing path is already a safe no-op, confirmed directly.
        try { [System.IO.File]::Delete($Job.MagickOutputPath) } catch { }
        # $webpReplaceBackup cleanup (2026-08-31 fix, found by a THIRD
        # same-day /code-review pass): it was only ever deleted on the
        # success path (right after File.Replace itself succeeds) - if
        # File.Replace THROWS (e.g. a momentary lock on $Job.WebpPath),
        # execution lands here instead, and the backup - a full copy of
        # the pre-replace .webp, already-verified content with nothing
        # worth keeping - was never cleaned up. $webpReplaceBackup is
        # $null here if this failure happened before that code ever ran
        # (or $Job.MagickOutputPath -eq $Job.WebpPath, meaning no backup
        # was ever created), so this is safe unconditionally.
        if ($webpReplaceBackup) { try { [System.IO.File]::Delete($webpReplaceBackup) } catch { } }
    }

    if ($convOk -and $DoAnimatedDeleteSource) {
        try {
            $null = Remove-Source -ItemPath $Job.SrcPath
            $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
            Write-Log ("Deleted source (" + $deleteDesc + "): '" + $Job.SrcPath + "'")
            $BatchResult.DeletedCount++
        } catch {
            Write-Log ("FAILED to delete source '" + $Job.SrcPath + "': " + $_) -Level Error
            $BatchResult.DeleteFailedCount++
        }
    }
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
        [System.Threading.SemaphoreSlim]$SharedBudget = $null,
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

    # try/catch around the whole dispatch loop (2026-08-31 fix, mirrors
    # Convert-ImageBatch's identical fix in the sibling module - see that
    # function's own header comment for the full reasoning: every OTHER
    # exit from this loop already releases every running job's process
    # handle and SharedBudget slot, but an unexpected throw from inside
    # the loop itself (-AbortPollCallback, Write-Log on a locked log file,
    # a rethrow from Complete-AnimatedConversionJob) had no such
    # guarantee).
    try {
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
            # Wrapped in try/catch (2026-08-31 fix) - see Convert-ImageBatch's
            # identical fix (ImageConversionPipeline.ps1) for the full
            # reasoning: a raw .NET exception from Process.Start() below (a
            # stale cached -MagickExe path, etc.) is not a terminating error
            # in this scriptblock, so without this it would keep going with
            # $j.Proc left $null - that job then sits in $running forever
            # (HasExited on $null never becomes true) and hangs the whole
            # dispatch loop indefinitely instead of failing that one job.
            try {

            # Computed once, reused below for WebpExistedBeforeJob
            # (2026-08-31 efficiency fix) - this same path was being
            # stat'd twice per dispatched job.
            $webpPathExists = Test-Path -LiteralPath $j.WebpPath
            if ($webpPathExists -and -not $DoAnimatedOverwrite) {
                Write-Log ("SKIPPING '" + $j.SrcPath + "': output '" + $j.WebpPath + "' already exists (Overwrite is off).")
                $batchResult.SkippedCount++
                $batchResult.SkippedPaths.Add($j.SrcPath)
                if ($SharedBudget) { $SharedBudget.Release() | Out-Null }
                continue
            }

            # -KnownAnimatedPaths (2026-08-31 efficiency fix): Controller.ps1's
            # Full Pipeline already ran Test-AvifAnimated on every ambiguous
            # .avif during its own per-series ownership classification,
            # before ever dispatching to this function - re-running it here
            # for every one of those files was a pure redundant magick
            # identify spawn per file. A file already confirmed animated by
            # the caller skips the re-check entirely; anything NOT in the
            # set (standalone mode 3, or any caller that never classified)
            # falls through to the real check unchanged.
            $isAnimated = $false
            if ($KnownAnimatedPaths -and $KnownAnimatedPaths.Contains($j.SrcPath)) {
                $isAnimated = $true
            } else {
                try {
                    $isAnimated = Test-AvifAnimated -AvifPath $j.SrcPath -MagickExe $MagickExe
                } catch {
                    Write-Log ("Could not determine if '" + $j.SrcPath + "' is animated - skipping: " + $_) -Level Warn
                    $batchResult.InspectFailedCount++
                    if ($SharedBudget) { $SharedBudget.Release() | Out-Null }
                    continue
                }
            }

            if (-not $isAnimated) {
                Write-Log ("'" + $j.SrcPath + "' is a static AVIF (not animated) - left unconverted.")
                $batchResult.StaticSkippedCount++
                $batchResult.StaticSkippedPaths.Add($j.SrcPath)
                if ($SharedBudget) { $SharedBudget.Release() | Out-Null }
                continue
            }

            # Captured BEFORE Process.Start() - Complete-AnimatedConversionJob's
            # $j.MagickOutputPath (2026-08-31 fix, from a same-day
            # /code-review): a plain WebpExistedBeforeJob delete-guard
            # (this attempt's own failure cleanup checking whether
            # $j.WebpPath already existed before deciding it's safe to
            # delete) only ever protected a pre-existing .webp from THIS
            # SCRIPT's own Delete calls - it did nothing to stop magick.exe
            # itself from opening and overwriting that same path as ITS OWN
            # output target. With -DoAnimatedOverwrite on (a real,
            # menu-exposed setting), magick writing straight to an existing
            # good .webp and then crashing/being force-killed/exiting
            # non-zero PARTWAY through encoding already destroys the
            # original - by the time cleanup code declines to delete it,
            # the damage is done. Fixed at the actual mechanism: when
            # overwriting an existing file, magick targets a TEMP path
            # instead of the real one; the real WebpPath is only replaced
            # (via File.Replace, in Complete-AnimatedConversionJob) after a
            # verified-successful conversion. When there's no pre-existing
            # file to protect, magick still writes directly to WebpPath as
            # before - nothing to lose in that case, and no temp-file/move
            # overhead added for the common (non-overwrite) path.
            # ($webpPathExists, computed just above, doubles as this
            # decision - no separate job-hashtable field needed once
            # Complete-AnimatedConversionJob stopped consuming one
            # directly, per this same fix.)
            # $j.TempOverwritePath (2026-08-31 fix, caught by verifying this
            # same day's /code-review 4th pass): mirrors the sibling
            # module's $j.TempPng field - a SEPARATE handle on the temp
            # overwrite file, distinct from $j.MagickOutputPath, so the
            # outer dispatch-loop catch below can delete it UNCONDITIONALLY
            # (like the sibling deletes TempPng) instead of only when
            # SlotReleased is false. Without this, a job whose own
            # Complete-AnimatedConversionJob call threw AFTER its
            # SlotReleased-setting finally (the unguarded "magick stdout
            # for" Write-Log call is the realistic trigger) left its
            # "_tmp_overwrite.webp" debris on disk forever - SlotReleased
            # being true correctly protects a job's REAL output
            # ($j.MagickOutputPath when it equals $j.WebpPath) from the
            # outer catch, but a temp overwrite file isn't real output, the
            # same way TempPng isn't in the sibling module. $null when
            # there's no pre-existing file to protect (magick writes
            # directly to $j.WebpPath in that case - nothing to clean up).
            $j.TempOverwritePath = if ($webpPathExists) {
                [System.IO.Path]::Combine(
                    [System.IO.Path]::GetDirectoryName($j.WebpPath),
                    [System.IO.Path]::GetFileNameWithoutExtension($j.WebpPath) + "_tmp_overwrite.webp"
                )
            } else {
                $null
            }
            $j.MagickOutputPath = if ($j.TempOverwritePath) { $j.TempOverwritePath } else { $j.WebpPath }

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $MagickExe
            $qualityArg = if ($DoAnimatedLossless) { "-define webp:lossless=true" } else { "-quality " + $AnimatedQuality }
            $psi.Arguments = "`"" + $j.SrcPath + "`" -coalesce -loop 0 " + $qualityArg + " `"" + $j.MagickOutputPath + "`""
            $psi.UseShellExecute        = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow         = $true

            Write-Log ("Converting animated: '" + $j.SrcPath + "'")

            $j.Proc          = [System.Diagnostics.Process]::Start($psi)
            $j.StartTime     = [System.Diagnostics.Stopwatch]::StartNew()
            $j.LastHeartbeat = [timespan]::Zero
            $running.Add($j)
            } catch {
                Write-Log ("FAILED to start conversion process for '" + $j.SrcPath + "': " + $_) -Level Error
                $batchResult.FailedCount++
                if ($SharedBudget) { $SharedBudget.Release() | Out-Null }
            }
        }

        # Poll for finished processes; heartbeat any still running past the threshold
        $stillRunning = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($j in $running) {
            if ($j.Proc.HasExited) {
                Complete-AnimatedConversionJob -Job $j -BatchResult $batchResult -DoFullLogging $DoFullLogging -DoAnimatedDeleteSource $DoAnimatedDeleteSource -SharedBudget $SharedBudget
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

        # Always sleep briefly here - see Convert-ImageBatch's identical
        # fix (ImageConversionPipeline.ps1) for the full reasoning: the
        # outer while's own condition already guarantees there's work left
        # whenever execution reaches this point, and the old conditional
        # check busy-spun at ~100% CPU whenever -SharedBudget was smaller
        # than $AnimatedThreads (the normal Full Pipeline case).
        Start-Sleep -Milliseconds 50
    }
    } catch {
        # Force-cleanup mirrors the force-kill block below (own try/catch
        # per step, same as every other cleanup path in this file) - best
        # effort, since we're already unwinding from an unexpected failure
        # and must not let a cleanup error mask or replace the real one.
        # $j.SlotReleased guards the Release() call AND the output-path
        # deletion (2026-08-31 fix, mirrors Convert-ImageBatch's identical
        # fix, INCLUDING the data-loss correction a verification pass
        # found there - this $running list is STALE, since the poll loop
        # above only reassigns it after its whole foreach pass completes,
        # so it can still list a job that ALREADY completed successfully
        # earlier in the SAME pass, source deleted and all, right
        # alongside a job that throws later in that pass. SlotReleased is
        # set in Complete-AnimatedConversionJob's own finally, true for
        # any job whose own cleanup already ran - success or failure,
        # doesn't matter which - false only for one genuinely still
        # running when this catch fires).
        foreach ($j in $running) {
            try { if ($j.Proc -and -not $j.Proc.HasExited) { $j.Proc.Kill() } } catch { }
            try { if ($j.Proc) { $j.Proc.WaitForExit(5000) } } catch { }
            # $j.TempOverwritePath cleanup is intentionally NOT guarded by
            # SlotReleased (2026-08-31 fix, mirrors the sibling module's
            # own TempPng cleanup - see this file's own comment at the
            # field's assignment above): it's never real output, regardless
            # of which state this job is in when the catch fires - still
            # genuinely encoding into it (real debris to clean up),
            # verified and already File.Replace'd into the real WebpPath
            # (this path is now stale, Delete is a safe no-op), or failed
            # (already deleted by Complete-AnimatedConversionJob's own
            # failure cleanup, same no-op) - so it's always safe to delete
            # unconditionally. $null when there was no pre-existing file to
            # protect in the first place (nothing to clean up).
            if ($j.TempOverwritePath) {
                try { [System.IO.File]::Delete($j.TempOverwritePath) } catch { }
            }
            # $j.MagickOutputPath itself IS guarded by SlotReleased - when
            # there was no pre-existing file to protect, it equals
            # $j.WebpPath directly (the job's REAL output), which a job
            # whose own cleanup already ran must not have touched.
            if (-not $j.SlotReleased) {
                try { [System.IO.File]::Delete($j.MagickOutputPath) } catch { }
            }
            try { if ($j.Proc) { $j.Proc.Dispose() } } catch { }
            if ($SharedBudget -and -not $j.SlotReleased) { try { $SharedBudget.Release() | Out-Null } catch { } }
        }
        throw
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
            Write-GatedConsoleMessage -Text $AbortWaitMessage -Color Yellow -CleanConsoleOutputEnabled ([bool]$script:CleanConsoleOutputEnabled)
        }
        $abortDeadline = [System.Diagnostics.Stopwatch]::StartNew()

        # try/catch around the whole straggler-drain body (2026-08-31
        # addition, project owner approved as an easy fix - mirrors both
        # this function's own outer dispatch-loop catch above AND the
        # identical fix applied to the sibling module's own straggler
        # drain: that outer catch only covers the MAIN loop, and an
        # unexpected throw here (Complete-AnimatedConversionJob's Write-Log
        # calls are all guarded by its own try/catch, so the realistic
        # trigger is the force-kill block's own unguarded "Force-stopping"
        # Write-Log call below) had no equivalent guard, leaking every
        # remaining drain-list job's process handle and SharedBudget slot.
        try {
            while ($running.Count -gt 0 -and $abortDeadline.Elapsed.TotalSeconds -lt $AbortTimeoutSeconds) {
                $stillWaiting = [System.Collections.Generic.List[hashtable]]::new()
                foreach ($j in $running) {
                    if ($j.Proc.HasExited) {
                        Complete-AnimatedConversionJob -Job $j -BatchResult $batchResult -DoFullLogging $DoFullLogging -DoAnimatedDeleteSource $DoAnimatedDeleteSource -SharedBudget $SharedBudget -IsAbortDrain $true
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
                    # Swallowed deliberately: a TOCTOU race between the
                    # HasExited check and Kill() (or an access-denied Kill()/
                    # WaitForExit()) would otherwise propagate out of an
                    # already-aborting run's own cleanup - best-effort only,
                    # matching this file's established best-effort cleanup
                    # idiom used throughout.
                    try { if (-not $j.Proc.HasExited) { $j.Proc.Kill() } } catch { }
                    try { $j.Proc.WaitForExit(5000) } catch { }
                    # Always safe to delete $j.MagickOutputPath (2026-08-31
                    # fix, mirrors Complete-AnimatedConversionJob's own failure
                    # cleanup - see that function's comment): it's either a
                    # dedicated temp path magick was writing to (an overwrite
                    # case, never the original file) or, when there was no
                    # pre-existing file, $j.WebpPath itself. A Ctrl+C during a
                    # -DoAnimatedOverwrite re-conversion pass force-killing a
                    # job mid-flight can no longer damage the pre-existing
                    # good .webp, since magick was never pointed at it
                    # directly in that case. The inner catch is swallowed
                    # deliberately, same reasoning as the identical cleanup in
                    # Complete-AnimatedConversionJob - best-effort only. No
                    # Test-Path guard needed - File.Delete on a missing path
                    # is already a safe no-op.
                    try { [System.IO.File]::Delete($j.MagickOutputPath) } catch { }
                    $j.Proc.Dispose()
                    if ($SharedBudget) { $SharedBudget.Release() | Out-Null }
                    # $j.SlotReleased = $true (2026-08-31 fix, mirrors the
                    # identical fix in the sibling module's own force-kill
                    # loop - see that file's comment for the full
                    # reasoning): without this, a throw partway through
                    # THIS loop would drop into the outer catch below,
                    # which re-iterates this same $running list and could
                    # release an already-released job's slot a second
                    # time.
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
                if ($SharedBudget -and -not $j.SlotReleased) { try { $SharedBudget.Release() | Out-Null } catch { } }
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
        Get-ChapterProgressStatus's severity ordering (Error > Warning >
        Success), both treating InspectFailedCount as Error-tier (2026-08-31
        fix - an inspect failure leaves a raw, completely unconverted file
        on disk, which must block the zip gate the same way a real
        conversion failure does). A $null $ChapterResult (nothing left to
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

    # InspectFailedCount is Error-tier, not Warning: unlike SkippedCount (a
    # file deliberately left alone because its output already exists - a
    # non-problem), an inspect failure means Test-AvifAnimated couldn't even
    # determine whether the file needs converting, so it was left as a raw,
    # completely unconverted .avif on disk. A Warning-tier chapter still
    # passes the zip gate (Controller.ps1's Invoke-FullPipelineChapter only
    # blocks on 'Error') - left as Warning, that raw file would get zipped
    # into the archive and its source folder deleted anyway. 2026-08-31 fix.
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
        # Kept as its own literal, not ImageConversionPipeline.ps1's shared
        # Get-LooseImageExtensions (2026-08-31), even though this is the
        # exact same list - this module's own harness dot-sources it
        # standalone, without ImageConversionPipeline.ps1, by design
        # (this project's "own standalone test harness, verified in
        # isolation" convention). A cross-module default-value dependency
        # would break that. Must be kept in sync by hand with the
        # canonical list if it ever changes - updated 2026-09-02 to add
        # ".gif"/".bmp"/".heic"/".heif" alongside that list's own same-day
        # addition.
        [string[]]$FolderQualifyingExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif", ".gif", ".bmp", ".heic", ".heif"),
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
    #
    # Construction/registration moved INSIDE the try (2026-08-31 fix, same
    # species as ZipParallelProcessing.ps1's mutex-leak fix earlier today) -
    # if either throws, the finally block below still runs and disposes
    # $animatedCts if it was actually created.
    try {
        $animatedCts = [System.Threading.CancellationTokenSource]::new()
        Register-AbortCancellationSource -Cts $animatedCts
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
        # $animatedCts can be unset if construction/registration itself
        # threw (now inside the try above).
        if ($animatedCts) {
            Unregister-AbortCancellationSource -Cts $animatedCts
            $animatedCts.Dispose()
        }
        # Safety net for the abort/shutdown path - same reasoning as
        # Invoke-LooseImageConversionPipeline's own finally block.
        if ($script:CleanConsoleOutputEnabled) {
            $null = Complete-AllActiveSeriesProgress
        }
    }

    return $totals
}

function Get-AnimatedConversionSharedFunctionNames {
    <#
    .SYNOPSIS
        The function names a caller must add to its own -SharedFunctionNames
        list (Invoke-ZipParallelProcessing) to safely call Convert-AnimatedBatch
        from inside a runspace worker - single source of truth for this
        group (see Logging.ps1's Get-LoggingSharedFunctionNames for why this
        exists). Does NOT include Write-GatedConsoleMessage - see
        Get-ImageConversionSharedFunctionNames's own docstring for why
        (same reason, same deliberate gap).
    #>
    return @('Convert-AnimatedBatch', 'Complete-AnimatedConversionJob', 'Test-AvifAnimated')
}
