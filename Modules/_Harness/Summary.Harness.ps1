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
    param([string]$Message, [string]$Level = "Info")
    $script:writeLogCalls.Add(@{ Message = $Message; Level = $Level })
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
    return @{ RunImageConversion = $false; RunAnimatedConversion = $false; RunZip = $false; RunZipOnly = $false; RunConvertZipped = $false }
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
Write-Host ""

# ==============================================================================
#  Scenario B: Format-ElapsedTime
# ==============================================================================
Write-Host "=== Scenario B: Format-ElapsedTime ===" -ForegroundColor Cyan
Test-Assert ((Format-ElapsedTime -Elapsed ([timespan]::new(1, 2, 3))) -eq "01h 02m 03s") "1h2m3s formats zero-padded"
Test-Assert ((Format-ElapsedTime -Elapsed ([timespan]::new(0, 0, 0))) -eq "00h 00m 00s") "zero elapsed formats as all zeros"
Test-Assert ((Format-ElapsedTime -Elapsed ([timespan]::new(25, 5, 9))) -eq "01h 05m 09s") "a >24h TimeSpan uses .Hours (25h wraps to 1 day + 1h), matching the reference's exact behavior, not total hours"
Write-Host ""

# ==============================================================================
#  Scenario C: Get-SummaryLines - RunConvertZipped shows only the
#  ZIP-pipeline rows
# ==============================================================================
Write-Host "=== Scenario C: Get-SummaryLines, RunConvertZipped only ===" -ForegroundColor Cyan
$statsC = New-StatsTracker
$statsC.ZipExtracted.Success = 5
$flagsC = Get-AllModeFlagsFalse
$flagsC.RunConvertZipped = $true
$linesC = Get-SummaryLines -Stats $statsC -ElapsedString "00h 01m 00s" -ModeFlags $flagsC
$blobC = $linesC -join "`n"
Test-Assert ($blobC -match "ZIPs Extracted") "shows the ZIP-pipeline rows when RunConvertZipped is true"
Test-Assert ($blobC -match "Success = 5") "the actual stat value appears in the line"
Test-Assert ($blobC -notmatch "Loose Img Conv\.") "does not show loose-image rows when RunConvertZipped is the only flag set"
Test-Assert ($blobC -notmatch "Zip-only") "does not show zip-only rows"
Test-Assert ($linesC[0] -eq "=== SUMMARY ===" -and $linesC[-1] -eq "=== Processing complete ===") "starts/ends with the standard header/footer"
Write-Host ""

# ==============================================================================
#  Scenario D: Get-SummaryLines - Full Pipeline's flags (image + animated
#  + zip) show exactly those three groups, nothing else
# ==============================================================================
Write-Host "=== Scenario D: Get-SummaryLines, Full Pipeline flags ===" -ForegroundColor Cyan
$statsD = New-StatsTracker
$flagsD = @{ RunImageConversion = $true; RunAnimatedConversion = $true; RunZip = $true; RunZipOnly = $false; RunConvertZipped = $false }
$blobD = (Get-SummaryLines -Stats $statsD -ElapsedString "00h 00m 05s" -ModeFlags $flagsD) -join "`n"
Test-Assert ($blobD -match "Loose Img Conv\.") "shows loose image conversion rows"
Test-Assert ($blobD -match "Loose Anim\. Conv\.") "shows loose animated conversion rows"
Test-Assert ($blobD -match "Loose Folders Zipped") "shows the zip-after-conversion rows"
Test-Assert ($blobD -notmatch "ZIPs Extracted") "does not show the (unrelated) rezip/ZIP-pipeline rows"
Test-Assert ($blobD -notmatch "Zip-only") "does not show the (unrelated) zip-only rows"
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
Test-Assert ($blobE -notmatch "Loose") "shows nothing from any loose-pipeline group"
Test-Assert ($blobE -notmatch "ZIPs Extracted") "shows nothing from the rezip/ZIP-pipeline group"
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
