<#
.SYNOPSIS
    Standalone test harness for Modules\ZipValidation.ps1.

.DESCRIPTION
    Dot-sources the real module and exercises it against real ZIP files
    built directly via System.IO.Compression (not via ZipCreation.ps1 -
    this harness stays independent of sibling modules, per this project's
    established harness philosophy).

.EXAMPLE
    .\Modules\_Harness\ZipValidation.Harness.ps1
#>

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName "System.IO.Compression"   # ZipArchiveMode, for this harness's own New-TestZip helper

. (Join-Path $PSScriptRoot "..\ZipValidation.ps1")

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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("zipvalidation-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray
Write-Host ""

function New-TestZip {
    <#
    .SYNOPSIS
        Builds a real ZIP at a fresh scratch path with one entry per name
        in -EntryNames (empty content is fine - only names/extensions
        matter for Test-ZipArchive). Pass @() for an empty (0-entry) ZIP.
    #>
    param([string[]]$EntryNames)
    $zipPath = Join-Path $scratchDir ("test-" + [guid]::NewGuid().ToString("N") + ".zip")
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $EntryNames) {
            $entry = $zip.CreateEntry($name)
            $writer = New-Object System.IO.StreamWriter($entry.Open())
            try { $writer.Write("x") } finally { $writer.Dispose() }
        }
    } finally {
        $zip.Dispose()
    }
    return $zipPath
}

# ==============================================================================
#  Scenario A: valid ZIP with .jxl entries, RequireJxlEntry=$true (default)
# ==============================================================================
Write-Host "=== Scenario A: valid ZIP with .jxl entries, RequireJxlEntry default (`$true) ===" -ForegroundColor Cyan
$zipA = New-TestZip -EntryNames @("page1.jxl", "page2.jxl", "page3.jxl")
$resultA = Test-ZipArchive -ZipPath $zipA
Test-Assert ($resultA.EntryCount -eq 3) ("EntryCount is 3 (got " + $resultA.EntryCount + ")")
Test-Assert ($resultA.JxlCount -eq 3) ("JxlCount is 3 (got " + $resultA.JxlCount + ")")
Write-Host ""

# ==============================================================================
#  Scenario B: valid ZIP with .jxl entries, RequireJxlEntry=$false explicitly
# ==============================================================================
Write-Host "=== Scenario B: valid ZIP with .jxl entries, RequireJxlEntry=`$false ===" -ForegroundColor Cyan
$zipB = New-TestZip -EntryNames @("page1.jxl", "page2.jxl")
$resultB = Test-ZipArchive -ZipPath $zipB -RequireJxlEntry $false
Test-Assert ($resultB.EntryCount -eq 2 -and $resultB.JxlCount -eq 2) "same correct counts regardless of RequireJxlEntry when .jxl IS present"
Write-Host ""

# ==============================================================================
#  Scenario C: entries present but none are .jxl, RequireJxlEntry=$true - throws
# ==============================================================================
Write-Host "=== Scenario C: no .jxl entries + RequireJxlEntry=`$true throws ===" -ForegroundColor Cyan
$zipC = New-TestZip -EntryNames @("readme.txt", "cover.png")
$threwC = $false
try { Test-ZipArchive -ZipPath $zipC } catch { $threwC = $true }
Test-Assert $threwC "throws when the archive has entries but none are .jxl and RequireJxlEntry defaults to `$true"
Write-Host ""

# ==============================================================================
#  Scenario D: entries present but none are .jxl, RequireJxlEntry=$false -
#  does NOT throw, matching mode 4's zip-only use case (arbitrary content).
# ==============================================================================
Write-Host "=== Scenario D: no .jxl entries + RequireJxlEntry=`$false does not throw ===" -ForegroundColor Cyan
$zipD = New-TestZip -EntryNames @("readme.txt", "cover.png")
$resultD = $null
$threwD = $false
try { $resultD = Test-ZipArchive -ZipPath $zipD -RequireJxlEntry $false } catch { $threwD = $true }
Test-Assert (-not $threwD) "does not throw when RequireJxlEntry is `$false, even with zero .jxl entries"
Test-Assert ($resultD.EntryCount -eq 2 -and $resultD.JxlCount -eq 0) "EntryCount=2, JxlCount=0 returned correctly"
Write-Host ""

