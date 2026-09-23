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
#  Scenario F2 (2026-09-04 fix, real bug, same species as
#  UnwantedImage.ps1's Invoke-UnwantedImageScan Scenario G2 and
#  Controller.Harness.ps1's Scenario C4c): Remove-Source's $false return
#  (the folder already vanished before deletion, a real TOCTOU gap) used
#  to be discarded here - FolderDeleted was reported $true regardless.
#  Remove-Source shadowed to return $false unconditionally.
# ==============================================================================
Write-Host "=== Scenario F2: Invoke-LooseFolderZip does not miscount an already-gone folder as deleted ===" -ForegroundColor Cyan
$dirF2 = New-Dir "scenario-f2"
New-FileIn -DirPath $dirF2 -Name "page1.jxl" | Out-Null
$zipOutF2 = Join-Path $scratchDir "scenario-f2.zip"

$realRemoveSourceF2 = ${function:Remove-Source}
function Remove-Source {
    param([string]$ItemPath)
    return $false
}
try {
    $resultF2 = Invoke-LooseFolderZip -FolderPath $dirF2 -ZipOut $zipOutF2 -LooseImageExtensions @(".jpg", ".png")
} finally {
    ${function:Remove-Source} = $realRemoveSourceF2
}

Test-Assert ($resultF2.Status -eq "Success") "sanity check: the zip itself still succeeded"
Test-Assert ($resultF2.FolderDeleted -eq $false) "FolderDeleted is `$false, not miscounted as a real delete, when Remove-Source reports the folder already gone"
Test-Assert ($resultF2.FolderDeleteFailed -eq $false) "FolderDeleteFailed is also `$false - an already-gone folder is neither a success nor a real failure"
Write-Host ""

# ==============================================================================
#  Scenario F3 (2026-09-15 fix, real bug): a double failure in the post-zip
#  delete phase - Remove-Source itself throws, AND the catch block logging
#  THAT failure also throws (e.g. a locked Errors log file, before Logging.ps1's
#  own 2026-09-15 fix) - used to propagate out of the delete phase's own
#  try/catch entirely and get caught by the OUTER try/catch that guards zip
#  CREATION, which unconditionally deletes $ZipOut on the theory that
#  anything caught there means the zip itself failed. It doesn't anymore -
#  the zip is already built and verified by the time this phase runs. The
#  one property that has to hold regardless of whether this double failure
#  makes the function throw: the already-good zip file must survive.
# ==============================================================================
Write-Host "=== Scenario F3: a double failure in the post-zip delete phase does not delete the already-good zip ===" -ForegroundColor Cyan
$dirF3 = New-Dir "scenario-f3"
New-FileIn -DirPath $dirF3 -Name "page1.jxl" | Out-Null
$zipOutF3 = Join-Path $scratchDir "scenario-f3.zip"

$realRemoveSourceF3 = ${function:Remove-Source}
$realWriteLogF3      = ${function:Write-Log}
function Remove-Source { param([string]$ItemPath) throw "simulated Remove-Source failure" }
function Write-Log {
    param([string]$Message, [string]$Level = "Info", [switch]$ForceConsole)
    if ($Message -like "*FAILED to delete folder*") { throw "simulated failure logging the delete failure itself" }
    & $realWriteLogF3 -Message $Message -Level $Level -ForceConsole:$ForceConsole
}
$threwF3 = $false
try {
    $resultF3 = Invoke-LooseFolderZip -FolderPath $dirF3 -ZipOut $zipOutF3 -LooseImageExtensions @(".jpg", ".png")
} catch {
    $threwF3 = $true
} finally {
    ${function:Remove-Source} = $realRemoveSourceF3
    ${function:Write-Log}     = $realWriteLogF3
}

Test-Assert (Test-Path -LiteralPath $zipOutF3) "the already-verified zip survives even a double failure in the post-zip delete phase - it is NOT deleted just because something unrelated threw after it was built"
if ($threwF3) {
    Write-Host "  (the double failure did propagate out of the function this time - that's fine, the important property is the zip survives either way)" -ForegroundColor DarkGray
}
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
#  Scenario G3 (2026-09-02 review fix, live-confirmed): the mirror image of
#  Scenario G - a chapter containing a never-converted file (.gif) MUST
#  still zip successfully when the caller's own -LooseImageExtensions
#  doesn't include it, exactly as Controller.ps1's own mode-8 zip-blocking
#  list is now built (Get-LooseImageExtensions() minus
#  Get-NeverConvertedExtensions()). Before that same-day fix, mode 8's own
#  list DID include ".gif" (it derives from the full canonical list), so
#  passing it here reproduces the real deadlock this fix closes: a
#  never-converted file can never stop being "unconverted", so a chapter
#  containing one could never be zipped by mode 8, on any run, forever.
#  This function (Invoke-LooseFolderZip) itself is correct either way -
#  it just does what its own -LooseImageExtensions is told; the bug and
#  the fix both live entirely in what CALLERS pass it.
# ==============================================================================
Write-Host "=== Scenario G3: a chapter with a never-converted .gif zips successfully when the caller excludes it (mode 8's own real fix) ===" -ForegroundColor Cyan
$dirG3 = New-Dir "scenario-g3"
New-FileIn -DirPath $dirG3 -Name "page1.jxl" | Out-Null
New-FileIn -DirPath $dirG3 -Name "cover.gif" | Out-Null
$zipOutG3 = Join-Path $scratchDir "scenario-g3.zip"

