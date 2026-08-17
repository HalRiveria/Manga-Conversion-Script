<#
.SYNOPSIS
    Standalone test harness for Modules\LeafDirectoryDiscovery.ps1.

.DESCRIPTION
    Dot-sources the real module and exercises it against real folders -
    not mocked I/O. Write-Log is a FORWARD REFERENCE this module expects
    from Logging.ps1 - stubbed here since LeafDirectoryDiscovery must
    stay standalone-testable without it.

    Scenario K/L reproduce the "parent/container folder" bug documented
    in CHANGELOG.md's former-container guard entry, using a folder shape
    modeled directly on the real examples in Backups\Test Images\Only
    Images (before: chapter subfolders full of images) and
    Backups\Rezip Tests\Only Images (after: chapter subfolders zipped and
    removed, leaving only .zip files at the series level) - not touching
    Backups itself, which is off-limits to every script by design; this
    harness builds its own equivalent shape in a scratch temp directory.
    CHANGELOG.md's own note says the guard's fix was "best-reasoned...
    not a confirmed root-cause diagnosis - the exact mechanism wasn't
    reproduced" - this is the first live reproduction and confirmation.

.EXAMPLE
    .\Modules\_Harness\LeafDirectoryDiscovery.Harness.ps1
#>

$ErrorActionPreference = "Stop"

$script:logMessages = [System.Collections.Generic.List[string]]::new()
function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $script:logMessages.Add($Message)
    Write-Host ("  [log:" + $Level + "] " + $Message) -ForegroundColor DarkGray
}

