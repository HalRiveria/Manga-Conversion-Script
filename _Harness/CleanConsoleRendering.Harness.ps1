<#
.SYNOPSIS
    Standalone test harness for Modules\CleanConsoleRendering.ps1.

.DESCRIPTION
    Dot-sources the real module - no forward references, no stubs needed
    (CCR is fully standalone, like DependencyDetection.ps1).

    WHAT THIS HARNESS CAN AND CANNOT VERIFY: this execution environment
    has no real attached console - [Console]::CursorTop/SetCursorPosition throws
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
    available since PS5) for content assertions. A captured
    InformationRecord's .MessageData carries the actual -ForegroundColor
    value used (a real System.Management.Automation.HostInformationMessage
    object, not just the text) - used in Scenario K to prove color is
    genuinely applied through a real redraw, not just correct in the
    content-generation functions considered alone.

.EXAMPLE
    .\_Harness\CleanConsoleRendering.Harness.ps1
#>

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\Modules\CleanConsoleRendering.ps1")

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
    $script:ccrLastDrawWidth       = $null
    $script:ccrMaxLiveRows         = $null
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
# Math.Round(19.8) rounds UP to 20, so a
# 39/40 bar (ratio 0.975, at width 20 that's 19.5) would show as
# COMPLETELY FULL - defeating the documented "a bar short of full means
# something's still not done" signal, including for a chapter that then
# goes on to fail. Floor keeps it honestly short of full until the last
# chapter truly finishes.
Test-Assert ((Get-ProgressBarString -Completed 39 -Total 40 -Width 20) -eq ("[" + ("#" * 19) + "-" + "]")) "39/40 at width 20 is NOT fully filled (Floor, not Round) - 19 filled, 1 dash short of full"
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
#  Scenario C2: Get-DisplayWidth/
#  Set-PadToDisplayWidth/Split-TextToWidth all treat a CJK character as 2
#  console columns, not 1 - $Text.Length (a .NET UTF-16 code-unit count)
#  must not be treated as a column count, or a chunk that fit within
#  $Width CHARACTERS could still be wider than $Width COLUMNS on screen,
#  triggering the terminal's own automatic wrap and desyncing this
#  module's row-count math for every row after it. This can't be verified
#  against a REAL console from a harness (no live terminal in tests) -
#  these scenarios cover the
#  underlying width/chunking/padding MATH directly instead, which is
#  exactly what the desync traced back to.
# ==============================================================================
Write-Host "=== Scenario C2: CJK-aware display width, chunking, and padding ===" -ForegroundColor Cyan
# Built from explicit Unicode code points, not literal CJK characters in
# the source - a PS 5.1 .ps1 file without a BOM can misread literal
# non-ASCII source characters depending on the encoding it's saved/read
# with.
# 0x65E5 0x672C 0x8A9E = "日本語" ("Japanese language"), 0x30C1 0x30E3
# 0x30D7 0x30BF 0x30FC = "チャプター" ("chapter", katakana).
$nihongo  = [string]([char]0x65E5) + [string]([char]0x672C) + [string]([char]0x8A9E)
$chapterJ = -join @(0x30C1, 0x30E3, 0x30D7, 0x30BF, 0x30FC | ForEach-Object { [char]$_ })

Test-Assert ((Get-DisplayWidth -Text "hello") -eq 5) "plain ASCII: display width equals character count"
Test-Assert ((Get-DisplayWidth -Text "") -eq 0) "empty string has zero display width"
Test-Assert ((Get-DisplayWidth -Text $nihongo) -eq 6) "3 CJK characters report a display width of 6, not 3 (2 columns each)"
Test-Assert ((Get-DisplayWidth -Text ("ab" + $nihongo.Substring(0,2) + "cd")) -eq 8) "mixed ASCII + CJK sums correctly (4 ASCII x1 + 2 CJK x2 = 8)"

$cjkText  = $nihongo + $chapterJ
$cjkSplit = @(Split-TextToWidth -Text $cjkText -Width 10)
Test-Assert (($cjkSplit | ForEach-Object { Get-DisplayWidth -Text $_ } | Measure-Object -Maximum).Maximum -le 10) "every CJK chunk fits within the requested display width in COLUMNS, not just in character count"
Test-Assert (($cjkSplit -join "") -eq $cjkText) "rejoining the CJK chunks reproduces the original text exactly - nothing lost or duplicated"

