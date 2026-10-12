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

$totalsA = Invoke-ZipOnlyPipeline -Path $rootA -MaxParallel 2 -DeleteFolders $true -PermanentDelete $true

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
# 2026-09-03 fix, real bug caught by a same-session /code-review pass:
# Invoke-ZipOnlyPipeline previously had no Aborted field at all (only
# ForceStoppedCount) - Controller.ps1's Invoke-Mode now maps this onto
# Summary.ps1's Aborted/ForceKilledCount fields, so mode 3's own summary
# can say "Processing ABORTED" too.
Test-Assert ($totalsA.Aborted -eq $false) "a normal, non-aborted run reports Aborted = `$false"
Write-Host ""

# ==============================================================================
#  Scenario A2 (2026-09-04 fix, real bug): $script:zipOnlyWorker's own
#  bootstrap never set $script:CleanConsoleOutputEnabled in its own
#  runspace's independent script scope - Write-Log's CCO gate never fired
#  there, so every worker line was enqueued and printed straight to the
#  console through Flush-ConsoleQueue's own unconditional drain, even with
#  Clean Console Output on. Write-LogLineToHost shadowed to record every
#  line actually reaching the console (both the direct-write and the
#  queue-flush paths go through it).
# ==============================================================================
Write-Host "=== Scenario A2: mode 3's worker respects Clean Console Output - its own lines are not printed ===" -ForegroundColor Cyan
$rootA2 = New-Dir "scenario-a2"
$leafA2 = New-Dir "scenario-a2\Chapter 1"
New-FileIn -DirPath $leafA2 -Name "page1.jpg" | Out-Null

$script:hostLinesA2 = [System.Collections.Generic.List[string]]::new()
$realWriteLogLineToHostA2 = ${function:Write-LogLineToHost}
function Write-LogLineToHost {
    param([string]$Line, [string]$Level)
    $script:hostLinesA2.Add($Line)
}
$script:CleanConsoleOutputEnabled = $true
try {
    $totalsA2 = Invoke-ZipOnlyPipeline -Path $rootA2 -MaxParallel 2 -DeleteFolders $true -PermanentDelete $true
} finally {
    $script:CleanConsoleOutputEnabled = $false
    ${function:Write-LogLineToHost} = $realWriteLogLineToHostA2
}

Test-Assert ($totalsA2.ZippedSuccess -eq 1) "sanity check: the zip itself still succeeded with Clean Console Output on"
Test-Assert (@($script:hostLinesA2 | Where-Object { $_ -like "*Zipping*" -or $_ -like "*ZIP OK*" }).Count -eq 0) ("none of the worker's own 'Zipping'/'ZIP OK' lines reached the console while Clean Console Output was on (got " + $script:hostLinesA2.Count + " unrelated line(s))")
Write-Host ""

# ==============================================================================
#  Scenario A4 (2026-09-23): Zip Folders' CCR series grouping skips category
#  folders, same rule as New-SeriesProvider - 'Complete\Series Z' shows as
#  series 'Series Z' with its own 2-chapter total, not one 'Complete' series.
# ==============================================================================
Write-Host "=== Scenario A4: Zip Folders groups by the real series folder under a category ===" -ForegroundColor Cyan
$rootA4 = New-Dir "scenario-a4"
New-FileIn -DirPath (New-Dir "scenario-a4\Complete\Series Z\Chapter 1") -Name "page1.jpg" | Out-Null
New-FileIn -DirPath (New-Dir "scenario-a4\Complete\Series Z\Chapter 2") -Name "page1.jpg" | Out-Null
$script:seriesStartsA4 = [System.Collections.Generic.List[string]]::new()
$realStartSeriesA4 = ${function:Start-SeriesProgress}
function Start-SeriesProgress {
    param([string]$SeriesName, [int]$TotalChapters)
    $script:seriesStartsA4.Add($SeriesName + ":" + $TotalChapters)
    & $realStartSeriesA4 -SeriesName $SeriesName -TotalChapters $TotalChapters
}
$script:CleanConsoleOutputEnabled = $true
try {
    $totalsA4 = Invoke-ZipOnlyPipeline -Path $rootA4 -MaxParallel 2 -DeleteFolders $true -PermanentDelete $true
} finally {
    $script:CleanConsoleOutputEnabled = $false
    ${function:Start-SeriesProgress} = $realStartSeriesA4
    $null = Complete-AllActiveSeriesProgress
}
Test-Assert ($totalsA4.ZippedSuccess -eq 2) ("sanity check: both chapters zipped (got " + $totalsA4.ZippedSuccess + ")")
Test-Assert (($script:seriesStartsA4 -join ",") -eq "Series Z:2") ("CCR got one series 'Series Z' with 2 chapters, not 'Complete' (got: " + ($script:seriesStartsA4 -join ",") + ")")
Write-Host ""

