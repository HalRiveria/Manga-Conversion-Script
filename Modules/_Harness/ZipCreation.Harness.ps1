<#
.SYNOPSIS
    Standalone test harness for Modules\ZipCreation.ps1.

.DESCRIPTION
    Dot-sources the real module (not a reimplementation) and exercises it
    against real folders/files and real ZIP creation - not mocked I/O.
    Write-Log and Remove-Source/$script:PermanentDelete are FORWARD
    REFERENCES this module expects from Logging.ps1/FileDeletion.ps1 -
    stubbed here (with call tracking for Remove-Source) since ZipCreation
    must stay standalone-testable without either dependency existing.

.EXAMPLE
    .\Modules\_Harness\ZipCreation.Harness.ps1
#>

$ErrorActionPreference = "Stop"

$script:removeSourceCalls = [System.Collections.Generic.List[string]]::new()
function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    Write-Host ("  [log:" + $Level + "] " + $Message) -ForegroundColor DarkGray
}
function Remove-Source {
    param([string]$ItemPath)
    $script:removeSourceCalls.Add($ItemPath)
    Remove-Item -LiteralPath $ItemPath -Force
    return $true
}
$script:removeItemPermanentlyCalls = [System.Collections.Generic.List[string]]::new()
function Remove-ItemPermanently {
    param([string]$ItemPath)
    $script:removeItemPermanentlyCalls.Add($ItemPath)
    if (Test-Path -LiteralPath $ItemPath) { Remove-Item -LiteralPath $ItemPath -Force }
    return $true
}
$script:PermanentDelete = $false

. (Join-Path $PSScriptRoot "..\ZipCreation.ps1")

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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("zipcreation-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray
Write-Host ""

function New-ScratchSourceDir {
    param([string]$Name, [int]$FileCount = 3)
    $dir = Join-Path $scratchDir $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    for ($i = 1; $i -le $FileCount; $i++) {
        "content of file $i" | Out-File -FilePath (Join-Path $dir ("file" + $i + ".txt")) -Encoding UTF8
    }
    return $dir
}

# ==============================================================================
#  Scenario A: basic zip creation - real folder, real files, real ZIP
#  readable back with the expected entry count.
# ==============================================================================
Write-Host "=== Scenario A: Compress-FolderToZip creates a real, readable ZIP ===" -ForegroundColor Cyan
$sourceA = New-ScratchSourceDir -Name "scenario-a-source" -FileCount 3
$zipOutA = Join-Path $scratchDir "scenario-a-source.zip"

$sizeA = Compress-FolderToZip -SourceDir $sourceA -ZipOut $zipOutA

Test-Assert (Test-Path -LiteralPath $zipOutA) "the ZIP file was created"
Test-Assert ($sizeA -gt 0) "Compress-FolderToZip returned a non-zero size"
Test-Assert ((Get-Item -LiteralPath $zipOutA).Length -eq $sizeA) "the returned size matches the actual file size on disk"

$archiveA = [System.IO.Compression.ZipFile]::OpenRead($zipOutA)
try {
    Test-Assert ($archiveA.Entries.Count -eq 3) ("the ZIP contains exactly the 3 source files (got " + $archiveA.Entries.Count + " entries)")
} finally { $archiveA.Dispose() }
Write-Host ""

# ==============================================================================
#  Scenario B: a pre-existing ZIP at $ZipOut is deleted (via Remove-Source)
#  before the new one is created - verified both by call-tracking AND by
#  the new ZIP's actual contents replacing the old ones.
# ==============================================================================
Write-Host "=== Scenario B: pre-existing ZIP is removed via Remove-Source before overwriting ===" -ForegroundColor Cyan
$sourceB = New-ScratchSourceDir -Name "scenario-b-source" -FileCount 2
$zipOutB = Join-Path $scratchDir "scenario-b-source.zip"
"stale zip content, not a real zip" | Out-File -FilePath $zipOutB -Encoding UTF8   # pre-existing file at the target path
$script:removeSourceCalls.Clear()

$sizeB = Compress-FolderToZip -SourceDir $sourceB -ZipOut $zipOutB

Test-Assert ($script:removeSourceCalls.Count -eq 1 -and $script:removeSourceCalls[0] -eq $zipOutB) "Remove-Source was called exactly once, on the pre-existing ZIP path"
Test-Assert ($sizeB -gt 0) "the new ZIP was created successfully after the old one was cleared"
$archiveB = [System.IO.Compression.ZipFile]::OpenRead($zipOutB)
try {
    Test-Assert ($archiveB.Entries.Count -eq 2) "the ZIP now contains the NEW source's 2 files, not stale content"
} finally { $archiveB.Dispose() }
Write-Host ""

# ==============================================================================
#  Scenario C: SourceDir that doesn't exist - propagates a real, clear
#  exception rather than silently producing a bad/empty ZIP.
# ==============================================================================
Write-Host "=== Scenario C: nonexistent SourceDir throws ===" -ForegroundColor Cyan
$missingSourceC = Join-Path $scratchDir "does-not-exist-source"
$zipOutC = Join-Path $scratchDir "scenario-c.zip"
$script:removeItemPermanentlyCalls.Clear()
$threwC = $false
try { Compress-FolderToZip -SourceDir $missingSourceC -ZipOut $zipOutC } catch { $threwC = $true }
Test-Assert $threwC "Compress-FolderToZip throws when SourceDir doesn't exist"
Test-Assert (-not (Test-Path -LiteralPath $zipOutC)) "no stray ZIP file was left behind after the failure (cleaned up via Remove-ItemPermanently)"
Test-Assert ($script:removeItemPermanentlyCalls.Count -eq 1 -and $script:removeItemPermanentlyCalls[0] -eq $zipOutC) "Remove-ItemPermanently was called on the stray ZIP CreateFromDirectory left behind"
Write-Host ""

# ==============================================================================
#  Scenario D (user-requested): the ZIP output path must not be allowed to
#  land INSIDE the folder being zipped - $SourceDir would then effectively
#  be the zip's own "parent," and ZipFile.CreateFromDirectory can end up
#  trying to include the very ZIP it's writing as part of its own
#  contents (a self-referential write). Tested live, not assumed, since
#  the failure mode here (hang vs. throw vs. silently-corrupt output) was
#  not known in advance when this scenario was first written - it's known
#  NOW (confirmed live, repeatedly, on this real machine:
#  ZipFile.CreateFromDirectory throws "The process cannot access the
#  file" - it tries to read the in-progress output file, which is still
#  open for writing, as one of its own source entries): pinned to the
#  real, observed behavior (2026-08-31, caught by a same-day /code-review -
#  the original version branched on whether it threw and asserted
#  `Test-Assert $true` in the throw case, a tautology that would keep
#  passing even if this behavior later regressed to something worse,
#  like silent corruption).
# ==============================================================================
Write-Host "=== Scenario D: ZipOut located INSIDE SourceDir (self-referential) ===" -ForegroundColor Cyan
$sourceD = New-ScratchSourceDir -Name "scenario-d-source" -FileCount 2
$zipOutD = Join-Path $sourceD "output-inside-itself.zip"   # nested INSIDE the source dir being zipped

$threwD = $false
try {
    Compress-FolderToZip -SourceDir $sourceD -ZipOut $zipOutD
} catch {
    $threwD = $true
}

Test-Assert $threwD "a self-referential ZipOut throws (reading its own in-progress output file as a source entry fails), rather than silently corrupting or hanging"
Test-Assert (-not (Test-Path -LiteralPath $zipOutD)) "the broken/partial zip left behind by the failed attempt was cleaned up, not left as debris"
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
