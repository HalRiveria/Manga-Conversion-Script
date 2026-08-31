<#
.SYNOPSIS
    Standalone module: the Ctrl+C / window-close abort pipeline shared by
    every pipeline mode.

.DESCRIPTION
    Wired into Conversion Script Main.ps1 (Register-AbortHandler at
    bootstrap; Reset-AbortState called once per loop iteration by
    Controller.ps1's Invoke-MainLoop) - built and verified standalone
    first, per this repo's development process (see CLAUDE.md). Usage:

      1. Call Register-AbortHandler once, near script startup, to install
         the native Ctrl+C / window-close handler.
      2. Whenever a pipeline creates a CancellationTokenSource it wants
         cancelled on abort, call Register-AbortCancellationSource. Call
         Unregister-AbortCancellationSource when that CTS is disposed, so
         the registry doesn't hold a reference to a disposed object.
      3. Poll Test-AbortSignal wherever a pipeline's dispatch loop currently
         polls the equivalent inline check. It cancels every registered CTS
         exactly once and prints a one-time "[ABORT] ..." message.
      4. Once a pipeline has stopped dispatching new work and wants to wait
         for in-flight jobs before force-stopping stragglers, call
         Invoke-GracefulDrain. It ALWAYS signals DrainComplete when it
         returns (success or force-stop) - the caller does not need to call
         Complete-AbortDrain itself in that case. Complete-AbortDrain is
         exposed separately for paths that need to unblock the handler
         without going through a drain (e.g. abort detected before any job
         was ever dispatched).
      5. In the script's own top-level catch block, call
         Invoke-AbortOrFatalHandler -ErrorRecord $_ - disambiguates
         PowerShell's own internal Ctrl+C handling firing early (a
         PipelineStoppedException/OperationCanceledException thrown before
         step 1's handler suppresses it) from a genuine, unrelated crash.
         Built 2026-08-28 from a real extraction of the main script's own
         catch block that sat unmerged since this module was first built -
         see Modules\_Reference\AbortPipeline.reference.ps1 and CLAUDE.md's
         Known gaps for the full history.

    What this module deliberately does NOT own: per-pipeline dispatch loops
    (job scanning/throttling), per-mode abort summaries (stats formatting,
    "last completed" tracking), and resume-state writes. Those stay in each
    pipeline/module, using -ResultHandler on Invoke-GracefulDrain (same
    pattern as Invoke-ParallelFolderJobs's -ResultHandler) to fold results
    into whatever shape the caller needs.

    Clean Console Output touch point (2026-08-18): Test-AbortSignal's
    abort message and Invoke-GracefulDrain's wait/force-stop messages
    now route through CleanConsoleRendering.ps1's Write-GatedConsoleMessage
    instead of a raw Write-Host, when the toggle is on - a raw Write-Host
    firing while CCR's live region is mid-redraw would land wherever the
    cursor happens to be and get mangled by the next redraw.
    Write-GatedConsoleMessage (2026-08-29) centralizes the gate itself
    (this module used to check the toggle and branch between
    Write-CleanConsoleMessage/raw Write-Host at each of its 3 call sites
    by hand - now each just calls Write-GatedConsoleMessage and passes
    the toggle in). Two forward references this requires, both FROM
    Logging.ps1/CleanConsoleRendering.ps1 (both already built and tested,
    so both are confirmed against real signatures now, not stubbed-
    forward like Logging.ps1's original Move-ToRecycleBin reference was):
      - $script:CleanConsoleOutputEnabled - owned by Logging.ps1, NOT
        redeclared here. Read directly via the shared script scope every
        dot-sourced module lives in (the same pattern ZipCreation.ps1
        already uses for FileDeletion.ps1's $script:PermanentDelete) -
        deliberately not a second parallel toggle, so there's only ever
        one on/off switch to keep in sync. Defaults to $null/falsy (same
        as "off") if Logging.ps1 was never dot-sourced at all, so this
        module still works completely standalone with its original
        behavior - this harness proves that by never dot-sourcing
        Logging.ps1 and getting the original raw-Write-Host behavior
        throughout.
      - Write-GatedConsoleMessage - owned by CleanConsoleRendering.ps1.
        Takes the toggle as an explicit -CleanConsoleOutputEnabled
        parameter rather than reading $script:CleanConsoleOutputEnabled
        itself, since CleanConsoleRendering.ps1 documents itself as
        having NO forward references - this call site is what supplies
        that value, not the callee. Write-GatedConsoleMessage only does
        real CCR work (calling Write-CleanConsoleMessage) when the
        toggle passed in is true, so a caller that leaves the toggle off
        never needs CleanConsoleRendering.ps1 dot-sourced at all.
    Core abort mechanics (CTS registry, drain loop, force-kill) are
    unchanged by any of this - only the console-output call sites.
    Complete-AbortDrain also now finalizes the CCR display (force-
    resolving any still-active series via Complete-AllActiveSeriesProgress,
    same gating) before signalling DrainComplete - so a still-live
    progress region isn't left stuck forever when a run ends mid-abort.

.NOTES
    Extracted from Conversion Script Main.ps1's ConsoleCtrl type, script-scope
    abort state, Test-AbortSignal, and the graceful-drain loop that was
    previously duplicated (with minor variations) inside both
    Invoke-ParallelFolderJobs and the ZIP-extraction pipeline's own inline
    dispatch loop. See CLAUDE.md for the history of what's been fixed here
    relative to those originals:
      - DrainComplete is now always signalled by Invoke-GracefulDrain itself,
        closing a gap where Invoke-ParallelFolderJobs's callers (mode 3)
        never signalled it near the call site and instead relied on a
        catch-all far later in the script - risky given CTRL_CLOSE_EVENT
        gives the native handler only ~5s before Windows force-kills the
        process, and a drain can take up to the configured timeout (60s).
      - The drain loop now does one final completion-check pass after its
        timeout expires and before declaring stragglers force-stopped,
        closing the race documented in CLAUDE.md's "Known gaps" (a job that
        finishes in the ~250ms window between the last poll and the timeout
        firing was previously discarded and miscounted as force-stopped).
#>

# ==============================================================================
#  ConsoleCtrl - native Win32 console-control handler (P/Invoke)
#
#  SetConsoleCtrlHandler lets us intercept CTRL_CLOSE_EVENT (the X button)
#  synchronously - unlike AppDomain.ProcessExit which fires after PowerShell
#  has already begun its teardown and can no longer run script code reliably.
#
#  The handler is also used for CTRL_C_EVENT so both abort paths share one
#  implementation and we are no longer reliant on [Console]::CancelKeyPress
#  (which can be swallowed by PowerShell's own Ctrl+C handling).
#
#  The handler BLOCKS (via the drain event) until the main thread has finished
#  its graceful drain, then returns $true so the OS does not immediately kill
#  the process. For CTRL_CLOSE_EVENT Windows gives the handler ~5s before a
#  forced kill; for CTRL_C_EVENT there is no hard deadline.
# ==============================================================================
if (-not ([System.Management.Automation.PSTypeName]'ConsoleCtrl').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class ConsoleCtrl
{
    public delegate bool HandlerRoutine(uint ctrlType);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

    // Shared state set by the handler; polled by the main PowerShell thread.
    public static volatile bool AbortRequested = false;
    public static volatile bool IsCloseEvent   = false;   // true = X button, false = Ctrl+C

    // The handler signals this when abort is requested; the main thread calls
    // Set() when the graceful drain is complete so the handler can return.
    public static readonly ManualResetEventSlim DrainComplete = new ManualResetEventSlim(false);

    private static HandlerRoutine _handler;   // keep a strong ref so the GC can't collect it

    public static void Register()
    {
        _handler = new HandlerRoutine(Handler);
        SetConsoleCtrlHandler(_handler, true);
    }

    private static bool Handler(uint ctrlType)
    {
        // ctrlType: 0=CTRL_C, 1=CTRL_BREAK, 2=CTRL_CLOSE, 5=CTRL_LOGOFF, 6=CTRL_SHUTDOWN
        if (ctrlType == 0 || ctrlType == 1 || ctrlType == 2 || ctrlType == 5 || ctrlType == 6)
        {
            AbortRequested = true;
            IsCloseEvent   = (ctrlType == 2 || ctrlType == 5 || ctrlType == 6);
            // Block until the PowerShell main thread finishes the graceful drain
            // (or until Windows force-kills us after its timeout).
            DrainComplete.Wait(65000);   // 65 s > our default 60 s drain timeout
            return true;   // suppress default OS action
        }
        return false;
    }
}
'@ -Language CSharp
}

# ==============================================================================
#  Abort state
# ==============================================================================
$script:abortRequested = $false   # set once, by the first Test-AbortSignal call after abort
$script:ctrlCloseAbort  = $false  # set only when the X button (CTRL_CLOSE_EVENT) triggered the abort

# Registry of CancellationTokenSources to cancel on abort. Generalizes the
# hardcoded per-pipeline CTS list this replaced (one named variable per
# mode) so a future mode just registers its own CTS instead of editing
# Test-AbortSignal.
$script:abortCancellationSources = [System.Collections.Generic.List[System.Threading.CancellationTokenSource]]::new()

function Register-AbortHandler {
    <#
    .SYNOPSIS
        Installs the native Ctrl+C / window-close handler. Call once, near
        script startup, before any pipeline runs.
    #>
    [ConsoleCtrl]::Register()
}

function Register-AbortCancellationSource {
    <#
    .SYNOPSIS
        Adds a CancellationTokenSource to the set Test-AbortSignal cancels
        when an abort is detected. Call once per pipeline phase, right after
        creating that phase's CTS.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Threading.CancellationTokenSource]$Cts
    )
    $script:abortCancellationSources.Add($Cts)
}

function Unregister-AbortCancellationSource {
    <#
    .SYNOPSIS
        Removes a CancellationTokenSource from the abort registry. Call
        before/when disposing a phase's CTS, so the registry doesn't hold a
        reference to (and later try to .Cancel()) a disposed object.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Threading.CancellationTokenSource]$Cts
    )
    $null = $script:abortCancellationSources.Remove($Cts)
}

