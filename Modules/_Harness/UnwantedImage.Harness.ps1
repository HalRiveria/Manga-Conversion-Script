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
# -ForceConsole tracked separately, not folded into $logCalls' own string
# shape (2026-09-03 addition) - Scenario Z below checks specifically that
# every user-facing scan/audit line passes it, since that's the actual
# fix for the real "mode 5 reports nothing under Clean Console Output"
# bug (see Logging.ps1's Write-Log .PARAMETER doc for the full reasoning).
$script:logCallsForceConsole = New-Object System.Collections.Generic.List[bool]
function Write-Log {
    param([string]$Message, [string]$Level = "Info", [switch]$ForceConsole)
    $script:logCalls.Add($Level + ": " + $Message)
    $script:logCallsForceConsole.Add([bool]$ForceConsole)
}

$script:removeSourceCalls = New-Object System.Collections.Generic.List[string]
$script:removeSourceShouldThrow = $false
$script:PermanentDelete = $true
function Remove-Source {
    param([string]$ItemPath)
    if ($script:removeSourceShouldThrow) { throw "simulated delete failure" }
    $script:removeSourceCalls.Add($ItemPath)
    if ($script:removeSourceShouldReturnFalse) { return $false }
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

function New-ScriptedPrompt {
    <#
    .SYNOPSIS
        Builds a -PromptFunc scriptblock that returns each of $Responses
        in order, one per call, and throws if asked for more than were
        queued - same technique as Menu.Harness.ps1's own helper, so an
        under-scripted scenario fails loudly instead of blocking on a
        real Read-Host.
    #>
    param([string[]]$Responses)

    $queue = New-Object System.Collections.Generic.Queue[string]
    foreach ($r in $Responses) { $queue.Enqueue($r) }

    return {
        param($Message)
        if ($queue.Count -eq 0) {
            throw ("ScriptedPrompt exhausted - no more responses queued (asked: '" + $Message + "')")
        }
        return $queue.Dequeue()
    }.GetNewClosure()
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

# 2026-09-02 review fix: a file that matches on size+dimensions but can't
# be hashed (locked by another process, or vanishes between the dimension
# read and this call - a real TOCTOU gap, since Get-ImageDimensions and
# Get-FileHash are two separate file opens) used to throw straight out of
# Test-UnwantedImageMatch - with the bootstrap's $ErrorActionPreference =
# 'Stop' inherited into this function, Get-FileHash's own terminating
# error was never caught, unlike Get-TrailingZeroGroups's identical call
# further down this same file. A real FileShare.None lock can't isolate
# this to just the hash step (Get-ImageDimensions's own
# [System.Drawing.Image]::FromFile call needs Read access too, so it
# fails FIRST and this never reaches the hash line at all) - so this
# shadows the Get-FileHash cmdlet with a throwing function for the
# duration of one call instead, the standard PowerShell mocking technique
# (a function of the same name resolves before the cmdlet in the same
# scope chain). Confirmed live (outside this harness) that a real
# FileShare.None lock DOES throw from Get-FileHash when it's the only
# thing holding the file open - this just isolates that one failure
# deterministically rather than racing a real lock against GDI+.
$imgC6 = New-RealImage -Name "locked-c.png" -Width 50 -Height 30
$profileC6 = New-ProfileFromRealFile -File $imgC6 -Width 50 -Height 30
function Get-FileHash { throw "simulated: file vanished/got locked between the dimension read and the hash read" }
try {
    $resultC6 = Test-UnwantedImageMatch -File $imgC6 -Profiles @($profileC6)
    Test-Assert ($resultC6.Status -eq 'HashFailure') ("size+dimensions match but the hash read throws -> HashFailure, not a throw (got '" + $resultC6.Status + "')")
} finally {
    Remove-Item Function:\Get-FileHash -ErrorAction SilentlyContinue
}
Write-Host ""

# ==============================================================================
#  Scenario C2 (2026-09-03 fix, Todo.md finding): a real, previously
#  unfixed shadowing risk - a profile whose size+dimensions match but
#  hash doesn't used to make Test-UnwantedImageMatch return HashMismatch
#  immediately, WITHOUT trying any later profile - so a second profile
#  sharing the exact same size+dimensions but a genuinely matching hash
#  was permanently shadowed and never got to delete anything. Now every
#  size+dimension-matching profile is tried until a real Match is found.
# ==============================================================================
Write-Host "=== Scenario C2: a later profile with the same size+dimensions is no longer shadowed by an earlier hash mismatch ===" -ForegroundColor Cyan
$imgC2 = New-RealImage -Name "match-c2.png" -Width 50 -Height 30
$realProfileC2 = New-ProfileFromRealFile -File $imgC2 -Width 50 -Height 30 -Label "Real Match"
$shadowingProfileC2 = $realProfileC2.Clone()
$shadowingProfileC2.Label = "Shadowing Profile"
$shadowingProfileC2.Hash  = "0000000000000000000000000000000000000000000000000000000000000000"

# The shadowing (wrong-hash) profile is FIRST in the list - the exact
# shape that used to permanently hide the real match behind it.
$resultC2 = Test-UnwantedImageMatch -File $imgC2 -Profiles @($shadowingProfileC2, $realProfileC2)
Test-Assert ($resultC2.Status -eq 'Match' -and $resultC2.Profile.Label -eq 'Real Match') ("the real match (second in the list) was found despite an earlier same-size+dimensions profile with a wrong hash (got Status=" + $resultC2.Status + ", Profile=" + $resultC2.Profile.Label + ")")

# Sanity check: when NOTHING actually matches by hash, the FIRST
# profile's own HashMismatch is still what gets reported - preserving
# this function's original behavior for the "nothing really matched" case.
$wrongHashProfileC2a = $realProfileC2.Clone(); $wrongHashProfileC2a.Label = "Wrong A"; $wrongHashProfileC2a.Hash = "1111111111111111111111111111111111111111111111111111111111111111"
$wrongHashProfileC2b = $realProfileC2.Clone(); $wrongHashProfileC2b.Label = "Wrong B"; $wrongHashProfileC2b.Hash = "2222222222222222222222222222222222222222222222222222222222222222"
$resultC2b = Test-UnwantedImageMatch -File $imgC2 -Profiles @($wrongHashProfileC2a, $wrongHashProfileC2b)
Test-Assert ($resultC2b.Status -eq 'HashMismatch' -and $resultC2b.Profile.Label -eq 'Wrong A') "when nothing matches by hash, the FIRST profile's own HashMismatch is still what's reported"
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
#  Scenario D2 (2026-09-02 review fix, live-confirmed): a ".tif" file must
#  actually be scanned and matchable, not silently invisible to
#  Invoke-UnwantedImageScan's own default -ImageExtensions. Before this
#  fix, New-UnwantedImageProfileFromFile (the real "2 - Add Image" flow)
#  applied no extension filter at all - System.Drawing.Image.FromFile
#  reads both .tif and .tiff - so a user could add a profile from a real
#  .tif cover, get the "will be caught on every future scan" green-light
#  confirmation, and have it silently never match on any later scan. Not
#  a data-loss risk (fails toward not deleting), but a real false promise
#  this closes.
# ==============================================================================
Write-Host "=== Scenario D2: a .tif file is actually scanned and matchable, not silently invisible ===" -ForegroundColor Cyan
$rootD2 = Join-Path $scratchDir "scenario-d2"
New-Item -ItemType Directory -Path $rootD2 -Force | Out-Null
$tifImgD2 = New-RealImage -Name "scenario-d2\cover.tif" -Width 70 -Height 50
$tifProfileD2 = New-ProfileFromRealFile -File $tifImgD2 -Width 70 -Height 50 -Label "TIF Target"

$resultD2 = Invoke-UnwantedImageScan -Path $rootD2 -Profiles @($tifProfileD2)

Test-Assert ($resultD2.ScannedCount -eq 1) ("the .tif file was actually scanned, not silently skipped by extension (got ScannedCount=" + $resultD2.ScannedCount + ")")
Test-Assert ($resultD2.DeletedCount -eq 1) "the .tif file was matched and deleted, same as any other extension on the list"
Test-Assert (-not (Test-Path -LiteralPath $tifImgD2.FullName)) "the .tif file is actually gone"
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
#  Scenario G2 (2026-09-03 fix, Todo.md finding): Remove-Source's return
#  value used to be discarded (`$null = Remove-Source ...`) - it returns
#  $false (not an exception) when the file already vanished before
#  deletion (a real TOCTOU gap between the match check and the delete
#  call), so a file that was never actually there got logged and counted
#  as a successful delete anyway. Must now be counted/logged distinctly.
# ==============================================================================
Write-Host "=== Scenario G2: a file that vanished before deletion is not miscounted as deleted ===" -ForegroundColor Cyan
$rootG2 = Join-Path $scratchDir "scenario-g2"
New-Item -ItemType Directory -Path $rootG2 -Force | Out-Null
$imgG2 = New-RealImage -Name "scenario-g2\match.png" -Width 60 -Height 40
$profileG2 = New-ProfileFromRealFile -File $imgG2 -Width 60 -Height 40

$script:removeSourceShouldReturnFalse = $true
$resultG2 = Invoke-UnwantedImageScan -Path $rootG2 -Profiles @($profileG2)
$script:removeSourceShouldReturnFalse = $false

Test-Assert ($resultG2.DeletedCount -eq 0) "a vanished file is NOT counted as deleted"
Test-Assert ($resultG2.DeleteFailedCount -eq 0) "and NOT counted as a delete failure either - Remove-Source didn't throw, it just had nothing to do"
Test-Assert ($resultG2.AlreadyGoneCount -eq 1) "counted in its own AlreadyGoneCount instead"
Test-Assert (Test-Path -LiteralPath $imgG2.FullName) "sanity check: the real file was never actually touched by the stubbed Remove-Source"
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
#  Scenario L: Get-UnwantedImageProfilesPath
# ==============================================================================
Write-Host "=== Scenario L: Get-UnwantedImageProfilesPath ===" -ForegroundColor Cyan
Test-Assert ((Get-UnwantedImageProfilesPath -BaseDir "C:\Fake") -eq (Join-Path "C:\Fake" "ConversionScript\unwanted-image-profiles.json")) "builds the expected path under -BaseDir"
Write-Host ""

# ==============================================================================
#  Scenario M: Import-UnwantedImageProfiles - missing file, real file,
#  corrupt file
# ==============================================================================
Write-Host "=== Scenario M: Import-UnwantedImageProfiles ===" -ForegroundColor Cyan
$profilesPathM = Join-Path $scratchDir "profiles-m\unwanted-image-profiles.json"
Test-Assert (@(Import-UnwantedImageProfiles -ProfilesPath $profilesPathM).Count -eq 0) "a missing profiles file returns an empty array"

New-Item -ItemType Directory -Path (Split-Path $profilesPathM -Parent) -Force | Out-Null
'[{"Label":"Test A","Width":10,"Height":20,"SizeBytes":100,"SizeTolerance":5,"Hash":"AAA"}]' | Set-Content -LiteralPath $profilesPathM -Encoding UTF8
$loadedM = Import-UnwantedImageProfiles -ProfilesPath $profilesPathM
Test-Assert ($loadedM.Count -eq 1 -and $loadedM[0].Label -eq "Test A" -and $loadedM[0].Width -eq 10) "a real profiles file loads correctly"

$corruptPathM = Join-Path $scratchDir "profiles-m-corrupt\unwanted-image-profiles.json"
New-Item -ItemType Directory -Path (Split-Path $corruptPathM -Parent) -Force | Out-Null
"{ not valid json" | Set-Content -LiteralPath $corruptPathM -Encoding UTF8
$script:logCalls.Clear()
$threwM = $false
$loadedM2 = $null
try { $loadedM2 = Import-UnwantedImageProfiles -ProfilesPath $corruptPathM } catch { $threwM = $true }
Test-Assert (-not $threwM -and @($loadedM2).Count -eq 0) "a corrupt profiles file returns an empty array, does not throw"
Test-Assert (@($script:logCalls | Where-Object { $_ -like "Warn:*" }).Count -ge 1) "a Warn was logged for the corrupt file"
Test-Assert (@(Get-ChildItem -LiteralPath (Split-Path $corruptPathM -Parent) -Filter "*.corrupt-*.bak").Count -eq 1) "the corrupt file was backed up, not silently discarded"

# 2026-09-02 review fix: valid JSON (so the parse step above never
# catches it), but a non-numeric value in one of the [int]/[int64]-cast
# fields - the per-field cast used to run outside the try/catch entirely.
# Real trigger: a user hand-editing the plain-JSON profiles file and
# fat-fingering a dimension. Same recovery contract as a parse failure -
# Warn + .bak + empty array, not a throw.
$badFieldPathM = Join-Path $scratchDir "profiles-m-badfield\unwanted-image-profiles.json"
New-Item -ItemType Directory -Path (Split-Path $badFieldPathM -Parent) -Force | Out-Null
'[{"Label":"Test A","Width":"3OOO","Height":20,"SizeBytes":100,"SizeTolerance":5,"Hash":"AAA"}]' | Set-Content -LiteralPath $badFieldPathM -Encoding UTF8
$script:logCalls.Clear()
$threwM2 = $false
$loadedM3 = $null
try { $loadedM3 = Import-UnwantedImageProfiles -ProfilesPath $badFieldPathM } catch { $threwM2 = $true }
Test-Assert (-not $threwM2 -and @($loadedM3).Count -eq 0) "a valid-JSON profiles file with a bad field value returns an empty array, does not throw"
Test-Assert (@($script:logCalls | Where-Object { $_ -like "Warn:*" }).Count -ge 1) "a Warn was logged for the bad field value"
Test-Assert (@(Get-ChildItem -LiteralPath (Split-Path $badFieldPathM -Parent) -Filter "*.corrupt-*.bak").Count -eq 1) "the bad-field file was backed up too, same as a parse failure"
Write-Host ""

# ==============================================================================
#  Scenario N: Export-UnwantedImageProfiles round-trips, including a
#  single-entry array staying a real JSON array (not a bare object)
# ==============================================================================
Write-Host "=== Scenario N: Export-UnwantedImageProfiles round-trips ===" -ForegroundColor Cyan
$profilesPathN = Join-Path $scratchDir "profiles-n\unwanted-image-profiles.json"
Export-UnwantedImageProfiles -Profiles @(@{ Label = "Solo"; Width = 5; Height = 6; SizeBytes = 7; SizeTolerance = 1; Hash = "ZZZ" }) -ProfilesPath $profilesPathN
$rawTextN = Get-Content -LiteralPath $profilesPathN -Raw
Test-Assert ($rawTextN.TrimStart().StartsWith("[")) "a single-entry file is written as a JSON array, not a bare object"
$loadedN = Import-UnwantedImageProfiles -ProfilesPath $profilesPathN
Test-Assert ($loadedN.Count -eq 1 -and $loadedN[0].Label -eq "Solo") "round-trips correctly"
Write-Host ""

# ==============================================================================
#  Scenario O: Get-AllUnwantedImageProfiles combines built-in + persisted
# ==============================================================================
Write-Host "=== Scenario O: Get-AllUnwantedImageProfiles ===" -ForegroundColor Cyan
$profilesPathO = Join-Path $scratchDir "profiles-o\unwanted-image-profiles.json"
Export-UnwantedImageProfiles -Profiles @(
    @{ Label = "Custom 1"; Width = 1; Height = 1; SizeBytes = 1; SizeTolerance = 0; Hash = "C1" }
    @{ Label = "Custom 2"; Width = 2; Height = 2; SizeBytes = 2; SizeTolerance = 0; Hash = "C2" }
) -ProfilesPath $profilesPathO
$allO = Get-AllUnwantedImageProfiles -ProfilesPath $profilesPathO
Test-Assert ($allO.Count -eq 7) ("5 built-in + 2 persisted = 7 (got " + $allO.Count + ")")
Write-Host ""

# ==============================================================================
#  Scenario P: New-UnwantedImageProfileFromFile - builds a profile from
#  a REAL file's real dimensions/size/hash; default Label; error paths
# ==============================================================================
Write-Host "=== Scenario P: New-UnwantedImageProfileFromFile ===" -ForegroundColor Cyan
$imgP = New-RealImage -Name "profile-source-p.png" -Width 33 -Height 22
$profileP = New-UnwantedImageProfileFromFile -Path $imgP.FullName -Label "My New Target"
Test-Assert ($profileP.Width -eq 33 -and $profileP.Height -eq 22) "real dimensions read from the file"
Test-Assert ($profileP.SizeBytes -eq $imgP.Length) "real file size read from the file"
Test-Assert ($profileP.Hash -eq (Get-FileHash -LiteralPath $imgP.FullName -Algorithm SHA256).Hash) "real SHA-256 hash read from the file"
Test-Assert ($profileP.Label -eq "My New Target") "the given label is used"
Test-Assert ($profileP.SizeTolerance -eq 5000) "default SizeTolerance is 5000, matching the built-in profiles"

$imgP2 = New-RealImage -Name "unlabeled-p.png" -Width 10 -Height 10
$profileP2 = New-UnwantedImageProfileFromFile -Path $imgP2.FullName
Test-Assert ($profileP2.Label -eq "unlabeled-p.png") "Label defaults to the file's own name when omitted"

$threwP = $false
try { New-UnwantedImageProfileFromFile -Path (Join-Path $scratchDir "does-not-exist.png") -Label "X" } catch { $threwP = $true }
Test-Assert $threwP "throws for a nonexistent file"

$nonImgP = New-NonImageFile -Name "notimage-p.jpg"
$threwP2 = $false
try { New-UnwantedImageProfileFromFile -Path $nonImgP.FullName -Label "X" } catch { $threwP2 = $true }
Test-Assert $threwP2 "throws for a file that can't be read as an image"

# 2026-09-02 review fix: this function's own Get-FileHash call now passes
# -ErrorAction Stop, matching this file's other two Get-FileHash sites
# (both fixed the same day) - makes the throw reliable regardless of the
# ambient $ErrorActionPreference a caller might have, rather than
# depending on inheriting the bootstrap's own 'Stop' setting. Proven here
# by explicitly setting a non-Stop preference for this one call and
# shadowing Get-FileHash with a non-terminating-error version (a real
# file lock can't isolate the failure to just this call, since
# Get-ImageDimensions needs read access too and would fail first - same
# reasoning as the earlier Test-UnwantedImageMatch fix's own test).
$imgP3 = New-RealImage -Name "profile-source-p3.png" -Width 15 -Height 15
function Get-FileHash {
    [CmdletBinding()]
    param($LiteralPath, $Algorithm)
    Write-Error "simulated non-terminating hash failure"
}
$threwP3 = $false
$oldEapP3 = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    New-UnwantedImageProfileFromFile -Path $imgP3.FullName -Label "X"
} catch {
    $threwP3 = $true
} finally {
    $ErrorActionPreference = $oldEapP3
    Remove-Item Function:\Get-FileHash -ErrorAction SilentlyContinue
}
Test-Assert $threwP3 "still throws on a hash failure even under a non-Stop `$ErrorActionPreference, thanks to its own -ErrorAction Stop"
Write-Host ""

# ==============================================================================
#  Scenario Q: Add-UnwantedImageProfile - adds successfully, persists,
#  refuses a duplicate hash (against built-in AND already-persisted)
# ==============================================================================
Write-Host "=== Scenario Q: Add-UnwantedImageProfile ===" -ForegroundColor Cyan
$profilesPathQ = Join-Path $scratchDir "profiles-q\unwanted-image-profiles.json"
$imgQ = New-RealImage -Name "profile-source-q.png" -Width 44 -Height 55
$profileQ = New-UnwantedImageProfileFromFile -Path $imgQ.FullName -Label "Add Target"

$addResultQ = Add-UnwantedImageProfile -Profile $profileQ -ProfilesPath $profilesPathQ
Test-Assert ($addResultQ.Added -eq $true) "the new profile was added"
$loadedQ = Import-UnwantedImageProfiles -ProfilesPath $profilesPathQ
Test-Assert ($loadedQ.Count -eq 1 -and $loadedQ[0].Label -eq "Add Target") "it's actually persisted to disk"

$dupResultQ = Add-UnwantedImageProfile -Profile $profileQ -ProfilesPath $profilesPathQ
Test-Assert ($dupResultQ.Added -eq $false -and $dupResultQ.Reason) "adding the exact same profile again is refused, with a reason"
Test-Assert ((Import-UnwantedImageProfiles -ProfilesPath $profilesPathQ).Count -eq 1) "still only 1 persisted - no duplicate was written"

$builtInDupProfileQ = (Get-UnwantedImageProfiles)[0].Clone()
$dupResultQ2 = Add-UnwantedImageProfile -Profile $builtInDupProfileQ -ProfilesPath $profilesPathQ
Test-Assert ($dupResultQ2.Added -eq $false) "a profile matching a BUILT-IN profile's hash is also refused, not just persisted-vs-persisted"
Write-Host ""

# ==============================================================================
#  Scenario R: Add-UnwantedImageProfileFromFile end to end - build +
#  persist in one call, then a LATER scan picks it up automatically with
#  no further wiring (the actual feature requested)
# ==============================================================================
Write-Host "=== Scenario R: Add-UnwantedImageProfileFromFile, then a later scan picks it up ===" -ForegroundColor Cyan
$profilesPathR = Join-Path $scratchDir "profiles-r\unwanted-image-profiles.json"
$sourceImgR = New-RealImage -Name "source-for-profile-r.png" -Width 77 -Height 88

$addFromFileR = Add-UnwantedImageProfileFromFile -Path $sourceImgR.FullName -Label "Auto-Added" -ProfilesPath $profilesPathR
Test-Assert ($addFromFileR.Added -eq $true) "the profile was built from the real file and added in one call"
Test-Assert ($addFromFileR.Profile.Width -eq 77 -and $addFromFileR.Profile.Height -eq 88) "the built profile reflects the real file's dimensions"

# Simulate a LATER, separate run: a target image with the SAME real
# content as the source used to build the profile shows up somewhere
# else in the library. A fresh Get-AllUnwantedImageProfiles call (as
# Invoke-UnwantedImageScan's own default -Profiles does) should now
# match and delete it - with NO manual profile list update in between.
$laterRunRootR = Join-Path $scratchDir "scenario-r-later-run"
New-Item -ItemType Directory -Path $laterRunRootR -Force | Out-Null
Copy-Item -LiteralPath $sourceImgR.FullName -Destination (Join-Path $laterRunRootR "found-later.png")

$script:removeSourceCalls.Clear()
$laterScanR = Invoke-UnwantedImageScan -Path $laterRunRootR -Profiles (Get-AllUnwantedImageProfiles -ProfilesPath $profilesPathR)
Test-Assert ($laterScanR.DeletedCount -eq 1) "a later scan matched and deleted the file using the auto-added profile, with zero manual wiring"
Test-Assert (-not (Test-Path -LiteralPath (Join-Path $laterRunRootR "found-later.png"))) "the matched file is actually gone"
Write-Host ""

# ==============================================================================
#  Scenario S: Show-AddUnwantedImageProfileFlow - happy path with an
#  explicit label, confirmed
# ==============================================================================
Write-Host "=== Scenario S: interactive flow, happy path ===" -ForegroundColor Cyan
$profilesPathS = Join-Path $scratchDir "profiles-s\unwanted-image-profiles.json"
$imgS = New-RealImage -Name "flow-source-s.png" -Width 15 -Height 25
$promptS = New-ScriptedPrompt -Responses @($imgS.FullName, "Flow Label", "Y")
$flowResultS = Show-AddUnwantedImageProfileFlow -ProfilesPath $profilesPathS -PromptFunc $promptS

Test-Assert ($flowResultS.Added -eq $true) "added via the interactive flow"
Test-Assert ($flowResultS.Profile.Label -eq "Flow Label") "used the explicitly entered label"
$loadedS = Import-UnwantedImageProfiles -ProfilesPath $profilesPathS
Test-Assert ($loadedS.Count -eq 1 -and $loadedS[0].Label -eq "Flow Label") "actually persisted to disk"
Write-Host ""

# ==============================================================================
#  Scenario T: blank label defaults to the file's own name; a
#  drag-and-drop-style quoted path is accepted
# ==============================================================================
Write-Host "=== Scenario T: blank label defaults to filename, quoted path accepted ===" -ForegroundColor Cyan
$profilesPathT = Join-Path $scratchDir "profiles-t\unwanted-image-profiles.json"
$imgT = New-RealImage -Name "flow-source-t.png" -Width 16 -Height 26
$quotedPathT = '"' + $imgT.FullName + '"'
$promptT = New-ScriptedPrompt -Responses @($quotedPathT, "", "Y")
$flowResultT = Show-AddUnwantedImageProfileFlow -ProfilesPath $profilesPathT -PromptFunc $promptT

Test-Assert ($flowResultT.Added -eq $true) "a drag-and-drop-style quoted path was accepted"
Test-Assert ($flowResultT.Profile.Label -eq "flow-source-t.png") "a blank label defaulted to the file's own name"
Write-Host ""

# ==============================================================================
#  Scenario U: no path entered - cancels immediately, only 1 prompt call
# ==============================================================================
Write-Host "=== Scenario U: no path entered cancels immediately ===" -ForegroundColor Cyan
$promptU = New-ScriptedPrompt -Responses @("")
$flowResultU = Show-AddUnwantedImageProfileFlow -ProfilesPath (Join-Path $scratchDir "profiles-u\unwanted-image-profiles.json") -PromptFunc $promptU
Test-Assert ($flowResultU.Added -eq $false -and $flowResultU.Reason -eq "No path entered.") "cancelled immediately - the scripted queue having only 1 response proves no further prompts were made"
Write-Host ""

# ==============================================================================
#  Scenario V: a file that can't be read as an image cancels with a
#  clear reason, nothing persisted
# ==============================================================================
Write-Host "=== Scenario V: unreadable image file cancels cleanly ===" -ForegroundColor Cyan
$badImgV = New-NonImageFile -Name "flow-not-an-image-v.jpg"
$profilesPathV = Join-Path $scratchDir "profiles-v\unwanted-image-profiles.json"
$promptV = New-ScriptedPrompt -Responses @($badImgV.FullName, "Doesn't Matter")
$flowResultV = Show-AddUnwantedImageProfileFlow -ProfilesPath $profilesPathV -PromptFunc $promptV
Test-Assert ($flowResultV.Added -eq $false -and $flowResultV.Reason -like "Cancelled by file-read error*") "cancelled with a file-read-error reason"
Test-Assert (-not (Test-Path -LiteralPath $profilesPathV)) "nothing was persisted"
Write-Host ""

# ==============================================================================
#  Scenario W: declining the confirmation (N) does not persist anything
# ==============================================================================
Write-Host "=== Scenario W: declining confirmation does not add ===" -ForegroundColor Cyan
$imgW = New-RealImage -Name "flow-source-w.png" -Width 17 -Height 27
$profilesPathW = Join-Path $scratchDir "profiles-w\unwanted-image-profiles.json"
$promptW = New-ScriptedPrompt -Responses @($imgW.FullName, "Declined Label", "N")
$flowResultW = Show-AddUnwantedImageProfileFlow -ProfilesPath $profilesPathW -PromptFunc $promptW
Test-Assert ($flowResultW.Added -eq $false -and $flowResultW.Reason -eq "Cancelled by user.") "declined via N, not added"
Test-Assert (-not (Test-Path -LiteralPath $profilesPathW)) "nothing was persisted"
Write-Host ""

# ==============================================================================
#  Scenario X: a duplicate hash is reported by the EXISTING profile's
#  label, not added a second time
# ==============================================================================
Write-Host "=== Scenario X: duplicate hash is reported, not re-added ===" -ForegroundColor Cyan
$profilesPathX = Join-Path $scratchDir "profiles-x\unwanted-image-profiles.json"
$imgX = New-RealImage -Name "flow-source-x.png" -Width 18 -Height 28
$existingProfileX = New-UnwantedImageProfileFromFile -Path $imgX.FullName -Label "Already Tracked"
Add-UnwantedImageProfile -Profile $existingProfileX -ProfilesPath $profilesPathX | Out-Null

# Same real file (identical content -> identical hash) offered again
# through the interactive flow, under a different label this time.
$promptX = New-ScriptedPrompt -Responses @($imgX.FullName, "A Different Label This Time", "Y")
$flowResultX = Show-AddUnwantedImageProfileFlow -ProfilesPath $profilesPathX -PromptFunc $promptX

Test-Assert ($flowResultX.Added -eq $false) "not added a second time"
Test-Assert ($flowResultX.ExistingLabel -eq "Already Tracked") "the message names the EXISTING profile's label, not the new one just typed in"
Test-Assert ((Import-UnwantedImageProfiles -ProfilesPath $profilesPathX).Count -eq 1) "still only 1 persisted profile - no duplicate was written"
Write-Host ""

# ==============================================================================
#  Scenario Y (2026-09-03 fix, real bug, live-reported): every user-facing
#  Invoke-UnwantedImageScan/Invoke-TrailingZeroAudit line passes
#  -ForceConsole to Write-Log. Mode 5/Cover Deletion has no CCR live-
#  progress display of its own to replace suppressed console lines with,
#  so before this fix it silently reported nothing to the console at all
#  with Clean Console Output on, while still working and file-logging
#  normally - see Logging.ps1's Write-Log .PARAMETER doc for the full
#  reasoning. This harness's own Write-Log stub can't verify the CCO gate
#  itself (that's Logging.Harness.ps1's Scenario Q, against the real
#  function) - it verifies the other half: that these call sites actually
#  pass the flag at all.
# ==============================================================================
Write-Host "=== Scenario Y: scan/audit lines all pass -ForceConsole to Write-Log ===" -ForegroundColor Cyan
$rootY = Join-Path $scratchDir "scenario-y"
New-Item -ItemType Directory -Path $rootY -Force | Out-Null
$matchImgY = New-RealImage -Name "scenario-y\match.png" -Width 62 -Height 42
$matchProfileY = New-ProfileFromRealFile -File $matchImgY -Width 62 -Height 42 -Label "Y Target"
$mismatchImgY = New-RealImage -Name "scenario-y\mismatch.png" -Width 63 -Height 43
$mismatchProfileY = New-ProfileFromRealFile -File $mismatchImgY -Width 63 -Height 43 -Label "Y Mismatch"
$mismatchProfileY.Hash = "2222222222222222222222222222222222222222222222222222222222222222"

$script:logCalls.Clear()
$script:logCallsForceConsole.Clear()
$null = Invoke-UnwantedImageScan -Path $rootY -Profiles @($matchProfileY, $mismatchProfileY)
Test-Assert ($script:logCalls.Count -ge 2) "the scan produced at least the deleted-match and hash-mismatch lines"
Test-Assert (-not ($script:logCallsForceConsole -contains $false)) ("every Invoke-UnwantedImageScan line passed -ForceConsole (recorded: " + ($script:logCallsForceConsole -join ",") + ")")

$rootY2 = Join-Path $scratchDir "scenario-y2"
New-Item -ItemType Directory -Path $rootY2 -Force | Out-Null
$imgY2a = New-RealImage -Name "scenario-y2\a_0.jpg" -Width 10 -Height 20
$imgY2b = New-RealImage -Name "scenario-y2\sub\a_00.jpg" -Width 10 -Height 20
Copy-Item -LiteralPath $imgY2a.FullName -Destination $imgY2b.FullName -Force
$reportPathY2 = Join-Path $scratchDir "scenario-y2-report.txt"

$script:logCalls.Clear()
$script:logCallsForceConsole.Clear()
$null = Invoke-TrailingZeroAudit -Path $rootY2 -ReportPath $reportPathY2
Test-Assert ($script:logCalls.Count -ge 1) "the audit produced at least its own summary line"
Test-Assert (-not ($script:logCallsForceConsole -contains $false)) ("every Invoke-TrailingZeroAudit line passed -ForceConsole (recorded: " + ($script:logCallsForceConsole -join ",") + ")")
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
