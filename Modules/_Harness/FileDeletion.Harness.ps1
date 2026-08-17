<#
.SYNOPSIS
    Standalone test harness for Modules\FileDeletion.ps1.

.DESCRIPTION
    Dot-sources the real module (not a reimplementation) and exercises it
    against real files/folders in a scratch temp directory - not mocked
    I/O - so it tests actual behavior, not a guess at it. Scenario G goes
    one step further and verifies via the Windows Shell.Application COM
    object that Move-ToRecycleBin's target genuinely lands in the Recycle
    Bin (recoverable), not just "gone from its original location" - the
    same check Test-Path alone can't distinguish from
    Remove-ItemPermanently's behavior.

.EXAMPLE
    .\Modules\_Harness\FileDeletion.Harness.ps1
#>

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\FileDeletion.ps1")

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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("filedeletion-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray
Write-Host ""

function New-ScratchFile {
    param([string]$Name, [string]$Content = "scratch content")
    $path = Join-Path $scratchDir $Name
    $Content | Out-File -FilePath $path -Encoding UTF8
    return $path
}

function New-ScratchDir {
    param([string]$Name)
    $path = Join-Path $scratchDir $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    "nested content" | Out-File -FilePath (Join-Path $path "nested.txt") -Encoding UTF8
    return $path
}

function Test-ItemInRecycleBin {
    <#
    .SYNOPSIS
        Real check (not simulated) - true if an item named $FileName
        currently exists in the Windows Recycle Bin, via the
        Shell.Application COM object (Namespace 10 = Recycle Bin).
    #>
    param([string]$FileName)
    $shell = New-Object -ComObject Shell.Application
    $recycleBin = $shell.Namespace(10)
    $found = $false
    foreach ($item in $recycleBin.Items()) {
        if ($item.Name -eq $FileName) { $found = $true; break }
    }
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($recycleBin) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
    return $found
}

# ==============================================================================
#  Scenario A: Move-ToRecycleBin removes a file from its original location
# ==============================================================================
Write-Host "=== Scenario A: Move-ToRecycleBin removes a file ===" -ForegroundColor Cyan
$fileA = New-ScratchFile -Name "scenario-a.txt"
Test-Assert (Test-Path -LiteralPath $fileA) "file exists before Move-ToRecycleBin"
Move-ToRecycleBin -ItemPath $fileA
Test-Assert (-not (Test-Path -LiteralPath $fileA)) "file is gone from its original location after Move-ToRecycleBin"
Write-Host ""

# ==============================================================================
#  Scenario B: Move-ToRecycleBin removes a directory (with nested contents)
# ==============================================================================
Write-Host "=== Scenario B: Move-ToRecycleBin removes a directory ===" -ForegroundColor Cyan
$dirB = New-ScratchDir -Name "scenario-b-dir"
Test-Assert (Test-Path -LiteralPath $dirB) "directory exists before Move-ToRecycleBin"
Move-ToRecycleBin -ItemPath $dirB
Test-Assert (-not (Test-Path -LiteralPath $dirB)) "directory (with nested contents) is gone after Move-ToRecycleBin"
Write-Host ""

# ==============================================================================
#  Scenario C: Move-ToRecycleBin on a nonexistent path is a silent no-op
# ==============================================================================
Write-Host "=== Scenario C: Move-ToRecycleBin on a nonexistent path ===" -ForegroundColor Cyan
$missingC = Join-Path $scratchDir "does-not-exist.txt"
$threwC = $false
try { Move-ToRecycleBin -ItemPath $missingC } catch { $threwC = $true }
Test-Assert (-not $threwC) "Move-ToRecycleBin on a nonexistent path does not throw"
Write-Host ""

# ==============================================================================
#  Scenario D: Remove-ItemPermanently removes a file from its original location
# ==============================================================================
Write-Host "=== Scenario D: Remove-ItemPermanently removes a file ===" -ForegroundColor Cyan
$fileD = New-ScratchFile -Name "scenario-d.txt"
Test-Assert (Test-Path -LiteralPath $fileD) "file exists before Remove-ItemPermanently"
Remove-ItemPermanently -ItemPath $fileD
Test-Assert (-not (Test-Path -LiteralPath $fileD)) "file is gone from its original location after Remove-ItemPermanently"
Write-Host ""

# ==============================================================================
#  Scenario E: Remove-ItemPermanently removes a directory (with nested contents)
# ==============================================================================
Write-Host "=== Scenario E: Remove-ItemPermanently removes a directory ===" -ForegroundColor Cyan
$dirE = New-ScratchDir -Name "scenario-e-dir"
Test-Assert (Test-Path -LiteralPath $dirE) "directory exists before Remove-ItemPermanently"
Remove-ItemPermanently -ItemPath $dirE
Test-Assert (-not (Test-Path -LiteralPath $dirE)) "directory (with nested contents) is gone after Remove-ItemPermanently"
Write-Host ""

# ==============================================================================
#  Scenario F: Remove-ItemPermanently on a nonexistent path is a silent no-op
# ==============================================================================
Write-Host "=== Scenario F: Remove-ItemPermanently on a nonexistent path ===" -ForegroundColor Cyan
$missingF = Join-Path $scratchDir "also-does-not-exist.txt"
$threwF = $false
try { Remove-ItemPermanently -ItemPath $missingF } catch { $threwF = $true }
Test-Assert (-not $threwF) "Remove-ItemPermanently on a nonexistent path does not throw"
Write-Host ""

# ==============================================================================
#  Scenario G: Move-ToRecycleBin's target is genuinely recoverable in the
#  real Windows Recycle Bin - not just "gone from disk" (which alone
#  wouldn't distinguish it from Remove-ItemPermanently). Uses a
#  guid-stamped filename so the Shell.Application lookup is unambiguous
#  even if the Recycle Bin already has other items in it.
# ==============================================================================
Write-Host "=== Scenario G: Move-ToRecycleBin target actually lands in the Recycle Bin ===" -ForegroundColor Cyan
$uniqueNameG = "filedeletion-harness-" + [guid]::NewGuid().ToString("N") + ".txt"
$fileG = New-ScratchFile -Name $uniqueNameG
Move-ToRecycleBin -ItemPath $fileG
$foundInBinG = Test-ItemInRecycleBin -FileName $uniqueNameG
Test-Assert $foundInBinG "Move-ToRecycleBin's target is found in the real Windows Recycle Bin (genuinely recoverable, not just deleted)"
Write-Host ""

# ==============================================================================
#  Scenario H: Remove-Source routes to Move-ToRecycleBin when
#  $PermanentDelete is $false (default). Verified via a temporary
#  call-tracking override, not just a filesystem side effect, so the
#  routing decision itself is what's being tested.
# ==============================================================================
Write-Host "=== Scenario H: Remove-Source routes to Move-ToRecycleBin ===" -ForegroundColor Cyan
Initialize-FileDeletion -PermanentDelete $false

$script:moveCallsH = [System.Collections.Generic.List[string]]::new()
$script:permCallsH = [System.Collections.Generic.List[string]]::new()
$originalMove = ${function:Move-ToRecycleBin}
$originalPerm = ${function:Remove-ItemPermanently}
function Move-ToRecycleBin     { param([string]$ItemPath) $script:moveCallsH.Add($ItemPath) }
function Remove-ItemPermanently { param([string]$ItemPath) $script:permCallsH.Add($ItemPath) }

Remove-Source -ItemPath "C:\Fake\Path\For\Routing\Test.txt"

Test-Assert ($script:moveCallsH.Count -eq 1) "Remove-Source called Move-ToRecycleBin exactly once when PermanentDelete=`$false"
Test-Assert ($script:permCallsH.Count -eq 0) "Remove-Source did NOT call Remove-ItemPermanently when PermanentDelete=`$false"

${function:Move-ToRecycleBin}     = $originalMove
${function:Remove-ItemPermanently} = $originalPerm
Write-Host ""

# ==============================================================================
#  Scenario I: Remove-Source routes to Remove-ItemPermanently when
#  $PermanentDelete is $true. Same call-tracking technique as Scenario H.
# ==============================================================================
Write-Host "=== Scenario I: Remove-Source routes to Remove-ItemPermanently ===" -ForegroundColor Cyan
Initialize-FileDeletion -PermanentDelete $true

$script:moveCallsI = [System.Collections.Generic.List[string]]::new()
$script:permCallsI = [System.Collections.Generic.List[string]]::new()
$originalMove = ${function:Move-ToRecycleBin}
$originalPerm = ${function:Remove-ItemPermanently}
function Move-ToRecycleBin     { param([string]$ItemPath) $script:moveCallsI.Add($ItemPath) }
function Remove-ItemPermanently { param([string]$ItemPath) $script:permCallsI.Add($ItemPath) }

Remove-Source -ItemPath "C:\Fake\Path\For\Routing\Test2.txt"

Test-Assert ($script:permCallsI.Count -eq 1) "Remove-Source called Remove-ItemPermanently exactly once when PermanentDelete=`$true"
Test-Assert ($script:moveCallsI.Count -eq 0) "Remove-Source did NOT call Move-ToRecycleBin when PermanentDelete=`$true"

${function:Move-ToRecycleBin}     = $originalMove
${function:Remove-ItemPermanently} = $originalPerm
Initialize-FileDeletion -PermanentDelete $false   # restore the default for any later scenario
Write-Host ""

# ==============================================================================
#  Scenario J: -ItemPath is Mandatory on all three functions - calling
#  without it fails loudly (parameter binding error) instead of silently
#  no-op'ing, catching a caller bug early.
# ==============================================================================
Write-Host "=== Scenario J: -ItemPath is Mandatory ===" -ForegroundColor Cyan
$threwMoveJ = $false
try { Move-ToRecycleBin } catch { $threwMoveJ = $true }
Test-Assert $threwMoveJ "Move-ToRecycleBin without -ItemPath throws (Mandatory parameter)"

$threwPermJ = $false
try { Remove-ItemPermanently } catch { $threwPermJ = $true }
Test-Assert $threwPermJ "Remove-ItemPermanently without -ItemPath throws (Mandatory parameter)"

$threwSourceJ = $false
try { Remove-Source } catch { $threwSourceJ = $true }
Test-Assert $threwSourceJ "Remove-Source without -ItemPath throws (Mandatory parameter)"
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
