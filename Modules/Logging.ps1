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
      $script:logWarnFile, $script:pathHash

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

    Initialize-LogPaths's full-logging branch Recycle-Bins old log files
    left over from previous runs against the same target, via
    Move-ToRecycleBin - now a real function in Modules\FileDeletion.ps1
    (confirmed matching signature, see the comment at that call site).
    Callers that dot-source Logging.ps1 standalone (as the harness does)
    still need to stub that function out, or dot-source FileDeletion.ps1
    too.

    Log files are written UTF-8, not ASCII - the historical ASCII-only
    rule (see CHANGELOG.md v3.0/v4.0) was about emoji/unicode literally
    hardcoded into the script's own SOURCE causing problems, not about
    runtime log content, so it doesn't apply to the log file's own
    encoding. Non-ASCII message text (this project's manga-library domain
    routinely has Japanese/Korean/Chinese filenames) is written through
    as-is, not sanitized to "?" like the original extraction did.

    Initialize-LogMutex centralizes the "JxlLogMutex_" + pathHash naming
    convention, previously reimplemented independently at 3 call sites
    (see its own header comment). Not yet adopted by those call sites -
    this only makes the shared implementation available, migrating the
    existing duplicates is separate, not-yet-authorized work.

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

function Initialize-LogPaths {
    <#
    .SYNOPSIS
        Computes this run's log file path(s) and $script:pathHash, and (in
        split-log mode) clears stale Error/Warn logs from a previous run.
        Call once, before anything calls Write-Log.
    .PARAMETER TargetPath
        The directory being processed - hashed (SHA-256) to build
        $script:pathHash, so log/state/mutex names for different -Path
        targets run from the same script location never collide. Exposed
        as $script:pathHash afterward since other modules (zip creation/
        validation mutex naming, resume-state) need the same value - call
        this first if a caller needs $script:pathHash for its own purposes
        too, rather than hashing $TargetPath a second time.
    .PARAMETER FullLogging
        $true: one combined timestamped log file, every level.
        $false: three split files (Summary/Errors/Warnings), Info not
        persisted. Split mode's Error/Warn files are cleared here so a
        clean run's absence of new errors/warnings isn't confused with
        stale ones from a previous run.
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

        # Clean up old full-logging files left over from previous runs
        # against this same target (same $pathHashShort) - each run gets
        # its own timestamped file and nothing ever deleted them before.
        # Recycle-Bin'd, not permanently deleted, regardless of
        # $PermanentDelete - these are the user's own log history, not a
        # job-generated intermediate (see CLAUDE.md's deletion-semantics
        # convention), so they get the safer default unconditionally.
        #
        # FORWARD REFERENCE: Move-ToRecycleBin isn't defined in this
        # module - it's Modules\FileDeletion.ps1's function. RESOLVED
        # (2026-08-14): FileDeletion.ps1 is now built for real, and its
        # Move-ToRecycleBin signature (-ItemPath <string>, single
        # file/dir path) matches this call exactly - no changes needed
        # here. Callers must dot-source FileDeletion.ps1 (in either order
        # relative to this file, just before Initialize-LogPaths's
        # full-logging branch actually runs) for this to resolve.
        # Logging.Harness.ps1 still stubs this function out, since
        # Logging must stay standalone-testable without a real dependency
        # on FileDeletion.
        $oldLogPattern = "Conversion Log - * - " + $pathHashShort + ".log"
        $oldLogs = Get-ChildItem -LiteralPath $ScriptDir -Filter $oldLogPattern -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.FullName -ne $script:logFile }
        foreach ($oldLog in $oldLogs) {
            try { Move-ToRecycleBin -ItemPath $oldLog.FullName } catch { }
        }
    } else {
        $script:logFile            = $null
        $script:SummaryFileEnabled = -not $DisableSummaryFile
        $script:logSummaryFile     = if ($script:SummaryFileEnabled) { Join-Path $ScriptDir ("Conversion Log - Summary - " + $pathHashShort + ".log") } else { $null }
        $script:logErrorFile       = Join-Path $ScriptDir ("Conversion Log - Errors - "   + $pathHashShort + ".log")
        $script:logWarnFile        = Join-Path $ScriptDir ("Conversion Log - Warnings - " + $pathHashShort + ".log")

        foreach ($staleLog in @($script:logErrorFile, $script:logWarnFile)) {
            if (Test-Path -LiteralPath $staleLog) {
                try { Remove-Item -LiteralPath $staleLog -Force } catch { }
            }
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
        independently reimplemented at every call site that needed it
        (previously: Conversion Script Main.ps1 twice, and
        ZipParallelProcessing.ps1 once - confirmed via grep, not just
        suspected) rather than being this module's own responsibility.
        Centralized here now. NOT YET adopted by those existing call
        sites - see CLAUDE.md's "Known gaps" for why, and don't migrate
        them without an explicit go-ahead first (they're already-built,
        already-tested modules/script sections).
    .PARAMETER PathHash
        Defaults to $script:pathHash (set by Initialize-LogPaths) if not
        supplied. Must be passed explicitly from a runspace worker that
        hasn't called Initialize-LogPaths itself - the established
        pattern elsewhere in this codebase (see the module header) is for
        a worker to receive the values it needs as its own parameters,
        since $script:pathHash inside a fresh runspace is independent
        state, not inherited from the caller.
    #>
    param([string]$PathHash)

    if ([string]::IsNullOrEmpty($PathHash)) { $PathHash = $script:pathHash }
    if ([string]::IsNullOrEmpty($PathHash)) {
        throw "Initialize-LogMutex: no -PathHash supplied and `$script:pathHash is not set - call Initialize-LogPaths first, or pass -PathHash explicitly (e.g. from a runspace worker's own parameters)."
    }

    $script:logMutex = [System.Threading.Mutex]::new($false, ("JxlLogMutex_" + $PathHash))
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

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info", "Warn", "Error", "Summary")][string]$Level = "Info"
    )

    $line = (Get-Date -Format "yyyy-MM-dd HHmmss") + " [" + $Level + "] " + $Message

    if ($script:FullLogging) {
        # Full-logging mode: every level goes to the single timestamped file
        Invoke-MutexGuardedWrite { $line | Out-File -FilePath $script:logFile -Append -Encoding UTF8 }
    } else {
        # Split-log mode
        if ($Level -eq "Error") {
            Invoke-MutexGuardedWrite { $line | Out-File -FilePath $script:logErrorFile -Append -Encoding UTF8 }
        } elseif ($Level -eq "Warn") {
            Invoke-MutexGuardedWrite { $line | Out-File -FilePath $script:logWarnFile -Append -Encoding UTF8 }
        } elseif ($Level -eq "Summary") {
            # Summary is written later in block form; nothing to do per-line here
        }
        # Info lines are not written in split-log mode
    }

    # Inside a runspace worker, $script:workerConsoleQueue is set and
    # cross-thread Write-Host is unsafe, so queue for the main thread to
    # drain via Flush-ConsoleQueue instead of writing directly.
    if ($null -ne $script:workerConsoleQueue) {
        $script:workerConsoleQueue.Enqueue([pscustomobject]@{ Message = $Message; Level = $Level })
    } else {
        switch ($Level) {
            "Error"   { Write-Host $line -ForegroundColor Red    }
            "Warn"    { Write-Host $line -ForegroundColor Yellow }
            "Summary" { Write-Host $line -ForegroundColor Cyan   }
            default   { Write-Host $line }
        }
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
        $line = (Get-Date -Format "yyyy-MM-dd HHmmss") + " [" + $item.Level + "] " + $item.Message
        switch ($item.Level) {
            "Error"   { Write-Host $line -ForegroundColor Red    }
            "Warn"    { Write-Host $line -ForegroundColor Yellow }
            "Summary" { Write-Host $line -ForegroundColor Cyan   }
            default   { Write-Host $line }
        }
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