$padAsciiC2 = Set-PadToDisplayWidth -Text "abc" -Width 6
Test-Assert ($padAsciiC2 -eq "abc   ") "plain ASCII pads exactly like .PadRight would"
$padCjkC2 = Set-PadToDisplayWidth -Text $nihongo.Substring(0,2) -Width 6
Test-Assert ((Get-DisplayWidth -Text $padCjkC2) -eq 6 -and $padCjkC2 -eq ($nihongo.Substring(0,2) + "  ")) "a 2-character CJK string (4 display columns) gets only 2 trailing spaces, not `$Width minus the character COUNT"
$padExactC2 = Set-PadToDisplayWidth -Text $nihongo -Width 6
Test-Assert ($padExactC2 -eq $nihongo) "a CJK string already exactly at the target display width is returned unchanged, no trailing spaces"
Write-Host ""

# ==============================================================================
#  Scenario D: Format-SeriesLines - now returns @{ Text; Color } objects,
#  not bare strings, so colors can be verified directly here.
# ==============================================================================
Write-Host "=== Scenario D: Format-SeriesLines ===" -ForegroundColor Cyan
$entryD1 = @{ TotalChapters = 8; SuccessCount = 3; ActiveChapters = [System.Collections.Generic.List[string]]::new(); IssueChapters = [System.Collections.Generic.List[hashtable]]::new() }
$entryD1.ActiveChapters.Add("Chapter 4")
$entryD1.ActiveChapters.Add("Chapter 5")
$linesD1 = @(Format-SeriesLines -SeriesName "Only Images" -Entry $entryD1)
Test-Assert ($linesD1[0].Text -eq "Only Images") "first line is the series name"
Test-Assert ($null -eq $linesD1[0].Color) "series name line is uncolored"
Test-Assert ($linesD1[1].Text -like "*3/8 chapters*") "second line shows SuccessCount/TotalChapters"
Test-Assert ($null -eq $linesD1[1].Color) "bar+count line is uncolored when there are no issue chapters"
Test-Assert (@($linesD1 | Where-Object { $_.Text -like "*Chapter 4*in progress*" }).Count -eq 1) "active chapter 4 is listed as in progress"
Test-Assert (@($linesD1 | Where-Object { $_.Text -like "*Chapter 5*in progress*" -and $null -eq $_.Color }).Count -eq 1) "active chapter lines are uncolored"

$entryD2 = @{ TotalChapters = 8; SuccessCount = 6; ActiveChapters = [System.Collections.Generic.List[string]]::new(); IssueChapters = [System.Collections.Generic.List[hashtable]]::new() }
$entryD2.IssueChapters.Add(@{ ChapterName = "Chapter 3"; Status = "Warning"; Detail = "2 files skipped" })
$entryD2.IssueChapters.Add(@{ ChapterName = "Chapter 7"; Status = "Error"; Detail = "1 file failed" })
$linesD2 = @(Format-SeriesLines -SeriesName "Only Images" -Entry $entryD2)
Test-Assert ($linesD2[1].Text -like "*6/8 chapters*") "bar numerator is SuccessCount (6), NOT resolved-count (8) - issues don't count toward it"
Test-Assert ($linesD2[1].Color -eq "Red") "bar+count line takes the WORST severity present (Red, because at least one Error exists)"
Test-Assert (@($linesD2 | Where-Object { $_.Text -eq "    Chapter 3 - Warning: 2 files skipped" -and $_.Color -eq "Yellow" }).Count -eq 1) "warning chapter persists with its detail text, colored Yellow"
Test-Assert (@($linesD2 | Where-Object { $_.Text -eq "    Chapter 7 - Error: 1 file failed" -and $_.Color -eq "Red" }).Count -eq 1) "error chapter persists with its detail text, colored Red"
Test-Assert ($linesD2.Count -eq 4) "no active-chapter lines when ActiveChapters is empty (this is what a FROZEN series' lines look like too - same function, no separate frozen formatter needed)"