function Reset-AbortState {
    <#
    .SYNOPSIS
        Clears every piece of abort state back to "no abort has happened" -
        $script:abortRequested/$script:ctrlCloseAbort, the native handler's
        own [ConsoleCtrl]::AbortRequested/IsCloseEvent flags, and
        [ConsoleCtrl]::DrainComplete (a ManualResetEventSlim, reset back to
        unsignalled). Call once per real dispatched run, before that run's
        own Test-AbortSignal polling could ever see stale state from a
        PREVIOUS run in the same process.
    .DESCRIPTION
        Real bug this closes (found and verified live during a code
        review, see Todo.md/CHANGELOG.md): none of this state was EVER
        reset anywhere in production code before this function existed -
        only harness test setup ever reset it. Since Invoke-MainLoop
        (Controller.ps1) runs multiple mode selections in the same
        process (that's the whole point of "press any key to return to
        the main menu" after a run), a single Ctrl+C - even one that
        happened while idle at the menu, before any pipeline was even
        running - left $script:abortRequested stuck $true for the rest
        of the process's lifetime. Every subsequent run's very first
        Test-AbortSignal poll then saw an abort already "in progress" and
        aborted immediately, doing no real work, with no new Ctrl+C from
        the user - until the whole script was closed and reopened.
        Verified live: dot-source this module, trigger one abort, poll
        Test-AbortSignal again with no new Ctrl+C (still $true), call
        this function, poll again (now $false).

        Does NOT touch $script:abortCancellationSources - that registry's
        lifecycle is already handled per pipeline phase by
        Register-/Unregister-AbortCancellationSource and has nothing to
        do with whether a PAST abort happened.
    #>
    $script:abortRequested = $false
    $script:ctrlCloseAbort = $false
    [ConsoleCtrl]::AbortRequested = $false
    [ConsoleCtrl]::IsCloseEvent   = $false
    [ConsoleCtrl]::DrainComplete.Reset()
}

function Test-AbortSignal {
    <#
    .SYNOPSIS
        Polls for an abort request. Idempotent - only acts the first time it
        observes the native handler's flag set. Cancels every registered
        CancellationTokenSource and prints a one-time "[ABORT] ..." message.
    .OUTPUTS
        $true once an abort has been detected (on this and every subsequent
        call); $false until then.
    #>
    if ([ConsoleCtrl]::AbortRequested -and -not $script:abortRequested) {
        $script:abortRequested = $true
        $script:ctrlCloseAbort = [ConsoleCtrl]::IsCloseEvent
        foreach ($cts in @($script:abortCancellationSources)) {
            try { $cts.Cancel() } catch { }
        }
        $abortMessage = if (-not $script:ctrlCloseAbort) {
            "`n[ABORT] Ctrl+C detected - finishing current jobs, please wait..."
        } else {
            "`n[ABORT] Window close detected - finishing current jobs, please wait..."
        }
        Write-GatedConsoleMessage -Text $abortMessage -Color Yellow -CleanConsoleOutputEnabled ([bool]$script:CleanConsoleOutputEnabled)
    }
    return $script:abortRequested
}

function Get-AbortTriggerLabel {
    <#
    .SYNOPSIS
        Returns the human-readable abort trigger for summary text -
        "window close (X button)" or "Ctrl+C" - matching what every
        per-mode abort summary previously computed independently.
    #>
    if ($script:ctrlCloseAbort) { return "window close (X button)" }
    return "Ctrl+C"
}

function Complete-AbortDrain {
    <#
    .SYNOPSIS
        Signals the native handler that draining is complete, unblocking it
        so the OS can proceed (process exit for CTRL_CLOSE_EVENT, continued
        execution for CTRL_C_EVENT). Safe to call more than once - callers
        that already called Invoke-GracefulDrain do not need to call this
        too; it's for paths that need to unblock the handler without going
        through a drain (e.g. abort detected before any job was dispatched).
    .DESCRIPTION
        When Clean Console Output is on, also finalizes CCR's display
        (Complete-AllActiveSeriesProgress) BEFORE signalling DrainComplete -
        deliberately in that order, since CTRL_CLOSE_EVENT gives the OS
        license to force-kill the process shortly after DrainComplete
        unblocks the native handler, and a still-live progress region left
        stuck would otherwise never get finalized. No-ops cleanly (via
        Complete-AllActiveSeriesProgress's own no-active-series no-op) when
        there's nothing to finalize.
    #>
    if ($script:CleanConsoleOutputEnabled) {
        try { Complete-AllActiveSeriesProgress } catch { }
    }
    try { [ConsoleCtrl]::DrainComplete.Set() } catch { }
}

function Test-OwnAbortException {
    <#
    .SYNOPSIS
        True only if $ErrorRecord looks like our own abort mechanism
        firing early - PowerShell's internal Ctrl+C handling throwing a
        PipelineStoppedException/OperationCanceledException before our
        SetConsoleCtrlHandler-based handler suppresses it - rather than a
        genuine, unrelated crash. Requires BOTH conditions: an abort must
        already be in progress ($script:abortRequested) AND the exception
        type must match - an exception of either type that fires with NO
        abort in progress is a real crash that merely resembles one (e.g.
        an unrelated cancellation from some other source), not our own
        abort.
    .PARAMETER ErrorRecord
        The caught error - pass $_ from a catch block.
    .DESCRIPTION
        Calls Test-AbortSignal itself first, rather than reading
        $script:abortRequested directly - a Ctrl+C/window-close that lands
        during a stretch where nothing happens to be polling
        Test-AbortSignal (chapter discovery, Compress-FolderToZip,
        Test-ZipArchive, summary writing) left [ConsoleCtrl]::AbortRequested
        (the native handler's own flag, set immediately and independent of
        polling) true while $script:abortRequested (only ever set BY a
        Test-AbortSignal call) stayed false - so PowerShell's own
        PipelineStoppedException from that same Ctrl+C looked like a
        genuine, unrelated crash instead of our own abort firing early:
        logged as a FATAL ERROR, and Complete-AbortDrain never called,
        leaking the native handler thread (parked in
        DrainComplete.Wait(65000)). Calling Test-AbortSignal here brings
        $script:abortRequested (and its one-time side effects - CTS
        cancellation, the "[ABORT] ..." message) up to date from the native
        flag before this check runs, regardless of whether anything else
        polled first.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    $exType = $ErrorRecord.Exception.GetType().FullName
    return ((Test-AbortSignal) -and ($exType -like '*PipelineStoppedException*' -or $exType -like '*OperationCanceled*'))
}

function Invoke-AbortOrFatalHandler {
    <#
    .SYNOPSIS
        Ported from the real main script's top-level catch block (see
        Modules\_Reference\AbortPipeline.reference.ps1 for the verbatim
        extraction this was built from, and CLAUDE.md's Known gaps for
        the full history): if $ErrorRecord is our own abort firing early
        (Test-OwnAbortException), finalizes the drain via
        Complete-AbortDrain and does nothing else - this is a graceful
        abort, not an error, so nothing gets logged as one. Otherwise
        it's a genuine crash: builds a "FATAL ERROR: ..." message
        (exception text + stack trace) and hands it to -LogHandler.
    .PARAMETER LogHandler
        Scriptblock taking a single message string. Defaults to a raw
        Write-Host in red, matching Invoke-GracefulDrain's own
        -ErrorHandler default - this module has no hard dependency on
        the caller's Write-Log. A real caller with Logging.ps1 dot-
        sourced should pass `{ param($m) Write-Log $m -Level Error }`
        instead - Write-Log already handles mutex-guarded writes and
        FullLogging-aware file routing, which the original main-script
        snippet's raw (unguarded) Out-File call never did. The original
        snippet's ASCII-stripping (for a legacy `-Encoding ASCII` Out-File
        call) is deliberately NOT ported - Logging.ps1's real Write-Log
        already writes UTF-8, making that workaround dead code, not a
        behavior worth preserving.
    .OUTPUTS
        $true if this was our own abort (already handled, nothing more
        to do); $false if it was a genuine fatal error (already handed
        to -LogHandler).
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [scriptblock]$LogHandler = { param($Message) Write-Host ("`r`n" + $Message) -ForegroundColor Red }
    )

    if (Test-OwnAbortException -ErrorRecord $ErrorRecord) {
        Complete-AbortDrain
        return $true
    }

    $fatalMsg = "FATAL ERROR: " + $ErrorRecord.ToString() + "`r`nStack Trace:`r`n" + $ErrorRecord.ScriptStackTrace
    & $LogHandler $fatalMsg
    return $false
}

