# See module-descriptions.md for this module's full description.

$script:logMutex           = $null
$script:workerConsoleQueue = $null   # NAMED DIFFERENTLY FROM the plain $consoleQueue local
                                      # var used elsewhere for dispatch-loop setup - see
                                      # Docs/function-notes.md, do not rename this back.
$script:FullLogging        = $false
$script:logFile            = $null
$script:logSummaryFile     = $null
$script:logErrorFile       = $null
$script:logWarnFile        = $null
$script:pathHash           = $null
$script:SummaryFileEnabled = $true
$script:CleanConsoleOutputEnabled = $false
$script:logErrorPriorContent = ""
$script:logWarnPriorContent  = ""
$script:logWriteFailureWarned = $null   # log files already warned about this run - see Write-LogWriteFailureWarning

function Initialize-LogPaths {
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
        $script:SummaryFileEnabled = $true
    } else {
        $script:logFile            = $null
        $script:SummaryFileEnabled = -not $DisableSummaryFile
        $script:logSummaryFile     = if ($script:SummaryFileEnabled) { Join-Path $ScriptDir ("Conversion Log - Summary - " + $pathHashShort + ".log") } else { $null }
        $script:logErrorFile       = Join-Path $ScriptDir ("Conversion Log - Errors - "   + $pathHashShort + ".log")
        $script:logWarnFile        = Join-Path $ScriptDir ("Conversion Log - Warnings - " + $pathHashShort + ".log")
    }
}

function Start-LogRun {
    $script:logWriteFailureWarned = $null
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
            # Report straight to the console rather than through Write-Log - see
            # Docs/function-notes.md for why (Write-Log would route a Warn back
            # into this same locked file and throw again, uncaught).
            $warnLine = Format-LogLine -Message ("Could not start a new run header in '" + $target.FilePath + "' - it may be locked or otherwise inaccessible. This run's own entries will still be appended, just without a run separator: " + $_) -Level "Warn"
            try { Write-LogLineToHost -Line $warnLine -Level "Warn" } catch { }
        }
    }
}

function Complete-LogRun {
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
                # else: content no longer starts with what Start-LogRun captured
                # (shouldn't happen) - leave it untouched rather than guess.
            }
        } catch {
            # Same reasoning as Start-LogRun's catch - see Docs/function-notes.md.
            $warnLine = Format-LogLine -Message ("Could not move this run's content to the top of '" + $target.FilePath + "' - it may be locked or otherwise inaccessible. The content is still there, just not reordered: " + $_) -Level "Warn"
            try { Write-LogLineToHost -Line $warnLine -Level "Warn" } catch { }
        }
    }
}

function Initialize-LogMutex {
    param([string]$PathHash)

    if ([string]::IsNullOrEmpty($PathHash)) { $PathHash = $script:pathHash }
    if ([string]::IsNullOrEmpty($PathHash)) {
        throw "Initialize-LogMutex: no -PathHash supplied and `$script:pathHash is not set - call Initialize-LogPaths first, or pass -PathHash explicitly (e.g. from a runspace worker's own parameters)."
    }

    # Deliberately does NOT dispose any previous $script:logMutex - see
    # Docs/function-notes.md, ZipParallelProcessing.ps1 depends on that.
    $script:logMutex = [System.Threading.Mutex]::new($false, ("JxlLogMutex_" + $PathHash))
}

function Get-LogMutex {
    # Plain accessor, not a closure - a .GetNewClosure()'d caller can't read
    # $script:logMutex directly (confirmed live: it resolves to $null inside
    # such a closure, not the real value - Docs/lessons-learned.md's 9th
    # entry). Invoke via a function reference (& ${function:Get-LogMutex})
    # from inside a closure instead of reading $script:logMutex there.
    return $script:logMutex
}

function Initialize-CleanConsoleOutput {
    param([Parameter(Mandatory)][bool]$Enabled)
    $script:CleanConsoleOutputEnabled = $Enabled
}