$entryD3 = @{ TotalChapters = 2; SuccessCount = 1; ActiveChapters = [System.Collections.Generic.List[string]]::new(); IssueChapters = [System.Collections.Generic.List[hashtable]]::new() }
$entryD3.IssueChapters.Add(@{ ChapterName = "Chapter 2"; Status = "Warning"; Detail = "" })
$linesD3 = @(Format-SeriesLines -SeriesName "Series C" -Entry $entryD3)
Test-Assert (@($linesD3 | Where-Object { $_.Text -eq "    Chapter 2 - Warning" }).Count -eq 1) "empty -Detail renders with no dangling ': ' suffix"
Test-Assert ($linesD3[1].Color -eq "Yellow") "bar+count line is Yellow (not Red) when only Warning issues are present, no Error"
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
#  Scenario J: Start-SeriesProgress rejects a negative -TotalChapters
#  instead of silently treating it the same as the legitimate 0-chapter
#  case.
# ==============================================================================
Write-Host "=== Scenario J: negative -TotalChapters throws ===" -ForegroundColor Cyan
Reset-CCRState
$threwNegativeJ = $false
try { Start-SeriesProgress -SeriesName "Bad Series" -TotalChapters -5 } catch { $threwNegativeJ = $true }
Test-Assert $threwNegativeJ "a negative -TotalChapters throws rather than being treated as an empty series"
Test-Assert (-not $script:ccrActiveSeries.Contains("Bad Series")) "the bad series was never registered"
Write-Host ""

# ==============================================================================
#  Scenario K: Complete-AllActiveSeriesProgress - force-resolves every
#  still-active series (the abort/shutdown finalization path). Chapters
#  still running get moved into the persistent issue list with -Status
#  Aborted, exactly like Warning/Error - not left dangling forever.
# ==============================================================================
Write-Host "=== Scenario K: Complete-AllActiveSeriesProgress ===" -ForegroundColor Cyan
Reset-CCRState
$noopK = $false
try { Complete-AllActiveSeriesProgress } catch { $noopK = $true }
Test-Assert (-not $noopK) "calling it with nothing active at all is a clean no-op, not an error"

Reset-CCRState
Start-SeriesProgress -SeriesName "Series A" -TotalChapters 3
Start-ChapterProgress -SeriesName "Series A" -ChapterName "Chapter 1"
$null = Complete-ChapterProgress -SeriesName "Series A" -ChapterName "Chapter 1" -Status Success
Start-ChapterProgress -SeriesName "Series A" -ChapterName "Chapter 2"
Start-ChapterProgress -SeriesName "Series A" -ChapterName "Chapter 3"
Start-SeriesProgress -SeriesName "Series B" -TotalChapters 1
Start-ChapterProgress -SeriesName "Series B" -ChapterName "B-Chapter 1"

$outputK = & { Complete-AllActiveSeriesProgress } 6>&1
$outputTextK = ($outputK | ForEach-Object { $_.ToString() }) -join "`n"

Test-Assert ($script:ccrActiveSeries.Count -eq 0) "every series is removed from the active registry - nothing left live"
Test-Assert ($outputTextK -like "*Series A*" -and $outputTextK -like "*Series B*") "both series' final content was printed as permanent output"
Test-Assert ($outputTextK -like "*Chapter 2 - Aborted*" -and $outputTextK -like "*Chapter 3 - Aborted*") "Series A's two still-running chapters are marked Aborted, not silently dropped"
Test-Assert ($outputTextK -like "*B-Chapter 1 - Aborted*") "Series B's still-running chapter is marked Aborted too"
Test-Assert ($outputTextK -like "*1/3 chapters*") "Series A's bar numerator stays at 1 (the 1 real success) - Aborted chapters don't count toward it either"

$colorFoundK = $false
foreach ($rec in $outputK) {
    if ($rec.MessageData -and $rec.MessageData.PSObject.Properties['ForegroundColor'] -and $rec.MessageData.ForegroundColor -eq "Yellow" -and $rec.ToString() -like "*Aborted*") {
        $colorFoundK = $true
    }
}
Test-Assert $colorFoundK "an Aborted chapter line is actually printed in Yellow via a real captured Write-Host call, not just correct in the abstract content-generation functions"
Write-Host ""

# ==============================================================================
#  Scenario L: Write-CleanConsoleMessage - the new one-off status line
#  function built for AbortPipeline.ps1's abort/drain messages. Verifies
#  it prints as real captured output (content + color), splits a "`n"-
#  led message into separate rows instead of one row with a literal "n"
#  embedded, and is safe to call with nothing active (the common case for
#  most of AbortPipeline's messages, which fire whether or not any series
#  happens to be mid-run).
# ==============================================================================
Write-Host "=== Scenario L: Write-CleanConsoleMessage ===" -ForegroundColor Cyan
Reset-CCRState

