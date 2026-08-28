<#
.SYNOPSIS
    Standalone test harness for Modules\UnwantedImage.ps1.

.DESCRIPTION
    Dot-sources the real module and stubs Write-Log/Remove-Source/
    $script:PermanentDelete (same pattern as
    ImageConversionPipeline.Harness.ps1). Builds REAL, readable PNG files
    via System.Drawing.Bitmap for dimension/hash matching - since a match
    is content-derived (SHA-256 of real bytes), profiles used in "Match"
    scenarios are built FROM a real generated file's own actual size/
    hash/dimensions, not invented.

.EXAMPLE
    .\Modules\_Harness\UnwantedImage.Harness.ps1
#>

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\UnwantedImage.ps1")

$script:logCalls = New-Object System.Collections.Generic.List[string]
function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $script:logCalls.Add($Level + ": " + $Message)
}

$script:removeSourceCalls = New-Object System.Collections.Generic.List[string]
$script:removeSourceShouldThrow = $false
$script:PermanentDelete = $true
function Remove-Source {
    param([string]$ItemPath)
    if ($script:removeSourceShouldThrow) { throw "simulated delete failure" }
    $script:removeSourceCalls.Add($ItemPath)
    if (Test-Path -LiteralPath $ItemPath) { Remove-Item -LiteralPath $ItemPath -Force }
    return $true
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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("unwantedimage-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray

function New-RealImage {
    <#
    .SYNOPSIS
        Builds a real, readable PNG at $Name with real pixel dimensions
        via System.Drawing.Bitmap - not a fake/placeholder file.
    #>
    param([string]$Name, [int]$Width = 40, [int]$Height = 20)
    $path = Join-Path $scratchDir $Name
    $parent = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $bitmap = New-Object System.Drawing.Bitmap($Width, $Height)
    try {
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bitmap.Dispose()
    }
    return (Get-Item -LiteralPath $path)
}

function New-ProfileFromRealFile {
    <#
    .SYNOPSIS
        Builds a profile that will genuinely MATCH $File - real size,
        real dimensions, real SHA-256 hash. Match tests need this since
        a hash can't be invented to match arbitrary content.
    #>
    param([System.IO.FileInfo]$File, [int]$Width, [int]$Height, [string]$Label = "Test Profile")
    return @{
        Label         = $Label
        Width         = $Width
        Height        = $Height
        SizeBytes     = $File.Length
        SizeTolerance = 0
        Hash          = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
    }
}

function New-NonImageFile {
    param([string]$Name, [string]$Content = "not an image")
    $path = Join-Path $scratchDir $Name
    $parent = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $path -Value $Content -Encoding UTF8
    return (Get-Item -LiteralPath $path)
}

Write-Host ""

# ==============================================================================
#  Scenario A: Get-UnwantedImageProfiles - fresh, independent, expected shape
# ==============================================================================
Write-Host "=== Scenario A: Get-UnwantedImageProfiles ===" -ForegroundColor Cyan
$profilesA1 = Get-UnwantedImageProfiles
$profilesA2 = Get-UnwantedImageProfiles
$profilesA1[0].Label = "mutated"
Test-Assert ($profilesA2[0].Label -eq "Cover") "mutating one call's result does not affect a second call's result"
Test-Assert ($profilesA2.Count -eq 5) "five known profiles (v1-v5)"
Test-Assert (@($profilesA2 | Where-Object { $_.Width -eq 3000 -and $_.Height -eq 1500 }).Count -eq 5) "all five share the expected 3000x1500 dimensions"
Write-Host ""

# ==============================================================================
#  Scenario B: Get-ImageDimensions - real success and real failure
# ==============================================================================
Write-Host "=== Scenario B: Get-ImageDimensions ===" -ForegroundColor Cyan
$imgB = New-RealImage -Name "dims-b.png" -Width 123 -Height 45
$w = $null; $h = $null
$okB = Get-ImageDimensions -Path $imgB.FullName -OutWidth ([ref]$w) -OutHeight ([ref]$h)
Test-Assert ($okB -eq $true -and $w -eq 123 -and $h -eq 45) "reads real pixel dimensions from a real PNG"

$nonImgB = New-NonImageFile -Name "notimage-b.jpg"
$w2 = $null; $h2 = $null
$threwB = $false
$okB2 = $false
try { $okB2 = Get-ImageDimensions -Path $nonImgB.FullName -OutWidth ([ref]$w2) -OutHeight ([ref]$h2) } catch { $threwB = $true }
Test-Assert (-not $threwB -and $okB2 -eq $false) "a non-image file returns `$false, does not throw"
Write-Host ""

# ==============================================================================
#  Scenario C: Test-UnwantedImageMatch - Match, HashMismatch, NoMatch
#  (size out of tolerance, dimension mismatch, non-image file)
# ==============================================================================
Write-Host "=== Scenario C: Test-UnwantedImageMatch ===" -ForegroundColor Cyan
$imgC = New-RealImage -Name "match-c.png" -Width 50 -Height 30
$profileC = New-ProfileFromRealFile -File $imgC -Width 50 -Height 30
$resultC1 = Test-UnwantedImageMatch -File $imgC -Profiles @($profileC)
Test-Assert ($resultC1.Status -eq 'Match' -and $resultC1.Profile.Label -eq 'Test Profile') "a real size+dimensions+hash match returns Match"

$badHashProfileC = $profileC.Clone()
$badHashProfileC.Hash = "0000000000000000000000000000000000000000000000000000000000000000"
$resultC2 = Test-UnwantedImageMatch -File $imgC -Profiles @($badHashProfileC)
Test-Assert ($resultC2.Status -eq 'HashMismatch') "size+dimensions match but hash differs -> HashMismatch"

$badSizeProfileC = $profileC.Clone()
$badSizeProfileC.SizeBytes = $profileC.SizeBytes + 999999
$badSizeProfileC.SizeTolerance = 0
$resultC3 = Test-UnwantedImageMatch -File $imgC -Profiles @($badSizeProfileC)
Test-Assert ($resultC3.Status -eq 'NoMatch') "size far outside tolerance -> NoMatch (never reaches dimension/hash check)"

$badDimProfileC = $profileC.Clone()
$badDimProfileC.Width = 9999
$resultC4 = Test-UnwantedImageMatch -File $imgC -Profiles @($badDimProfileC)
Test-Assert ($resultC4.Status -eq 'NoMatch') "correct size but wrong dimensions -> NoMatch"

$nonImgC = New-NonImageFile -Name "notimage-c.jpg" -Content "x" * 100
$profileNonImgC = @{ Label = "N/A"; Width = 1; Height = 1; SizeBytes = $nonImgC.Length; SizeTolerance = 0; Hash = "irrelevant" }
$resultC5 = Test-UnwantedImageMatch -File $nonImgC -Profiles @($profileNonImgC)
Test-Assert ($resultC5.Status -eq 'NoMatch') "a non-image file (dimension read fails) -> NoMatch, no throw"
Write-Host ""

# ==============================================================================
#  Scenario D: Invoke-UnwantedImageScan end-to-end - matched file deleted,
#  hash-mismatch file logged but not deleted, non-matching file untouched
# ==============================================================================
Write-Host "=== Scenario D: end-to-end scan ===" -ForegroundColor Cyan
$rootD = Join-Path $scratchDir "scenario-d"
New-Item -ItemType Directory -Path $rootD -Force | Out-Null

# Distinct dimensions per file (not just distinct labels) so the two
# real generated images can never cross-match each other's profile -
# two blank same-size bitmaps saved as PNG are byte-identical, which
# would otherwise make "the mismatch file" actually match the FIRST
# profile in the list before ever reaching its own mismatch case.
$matchImgD = New-RealImage -Name "scenario-d\match.png" -Width 60 -Height 40
$matchProfileD = New-ProfileFromRealFile -File $matchImgD -Width 60 -Height 40 -Label "Matched Target"

$mismatchImgD = New-RealImage -Name "scenario-d\mismatch.png" -Width 61 -Height 41
$mismatchProfileD = New-ProfileFromRealFile -File $mismatchImgD -Width 61 -Height 41 -Label "Mismatch Target"
$mismatchProfileD.Hash = "1111111111111111111111111111111111111111111111111111111111111111"

$unrelatedImgD = New-RealImage -Name "scenario-d\unrelated.png" -Width 5 -Height 5

$script:removeSourceCalls.Clear()
$script:logCalls.Clear()
$resultD = Invoke-UnwantedImageScan -Path $rootD -Profiles @($matchProfileD, $mismatchProfileD)

Test-Assert ($resultD.ScannedCount -eq 3) "all 3 images scanned"
Test-Assert ($resultD.DeletedCount -eq 1) "exactly 1 deleted (the real match)"
Test-Assert ($resultD.HashMismatchCount -eq 1) "exactly 1 hash mismatch logged"
Test-Assert (-not (Test-Path -LiteralPath $matchImgD.FullName)) "the matched file is actually gone"
Test-Assert (Test-Path -LiteralPath $mismatchImgD.FullName) "the hash-mismatch file was NOT deleted"
Test-Assert (Test-Path -LiteralPath $unrelatedImgD.FullName) "the unrelated file was untouched"
Test-Assert (@($script:logCalls | Where-Object { $_ -like "Warn:*Hash mismatch*" }).Count -eq 1) "a Warn-level hash-mismatch line was logged"
Write-Host ""

# ==============================================================================
#  Scenario E: -DryRun counts as deleted but does not actually delete
# ==============================================================================
Write-Host "=== Scenario E: DryRun ===" -ForegroundColor Cyan
$rootE = Join-Path $scratchDir "scenario-e"
New-Item -ItemType Directory -Path $rootE -Force | Out-Null
$imgE = New-RealImage -Name "scenario-e\match.png" -Width 60 -Height 40
$profileE = New-ProfileFromRealFile -File $imgE -Width 60 -Height 40

$resultE = Invoke-UnwantedImageScan -Path $rootE -Profiles @($profileE) -DryRun $true
Test-Assert ($resultE.DeletedCount -eq 1) "counted as deleted"
Test-Assert (Test-Path -LiteralPath $imgE.FullName) "but the file was NOT actually touched"
Write-Host ""

# ==============================================================================
#  Scenario F: -ExcludePaths skips a file entirely, even if it would match
# ==============================================================================
Write-Host "=== Scenario F: ExcludePaths ===" -ForegroundColor Cyan
$rootF = Join-Path $scratchDir "scenario-f"
New-Item -ItemType Directory -Path $rootF -Force | Out-Null
$imgF = New-RealImage -Name "scenario-f\match.png" -Width 60 -Height 40
$profileF = New-ProfileFromRealFile -File $imgF -Width 60 -Height 40

$resultF = Invoke-UnwantedImageScan -Path $rootF -Profiles @($profileF) -ExcludePaths @($imgF.FullName)
Test-Assert ($resultF.ScannedCount -eq 0 -and $resultF.DeletedCount -eq 0) "the excluded file was never scanned at all"
Test-Assert (Test-Path -LiteralPath $imgF.FullName) "and so was never deleted"
Write-Host ""

# ==============================================================================
#  Scenario G: a delete failure is counted distinctly, does not crash
# ==============================================================================
Write-Host "=== Scenario G: delete failure ===" -ForegroundColor Cyan
$rootG = Join-Path $scratchDir "scenario-g"
New-Item -ItemType Directory -Path $rootG -Force | Out-Null
$imgG = New-RealImage -Name "scenario-g\match.png" -Width 60 -Height 40
$profileG = New-ProfileFromRealFile -File $imgG -Width 60 -Height 40

$script:removeSourceShouldThrow = $true
$threwG = $false
$resultG = $null
try { $resultG = Invoke-UnwantedImageScan -Path $rootG -Profiles @($profileG) } catch { $threwG = $true }
$script:removeSourceShouldThrow = $false

Test-Assert (-not $threwG) "a delete failure does not crash the whole scan"
Test-Assert ($resultG.DeleteFailedCount -eq 1 -and $resultG.DeletedCount -eq 0) "counted as a delete failure, not a success"
Write-Host ""

# ==============================================================================
#  Scenario H: Test-TrailingZeroName - longest-first suffix matching
# ==============================================================================
Write-Host "=== Scenario H: Test-TrailingZeroName ===" -ForegroundColor Cyan
$fileH1 = New-NonImageFile -Name "cover_000.jpg" -Content "x"
Test-Assert (Test-TrailingZeroName -File $fileH1) "'cover_000.jpg' matches the trailing-zero pattern"
$fileH2 = New-NonImageFile -Name "cover_00.jpg" -Content "x"
Test-Assert (Test-TrailingZeroName -File $fileH2) "'cover_00.jpg' matches"
$fileH3 = New-NonImageFile -Name "cover_0.jpg" -Content "x"
Test-Assert (Test-TrailingZeroName -File $fileH3) "'cover_0.jpg' matches"
$fileH4 = New-NonImageFile -Name "cover_1.jpg" -Content "x"
Test-Assert (-not (Test-TrailingZeroName -File $fileH4)) "'cover_1.jpg' does not match"
Write-Host ""

# ==============================================================================
#  Scenario I: Get-TrailingZeroGroups - dedups identical content across
#  folders into one group with multiple Locations
# ==============================================================================
Write-Host "=== Scenario I: Get-TrailingZeroGroups dedups by hash ===" -ForegroundColor Cyan
$rootI = Join-Path $scratchDir "scenario-i"
New-Item -ItemType Directory -Path $rootI -Force | Out-Null
$dupContent = "identical content for dedup test"
$dupPath1 = Join-Path $rootI "FolderA"
$dupPath2 = Join-Path $rootI "FolderB"
New-Item -ItemType Directory -Path $dupPath1 -Force | Out-Null
New-Item -ItemType Directory -Path $dupPath2 -Force | Out-Null
Set-Content -LiteralPath (Join-Path $dupPath1 "page_00.txt") -Value $dupContent -Encoding UTF8 -NoNewline
Set-Content -LiteralPath (Join-Path $dupPath2 "page_00.txt") -Value $dupContent -Encoding UTF8 -NoNewline
Set-Content -LiteralPath (Join-Path $rootI "unique_0.txt") -Value "different content" -Encoding UTF8 -NoNewline
Set-Content -LiteralPath (Join-Path $rootI "normal.txt") -Value "no trailing zero suffix" -Encoding UTF8 -NoNewline

$scanI = Get-TrailingZeroGroups -Path $rootI
Test-Assert ($scanI.Groups.Count -eq 2) ("two distinct groups: the duplicated pair (1) + the unique file (1) - got " + $scanI.Groups.Count)
$dupGroupI = $scanI.Groups | Where-Object { $_.FileName -eq "page_00.txt" }
Test-Assert ($dupGroupI.Locations.Count -eq 2) "the duplicated file's group lists both folder locations"
Test-Assert ($scanI.HashFailureCount -eq 0) "no hash failures"
Write-Host ""

# ==============================================================================
#  Scenario J: Get-TrailingZeroReportLines - pure formatting
# ==============================================================================
Write-Host "=== Scenario J: Get-TrailingZeroReportLines ===" -ForegroundColor Cyan
$groupsJ = @(
    @{ FileName = "a_0.jpg"; Locations = [System.Collections.Generic.List[string]]@("C:\X"); SizeBytes = 100; Width = 10; Height = 20; Hash = "ABC" }
)
$linesJ = Get-TrailingZeroReportLines -Groups $groupsJ -SearchRoot "C:\Root"
Test-Assert ($linesJ[0] -eq "Trailing-Zero Filename Report") "starts with the report title"
Test-Assert ((($linesJ -join "`n")) -match "a_0\.jpg") "includes the file name"
Test-Assert ((($linesJ -join "`n")) -match "10x20") "includes formatted dimensions"
Test-Assert ($linesJ[-1] -eq "--- 1 unique file(s) found ---") "ends with the correct count line"
Write-Host ""

# ==============================================================================
#  Scenario K: Invoke-TrailingZeroAudit - writes a report file when
#  something is found, writes NOTHING when nothing is found
# ==============================================================================
Write-Host "=== Scenario K: Invoke-TrailingZeroAudit ===" -ForegroundColor Cyan
$reportPathK = Join-Path $scratchDir "trailing_zeros_report.txt"
$auditK = Invoke-TrailingZeroAudit -Path $rootI -ReportPath $reportPathK
Test-Assert ($auditK.UniqueFileCount -eq 2) "found the same 2 groups as Scenario I"
Test-Assert ($auditK.ReportPath -eq $reportPathK) "returned the report path"
Test-Assert (Test-Path -LiteralPath $reportPathK) "the report file was actually written"

$rootK2 = Join-Path $scratchDir "scenario-k-empty"
New-Item -ItemType Directory -Path $rootK2 -Force | Out-Null
$reportPathK2 = Join-Path $scratchDir "should-not-exist.txt"
$auditK2 = Invoke-TrailingZeroAudit -Path $rootK2 -ReportPath $reportPathK2
Test-Assert ($auditK2.UniqueFileCount -eq 0 -and $null -eq $auditK2.ReportPath) "nothing found -> UniqueFileCount 0, ReportPath `$null"
Test-Assert (-not (Test-Path -LiteralPath $reportPathK2)) "no report file was created when nothing was found"
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
