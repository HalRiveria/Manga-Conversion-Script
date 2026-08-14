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

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info", "Warn", "Error", "Summary")][string]$Level = "Info"
    )

    $line = (Get-Date -Format "yyyy-MM-dd HHmmss") + " [" + $Level + "] " + $Message
    $safeLine = [System.Text.RegularExpressions.Regex]::Replace($line, "[^\x00-\x7F]", "?")

    $mtx = $script:logMutex

    if ($script:FullLogging) {
        # Full-logging mode: every level goes to the single timestamped file
        try   {
            if ($null -ne $mtx) { $null = $mtx.WaitOne() }
            $safeLine | Out-File -FilePath $script:logFile -Append -Encoding ASCII
        }
        finally { if ($null -ne $mtx) { $mtx.ReleaseMutex() } }
    } else {
        # Split-log mode
        if ($Level -eq "Error") {
            try   {
                if ($null -ne $mtx) { $null = $mtx.WaitOne() }
                $safeLine | Out-File -FilePath $script:logErrorFile -Append -Encoding ASCII
            }
            finally { if ($null -ne $mtx) { $mtx.ReleaseMutex() } }
        } elseif ($Level -eq "Warn") {
            try   {
                if ($null -ne $mtx) { $null = $mtx.WaitOne() }
                $safeLine | Out-File -FilePath $script:logWarnFile -Append -Encoding ASCII
            }
            finally { if ($null -ne $mtx) { $mtx.ReleaseMutex() } }
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

    $safeBlock = $block | ForEach-Object {
        [System.Text.RegularExpressions.Regex]::Replace($_, "[^\x00-\x7F]", "?")
    }

    $mtx = $script:logMutex
    try {
        if ($null -ne $mtx) { $null = $mtx.WaitOne() }
        $existing = ""
        if (Test-Path -LiteralPath $script:logSummaryFile) {
            $existing = [System.IO.File]::ReadAllText($script:logSummaryFile)
        }
        $newContent = ($safeBlock -join "`r`n") + "`r`n" + $existing
        [System.IO.File]::WriteAllText($script:logSummaryFile, $newContent, [System.Text.Encoding]::ASCII)
    }
    finally { if ($null -ne $mtx) { $mtx.ReleaseMutex() } }
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