$outputL1 = & { Write-CleanConsoleMessage -Text "`n[ABORT] Ctrl+C detected - finishing current jobs, please wait..." -Color Yellow } 6>&1
$outputTextL1 = ($outputL1 | ForEach-Object { $_.ToString() }) -join "`n"
# -like's "[...]" is a wildcard character-class, not a literal bracket - use
# -match (regex) with the brackets escaped so this genuinely checks for the
# literal text "[ABORT]", not "one char from the set A/B/O/R/T".
Test-Assert ($outputTextL1 -match [regex]::Escape("[ABORT] Ctrl+C detected")) "the message content is actually printed"
Test-Assert ($outputL1.Count -ge 2) ("the leading `n produced its own separate (blank) row, not one row with a literal backtick-n embedded (got " + $outputL1.Count + " row(s))")

$colorFoundL1 = $false
foreach ($rec in $outputL1) {
    if ($rec.MessageData -and $rec.MessageData.PSObject.Properties['ForegroundColor'] -and $rec.MessageData.ForegroundColor -eq "Yellow" -and $rec.ToString() -like "*ABORT*") {
        $colorFoundL1 = $true
    }
}
Test-Assert $colorFoundL1 "the message row is printed in the requested -Color (Yellow), via a real captured Write-Host call"

$callThrewL1 = $false
try { Write-CleanConsoleMessage -Text "no series active right now" } catch { $callThrewL1 = $true }
Test-Assert (-not $callThrewL1) "calling Write-CleanConsoleMessage with zero active series does not throw"

# Now with a live series in progress - confirm the message prints as
# permanent content WITHOUT disturbing the still-active series (it's not
# accidentally removed from the registry, resolved, or otherwise mutated).
Reset-CCRState
Start-SeriesProgress -SeriesName "Series L" -TotalChapters 2
Start-ChapterProgress -SeriesName "Series L" -ChapterName "Chapter 1"
$outputL2 = & { Write-CleanConsoleMessage -Text "[ABORT] Waiting for current jobs to finish..." -Color Yellow } 6>&1
$outputTextL2 = ($outputL2 | ForEach-Object { $_.ToString() }) -join "`n"
Test-Assert ($outputTextL2 -like "*Waiting for current jobs*") "the message prints correctly even while a series is actively in progress"
Test-Assert ($script:ccrActiveSeries.Contains("Series L")) "the active series is untouched - still registered after the message was printed"
Test-Assert ($script:ccrActiveSeries["Series L"].ActiveChapters -contains "Chapter 1") "the active series' in-progress chapter is untouched too"

# No current caller passes CRLF, but a
# public function's own contract shouldn't depend on that: splitting on
# a bare "`n" leaves a trailing "`r" on each CRLF-delimited segment. A
# stray CR mid-row makes the terminal snap the cursor back to column 0,
# so the row's own trailing padding then overwrites the real message
# text with blanks. -split "\r?\n" strips the CR cleanly either way.
Reset-CCRState
$outputL3 = & { Write-CleanConsoleMessage -Text "line one`r`nline two" -Color Yellow } 6>&1
$rowTextsL3 = @($outputL3 | ForEach-Object { $_.ToString() })
Test-Assert (-not ($rowTextsL3 | Where-Object { $_.Contains("`r") })) ("no output row contains a stray carriage return from CRLF input (rows: [" + ($rowTextsL3 -join "]/[") + "])")
Test-Assert (($rowTextsL3 | Where-Object { $_ -like "*line one*" }).Count -eq 1) "the CRLF input still split into two separate rows, not one row with an embedded CR"
Test-Assert (($rowTextsL3 | Where-Object { $_ -like "*line two*" }).Count -eq 1) "both lines from the CRLF input are present"
Write-Host ""

# ==============================================================================
#  Scenario M: live-region cap. A Full
#  Pipeline run whose idle engine walks the whole library up front
#  announces every series to CCR at once. Without a cap the live region
#  would grow unbounded, eventually overrun the console buffer, and
#  SetCursorPosition would throw - latching CCR into the print-everything
#  fallback that floods the console and starves the main thread (zip stops,
#  abort polls are never reached). Get-CappedLiveRows bounds the live
#  region to the window height so that can never happen at any library
#  size. This environment has no real console, so the cursor mechanics
#  themselves still can't be exercised (see this harness's header); what IS
#  proven here is the cap logic that makes the overrun unreachable.
# ==============================================================================
Write-Host "=== Scenario M: live-region cap (CCR pacing gap) ===" -ForegroundColor Cyan
Reset-CCRState

