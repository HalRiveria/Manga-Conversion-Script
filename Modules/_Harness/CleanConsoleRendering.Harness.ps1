<#
.SYNOPSIS
    Standalone test harness for Modules\CleanConsoleRendering.ps1.

.DESCRIPTION
    Dot-sources the real module - no forward references, no stubs needed
    (CCR is fully standalone, like DependencyDetection.ps1).

    WHAT THIS HARNESS CAN AND CANNOT VERIFY: this execution environment
    has no real attached console - confirmed live that
    [Console]::CursorTop/SetCursorPosition throws
    System.IO.IOException ("The handle is invalid") here. That means:
      - Test-CleanConsoleCursorAvailable is verified to correctly detect
        this and return $false, and every scenario below therefore
        exercises the FALLBACK (simple sequential Write-Host, no erase)
        rendering path for real - not simulated.
      - The actual cursor-erase-and-redraw mechanics (the real "clean" in
        Clean Console Output) are NOT exercised here - there is no
        automated way to verify that in this environment. What IS
        verified: the CONTENT that would be drawn is correct
        (Get-ProgressBarString/Split-TextToWidth/Format-SeriesLines are
        pure functions, fully testable without a console), and that the
        cursor code path is wrapped safely enough to never crash a run
        when cursor control isn't available (proven by every scenario
        below completing without an uncaught exception, despite hitting
        that exact failure mode every time). A real interactive terminal
        run is still needed to eyeball the actual in-place redraw
        visually - that is explicitly not something this harness claims
        to cover.
    Write-Host output is captured via the Information stream (6>&1,
    available since PS5) for content assertions - verified live that this
    works before relying on it.

.EXAMPLE
    .\Modules\_Harness\CleanConsoleRendering.Harness.ps1
#>

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\CleanConsoleRendering.ps1")

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

function Reset-CCRState {
    $script:ccrActiveSeries        = [System.Collections.Specialized.OrderedDictionary]::new()
    $script:ccrLiveRegionLineCount = 0
    $script:ccrCursorAvailable     = $null
}

# ==============================================================================
#  Scenario A: Test-CleanConsoleCursorAvailable correctly detects and
#  caches non-interactive/no-console context.
# ==============================================================================
Write-Host "=== Scenario A: Test-CleanConsoleCursorAvailable ===" -ForegroundColor Cyan
Reset-CCRState
$avail1 = Test-CleanConsoleCursorAvailable
$avail2 = Test-CleanConsoleCursorAvailable
Test-Assert ($avail1 -eq $false) "correctly detects no real console is available in this environment"
Test-Assert ($avail2 -eq $false) "second call returns the same (cached) result"
Write-Host ""

# ==============================================================================
#  Scenario B: Get-ProgressBarString
# ==============================================================================
Write-Host "=== Scenario B: Get-ProgressBarString ===" -ForegroundColor Cyan
Test-Assert ((Get-ProgressBarString -Completed 0 -Total 8 -Width 8) -eq "[--------]") "0/8 is fully empty"
Test-Assert ((Get-ProgressBarString -Completed 8 -Total 8 -Width 8) -eq "[########]") "8/8 is fully filled"
Test-Assert ((Get-ProgressBarString -Completed 4 -Total 8 -Width 8) -eq "[####----]") "4/8 is half filled"
Test-Assert ((Get-ProgressBarString -Completed 0 -Total 0 -Width 8) -eq "[########]") "0/0 (degenerate) renders as fully filled, not divide-by-zero"
Write-Host ""

# ==============================================================================
#  Scenario C: Split-TextToWidth
# ==============================================================================
Write-Host "=== Scenario C: Split-TextToWidth ===" -ForegroundColor Cyan
$shortSplit = @(Split-TextToWidth -Text "hello" -Width 10)
Test-Assert ($shortSplit.Count -eq 1 -and $shortSplit[0] -eq "hello") "text shorter than width returns a single unmodified chunk"

$exactSplit = @(Split-TextToWidth -Text "0123456789" -Width 10)
Test-Assert ($exactSplit.Count -eq 1 -and $exactSplit[0] -eq "0123456789") "text exactly matching width returns a single chunk"

$longSplit = @(Split-TextToWidth -Text "0123456789ABCDE" -Width 10)
Test-Assert ($longSplit.Count -eq 2 -and $longSplit[0] -eq "0123456789" -and $longSplit[1] -eq "ABCDE") "long text (a very long series name) splits into correctly-sized chunks, last one shorter"

$emptySplit = @(Split-TextToWidth -Text "" -Width 10)
Test-Assert ($emptySplit.Count -eq 1 -and $emptySplit[0] -eq "") "empty text returns one empty chunk, not zero chunks"
Write-Host ""

