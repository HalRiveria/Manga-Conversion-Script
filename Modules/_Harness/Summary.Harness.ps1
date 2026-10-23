<#
.SYNOPSIS
    Standalone test harness for Modules\Summary.ps1.

.DESCRIPTION
    Dot-sources the real module and stubs Write-Log/Write-SummaryLog with
    call tracking (same pattern as AbortPipeline.Harness.ps1) - this
    module doesn't need the real Logging.ps1 built/working to be tested.

.EXAMPLE
    .\Modules\_Harness\Summary.Harness.ps1
#>

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\Summary.ps1")

$script:writeLogCalls = New-Object System.Collections.Generic.List[object]
function Write-Log {
    # -ForceConsole tracked explicitly (2026-09-15 fix regression coverage) -
    # a fake without this parameter declared doesn't throw when called with
    # -ForceConsole (verified live: PowerShell silently accepts it as if it
    # were positional/ignored on a non-CmdletBinding function), so a fake
    # missing the parameter can't catch a caller failing to pass it either -
    # it has to actually capture the value to be a meaningful test.
    param([string]$Message, [string]$Level = "Info", [switch]$ForceConsole)
    $script:writeLogCalls.Add(@{ Message = $Message; Level = $Level; ForceConsole = [bool]$ForceConsole })
}

$script:summaryLogCalls = New-Object System.Collections.Generic.List[string[]]
function Write-SummaryLog {
    param([string[]]$Lines)
    $script:summaryLogCalls.Add($Lines)
}

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

function Get-AllModeFlagsFalse {
    return @{ RunImageConversion = $false; RunAnimatedConversion = $false; RunZip = $false; RunZipOnly = $false }
}

Write-Host ""

# ==============================================================================
#  Scenario A: New-StatsTracker returns a fresh, independent copy each
#  call, including its nested Success/Fail/Skipped hashtables
# ==============================================================================
Write-Host "=== Scenario A: New-StatsTracker returns independent copies ===" -ForegroundColor Cyan
$statsA1 = New-StatsTracker
$statsA2 = New-StatsTracker
$statsA1.LooseImgConverted.Success = 999
Test-Assert ($statsA2.LooseImgConverted.Success -eq 0) "mutating one tracker's nested counter does not affect a second call's result"
Test-Assert (
    $statsA2.ContainsKey('LooseAnimatedConverted') -and $statsA2.ContainsKey('LooseAnimatedDeleted')
) "schema includes the new LooseAnimatedConverted/LooseAnimatedDeleted groups"
Test-Assert ($statsA2.ContainsKey('InspectFailed') -and $statsA2.InspectFailed.Count -eq 0) "schema includes InspectFailed (2026-08-28), defaulting to 0"
Test-Assert ($statsA2.ContainsKey('Aborted') -and $statsA2.Aborted -eq $false) "schema includes Aborted (2026-09-03), defaulting to `$false"
Test-Assert ($statsA2.ContainsKey('ForceKilledCount') -and $statsA2.ForceKilledCount -eq 0) "schema includes ForceKilledCount (2026-09-03), defaulting to 0"
Write-Host ""

# ==============================================================================
#  Scenario B: Format-ElapsedTime
# ==============================================================================
Write-Host "=== Scenario B: Format-ElapsedTime ===" -ForegroundColor Cyan
Test-Assert ((Format-ElapsedTime -Elapsed ([timespan]::new(1, 2, 3))) -eq "01h 02m 03s") "1h2m3s formats zero-padded"
Test-Assert ((Format-ElapsedTime -Elapsed ([timespan]::new(0, 0, 0))) -eq "00h 00m 00s") "zero elapsed formats as all zeros"
Test-Assert ((Format-ElapsedTime -Elapsed ([timespan]::new(25, 5, 9))) -eq "25h 05m 09s") "a run longer than a day shows its total hours (25h), not a wrapped 01h"
Test-Assert ((Format-ElapsedTime -Elapsed ([timespan]::new(0, 59, 59) + [timespan]::FromMilliseconds(900))) -eq "00h 59m 59s") "a fraction of a second below the hour doesn't round up to the next hour"
Write-Host ""