# Build 100 active series, each with one in-progress chapter (= 3 rows per
# series: name, bar, the in-progress chapter line), all in the registry at
# once - exactly the "whole library announced up front" flood.
$floodSeries = [System.Collections.Specialized.OrderedDictionary]::new()
for ($s = 1; $s -le 100; $s++) {
    $entry = @{
        TotalChapters  = 1
        SuccessCount   = 0
        ActiveChapters = [System.Collections.Generic.List[string]]::new()
        IssueChapters  = [System.Collections.Generic.List[hashtable]]::new()
    }
    $entry.ActiveChapters.Add("Chapter 1")
    $floodSeries[("Series " + $s)] = $entry
}

# Uncapped (MaxRows 0): the entire flood renders.
# (Get-CappedLiveRows returns its List via the `,` unary-array convention,
# so capture it directly - @(...) would see the wrapper as one element.)
$uncapped = Get-CappedLiveRows -ActiveSeries $floodSeries -Width 79 -MaxRows 0
Test-Assert ($uncapped.Count -eq 300) ("without a cap the full flood renders - 100 series x 3 rows = 300 rows (got " + $uncapped.Count + ")")

# Capped to a 20-row window: bounded, and a summary accounts for the rest.
$capped = Get-CappedLiveRows -ActiveSeries $floodSeries -Width 79 -MaxRows 20
Test-Assert ($capped.Count -le 20) ("capped to a 20-row window, the live region never exceeds it (got " + $capped.Count + " rows)")
$summaryRow = $capped | Where-Object { $_.Text -like "*more series in progress*" }
Test-Assert ($null -ne $summaryRow) "a '... and N more series in progress' summary replaces the hidden series"
Test-Assert ($capped[$capped.Count - 1].Text -like "*more series in progress*") "the summary is the last row of the capped region"

# The cap never cuts a series mid-block: the last shown series' rows are
# whole (6 series x 3 rows = 18, then the summary = 19 total).
Test-Assert ($capped.Count -eq 19) ("cap stops on a whole-series boundary - 6 full series (18 rows) + 1 summary = 19 (got " + $capped.Count + ")")

# A cap larger than the content shows everything, with no summary.
$roomy = Get-CappedLiveRows -ActiveSeries $floodSeries -Width 79 -MaxRows 5000
Test-Assert ($roomy.Count -eq 300) "a cap larger than the content renders every row, no truncation"
Test-Assert ($null -eq ($roomy | Where-Object { $_.Text -like "*more series in progress*" })) "no summary row when nothing is hidden"

# A single series taller than the cap: a
# series block keeps every Warning/Error chapter for the life of the series,
# so one warning-heavy series can outgrow the window on its own. A cap that
# always admitted the first series whole would let the region exceed
# MaxRows, and the cursor rewind would fail exactly like the original flood.
$tallSeries = [System.Collections.Specialized.OrderedDictionary]::new()
$tallEntry = @{
    TotalChapters  = 60
    SuccessCount   = 0
    ActiveChapters = [System.Collections.Generic.List[string]]::new()
    IssueChapters  = [System.Collections.Generic.List[hashtable]]::new()
}
for ($c = 1; $c -le 40; $c++) { $tallEntry.IssueChapters.Add(@{ ChapterName = ("Chapter " + $c); Status = "Warning"; Detail = "AVIF classification failure" }) }
$tallSeries["Tall Series"] = $tallEntry
$tallAlone = Get-CappedLiveRows -ActiveSeries $tallSeries -Width 79 -MaxRows 20
Test-Assert ($tallAlone.Count -eq 20) ("a lone series taller than the cap is cut to exactly the cap (got " + $tallAlone.Count + " rows for a 42-row series, cap 20)")
Test-Assert ($tallAlone[0].Text -eq "Tall Series") "the cut series still starts with its own name row"
Test-Assert ($tallAlone[$tallAlone.Count - 1].Text -like "*23 more line(s)*") ("the last row says how many of its lines were hidden (got '" + $tallAlone[$tallAlone.Count - 1].Text + "')")

$tallSeries["Second"] = $floodSeries["Series 1"]
$tallFirst = Get-CappedLiveRows -ActiveSeries $tallSeries -Width 79 -MaxRows 20
Test-Assert ($tallFirst.Count -eq 20) ("a tall FIRST series followed by others still respects the cap (got " + $tallFirst.Count + ")")
Test-Assert ($tallFirst[$tallFirst.Count - 1].Text -like "*and 1 more series in progress*") "...and the summary also counts the series behind it"