function Receive-CompletedHandles {
    <#
    .SYNOPSIS
        Internal helper: collects results from any completed handle in
        -Handles, invoking -ResultHandler for each, and returns the handles
        that are still running. Shared by Invoke-GracefulDrain's polling
        loop and its final post-timeout pass so both use the exact same
        collection logic.
    #>
    param(
        [System.Collections.Generic.List[hashtable]]$Handles,
        [scriptblock]$ResultHandler,
        [scriptblock]$ErrorHandler
    )
    $stillActive = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($h in $Handles) {
        if ($h.Handle.IsCompleted) {
            try {
                $results = $h.PS.EndInvoke($h.Handle)
                if ($null -ne $ResultHandler) {
                    foreach ($r in $results) { & $ResultHandler $r }
                }
            } catch {
                if ($null -ne $ErrorHandler) {
                    & $ErrorHandler ("Error collecting runspace result during abort drain: " + $_)
                }
            } finally {
                $h.PS.Dispose()
            }
        } else {
            $stillActive.Add($h)
        }
    }
    # The leading comma prevents PowerShell's pipeline output from enumerating
    # the list - without it, a 1-element list collapses to its bare element
    # (and a 0-element list to $null) instead of staying a List[hashtable],
    # corrupting the caller's -Handles on the next call. Live-caught: see
    # AbortPipeline.Harness.ps1 Scenario D/E, which failed with a confusing
    # "cannot convert Hashtable to List[hashtable]" error the very first time
    # this path was exercised with 1 remaining handle.
    return ,$stillActive
}

