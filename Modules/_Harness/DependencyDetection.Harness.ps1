<#
.SYNOPSIS
    Standalone test harness for Modules\DependencyDetection.ps1.

.DESCRIPTION
    Dot-sources the real module and exercises it against real filesystem
    paths and a real PATH-resolvable executable (cmd.exe) - not mocked -
    so it tests actual behavior, not a guess at it.

.EXAMPLE
    .\Modules\_Harness\DependencyDetection.Harness.ps1
#>

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\DependencyDetection.ps1")

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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dependencydetection-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray
Write-Host ""

# ==============================================================================
#  Scenario A: -UserPath, when it exists, wins immediately - no PATH or
#  -Candidates lookup needed.
# ==============================================================================
Write-Host "=== Scenario A: -UserPath wins when it exists ===" -ForegroundColor Cyan
$userPathA = Join-Path $scratchDir "my-cjxl.exe"
"fake exe content" | Out-File -FilePath $userPathA -Encoding UTF8
$resultA = Find-Exe -UserPath $userPathA -ExeName "totally-fake-exe-name-zzz" -Candidates @("C:\also\does\not\exist.exe")
Test-Assert ($resultA -eq $userPathA) "an existing -UserPath is returned as-is, without needing PATH/-Candidates"
Write-Host ""

# ==============================================================================
#  Scenario B: -UserPath given but it does NOT exist - falls through to
#  PATH/-Candidates instead of failing outright.
# ==============================================================================
Write-Host "=== Scenario B: nonexistent -UserPath falls through ===" -ForegroundColor Cyan
$staleUserPathB = Join-Path $scratchDir "stale-path-does-not-exist.exe"
$resultB = Find-Exe -UserPath $staleUserPathB -ExeName "cmd"
Test-Assert ($resultB -ne $staleUserPathB) "a nonexistent -UserPath is not returned as-is"
Test-Assert ($null -ne $resultB -and (Test-Path -LiteralPath $resultB)) "it fell through to a real, existing path instead (PATH lookup)"
Write-Host ""

# ==============================================================================
#  Scenario C: found via PATH (Get-Command) - using a real executable
#  (cmd.exe) guaranteed present on any Windows machine, not a fake name.
# ==============================================================================
Write-Host "=== Scenario C: found via PATH ===" -ForegroundColor Cyan
$resultC = Find-Exe -ExeName "cmd"
Test-Assert ($null -ne $resultC) "cmd was found via PATH"
Test-Assert (Test-Path -LiteralPath $resultC) "the PATH-resolved path actually exists on disk"
Test-Assert ($resultC -like "*cmd.exe") "the PATH-resolved path points at cmd.exe"
Write-Host ""

# ==============================================================================
#  Scenario D: not in PATH, found via -Candidates - picks the first
#  candidate that actually exists, in order (not just any).
# ==============================================================================
Write-Host "=== Scenario D: found via -Candidates, first-existing-wins ===" -ForegroundColor Cyan
$missingCandidateD = Join-Path $scratchDir "candidate-1-does-not-exist.exe"
$realCandidateD    = Join-Path $scratchDir "candidate-2-exists.exe"
"fake exe content" | Out-File -FilePath $realCandidateD -Encoding UTF8
$thirdCandidateD   = Join-Path $scratchDir "candidate-3-also-exists-but-should-not-be-picked.exe"
"fake exe content" | Out-File -FilePath $thirdCandidateD -Encoding UTF8

$resultD = Find-Exe -ExeName "totally-fake-exe-name-zzz" -Candidates @($missingCandidateD, $realCandidateD, $thirdCandidateD)
Test-Assert ($resultD -eq $realCandidateD) "the first EXISTING candidate in order was picked (not the first in the list, not a later one)"
Write-Host ""

# ==============================================================================
#  Scenario E: not found anywhere (no -UserPath, not in PATH, no matching
#  -Candidates) - returns `$null`, not an error.
# ==============================================================================
Write-Host "=== Scenario E: not found anywhere returns `$null ===" -ForegroundColor Cyan
$notFoundThrew = $false
$resultE = "sentinel - should be overwritten"
try {
    $resultE = Find-Exe -ExeName "totally-fake-exe-name-zzz" -Candidates @(
        (Join-Path $scratchDir "nope-1.exe"),
        (Join-Path $scratchDir "nope-2.exe")
    )
} catch { $notFoundThrew = $true }
Test-Assert (-not $notFoundThrew) "Find-Exe does not throw when nothing is found"
Test-Assert ($null -eq $resultE) "Find-Exe returns `$null when nothing is found"
Write-Host ""

# ==============================================================================
#  Scenario F: -Candidates omitted entirely (defaults to empty) - still
#  works via PATH without erroring on a missing parameter.
# ==============================================================================
Write-Host "=== Scenario F: -Candidates is optional ===" -ForegroundColor Cyan
$noCandidatesThrew = $false
$resultF = $null
try { $resultF = Find-Exe -ExeName "cmd" } catch { $noCandidatesThrew = $true }
Test-Assert (-not $noCandidatesThrew) "Find-Exe works without -Candidates being supplied at all"
Test-Assert ($null -ne $resultF) "PATH lookup still succeeds with no -Candidates"
Write-Host ""

# ==============================================================================
#  Scenario G: -ExeName is Mandatory - omitting it fails loudly.
# ==============================================================================
Write-Host "=== Scenario G: -ExeName is Mandatory ===" -ForegroundColor Cyan
$threwG = $false
try { Find-Exe -UserPath "C:\whatever.exe" } catch { $threwG = $true }
Test-Assert $threwG "Find-Exe without -ExeName throws (Mandatory parameter)"
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