# ==============================================================================
#  Scenario D: Format-SeriesLines
# ==============================================================================
Write-Host "=== Scenario D: Format-SeriesLines ===" -ForegroundColor Cyan
$entryD1 = @{ TotalChapters = 8; SuccessCount = 3; ActiveChapters = [System.Collections.Generic.List[string]]::new(); IssueChapters = [System.Collections.Generic.List[hashtable]]::new() }
$entryD1.ActiveChapters.Add("Chapter 4")
$entryD1.ActiveChapters.Add("Chapter 5")
$linesD1 = @(Format-SeriesLines -SeriesName "Only Images" -Entry $entryD1)
Test-Assert ($linesD1[0] -eq "Only Images") "first line is the series name"
Test-Assert ($linesD1[1] -like "*3/8 chapters*") "second line shows SuccessCount/TotalChapters"
Test-Assert (($linesD1 | Where-Object { $_ -like "*Chapter 4*in progress*" }).Count -eq 1) "active chapter 4 is listed as in progress"
Test-Assert (($linesD1 | Where-Object { $_ -like "*Chapter 5*in progress*" }).Count -eq 1) "active chapter 5 is listed as in progress"

$entryD2 = @{ TotalChapters = 8; SuccessCount = 6; ActiveChapters = [System.Collections.Generic.List[string]]::new(); IssueChapters = [System.Collections.Generic.List[hashtable]]::new() }
$entryD2.IssueChapters.Add(@{ ChapterName = "Chapter 3"; Status = "Warning"; Detail = "2 files skipped" })
$entryD2.IssueChapters.Add(@{ ChapterName = "Chapter 7"; Status = "Error"; Detail = "1 file failed" })
$linesD2 = @(Format-SeriesLines -SeriesName "Only Images" -Entry $entryD2)
Test-Assert ($linesD2[1] -like "*6/8 chapters*") "bar numerator is SuccessCount (6), NOT resolved-count (8) - issues don't count toward it"
Test-Assert (($linesD2 | Where-Object { $_ -eq "    Chapter 3 - Warning: 2 files skipped" }).Count -eq 1) "warning chapter persists with its detail text"
Test-Assert (($linesD2 | Where-Object { $_ -eq "    Chapter 7 - Error: 1 file failed" }).Count -eq 1) "error chapter persists with its detail text"
Test-Assert ($linesD2.Count -eq 4) "no active-chapter lines when ActiveChapters is empty (this is what a FROZEN series' lines look like too - same function, no separate frozen formatter needed)"
Write-Host ""

# ==============================================================================
#  Scenario E: Start-SeriesProgress
# ==============================================================================
Write-Host "=== Scenario E: Start-SeriesProgress ===" -ForegroundColor Cyan
Reset-CCRState
Start-SeriesProgress -SeriesName "Only Images" -TotalChapters 8
Test-Assert ($script:ccrActiveSeries.Contains("Only Images")) "series is registered as active"
Test-Assert ($script:ccrActiveSeries["Only Images"].TotalChapters -eq 8) "TotalChapters recorded correctly"

$threwDuplicateE = $false
try { Start-SeriesProgress -SeriesName "Only Images" -TotalChapters 3 } catch { $threwDuplicateE = $true }
Test-Assert $threwDuplicateE "starting the same series name twice throws"

Reset-CCRState
$outputE2 = & { Start-SeriesProgress -SeriesName "Empty Series" -TotalChapters 0 } 6>&1
Test-Assert (-not $script:ccrActiveSeries.Contains("Empty Series")) "a 0-chapter series never enters the active registry"
Test-Assert (($outputE2 | Where-Object { $_.ToString() -like "*0/0 chapters*" }).Count -eq 1) "a 0-chapter series is still immediately rendered as a frozen 0/0 line"
Write-Host ""

# ==============================================================================
#  Scenario F: Start-ChapterProgress
# ==============================================================================
Write-Host "=== Scenario F: Start-ChapterProgress ===" -ForegroundColor Cyan
Reset-CCRState
Start-SeriesProgress -SeriesName "Only Images" -TotalChapters 3
Start-ChapterProgress -SeriesName "Only Images" -ChapterName "Chapter 1"
Test-Assert ($script:ccrActiveSeries["Only Images"].ActiveChapters -contains "Chapter 1") "chapter is tracked as active"

$threwUnknownSeriesF = $false
try { Start-ChapterProgress -SeriesName "Nonexistent Series" -ChapterName "X" } catch { $threwUnknownSeriesF = $true }
Test-Assert $threwUnknownSeriesF "starting a chapter for an unknown series throws"
Write-Host ""