# ==============================================================================
#  Scenario A3 (2026-09-04 fix, real bug): mode 3's own worker had NO
#  orphaned-"_tmp_*"-scratch-file sweep at all, unlike Invoke-LooseFolderZip
#  (Scenario G2) and Invoke-FullPipelineChapter - a leftover scratch file
#  from an earlier force-killed conversion run got permanently archived
#  into the .cbz as a junk page, with the source folder then deleted right
#  after.
# ==============================================================================
Write-Host "=== Scenario A3: mode 3's worker sweeps orphaned scratch files instead of archiving them ===" -ForegroundColor Cyan
$rootA3 = New-Dir "scenario-a3"
$leafA3 = New-Dir "scenario-a3\Chapter 1"
New-FileIn -DirPath $leafA3 -Name "page1.jxl" | Out-Null
New-FileIn -DirPath $leafA3 -Name "photo_tmp_iccstrip.png" | Out-Null
New-FileIn -DirPath $leafA3 -Name "photo_tmp_webp2png.png" | Out-Null
New-FileIn -DirPath $leafA3 -Name "photo_tmp_overwrite.webp" | Out-Null

$totalsA3 = Invoke-ZipOnlyPipeline -Path $rootA3 -MaxParallel 2 -DeleteFolders $true -PermanentDelete $true

Test-Assert ($totalsA3.ZippedSuccess -eq 1) ("the chapter still zipped successfully (got ZippedSuccess=" + $totalsA3.ZippedSuccess + ")")
$zipA3 = Join-Path $rootA3 "Chapter 1.zip"
Test-Assert (Test-Path -LiteralPath $zipA3) "the zip file exists"
if (Test-Path -LiteralPath $zipA3) {
    $archiveA3 = [System.IO.Compression.ZipFile]::OpenRead($zipA3)
    try { $entryNamesA3 = @($archiveA3.Entries | ForEach-Object { $_.Name }) }
    finally { $archiveA3.Dispose() }
    Test-Assert (@($entryNamesA3 | Where-Object { $_ -match '_tmp_' }).Count -eq 0) ("none of the 3 scratch files were archived into the zip (got entries: " + ($entryNamesA3 -join ", ") + ")")
    Test-Assert ($entryNamesA3 -contains "page1.jxl") "the real .jxl entry is still there"
}
Write-Host ""

# ==============================================================================
#  Scenario B: no qualifying leaf directories - all totals stay zero, a
#  clear warning is logged, no error.
# ==============================================================================
Write-Host "=== Scenario B: no candidates found ===" -ForegroundColor Cyan
$rootB = New-Dir "scenario-b-empty"

$totalsB = Invoke-ZipOnlyPipeline -Path $rootB -MaxParallel 2 -PermanentDelete $true
Test-Assert ($totalsB.CandidateCount -eq 0) "0 candidates found in an empty tree"
Test-Assert ($totalsB.ZippedSuccess -eq 0 -and $totalsB.ZippedFail -eq 0) "no zip attempts were made"
Write-Host ""

# ==============================================================================
#  Scenario B2 (2026-09-15 fix, real bug): an abort BEFORE any candidate
#  is found must be reported as an abort, not as "no qualifying leaf
#  directories found" (the same message a genuinely empty library gets)
#  - the two are different problems that need different next steps from
#  the user. [ConsoleCtrl]::AbortRequested pre-signalled so the scan
#  never gets a chance to find the one real candidate present.
# ==============================================================================
Write-Host "=== Scenario B2: an abort before any candidate is found reports Aborted, not empty ===" -ForegroundColor Cyan
$rootB2 = New-Dir "scenario-b2"

[ConsoleCtrl]::AbortRequested = $true
[ConsoleCtrl]::DrainComplete.Set()
try {
    $totalsB2 = Invoke-ZipOnlyPipeline -Path $rootB2 -MaxParallel 2 -PermanentDelete $true
} finally {
    Reset-AbortState
}
Test-Assert ($totalsB2.CandidateCount -eq 0) "sanity check: the abort really did prevent the one real candidate from being counted"
Test-Assert ($totalsB2.Aborted -eq $true) "the run correctly reports Aborted = `$true, not just a silent 0-candidate result"
$abortedLineB2 = @(Get-Content -LiteralPath $script:logWarnFile | Where-Object { $_ -like "*aborted before any leaf directory*" })
Test-Assert ($abortedLineB2.Count -ge 1) "the log reports the run was aborted before finding anything, not the generic 'no qualifying leaf directories found' message an empty library gets"
Write-Host ""