# ==============================================================================
#  Scenario E: 0-entry ZIP throws regardless of RequireJxlEntry
# ==============================================================================
Write-Host "=== Scenario E: 0-entry ZIP always throws ===" -ForegroundColor Cyan
$zipE1 = New-TestZip -EntryNames @()
$threwE1 = $false
try { Test-ZipArchive -ZipPath $zipE1 } catch { $threwE1 = $true }
Test-Assert $threwE1 "0-entry ZIP throws with RequireJxlEntry=`$true (default)"

$zipE2 = New-TestZip -EntryNames @()
$threwE2 = $false
try { Test-ZipArchive -ZipPath $zipE2 -RequireJxlEntry $false } catch { $threwE2 = $true }
Test-Assert $threwE2 "0-entry ZIP throws even with RequireJxlEntry=`$false - an empty archive is never valid"
Write-Host ""

# ==============================================================================
#  Scenario F: .jxl matching is case-insensitive
# ==============================================================================
Write-Host "=== Scenario F: .JXL (uppercase) still counts as a jxl entry ===" -ForegroundColor Cyan
$zipF = New-TestZip -EntryNames @("PAGE1.JXL", "page2.Jxl")
$resultF = Test-ZipArchive -ZipPath $zipF
Test-Assert ($resultF.JxlCount -eq 2) ("both uppercase/mixed-case .jxl entries were counted (got JxlCount=" + $resultF.JxlCount + ")")
Write-Host ""

# ==============================================================================
#  Scenario G: mixed entries - correct EntryCount vs. JxlCount distinction
# ==============================================================================
Write-Host "=== Scenario G: mixed .jxl and non-.jxl entries ===" -ForegroundColor Cyan
$zipG = New-TestZip -EntryNames @("page1.jxl", "page2.jxl", "cover.png", "info.txt", "page3.jxl")
$resultG = Test-ZipArchive -ZipPath $zipG
Test-Assert ($resultG.EntryCount -eq 5) ("EntryCount is 5 (got " + $resultG.EntryCount + ")")
Test-Assert ($resultG.JxlCount -eq 3) ("JxlCount is 3, distinct from EntryCount (got " + $resultG.JxlCount + ")")
Write-Host ""

# ==============================================================================
#  Scenario H: nonexistent ZIP path - propagates a real, clear exception
#  from ZipFile.OpenRead itself (not our own guard).
# ==============================================================================
Write-Host "=== Scenario H: nonexistent ZIP path throws ===" -ForegroundColor Cyan
$missingZipH = Join-Path $scratchDir "does-not-exist.zip"
$threwH = $false
try { Test-ZipArchive -ZipPath $missingZipH } catch { $threwH = $true }
Test-Assert $threwH "Test-ZipArchive throws when the ZIP path doesn't exist"
Write-Host ""

# ==============================================================================
#  Scenario I: -ZipPath is Mandatory. Checked via parameter METADATA
#  (Get-Command), not by actually calling Test-ZipArchive with -ZipPath
#  omitted: PowerShell
#  only THROWS on a missing Mandatory parameter when it can't prompt for
#  one - with a real interactive console attached, it instead blocks the
#  whole process waiting on stdin forever, zero CPU/disk activity.
#  Matches ZipParallelProcessing.Harness.ps1's own Scenario E, which
#  avoids this same host-dependent hang.
# ==============================================================================
Write-Host "=== Scenario I: -ZipPath is Mandatory ===" -ForegroundColor Cyan
$attrI = (Get-Command Test-ZipArchive).Parameters['ZipPath'].Attributes |
    Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | Select-Object -First 1
Test-Assert ([bool]$attrI.Mandatory) "-ZipPath is Mandatory on Test-ZipArchive"
Write-Host ""

# ==============================================================================
#  Scenario F: a zip that can't be opened gets a message naming it
# ==============================================================================
Write-Host "=== Scenario F: missing zip -> clear error naming the file ===" -ForegroundColor Cyan
$missingF = Join-Path ([System.IO.Path]::GetTempPath()) ("no-such-" + [guid]::NewGuid().ToString("N") + ".zip")
$messageF = $null
try { $null = Test-ZipArchive -ZipPath $missingF } catch { $messageF = $_.ToString() }
Test-Assert ($null -ne $messageF -and $messageF -like ("*Could not open '" + $missingF + "' to verify it*")) "a missing zip throws a message that names the file and says what's wrong"
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