function Invoke-MutexGuardedWrite {
    param([scriptblock]$Action)

    $mtx = $script:logMutex
    $acquired = $true
    try {
        if ($null -ne $mtx) {
            # WaitOne() used to have no timeout (2026-09-16 fix, real bug,
            # live-experienced this session - see CHANGELOG.md): a stuck or
            # orphaned process that never released this named, system-wide
            # mutex left every later Write-Log call on the same target path
            # blocked here forever, 0% CPU, no error. 10s is generous for a
            # real writer (a brief file append) but short enough that a
            # genuinely stuck holder doesn't stall the whole run.
            try { $acquired = $mtx.WaitOne(10000) }
            catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        }
        if ($acquired) {
            & $Action
        } else {
            # Skip the write rather than proceed unguarded - some callers
            # (Write-SummaryLog, Complete-LogRun) do a real read-modify-write
            # against the shared file, which an unguarded write could
            # corrupt against whatever's still holding the mutex. Reported
            # straight to the console, not through Write-Log - this IS
            # Write-Log's own write path; recursing back in would just wait
            # on the same stuck mutex again.
            $warnLine = Format-LogLine -Message "Could not acquire the log mutex within 10s - a prior process may still be holding it. This write was skipped rather than risk corrupting the log file." -Level "Warn"
            try { Write-LogLineToHost -Line $warnLine -Level "Warn" } catch { }
        }
    } finally {
        if ($acquired -and $null -ne $mtx) { try { $mtx.ReleaseMutex() } catch { } }
    }
}

function Format-LogLine {
    param([string]$Message, [string]$Level)
    return ([System.DateTime]::Now.ToString("yyyy-MM-dd HHmmss")) + " [" + $Level + "] " + $Message
}

function Write-LogLineToHost {
    param([string]$Line, [string]$Level)
    switch ($Level) {
        "Error"   { Write-Host $Line -ForegroundColor Red    }
        "Warn"    { Write-Host $Line -ForegroundColor Yellow }
        "Summary" { Write-Host $Line -ForegroundColor Cyan   }
        default   { Write-Host $Line }
    }
}