$tinyCap = Get-CappedLiveRows -ActiveSeries $floodSeries -Width 79 -MaxRows 1
Test-Assert ($tinyCap.Count -eq 1) ("a 1-row cap (tiny window) yields exactly 1 row, not a whole series (got " + $tinyCap.Count + ")")

# The summary line is truncated to ONE row - it's the one row the cap
# reserves, so a wrapping summary would overrun the cap at narrow widths.
$narrow = Get-CappedLiveRows -ActiveSeries $floodSeries -Width 12 -MaxRows 10
Test-Assert ($narrow.Count -le 10) ("at a 12-column width the region still fits a 10-row cap (got " + $narrow.Count + ")")

# Integration: Update-CleanConsoleDisplay honors the $ccrMaxLiveRows seam,
# so a real redraw of the flooded registry emits a bounded row count
# instead of the whole library.
Reset-CCRState
$script:ccrMaxLiveRows = 20
for ($s = 1; $s -le 100; $s++) {
    Start-SeriesProgress -SeriesName ("S" + $s) -TotalChapters 1
    Start-ChapterProgress -SeriesName ("S" + $s) -ChapterName "Chapter 1"
}
$redraw = & { Update-CleanConsoleDisplay } 6>&1
Test-Assert (@($redraw).Count -le 20) ("a full redraw of 100 announced series emits at most a window's worth of rows, not the whole flood (emitted " + @($redraw).Count + ")")
$script:ccrMaxLiveRows = $null
Write-Host ""

# ==============================================================================
#  Summary
# ==============================================================================
# ==============================================================================
#  Scenario N: queued -> in progress. A chapter started with -Queued shows
#  "(queued)" until Set-ChapterInProgress flips it; the flip is a no-op for
#  an unknown series/chapter or an already-flipped one, and completing a
#  still-queued chapter clears its queued state.
# ==============================================================================
Write-Host "=== Scenario N: queued chapters show as queued until Set-ChapterInProgress ===" -ForegroundColor Cyan
Reset-CCRState
Start-SeriesProgress -SeriesName "Series N" -TotalChapters 3
Start-ChapterProgress -SeriesName "Series N" -ChapterName "Chapter 1" -Queued
Start-ChapterProgress -SeriesName "Series N" -ChapterName "Chapter 2"
$linesN1 = @(Format-SeriesLines -SeriesName "Series N" -Entry $script:ccrActiveSeries["Series N"] | ForEach-Object { $_.Text })
Test-Assert ($linesN1 -contains "    Chapter 1 (queued)") "a -Queued chapter renders as '(queued)'"
Test-Assert ($linesN1 -contains "    Chapter 2 (in progress)") "a chapter started without -Queued still renders as '(in progress)'"

Set-ChapterInProgress -SeriesName "Series N" -ChapterName "Chapter 1"
$linesN2 = @(Format-SeriesLines -SeriesName "Series N" -Entry $script:ccrActiveSeries["Series N"] | ForEach-Object { $_.Text })
Test-Assert ($linesN2 -contains "    Chapter 1 (in progress)") "Set-ChapterInProgress flips a queued chapter to '(in progress)'"
Test-Assert (@($linesN2 -match '\(queued\)').Count -eq 0) "no chapter is left showing '(queued)' after the flip"

$threwN = $false
try {
    Set-ChapterInProgress -SeriesName "Series N" -ChapterName "Chapter 1"
    Set-ChapterInProgress -SeriesName "Series N" -ChapterName "Never Started"
    Set-ChapterInProgress -SeriesName "Nonexistent Series" -ChapterName "X"
} catch { $threwN = $true }
Test-Assert (-not $threwN) "Set-ChapterInProgress is a silent no-op for an already-flipped chapter, an unknown chapter, and an unknown series"

Start-ChapterProgress -SeriesName "Series N" -ChapterName "Chapter 3" -Queued
$null = Complete-ChapterProgress -SeriesName "Series N" -ChapterName "Chapter 3" -Status Success
Test-Assert (-not $script:ccrActiveSeries["Series N"].QueuedChapters.Contains("Chapter 3")) "completing a still-queued chapter clears its queued state"
Reset-CCRState
Write-Host ""

Write-Host "==============================================="
if ($script:failCount -eq 0) {
    Write-Host ("ALL PASSED  (" + $script:passCount + " assertions)") -ForegroundColor Green
} else {
    Write-Host ($script:failCount.ToString() + " FAILED, " + $script:passCount + " passed") -ForegroundColor Red
}
Write-Host "==============================================="

if ($script:failCount -gt 0) { exit 1 } else { exit 0 }
