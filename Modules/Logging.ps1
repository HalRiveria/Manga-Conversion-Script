<#
.SYNOPSIS
    Logging - shared Write-Log/Write-SummaryLog/Flush-ConsoleQueue plus the
    log-file-path setup every mode needs.

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules. Call Initialize-LogPaths
    once, near script startup, before anything calls Write-Log.

    State this module owns (matches the pattern AbortPipeline.ps1 already
    uses for its own $script:abortRequested/$script:ctrlCloseAbort - a
    module owns its own script-scope state, callers don't set it up):
      $script:logMutex, $script:workerConsoleQueue, $script:FullLogging,
      $script:logFile, $script:logSummaryFile, $script:logErrorFile,
      $script:logWarnFile, $script:pathHash, $script:CleanConsoleOutputEnabled

    Clean Console Output (2026-08-18): when
    Initialize-CleanConsoleOutput -Enabled $true has been called,
    Write-Log stops echoing to the console entirely (both the direct
    Write-Host path and the worker-queue-then-Flush-ConsoleQueue path -
    since nothing gets enqueued in the first place, Flush-ConsoleQueue
    naturally has nothing to drain, no separate change needed there).
    Log FILE writes are completely unaffected either way - this toggle
    only ever controls the console echo, matching this feature's
    project-wide rule (see CLAUDE.md's "Clean Console Output" section)
    that log content is never touched by it. With the toggle on, all
    user-facing console output becomes CleanConsoleRendering.ps1's job
    (series/chapter/progress-bar display, including persisted
    Warning/Error/Aborted chapter lines) instead of Write-Log's own
    per-line echo - this module doesn't call into CCR itself, it just
    gets out of the way.

    Runspace workers get their own independent copy of this state (a
    runspace doesn't share the parent scope) - the established pattern
    elsewhere in this codebase (see Modules\_Reference\ZipPipeline's
    $zipOnlyWorker, RezipPipeline's $zipWorker) is for the worker
    scriptblock to set $script:logFile/$script:logMutex/etc. itself from
    parameters it was bound at dispatch time, then call Write-Log exactly
    as the main thread does. Write-Log/Write-SummaryLog reference this
    module's state via explicit $script: prefixes (not bare names, unlike
    the original main-script code this was extracted from) so that's
    unambiguous regardless of which runspace they're executing in -
    verified live (see the harness) that this resolves correctly to
    whichever runspace's own script-scope state was set, not the main
    thread's, when Write-Log is invoked from inside a worker.

    Write-Log/Write-SummaryLog both go through the internal
    Invoke-MutexGuardedWrite helper, which absorbs
    AbandonedMutexException (a previous holder terminating without
    releasing - e.g. a force-stopped worker mid-write - still results in
    a successful acquire, not a failure) so every WaitOne() call site
    doesn't need to repeat that handling itself.

    Neither logging mode ever deletes or clears a previous run's own log
    content (2026-09-03 fix, project owner's own explicit call): full-
    logging mode gets a fresh uniquely-timestamped file every run (nothing
    to clear - no fixed-name ambiguity); split-log mode's fixed-name
    Errors/Warnings/Summary files all ACCUMULATE across runs instead, with
    the NEWEST run always on top - each run's own content is marked off by
    a "=== Run: <timestamp> ===" header. Summary already worked this way
    (Write-SummaryLog collects the whole run's lines and prepends them as
    one block); Errors/Warnings are written incrementally throughout a run
    instead, from potentially several runspace workers at once (Full
    Pipeline's per-chapter dispatch), so they use a different mechanism to
    get the same "newest on top" result: Write-Log still just appends in
    real time (Initialize-LogPaths captures the file's pre-run content
    first), and Complete-LogRun (call once, on the main thread, right
    after a run finishes) moves that run's newly-appended content above
    the captured pre-run content - see that function's own header comment
    for why it's done once at the end rather than per-line. A previous
    design here Recycle-Binned Errors/Warnings at the start of every run
    so a clean run's absence of new content wasn't confused with a stale
    previous run's - that distinction is now made by the run-separator
    header instead of by deleting anything.

    Log files are written UTF-8, not ASCII - the historical ASCII-only
    rule (see CHANGELOG.md v3.0/v4.0) was about emoji/unicode literally
    hardcoded into the script's own SOURCE causing problems, not about
    runtime log content, so it doesn't apply to the log file's own
    encoding. Non-ASCII message text (this project's manga-library domain
    routinely has Japanese/Korean/Chinese filenames) is written through
    as-is, not sanitized to "?" like the original extraction did.

    Initialize-LogMutex centralizes the "JxlLogMutex_" + pathHash naming
    convention, previously reimplemented independently at every call site
    that needed it (the main script, ZipParallelProcessing.ps1). Both
    real call sites have since migrated onto this shared implementation -
    see its own header comment.

.NOTES
    Extracted from Conversion Script Main.ps1 - see
    Modules\_Reference\Logging.reference.ps1 for the verbatim source this
    was built from, with original line numbers.
#>

# ==============================================================================
#  Module-owned state
# ==============================================================================
$script:logMutex           = $null   # set to the real mutex once workers are running
$script:workerConsoleQueue = $null   # non-null only inside a runspace worker; when set,
                                      # Write-Log queues console output instead of calling
                                      # Write-Host directly (cross-thread console writes
                                      # are not safe/visible from a background runspace).
                                      # NAMED DIFFERENTLY FROM the plain $consoleQueue local
                                      # var used elsewhere for dispatch-loop setup - that
                                      # local var and this script-scope one once shared the
                                      # same name, which silently broke ALL console output
                                      # (but not file logging) for the remainder of any run
                                      # that included a ZIP phase. Do not rename this back.
$script:FullLogging        = $false
$script:logFile            = $null
$script:logSummaryFile     = $null
$script:logErrorFile       = $null
$script:logWarnFile        = $null
$script:pathHash           = $null
$script:SummaryFileEnabled = $true   # only meaningful when FullLogging = $false - see
                                      # Initialize-LogPaths -DisableSummaryFile and
                                      # Write-SummaryLog
$script:CleanConsoleOutputEnabled = $false   # see Initialize-CleanConsoleOutput
$script:logErrorPriorContent = ""   # split-log mode only - the file's content from BEFORE
$script:logWarnPriorContent  = ""   # this run started, captured once at Initialize-LogPaths -
                                      # see Complete-LogRun, which uses this to move this run's
                                      # own newly-appended content to the top of the file once
                                      # the run finishes, so the newest run stays on top.

function Initialize-LogPaths {
    <#
    .SYNOPSIS
        Computes this run's log file path(s) and $script:pathHash, and (in
        split-log mode) captures each file's pre-run content so
        Complete-LogRun can move this run's own content above it once the
        run finishes. Call once, before anything calls Write-Log.
    .PARAMETER TargetPath
        The directory being processed - hashed (SHA-256) to build
        $script:pathHash, so log/state/mutex names for different -Path
        targets run from the same script location never collide. Exposed
        as $script:pathHash afterward since other modules (zip creation/
        validation mutex naming, resume-state) need the same value - call
        this first if a caller needs $script:pathHash for its own purposes
        too, rather than hashing $TargetPath a second time.
    .PARAMETER FullLogging
        $true: one combined timestamped log file, every level, a fresh
        file every run.
        $false: three split files (Summary/Errors/Warnings), Info not
        persisted, all three accumulating across runs - a "=== Run:
        <timestamp> ===" header marks where each run's Error/Warn content
        starts.
    .PARAMETER DisableSummaryFile
        Only meaningful when -FullLogging is $false. When set, the
        Summary log file is never created/written - Write-SummaryLog
        becomes a no-op - but Summary lines still print to the console as
        normal via Write-Log (that path is unaffected; this only controls
        the on-disk Summary file). Ignored when -FullLogging is $true,
        since there's no separate Summary file in that mode to disable -
        Summary lines already go into the one combined file like
        everything else.
    .PARAMETER ScriptDir
        Where log files are written. Defaults to $PSScriptRoot of the
        caller if not supplied, falling back to the current location.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$TargetPath,
        [Parameter(Mandatory)]
        [bool]$FullLogging,
        [bool]$DisableSummaryFile = $false,
        [string]$ScriptDir
    )

    if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
        $ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    }

    $pathBytes = [System.Text.Encoding]::UTF8.GetBytes($TargetPath.ToLowerInvariant())
    $sha256    = [System.Security.Cryptography.SHA256]::Create()
    try {
        $script:pathHash = ([System.BitConverter]::ToString($sha256.ComputeHash($pathBytes)) -replace "-", "")
    } finally {
        $sha256.Dispose()
    }
    $pathHashShort = $script:pathHash.Substring(0, 10)

    $script:FullLogging = $FullLogging

    if ($FullLogging) {
        $timestamp             = Get-Date -Format "yyyyMMdd HHmmss"
        $script:logFile        = Join-Path $ScriptDir ("Conversion Log - " + $timestamp + " - " + $pathHashShort + ".log")
        $script:logSummaryFile = $null
        $script:logErrorFile   = $null
        $script:logWarnFile    = $null
        $script:SummaryFileEnabled = $true   # DisableSummaryFile is ignored in this mode - see param docs

        # No old-log cleanup in this branch (2026-09-03 fix, real bug,
        # live-reported: a previous run's own timestamped full-logging
        # file - the one the user was actively looking at right after
        # that run finished - got Recycle-Bin'd out from under them the
        # moment the NEXT run against the same target started).
        # Previously this block swept every OTHER "Conversion Log - * -
        # <pathHash>.log" file for the same target into the Recycle Bin
        # on every run, on the theory that a fresh timestamped file every
        # run needed the same "clean up the old one" treatment split-log
        # mode's fixed-name Errors/Warnings files get. That reasoning
        # doesn't hold: a fixed-name file has to be cleared or it can't
        # tell this run's own errors from a stale previous run's, but a
        # UNIQUELY-timestamped file never has that ambiguity - there's no
        # reason it can't just be left alone. Project owner's own
        # explicit call: "if the logs are going to get a unique ID then
        # they shouldn't get deleted on subsequent runs." A per-run
        # accumulation toggle (keep every run's own file vs. the old
        # append-to-one-file behavior) is tracked separately in Todo.md -
        # this fix only stops the unwanted auto-deletion, it doesn't
        # change the one-file-per-run design itself.
    } else {
        $script:logFile            = $null
        $script:SummaryFileEnabled = -not $DisableSummaryFile
        $script:logSummaryFile     = if ($script:SummaryFileEnabled) { Join-Path $ScriptDir ("Conversion Log - Summary - " + $pathHashShort + ".log") } else { $null }
        $script:logErrorFile       = Join-Path $ScriptDir ("Conversion Log - Errors - "   + $pathHashShort + ".log")
        $script:logWarnFile        = Join-Path $ScriptDir ("Conversion Log - Warnings - " + $pathHashShort + ".log")

        # No clearing here (2026-09-03 fix, project owner's own explicit
        # call: split-log mode's Errors/Warnings/Summary files should all
        # ACCUMULATE across runs, newest run on top - matching
        # Write-SummaryLog's own already-existing prepend-block behavior,
        # not just Summary's). Previously this block sent both files to
        # the Recycle Bin at the start of every run so a clean run's
        # absence of new content wasn't confused with a stale previous
        # run's - now that distinction is made by the run-separator
        # header instead of by deleting anything.
        #
        # The header write + prior-content capture themselves do NOT
        # happen here (2026-09-03 fix, real bug caught by a same-session
        # /code-review pass: this function only runs once at bootstrap
        # and again only when FullLogging/DisableSummaryFile actually
        # changes - Invoke-MainLoop's own re-sync gates it on that - but
        # Complete-LogRun runs after EVERY run. A session with 2+ runs
        # between one Initialize-LogPaths call left every run after the
        # first with no header and a stale $logErrorPriorContent, so
        # Complete-LogRun's own StartsWith check silently failed and
        # those runs' content was never promoted to the top - live-
        # reproduced during that review). Start-LogRun (below) now owns
        # both, called once per run from Invoke-MainLoop, paired with
        # Complete-LogRun at the end of that same run.
    }
}

function Start-LogRun {
    <#
    .SYNOPSIS
        Call once, on the main thread, right before EACH run starts (not
        just once per session) - captures this run's pre-existing
        Errors/Warnings content and writes a "=== Run: <timestamp> ==="
        header, so Complete-LogRun (called after the run finishes) has a
        correct, THIS-RUN-specific boundary to reorder against. A no-op
        in full-logging mode (nothing to do - one fresh file per run,
        already handled by Initialize-LogPaths).
    .DESCRIPTION
        Deliberately separate from Initialize-LogPaths (2026-09-03 fix,
        real bug - see Complete-LogRun's own header for the full story):
        Initialize-LogPaths computes log file PATHS, which only need
        recomputing when FullLogging/DisableSummaryFile actually changes
        or at bootstrap - but a run's own header/prior-content capture
        needs to happen at the start of EVERY run regardless. Conflating
        the two meant every run after the first in a session (when
        nothing had toggled) got no header and a stale prior-content
        snapshot.

        Errors/Warnings I/O is wrapped in try/catch (2026-09-03 fix,
        same review pass) - a locked/AV-held log file used to have this
        exact failure handled gracefully by the old stale-log-clearing
        code this design replaced; the read/write calls below had lost
        that protection. A failure here degrades to "this run's content
        won't get a header/won't be reorderable" (logged as a Warn) -
        Complete-LogRun's own StartsWith guard already treats a missing/
        mismatched Prior as "leave the file alone", so this fails safe.
    #>
    if ($script:FullLogging) { return }

    $runHeader = "=== Run: " + (Get-Date -Format "yyyy-MM-dd HHmmss") + " ==="
    foreach ($target in @(
        @{ FilePath = $script:logErrorFile; PriorVar = 'logErrorPriorContent' },
        @{ FilePath = $script:logWarnFile;  PriorVar = 'logWarnPriorContent'  }
    )) {
        if ([string]::IsNullOrEmpty($target.FilePath)) { continue }
        try {
            $prior = if (Test-Path -LiteralPath $target.FilePath) { [System.IO.File]::ReadAllText($target.FilePath) } else { "" }
            Set-Variable -Scope Script -Name $target.PriorVar -Value $prior
            Invoke-MutexGuardedWrite { $runHeader | Out-File -FilePath $target.FilePath -Append -Encoding UTF8 }
        } catch {
            Write-Log ("Could not start a new run header in '" + $target.FilePath + "' - it may be locked or otherwise inaccessible. This run's own entries will still be appended, just without a run separator: " + $_) -Level Warn -ForceConsole
        }
    }
}

function Complete-LogRun {
    <#
    .SYNOPSIS
        Call once, on the main thread, right after a run finishes (every
        worker runspace it dispatched has already joined back by then) -
        moves this run's newly-appended Errors/Warnings content (whatever
        was written since Start-LogRun captured
        $script:logErrorPriorContent/$script:logWarnPriorContent) to the
        TOP of each file, so the newest run is always on top, matching
        Write-SummaryLog's own prepend-block behavior for the Summary
        file. A no-op in full-logging mode (nothing to reorder - one
        combined file, no split Errors/Warnings) and a no-op for a file
        that doesn't exist (a genuinely clean first-ever run for this
        target, with nothing written at all - not even a header).
    .DESCRIPTION
        Deliberately a single end-of-run reorder rather than something
        every Write-Log call does - see Start-LogRun for why: this keeps
        the real-time write path (used by every runspace worker that can
        log an Error/Warn) exactly the plain mutex-guarded append it
        always was, and only reorders content once the run is back to
        being single-threaded. A crash/force-kill mid-run simply means
        this never runs for that run - its content stays appended at the
        BOTTOM of the file instead of moved to the top; nothing is lost.

        Wrapped in try/catch per file (2026-09-03 fix, real bug caught by
        a same-session /code-review pass) - a locked/AV-held file used to
        be handled gracefully by the old stale-log-clearing code this
        design replaced; this rewrite's own ReadAllText/WriteAllText had
        no such protection, so a locked Errors/Warnings file could throw
        uncaught out of Invoke-MainLoop (this function's real call site),
        killing the whole run loop for a run that had otherwise already
        finished successfully. A failed reorder now just logs a Warn and
        leaves this run's content appended at the bottom, same as the
        "shouldn't happen" fallback below already does deliberately.
        StartsWith/Substring use Ordinal comparison, not the culture-
        sensitive default - a culture-aware match could treat two
        different byte sequences as an equal prefix (relevant here since
        these logs routinely carry non-ASCII manga filenames), splitting
        $current at the wrong character count.
    #>
    foreach ($target in @(
        @{ FilePath = $script:logErrorFile; Prior = $script:logErrorPriorContent },
        @{ FilePath = $script:logWarnFile;  Prior = $script:logWarnPriorContent  }
    )) {
        if ($script:FullLogging -or [string]::IsNullOrEmpty($target.FilePath) -or -not (Test-Path -LiteralPath $target.FilePath)) { continue }
        try {
            Invoke-MutexGuardedWrite {
                $current = [System.IO.File]::ReadAllText($target.FilePath)
                if ($current.StartsWith($target.Prior, [System.StringComparison]::Ordinal)) {
                    $thisRunContent = $current.Substring($target.Prior.Length)
                    [System.IO.File]::WriteAllText($target.FilePath, ($thisRunContent + $target.Prior), [System.Text.Encoding]::UTF8)
                }
                # else: the file no longer starts with the content captured at
                # Start-LogRun time (shouldn't happen under normal use) -
                # leave it untouched rather than guess at a transformation that
                # could scramble real content.
            }
        } catch {
            Write-Log ("Could not move this run's content to the top of '" + $target.FilePath + "' - it may be locked or otherwise inaccessible. The content is still there, just not reordered: " + $_) -Level Warn -ForceConsole
        }
    }
}

function Initialize-LogMutex {
    <#
    .SYNOPSIS
        Creates/attaches $script:logMutex to the shared "JxlLogMutex_" +
        pathHash named mutex, so every runspace synchronizing against the
        same target's log files uses the SAME underlying OS mutex.
    .DESCRIPTION
        This naming convention ("JxlLogMutex_" + pathHash) used to be
        independently reimplemented at every call site that needed it -
        the main script and ZipParallelProcessing.ps1. Both have since
        migrated onto this shared implementation; only the frozen
        `Modules\_Reference\Conversion Script Main - Old.ps1` and build-input
        reference files still carry the old inline construction, which is
        expected - they're historical, not live code.
    .PARAMETER PathHash
        Defaults to $script:pathHash (set by Initialize-LogPaths) if not
        supplied. Must be passed explicitly from a runspace worker that
        hasn't called Initialize-LogPaths itself - the established
        pattern elsewhere in this codebase (see the module header) is for
        a worker to receive the values it needs as its own parameters,
        since $script:pathHash inside a fresh runspace is independent
        state, not inherited from the caller.
    .NOTES
        Deliberately does NOT dispose whatever mutex was already at
        $script:logMutex before overwriting it (2026-08-31, confirmed by a
        same-day /code-review) - ZipParallelProcessing.ps1's own caller
        contract depends on that OLD reference staying valid: it saves it
        before calling this function specifically so it can restore it
        afterward once its own local mutex is no longer needed. Adding an
        unconditional dispose here would destroy that still-live reference
        out from under the caller. A future caller that re-initializes
        this mutex WITHOUT needing the old reference back is responsible
        for disposing it itself first - this function only ever creates
        the new one.
    #>
    param([string]$PathHash)

    if ([string]::IsNullOrEmpty($PathHash)) { $PathHash = $script:pathHash }
    if ([string]::IsNullOrEmpty($PathHash)) {
        throw "Initialize-LogMutex: no -PathHash supplied and `$script:pathHash is not set - call Initialize-LogPaths first, or pass -PathHash explicitly (e.g. from a runspace worker's own parameters)."
    }

    $script:logMutex = [System.Threading.Mutex]::new($false, ("JxlLogMutex_" + $PathHash))
}

function Initialize-CleanConsoleOutput {
    <#
    .SYNOPSIS
        Sets $script:CleanConsoleOutputEnabled once, matching the
        Initialize-FileDeletion -PermanentDelete "call once, don't
        re-pass every call" pattern. Call before anything calls
        Write-Log, alongside Initialize-LogPaths.
    .PARAMETER Enabled
        $true: Write-Log stops echoing to the console (log files
        unaffected) - the options-menu "Clean Console Output" toggle.
        $false (default): current behavior, Write-Log echoes every line
        to the console as it always has.
    .DESCRIPTION
        Like every other $script:-prefixed state this module owns, this
        is per-runspace - a worker that calls Write-Log must call this
        itself too (from its own dispatch-time parameters, the
        established pattern elsewhere in this module), or it silently
        keeps echoing to a console a background thread cannot safely
        write to. Not enforced here; documented so whoever wires this
        into a worker scriptblock doesn't miss it.
    #>
    param([Parameter(Mandatory)][bool]$Enabled)
    $script:CleanConsoleOutputEnabled = $Enabled
}

function Invoke-MutexGuardedWrite {
    <#
    .SYNOPSIS
        Internal helper (not meant to be called from outside this module) -
        runs $Action while holding $script:logMutex, if one is set.
    .DESCRIPTION
        Centralizes AbandonedMutexException handling in one place instead
        of repeating it at every WaitOne() call site. WaitOne() throws
        AbandonedMutexException when a previous holder terminated (e.g. a
        force-stopped worker mid-write) without releasing - but the
        calling thread still successfully acquires the mutex when that
        happens, it's a warning wrapped in an exception, not a failure.
        So: catch it and proceed as normal (do NOT skip $Action or skip
        releasing - either would leave the mutex abandoned again for the
        next caller, cascading the same exception forever).
    #>
    param([scriptblock]$Action)

    $mtx = $script:logMutex
    try {
        if ($null -ne $mtx) {
            try { $null = $mtx.WaitOne() }
            catch [System.Threading.AbandonedMutexException] { }
        }
        & $Action
    } finally {
        if ($null -ne $mtx) { try { $mtx.ReleaseMutex() } catch { } }
    }
}

function Format-LogLine {
    <#
    .SYNOPSIS
        Internal helper - "yyyy-MM-dd HHmmss [Level] Message", the one
        timestamped-line format both Write-Log (at write time) and
        Flush-ConsoleQueue (at drain time, its own fresh timestamp - see
        Flush-ConsoleQueue's own header for why that's intentional, not
        a bug) build independently.
    #>
    param([string]$Message, [string]$Level)
    return (Get-Date -Format "yyyy-MM-dd HHmmss") + " [" + $Level + "] " + $Message
}

function Write-LogLineToHost {
    <#
    .SYNOPSIS
        Internal helper - Write-Host $Line, colored by $Level. Shared by
        Write-Log's direct-echo path and Flush-ConsoleQueue's drain loop,
        which previously each carried this exact switch by hand.
    #>
    param([string]$Line, [string]$Level)
    switch ($Level) {
        "Error"   { Write-Host $Line -ForegroundColor Red    }
        "Warn"    { Write-Host $Line -ForegroundColor Yellow }
        "Summary" { Write-Host $Line -ForegroundColor Cyan   }
        default   { Write-Host $Line }
    }
}

function Write-LogLineToFile {
    <#
    .SYNOPSIS
        Internal helper - mutex-guarded append of $Line to $FilePath, or
        a no-op if $FilePath is empty/unset. Guarded the same way
        Write-SummaryLog already guards $script:logSummaryFile -
        Write-Log called before Initialize-LogPaths has run (a real,
        verified gap - see CHANGELOG.md/Todo.md) used to throw
        ParameterBindingValidationException on a null -FilePath instead
        of degrading like every other file-write path here does. Not
        reachable in the real script today (Initialize-LogPaths always
        runs first), but Write-Log's console echo still has real value
        even when a file write can't happen, so this only skips the file
        write, not the whole function. Shared by Write-Log's three
        near-identical file-write branches (logFile/logErrorFile/
        logWarnFile), which previously each repeated this "skip if
        empty, else mutex-guarded write" shape by hand.
    #>
    param([string]$FilePath, [string]$Line)
    if ([string]::IsNullOrEmpty($FilePath)) { return }
    Invoke-MutexGuardedWrite { $Line | Out-File -FilePath $FilePath -Append -Encoding UTF8 }
}

function Write-Log {
    <#
    .PARAMETER ForceConsole
        Bypasses the Clean Console Output console-echo gate below
        (2026-09-03 fix - real bug, live-reported: mode 5/Cover Deletion
        has no CCR live-progress display of its own to replace the
        suppressed lines with, so with CCO on it reported nothing to the
        console at all, silently, while still working and file-logging
        normally). Only meant for a pipeline like Cover Deletion that
        never starts a CCR live-redraw region - still routes through the
        same $script:workerConsoleQueue check as the normal path, so it
        stays cross-thread-safe if a future caller ever uses it from
        inside a worker runspace, even though none does today.
    #>
    param(
        [string]$Message,
        [ValidateSet("Info", "Warn", "Error", "Summary")][string]$Level = "Info",
        [switch]$ForceConsole
    )

    $line = Format-LogLine -Message $Message -Level $Level

    if ($script:FullLogging) {
        # Full-logging mode: every level goes to the single timestamped file.
        Write-LogLineToFile -FilePath $script:logFile -Line $line
    } else {
        # Split-log mode, per target file - Summary is written later in
        # block form (Write-SummaryLog), and Info lines are not persisted
        # at all in this mode, so neither reaches Write-LogLineToFile here.
        # Plain append, same as always - see Complete-LogRun for how this
        # run's content still ends up on top of the file once it finishes.
        if ($Level -eq "Error") {
            Write-LogLineToFile -FilePath $script:logErrorFile -Line $line
        } elseif ($Level -eq "Warn") {
            Write-LogLineToFile -FilePath $script:logWarnFile -Line $line
        }
    }

    # Clean Console Output: skip console echo entirely (both paths below) -
    # CleanConsoleRendering.ps1 owns all user-facing console output when
    # this toggle is on. Nothing gets enqueued in this branch either, so
    # Flush-ConsoleQueue naturally has nothing to drain - no change needed
    # there. -ForceConsole (see this function's own .PARAMETER doc) is the
    # one deliberate exception.
    if ($script:CleanConsoleOutputEnabled -and -not $ForceConsole) { return }

    # Inside a runspace worker, $script:workerConsoleQueue is set and
    # cross-thread Write-Host is unsafe, so queue for the main thread to
    # drain via Flush-ConsoleQueue instead of writing directly.
    if ($null -ne $script:workerConsoleQueue) {
        $script:workerConsoleQueue.Enqueue([pscustomobject]@{ Message = $Message; Level = $Level })
    } else {
        Write-LogLineToHost -Line $line -Level $Level
    }
}

function Write-SummaryLog {
    <#
    .SYNOPSIS
        Only used in split-log mode ($script:FullLogging = $false) -
        prepends a summary block to the Summary log so the newest run is
        always on top. No-ops cleanly if the Summary file was disabled
        via Initialize-LogPaths -DisableSummaryFile (or $script:logMutex
        was never set up at all) - Summary lines still reach the console
        through Write-Log regardless, this function only ever controls
        the on-disk file.
    #>
    param([string[]]$Lines)

    if (-not $script:SummaryFileEnabled -or [string]::IsNullOrEmpty($script:logSummaryFile)) { return }

    $timestamp = Get-Date -Format "yyyy-MM-dd HHmmss"
    $block = @("", ("=== Run: " + $timestamp + " ==="))
    $block += $Lines
    $block += "=== End of run ==="
    $block += ""

    Invoke-MutexGuardedWrite {
        $existing = ""
        if (Test-Path -LiteralPath $script:logSummaryFile) {
            $existing = [System.IO.File]::ReadAllText($script:logSummaryFile)
        }
        $newContent = ($block -join "`r`n") + "`r`n" + $existing
        [System.IO.File]::WriteAllText($script:logSummaryFile, $newContent, [System.Text.Encoding]::UTF8)
    }
}

function Flush-ConsoleQueue {
    <#
    .SYNOPSIS
        Drains $script:workerConsoleQueue on the main thread. Runspace
        workers cannot call Write-Host directly (cross-thread console
        writes are not safe/visible), so Write-Log queues instead when
        $script:workerConsoleQueue is set; every dispatch loop
        (ZipParallelProcessing, AbortPipeline, and eventually every
        pipeline module) calls this once per poll pass.
    #>
    param([System.Collections.Concurrent.ConcurrentQueue[object]]$Queue)

    $item = $null
    while ($Queue.TryDequeue([ref]$item)) {
        $line = Format-LogLine -Message $item.Message -Level $item.Level
        Write-LogLineToHost -Line $line -Level $item.Level
    }
}

function Write-LogFileSummary {
    <#
    .SYNOPSIS
        End-of-run display of where the log file(s) ended up. Optional -
        cosmetic only, callers may just skip calling this and print
        nothing, or do their own thing instead.
    #>
    if ($script:FullLogging) {
        Write-Host ("`r`nLog file: " + $script:logFile) -ForegroundColor Green
    } else {
        Write-Host "`r`nLog files:" -ForegroundColor Green
        if ($script:SummaryFileEnabled -and -not [string]::IsNullOrEmpty($script:logSummaryFile)) {
            Write-Host ("  Summary  : " + $script:logSummaryFile) -ForegroundColor Green
        } else {
            Write-Host "  Summary  : (disabled)" -ForegroundColor DarkGray
        }
        if (Test-Path -LiteralPath $script:logErrorFile) { Write-Host ("  Errors   : " + $script:logErrorFile) -ForegroundColor Green }
        if (Test-Path -LiteralPath $script:logWarnFile)  { Write-Host ("  Warnings : " + $script:logWarnFile)  -ForegroundColor Green }
    }
}

function Get-LoggingSharedFunctionNames {
    <#
    .SYNOPSIS
        The function names a caller must add to its own -SharedFunctionNames
        list (Invoke-ZipParallelProcessing) to safely call Write-Log from
        inside a runspace worker. Single source of truth for this group -
        added specifically so a future new Write-Log dependency only needs
        updating HERE, not at every one of Controller.ps1/RezipPipeline.ps1/
        ZipPipeline.ps1's own call sites by hand (the exact bug pattern that
        bit this project four times in one session - see CHANGELOG.md
        2026-08-29). Callers concatenate this with whatever other groups
        (FileDeletion, image/animated conversion, zip creation) they need.
    #>
    return @('Write-Log', 'Invoke-MutexGuardedWrite', 'Format-LogLine', 'Write-LogLineToHost', 'Write-LogLineToFile')
}