function Write-LogLineToFile {
    param([string]$FilePath, [string]$Line)
    if ([string]::IsNullOrEmpty($FilePath)) { return }
    Invoke-MutexGuardedWrite {
        try {
            [System.IO.File]::AppendAllText($FilePath, $Line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
        } catch {
            # Never fatal - losing a log line must not take the run down
            # (see Docs/function-notes.md). Warned once per file per run.
            Write-LogWriteFailureWarning -FilePath $FilePath -ErrorText ([string]$_)
        }
    }
}

function Write-LogWriteFailureWarning {
    param([string]$FilePath, [string]$ErrorText)
    try {
        if ($null -eq $script:logWriteFailureWarned) {
            $script:logWriteFailureWarned = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
        if (-not $script:logWriteFailureWarned.Add([string]$FilePath)) { return }
        # Straight to the console, not through Write-Log - this IS Write-Log's own write path.
        $warnLine = Format-LogLine -Message ("Could not write to the log file '" + $FilePath + "' - it may be locked (an open editor, cloud sync, antivirus). Lines that can't be written are skipped and the run carries on; this warning shows once per run. " + $ErrorText) -Level "Warn"
        Write-LogLineToHost -Line $warnLine -Level "Warn"
    } catch { }   # a failed warning must not fail the run either
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info", "Warn", "Error", "Summary")][string]$Level = "Info",
        [switch]$ForceConsole
    )

    $workerQueue = Get-WorkerRunspaceValue -Name workerConsoleQueue
    if ($null -ne $workerQueue) {
        $workerQueue.Enqueue(@{ Message = $Message; Level = $Level; Line = (Format-LogLine -Message $Message -Level $Level); ForceConsole = [bool]$ForceConsole })
        return
    }

    $writesFile = $script:FullLogging -or $Level -eq "Error" -or $Level -eq "Warn"
    $echoes     = -not ($script:CleanConsoleOutputEnabled -and -not $ForceConsole)
    if (-not ($writesFile -or $echoes)) { return }
    $line = Format-LogLine -Message $Message -Level $Level
    if ($writesFile) { Write-LogLineToRunFiles -Line $line -Level $Level }
    if ($echoes) { Write-LogLineToHost -Line $line -Level $Level }
}

function Write-LogLineToRunFiles {
    param([string]$Line, [string]$Level)
    if ($script:FullLogging) {
        Write-LogLineToFile -FilePath $script:logFile -Line $Line
    } elseif ($Level -eq "Error") {
        Write-LogLineToFile -FilePath $script:logErrorFile -Line $Line
    } elseif ($Level -eq "Warn") {
        Write-LogLineToFile -FilePath $script:logWarnFile -Line $Line
    }
}

function Get-WorkerRunspaceValue {
    param([Parameter(Mandatory)][ValidateSet('workerConsoleQueue', 'PermanentDelete')][string]$Name)
    if ($Name -eq 'workerConsoleQueue') {
        $value = $script:workerConsoleQueue
        if ($null -eq $value) { $value = $global:workerConsoleQueue }
    } else {
        $value = $script:PermanentDelete
        if ($null -eq $value) { $value = $global:PermanentDelete }
    }
    return ,$value
}

function Write-SummaryLog {
    param([string[]]$Lines)

    if (-not $script:SummaryFileEnabled -or [string]::IsNullOrEmpty($script:logSummaryFile)) { return }

    $timestamp = Get-Date -Format "yyyy-MM-dd HHmmss"
    $block = @("", ("=== Run: " + $timestamp + " ==="))
    $block += $Lines
    $block += "=== End of run ==="
    $block += ""

    try {
        Invoke-MutexGuardedWrite {
            $existing = ""
            if (Test-Path -LiteralPath $script:logSummaryFile) {
                $existing = [System.IO.File]::ReadAllText($script:logSummaryFile)
            }
            $newContent = ($block -join "`r`n") + "`r`n" + $existing
            [System.IO.File]::WriteAllText($script:logSummaryFile, $newContent, [System.Text.Encoding]::UTF8)
        }
    } catch {
        # Same reasoning as Start-LogRun's catch - see Docs/function-notes.md.
        $warnLine = Format-LogLine -Message ("Could not write this run's summary to '" + $script:logSummaryFile + "' - it may be locked or otherwise inaccessible. The summary above was still shown; only the file copy was skipped: " + $_) -Level "Warn"
        try { Write-LogLineToHost -Line $warnLine -Level "Warn" } catch { }
    }
}

function Flush-ConsoleQueue {
    param([System.Collections.Concurrent.ConcurrentQueue[object]]$Queue)

    # Main thread only (not in Get-LoggingSharedFunctionNames). See Docs/function-notes.md.
    $item = $null
    while ($Queue.TryDequeue([ref]$item)) {
        $line = $item.Line
        if ([string]::IsNullOrEmpty($line)) { $line = Format-LogLine -Message $item.Message -Level $item.Level }
        Write-LogLineToRunFiles -Line $line -Level $item.Level

        if ($script:CleanConsoleOutputEnabled) {
            if ($item.Level -eq "Info" -and -not $item.ForceConsole) { continue }
            $ccrColor = $null
            switch ($item.Level) {
                "Error"   { $ccrColor = "Red" }
                "Warn"    { $ccrColor = "Yellow" }
                "Summary" { $ccrColor = "Cyan" }
            }
            Write-GatedConsoleMessage -Text $line -Color $ccrColor -CleanConsoleOutputEnabled $true
        } else {
            Write-LogLineToHost -Line $line -Level $item.Level
        }
    }
}

function Write-LogFileSummary {
    if ($script:FullLogging) {
        Write-Host ("`r`nLog file: " + $script:logFile) -ForegroundColor Green
    } else {
        Write-Host "`r`nLog files:" -ForegroundColor Green
        if ($script:SummaryFileEnabled -and -not [string]::IsNullOrEmpty($script:logSummaryFile)) {
            Write-Host ("  Summary  : " + $script:logSummaryFile) -ForegroundColor Green
        } else {
            Write-Host "  Summary  : (disabled)" -ForegroundColor DarkGray
        }
        # IsNullOrEmpty guards before Test-Path (2026-09-15 fix, real but
        # latent - not reachable today since Initialize-LogPaths always
        # runs before this, but every other path read in this module
        # already guards this way; this pair was the one omission) -
        # Test-Path -LiteralPath $null throws a parameter-binding error,
        # not a clean $false.
        if ((-not [string]::IsNullOrEmpty($script:logErrorFile)) -and (Test-Path -LiteralPath $script:logErrorFile)) { Write-Host ("  Errors   : " + $script:logErrorFile) -ForegroundColor Green }
        if ((-not [string]::IsNullOrEmpty($script:logWarnFile))  -and (Test-Path -LiteralPath $script:logWarnFile))  { Write-Host ("  Warnings : " + $script:logWarnFile)  -ForegroundColor Green }
    }
}

function Get-LoggingSharedFunctionNames {
    return @('Write-Log', 'Get-WorkerRunspaceValue', 'Invoke-MutexGuardedWrite', 'Format-LogLine', 'Write-LogLineToHost', 'Write-LogLineToFile', 'Write-LogLineToRunFiles', 'Write-LogWriteFailureWarning')
}