# ==============================================================================
#  Scenario D: Get-SummaryLines - Full Pipeline's flags (image + animated
#  + zip) show exactly those three groups, nothing else
# ==============================================================================
Write-Host "=== Scenario D: Get-SummaryLines, Full Pipeline flags ===" -ForegroundColor Cyan
$statsD = New-StatsTracker
$statsD.InspectFailed.Count = 3
$flagsD = @{ RunImageConversion = $true; RunAnimatedConversion = $true; RunZip = $true; RunZipOnly = $false }
$blobD = (Get-SummaryLines -Stats $statsD -ElapsedString "00h 00m 05s" -ModeFlags $flagsD) -join "`n"
Test-Assert ($blobD -match "Loose Img Conv\.") "shows loose image conversion rows"
Test-Assert ($blobD -match "Loose Anim\. Conv\.") "shows loose animated conversion rows"
Test-Assert ($blobD -match "Loose Folders Zipped") "shows the zip-after-conversion rows"
Test-Assert ($blobD -notmatch "ZIPs Extracted") "does not show the (unrelated) rezip/ZIP-pipeline rows"
Test-Assert ($blobD -notmatch "Zip-only") "does not show the (unrelated) zip-only rows"
Test-Assert ($blobD -match "Inspect Failed\s*: 3 file\(s\)") "shows Inspect Failed with the real count (2026-08-28)"
Write-Host ""

# ==============================================================================
#  Scenario D2: Inspect Failed shows when ONLY RunAnimatedConversion is set
#  (not RunImageConversion) - proves the shared row is on an -or, not -and,
#  since either engine can hit this failure mode independently.
# ==============================================================================
Write-Host "=== Scenario D2: Inspect Failed shows for RunAnimatedConversion alone ===" -ForegroundColor Cyan
$statsD2 = New-StatsTracker
$statsD2.InspectFailed.Count = 1
$flagsD2 = Get-AllModeFlagsFalse
$flagsD2.RunAnimatedConversion = $true
$blobD2 = (Get-SummaryLines -Stats $statsD2 -ElapsedString "00h 00m 01s" -ModeFlags $flagsD2) -join "`n"
Test-Assert ($blobD2 -match "Inspect Failed\s*: 1 file\(s\)") "Inspect Failed shows with RunAnimatedConversion alone, RunImageConversion false"
Write-Host ""

# ==============================================================================
#  Scenario E: Get-SummaryLines - RunZipOnly shows only zip-only rows
# ==============================================================================
Write-Host "=== Scenario E: Get-SummaryLines, RunZipOnly only ===" -ForegroundColor Cyan
$statsE = New-StatsTracker
$flagsE = Get-AllModeFlagsFalse
$flagsE.RunZipOnly = $true
$blobE = (Get-SummaryLines -Stats $statsE -ElapsedString "00h 00m 01s" -ModeFlags $flagsE) -join "`n"
Test-Assert ($blobE -match "Zip-only Zipped") "shows zip-only rows"
$statsE.ZipOnlyZipped.Skipped = 2
$blobE2 = (Get-SummaryLines -Stats $statsE -ElapsedString "00h 00m 01s" -ModeFlags $flagsE) -join "`n"
Test-Assert ($blobE2 -match "Skipped \(animated originals kept\) = 2") "the zip-only row shows folders skipped for an .avif/.webp pair"
Test-Assert ($blobE -notmatch "Loose") "shows nothing from any loose-pipeline group"
Test-Assert ($blobE -notmatch "ZIPs Extracted") "shows nothing from the rezip/ZIP-pipeline group"
Test-Assert ($blobE -notmatch "Inspect Failed") "does not show Inspect Failed - RunZipOnly alone doesn't touch either conversion engine"
Write-Host ""

# ==============================================================================
#  Scenario F: Get-SummaryLines - every flag false still returns a valid
#  (if minimal) report: header, elapsed time, footer, no group rows
# ==============================================================================
Write-Host "=== Scenario F: Get-SummaryLines, all flags false ===" -ForegroundColor Cyan
$statsF = New-StatsTracker
$linesF = Get-SummaryLines -Stats $statsF -ElapsedString "00h 00m 00s" -ModeFlags (Get-AllModeFlagsFalse)
Test-Assert ($linesF.Count -eq 3) "exactly 3 lines with no group rows: header, time taken, footer"
Test-Assert ($linesF -contains "=== SUMMARY ===") "still has the header"
Test-Assert (($linesF -join "`n") -match "Time taken\s+: 00h 00m 00s") "still reports elapsed time"
Test-Assert ($linesF -contains "=== Processing complete ===") "still has the footer"
Test-Assert (($linesF -join "`n") -notmatch "ABORTED") "a normal (non-aborted) run's footer says nothing about being aborted"
Write-Host ""

