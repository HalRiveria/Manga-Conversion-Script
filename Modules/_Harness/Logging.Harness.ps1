<#
.SYNOPSIS
    Standalone test harness for Modules\Logging.ps1.

.DESCRIPTION
    Dot-sources the real module (not a reimplementation) and exercises it
    against real temp files - not mocked I/O - so it tests actual
    behavior, not a guess at it.

.EXAMPLE
    .\Modules\_Harness\Logging.Harness.ps1
#>

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\Logging.ps1")

$script:passCount = 0
$script:failCount = 0
function Test-Assert {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Host ("  [PASS] " + $Message) -ForegroundColor Green
        $script:passCount++
    } else {
        Write-Host ("  [FAIL] " + $Message) -ForegroundColor Red
        $script:failCount++
    }
}

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("logging-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray
Write-Host ""

function Reset-LoggingState {
    $script:logMutex           = $null
    $script:workerConsoleQueue = $null
    $script:FullLogging        = $false
    $script:logFile            = $null
    $script:logSummaryFile     = $null
    $script:logErrorFile       = $null
    $script:logWarnFile        = $null
    $script:pathHash           = $null
    $script:SummaryFileEnabled = $true
}

# ==============================================================================
#  Scenario A: Initialize-LogPaths, full-logging mode
# ==============================================================================
Write-Host "=== Scenario A: Initialize-LogPaths, full-logging mode ===" -ForegroundColor Cyan
Reset-LoggingState

Initialize-LogPaths -TargetPath "C:\Fake\Manga\Path" -FullLogging $true -ScriptDir $scratchDir

Test-Assert ($script:pathHash -match '^[0-9A-F]{64}$') ("pathHash is a 64-char uppercase hex SHA-256 (got '" + $script:pathHash + "')")
Test-Assert ($null -ne $script:logFile) "logFile is set in full-logging mode"
Test-Assert ($script:logFile -like "*Conversion Log - *.log") "logFile name matches expected pattern"
Test-Assert ($script:logFile.StartsWith($scratchDir)) "logFile lives in the supplied ScriptDir"
Test-Assert ($null -eq $script:logSummaryFile -and $null -eq $script:logErrorFile -and $null -eq $script:logWarnFile) "split-log paths are null in full-logging mode"
Write-Host ""

# ==============================================================================
#  Scenario B: Initialize-LogPaths, split-log mode + stale file cleanup
# ==============================================================================
Write-Host "=== Scenario B: Initialize-LogPaths, split-log mode, stale cleanup ===" -ForegroundColor Cyan
Reset-LoggingState

# Pre-compute what the error/warn paths WILL be so we can seed stale files
# at those exact paths before calling Initialize-LogPaths.
$probeHashBytes = [System.Text.Encoding]::UTF8.GetBytes("C:\Fake\Manga\Path".ToLowerInvariant())
$probeSha256     = [System.Security.Cryptography.SHA256]::Create()
$probeHash       = ([System.BitConverter]::ToString($probeSha256.ComputeHash($probeHashBytes)) -replace "-", "")
$probeSha256.Dispose()
$probeHashShort  = $probeHash.Substring(0, 10)
$staleErrorPath  = Join-Path $scratchDir ("Conversion Log - Errors - "   + $probeHashShort + ".log")
$staleWarnPath   = Join-Path $scratchDir ("Conversion Log - Warnings - " + $probeHashShort + ".log")
"stale error content" | Out-File -FilePath $staleErrorPath -Encoding ASCII
"stale warn content"  | Out-File -FilePath $staleWarnPath  -Encoding ASCII

Initialize-LogPaths -TargetPath "C:\Fake\Manga\Path" -FullLogging $false -ScriptDir $scratchDir

Test-Assert ($null -eq $script:logFile) "logFile is null in split-log mode"
Test-Assert ($script:logSummaryFile -like "*Conversion Log - Summary - *.log") "logSummaryFile matches expected pattern"
Test-Assert ($script:logErrorFile -eq $staleErrorPath) "logErrorFile path matches the pre-computed hash-based name"
Test-Assert (-not (Test-Path -LiteralPath $staleErrorPath)) "stale error log from a previous run was deleted"
Test-Assert (-not (Test-Path -LiteralPath $staleWarnPath)) "stale warn log from a previous run was deleted"
Write-Host ""

# ==============================================================================
#  Scenario C: pathHash is deterministic per TargetPath
# ==============================================================================
Write-Host "=== Scenario C: pathHash determinism ===" -ForegroundColor Cyan
Reset-LoggingState
Initialize-LogPaths -TargetPath "C:\Same\Path" -FullLogging $true -ScriptDir $scratchDir
$hashA = $script:pathHash
Reset-LoggingState
Initialize-LogPaths -TargetPath "C:\Same\Path" -FullLogging $true -ScriptDir $scratchDir
$hashB = $script:pathHash
Reset-LoggingState
Initialize-LogPaths -TargetPath "C:\Different\Path" -FullLogging $true -ScriptDir $scratchDir
$hashC = $script:pathHash

Test-Assert ($hashA -eq $hashB) "same TargetPath produces the same pathHash"
Test-Assert ($hashA -ne $hashC) "different TargetPath produces a different pathHash"
Write-Host ""

# ==============================================================================
#  Scenario D: Write-Log, full-logging mode - writes, appends, ASCII-safes
# ==============================================================================
Write-Host "=== Scenario D: Write-Log, full-logging mode ===" -ForegroundColor Cyan
Reset-LoggingState
Initialize-LogPaths -TargetPath "C:\D\Path" -FullLogging $true -ScriptDir $scratchDir

Write-Log "first line"
Write-Log "second line" -Level Warn
Write-Log "unicode: café 日本語" -Level Error

$content = Get-Content -LiteralPath $script:logFile
Test-Assert ($content.Count -eq 3) ("all 3 Write-Log calls appended (got " + $content.Count + " lines)")
Test-Assert ($content[0] -like "*[Info]*first line*") "first line has Info level and correct message"
Test-Assert ($content[1] -like "*[Warn]*second line*") "second line has Warn level and correct message"
Test-Assert ($content[2] -notmatch 'caf.\s' -or $content[2] -match '\?') "non-ASCII characters were replaced (not passed through raw)"
Test-Assert ($content[2] -notlike "*日本語*") "non-ASCII (Japanese) characters were not written raw"
Write-Host ""

# ==============================================================================
#  Scenario E: Write-Log, split-log mode - routes by level, Info not persisted
# ==============================================================================
Write-Host "=== Scenario E: Write-Log, split-log mode ===" -ForegroundColor Cyan
Reset-LoggingState
Initialize-LogPaths -TargetPath "C:\E\Path" -FullLogging $false -ScriptDir $scratchDir

Write-Log "info line, should not persist" -Level Info
Write-Log "an error happened" -Level Error
Write-Log "a warning happened" -Level Warn
Write-Log "a summary line" -Level Summary

Test-Assert (-not (Test-Path -LiteralPath $script:logErrorFile) -or (Get-Content -LiteralPath $script:logErrorFile) -notlike "*info line*") "Info level did not leak into the error file"
# Get-Content on a single-line file returns a bare String, not a 1-element
# array - wrap in @() so indexing/Count below operate on the line, not on
# individual characters of it (the exact class of PowerShell collection-
# collapsing gotcha documented in CLAUDE.md's "Lessons learned").
$errContent = @(Get-Content -LiteralPath $script:logErrorFile)
$warnContent = @(Get-Content -LiteralPath $script:logWarnFile)
Test-Assert ($errContent.Count -eq 1 -and $errContent[0] -like "*[Error]*an error happened*") "Error level went to the error file only"
Test-Assert ($warnContent.Count -eq 1 -and $warnContent[0] -like "*[Warn]*a warning happened*") "Warn level went to the warn file only"
Test-Assert (-not (Test-Path -LiteralPath $script:logSummaryFile)) "Summary level does not write the summary file per-line (that's Write-SummaryLog's job)"
Write-Host ""

# ==============================================================================
#  Scenario F: Write-Log respects workerConsoleQueue instead of Write-Host
# ==============================================================================
Write-Host "=== Scenario F: Write-Log queues when workerConsoleQueue is set ===" -ForegroundColor Cyan
Reset-LoggingState
Initialize-LogPaths -TargetPath "C:\F\Path" -FullLogging $true -ScriptDir $scratchDir
$script:workerConsoleQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

Write-Log "queued message" -Level Warn

Test-Assert ($script:workerConsoleQueue.Count -eq 1) "message was enqueued instead of written directly to host"
$peeked = $null
$null = $script:workerConsoleQueue.TryPeek([ref]$peeked)
Test-Assert ($peeked.Message -eq "queued message" -and $peeked.Level -eq "Warn") "queued item has the correct Message/Level"
$script:workerConsoleQueue = $null
Write-Host ""

# ==============================================================================
#  Scenario G: Flush-ConsoleQueue drains in order, handles empty queue
# ==============================================================================
Write-Host "=== Scenario G: Flush-ConsoleQueue ===" -ForegroundColor Cyan
$q = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$q.Enqueue([pscustomobject]@{ Message = "one";   Level = "Info" })
$q.Enqueue([pscustomobject]@{ Message = "two";   Level = "Warn" })
$q.Enqueue([pscustomobject]@{ Message = "three"; Level = "Error" })

$flushThrew = $false
try { Flush-ConsoleQueue -Queue $q } catch { $flushThrew = $true }
Test-Assert (-not $flushThrew) "Flush-ConsoleQueue did not throw draining 3 items"
Test-Assert ($q.Count -eq 0) "queue is empty after flush"

$emptyFlushThrew = $false
try { Flush-ConsoleQueue -Queue $q } catch { $emptyFlushThrew = $true }
Test-Assert (-not $emptyFlushThrew) "Flush-ConsoleQueue on an already-empty queue does not throw"
Write-Host ""

# ==============================================================================
#  Scenario H: Write-SummaryLog prepends newest-first
# ==============================================================================
Write-Host "=== Scenario H: Write-SummaryLog prepends newest run first ===" -ForegroundColor Cyan
Reset-LoggingState
Initialize-LogPaths -TargetPath "C:\H\Path" -FullLogging $false -ScriptDir $scratchDir

Write-SummaryLog -Lines @("=== SUMMARY ===", "first run's line")
Start-Sleep -Milliseconds 1100   # ensure a distinct HHmmss timestamp between the two runs
Write-SummaryLog -Lines @("=== SUMMARY ===", "second run's line")

$summaryText = [System.IO.File]::ReadAllText($script:logSummaryFile)
$firstRunIdx  = $summaryText.IndexOf("first run's line")
$secondRunIdx = $summaryText.IndexOf("second run's line")
Test-Assert ($secondRunIdx -ge 0 -and $firstRunIdx -ge 0 -and $secondRunIdx -lt $firstRunIdx) "the second (newer) Write-SummaryLog call appears before the first in the file"
Write-Host ""

# ==============================================================================
#  Scenario H2: -DisableSummaryFile - Summary file never created, but
#  Summary lines still reach the console via Write-Log regardless.
# ==============================================================================
Write-Host "=== Scenario H2: Initialize-LogPaths -DisableSummaryFile ===" -ForegroundColor Cyan
Reset-LoggingState
Initialize-LogPaths -TargetPath "C:\H2\Path" -FullLogging $false -DisableSummaryFile $true -ScriptDir $scratchDir

Test-Assert ($script:SummaryFileEnabled -eq $false) "SummaryFileEnabled is false after -DisableSummaryFile `$true"
Test-Assert ($null -eq $script:logSummaryFile) "logSummaryFile stays null when the summary file is disabled"

$noThrow = $false
try { Write-SummaryLog -Lines @("=== SUMMARY ===", "should not be written anywhere") } catch { $noThrow = $true }
Test-Assert (-not $noThrow) "Write-SummaryLog does not throw when the summary file is disabled (clean no-op)"

$anyLogFileCreated = Get-ChildItem -Path $scratchDir -Filter "*Summary*H2*" -ErrorAction SilentlyContinue
Test-Assert ($null -eq $anyLogFileCreated -or $anyLogFileCreated.Count -eq 0) "no Summary file was created on disk for this run"

# Error/Warn files are unaffected by this toggle - still created normally.
Test-Assert ($null -ne $script:logErrorFile -and $null -ne $script:logWarnFile) "Error/Warn file paths are still set - the toggle only affects the Summary file"
Write-Host ""

# ==============================================================================
#  Scenario H3: -DisableSummaryFile is ignored when FullLogging is $true
# ==============================================================================
Write-Host "=== Scenario H3: -DisableSummaryFile ignored in full-logging mode ===" -ForegroundColor Cyan
Reset-LoggingState
Initialize-LogPaths -TargetPath "C:\H3\Path" -FullLogging $true -DisableSummaryFile $true -ScriptDir $scratchDir

Test-Assert ($script:SummaryFileEnabled -eq $true) "SummaryFileEnabled stays true in full-logging mode regardless of -DisableSummaryFile"
Write-Log "a summary line in full-logging mode" -Level Summary
$fullLogContent = Get-Content -LiteralPath $script:logFile
Test-Assert ($fullLogContent -like "*a summary line in full-logging mode*") "Summary-level lines still land in the combined log file in full-logging mode"
Write-Host ""

# ==============================================================================
#  Scenario I: Write-Log with a real Mutex does not deadlock or throw
# ==============================================================================
Write-Host "=== Scenario I: Write-Log with a real Mutex ===" -ForegroundColor Cyan
Reset-LoggingState
Initialize-LogPaths -TargetPath "C:\I\Path" -FullLogging $true -ScriptDir $scratchDir
$script:logMutex = [System.Threading.Mutex]::new($false, ("LoggingHarnessMutex_" + [guid]::NewGuid().ToString("N")))

$mutexThrew = $false
try {
    for ($i = 0; $i -lt 5; $i++) { Write-Log ("mutex-guarded line " + $i) }
} catch { $mutexThrew = $true }
Test-Assert (-not $mutexThrew) "5 sequential Write-Log calls through a real Mutex completed without throwing/deadlocking"
$script:logMutex.Dispose()
$script:logMutex = $null
Write-Host ""

# ==============================================================================
#  Scenario J: Write-Log inside a real runspace worker writes to THAT
#  runspace's own configured file, not the main thread's - the critical
#  check that $script: prefixes resolve per-runspace, not to whichever
#  runspace happened to set them first.
# ==============================================================================
Write-Host "=== Scenario J: Write-Log from inside a runspace worker ===" -ForegroundColor Cyan
Reset-LoggingState
Initialize-LogPaths -TargetPath "C:\Main\Path" -FullLogging $true -ScriptDir $scratchDir
Write-Log "main thread's own line"
$mainThreadLogFile = $script:logFile

$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
foreach ($fn in @('Write-Log')) {
    $fnDef = (Get-Item ("Function:\" + $fn)).Definition
    $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $fn, $fnDef))
}
$pool = [RunspaceFactory]::CreateRunspacePool(1, 1, $iss, $Host)
$pool.Open()

$workerLogFile = Join-Path $scratchDir "worker-own-log.log"
$worker = {
    param($LogFilePath)
    $script:FullLogging = $true
    $script:logFile     = $LogFilePath
    $script:logMutex    = $null
    Write-Log "worker's own line"
}
$ps = [PowerShell]::Create()
$ps.RunspacePool = $pool
$null = $ps.AddScript($worker)
$null = $ps.AddArgument($workerLogFile)
$handle = $ps.BeginInvoke()
$null = $ps.EndInvoke($handle)
$ps.Dispose()
$pool.Close(); $pool.Dispose()

$workerFileExists = Test-Path -LiteralPath $workerLogFile
Test-Assert $workerFileExists "the worker runspace created its OWN log file at its own configured path"
if ($workerFileExists) {
    $workerContent = Get-Content -LiteralPath $workerLogFile
    Test-Assert ($workerContent -like "*worker's own line*") "the worker's log file contains the worker's own message"
    Test-Assert ($workerContent -notlike "*main thread's own line*") "the worker's log file does NOT contain the main thread's message (no cross-contamination)"
}
$mainContent = Get-Content -LiteralPath $mainThreadLogFile
Test-Assert ($mainContent -like "*main thread's own line*") "the main thread's log file still has its own message"
Test-Assert ($mainContent -notlike "*worker's own line*") "the main thread's log file does NOT contain the worker's message"
Write-Host ""

# ==============================================================================
#  Scenario K: Write-LogFileSummary smoke test (cosmetic, just must not throw)
# ==============================================================================
Write-Host "=== Scenario K: Write-LogFileSummary ===" -ForegroundColor Cyan
Reset-LoggingState
Initialize-LogPaths -TargetPath "C:\K\Path" -FullLogging $true -ScriptDir $scratchDir
$fullThrew = $false
try { Write-LogFileSummary } catch { $fullThrew = $true }
Test-Assert (-not $fullThrew) "Write-LogFileSummary does not throw in full-logging mode"

Reset-LoggingState
Initialize-LogPaths -TargetPath "C:\K2\Path" -FullLogging $false -ScriptDir $scratchDir
$splitThrew = $false
try { Write-LogFileSummary } catch { $splitThrew = $true }
Test-Assert (-not $splitThrew) "Write-LogFileSummary does not throw in split-log mode"
Write-Host ""

# ==============================================================================
#  Summary
# ==============================================================================
Write-Host "==============================================="
if ($script:failCount -eq 0) {
    Write-Host ("ALL PASSED  (" + $script:passCount + " assertions)") -ForegroundColor Green
} else {
    Write-Host ($script:failCount.ToString() + " FAILED, " + $script:passCount + " passed") -ForegroundColor Red
}
Write-Host "==============================================="

try { Remove-Item -LiteralPath $scratchDir -Recurse -Force } catch { }

if ($script:failCount -gt 0) { exit 1 } else { exit 0 }