. (Join-Path $PSScriptRoot "..\LeafDirectoryDiscovery.ps1")

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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("leafdiscovery-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray
Write-Host ""

$imgExts = @(".jpg", ".png", ".jxl")

function New-Dir {
    param([string]$RelativePath)
    $path = Join-Path $scratchDir $RelativePath
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}
function New-FileIn {
    param([string]$DirPath, [string]$Name, [Nullable[datetime]]$LastWriteTimeUtc = $null)
    $path = Join-Path $DirPath $Name
    "content" | Out-File -FilePath $path -Encoding UTF8
    if ($LastWriteTimeUtc) { (Get-Item -LiteralPath $path).LastWriteTimeUtc = $LastWriteTimeUtc }
    return $path
}

# ==============================================================================
#  Scenario A: basic - one leaf dir with qualifying files is found
# ==============================================================================
Write-Host "=== Scenario A: basic leaf discovery ===" -ForegroundColor Cyan
$rootA = New-Dir "scenario-a"
$leafA = New-Dir "scenario-a\Chapter 1"
New-FileIn -DirPath $leafA -Name "page1.jpg" | Out-Null

$resultA = Get-ZippableLeafDirs -ScanPath $rootA -QualifyingExtensions $imgExts
Test-Assert ($resultA.Count -eq 1) ("exactly 1 leaf found (got " + $resultA.Count + ")")
Test-Assert ($resultA[0].Dir.FullName -eq $leafA) "the found leaf's Dir matches the actual folder"
Test-Assert ($resultA[0].ZipOut -eq (Join-Path $rootA "Chapter 1.zip")) "ZipOut is correctly placed in the leaf's PARENT directory"
Write-Host ""

# ==============================================================================
#  Scenario B: a folder with subdirectories is NOT a leaf, even if it also
#  has qualifying files directly inside it.
# ==============================================================================
Write-Host "=== Scenario B: non-leaf (has subdirs) is excluded ===" -ForegroundColor Cyan
$rootB    = New-Dir "scenario-b"
$parentB  = New-Dir "scenario-b\Series"
New-FileIn -DirPath $parentB -Name "stray.jpg" | Out-Null   # qualifying file directly in the non-leaf
$childB   = New-Dir "scenario-b\Series\Chapter 1"
New-FileIn -DirPath $childB -Name "page1.jpg" | Out-Null

$resultB = Get-ZippableLeafDirs -ScanPath $rootB -QualifyingExtensions $imgExts
Test-Assert ($resultB.Count -eq 1) ("only the true leaf (Chapter 1) was found, not the parent (got " + $resultB.Count + ")")
Test-Assert ($resultB[0].Dir.FullName -eq $childB) "the one result is the leaf, not the non-leaf parent"
Write-Host ""

# ==============================================================================
#  Scenario C: former-container guard - a leaf-shaped dir containing an
#  existing .zip (and no qualifying files) is skipped, with a Warn log.
# ==============================================================================
Write-Host "=== Scenario C: former-container guard (basic) ===" -ForegroundColor Cyan
$rootC = New-Dir "scenario-c"
$dirC  = New-Dir "scenario-c\Old Chapter"
New-FileIn -DirPath $dirC -Name "Old Chapter.zip" | Out-Null
$script:logMessages.Clear()

$resultC = Get-ZippableLeafDirs -ScanPath $rootC -QualifyingExtensions $imgExts
Test-Assert ($resultC.Count -eq 0) "a folder containing only a .zip is not treated as a zip candidate"
Test-Assert (($script:logMessages | Where-Object { $_ -like "*SKIPPING*existing .zip*" }).Count -eq 1) "a Warn-level skip message was logged explaining why"
Write-Host ""

# ==============================================================================
#  Scenario D: no qualifying extensions present - silently skipped (empty
#  result for that dir, no warning - this is just "nothing to do" here,
#  not a container-guard case).
# ==============================================================================
Write-Host "=== Scenario D: no qualifying files - silently skipped ===" -ForegroundColor Cyan
$rootD = New-Dir "scenario-d"
$dirD  = New-Dir "scenario-d\Empty-ish"
New-FileIn -DirPath $dirD -Name "notes.txt" | Out-Null
$script:logMessages.Clear()

$resultD = Get-ZippableLeafDirs -ScanPath $rootD -QualifyingExtensions $imgExts
Test-Assert ($resultD.Count -eq 0) "a folder with no qualifying files produces no candidate"
Test-Assert ($script:logMessages.Count -eq 0) "no warning was logged - this isn't a container-guard case, just nothing to do"
Write-Host ""

# ==============================================================================
#  Scenario E: staleness check - existing zip newer than every qualifying
#  file is skipped (up to date already).
# ==============================================================================
Write-Host "=== Scenario E: staleness check skips an up-to-date zip ===" -ForegroundColor Cyan
$rootE = New-Dir "scenario-e"
$dirE  = New-Dir "scenario-e\Chapter 1"
$fileTimeE = (Get-Date).ToUniversalTime().AddHours(-2)
New-FileIn -DirPath $dirE -Name "page1.jpg" -LastWriteTimeUtc $fileTimeE | Out-Null
$zipOutE = Join-Path $rootE "Chapter 1.zip"
"fake zip" | Out-File -FilePath $zipOutE -Encoding UTF8
(Get-Item -LiteralPath $zipOutE).LastWriteTimeUtc = (Get-Date).ToUniversalTime()   # newer than the source file
$script:logMessages.Clear()

$resultE = Get-ZippableLeafDirs -ScanPath $rootE -QualifyingExtensions $imgExts
Test-Assert ($resultE.Count -eq 0) "an up-to-date zip means the leaf is not re-queued"
Test-Assert (($script:logMessages | Where-Object { $_ -like "*up to date*" }).Count -eq 1) "a Warn-level 'up to date' message was logged"
Write-Host ""

# ==============================================================================
#  Scenario F: staleness check - existing zip OLDER than a qualifying file
#  means the leaf IS re-queued (something changed since it was last zipped).
# ==============================================================================
Write-Host "=== Scenario F: staleness check re-includes a stale zip ===" -ForegroundColor Cyan
$rootF = New-Dir "scenario-f"
$dirF  = New-Dir "scenario-f\Chapter 1"
$zipOutF = Join-Path $rootF "Chapter 1.zip"
"fake zip" | Out-File -FilePath $zipOutF -Encoding UTF8
(Get-Item -LiteralPath $zipOutF).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-2)
New-FileIn -DirPath $dirF -Name "page1.jpg" -LastWriteTimeUtc ((Get-Date).ToUniversalTime()) | Out-Null   # newer than the zip

$resultF = Get-ZippableLeafDirs -ScanPath $rootF -QualifyingExtensions $imgExts
Test-Assert ($resultF.Count -eq 1) "a zip older than its source file means the leaf IS re-queued for zipping"
Write-Host ""

