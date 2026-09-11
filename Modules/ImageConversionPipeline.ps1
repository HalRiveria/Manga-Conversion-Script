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

    CLEAN CONSOLE OUTPUT REWORK: PART 2 walks the library
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
      - Test-AvifAnimated (AnimatedConversionPipeline.ps1) - for the
        static-AVIF conversion path in
        Convert-ImageBatch (see "STATIC AVIF -> JXL" below). Spawns a
        real magick identify process - not a cheap byte read like the
        WebP animation check - so this module now genuinely depends on
        AnimatedConversionPipeline.ps1 being dot-sourced first, a real
        new coupling between the two, not just a docstring note.
    Modules\_Harness\ImageConversionPipeline.Harness.ps1 dot-sources the
    real Logging.ps1/FileDeletion.ps1/AbortPipeline.ps1/
    LeafDirectoryDiscovery.ps1/CleanConsoleRendering.ps1/
    AnimatedConversionPipeline.ps1 (the last one for
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

    STATIC AVIF -> JXL: decided unconditionally, no toggle - convert
    static AVIF the same as everything else, for consistency with the
    rest of the library. Lives HERE, not AnimatedConversionPipeline.ps1,
    since it's a static-image concern - reuses the exact same "transcode
    to a temp PNG via magick, then hand that to cjxl" detour already
    built for WebP (the two now share one code path in the dispatch
    loop below, the WebP/AVIF-specific parts are only the pre-checks:
    Test-WebPAnimated's own VP8X-chunk byte read for WebP - cheap, no
    magick spawn - versus a real Test-AvifAnimated call for AVIF - a
    magick identify process spawn, reading the container's animation
    delay metadata on frame [0] only, not a cheap byte read). Animated
    AVIF is left untouched here, same as animated WebP - it has its own
    conversion pipeline (AnimatedConversionPipeline.ps1). A real
    Test-AvifAnimated failure (magick itself failed, or returned
    something that couldn't be parsed as a delay value) is its own
    outcome, NOT folded into
    FailedCount or SkippedCount - see the new InspectFailedCount field,
    matching Convert-AnimatedBatch's own field of the same name for the
    identical failure mode (this project's own "give it its own field,
    don't fold it into Fail" call, see Todo.md's Summary.ps1 decision).

    -ZIPSTEPCALLBACK: mode 8's ("Image Conversion +
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

function Get-LooseImageExtensions {
    <#
    .SYNOPSIS
        The canonical "loose image" extension list - single source of
        truth for what this project treats as a convertible/zip-blocking
        image file, so a future edit doesn't silently desync which files
        get converted vs. left as unconverted loose files (the risk if it
        were hardcoded independently in multiple places, matching the
        established Get-XSharedFunctionNames pattern this project already
        uses for exactly this kind of problem).
    .DESCRIPTION
        Used as a default parameter value elsewhere in this module and in
        Controller.ps1 (which already dot-sources this module, in both
        the real script and its own harness). Deliberately NOT used as
        AnimatedConversionPipeline.ps1's own -FolderQualifyingExtensions
        default - that module's harness dot-sources it standalone,
        without this one, by design (see this project's "own standalone
        test harness, verified in isolation" convention); a cross-module
        default-value dependency would break that. That module keeps its
        own literal, commented as matching this canonical list.

        ".gif"/".bmp"/".heic"/".heif" are on this list per the project
        owner's own decision - these formats would otherwise be silently
        invisible to chapter discovery entirely, and the owner's call was
        they should count as unconverted content instead, the same as any
        other format on this list. ".gif" is included here for that reason
        ONLY - it still counts as unconverted/zip-blocking content, but
        Convert-ImageBatch always SKIPS it rather than actually
        converting it (project owner's own real-world experience: GIF
        conversion caused real problems in older script versions - an
        animated GIF reaching
        the ICC-strip retry path leaves orphaned numbered temp PNGs behind
        that no cleanup regex in this project catches). ".bmp"/".heic"/".heif" DO actually convert, through
        cjxl's existing WebP/AVIF magick-detour (transcode to a temp PNG
        first) - confirmed live, cjxl.exe cannot read any of the three
        directly, but `magick -list format` confirms BMP is read/write
        and HEIC/HEIF are read-only, both sufficient for the detour's
        one-way source-to-PNG conversion.
    #>
    return @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif", ".gif", ".bmp", ".heic", ".heif")
}

function Test-OrphanedScratchFileName {
    <#
    .SYNOPSIS
        True if $Name matches one of this project's own scratch-file
        naming patterns: "_tmp_iccstrip.png"/"_tmp_iccstrip-N.png" (this
        module's own Invoke-IccStripRetryOrFail - the "-N" form is fully
        reachable, not legacy, since that function's own magick call
        deliberately doesn't select frame 0), "_tmp_<fmt>2png.png" (this
        module's own WebP/AVIF/BMP/HEIC/HEIF pre-conversion detour), and
        "_tmp_overwrite.webp" (AnimatedConversionPipeline.ps1's own
        -DoAnimatedOverwrite staging file).
    .DESCRIPTION
        Single source of truth for a
        3-line regex trio that would otherwise be hand-duplicated across this
        module's own Get-LooseImageCandidates, Controller.ps1's
        Invoke-FullPipelineChapter, and ZipPipeline.ps1's
        Invoke-LooseFolderZip, matching the exact problem Get-LooseImageExtensions
        (immediately above) already solved for this project's loose-image
        extension list.

        Every real leak path for these files already has its own cleanup
        (retry-enqueue, failed-strip, force-kill drain, still-pending
        sweep) - callers use this as the boundary-level backstop for when
        that cleanup itself couldn't run (a force-killed process, a locked
        file swallowed by a bare `catch {}`): without it, a leaked scratch
        file gets treated as a real loose image by the very next run,
        converted, and left behind permanently instead of recognized as
        debris.
    #>
    param([Parameter(Mandatory)][string]$Name)
    return (
        $Name -imatch '_tmp_iccstrip(-\d+)?\.png$' -or
        $Name -imatch '_tmp_(webp|avif|bmp|heic|heif)2png\.png$' -or
        $Name -imatch '_tmp_overwrite\.webp$'
    )
}

function Get-NeverConvertedExtensions {
    <#
    .SYNOPSIS
        Extensions on Get-LooseImageExtensions()'s own list that this
        project deliberately never actually converts - currently just
        ".gif", per the project owner's own decision from real-world
        experience with older script versions. Single source of truth
        for that fact, used by BOTH Convert-ImageBatch's own skip check
        AND Get-LooseImageCandidates's staleness classification - without
        a shared getter, those two could agree only by accident:
        Convert-ImageBatch skips GIF and
        leaves it untouched with a "File left untouched" promise, but if
        Get-LooseImageCandidates had no matching exclusion, a GIF
        older than an unrelated same-basename .jxl would get classified as a
        stale leftover and deleted on the very next run, breaking that
        promise one run later. Same species as this project's other
        divergent-list bugs (Get-LooseImageExtensions itself, the
        orphaned-scratch-file regex trio) - a fact that has to stay true
        in two places, now consolidated into one.
    #>
    return @(".gif")
}

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
        [string]$MagickExe,
        # $null default = unchanged behavior for Convert-ImageBatch's own
        # call site - Invoke-ChapterDispatch identifies a chapter by the
        # exact ChapterKey value tagged onto each of its own jobs (see
        # that module's own header), and has no other way to know a
        # requeued retry job belongs to the same chapter as the job that
        # requeued it. Only meaningful to a caller going through
        # Invoke-ChapterDispatch; Convert-ImageBatch itself never sets
        # ChapterKey on any of its own jobs, so this stays $null there.
        $ChapterKey = $null
    )

    $strippedPng = [System.IO.Path]::Combine(
        [System.IO.Path]::GetDirectoryName($Job.SrcPath),
        [System.IO.Path]::GetFileNameWithoutExtension($Job.SrcPath) + "_tmp_iccstrip.png"
    )
    Write-Log ("ICC profile mismatch on '" + $Job.SrcPath + "' - stripping profile and retrying.") -Level Warn
    # [System.Diagnostics.ProcessStartInfo]::new(), not New-Object -
    # a real bug found live-catching a Controller.Harness.ps1
    # hang with NO subprocess alive at all - see Controller.ps1's own
    # matching JobStarter comment for the full reasoning). This function is
    # called from Complete-ImageDispatchJob, Full Pipeline's own image-
    # engine JobFinalize, running inside that engine's fresh worker
    # runspace - the same first-cmdlet-call-in-a-fresh-runspace race
    # already fixed for Test-Path/Get-ChildItem/etc., never audited for
    # New-Object before now.
    $stripPsi = [System.Diagnostics.ProcessStartInfo]::new()
    $stripPsi.FileName               = $MagickExe
    # -strip ONLY - no -colorspace Gray, project owner's own
    # explicit decision: color data must never be force-converted, full
    # stop). The retry trigger is cjxl's generic "Getting pixel data
    # failed" stderr match - broader than the one specific case
    # (a PNG mislabeled RGB that's actually grayscale) this was written
    # for. -strip alone already fixes THAT case (the profile/pixel-format
    # mismatch is what -strip resolves); -colorspace Gray was a no-op for
    # it (the source was already grayscale) but would silently destroy
    # color data - then get its now-unrecoverable original deleted as a
    # successful conversion - for any OTHER cause of the same generic
    # stderr message on a genuinely color image cjxl can't read. Verbatim
    # -colorspace Gray usage was inherited from the original monolithic
    # reference script; removing it here is a deliberate, explicit
    # deviation from that reference, not an oversight.
    # Deliberately NO "[0]" frame selector here - considered and
    # rejected, since this retry can leak an orphaned numbered PNG
    # against a multi-frame/multi-image source -
    # see the calling function's own header and Get-LooseImageCandidates's
    # matching exclusion fix). Adding "[0]" WOULD stop magick from auto-
    # numbering its output - but it would also silently strip every frame
    # past the first from whatever this retry produces, for any genuinely
    # multi-frame/multi-image source that reaches this point (a multi-page
    # TIFF, a multi-image HEIC burst) - trading a noisy-but-safe failure
    # (Test-Path below correctly finds no file at the expected exact name,
    # so this function correctly returns $false, no data touched) for a
    # quiet, lossy "success" that silently truncates real content. That is
    # exactly the class of bug this project's own standing rule already
    # exists to prevent (see the -colorspace Gray removal above, same
    # function - "never silently strip data, full stop"). The
    # numbered-orphan-file problem is real but cosmetic (disk space, not
    # data loss) and is fixed instead at the cleanup side - see
    # Get-LooseImageCandidates's own widened orphan-sweep regex, which now
    # matches the numbered form this command can produce.
    $stripPsi.Arguments              = "`"" + $Job.SrcPath + "`" -strip `"" + $strippedPng + "`""
    $stripPsi.UseShellExecute        = $false
    $stripPsi.RedirectStandardOutput = $true
    $stripPsi.RedirectStandardError  = $true
    $stripPsi.CreateNoWindow         = $true
    # ReadToEndAsync + try/finally matter here, same species already
    # found and fixed in
    # AnimatedConversionPipeline.ps1's Test-AvifAnimated: both streams
    # redirected but never read is the classic Process redirect deadlock -
    # if magick writes enough combined stdout+stderr to fill the OS pipe
    # buffer, it blocks writing while nothing ever drains the pipes, so
    # WaitForExit() never returns. Draining both asynchronously before
    # WaitForExit() prevents either buffer from ever filling.
    # Start() itself guarded - both sibling Process::Start
    # calls in this file (the magick pre-conversion above, and the cjxl
    # dispatch in Convert-ImageBatch) already wrap Start in try/catch for a
    # stale/missing exe path; this one didn't, so the same failure here
    # (e.g. MagickExe cached from a since-uninstalled install) threw a raw
    # exception past this function's own tail-path logging instead of a
    # clear, consistent message.
    try {
        $stripProc = [System.Diagnostics.Process]::Start($stripPsi)
    } catch {
        Write-Log ("Could not start ICC-strip retry process for '" + $Job.SrcPath + "': " + $_) -Level Error
        return $false
    }
    # Raw OS handle wait for exit detection (round 6 fix).
    # DOCUMENTED DUPLICATE: Test-AvifAnimated in
    # AnimatedConversionPipeline.ps1 uses the identical pattern and has
    # the full reasoning - keep both in sync.
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
        # Clean up any partial/corrupt .jxl the ORIGINAL failed attempt
        # may have already written to this same path - the retry
        # below targets the identical $Job.JxlPath, and this function's
        # own early `return $true` skips the normal failure path's own
        # partial-.jxl cleanup entirely. Real cjxl.exe was confirmed to
        # overwrite an existing file at this path cleanly (no error, no
        # prompt) on this machine, so this wasn't causing live harm - but
        # nothing in this file's own contract guarantees that, and this
        # matches the same defensive cleanup every other failure path
        # here already does before writing again.
        if ([System.IO.File]::Exists($Job.JxlPath)) { try { [System.IO.File]::Delete($Job.JxlPath) } catch { } }
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
            ChapterKey = $ChapterKey
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
    if ([System.IO.File]::Exists($strippedPng)) { try { [System.IO.File]::Delete($strippedPng) } catch { } }
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

        DOCUMENTED DUPLICATE: the exit-code/ICC-retry-decision/delete-source
        portion of this function (everything after its own try/finally)
        is copied, not shared, into Complete-ImageDispatchJob - see that
        function's own header for why (Invoke-ChapterDispatch owns
        process disposal/-SharedBudget release generically now, this
        function's own callers still don't). Keep both in sync if either
        changes.
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
        [bool]$IsAbortDrain = $false
    )

    # try/finally matters here - this is the one place a RUNNING job's
    # process handle gets disposed - unlike every other resource-release
    # path in this file, it needs the guard. Without it, a throw from
    # ReadToEnd/ExitCode (unlikely on an already-exited process, but not
    # impossible) would skip Dispose() entirely and propagate straight
    # out of Convert-ImageBatch.
    try {
        # Await the tasks started right after Process::Start rather than
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
        # SlotReleased marker matters here: Convert-ImageBatch's own dispatch-
        # loop try/catch (see that function's header comment) does its own
        # bulk cleanup of every job still in $running if something throws -
        # but the poll loop that calls this function only reassigns
        # $running AFTER its whole foreach pass completes. If THIS call
        # throws (e.g. a Write-Log below failing on a locked log file)
        # partway through that pass, the outer catch sees the STALE
        # $running list, which still includes every job THIS finally
        # already finished processing earlier in the same pass - without
        # this marker, the outer catch would delete that job's real,
        # already-converted .jxl output as if it belonged to a genuinely
        # still-running, force-killed job (see the outer catch's own
        # SlotReleased-guarded deletion, below in Convert-ImageBatch).
        $Job.SlotReleased = $true
    }

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
                    # THIS job's own TempPng (the webp/avif pre-conversion
                    # PNG that fed the now-failed cjxl attempt, if any) is
                    # done being needed - the retry enqueued above is a
                    # SEPARATE job with its own (already-stripped) TempPng.
                    # Cleaned up here since this early `return` skips the
                    # normal TempPng cleanup below entirely - without this,
                    # every webp/avif source that ever hit an ICC-strip
                    # retry left its first attempt's own pre-conversion PNG
                    # orphaned on disk.
                    if ($Job.TempPng -and [System.IO.File]::Exists($Job.TempPng)) { try { [System.IO.File]::Delete($Job.TempPng) } catch { } }
                    return $true
                }
            }
            throw ("cjxl exited with code " + $code + ". Stderr: " + $stderr)
        }
        # [System.IO.File]::Exists / [System.IO.FileInfo]::new, not
        # Test-Path / Get-Item (same cmdlet-first-invocation-in-a-fresh-
        # runspace race as Test-AvifAnimated's Where-Object - this function
        # runs as Full Pipeline's image engine JobFinalize, inside a fresh
        # worker runspace racing the animated engine's own first cmdlet
        # call). Complete-AnimatedDispatchJob's own copy already uses raw
        # .NET (see its comment at its own matching line).
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
        # Clean up any partial/corrupt .jxl left behind by a cjxl process
        # that exited non-zero after already writing output (a crash or a
        # disk-full mid-write) - same cleanup the force-kill drain path
        # below already does. Safe unconditionally: a job only reaches this
        # function if it needed converting, which means nothing valid could
        # have existed at JxlPath before this attempt (Get-LooseImageCandidates
        # only dispatches a source with no .jxl or a 0-byte placeholder one).
        # Without this, a corrupt non-zero-byte .jxl left behind gets picked
        # up as a StaleSources match on the NEXT run and the real source
        # gets permanently deleted, leaving only the garbage output.
        if ([System.IO.File]::Exists($Job.JxlPath)) {
            try { [System.IO.File]::Delete($Job.JxlPath) } catch { }
        }
    }

    # Clean up the temporary PNG used for WebP/ICC-strip pre-conversion
    if ($Job.TempPng -and [System.IO.File]::Exists($Job.TempPng)) {
        try { [System.IO.File]::Delete($Job.TempPng) } catch { }
    }

    if ($convOk) {
        try {
            # Return value checked, not discarded - same
            # species as this project's other Remove-Source call sites,
            # see FileDeletion.ps1's own .OUTPUTS. Remove-Source returns
            # $false (not an exception) when the source already vanished
            # before deletion (a real TOCTOU gap). Neither a success nor a
            # real failure - left uncounted rather than falsely reporting
            # a delete that didn't happen.
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
    <#
    .SYNOPSIS
        JobFinalize-shaped completion handler for a job dispatched via
        Invoke-ChapterDispatch (mode 2's own migration onto
        ChapterDispatch.ps1 - see
        Docs\dispatch-redesign-design.md). Handles exit-code/output
        verification (including the ICC-profile-mismatch retry via
        Invoke-IccStripRetryOrFail) and (on success) source deletion,
        mutating $ChapterResult (this chapter's own per-chapter
        accumulator, built by Invoke-LooseImageConversionPipeline's own
        JobBuilder) in place.

        DOCUMENTED DUPLICATE, not a call-through, of
        Complete-ImageConversionJob's own exit-code/ICC-retry-decision/
        delete-source logic (everything after that function's own
        try/finally) - see that function's own header for the cross-
        reference. Genuinely different contract, not a lazy copy:
        Complete-ImageConversionJob's caller (Convert-ImageBatch, no
        remaining real caller of its own other than its own harness)
        owns process disposal
        itself; THIS
        function's caller (Invoke-ChapterDispatch) already owns process
        disposal AND its own -MaxConcurrent SemaphoreSlim release
        generically for every job on every exit path - duplicating either
        here would double-release the same slot. No -IsAbortDrain
        distinction either - Invoke-ChapterDispatch calls JobFinalize
        identically whether a job finished during normal polling or during
        the abort/drain window, so there's no separate wording variant to
        capture.
    .OUTPUTS
        @{ Success = [bool] } for a normal completion, or
        @{ Requeued = $true } when Invoke-IccStripRetryOrFail enqueued a
        retry job instead - Invoke-ChapterDispatch doesn't count a result
        for THIS job in that case, matching Complete-ImageConversionJob's
        own $true-return contract.
    #>
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
            # -not $Job.IccRetried: see Complete-ImageConversionJob's own
            # identical guard for why - a job that's ALREADY the ICC-strip
            # retry hitting the same failure signature again must fall
            # through to the normal failure path, not retry forever.
            if ($code -eq 1 -and $stderr -imatch 'Getting pixel data failed' -and $MagickExe -and -not $Job.IccRetried) {
                # Bridge through a real, plain System.Collections.Queue,
                # NOT $PendingQueue directly - Invoke-IccStripRetryOrFail's own
                # -Pending param is typed [System.Collections.Queue], and
                # Queue[hashtable] does NOT derive from that non-generic
                # type. PowerShell's own parameter binding silently
                # CONVERTS a Queue[hashtable] argument into a brand-new,
                # disconnected System.Collections.Queue instead of
                # refusing the mismatch or passing the reference through -
                # enqueuing into the converted copy would leave
                # the caller's own original queue completely untouched, no
                # error anywhere. Passed directly, the real retry job
                # would silently vanish into that throwaway copy - the
                # chapter's Outstanding count would never reach 0 (this
                # job's own "Requeued" signal already stopped it from
                # decrementing, expecting the retry to eventually finish
                # instead), so neither this chapter nor the whole run
                # would ever complete. Enqueuing into a real, dedicated
                # System.Collections.Queue first, then re-enqueuing
                # whatever landed there onto the REAL $PendingQueue
                # afterward, sidesteps the coercion entirely - each
                # dequeued item is already a real Hashtable reference
                # (Invoke-IccStripRetryOrFail builds it as a literal
                # @{...}), so Queue[hashtable].Enqueue() accepts it
                # directly, no further conversion risk.
                $iccRetryLanding = [System.Collections.Queue]::new()
                if (Invoke-IccStripRetryOrFail -Job $Job -Pending $iccRetryLanding -MagickExe $MagickExe -ChapterKey $Job.ChapterKey) {
                    foreach ($retryJob in $iccRetryLanding) { $PendingQueue.Enqueue($retryJob) }
                    # [System.IO.File]::Exists, not Test-Path - this whole function is
                    # JobFinalize for Full Pipeline's image engine, called
                    # from inside a fresh worker runspace on the hot path for
                    # every converted file - an unswept instance of the same
                    # cmdlet-first-invocation-in-a-fresh-runspace race
                    # LeafDirectoryDiscovery.ps1's functions were fixed for
                    # (see those functions' own NOTES).
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
    <#
    .SYNOPSIS
        True if $WebPPath's VP8X chunk has the animation flag set (bit
        0x02) - a direct byte read, no ImageMagick spawn needed (unlike
        Test-AvifAnimated - WebP's animation flag lives directly in the
        container header at a fixed offset, no format-specific decoder
        required to answer this). A file with no VP8X chunk at all (a
        plain/simple WebP, no extended features) is never animated.
        Throws on a real I/O failure - same "let the caller decide"
        contract as Test-AvifAnimated, for consistency between this
        project's two animated-format classification checks.
        This is byte-for-byte the same logic Convert-ImageBatch's own
        pre-pass used inline before, just extracted into a named,
        independently-testable function so both formats' "is this file
        animated" answer comes from the same kind of place - NOT a
        behavior change, and NOT the start of an animated-WebP
        conversion pipeline, which this project has no plans to ever
        build.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$WebPPath
    )

    # [byte[]]::new, not New-Object (cmdlet-first-invocation race in a
    # fresh runspace - called from Controller.ps1's image-engine
    # $jobBuilder, inside a worker runspace racing the animated engine).
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
        # = 90, matching Convert-AnimatedBatch's
        # own -AnimatedQuality default: unlike DoJpegLossless ($false) or
        # every other bool/int this batch engine takes, 0 is NOT a safe
        # fallback for a cjxl quality value - it means maximum-loss
        # encoding, silently. Both real call sites (Controller.ps1's
        # worker, Invoke-LooseImageConversionPipeline) already pass this
        # explicitly, but Controller.ps1's
        # own worker-param hashtable is deliberately built so an omitted
        # key falls back to the worker's own default (see that file's
        # header comment on $baseJobParams), so this default matters if
        # DoJpegQuality is ever the omitted key.
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

    # Build job list, skipping output-path collisions (e.g. "photo.jpg" and
    # "photo.webp" both mapping to "photo.jxl" - converting both would let one
    # silently overwrite the other's output while both sources get deleted).
    #
    # Animated WebP/AVIF are classified HERE, before the collision count
    # below, not later inside the dispatch loop, since the collision
    # pre-pass only knows extensions, not animation
    # status - an animated file sitting next to a same-basename convertible
    # source (e.g. animated "foo.avif" + "foo.jpg") would otherwise be counted as a
    # real collision and BOTH sources would fail with "Resolve the name clash
    # manually", even though the animated file was never actually a
    # candidate for "foo.jxl" in the first place. Classifying animation
    # status first and excluding animated files from $allJobs entirely means
    # the collision count only ever sees genuine candidates. Only run this
    # when $MagickExe is present, matching the dispatch loop's own prior
    # behavior of erroring "ImageMagick not found" before ever reaching an
    # animated check when magick isn't available - untouched below.
    $allJobs = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($img in $ImageFiles) {
        $srcPath = $img.FullName
        # Cancellation check matters here: without it, cancelling mid-run
        # would leave this pre-pass running unabated - every remaining .avif in
        # the batch would still get a real `magick identify` spawn before the
        # (now-pointless) dispatch loop below declined to run. Matches the same
        # already-pending reporting the drain path below uses.
        if ($CancelToken.IsCancellationRequested) {
            $batchResult.PendingPaths.Add($srcPath)
            continue
        }
        if ((Get-NeverConvertedExtensions) -icontains [System.IO.Path]::GetExtension($srcPath)) {
            # Reads Get-NeverConvertedExtensions rather than a literal
            # '\.gif$' match - a literal here would be the only place this
            # fact was recorded, and Get-LooseImageCandidates's own
            # staleness classification (below) would have no matching
            # exclusion, so a GIF older than an unrelated same-basename
            # .jxl would get deleted as a "stale leftover" on the very
            # next run, breaking this exact skip message's own "File left
            # untouched" promise one run later. See
            # Get-NeverConvertedExtensions's own header for the full
            # story. GIF is always skipped, never actually
            # converted (project owner's own decision from real-world
            # experience with older script versions - GIF conversion
            # caused real problems before). Still counts as unconverted
            # content for chapter-discovery/zip-blocking purposes
            # (Get-LooseImageExtensions includes ".gif"), same treatment
            # as animated WebP/AVIF - just unconditional here rather than
            # gated on an animation check, since the trouble wasn't
            # specific to animated GIFs. A real animated
            # GIF reaching cjxl via the ICC-strip retry path
            # (Invoke-IccStripRetryOrFail, below) leaves orphaned numbered
            # temp PNGs behind (magick auto-numbers its output when a
            # multi-frame source has no frame selector and the
            # destination is a single filename) that don't match the
            # orphaned-scratch-file cleanup regex anywhere in this
            # project - skipping GIF outright avoids that whole class of
            # problem rather than trying to patch around it.
            Write-Log ("SKIPPING '" + $srcPath + "': not converted by this project (see Get-NeverConvertedExtensions's own comment for why). File left untouched.") -Level Warn
            $batchResult.SkippedCount++
            $batchResult.SkippedPaths.Add($srcPath)
            continue
        }
        if ($MagickExe -and $srcPath -imatch '\.webp$') {
            # Test-WebPAnimated (see its own header) -
            # same cheap VP8X-chunk read as before, now a named function so
            # both animated-format checks (WebP here, AVIF just below) share
            # the same "ask a dedicated classifier, throw on failure" shape.
            # try/catch matters here: without it, a locked/deleted/
            # inaccessible .webp would throw straight out of Convert-ImageBatch
            # and end the whole run, instead of failing just that one
            # file the way every other per-file I/O error in this function
            # does.
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
        $allJobs.Add(@{
            SrcPath = $srcPath
            JxlPath = [System.IO.Path]::ChangeExtension($srcPath, ".jxl")
            Proc    = $null
            TempPng = $null
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

    # try/catch around the whole dispatch loop (2026-08-31 fix, caught by a
    # same-day /code-review 4th pass): every OTHER exit from this loop
    # (normal completion, or cancellation via the straggler-drain/force-kill
    # block below) already disposes every running job's process handle. An
    # unexpected throw from inside the loop itself (-AbortPollCallback,
    # Write-Log on a locked log file, a rethrow from
    # Complete-ImageConversionJob) had no such guarantee - it propagated
    # straight out of Convert-ImageBatch with $running jobs' handles
    # undisposed.
    try {
    while (($pending.Count -gt 0 -or $running.Count -gt 0) -and (-not $CancelToken.IsCancellationRequested)) {

        if ($AbortPollCallback) {
            $inFlight = [System.Collections.Generic.List[string]]::new()
            foreach ($r in $running) { $inFlight.Add($r.SrcPath) }
            & $AbortPollCallback $inFlight
        }

        # Fill up to MaxCjxlProcs slots.
        while ($pending.Count -gt 0 -and (-not $CancelToken.IsCancellationRequested) -and `
               $running.Count -lt $MaxCjxlProcs) {
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
            # Reset per-iteration, same reasoning as $magickProcLocal above
            # (2026-08-31 fix): $j.TempPng is only assigned AFTER the
            # magick Process.Start/WaitForExit calls below succeed, so if
            # either throws, the catch block's own cleanup (which checks
            # $j.TempPng) can't see a temp file magick may have already
            # written - this local variable, reset every iteration so a
            # PREVIOUS job's leftover value can't be mistaken for this
            # job's own temp file, gives the catch block a fallback that's
            # set as soon as the path is computed, before Start() ever runs.
            $tempPngLocal = $null
            try {
            # [System.Diagnostics.ProcessStartInfo]::new(), not New-Object -
            # same fix, same reasoning, as Controller.ps1's own matching
            # JobStarter comment (this module's mode-2 counterpart of the
            # same closure shape, also worker-runspace code).
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName               = $CjxlExe
            $psi.UseShellExecute        = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow         = $true

            # cjxl 0.11.x cannot read WebP, AVIF, BMP, HEIC, or HEIF
            # directly - transcode to a temp PNG first. Animated WebP/AVIF
            # are skipped entirely (cjxl has no multi-frame support) -
            # animated AVIF has its own conversion pipeline,
            # AnimatedConversionPipeline.ps1. BMP/HEIC/HEIF (2026-09-02
            # addition) need no animation pre-check - neither format
            # carries the kind of animation this project routes specially
            # (a real HEIC/HEIF "image sequence," e.g. a burst photo, just
            # transcodes its first image via magick's own "[0]" selector
            # below, same as it already does for WebP/AVIF). All five
            # formats share this one transcode step; only the animation
            # pre-check differs where one applies (a cheap WebP byte read
            # vs. a real magick identify process spawn for AVIF - see this
            # module's header, "STATIC AVIF -> JXL").
            $isWebp = ($j.SrcPath -imatch '\.webp$')
            $isAvif = ($j.SrcPath -imatch '\.avif$')
            $isBmp  = ($j.SrcPath -imatch '\.bmp$')
            $isHeic = ($j.SrcPath -imatch '\.heic$')
            $isHeif = ($j.SrcPath -imatch '\.heif$')
            if ($j.TempPng) {
                # Retry job (ICC-strip): TempPng already points to a
                # complete, ready-to-use PNG that Invoke-IccStripRetryOrFail
                # produced directly from the ORIGINAL source in one step
                # (magick reads webp/avif/anything natively for that single
                # strip+grayscale command - see that function). Checked
                # BEFORE the isWebp/isAvif branch below (2026-08-31 fix,
                # caught by a same-day /code-review) - $j.SrcPath still
                # carries the original extension even for a webp/avif
                # retry, so checking isWebp/isAvif first redid an entirely
                # separate, non-ICC-stripped pre-conversion every time,
                # silently overwriting this TempPng value, orphaning the
                # real stripped PNG on disk (a stray file a later run's
                # Get-LooseImageCandidates would pick up as a real loose
                # image), and failing the retry the same way every time
                # since the fresh pre-conversion was never actually
                # ICC-stripped.
                $cjxlSrc = $j.TempPng
            } elseif ($isWebp -or $isAvif -or $isBmp -or $isHeic -or $isHeif) {
                # Animation classification for WebP/AVIF now happens in the
                # pre-pass that builds $allJobs, before the collision count -
                # see that pre-pass's own comment (2026-08-31 fix). A job
                # reaching here is therefore already known non-animated
                # (unless $MagickExe was missing at pre-pass time too, in
                # which case it falls through to the same error below,
                # matching prior behavior). BMP/HEIC/HEIF never went
                # through that pre-pass at all (2026-09-02 addition) -
                # neither format needs an animation check, see this
                # branch's own header comment above.
                $formatLabel = if ($isAvif) { "AVIF" } elseif ($isWebp) { "WebP" } elseif ($isBmp) { "BMP" } elseif ($isHeic) { "HEIC" } else { "HEIF" }
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
                # [System.Diagnostics.ProcessStartInfo]::new(), not
                # New-Object - same fix as this closure's own $psi above.
                $magickPsi = [System.Diagnostics.ProcessStartInfo]::new()
                $magickPsi.FileName               = $MagickExe
                $magickPsi.Arguments              = "`"" + $j.SrcPath + "[0]`" `"" + $tempPng + "`""
                $magickPsi.UseShellExecute        = $false
                $magickPsi.RedirectStandardOutput = $true
                $magickPsi.RedirectStandardError  = $true
                $magickPsi.CreateNoWindow         = $true
                # ReadToEndAsync (2026-08-31 fix, from a THIRD same-day
                # /code-review pass) - same redirect-deadlock species as
                # Invoke-IccStripRetryOrFail's own fix above and
                # AnimatedConversionPipeline.ps1's Test-AvifAnimated: both
                # streams were redirected but never read, and this call
                # runs synchronously INLINE in the main dispatch loop (not
                # polled via HasExited like the cjxl job below) - a hang
                # here blocks the entire batch, not just one job.
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

            # JPEG encoding: controlled by the -DoJpegLossless / -DoJpegQuality params.
            # Non-JPEGs (PNG/WebP/TIFF): always lossy at quality 90.
            # --num_threads=1 on every invocation (2026-09-03 fix, real bug,
            # live-reported): cjxl's own default ("-1" = use machine
            # default) was never overridden, so every concurrently-
            # dispatched cjxl process independently grabbed its own
            # machine-default thread pool - MaxCjxlProcs controlled how
            # many PROCESSES ran, not how many real worker THREADS existed,
            # so e.g. MaxCjxlProcs=4 could saturate far more than 4 threads
            # system-wide. Pinning this makes MaxCjxlProcs mean what it
            # says: one real worker thread per configured process slot.
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
            # Start draining both redirected streams immediately, not when
            # the job is later found HasExited - same redirect-deadlock
            # species as the magick pre-conversion fix above and
            # Invoke-IccStripRetryOrFail's own fix (2026-09-04): this cjxl
            # job is polled via HasExited rather than read synchronously
            # inline, so a cjxl that writes more than the OS pipe buffer to
            # stdout/stderr before exiting would otherwise block on that
            # write forever - HasExited never becomes true, and this job
            # sits in $running for the rest of the run with no timeout.
            # Complete-ImageConversionJob awaits these tasks instead of
            # calling ReadToEnd() itself.
            $j.StdoutTask = $j.Proc.StandardOutput.ReadToEndAsync()
            $j.StderrTask = $j.Proc.StandardError.ReadToEndAsync()
            $running.Add($j)
            } catch {
                Write-Log ("FAILED to start conversion process for '" + $j.SrcPath + "': " + $_) -Level Error
                $batchResult.FailedCount++
                # Swallowed deliberately (2026-08-31, from a same-day
                # /code-review): a TOCTOU race between the HasExited check
                # and Kill() (or an access-denied Kill()) would otherwise
                # propagate out of an already-failing job's own cleanup -
                # best-effort only, matching this file's established
                # best-effort file-cleanup idiom used throughout.
                if ($magickProcLocal) { try { if (-not $magickProcLocal.HasExited) { $magickProcLocal.Kill() }; $magickProcLocal.Dispose() } catch { } }
                # $j.TempPng is only set after Start/WaitForExit succeed
                # (see the reset comment above) - $tempPngLocal is the
                # fallback for a throw landing before that assignment ever
                # happens, so a temp PNG magick already wrote isn't
                # orphaned just because the crash landed one line early.
                if ($j.TempPng -and ([System.IO.File]::Exists($j.TempPng))) { try { [System.IO.File]::Delete($j.TempPng) } catch { } }
                elseif ($tempPngLocal -and ([System.IO.File]::Exists($tempPngLocal))) { try { [System.IO.File]::Delete($tempPngLocal) } catch { } }
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
                if (Complete-ImageConversionJob -Job $j -BatchResult $batchResult -Pending $pending -MagickExe $MagickExe -DoFullLogging $DoFullLogging -ItemNoun $ItemNoun -SourceNoun $SourceNoun) {
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
        # point.
        [System.Threading.Thread]::Sleep(50)
    }
    } catch {
        # Force-cleanup mirrors the force-kill block below (own try/catch
        # per step, same as every other cleanup path in this file, INCLUDING
        # the partial/corrupt .jxl deletion - 2026-08-31 fix, caught by
        # verifying this same day's /code-review 4th pass, this block
        # originally dropped that one step despite the comment claiming
        # parity: a killed cjxl can leave a non-zero-byte truncated .jxl
        # NEWER than its source, which the NEXT run's Get-LooseImageCandidates
        # then classifies as a stale leftover and deletes the real source,
        # keeping only the garbage output) - best effort, since we're
        # already unwinding from an unexpected failure and must not let a
        # cleanup error mask or replace the real one.
        # $j.SlotReleased guards the .jxl deletion below (2026-08-31 fix,
        # corrected after a third verification pass found a real DATA-LOSS
        # bug in the second pass's own fix: this $running list is STALE -
        # the poll loop only reassigns it after its whole foreach pass
        # completes - so it can still list a job that ALREADY completed
        # successfully earlier in the SAME pass, source deleted and all.
        # SlotReleased is set in Complete-ImageConversionJob's own finally
        # block, true for exactly those already-finished jobs (success OR
        # failure, doesn't matter which - either way their OWN cleanup
        # already ran and this block must leave their .jxl alone) and
        # false for the genuinely-still-running jobs this force-kill path
        # exists for. Verified live: without this guard, a job that
        # converted successfully and had its source already deleted lost
        # its .jxl too the moment a LATER job in the same poll pass threw -
        # the image was gone entirely, not just its source. TempPng
        # cleanup is intentionally NOT guarded by this flag -
        # Complete-ImageConversionJob's own TempPng cleanup runs AFTER its
        # SlotReleased-setting finally, so a job marked SlotReleased via an
        # early throw (the unguarded "cjxl stdout for" Write-Log call) can
        # still have a real, undeleted TempPng.
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

        # try/catch around the whole straggler-drain body (2026-08-31
        # addition - project owner approved as an easy fix, same shape as
        # the main dispatch loop's own outer catch above): that catch only
        # covers the MAIN loop - an unexpected throw here (the same
        # unguarded Write-Log calls inside Complete-ImageConversionJob are
        # the realistic trigger) had no equivalent guard, leaking every
        # remaining drain-list job's process handle. Mirrors that catch's
        # own cleanup exactly, including the
        # SlotReleased-guarded .jxl deletion (the identical stale-list/
        # data-loss shape applies here too - the drain's own polling loop
        # only reassigns $running after its whole foreach pass completes).
        try {
            # -not [ConsoleCtrl]::IsCloseEvent (2026-09-03 fix, real bug,
            # live-reported and live-tested): Windows force-kills the whole
            # process ~5s after a CTRL_CLOSE_EVENT (the X button) regardless
            # of what this drain does - confirmed via this machine's
            # WaitToKillAppTimeout registry value AND a live test (force-
            # killing the parent mid-run left cjxl/magick child processes
            # running as orphans, in both this script and the old reference
            # script). Waiting out any part of -AbortTimeoutSeconds (default
            # 60s) can never fit in that ~5s window, so a close event skips
            # straight to the force-kill block below instead of wasting any
            # of it. [ConsoleCtrl] is a compiled type (Add-Type,
            # AbortPipeline.ps1) - its static fields are visible from this
            # runspace worker without needing -SharedFunctionNames
            # propagation, unlike a PowerShell function/variable.
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

            # One final completion-check pass before declaring anything
            # force-stopped (2026-09-03 fix, real bug found by code review
            # after the IsCloseEvent fast-path above was added). Same closing
            # move Invoke-GracefulDrain's own drain loop already uses for the
            # identical race at the normal -AbortTimeoutSeconds boundary -
            # needed MORE here now, not less: IsCloseEvent can exit the while
            # loop above on its very first condition check, before even one
            # poll of $running has happened, so a job whose process had
            # ALREADY exited successfully (a real, valid, fully-written .jxl)
            # could still be sitting in $running with nothing having checked
            # HasExited for it yet. Without this pass, the force-kill block
            # below would delete that legitimate output as if it were
            # partial/corrupt from a killed process - destroying finished
            # work instead of just cleaning up a genuinely-still-running job.
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

            # Force-kill anything still running past the timeout
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
                    # Clean up any partial/corrupt .jxl left behind by the killed process
                    if ([System.IO.File]::Exists($j.JxlPath)) {
                        try { [System.IO.File]::Delete($j.JxlPath) } catch { }
                    }
                    $j.Proc.Dispose()
                    # $j.SlotReleased = $true (2026-08-31 fix, caught by
                    # verifying a same-day /code-review pass): without
                    # this, a throw partway through THIS SAME loop (e.g.
                    # Process.Dispose() itself throwing) would drop
                    # straight into the outer catch below, which
                    # re-iterates this same $running list - any job THIS
                    # loop already finished processing, with no marker to
                    # say so, could have its real output deleted a second
                    # time as if it were still-running debris.
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

    # Anything left un-dispatched (only possible if cancelled before it could
    # be started) - callers that surface a "still pending" count need this,
    # since $pending itself is local to this function. A job here can only
    # have a non-null TempPng if it's an ICC-strip retry enqueued by
    # Invoke-IccStripRetryOrFail during the abort-drain above (2026-08-31
    # fix) - that retry never gets dispatched once cancelled (the drain
    # only waits for ALREADY-running processes, it doesn't start new ones),
    # so without this cleanup the real, already-stripped PNG it produced
    # was orphaned on disk with nothing to ever delete it - a stray file a
    # later run's Get-LooseImageCandidates would pick up as a real loose
    # image. The source itself is correctly left alone here (still
    # reported as pending, retried fresh on the next run).
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
    <#
    .SYNOPSIS
        Scans $ScanPath for loose image files (outside any known ZIP's
        staging/extraction directory), classifying each as needing
        conversion or stale (a valid non-zero-byte .jxl counterpart
        already exists, and isn't OLDER than this source - see 2026-08-31
        fix note below - safe to delete without converting). A third,
        unreturned case (2026-08-31): a source NEWER than its same-basename
        .jxl is a real naming collision this function can't safely resolve
        either way - excluded from both NeedsConversion and StaleSources,
        logged as an Error, left untouched on disk.
    .DESCRIPTION
        Staleness is matched by basename alone (same directory, same name
        minus extension) - there's no persisted link between a .jxl and
        which source produced it. A genuine leftover from a real conversion
        can't be newer than the output it produced, so a source NEWER than
        its same-basename .jxl is a real, different file that happens to
        share a name with an old, unrelated conversion (e.g. photo.jpg
        converted and deleted, then a later, different photo.png added) -
        not the source that produced that .jxl. Such a file is deliberately
        left OUT of both returned lists rather than being routed to either
        one: NeedsConversion would let cjxl's own output silently OVERWRITE
        the pre-existing .jxl in place (a plain file write, not a delete -
        not even Recycle-Bin-recoverable), and StaleSources would delete a
        genuinely unconverted source. Neither destructive action is safe
        when this function can't tell which of the two files is the "real"
        one - logged as an Error instead, left for the user to resolve by
        renaming. Not a perfect signal (a source touched/copied without
        content changing would still look "newer"), but a real improvement
        over matching by basename alone with no signal at all.
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
        @{ NeedsConversion = List[FileInfo]; StaleSources = List[FileInfo];
           NamingCollisions = List[FileInfo] } - NamingCollisions (added
        2026-08-31, from a same-day /code-review) makes the naming-
        collision exclusion described above VISIBLE to callers: before
        this field existed, a chapter whose only loose image was such a
        collision had zero entries in either returned list, so
        Convert-ImageBatch was never even dispatched for it and the
        chapter's own ChapterResult stayed $null - Get-ChapterProgressStatus
        maps a $null result to a clean Success with no way to know a real,
        unconverted file was sitting there. Both real callers (this
        module's own Invoke-LooseImageConversionPipeline, and
        Controller.ps1's Invoke-FullPipeline) count it and block that
        chapter from zipping the same way an AVIF classification failure
        already does (see Controller.ps1's own $failedClassificationDirs
        mechanism) - a NEW caller should do the same. Known remaining gap
        in both existing callers (not fixed by this field, tracked in
        Todo.md): the chapter's own reported Status/Detail still comes
        back a clean Success in this case (nothing left to convert once
        the collision is excluded), so IsZippable correctly blocks the
        zip but the live per-chapter display doesn't reflect the problem.
    #>
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

    # Get-FilesRecursiveSafe (LeafDirectoryDiscovery.ps1), not
    # Get-ChildItem -Recurse, as of 2026-09-10 - real, live-reproduced
    # hang (not just slowness) when two runspaces both make their
    # first-ever PowerShell FileSystem-provider call at close to the same
    # moment - see that function's own header for the full story. A real
    # `foreach` statement here, not `| Where-Object` - Get-FilesRecursiveSafe
    # returns its List with the leading-comma collapse guard (see
    # Docs/lessons-learned.md), which means a caller piping its output
    # receives the WHOLE List as one pipeline object, not one item per
    # element (that per-item unrolling only happens for a cmdlet emitting
    # items individually, e.g. Get-ChildItem, not a function returning a
    # single comma-protected collection) - confirmed live, Where-Object's
    # own $_ was the List itself, not a FileInfo, throwing deep inside the
    # filter body. `foreach` over the returned List enumerates its real
    # elements correctly either way.
    $allCandidates = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($file in (Get-FilesRecursiveSafe -ScanPath $ScanPath)) {
        if ($LooseImageExtensions -inotcontains $file.Extension) { continue }
        # Orphaned scratch files - Test-OrphanedScratchFileName (this
        # module, single source of truth, 2026-09-03 cleanup - see its
        # own header for the full reasoning, also used by
        # Controller.ps1/ZipPipeline.ps1's matching sweeps).
        if (Test-OrphanedScratchFileName -Name $file.Name) { continue }
        # Never-converted extensions (2026-09-02 fix, from a same-day
        # review, live-confirmed) - excluded here for the same reason
        # orphaned scratch files are excluded above: without this, a
        # GIF (Convert-ImageBatch's own pre-pass always skips it,
        # leaving it untouched with a "File left untouched" promise -
        # see Get-NeverConvertedExtensions's own header) that happens
        # to be OLDER than an unrelated same-basename .jxl gets
        # classified as a stale leftover below and DELETED on the
        # very next run, breaking that promise. Excluding it here
        # means it's never even a NeedsConversion/StaleSources/
        # NamingCollisions candidate - it just sits there, still
        # visible to a folder-qualifying-extension check (so a
        # chapter holding one is still discovered/walked, not
        # invisible), permanently untouched by this function
        # specifically. It does NOT keep blocking zip forever
        # (2026-09-02 correction, caught by a second same-day
        # review) - Controller.ps1's own mode-8 zip-blocking list
        # also subtracts Get-NeverConvertedExtensions now, for
        # exactly this reason: a never-converted file can never
        # produce the "conversion failure resolved" state a
        # blocking check like that expects, so leaving it as a
        # permanent blocker there meant mode 8 could never zip that
        # chapter, ever, on any run - live-confirmed. Full Pipeline
        # has no such gate at all and simply sweeps it into the zip;
        # mode 8 now matches that already-validated behavior.
        if ((Get-NeverConvertedExtensions) -icontains $file.Extension) {
            # Logged here, not just left silent like the scratch-file
            # exclusion above (2026-09-02 fix) - a never-converted file
            # is real user content, not internal debris, and this
            # exclusion means Convert-ImageBatch's own matching
            # "SKIPPING..." message (its pre-pass) can no longer fire
            # for it through either real caller (both route through
            # this function first) - without a message here, a
            # chapter holding only a never-converted file would show
            # nothing more specific than "no unconverted images",
            # indistinguishable from a chapter that's genuinely fully
            # done.
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
                # -ge, not -gt (2026-08-31 fix, found by a same-day
                # /code-review): a source whose LastWriteTimeUtc is
                # EXACTLY EQUAL to its .jxl's fell through to the stale
                # branch below and got permanently deleted without ever
                # being converted - a real risk in this project's domain,
                # since ZIP extraction commonly produces coarse (or
                # identical) timestamps, letting an unrelated same-basename
                # file from a different archive collide exactly with an
                # old unrelated .jxl's mtime. Treating equal the same as
                # newer (an unresolvable collision, excluded from both
                # lists) trades a rare false-positive "please rename one of
                # these" prompt for eliminating a silent, unconverted-
                # source data-loss path - the same conservative direction
                # this fix's own history above already established.
                # A same-basename .jxl existing is not, by itself, proof
                # THIS source produced it - basename matching alone can't
                # tell "photo.jpg, already converted and deleted, and this
                # is a stray leftover copy" apart from "photo.jpg was
                # converted, deleted, and an UNRELATED photo.png was later
                # added with the same name" (a real extension collision).
                # A source newer than the existing .jxl is a strong signal
                # it's the latter case - the .jxl a real conversion of THIS
                # file would produce can't predate the file itself.
                #
                # 2026-08-31 correction: an EARLIER version of this fix
                # routed this case to $needsConversion instead, reasoning
                # that Convert-ImageBatch's own output-path-collision guard
                # (two sources in the same batch mapping to the same .jxl)
                # would cover it. It doesn't - that guard only compares
                # sources against EACH OTHER within one batch; it never
                # checks an existing .jxl already on disk. Routing here to
                # NeedsConversion meant cjxl's own output silently
                # OVERWROTE the pre-existing .jxl in place - a plain file
                # write, not a delete, so not even Recycle-Bin-recoverable.
                # That trade one data-loss direction (an unconverted
                # source wrongly deleted, at least Recycle-Bin-recoverable)
                # for a worse one (a converted output silently, permanently
                # destroyed - live-caught by /code-review). This is a
                # genuine, unresolvable naming collision this function
                # cannot safely act on either way - excluded from BOTH
                # lists (no delete, no conversion, no overwrite) and logged
                # as a real problem needing the user to rename one of the
                # two files by hand.
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
            # Return value checked, not discarded (2026-09-08 fix, same
            # species as this project's other Remove-Source call sites) -
            # see Complete-ImageConversionJob's matching fix above for the
            # full reasoning.
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

    # InspectFailedCount is Error-tier: it means Test-AvifAnimated couldn't
    # even determine whether an AVIF needs converting, so it was left as a
    # raw, completely unconverted file on disk - previously not checked
    # here AT ALL, so it was silently treated as a clean Success, letting
    # the zip gate proceed with an unconverted file in the chapter. Same
    # underlying issue as AnimatedConversionPipeline.ps1's own
    # Get-ChapterAnimatedStatus, fixed there the same day (2026-08-31).
    # This condition + parts-building block is a deliberate duplicate of
    # that function's own copy (same four fields, same Error-tier severity
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
    <#
    .SYNOPSIS
        Given a chapter's own conversion Status/Detail (from
        Get-ChapterProgressStatus) and a reason its zip was blocked for a
        NON-engine-failure cause, returns the Status/Detail that should
        actually reach Complete-ChapterProgress - downgrades a clean
        Success/Warning to Warning with the reason appended; leaves an
        existing Error alone (already correctly severe, and already the
        reason zipping was skipped, not this).

        SOLE DEFINITION, reused by Controller.ps1 (2026-09-09, revised
        same day by a code-review fix - see Docs/zip-blocked-status-
        design.md's "Decided" section for the original "documented
        duplicate" reasoning, and CHANGELOG.md for why that shape got
        replaced with this one): originally an identical copy also lived
        in Controller.ps1 for Full Pipeline's own three block-reason
        cases, but both files are always dot-sourced into the same script
        scope (Controller.ps1 already unconditionally depends on this
        module being loaded first, in real runs and in
        Controller.Harness.ps1 alike) - two same-named function
        definitions there don't coexist, the later-loaded one silently
        wins for every caller, so the "duplicate" was never actually two
        independently-live copies. Neither CleanConsoleRendering.ps1 (its
        own header explicitly says it "never interprets -Detail's
        contents," so a why-interpreting function doesn't belong there)
        nor Summary.ps1 (its domain is the final run summary, not live
        per-chapter status) was a clean fit as a shared home either, but
        this module already being a required dependency of Controller.ps1
        makes it one - not exported via -SharedFunctionNames since both
        callers are main-thread-only code, never a runspace worker.
    .OUTPUTS
        Two values: Status, Detail - same shape as
        Get-ChapterProgressStatus, ready to pass straight to
        Complete-ChapterProgress.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Status,
        [string]$Detail,
        [Parameter(Mandatory)]
        [string]$BlockedReason
    )
    if ($Status -eq 'Error') { return $Status, $Detail }
    # Lowercase "zip skipped" (2026-09-09, code-review fix), matching
    # ZipPipeline.ps1's own existing "zip skipped: ..." Detail text for
    # the identical concept - was "Zip skipped" (capital Z), a
    # user-visible casing mismatch between two pipelines' Detail text
    # for the same underlying event.
    $newDetail = if ($Detail) { $Detail + " | zip skipped: " + $BlockedReason } else { "zip skipped: " + $BlockedReason }
    return 'Warning', $newDetail
}

function Invoke-LooseImageConversionPipeline {
    <#
    .SYNOPSIS
        Mode 2 end to end (and mode 2's conversion half of mode 8).
        Migrated 2026-09-09 onto ChapterDispatch.ps1's Invoke-ChapterDispatch
        (step 3 of Docs\dispatch-redesign-design.md's 4-step migration
        order, after mode 3) - idle concurrency now picks up the NEXT
        chapter's jobs immediately instead of blocking on one chapter's
        Convert-ImageBatch call finishing before the next chapter's images
        are even enumerated. Walks the library the same two-tier way as
        before (New-SeriesProvider lazy across series, Get-SeriesChapters
        eager per series) via a custom -ChapterProvider closure (not
        ChapterDispatch.ps1's own New-LibraryChapterProvider - see that
        function's own header for why: this module's own naming-
        collision/"extra chapter-equivalent entry" completeness logic is
        genuinely per-engine domain knowledge, not something the generic
        primitive should own).

        Get-SeriesChapters alone is NOT the full picture of what gets
        converted: it's a thin wrapper on the zip-domain
        Get-ZippableLeafDirs, whose former-container/zip-staleness guards
        decide "is this worth re-zipping", not "does this need
        converting". Any directory holding a needs-conversion image that
        those guards excluded (a stray .zip alongside fresh loose images,
        or images sitting directly in the series root) is folded in as an
        extra chapter-equivalent entry - unchanged from before, still
        handled inside the -ChapterProvider closure.

        WHAT MOVED WHERE, mapping today's callbacks onto
        Invoke-ChapterDispatch's seven scriptblocks: the -ChapterProvider
        closure owns the series/chapter walk plus the naming-collision
        scan (Get-LooseImageCandidates, once per series) and embeds each
        chapter's own Images list, IsZippable, IsExtra, and ZipOut
        directly on the yielded chapter item; JobBuilder is a near-verbatim
        port of Convert-ImageBatch's OWN existing pre-dispatch pass
        (never-converted-extension skip, WebP/AVIF animated
        classification, within-batch output-path collision detection) -
        unlike mode 3's migration, this one was ALREADY a clean pre-pass
        in the original code, not something that needed restructuring;
        JobStarter is a near-verbatim port of Convert-ImageBatch's own
        per-job dispatch (WebP/AVIF/BMP/HEIC/HEIF pre-conversion to PNG
        via magick when needed, then the real cjxl dispatch) - kept here,
        NOT moved into JobBuilder, specifically so one chapter's earlier
        jobs keep converting in the background while a later job's own
        pre-conversion runs, the same interleaving the original code
        already had; JobFinalize is Complete-ImageDispatchJob (see that
        function's own header for why it's a documented duplicate of
        Complete-ImageConversionJob, not a call-through, and for a real,
        previously-latent PowerShell parameter-binding bug this migration
        caught before it ever ran); JobAbortCleanup deletes a force-killed
        job's own TempPng/JxlPath (both always safe to delete
        unconditionally here, unlike the old code's SlotReleased-guarded
        version - see AnimatedConversionPipeline.ps1's own identical
        reasoning for why, applies unchanged here); ChapterCompleteCallback
        resolves CCR, runs -ZipStepCallback and the zip-blocked-status
        override, and merges that chapter's own accumulator into $totals.

        A NEW per-chapter accumulator dictionary ($chapterResults, keyed
        by the exact chapterInfo value each chapter provider yields -
        matching ChapterDispatch.ps1's own chapter-identity contract)
        replaces the old code's implicit "one chapter, one blocking
        Convert-ImageBatch call" scoping - Invoke-ChapterDispatch now
        interleaves multiple chapters' jobs concurrently, so per-chapter
        results can no longer come from a single function call's own
        return value. Same reasoning, same fix shape, as
        AnimatedConversionPipeline.ps1's own migration.
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
        (AVIF files whose animation status couldn't be determined) PLUS
        any Get-LooseImageCandidates NamingCollisions this run hit
        directly (2026-08-31) - both mean "a real file this run couldn't
        safely act on", counted the same way Controller.ps1's own
        Full Pipeline combines its AVIF-classification failures.
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
        [string[]]$LooseImageExtensions = (Get-LooseImageExtensions),
        [string[]]$KnownZipPaths = @(),
        # Get-LooseImageExtensions() PLUS ".jxl" (2026-09-01 live-shakedown
        # fix, same root cause as Controller.ps1's Full Pipeline default -
        # see that parameter's own comment there for the full explanation).
        # This engine's own output extension is ".jxl", which the bare
        # loose list doesn't include - a chapter this pipeline already
        # finished converting (source images deleted, only .jxl left) was
        # otherwise invisible to Get-SeriesChapters on any later solo-mode
        # run, permanently, with no warning logged.
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

    # Per-chapter accumulator, keyed by the exact chapterInfo value each
    # chapter provider yields (see this function's own header) - built by
    # JobBuilder, mutated by JobStarter/JobFinalize, read and removed by
    # ChapterCompleteCallback.
    $chapterResults = [System.Collections.Generic.Dictionary[object,hashtable]]::new()

    # Captured once, read by every closure below instead of each one
    # reading $script:CleanConsoleOutputEnabled directly - see
    # AnimatedConversionPipeline.ps1's own identical fix/comment for why
    # ($script: resolves against a .GetNewClosure()'d scriptblock's own
    # private scope, not the real one).
    $cleanConsoleOutputEnabled = [bool]$script:CleanConsoleOutputEnabled

    # Registered for the whole pipeline call (one phase), not per-series/
    # per-chapter - matches Register-AbortCancellationSource's own "call
    # once per pipeline phase" contract. Without this, Test-AbortSignal
    # would never actually cancel $looseCts, and Invoke-ChapterDispatch's
    # own CancelToken check would never fire on a real Ctrl+C - see this
    # module's header for how that was caught.
    #
    # Construction/registration moved INSIDE the try (2026-08-31 fix, same
    # species as ZipParallelProcessing.ps1's mutex-leak fix earlier today) -
    # if either throws, the finally block below still runs and disposes
    # $looseCts if it was actually created.
    try {
        $looseCts = [System.Threading.CancellationTokenSource]::new()
        Register-AbortCancellationSource -Cts $looseCts

        # --- Chapter provider: same two-tier walk + naming-collision scan
        #     + extra-dir fold-in as before, restructured as a lazy
        #     "-> next chapter or $null" closure instead of a nested
        #     foreach - see this function's own header for why this isn't
        #     ChapterDispatch.ps1's New-LibraryChapterProvider. ---
        $seriesProvider  = New-SeriesProvider -LibraryPath $Path
        $chapterQueue    = [System.Collections.Generic.Queue[hashtable]]::new()
        $seriesExhausted = $false
        $chapterProvider = {
            while ($chapterQueue.Count -eq 0 -and -not $seriesExhausted) {
                # Checked here, not just via -AbortPollCallback (2026-09-09,
                # real behavior gap caught by this module's own harness) -
                # the old code's per-series while loop checked
                # Test-AbortSignal at the very top, before fetching the
                # next series at all; -AbortPollCallback alone only runs
                # once per Invoke-ChapterDispatch pass (after pull-ahead
                # may have already pulled up to -MaxQueueAhead chapters),
                # so an abort already pending before this function is even
                # called would otherwise still fetch and start processing
                # the first series before ever being noticed.
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

        # --- JobBuilder: near-verbatim port of Convert-ImageBatch's own
        #     existing pre-dispatch pass (see this function's own header -
        #     unlike mode 3's migration, this one was already a clean
        #     pre-pass, nothing to restructure). ---
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
                $allJobs.Add(@{
                    SrcPath = $srcPath
                    JxlPath = [System.IO.Path]::ChangeExtension($srcPath, ".jxl")
                    Proc    = $null
                    TempPng = $null
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

        # --- JobStarter: near-verbatim port of Convert-ImageBatch's own
        #     per-job dispatch - kept here rather than moved into
        #     JobBuilder, so an earlier job in the same chapter keeps
        #     converting in the background while a later job's own
        #     pre-conversion runs (see this function's own header). Every
        #     failure path here does its own domain-specific accounting
        #     ($cr.FailedCount++) before throwing, matching the original
        #     code's own behavior exactly - the generic
        #     JobStarterFailedCount Invoke-ChapterDispatch also bumps on
        #     the same throw is a harmless secondary diagnostic, not the
        #     real count this function reports. ---
        $jobStarter = {
            param($job)
            $cr = $chapterResults[$job.ChapterKey]
            $tempPngLocal = $null
            $magickProcLocal = $null
            # Set right before the two pre-conversion failure throws below,
            # each of which already does its own $cr.FailedCount++ and
            # logging - tells the catch block not to double-count when one
            # of THOSE throws propagates here, without any fragile
            # exception-message matching.
            $failureAlreadyAccounted = $false
            try {
                # [System.Diagnostics.ProcessStartInfo]::new(), not
                # New-Object - same fix as Convert-ImageBatch's own copy of
                # this closure above (this is Complete-ImageConversionJob's
                # sibling JobStarter, Convert-ImageBatch's own dispatch
                # loop).
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName               = $CjxlExe
                $psi.UseShellExecute        = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $psi.CreateNoWindow         = $true

                $isWebp = ($job.SrcPath -imatch '\.webp$')
                $isAvif = ($job.SrcPath -imatch '\.avif$')
                $isBmp  = ($job.SrcPath -imatch '\.bmp$')
                $isHeic = ($job.SrcPath -imatch '\.heic$')
                $isHeif = ($job.SrcPath -imatch '\.heif$')
                if ($job.TempPng) {
                    # Retry job (ICC-strip) - TempPng already points to a
                    # complete, ready-to-use PNG. Checked BEFORE the
                    # isWebp/isAvif branch below - see
                    # Convert-ImageBatch's own identical comment for why.
                    $cjxlSrc = $job.TempPng
                } elseif ($isWebp -or $isAvif -or $isBmp -or $isHeic -or $isHeif) {
                    $formatLabel = if ($isAvif) { "AVIF" } elseif ($isWebp) { "WebP" } elseif ($isBmp) { "BMP" } elseif ($isHeic) { "HEIC" } else { "HEIF" }
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
                    # [System.Diagnostics.ProcessStartInfo]::new(), not
                    # New-Object - same fix as this closure's own $psi above.
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
                # Real Process.Start() failure for cjxl itself (a stale
                # cached exe path, etc.) - matches Convert-ImageBatch's
                # own catch block. The two pre-conversion failure paths
                # above already did their own $cr.FailedCount++ and
                # logging before throwing - $failureAlreadyAccounted skips
                # double-counting for those, no exception-message matching
                # needed.
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

        # Always safe to delete both paths unconditionally here - see
        # AnimatedConversionPipeline.ps1's own identical JobAbortCleanup
        # comment for why (Invoke-ChapterDispatch only ever calls this for
        # a job confirmed never to have reached JobFinalize).
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
            $chapterResults.Remove($chapterInfo)
        }.GetNewClosure()

        # Test-AbortSignal must be called from SOMEWHERE regularly for a
        # real abort to ever propagate into $looseCts - see
        # AnimatedConversionPipeline.ps1's own identical comment for the
        # full reasoning.
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
        # $looseCts can be unset if construction/registration itself threw
        # (now inside the try above).
        if ($looseCts) {
            Unregister-AbortCancellationSource -Cts $looseCts
            $looseCts.Dispose()
        }
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
        gap this leaves (deliberately, not an oversight either). Includes
        Get-NeverConvertedExtensions (2026-09-02) - Convert-ImageBatch's
        own pre-pass calls it directly to decide whether to skip a file
        (currently just ".gif") rather than dispatch it to cjxl. Includes
        Test-WebPAnimated (2026-09-09 extraction, this same module) -
        Convert-ImageBatch's own WebP pre-pass calls it directly, same
        reason as Test-AvifAnimated above.
    #>
    return @('Convert-ImageBatch', 'Complete-ImageConversionJob', 'Invoke-IccStripRetryOrFail', 'Test-AvifAnimated', 'Get-NeverConvertedExtensions', 'Test-WebPAnimated')
}