# ==============================================================================
#  Scenario C: -DeleteFolders $false - zips are created but source
#  folders are left alone.
# ==============================================================================
Write-Host "=== Scenario C: -DeleteFolders `$false leaves sources intact ===" -ForegroundColor Cyan
$rootC = New-Dir "scenario-c"
$leafC = New-Dir "scenario-c\Chapter 1"
New-FileIn -DirPath $leafC -Name "page1.jpg" | Out-Null

$totalsC = Invoke-ZipOnlyPipeline -Path $rootC -MaxParallel 2 -DeleteFolders $false -PermanentDelete $true
Test-Assert ($totalsC.ZippedSuccess -eq 1) "the folder was zipped"
Test-Assert ($totalsC.FolderDeletedSuccess -eq 0 -and $totalsC.FolderDeletedFail -eq 0) "no delete was attempted at all"
Test-Assert (Test-Path -LiteralPath $leafC) "the source folder still exists"
Write-Host ""

# ==============================================================================
#  Scenario P: a folder holding an .avif and its non-empty same-basename
#  .webp (animated originals kept) is not zipped or deleted - same rule as
#  Full Pipeline. Controls: .webp only, .avif only, and an .avif with a
#  0-byte .webp (a killed conversion, not a real pair) all still zip.
# ==============================================================================
Write-Host "=== Scenario P: an .avif/.webp pair blocks Zip Folders; controls still zip ===" -ForegroundColor Cyan
$rootP = New-Dir "scenario-p"
$pairP  = New-Dir "scenario-p\Series\Pair"
New-FileIn -DirPath $pairP -Name "page1.jpg" | Out-Null
[System.IO.File]::WriteAllText((Join-Path $pairP "anim.avif"), "avif")
[System.IO.File]::WriteAllText((Join-Path $pairP "anim.webp"), "webp")
$webpOnlyP = New-Dir "scenario-p\Series\Webp Only"
New-FileIn -DirPath $webpOnlyP -Name "page1.jpg" | Out-Null
[System.IO.File]::WriteAllText((Join-Path $webpOnlyP "anim.webp"), "webp")
$avifOnlyP = New-Dir "scenario-p\Series\Avif Only"
New-FileIn -DirPath $avifOnlyP -Name "page1.jpg" | Out-Null
[System.IO.File]::WriteAllText((Join-Path $avifOnlyP "anim.avif"), "avif")
$emptyWebpP = New-Dir "scenario-p\Series\Empty Webp"
New-FileIn -DirPath $emptyWebpP -Name "page1.jpg" | Out-Null
[System.IO.File]::WriteAllText((Join-Path $emptyWebpP "anim.avif"), "avif")
[System.IO.File]::WriteAllBytes((Join-Path $emptyWebpP "anim.webp"), [byte[]]@())

$totalsP = Invoke-ZipOnlyPipeline -Path $rootP -MaxParallel 2 -DeleteFolders $true -PermanentDelete $true
Test-Assert (-not (Test-Path -LiteralPath ($pairP + ".zip")) -and (Test-Path -LiteralPath (Join-Path $pairP "anim.avif")) -and (Test-Path -LiteralPath (Join-Path $pairP "anim.webp"))) "a folder with an .avif/.webp pair is not zipped, and the folder is left alone"
Test-Assert ((Test-Path -LiteralPath ($webpOnlyP + ".zip")) -and -not (Test-Path -LiteralPath $webpOnlyP)) "control: .webp only still zips"
Test-Assert ((Test-Path -LiteralPath ($avifOnlyP + ".zip")) -and -not (Test-Path -LiteralPath $avifOnlyP)) "control: .avif only still zips"
Test-Assert ((Test-Path -LiteralPath ($emptyWebpP + ".zip")) -and -not (Test-Path -LiteralPath $emptyWebpP)) "control: an .avif with a 0-byte .webp still zips (not a real pair)"
Test-Assert ($totalsP.PairBlocked -eq 1 -and $totalsP.ZippedSuccess -eq 3 -and $totalsP.ZippedFail -eq 0) ("totals: 1 pair-blocked, 3 zipped, 0 failed (got " + $totalsP.PairBlocked + " / " + $totalsP.ZippedSuccess + " / " + $totalsP.ZippedFail + ")")
$statusP, $detailP = Get-ZipChapterProgressStatus -ZipResult @{ Success = 0; Failed = 0; FolderDeleted = 0; FolderDeleteFailed = 0; Cancelled = 0; PairBlocked = 1 }
Test-Assert ($statusP -eq "Warning" -and $detailP -eq "zip skipped: animated originals kept (.avif and .webp both present)") ("a pair-blocked folder shows as a Warning with Full Pipeline's wording (got " + $statusP + " / " + $detailP + ")")
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