# ==============================================================================
#  Scenario G: -ForceRezip bypasses the staleness check even when the zip
#  is genuinely newer than every source file.
# ==============================================================================
Write-Host "=== Scenario G: -ForceRezip bypasses staleness ===" -ForegroundColor Cyan
$rootG = New-Dir "scenario-g"
$dirG  = New-Dir "scenario-g\Chapter 1"
$fileTimeG = (Get-Date).ToUniversalTime().AddHours(-2)
New-FileIn -DirPath $dirG -Name "page1.jpg" -LastWriteTimeUtc $fileTimeG | Out-Null
$zipOutG = Join-Path $rootG "Chapter 1.zip"
"fake zip" | Out-File -FilePath $zipOutG -Encoding UTF8
(Get-Item -LiteralPath $zipOutG).LastWriteTimeUtc = (Get-Date).ToUniversalTime()

$resultGNoForce = Get-ZippableLeafDirs -ScanPath $rootG -QualifyingExtensions $imgExts -ForceRezip $false
$resultGForce   = Get-ZippableLeafDirs -ScanPath $rootG -QualifyingExtensions $imgExts -ForceRezip $true
Test-Assert ($resultGNoForce.Count -eq 0) "without -ForceRezip, an up-to-date zip is still skipped (sanity check)"
Test-Assert ($resultGForce.Count -eq 1) "-ForceRezip `$true includes the leaf even though its zip is newer than the source"
Write-Host ""

# ==============================================================================
#  Scenario H: -ExcludeStagingDirs excludes a directory (and would exclude
#  anything under it) even though it would otherwise qualify.
# ==============================================================================
Write-Host "=== Scenario H: -ExcludeStagingDirs excludes a matching leaf ===" -ForegroundColor Cyan
$rootH   = New-Dir "scenario-h"
$stageH  = New-Dir "scenario-h\_staging"
New-FileIn -DirPath $stageH -Name "page1.jpg" | Out-Null
$normalH = New-Dir "scenario-h\Chapter 1"
New-FileIn -DirPath $normalH -Name "page1.jpg" | Out-Null
$excludeSetH = [System.Collections.Generic.HashSet[string]]::new()
$null = $excludeSetH.Add($stageH)

$resultH = Get-ZippableLeafDirs -ScanPath $rootH -QualifyingExtensions $imgExts -ExcludeStagingDirs $excludeSetH
Test-Assert ($resultH.Count -eq 1) ("only the non-staging leaf was found (got " + $resultH.Count + ")")
Test-Assert ($resultH[0].Dir.FullName -eq $normalH) "the one result is the normal chapter, not the staging dir"
Write-Host ""

# ==============================================================================
#  Scenario I: 0-result case - return type must stay a real, enumerable
#  List[hashtable], NOT collapse to $null. This is the exact bug class
#  documented in CLAUDE.md's "Lessons learned" (already caught twice
#  elsewhere in this project) - checked by TYPE, not just truthiness,
#  since a naive `$result.Count -eq 0` could also be satisfied by $null
#  going through `@()`-wrapping at the call site and masking the bug.
# ==============================================================================
Write-Host "=== Scenario I: 0-result return type stays List[hashtable] ===" -ForegroundColor Cyan
$rootI = New-Dir "scenario-i-empty"
$resultI = Get-ZippableLeafDirs -ScanPath $rootI -QualifyingExtensions $imgExts
Test-Assert ($null -ne $resultI) "0-result return is NOT `$null"
Test-Assert ($resultI -is [System.Collections.Generic.List[hashtable]]) ("0-result return is still a real List[hashtable] (actual type: " + $resultI.GetType().FullName + ")")
Test-Assert ($resultI.Count -eq 0) "0-result Count is 0"
Write-Host ""

