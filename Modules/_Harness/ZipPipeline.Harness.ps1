<#
.SYNOPSIS
    Standalone test harness for Modules\ZipPipeline.ps1.

.DESCRIPTION
    Unlike prior harnesses (mostly stubbed dependencies), this one dot-
    sources the REAL already-built dependency modules - FileDeletion.ps1,
    ZipCreation.ps1, ZipValidation.ps1, LeafDirectoryDiscovery.ps1,
    AbortPipeline.ps1, Logging.ps1, CleanConsoleRendering.ps1, and
    ZipParallelProcessing.ps1 - since ZipPipeline.ps1 is an orchestration-
    tier module that composes all of them for real. This is closer to an
    integration test than the earlier pure-unit harnesses, appropriate
    for this tier.

    DOT-SOURCE ORDER FLIPPED (2026-08-27, ZPP's migration onto
    Logging.ps1/AbortPipeline.ps1): it used to matter that Logging.ps1
    came AFTER ZipParallelProcessing.ps1, since ZPP had its own stale
    inline Write-Log/Test-AbortSignal that would otherwise silently win.
    ZPP no longer defines any of those itself - it forward-references
    them - so AbortPipeline.ps1 and Logging.ps1 must now be dot-sourced
    BEFORE ZipParallelProcessing.ps1, or ZPP's own Invoke-ZipParallelProcessing
    would fail immediately (Write-Log/Test-AbortSignal/Invoke-GracefulDrain
    undefined).

.EXAMPLE
    .\Modules\_Harness\ZipPipeline.Harness.ps1
#>

$ErrorActionPreference = "Stop"

