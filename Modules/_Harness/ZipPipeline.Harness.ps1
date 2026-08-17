<#
.SYNOPSIS
    Standalone test harness for Modules\ZipPipeline.ps1.

.DESCRIPTION
    Unlike prior harnesses (mostly stubbed dependencies), this one dot-
    sources the REAL already-built dependency modules - FileDeletion.ps1,
    ZipCreation.ps1, ZipValidation.ps1, LeafDirectoryDiscovery.ps1,
    ZipParallelProcessing.ps1, and Logging.ps1 - since ZipPipeline.ps1 is
    an orchestration-tier module that composes all of them for real. This
    is closer to an integration test than the earlier pure-unit harnesses,
    appropriate for this tier. Only the dot-source ORDER matters (see
    ZipPipeline.ps1's own "IMPORTANT ordering note"): Logging.ps1 must be
    dot-sourced AFTER ZipParallelProcessing.ps1, or ZPP's stale inline
    Write-Log would silently win instead of Logging.ps1's real one.

.EXAMPLE
    .\Modules\_Harness\ZipPipeline.Harness.ps1
#>

$ErrorActionPreference = "Stop"

$modulesDir = Join-Path $PSScriptRoot ".."
. (Join-Path $modulesDir "FileDeletion.ps1")
. (Join-Path $modulesDir "ZipCreation.ps1")
. (Join-Path $modulesDir "ZipValidation.ps1")
. (Join-Path $modulesDir "LeafDirectoryDiscovery.ps1")
. (Join-Path $modulesDir "ZipParallelProcessing.ps1")
. (Join-Path $modulesDir "Logging.ps1")   # AFTER ZipParallelProcessing.ps1 - see header note
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

$totalsA = Invoke-ZipOnlyPipeline -Path $rootA -MaxParallel 2 -DeleteFolders $true -FullLogging $false -PermanentDelete $true

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

$totalsB = Invoke-ZipOnlyPipeline -Path $rootB -MaxParallel 2 -FullLogging $false -PermanentDelete $true
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

$totalsC = Invoke-ZipOnlyPipeline -Path $rootC -MaxParallel 2 -DeleteFolders $false -FullLogging $false -PermanentDelete $true
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

$totalsD = Invoke-ZipOnlyPipeline -Path $rootD -MaxParallel 2 -FullLogging $false -PermanentDelete $true
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

$totalsE = Invoke-ZipOnlyPipeline -Path $rootE -MaxParallel 2 -FullLogging $false -PermanentDelete $true
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