# ==============================================================================
#  Scenario F2 (2026-09-03 fix, Todo.md finding): an aborted run's summary
#  used to end with the exact same "Processing complete" footer as a
#  normal finish - Stats.Aborted/Stats.ForceKilledCount (already tracked
#  by every pipeline with an abort loop, per Controller.ps1's own
#  $totals) now actually reach Get-SummaryLines' output.
# ==============================================================================
Write-Host "=== Scenario F2: Get-SummaryLines reflects an aborted run, not 'Processing complete' ===" -ForegroundColor Cyan
$statsF2 = New-StatsTracker
$statsF2.Aborted = $true
$statsF2.ForceKilledCount = 3
$linesF2 = Get-SummaryLines -Stats $statsF2 -ElapsedString "00h 00m 05s" -ModeFlags (Get-AllModeFlagsFalse)
$blobF2 = $linesF2 -join "`n"
Test-Assert ($linesF2 -notcontains "=== Processing complete ===") "the normal 'Processing complete' footer is NOT used for an aborted run"
Test-Assert ($linesF2 -contains "=== Processing ABORTED ===") "the footer clearly marks the run as aborted"
Test-Assert ($blobF2 -match "ABORTED") "the report visibly mentions the abort somewhere"
Test-Assert ($blobF2 -match "3") "the force-killed count (3) is reported"

$statsF2b = New-StatsTracker
$linesF2b = Get-SummaryLines -Stats $statsF2b -ElapsedString "00h 00m 05s" -ModeFlags (Get-AllModeFlagsFalse)
Test-Assert ($linesF2b -contains "=== Processing complete ===") "sanity check: Stats.Aborted = `$false (the default) still gets the normal footer"
Write-Host ""

# ==============================================================================
#  Scenario G: Write-SummaryReport - full-logging mode does NOT call
#  Write-SummaryLog (Write-Log already wrote every line to the one
#  combined file in that mode); non-full-logging mode DOES
# ==============================================================================
Write-Host "=== Scenario G: Write-SummaryReport dispatch by -FullLogging ===" -ForegroundColor Cyan
$reportLinesG = @("=== SUMMARY ===", "Time taken          : 00h 00m 01s", "=== Processing complete ===")

$script:writeLogCalls.Clear()
$script:summaryLogCalls.Clear()
Write-SummaryReport -Lines $reportLinesG -FullLogging $true
Test-Assert ($script:writeLogCalls.Count -eq $reportLinesG.Count) "Write-Log was called once per line"
Test-Assert (@($script:writeLogCalls | Where-Object { $_.Level -ne 'Summary' }).Count -eq 0) "every Write-Log call used -Level Summary"
Test-Assert ($script:summaryLogCalls.Count -eq 0) "Write-SummaryLog was NOT called in full-logging mode"
# 2026-09-15 fix (real bug): without -ForceConsole, Write-Log suppresses
# console output whenever Clean Console Output is enabled, and nothing
# turns CCO off before the summary is written - so the whole summary
# (every line) silently vanished from the console with CCO on.
Test-Assert (@($script:writeLogCalls | Where-Object { -not $_.ForceConsole }).Count -eq 0) "every Write-Log call passed -ForceConsole (so the summary still shows even with Clean Console Output enabled)"

$script:writeLogCalls.Clear()
$script:summaryLogCalls.Clear()
Write-SummaryReport -Lines $reportLinesG -FullLogging $false
Test-Assert ($script:writeLogCalls.Count -eq $reportLinesG.Count) "Write-Log was still called once per line in non-full-logging mode"
Test-Assert ($script:summaryLogCalls.Count -eq 1) "Write-SummaryLog WAS called exactly once in non-full-logging mode"
Test-Assert (($script:summaryLogCalls[0] -join "`n") -eq ($reportLinesG -join "`n")) "the exact same lines were passed through to Write-SummaryLog"
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

if ($script:failCount -gt 0) { exit 1 } else { exit 0 }