# ==============================================================================
#  Scenario J: 1-result case - return type must stay List[hashtable], NOT
#  collapse to a bare hashtable (the other half of the same bug class -
#  a 1-element collection is the specific shape that silently unwraps).
# ==============================================================================
Write-Host "=== Scenario J: 1-result return type stays List[hashtable] (not a bare hashtable) ===" -ForegroundColor Cyan
$rootJ = New-Dir "scenario-j-single"
$leafJ = New-Dir "scenario-j-single\Only Chapter"
New-FileIn -DirPath $leafJ -Name "page1.jpg" | Out-Null
$resultJ = Get-ZippableLeafDirs -ScanPath $rootJ -QualifyingExtensions $imgExts
Test-Assert ($resultJ -is [System.Collections.Generic.List[hashtable]]) ("1-result return is still a real List[hashtable], not a bare Hashtable (actual type: " + $resultJ.GetType().FullName + ")")
Test-Assert ($resultJ.Count -eq 1) "1-result Count is 1 (not silently missing via collapse)"
Test-Assert ($resultJ[0].Dir.FullName -eq $leafJ) "indexing [0] on the 1-result list still works correctly"
Write-Host ""

# ==============================================================================
#  Scenario K (user-requested, reproduces the CHANGELOG.md former-container
#  bug for real): a series folder ("Only Images") whose every chapter has
#  already been converted, zipped, and had its source folder removed -
#  modeled directly on Backups\Rezip Tests\Only Images's real shape (only
#  .zip files, zero subdirectories). Get-ZippableLeafDirs must NOT treat
#  "Only Images" itself as a zippable leaf - it would otherwise archive
#  all the already-created per-chapter .zip files into an unwanted wrapper
#  zip and (via the caller's later Remove-Source) delete the originals
#  along with them.
# ==============================================================================
Write-Host "=== Scenario K: former-container guard on a REAL post-completion series folder ===" -ForegroundColor Cyan
$rootK        = New-Dir "scenario-k"
$onlyImagesK  = New-Dir "scenario-k\Only Images"
New-FileIn -DirPath $onlyImagesK -Name "08 - Chapter 8.zip"  | Out-Null
New-FileIn -DirPath $onlyImagesK -Name "09 - Chapter 9.zip"  | Out-Null
New-FileIn -DirPath $onlyImagesK -Name "10 - Chapter 10.zip" | Out-Null
$script:logMessages.Clear()

$resultK = Get-ZippableLeafDirs -ScanPath $rootK -QualifyingExtensions $imgExts
Test-Assert ($resultK.Count -eq 0) "'Only Images' (zero subdirs, only .zip files inside) is NOT returned as a zip candidate"
Test-Assert (($script:logMessages | Where-Object { $_ -like "*Only Images*existing .zip*" }).Count -eq 1) "the skip was logged with a clear reason, not silently dropped"
Write-Host ("  (this is the first live reproduction of the bug CHANGELOG.md's former-container guard entry describes as 'not a confirmed root-cause diagnosis - the exact mechanism wasn't reproduced' - now confirmed fixed)") -ForegroundColor DarkGray
Write-Host ""

# ==============================================================================
#  Scenario L: mixed state - "Only Images" has TWO already-zipped chapters
#  (zip-only siblings, folders removed) AND ONE chapter not yet zipped
#  (a real leaf subfolder with images still inside). The still-pending
#  chapter must be found and zipped on its own; "Only Images" itself must
#  still be excluded (now doubly so: it has a subdirectory again, AND it
#  has .zip files directly inside it).
# ==============================================================================
Write-Host "=== Scenario L: mixed state - one pending chapter alongside already-zipped ones ===" -ForegroundColor Cyan
$rootL       = New-Dir "scenario-l"
$onlyImagesL = New-Dir "scenario-l\Only Images"
New-FileIn -DirPath $onlyImagesL -Name "01 - Chapter 1.zip" | Out-Null
New-FileIn -DirPath $onlyImagesL -Name "02 - Chapter 2.zip" | Out-Null
$pendingChapterL = New-Dir "scenario-l\Only Images\03 - Chapter 3"
New-FileIn -DirPath $pendingChapterL -Name "page1.jpg" | Out-Null
$script:logMessages.Clear()

$resultL = Get-ZippableLeafDirs -ScanPath $rootL -QualifyingExtensions $imgExts
Test-Assert ($resultL.Count -eq 1) ("exactly the 1 still-pending chapter was found (got " + $resultL.Count + ")")
Test-Assert ($resultL[0].Dir.FullName -eq $pendingChapterL) "the found leaf is the pending chapter, not 'Only Images' itself"
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