# ==============================================================================
#  Scenario G: Complete-ChapterProgress - Success clears, Warning/Error persist
# ==============================================================================
Write-Host "=== Scenario G: Complete-ChapterProgress status handling ===" -ForegroundColor Cyan
Reset-CCRState
Start-SeriesProgress -SeriesName "Only Images" -TotalChapters 3
Start-ChapterProgress -SeriesName "Only Images" -ChapterName "Chapter 1"
$resultG1 = Complete-ChapterProgress -SeriesName "Only Images" -ChapterName "Chapter 1" -Status Success
Test-Assert (-not ($script:ccrActiveSeries["Only Images"].ActiveChapters -contains "Chapter 1")) "successful chapter is removed from active list"
Test-Assert ($script:ccrActiveSeries["Only Images"].IssueChapters.Count -eq 0) "successful chapter does NOT appear in the persistent issues list"
Test-Assert ($script:ccrActiveSeries["Only Images"].SuccessCount -eq 1) "SuccessCount incremented"
Test-Assert ($resultG1.SeriesCompleted -eq $false) "series is not yet completed (2 more chapters pending)"

Start-ChapterProgress -SeriesName "Only Images" -ChapterName "Chapter 2"
$null = Complete-ChapterProgress -SeriesName "Only Images" -ChapterName "Chapter 2" -Status Warning -Detail "2 files skipped"
Test-Assert ($script:ccrActiveSeries["Only Images"].SuccessCount -eq 1) "SuccessCount NOT incremented for a Warning chapter"
Test-Assert ($script:ccrActiveSeries["Only Images"].IssueChapters.Count -eq 1) "warning chapter added to the persistent issues list"
Test-Assert ($script:ccrActiveSeries["Only Images"].IssueChapters[0].Detail -eq "2 files skipped") "detail text preserved"

$threwUnknownChapterG = $false
try { Complete-ChapterProgress -SeriesName "Only Images" -ChapterName "Never Started" -Status Success } catch { $threwUnknownChapterG = $true }
Test-Assert $threwUnknownChapterG "completing a chapter that was never started throws"
Write-Host ""

# ==============================================================================
#  Scenario H: full lifecycle - series resolves (nothing left running) while
#  its bar stays short of full because of issue chapters; series is removed
#  from the active registry and its final content is printed as permanent
#  (frozen) output.
# ==============================================================================
Write-Host "=== Scenario H: full series lifecycle with mixed outcomes ===" -ForegroundColor Cyan
Reset-CCRState
Start-SeriesProgress -SeriesName "Only Images" -TotalChapters 3
Start-ChapterProgress -SeriesName "Only Images" -ChapterName "Chapter 1"
Start-ChapterProgress -SeriesName "Only Images" -ChapterName "Chapter 2"
Start-ChapterProgress -SeriesName "Only Images" -ChapterName "Chapter 3"
$null = Complete-ChapterProgress -SeriesName "Only Images" -ChapterName "Chapter 1" -Status Success
$null = Complete-ChapterProgress -SeriesName "Only Images" -ChapterName "Chapter 2" -Status Warning -Detail "2 files skipped"
$script:resultH = $null
$outputH = & { $script:resultH = Complete-ChapterProgress -SeriesName "Only Images" -ChapterName "Chapter 3" -Status Error -Detail "1 file failed" } 6>&1

Test-Assert ($script:resultH.SeriesCompleted -eq $true) "the third and final chapter's completion correctly reports SeriesCompleted = `$true"
Test-Assert (-not $script:ccrActiveSeries.Contains("Only Images")) "series is removed from the active registry once fully resolved"
$outputTextH = ($outputH | ForEach-Object { $_.ToString() }) -join "`n"
Test-Assert ($outputTextH -like "*1/3 chapters*") "final frozen output shows bar numerator 1/3 (only the 1 clean success counts, not the warning/error)"
Test-Assert ($outputTextH -like "*Chapter 2 - Warning: 2 files skipped*") "warning chapter persists in the final frozen output"
Test-Assert ($outputTextH -like "*Chapter 3 - Error: 1 file failed*") "error chapter persists in the final frozen output"
Write-Host ""

# ==============================================================================
#  Scenario I: multiple concurrent series both appear in rendered output.
# ==============================================================================
Write-Host "=== Scenario I: multiple concurrent series ===" -ForegroundColor Cyan
Reset-CCRState
Start-SeriesProgress -SeriesName "Series A" -TotalChapters 2
Start-SeriesProgress -SeriesName "Series B" -TotalChapters 2
Start-ChapterProgress -SeriesName "Series A" -ChapterName "A-Chapter 1"
$outputI = & { Start-ChapterProgress -SeriesName "Series B" -ChapterName "B-Chapter 1" } 6>&1
$outputTextI = ($outputI | ForEach-Object { $_.ToString() }) -join "`n"

Test-Assert ($script:ccrActiveSeries.Contains("Series A") -and $script:ccrActiveSeries.Contains("Series B")) "both series remain tracked as active simultaneously"
Test-Assert ($outputTextI -like "*Series A*" -and $outputTextI -like "*Series B*") "both series' blocks appear together in the same redraw"
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
