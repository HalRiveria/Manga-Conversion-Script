# See Docs/module-descriptions.md for this module's full description.

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

function Initialize-CleanConsoleOutput {
    param([Parameter(Mandatory)][bool]$Enabled)
    $script:CleanConsoleOutputEnabled = $Enabled
}

function Invoke-MutexGuardedWrite {
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
    Invoke-MutexGuardedWrite { [System.IO.File]::AppendAllText($FilePath, $Line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8) }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info", "Warn", "Error", "Summary")][string]$Level = "Info",
        [switch]$ForceConsole
    )

    $line = Format-LogLine -Message $Message -Level $Level

    if ($script:FullLogging) {
        Write-LogLineToFile -FilePath $script:logFile -Line $line
    } else {
        if ($Level -eq "Error") {
            Write-LogLineToFile -FilePath $script:logErrorFile -Line $line
        } elseif ($Level -eq "Warn") {
            Write-LogLineToFile -FilePath $script:logWarnFile -Line $line
        }
    }

    if ($script:CleanConsoleOutputEnabled -and -not $ForceConsole) { return }

    if ($null -ne $script:workerConsoleQueue) {
        $script:workerConsoleQueue.Enqueue([pscustomobject]@{ Message = $Message; Level = $Level })
    } else {
        Write-LogLineToHost -Line $line -Level $Level
    }
}

function Write-SummaryLog {
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
    param([System.Collections.Concurrent.ConcurrentQueue[object]]$Queue)

    $item = $null
    while ($Queue.TryDequeue([ref]$item)) {
        $line = Format-LogLine -Message $item.Message -Level $item.Level
        Write-LogLineToHost -Line $line -Level $item.Level
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
        if (Test-Path -LiteralPath $script:logErrorFile) { Write-Host ("  Errors   : " + $script:logErrorFile) -ForegroundColor Green }
        if (Test-Path -LiteralPath $script:logWarnFile)  { Write-Host ("  Warnings : " + $script:logWarnFile)  -ForegroundColor Green }
    }
}

function Get-LoggingSharedFunctionNames {
    return @('Write-Log', 'Invoke-MutexGuardedWrite', 'Format-LogLine', 'Write-LogLineToHost', 'Write-LogLineToFile')
}