$totalsD = Invoke-ZipOnlyPipeline -Path $rootD -MaxParallel 2 -PermanentDelete $true
Test-Assert ($totalsD.CandidateCount -eq 0) "the up-to-date leaf was excluded before even reaching the zip step"
Write-Host ""

# ==============================================================================
#  Scenario D2 (2026-08-31 fix, caught by a same-day /code-review
#  full-codebase pass): with Clean Console Output OFF (the default), the
#  -NextJobProvider closure's per-series chapter-count side-scan (a
#  SECOND, bounded Get-ZippableLeafDirs walk, purely to feed
#  Start-CcrSeriesProgressIfEnabled's -TotalChapters - which itself no-ops
#  when CCR is off) used to run unconditionally anyway, duplicating every
#  Test-ZippableLeafDirCandidate skip-reason Warn the FIRST (real,
#  incremental) scan already logged. A series with one up-to-date leaf
#  (triggers a real skip Warn) and one real leaf must log that Warn
#  exactly ONCE, not twice, with CCR off.
# ==============================================================================
Write-Host "=== Scenario D2: the CCR-only side-scan does not double-log skip warnings when Clean Console Output is off ===" -ForegroundColor Cyan
$rootD2 = New-Dir "scenario-d2"
$leafD2Real = New-Dir "scenario-d2\Series\Chapter 1"
New-FileIn -DirPath $leafD2Real -Name "page1.jpg" | Out-Null
$leafD2Stale = New-Dir "scenario-d2\Series\Chapter 2"
New-FileIn -DirPath $leafD2Stale -Name "page1.jpg" | Out-Null
$zipOutD2 = Join-Path (Split-Path -Parent $leafD2Stale) "Chapter 2.zip"
"fake pre-existing zip" | Out-File -FilePath $zipOutD2 -Encoding UTF8
(Get-Item -LiteralPath $zipOutD2).LastWriteTimeUtc = (Get-Date).ToUniversalTime()

Test-Assert (-not $script:CleanConsoleOutputEnabled) "sanity check: Clean Console Output is off (the default) for this scenario"
$totalsD2 = Invoke-ZipOnlyPipeline -Path $rootD2 -MaxParallel 2 -PermanentDelete $true
$warnLinesD2 = @(Get-Content -LiteralPath $script:logWarnFile | Where-Object { $_ -like "*Chapter 2*" -and $_ -like "*up to date*" })
Test-Assert ($totalsD2.CandidateCount -eq 1) "only the one real leaf was a candidate, the up-to-date one excluded"
Test-Assert ($warnLinesD2.Count -eq 1) ("the up-to-date-zip skip Warn was logged exactly once, not duplicated by the CCR-only side-scan (got " + $warnLinesD2.Count + ")")
Write-Host ""

# ==============================================================================
#  Scenario D3 (2026-09-03 fix, Todo.md finding): the CCR series-name
#  derivation used to blindly Substring $next.Dir.FullName by
#  $trimmedPath's length with no check the prefix actually matches. A
#  -Path ending in a literal "\." segment makes $trimmedPath keep that
#  "\." (TrimEnd only strips a trailing separator, and "." isn't one) -
#  .NET path resolution treats "\." as "this same directory" internally
#  (the scan still works normally), but the un-resolved $Path STRING no
#  longer matches $next.Dir.FullName's own fully-resolved prefix
#  character-for-character, guaranteeing the exact mismatch this fix
#  guards - without depending on Push-Location (which changes PowerShell's
#  own $PWD, not the process's real current directory .NET path APIs
#  actually resolve relative paths against - the exact class of gotcha
#  CLAUDE.md's "Lessons learned" warns about, confirmed live: an earlier
#  draft of this test used a relative -Path and found zero candidates).
#  Must degrade to the leaf's own folder name (with a Warn explaining why)
#  instead of mis-slicing into a bogus name or throwing - and the actual
#  zip must still succeed either way, since this is CCR display only.
# ==============================================================================
Write-Host "=== Scenario D3: a Path whose literal string doesn't match FullName's prefix degrades gracefully, doesn't mis-slice or crash ===" -ForegroundColor Cyan
$rootD3 = New-Dir "scenario-d3"
$leafD3 = New-Dir "scenario-d3\Series\Chapter 1"
New-FileIn -DirPath $leafD3 -Name "page1.jpg" | Out-Null