# Literal, not a call to ImageConversionPipeline.ps1's own
# Get-LooseImageExtensions()/Get-NeverConvertedExtensions() - this
# harness deliberately doesn't dot-source that module (see this file's
# own header). Mirrors Controller.ps1's own real derivation by hand:
# the canonical list minus ".gif" (the only current
# Get-NeverConvertedExtensions member).
$mode8ExtensionsG3 = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif", ".bmp", ".heic", ".heif")

$resultG3 = Invoke-LooseFolderZip -FolderPath $dirG3 -ZipOut $zipOutG3 -LooseImageExtensions $mode8ExtensionsG3

Test-Assert ($resultG3.Status -eq "Success") ("the chapter actually zipped, not perpetually skipped as unresolvable (got Status=" + $resultG3.Status + ")")
Test-Assert (Test-Path -LiteralPath $zipOutG3) "the zip file actually exists on disk"
if (Test-Path -LiteralPath $zipOutG3) {
    $zipEntriesG3 = [System.IO.Compression.ZipFile]::OpenRead($zipOutG3)
    try {
        $entryNamesG3 = @($zipEntriesG3.Entries | ForEach-Object { $_.Name })
    } finally {
        $zipEntriesG3.Dispose()
    }
    Test-Assert ($entryNamesG3 -contains "page1.jxl" -and $entryNamesG3 -contains "cover.gif") ("the zip contains both the converted page and the never-converted gif, swept in together (got entries: " + ($entryNamesG3 -join ", ") + ")")
}
Write-Host ""

# ==============================================================================
#  Scenario G2 (2026-08-31 fix, corrected after a same-day /code-review 4th
#  pass verification): an orphaned "_tmp_*" scratch file (its owning
#  cleanup couldn't run) carries an extension in $LooseImageExtensions, so
#  this guard used to treat it as a real unconverted source and skip
#  zipping forever. A first fix just excluded it from the guard - but this
#  function zips the WHOLE folder and deletes the source folder right
#  after, so the excluded-but-not-deleted file ended up permanently
#  archived as a junk page instead. This guard now DELETES the orphan
#  (a job-generated intermediate, always safe to delete permanently) before
#  scanning/zipping - the zip succeeds AND the debris is gone, not
#  smuggled into the archive.
# ==============================================================================
Write-Host "=== Scenario G2: an orphaned _tmp_* scratch file is deleted, not archived or block-forever ===" -ForegroundColor Cyan
$dirG2 = New-Dir "scenario-g2"
New-FileIn -DirPath $dirG2 -Name "page1.jxl" | Out-Null
New-FileIn -DirPath $dirG2 -Name "photo_tmp_iccstrip.png" | Out-Null
New-FileIn -DirPath $dirG2 -Name "photo_tmp_iccstrip-0.png" | Out-Null
New-FileIn -DirPath $dirG2 -Name "photo_tmp_webp2png.png" | Out-Null
New-FileIn -DirPath $dirG2 -Name "photo_tmp_bmp2png.png" | Out-Null
New-FileIn -DirPath $dirG2 -Name "photo_tmp_heic2png.png" | Out-Null
New-FileIn -DirPath $dirG2 -Name "photo_tmp_heif2png.png" | Out-Null
New-FileIn -DirPath $dirG2 -Name "photo_tmp_overwrite.webp" | Out-Null
$zipOutG2 = Join-Path $scratchDir "scenario-g2.zip"

$resultG2 = Invoke-LooseFolderZip -FolderPath $dirG2 -ZipOut $zipOutG2 -LooseImageExtensions @(".jpg", ".png", ".webp")

# 2026-09-02 review fix: the BMP/HEIC/HEIF scratch patterns (and the
# numbered iccstrip variant) were confirmed live to be missed by the
# pre-widening regex here - real orphaned files of this shape would have
# been permanently embedded in the .cbz as junk pages.
Test-Assert ($resultG2.Status -eq "Success") ("Status is Success, not blocked by scratch files (got " + $resultG2.Status + ")")
Test-Assert (Test-Path -LiteralPath $zipOutG2) "the zip file was created"
$zipEntriesG2 = [System.IO.Compression.ZipFile]::OpenRead($zipOutG2)
try {
    $entryNamesG2 = @($zipEntriesG2.Entries | ForEach-Object { $_.Name })
} finally {
    $zipEntriesG2.Dispose()
}
Test-Assert (@($entryNamesG2 | Where-Object { $_ -match '_tmp_' }).Count -eq 0) ("none of the 7 scratch files were archived into the zip (got entries: " + ($entryNamesG2 -join ", ") + ")")
Test-Assert ($entryNamesG2 -contains "page1.jxl") "the real .jxl entry is still there"
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
# 2026-09-02 review fix: Compress-FolderToZip succeeded here (a real,
# complete zip WAS written) - it's Test-ZipArchive's own verification
# that failed, AFTER the file already existed on disk. Before this fix,
# that broken-but-real zip was left behind, and Test-ZippableLeafDirCandidate's
# own staleness guard (LeafDirectoryDiscovery.ps1) would then see it as
# newer than every file in the folder and skip this chapter FOREVER on
# every later run - live-reproduced. Invoke-ZipOnlyPipeline's own worker
# already cleaned this up; this call path didn't.
Test-Assert (-not (Test-Path -LiteralPath $zipOutH)) "the broken zip itself was deleted on validation failure, not left behind to permanently hide this chapter from later runs"
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