$modulesDir = Join-Path $PSScriptRoot ".."
. (Join-Path $modulesDir "FileDeletion.ps1")
. (Join-Path $modulesDir "ZipCreation.ps1")
. (Join-Path $modulesDir "ZipValidation.ps1")
. (Join-Path $modulesDir "LeafDirectoryDiscovery.ps1")
. (Join-Path $modulesDir "AbortPipeline.ps1")
. (Join-Path $modulesDir "Logging.ps1")
. (Join-Path $modulesDir "CleanConsoleRendering.ps1")
. (Join-Path $modulesDir "ZipParallelProcessing.ps1")   # AFTER AbortPipeline.ps1/Logging.ps1 now - see header note
. (Join-Path $modulesDir "ZipPipeline.ps1")

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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("zippipeline-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray
Write-Host ""

Initialize-FileDeletion -PermanentDelete $true   # scratch content - permanent delete keeps the real Recycle Bin clean across this harness's many runs
Initialize-LogPaths -TargetPath $scratchDir -FullLogging $false -ScriptDir $scratchDir

function New-Dir {
    param([string]$RelativePath)
    $path = Join-Path $scratchDir $RelativePath
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}
function New-FileIn {
    param([string]$DirPath, [string]$Name)
    $path = Join-Path $DirPath $Name
    "content of $Name" | Out-File -FilePath $path -Encoding UTF8
    return $path
}

# ==============================================================================
#  Scenario A: end-to-end mode 3 - real folders, real parallel zip, real
#  readable ZIP output, source folders deleted on success.
# ==============================================================================
Write-Host "=== Scenario A: Invoke-ZipOnlyPipeline end-to-end ===" -ForegroundColor Cyan
$rootA = New-Dir "scenario-a"
$leaf1A = New-Dir "scenario-a\Chapter 1"
New-FileIn -DirPath $leaf1A -Name "page1.jpg" | Out-Null
New-FileIn -DirPath $leaf1A -Name "page2.jpg" | Out-Null
$leaf2A = New-Dir "scenario-a\Chapter 2"
New-FileIn -DirPath $leaf2A -Name "page1.jpg" | Out-Null

$totalsA = Invoke-ZipOnlyPipeline -Path $rootA -MaxParallel 2 -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -DeleteFolders $true -FullLogging $false -PermanentDelete $true

Test-Assert ($totalsA.CandidateCount -eq 2) ("2 candidates found (got " + $totalsA.CandidateCount + ")")
Test-Assert ($totalsA.ZippedSuccess -eq 2) ("both zipped successfully (got " + $totalsA.ZippedSuccess + ")")
Test-Assert ($totalsA.ZippedFail -eq 0) "no failures"
Test-Assert ($totalsA.FolderDeletedSuccess -eq 2) ("both source folders deleted (got " + $totalsA.FolderDeletedSuccess + ")")
Test-Assert (-not (Test-Path -LiteralPath $leaf1A)) "Chapter 1's source folder is gone"
Test-Assert (-not (Test-Path -LiteralPath $leaf2A)) "Chapter 2's source folder is gone"

$zip1A = Join-Path $rootA "Chapter 1.zip"
$zip2A = Join-Path $rootA "Chapter 2.zip"
Test-Assert (Test-Path -LiteralPath $zip1A) "Chapter 1.zip exists"
Test-Assert (Test-Path -LiteralPath $zip2A) "Chapter 2.zip exists"
$archive1A = [System.IO.Compression.ZipFile]::OpenRead($zip1A)
try { Test-Assert ($archive1A.Entries.Count -eq 2) ("Chapter 1.zip has both real pages (got " + $archive1A.Entries.Count + " entries)") }
finally { $archive1A.Dispose() }

Test-Assert ($null -eq $script:zipOnlyCts) "the CTS was disposed and cleared after a normal (non-aborted) run"
Write-Host ""

# ==============================================================================
#  Scenario B: no qualifying leaf directories - all totals stay zero, a
#  clear warning is logged, no error.
# ==============================================================================
Write-Host "=== Scenario B: no candidates found ===" -ForegroundColor Cyan
$rootB = New-Dir "scenario-b-empty"

$totalsB = Invoke-ZipOnlyPipeline -Path $rootB -MaxParallel 2 -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -FullLogging $false -PermanentDelete $true
Test-Assert ($totalsB.CandidateCount -eq 0) "0 candidates found in an empty tree"
Test-Assert ($totalsB.ZippedSuccess -eq 0 -and $totalsB.ZippedFail -eq 0) "no zip attempts were made"
Write-Host ""

# ==============================================================================
#  Scenario C: -DeleteFolders $false - zips are created but source
#  folders are left alone.
# ==============================================================================
Write-Host "=== Scenario C: -DeleteFolders `$false leaves sources intact ===" -ForegroundColor Cyan
$rootC = New-Dir "scenario-c"
$leafC = New-Dir "scenario-c\Chapter 1"
New-FileIn -DirPath $leafC -Name "page1.jpg" | Out-Null

$totalsC = Invoke-ZipOnlyPipeline -Path $rootC -MaxParallel 2 -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -DeleteFolders $false -FullLogging $false -PermanentDelete $true
Test-Assert ($totalsC.ZippedSuccess -eq 1) "the folder was zipped"
Test-Assert ($totalsC.FolderDeletedSuccess -eq 0 -and $totalsC.FolderDeletedFail -eq 0) "no delete was attempted at all"
Test-Assert (Test-Path -LiteralPath $leafC) "the source folder still exists"
Write-Host ""

# ==============================================================================
#  Scenario D: a leaf with an already-up-to-date same-named zip is
#  correctly excluded - confirms real wiring to Get-ZippableLeafDirs's
#  own staleness check, not just that function in isolation.
# ==============================================================================
Write-Host "=== Scenario D: up-to-date zip is excluded via real LeafDirectoryDiscovery wiring ===" -ForegroundColor Cyan
$rootD = New-Dir "scenario-d"
$leafD = New-Dir "scenario-d\Chapter 1"
New-FileIn -DirPath $leafD -Name "page1.jpg" | Out-Null
$zipOutD = Join-Path $rootD "Chapter 1.zip"
"fake pre-existing zip" | Out-File -FilePath $zipOutD -Encoding UTF8
(Get-Item -LiteralPath $zipOutD).LastWriteTimeUtc = (Get-Date).ToUniversalTime()   # newer than the source file

$totalsD = Invoke-ZipOnlyPipeline -Path $rootD -MaxParallel 2 -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -FullLogging $false -PermanentDelete $true
Test-Assert ($totalsD.CandidateCount -eq 0) "the up-to-date leaf was excluded before even reaching the zip step"
Write-Host ""

# ==============================================================================
#  Scenario E: the former-container ("Only Images") case, exercised
#  through the FULL pipeline (not calling Get-ZippableLeafDirs directly) -
#  confirms end-to-end that a post-completion series folder is never
#  treated as a zip candidate.
# ==============================================================================
Write-Host "=== Scenario E: former-container guard through the full pipeline ===" -ForegroundColor Cyan
$rootE = New-Dir "scenario-e"
$onlyImagesE = New-Dir "scenario-e\Only Images"
New-FileIn -DirPath $onlyImagesE -Name "08 - Chapter 8.zip" | Out-Null
New-FileIn -DirPath $onlyImagesE -Name "09 - Chapter 9.zip" | Out-Null

$totalsE = Invoke-ZipOnlyPipeline -Path $rootE -MaxParallel 2 -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -FullLogging $false -PermanentDelete $true
Test-Assert ($totalsE.CandidateCount -eq 0) "'Only Images' (zero subdirs, only .zip files) was never a zip candidate through the full pipeline"
Test-Assert (Test-Path -LiteralPath (Join-Path $onlyImagesE "08 - Chapter 8.zip")) "the existing chapter zips were left completely untouched"
Write-Host ""

# ==============================================================================
#  Scenario F: Invoke-LooseFolderZip (PART 2) - normal success path.
# ==============================================================================
Write-Host "=== Scenario F: Invoke-LooseFolderZip success path ===" -ForegroundColor Cyan
$dirF = New-Dir "scenario-f"
New-FileIn -DirPath $dirF -Name "page1.jxl" | Out-Null
New-FileIn -DirPath $dirF -Name "page2.jxl" | Out-Null
$zipOutF = Join-Path $scratchDir "scenario-f.zip"

$resultF = Invoke-LooseFolderZip -FolderPath $dirF -ZipOut $zipOutF -LooseImageExtensions @(".jpg", ".png")

Test-Assert ($resultF.Status -eq "Success") ("Status is Success (got " + $resultF.Status + ")")
Test-Assert ($resultF.EntryCount -eq 2) "EntryCount is 2"
Test-Assert ($resultF.FolderDeleted -eq $true) "the source folder was deleted after a successful zip"
Test-Assert (-not (Test-Path -LiteralPath $dirF)) "the source folder is actually gone"
Test-Assert (Test-Path -LiteralPath $zipOutF) "the zip file exists"
Write-Host ""

# ==============================================================================
#  Scenario G: Invoke-LooseFolderZip - remaining unconverted source images
#  present - skipped, nothing zipped, folder left alone (partial-failure
#  protection).
# ==============================================================================
Write-Host "=== Scenario G: Invoke-LooseFolderZip skips when unconverted images remain ===" -ForegroundColor Cyan
$dirG = New-Dir "scenario-g"
New-FileIn -DirPath $dirG -Name "page1.jxl" | Out-Null
New-FileIn -DirPath $dirG -Name "page2.jpg" | Out-Null   # still-unconverted source image
$zipOutG = Join-Path $scratchDir "scenario-g.zip"

$resultG = Invoke-LooseFolderZip -FolderPath $dirG -ZipOut $zipOutG -LooseImageExtensions @(".jpg", ".png")

Test-Assert ($resultG.Status -eq "Skipped") ("Status is Skipped (got " + $resultG.Status + ")")
Test-Assert (-not (Test-Path -LiteralPath $zipOutG)) "no zip file was created"
Test-Assert (Test-Path -LiteralPath $dirG) "the source folder was left alone (not deleted)"
Write-Host ""

# ==============================================================================
#  Scenario H: Invoke-LooseFolderZip - zip succeeds but has no .jxl
#  entries and RequireJxlEntry defaults to $true - Test-ZipArchive throws,
#  Status is Fail.
# ==============================================================================
Write-Host "=== Scenario H: Invoke-LooseFolderZip fails validation with no .jxl entries ===" -ForegroundColor Cyan
$dirH = New-Dir "scenario-h"
New-FileIn -DirPath $dirH -Name "notes.txt" | Out-Null   # not a loose image ext, so it's not "remaining unconverted" - but also not .jxl
$zipOutH = Join-Path $scratchDir "scenario-h.zip"

$resultH = Invoke-LooseFolderZip -FolderPath $dirH -ZipOut $zipOutH -LooseImageExtensions @(".jpg", ".png")

Test-Assert ($resultH.Status -eq "Fail") ("Status is Fail when the zip has no .jxl entries and RequireJxlEntry defaults true (got " + $resultH.Status + ")")
Test-Assert (Test-Path -LiteralPath $dirH) "the source folder is left alone after a failed zip (not deleted)"
Write-Host ""

# ==============================================================================
#  Scenario I: mode 3 CCR wiring, real Series folder wrapping two chapters -
#  Start-SeriesProgress gets the real bounded-scan TotalChapters (2), both
#  chapters resolve Success, and the series ends up resolved (off the active
#  registry) once both are done.
# ==============================================================================
Write-Host "=== Scenario I: mode 3 CCR wiring, nested Series/Chapter ===" -ForegroundColor Cyan
$rootI  = New-Dir "scenario-i"
$ch1I   = New-Dir "scenario-i\My Series\Chapter 1"
$ch2I   = New-Dir "scenario-i\My Series\Chapter 2"
New-FileIn -DirPath $ch1I -Name "page1.jpg" | Out-Null
New-FileIn -DirPath $ch2I -Name "page1.jpg" | Out-Null

$script:CleanConsoleOutputEnabled = $true
try {
    $totalsI = Invoke-ZipOnlyPipeline -Path $rootI -MaxParallel 2 -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -FullLogging $false -PermanentDelete $true
} finally {
    $script:CleanConsoleOutputEnabled = $false
}

Test-Assert ($totalsI.CandidateCount -eq 2) ("2 candidates found (got " + $totalsI.CandidateCount + ")")
Test-Assert ($totalsI.ZippedSuccess -eq 2) "both chapters zipped"
Test-Assert ($script:ccrActiveSeries.Count -eq 0) "the series resolved and left the active registry once both chapters completed"

# ==============================================================================
#  Scenario J: mode 3 CCR wiring, a FLAT leaf with no Series folder wrapping
#  it (mode 3's own long-standing supported shape - see CLAUDE.md's Known
#  gaps on why this isn't validated away) - degenerates to a one-chapter
#  "series" named after the leaf itself, still resolves cleanly.
# ==============================================================================
Write-Host "=== Scenario J: mode 3 CCR wiring, flat leaf (no Series folder) ===" -ForegroundColor Cyan
$rootJ = New-Dir "scenario-j"
$leafJ = New-Dir "scenario-j\Lone Chapter"
New-FileIn -DirPath $leafJ -Name "page1.jpg" | Out-Null

$script:CleanConsoleOutputEnabled = $true
try {
    $totalsJ = Invoke-ZipOnlyPipeline -Path $rootJ -MaxParallel 2 -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -FullLogging $false -PermanentDelete $true
} finally {
    $script:CleanConsoleOutputEnabled = $false
}

Test-Assert ($totalsJ.ZippedSuccess -eq 1) "the flat leaf was still zipped successfully"
Test-Assert ($script:ccrActiveSeries.Count -eq 0) "the degenerate one-chapter series resolved too"

# ==============================================================================
#  Scenario K: mode 3 CCR wiring, a real zip FAILURE - Complete-ChapterProgress
#  gets called with Status Error, not silently skipped just because the job
#  failed. Forced by holding an exclusive-lock FileStream open on the
#  chapter's own image file, so ZipFile.CreateFromDirectory throws for real
#  when it tries to read it (a pre-created blocking directory at the zip-out
#  path doesn't work - Compress-FolderToZip's own Remove-Source call just
#  deletes it first and zips successfully anyway).
# ==============================================================================
Write-Host "=== Scenario K: mode 3 CCR wiring, a real zip failure ===" -ForegroundColor Cyan
$rootK  = New-Dir "scenario-k"
$ch1K   = New-Dir "scenario-k\Series\Chapter 1"
$imgK   = New-FileIn -DirPath $ch1K -Name "page1.jpg"
$lockK  = [System.IO.File]::Open($imgK, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)

$script:CleanConsoleOutputEnabled = $true
try {
    $totalsK = Invoke-ZipOnlyPipeline -Path $rootK -MaxParallel 2 -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -FullLogging $false -PermanentDelete $true
} finally {
    $script:CleanConsoleOutputEnabled = $false
    $lockK.Dispose()
}

Test-Assert ($totalsK.ZippedFail -eq 1) ("the forced zip failure was counted (got ZippedFail=" + $totalsK.ZippedFail + ")")
Test-Assert ($script:ccrActiveSeries.Count -eq 0) "the series still resolved (as an issue, not left hanging) after a real zip failure"

# ==============================================================================
#  Scenario L: Invoke-LooseFolderZip's own optional -SeriesName/-ChapterName
#  CCR wiring - Success/Skipped/Fail all map to the right Status, and a
#  caller that omits both params (the only wiring that exists in practice
#  today - see this function's own .PARAMETER note) gets no CCR calls at all.
#  Invoke-LooseFolderZip only calls Start-/Complete-ChapterProgress for
#  ITSELF, not Start-SeriesProgress - a real caller (e.g. a future mode 2
#  orchestrator) is assumed to already own that series' total, exactly like
#  ImageConversionPipeline.ps1 already does when it walks a series' chapters
#  - so each mock series here is started explicitly first, standing in for
#  that caller.
# ==============================================================================
Write-Host "=== Scenario L: Invoke-LooseFolderZip's own CCR wiring ===" -ForegroundColor Cyan
$script:CleanConsoleOutputEnabled = $true
try {
    Start-SeriesProgress -SeriesName "L Series" -TotalChapters 1
    $dirL1 = New-Dir "scenario-l1"
    New-FileIn -DirPath $dirL1 -Name "page1.jxl" | Out-Null
    $null = Invoke-LooseFolderZip -FolderPath $dirL1 -ZipOut (Join-Path $scratchDir "scenario-l1.zip") -LooseImageExtensions @(".jpg") -SeriesName "L Series" -ChapterName "Ch Success"
    Test-Assert ($script:ccrActiveSeries.Count -eq 0) "a Success zip resolves its own series immediately (1/1 total)"

    Start-SeriesProgress -SeriesName "L Series 2" -TotalChapters 1
    $dirL2 = New-Dir "scenario-l2"
    New-FileIn -DirPath $dirL2 -Name "page1.jxl" | Out-Null
    New-FileIn -DirPath $dirL2 -Name "page2.jpg" | Out-Null   # still-unconverted -> Skipped
    $null = Invoke-LooseFolderZip -FolderPath $dirL2 -ZipOut (Join-Path $scratchDir "scenario-l2.zip") -LooseImageExtensions @(".jpg") -SeriesName "L Series 2" -ChapterName "Ch Skipped"
    Test-Assert ($script:ccrActiveSeries.Count -eq 0) "a Skipped zip still resolves its series (mapped to Warning, not left hanging)"

    Start-SeriesProgress -SeriesName "L Series 3" -TotalChapters 1
    $dirL3 = New-Dir "scenario-l3"
    New-FileIn -DirPath $dirL3 -Name "notes.txt" | Out-Null   # no .jxl entries -> Fail (RequireJxlEntry defaults true)
    $null = Invoke-LooseFolderZip -FolderPath $dirL3 -ZipOut (Join-Path $scratchDir "scenario-l3.zip") -LooseImageExtensions @(".jpg") -SeriesName "L Series 3" -ChapterName "Ch Fail"
    Test-Assert ($script:ccrActiveSeries.Count -eq 0) "a Fail zip resolves its series too (mapped to Error)"
} finally {
    $script:CleanConsoleOutputEnabled = $false
}

$dirL4 = New-Dir "scenario-l4"
New-FileIn -DirPath $dirL4 -Name "page1.jxl" | Out-Null
$resultL4 = Invoke-LooseFolderZip -FolderPath $dirL4 -ZipOut (Join-Path $scratchDir "scenario-l4.zip") -LooseImageExtensions @(".jpg")
Test-Assert ($resultL4.Status -eq "Success") "omitting -SeriesName/-ChapterName still works normally (no CCR involvement)"

# 2026-08-31 fix: the case above ($script:CleanConsoleOutputEnabled already
# reset to $false by the time it runs) never actually exercised the real
# trigger - Controller.ps1's own real call site omits both names AND runs
# with Clean Console Output ON. An omitted [string] parameter binds to ""
# not $null, so a $null-based "were these supplied" check was $true for
# EVERY caller and crashed on -SeriesName "" the first time a chapter with
# CCR enabled reached this function. Re-run the exact same omitted-params
# call, this time with CCR actually on, and assert it doesn't throw.
$script:CleanConsoleOutputEnabled = $true
try {
    $dirL5 = New-Dir "scenario-l5"
    New-FileIn -DirPath $dirL5 -Name "page1.jxl" | Out-Null
    $resultL5 = Invoke-LooseFolderZip -FolderPath $dirL5 -ZipOut (Join-Path $scratchDir "scenario-l5.zip") -LooseImageExtensions @(".jpg")
    Test-Assert ($resultL5.Status -eq "Success") "omitting -SeriesName/-ChapterName with Clean Console Output ON does not throw (real Controller.ps1 call shape)"
} finally {
    $script:CleanConsoleOutputEnabled = $false
}

Write-Host ""

# ==============================================================================
#  Scenario M (2026-08-31 fix): Get-ZipChapterProgressStatus mapping, tested
#  directly (unit-level). A cancelled-before-start job's result
#  (Success=0/Failed=0/FolderDeleteFailed=0, all zero - nothing attempted)
#  used to be indistinguishable from a genuine clean success and fell
#  through to "Success". The worker now sets Cancelled=1 on that path, and
#  this function checks it first.
# ==============================================================================
Write-Host "=== Scenario M: Get-ZipChapterProgressStatus mapping - cancelled-before-start is not Success ===" -ForegroundColor Cyan
$statusCancelledM, $detailCancelledM = Get-ZipChapterProgressStatus -ZipResult @{ Success = 0; Failed = 0; FolderDeleted = 0; FolderDeleteFailed = 0; Cancelled = 1 }
Test-Assert ($statusCancelledM -eq "Warning" -and $detailCancelledM -match "cancelled") "a cancelled-before-start result is Warning, not Success - it was never actually zipped"

$statusCleanM, $detailCleanM = Get-ZipChapterProgressStatus -ZipResult @{ Success = 1; Failed = 0; FolderDeleted = 1; FolderDeleteFailed = 0; Cancelled = 0 }
Test-Assert ($statusCleanM -eq "Success" -and $null -eq $detailCleanM) "a genuine clean success is still Success"
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