$script:CleanConsoleOutputEnabled = $true
try {
    $totalsD3 = Invoke-ZipOnlyPipeline -Path ($rootD3 + "\.") -MaxParallel 2 -PermanentDelete $true
} finally {
    $script:CleanConsoleOutputEnabled = $false
}

Test-Assert ($totalsD3.ZippedSuccess -eq 1) "the actual zip still succeeded despite the Path/FullName mismatch - CCR series-name derivation is display-only"
$mismatchWarnD3 = @(Get-Content -LiteralPath $script:logWarnFile | Where-Object { $_ -like "*does not start with the scan root*" })
Test-Assert ($mismatchWarnD3.Count -ge 1) "a Warn was logged explaining the prefix mismatch, instead of silently mis-slicing"
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

$totalsE = Invoke-ZipOnlyPipeline -Path $rootE -MaxParallel 2 -PermanentDelete $true
Test-Assert ($totalsE.CandidateCount -eq 0) "'Only Images' (zero subdirs, only .zip files) was never a zip candidate through the full pipeline"
Test-Assert (Test-Path -LiteralPath (Join-Path $onlyImagesE "08 - Chapter 8.zip")) "the existing chapter zips were left completely untouched"
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
    $totalsI = Invoke-ZipOnlyPipeline -Path $rootI -MaxParallel 2 -PermanentDelete $true
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
    $totalsJ = Invoke-ZipOnlyPipeline -Path $rootJ -MaxParallel 2 -PermanentDelete $true
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
    $totalsK = Invoke-ZipOnlyPipeline -Path $rootK -MaxParallel 2 -PermanentDelete $true
} finally {
    $script:CleanConsoleOutputEnabled = $false
    $lockK.Dispose()
}

Test-Assert ($totalsK.ZippedFail -eq 1) ("the forced zip failure was counted (got ZippedFail=" + $totalsK.ZippedFail + ")")
Test-Assert ($script:ccrActiveSeries.Count -eq 0) "the series still resolved (as an issue, not left hanging) after a real zip failure"

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
#  Scenario Q (2026-10-12): the zip worker does not delete the source folder
#  once an abort is in. A force-stopped worker that was stuck inside the zip
#  call is no longer waited for, so it can finish that zip after the run has
#  already returned - this check is what stops it going on to delete the
#  folder unreported. Test-ZipArchive is swapped to cancel the token at the
#  exact point between "zip verified" and the delete step.
# ==============================================================================
Write-Host "=== Scenario Q: an abort that lands mid-zip leaves the source folder in place ===" -ForegroundColor Cyan
$rootQ = New-Dir "scenario-q"
$leafQ = New-Dir "scenario-q\Chapter 1"
New-FileIn -DirPath $leafQ -Name "page1.jpg" | Out-Null
$ctsQ = [System.Threading.CancellationTokenSource]::new()
$queueQ = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$origTestZipArchiveQ = ${function:Test-ZipArchive}
try {
    function Test-ZipArchive {
        param($ZipPath, $RequireJxlEntry)
        $ctsQ.Cancel()
        return (& $origTestZipArchiveQ -ZipPath $ZipPath -RequireJxlEntry $RequireJxlEntry)
    }
    $resultQ = & $script:zipOnlyWorker -FolderPath $leafQ -ZipOutPath ($leafQ + ".zip") -SeriesName "scenario-q" -DeleteFolders $true `
        -DoPermanentDelete $true -LogMutex $null -ConsoleQueue $queueQ -CancelToken $ctsQ.Token
} finally {
    ${function:Test-ZipArchive} = $origTestZipArchiveQ
    $script:workerConsoleQueue = $null
    $ctsQ.Dispose()
}
Test-Assert ($resultQ.Success -eq 1) "the zip itself finished and verified"
Test-Assert (Test-Path -LiteralPath ($leafQ + ".zip")) "the zip is on disk"
Test-Assert ($resultQ.FolderDeleted -eq 0 -and $resultQ.FolderDeleteFailed -eq 0 -and (Test-Path -LiteralPath $leafQ)) "the source folder was not deleted"
Test-Assert (@($queueQ.ToArray() | Where-Object { $_.Level -eq "Warn" -and $_.Message -like "*left the source folder in place*" }).Count -eq 1) "the log says why the folder was left"
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