function Invoke-GracefulDrain {
    <#
    .SYNOPSIS
        Waits for in-flight PowerShell runspace jobs to finish naturally
        after an abort, then force-stops anything still running past the
        timeout. Always signals DrainComplete before returning, whether the
        drain finished cleanly or had to force-stop stragglers.
    .PARAMETER Handles
        A List[hashtable] of @{ PS = <PowerShell>; Handle = <IAsyncResult> }
        pairs - the same shape Invoke-ParallelFolderJobs and the
        ZIP-extraction pipeline's dispatch loop already build. Jobs not yet
        dispatched are the caller's concern (simply don't dispatch them once
        abort is detected) - this function only drains what's already
        running.
    .PARAMETER ResultHandler
        Scriptblock invoked once per completed job's result object, same
        pattern as Invoke-ParallelFolderJobs's -ResultHandler - a closure
        over the caller's own stats/tracking so this function doesn't need
        to know their shape.
    .PARAMETER ConsoleQueue
        Optional. If supplied, flushed via Flush-ConsoleQueue after each
        poll, matching the existing cross-thread console-logging pattern.
        Flush-ConsoleQueue must already be defined in the caller's scope
        (this module does not define its own copy).
    .PARAMETER ErrorHandler
        Optional scriptblock taking a single message string, invoked when a
        job's result collection throws. Defaults to Write-Host in red so
        this module has no hard dependency on the caller's Write-Log.
    .PARAMETER TimeoutSeconds
        How long to wait for in-flight jobs before force-stopping. Defaults
        to 60 (matching every existing call site) - overridable so tests can
        use a small value instead of waiting out a real 60s drain.
    .PARAMETER AbortWaitMessage
        Console message printed once when the drain begins. Pass an empty
        string to suppress it.
    .OUTPUTS
        @{ ForceStoppedCount = <int> } - 0 if every in-flight job finished
        within the timeout.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[hashtable]]$Handles,
        [scriptblock]$ResultHandler,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ConsoleQueue,
        [scriptblock]$ErrorHandler = { param($msg) Write-Host $msg -ForegroundColor Red },
        [int]$TimeoutSeconds = 60,
        [string]$AbortWaitMessage
    )

    if ($Handles.Count -eq 0) {
        Complete-AbortDrain
        return @{ ForceStoppedCount = 0 }
    }

    # A caller that never passes -AbortWaitMessage at all should get the
    # default message; a caller that explicitly passes "" should get
    # silence (per this parameter's own docs). Those are NOT the same
    # thing PowerShell hands back for an unbound [string] parameter - an
    # omitted [string] binds to "" (empty string), not $null, so the
    # original "if ($null -eq $AbortWaitMessage)" check below never
    # actually fired for any caller, ever: $AbortWaitMessage was already
    # "" by the time this ran, so the default message was built and
    # printed for nobody, silently, since the day this module was
    # written - live-caught (not hypothetical) via Scenario J's stricter
    # message-count assertions, which is the first test this module ever
    # had that actually checked the WAIT message's content, not just
    # that -TimeoutSeconds/force-stop counted correctly. Fixed by
    # checking $PSBoundParameters instead of the value itself, which
    # correctly distinguishes "never passed" from "passed empty on
    # purpose".
    if (-not $PSBoundParameters.ContainsKey('AbortWaitMessage')) {
        $AbortWaitMessage = "[ABORT] Waiting for current jobs to finish (up to " + $TimeoutSeconds + "s)..."
    }
    if ($AbortWaitMessage -ne "") {
        Write-GatedConsoleMessage -Text $AbortWaitMessage -Color Yellow -CleanConsoleOutputEnabled ([bool]$script:CleanConsoleOutputEnabled)
    }

    $localHandles  = $Handles
    $abortDeadline = [System.Diagnostics.Stopwatch]::StartNew()

    while ($localHandles.Count -gt 0 -and $abortDeadline.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $localHandles = Receive-CompletedHandles -Handles $localHandles -ResultHandler $ResultHandler -ErrorHandler $ErrorHandler
        if ($null -ne $ConsoleQueue) { Flush-ConsoleQueue -Queue $ConsoleQueue }
        if ($localHandles.Count -gt 0) { Start-Sleep -Milliseconds 250 }
    }

    # One final completion-check pass before declaring anything force-stopped.
    # Closes the race where a job finishes in the gap between the last poll
    # and the timeout firing - without this, that job's real result is
    # silently discarded and it's miscounted as force-stopped (see
    # CLAUDE.md "Known gaps" for the history of this exact bug).
    if ($localHandles.Count -gt 0) {
        $localHandles = Receive-CompletedHandles -Handles $localHandles -ResultHandler $ResultHandler -ErrorHandler $ErrorHandler
        if ($null -ne $ConsoleQueue) { Flush-ConsoleQueue -Queue $ConsoleQueue }
    }

    $forceStoppedCount = 0
    if ($localHandles.Count -gt 0) {
        $forceStoppedCount = $localHandles.Count
        $forceStopMessage = "[ABORT] Force-stopping " + $forceStoppedCount + " job(s) that did not finish within " + $TimeoutSeconds + "s."
        Write-GatedConsoleMessage -Text $forceStopMessage -Color Red -CleanConsoleOutputEnabled ([bool]$script:CleanConsoleOutputEnabled)
        foreach ($h in $localHandles) {
            try { $h.PS.Stop() } catch { }
            try { $h.PS.Dispose() } catch { }
        }
    }

    if ($null -ne $ConsoleQueue) { Flush-ConsoleQueue -Queue $ConsoleQueue }
    Complete-AbortDrain

    return @{ ForceStoppedCount = $forceStoppedCount }
}
