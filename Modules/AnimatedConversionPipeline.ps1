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
    (Test-AvifAnimated, via `magick identify -ping -format "%T"` on
    frame [0] only - the animation delay, not a frame count) runs before
    each file is dispatched. A static AVIF (delay 0) is left untouched
    entirely - not converted, not deleted, not recorded as a failure.
    FLAGGED FOR FUTURE REVIEW, not decided or
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

    This module's own harness uses a compiled fake magick.exe stand-in
    (same technique as ImageConversionPipeline.Harness.ps1's fake
    cjxl.exe) to test the branching LOGIC (parse the delay value, static
    vs. animated, convert vs. skip) against 3 independent fake-magick.exe
    copies across this codebase (this module's own, plus
    Controller.Harness.ps1's and ImageConversionPipeline.Harness.ps1's) -
    Test-AvifAnimated's real classification method was additionally
    validated live against 9 real-world AVIF files across 3 independent
    encoders/pipelines (this project's own test library, link-u/
    avif-sample-images, and AOMediaCodec/libavif's own official animated
    conformance test files) before the 2026-09-09 rewrite was merged -
    see CHANGELOG.md's matching entry.

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
        for the same reasons; Invoke-ChapterDispatch (Modules\ChapterDispatch.ps1,
        2026-09-09 - see Invoke-LooseAnimatedConversionPipeline's own
        header for the migration this module was the first real caller
        of). NOT New-LibraryChapterProvider - that function's own header
        explains why this module builds its own -ChapterProvider closure
        instead.

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
        True if $AvifPath is animated - a real magick identify call reads
        the container's animation delay metadata (`-ping -format "%T\n"`
        on frame `[0]` only) rather than counting frames: nonzero delay
        means animated, "0" (no delay box at all) means static. Throws if
        magick itself fails or the output can't be parsed as an integer -
        callers decide how to treat that (this project's convention: log
        a Warn and skip, matching how a corrupt/unreadable file is
        treated elsewhere in this project, e.g. RezipPipeline.ps1's ZIP
        inspection).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$AvifPath,
        [Parameter(Mandatory)]
        [string]$MagickExe
    )

    # 2026-09-09 rewrite, real perf fix: the original method
    # (`identify -format "%n\n" <path>`, no frame index) makes ImageMagick
    # decode and enumerate EVERY frame in the sequence just to count them -
    # live-measured at 8-27s per file on real animated AVIFs, the dominant
    # cost in a run with many animated chapters. Addressing frame `[0]`
    # only, with `-ping` (skip pixel decode), and reading `%T` (the
    # animation delay, straight from container metadata) instead of `%n`
    # avoids touching any frame but the first - live-measured at
    # 0.15-0.35s per file, same real AVIFs, ~30-50x faster. Validated
    # against 9 real-world files across three independent
    # encoders/pipelines (this project's own crash-chapter AVIFs,
    # link-u/avif-sample-images' real photos including rotation/mirror/
    # EXIF variants, and AOMediaCodec/libavif's own official animated
    # conformance test files) - 9/9 correct, zero false positives or
    # negatives against the original frame-count method's own verdict.
    # `-ping` alone (no frame index) does NOT fix this - live-measured
    # still ~8s, since ImageMagick still enumerates every frame's own
    # container entry under `-ping`, it just skips decoding pixel data
    # for whichever frame(s) get loaded.
    #
    # Appending "[0]" to $AvifPath is safe even when the real filename or
    # an ancestor directory already contains literal "["/"]" (a genuinely
    # common scanlation-group naming convention, e.g.
    # "[Group] Series\Chapter [Special]\page[01].avif") - live-verified:
    # ImageMagick's own path parser only treats a TRAILING bracket
    # construct as a frame/scene selector, so an earlier bracket pair
    # anywhere else in the path never gets misread as one. Not a risk
    # this function had before, since it never used index syntax - now
    # confirmed safe rather than assumed so.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $MagickExe
    $psi.Arguments              = "identify -ping -format `"%T\n`" `"" + $AvifPath + "[0]`""
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
    $delay = 0
    if ($null -eq $firstLine -or -not [int]::TryParse($firstLine.Trim(), [ref]$delay)) {
        throw ("magick identify returned a non-numeric delay value: '" + $stdout.Trim() + "'")
    }

    return ($delay -gt 0)
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

        DOCUMENTED DUPLICATE (2026-09-09, mode 3's ChapterDispatch.ps1
        migration): the exit-code/File.Replace/delete-source portion of
        this function (everything after its own try/finally) is copied,
        not shared, into PART 2's Complete-AnimatedDispatchJob (see that
        function's own header for why - Invoke-ChapterDispatch owns
        process disposal/-SharedBudget release generically now, this
        function's own callers still don't). Keep both in sync if either
        changes.
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
        [bool]$IsAbortDrain = $false
    )

    # try/finally (2026-08-31 fix, caught by verifying this same day's
    # /code-review 4th pass on the sibling ImageConversionPipeline.ps1,
    # which found and fixed the identical gap in its own
    # Complete-ImageConversionJob first): this is the one place a RUNNING
    # job's process handle gets disposed - unlike every other resource-
    # release path in this file, it wasn't guarded. A throw from
    # ReadToEnd/ExitCode (unlikely on an already-exited process, but not
    # impossible) used to skip Dispose() entirely and propagate straight
    # out of Convert-AnimatedBatch.
    try {
        # Await the tasks started right after Process::Start (2026-09-08
        # fix) rather than a synchronous ReadToEnd() here - by the time
        # this function runs the process has already exited (both call
        # sites gate on HasExited first), so this just collects output
        # that was draining concurrently all along instead of being the
        # thing that could deadlock a chatty child. Falls back to a
        # synchronous read for any job that predates this field (defensive
        # only - every real dispatch path now sets it).
        $stdout = if ($Job.StdoutTask) { $Job.StdoutTask.GetAwaiter().GetResult() } else { $Job.Proc.StandardOutput.ReadToEnd() }
        $stderr = if ($Job.StderrTask) { $Job.StderrTask.GetAwaiter().GetResult() } else { $Job.Proc.StandardError.ReadToEnd() }
        $code   = $Job.Proc.ExitCode
    } finally {
        $Job.Proc.Dispose()
        # SlotReleased marker (2026-08-31 fix, mirrors the sibling module's
        # identical fix, INCLUDING the data-loss correction a later
        # verification pass found there - see Convert-AnimatedBatch's own
        # outer catch below for the full reasoning) - lets that catch tell
        # a job whose own cleanup already ran apart from one genuinely
        # still running, so it doesn't delete an already-converted job's
        # real output.
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
            # Return value checked, not discarded (2026-09-08 fix, same
            # species as this project's other Remove-Source call sites -
            # see FileDeletion.ps1's own .OUTPUTS) - Remove-Source returns
            # $false (not an exception) when the source already vanished
            # before deletion (a real TOCTOU gap). Neither a success nor a
            # real failure - left uncounted rather than falsely reporting
            # a delete that didn't happen.
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
    # exit from this loop already disposes every running job's process
    # handle, but an unexpected throw from inside the loop itself
    # (-AbortPollCallback, Write-Log on a locked log file, a rethrow from
    # Complete-AnimatedConversionJob) had no such guarantee).
    try {
    while (($pending.Count -gt 0 -or $running.Count -gt 0) -and (-not $CancelToken.IsCancellationRequested)) {

        if ($AbortPollCallback) {
            $inFlight = @($running | ForEach-Object { $_.SrcPath })
            & $AbortPollCallback $inFlight
        }

        # Fill up to AnimatedThreads slots.
        while ($pending.Count -gt 0 -and (-not $CancelToken.IsCancellationRequested) -and `
               $running.Count -lt $AnimatedThreads) {
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
                    continue
                }
            }

            if (-not $isAnimated) {
                Write-Log ("'" + $j.SrcPath + "' is a static AVIF (not animated) - left unconverted.")
                $batchResult.StaticSkippedCount++
                $batchResult.StaticSkippedPaths.Add($j.SrcPath)
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
            # Start draining both redirected streams immediately, not when
            # the job is later found HasExited (2026-09-08 fix, real bug -
            # same species as Convert-ImageBatch's own cjxl fix, missed
            # here at the time since this file's async magick dispatch is
            # polled the same way, not read synchronously inline): a magick
            # invocation that writes more than the OS pipe buffer to stderr
            # before exiting (e.g. per-frame warnings on a malformed/quirky
            # animated AVIF) would otherwise block on that write forever -
            # HasExited never becomes true, and this job sits in $running
            # for the rest of the run with no timeout. Live-reproduced.
            # Complete-AnimatedConversionJob awaits these tasks instead of
            # calling ReadToEnd() itself.
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

        # Poll for finished processes; heartbeat any still running past the threshold
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

        # Always sleep briefly here - see Convert-ImageBatch's identical
        # fix (ImageConversionPipeline.ps1) for the full reasoning: the
        # outer while's own condition already guarantees there's work left
        # whenever execution reaches this point.
        Start-Sleep -Milliseconds 50
    }
    } catch {
        # Force-cleanup mirrors the force-kill block below (own try/catch
        # per step, same as every other cleanup path in this file) - best
        # effort, since we're already unwinding from an unexpected failure
        # and must not let a cleanup error mask or replace the real one.
        # $j.SlotReleased guards the output-path deletion (2026-08-31 fix,
        # mirrors Convert-ImageBatch's identical fix, INCLUDING the
        # data-loss correction a verification pass found there - this
        # $running list is STALE, since the poll loop above only
        # reassigns it after its whole foreach pass completes, so it can
        # still list a job that ALREADY completed successfully earlier in
        # the SAME pass, source deleted and all, right alongside a job
        # that throws later in that pass. SlotReleased is set in
        # Complete-AnimatedConversionJob's own finally, true for any job
        # whose own cleanup already ran - success or failure, doesn't
        # matter which - false only for one genuinely still running when
        # this catch fires).
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
        # remaining drain-list job's process handle.
        try {
            # -not [ConsoleCtrl]::IsCloseEvent (2026-09-03 fix, real bug -
            # same reasoning as the sibling module's identical fix, see
            # ImageConversionPipeline.ps1's Convert-ImageBatch straggler
            # drain for the full writeup): Windows force-kills the whole
            # process ~5s after a CTRL_CLOSE_EVENT regardless of what this
            # drain does, so waiting out any part of -AbortTimeoutSeconds
            # can never fit - skip straight to the force-kill block below.
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
                if ($running.Count -gt 0) { Start-Sleep -Milliseconds 250 }
            }

            # One final completion-check pass before declaring anything
            # force-stopped (2026-09-03 fix, real bug found by code review
            # after the IsCloseEvent fast-path above was added) - same
            # reasoning as the sibling module's identical fix, see
            # ImageConversionPipeline.ps1's Convert-ImageBatch straggler
            # drain for the full writeup: IsCloseEvent can exit the while
            # loop above before even one poll of $running has happened, so a
            # job whose process had ALREADY exited successfully could still
            # be sitting in $running with nothing having checked HasExited
            # for it yet - without this pass, the force-kill block below
            # would delete that legitimate output as if it were partial/
            # corrupt from a killed process.
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
                    # $j.SlotReleased = $true (2026-08-31 fix, mirrors the
                    # identical fix in the sibling module's own force-kill
                    # loop - see that file's comment for the full
                    # reasoning): without this, a throw partway through
                    # THIS loop would drop into the outer catch below,
                    # which re-iterates this same $running list and could
                    # delete an already-processed job's real output a
                    # second time.
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
    # This condition + parts-building block is a deliberate duplicate of
    # ImageConversionPipeline.ps1's Get-ChapterProgressStatus (same four
    # fields, same Error-tier severity ordering) - keep both in sync.
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
    <#
    .SYNOPSIS
        JobFinalize-shaped completion handler for a job dispatched via
        Invoke-ChapterDispatch (mode 3's own migration onto
        ChapterDispatch.ps1, 2026-09-09 - see
        Docs\dispatch-redesign-design.md). Handles exit-code/output
        verification and (on success) source deletion, mutating
        $ChapterResult (this chapter's own per-chapter accumulator, built
        by Invoke-LooseAnimatedConversionPipeline's own JobBuilder) in
        place.

        DOCUMENTED DUPLICATE, not a call-through, of
        Complete-AnimatedConversionJob's own exit-code/File.Replace/
        delete-source logic (everything after that function's own
        try/finally) - see that function's own header for the cross-
        reference. Genuinely different contract, not a lazy copy:
        Complete-AnimatedConversionJob's caller (Convert-AnimatedBatch,
        still used only by that function's own harness now - no real
        caller left since Controller.ps1's Full Pipeline migrated onto
        Invoke-ChapterDispatch, step 4 of the dispatch redesign) owns
        process disposal itself; THIS function's caller
        (Invoke-ChapterDispatch) already owns process disposal AND its
        own -MaxConcurrent SemaphoreSlim release generically for every job
        on every exit path - duplicating either here would double-release
        the same slot. No -IsAbortDrain distinction either -
        Invoke-ChapterDispatch calls JobFinalize identically whether a
        job finished during normal polling or during the
        abort/drain window, so there's no separate wording variant to
        capture.
    .OUTPUTS
        @{ Success = [bool] } - Invoke-ChapterDispatch only cares that
        this is never @{ Requeued = $true } (mode 3 has no retry-requeue
        mechanism, unlike the image engine's ICC-strip retry).
    #>
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
        $webpItem = Get-Item -LiteralPath $Job.MagickOutputPath -ErrorAction SilentlyContinue
        if ($null -eq $webpItem) { throw ("Output .webp was not created: '" + $Job.MagickOutputPath + "'") }
        $webpSize = $webpItem.Length
        if ($webpSize -eq 0) { throw ("Output .webp is 0 bytes: '" + $Job.MagickOutputPath + "'") }
        # File.Replace, atomic swap - see Complete-AnimatedConversionJob's
        # own comment at its identical line for the full reasoning
        # (Move-Item -Force confirmed non-atomic on an existing
        # destination; a real, non-$null backup path is required on this
        # machine's real PS 5.1/.NET Framework).
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
    <#
    .SYNOPSIS
        Mode 3 ("Animated Conversion") end to end. Migrated 2026-09-09
        onto ChapterDispatch.ps1's Invoke-ChapterDispatch (step 2 of
        Docs\dispatch-redesign-design.md's 4-step migration order, mode 3
        chosen first as the simpler of the two conversion engines) -
        idle concurrency now picks up the NEXT chapter's jobs immediately
        instead of blocking on one chapter's Convert-AnimatedBatch call
        finishing before the next chapter's files are even enumerated.
        Walks the library the same two-tier way as before
        (New-SeriesProvider lazy across series, Get-SeriesChapters eager
        per series) via a custom -ChapterProvider closure (not
        ChapterDispatch.ps1's own New-LibraryChapterProvider - that
        function doesn't know about this module's own "extra chapter-
        equivalent entry" completeness fold-in below, which is genuinely
        per-engine domain logic, not something the generic primitive
        should own).

        Same chapter-discovery completeness handling as before:
        Get-SeriesChapters's former-container/zip-staleness guards decide
        "is this worth re-zipping", not "does this hold unconverted
        animated files" - a directory those guards exclude but that
        actually has .avif files needing conversion is folded in as an
        extra chapter-equivalent entry, so coverage can never silently
        regress the way it once did for images (see that module's own
        header for the real bug this already caught once there).

        WHAT MOVED WHERE, mapping today's callbacks onto
        Invoke-ChapterDispatch's seven scriptblocks: the -ChapterProvider
        closure below owns the series/chapter walk (same as before) and
        embeds each chapter's own AnimatedFiles list directly on the
        yielded chapter item; JobBuilder owns everything Convert-AnimatedBatch's
        own dispatch loop used to decide BEFORE ever acquiring a
        concurrency slot for a file (webp-already-exists skip, static-vs-
        animated classification via Test-AvifAnimated, the temp-overwrite-
        path decision) - moved here from mid-dispatch specifically so it
        happens in one clean pre-pass per chapter, matching
        Convert-ImageBatch's own already-more-mature pattern (see that
        function's own header) rather than porting Convert-AnimatedBatch's
        older "classify after acquiring a slot" shape as-is; JobStarter
        just spawns magick.exe; JobPollCompleted also owns heartbeat
        logging (the one place a still-running job's own "-HeartbeatIntervalSeconds
        elapsed" check has a natural home in this callback shape);
        JobFinalize is Complete-AnimatedDispatchJob (see that function's
        own header for why it's a documented duplicate of
        Complete-AnimatedConversionJob, not a call-through);
        JobAbortCleanup deletes a force-killed job's own TempOverwritePath/
        MagickOutputPath (both always safe to delete unconditionally here,
        unlike the old code's SlotReleased-guarded version - this
        callback is ONLY ever invoked for a job Invoke-ChapterDispatch
        confirms never reached JobFinalize, so there's no "already
        finalized earlier in this same pass" case to guard against, the
        exact ambiguity SlotReleased existed to resolve in the old,
        single-chapter-at-a-time code); ChapterCompleteCallback resolves
        CCR/the per-chapter PostChapterCallback and merges that chapter's
        own accumulator into $totals.

        A NEW per-chapter accumulator dictionary ($chapterResults, keyed
        by the exact chapterInfo value each chapter provider yields -
        matching ChapterDispatch.ps1's own chapter-identity contract)
        replaces the old code's implicit "one chapter, one blocking
        Convert-AnimatedBatch call" scoping - Invoke-ChapterDispatch now
        interleaves multiple chapters' jobs concurrently, so per-chapter
        results can no longer come from a single function call's own
        return value.

        NO LONGER A PER-CHAPTER .GetNewClosure() SCRIPTBLOCK: the old
        code built a fresh $abortPoll closure inside the per-chapter
        foreach loop, once per chapter (flagged in Todo.md as
        structurally similar to - though never confirmed as the actual
        cause of - the still-unexplained intermittent "Test-AbortSignal
        not recognized" crash in the sibling image-conversion module).
        This migration's JobBuilder/JobStarter/JobPollCompleted/
        JobFinalize/JobAbortCleanup/ChapterCompleteCallback/-AbortPollCallback
        are each built exactly ONCE, before Invoke-ChapterDispatch is
        ever called, not per chapter - there is no longer a closure
        recreated on every chapter iteration in this code path at all.
    .PARAMETER PostChapterCallback
        Invoked once per chapter with @{ SeriesName; ChapterName; Dir;
        ChapterResult } - $ChapterResult is $null when the chapter had no
        animated files to convert (unchanged contract).
    .OUTPUTS
        @{ ConvertedSuccess; ConvertedFail; ConvertedSkipped;
           StaticSkippedCount; InspectFailedCount; DeletedSuccess;
           DeletedFail; ForceKilledCount; LastCompletedPaths;
           LastSkippedPaths; LastStaticSkippedPaths; StillPendingPaths;
           SeriesCount; ChapterCount; Aborted } - unchanged shape, but
        LastCompletedPaths/StillPendingPaths are now always empty lists,
        not populated (a deliberate simplification, not an oversight -
        their old semantics were an "at the exact instant abort was
        detected" snapshot scoped to ONE chapter's own blocking batch
        call, which has no clean equivalent once dispatch spans the whole
        run and multiple chapters interleave; confirmed via a repo-wide
        grep that nothing outside this module and its own harness ever
        reads either field). LastSkippedPaths/LastStaticSkippedPaths are
        still fully populated - those were cheap to keep exact.
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

    # Per-chapter accumulator, keyed by the exact chapterInfo value each
    # chapter provider yields (see this function's own header) - built by
    # JobBuilder, mutated by JobFinalize, read and removed by
    # ChapterCompleteCallback.
    $chapterResults = [System.Collections.Generic.Dictionary[object,hashtable]]::new()

    # Captured once, read by every closure below instead of each one
    # reading $script:CleanConsoleOutputEnabled directly (2026-09-09,
    # real bug caught before this ever ran against a fake magick.exe -
    # see this function's own header's "GENUINE, PREVIOUSLY-UNDOCUMENTED
    # SCOPING HAZARD" note). Safe to snapshot once - nothing in this
    # project mutates this mid-run, only between runs.
    $cleanConsoleOutputEnabled = [bool]$script:CleanConsoleOutputEnabled

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

        # --- Chapter provider: same two-tier walk + extra-dir fold-in as
        #     before, restructured as a lazy "-> next chapter or $null"
        #     closure instead of a nested foreach - see this function's
        #     own header for why this isn't ChapterDispatch.ps1's
        #     New-LibraryChapterProvider. ---
        $seriesProvider  = New-SeriesProvider -LibraryPath $Path
        $chapterQueue    = [System.Collections.Generic.Queue[hashtable]]::new()
        $seriesExhausted = $false
        $chapterProvider = {
            while ($chapterQueue.Count -eq 0 -and -not $seriesExhausted) {
                $series = & $seriesProvider
                if ($null -eq $series) { $seriesExhausted = $true; break }
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

        # --- JobBuilder: pre-dispatch classification pre-pass, once per
        #     chapter (see this function's own header for why this moved
        #     here from mid-dispatch). ---
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

                $webpPathExists = Test-Path -LiteralPath $webpPath
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

                # Same temp-overwrite-path decision as Convert-AnimatedBatch's
                # own dispatch loop - see that function's own comment on
                # $j.TempOverwritePath/$j.MagickOutputPath for the full
                # "why a temp path" reasoning (magick must never write
                # straight over a pre-existing good .webp).
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
            $psi = New-Object System.Diagnostics.ProcessStartInfo
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
        }.GetNewClosure()

        # Heartbeat logging lives here (2026-09-09 - see this function's
        # own header for why this callback is its natural home): called
        # every poll pass for every still-running job, the same place the
        # old dispatch loop's own poll pass checked it.
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

        # Always safe to delete both paths unconditionally here (2026-09-09,
        # see this function's own header) - Invoke-ChapterDispatch only
        # ever calls JobAbortCleanup for a job it has confirmed never
        # reached JobFinalize, unlike the old code's own force-kill block,
        # which had to guard $j.MagickOutputPath's deletion with
        # SlotReleased to avoid tearing down a DIFFERENT, already-finished
        # job's real output (a stale-$running-list race - see
        # Convert-AnimatedBatch's own comment on that guard). That
        # ambiguity can't happen here; Invoke-ChapterDispatch's own
        # SlotReleased-equivalent bookkeeping is entirely internal to it.
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
            # Bounds memory across a long run - matches
            # Invoke-ChapterDispatch's own per-chapter cleanup philosophy.
            $chapterResults.Remove($chapterInfo)
        }.GetNewClosure()

        # Test-AbortSignal must be called from SOMEWHERE regularly for a
        # real abort to ever propagate into $animatedCts - it's the one
        # function that actually cancels every registered CTS (see
        # AbortPipeline.ps1's own docstring); nothing does that
        # automatically just because a CTS was registered. This
        # -AbortPollCallback (called every poll pass, same as the old
        # code's own $abortPoll) is now the ONLY place that happens in
        # this whole function, replacing both the old per-chapter-loop
        # top-of-loop checks (Invoke-ChapterDispatch's own pull-ahead
        # already stops calling -ChapterProvider once -CancelToken trips,
        # so a separate check there would be redundant) and prints the
        # old code's own one-time "[ABORT] Waiting..." message.
        $abortMessagePrinted = $false
        $abortPollCallback = {
            param($runningJobs)
            $aborted = Test-AbortSignal
            if ($aborted -and -not $abortMessagePrinted) {
                $abortMessagePrinted = $true
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
