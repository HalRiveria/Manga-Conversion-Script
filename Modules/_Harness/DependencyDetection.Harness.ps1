<#
.SYNOPSIS
    Standalone test harness for Modules\DependencyDetection.ps1.

.DESCRIPTION
    Dot-sources the real module and exercises it against real filesystem
    paths and a real PATH-resolvable executable (cmd.exe) - not mocked -
    so it tests actual behavior, not a guess at it. Find-ExeCached is
    exercised with plain hashtables built in-line (no dependency on
    Config.ps1's Import-/Export-ScriptSettings - Find-ExeCached doesn't
    need them either, by design).

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
#  Scenario C2 (2026-09-02 review fix, live-confirmed): a DIRECTORY passed
#  as -UserPath (or sitting in the cache) must fall through, not be
#  accepted as-is - Test-PathSafely's own bare Test-Path used to return
#  $true for a directory too. Real trigger: a mistyped -CjxlPath pointing
#  at an install FOLDER instead of the .exe inside it (or a hand-edited
#  settings.json with the same mistake) - accepted silently, with no
#  error until every file in the library failed at cjxl-exec time with
#  an unrelated-looking error, instead of this project's own clear
#  "cjxl.exe could not be found..." message.
# ==============================================================================
Write-Host "=== Scenario C2: a directory as -UserPath (or a cached path) falls through, not accepted as-is ===" -ForegroundColor Cyan
$dirPathC2 = Join-Path $scratchDir "a-real-directory-not-an-exe"
New-Item -ItemType Directory -Path $dirPathC2 -Force | Out-Null
$resultC2 = Find-Exe -UserPath $dirPathC2 -ExeName "cmd"
Test-Assert ($resultC2 -ne $dirPathC2) "a directory -UserPath is not returned as-is"
Test-Assert ($null -ne $resultC2 -and (Test-Path -LiteralPath $resultC2 -PathType Leaf)) "it fell through to a real file instead (PATH lookup), not a directory"

$fakeSettingsC2 = @{ CachedExePath = $dirPathC2 }
$resultC2b = Find-ExeCached -Settings $fakeSettingsC2 -SettingsKey "CachedExePath" -ExeName "cmd"
Test-Assert ($resultC2b -ne $dirPathC2) "a directory sitting in the cache is not returned as-is either"
Test-Assert ($null -ne $resultC2b -and (Test-Path -LiteralPath $resultC2b -PathType Leaf)) "the cached-directory case also falls through to a real file"
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
#  Scenario D2 (2026-08-31 fix, caught by a same-day /code-review
#  full-codebase pass): a function or alias sharing $ExeName's name (a
#  real, not hypothetical, case - a user's own PowerShell profile
#  defining a "magick"/"cjxl" helper) used to be matched by a bare
#  Get-Command call, and its .Source is an EMPTY STRING, not $null -
#  still truthy for the old if-check, so Find-Exe returned "" instead of
#  falling through to -Candidates, breaking the documented "$null if not
#  found" contract AND skipping a real exe sitting at a candidate path.
# ==============================================================================
Write-Host "=== Scenario D2: a function/alias sharing the exe name is skipped, falls through to -Candidates ===" -ForegroundColor Cyan
function totally-fake-function-zzz { "shadow function, not a real exe" }
Set-Alias -Name totally-fake-alias-zzz -Value Get-ChildItem
try {
    $realCandidateD2 = Join-Path $scratchDir "candidate-real-exe-behind-shadow.exe"
    "fake exe content" | Out-File -FilePath $realCandidateD2 -Encoding UTF8

    $resultD2Func  = Find-Exe -ExeName "totally-fake-function-zzz" -Candidates @($realCandidateD2)
    $resultD2Alias = Find-Exe -ExeName "totally-fake-alias-zzz" -Candidates @()

    Test-Assert ($resultD2Func -eq $realCandidateD2) ("a shadowing FUNCTION was skipped, real -Candidates exe found instead (got '" + $resultD2Func + "')")
    Test-Assert ($null -eq $resultD2Alias) ("a shadowing ALIAS with no -Candidates correctly returns `$null, not an empty string (got '" + $resultD2Alias + "', type " + $(if ($null -ne $resultD2Alias) { $resultD2Alias.GetType().Name } else { "`$null" }) + ")")
} finally {
    Remove-Item -Path Function:\totally-fake-function-zzz -ErrorAction SilentlyContinue
    Remove-Item -Path Alias:\totally-fake-alias-zzz -ErrorAction SilentlyContinue
}
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
#  Scenario H: Find-ExeCached - a valid cached path is used without a
#  fresh search (proven by a -Candidates value that would fail if used)
# ==============================================================================
Write-Host "=== Scenario H: Find-ExeCached uses a valid cached path, skipping fresh search ===" -ForegroundColor Cyan
$cachedPathH = Join-Path $scratchDir "cached-cjxl.exe"
"fake exe content" | Out-File -FilePath $cachedPathH -Encoding UTF8
$settingsH = @{ CjxlPath = $cachedPathH }
$resultH = Find-ExeCached -Settings $settingsH -SettingsKey "CjxlPath" -ExeName "totally-fake-exe-name-zzz" -Candidates @("C:\also\does\not\exist.exe")
Test-Assert ($resultH -eq $cachedPathH) "a valid cached path was returned"
Test-Assert ($settingsH.CjxlPath -eq $cachedPathH) "the cache was left unchanged"
Write-Host ""

# ==============================================================================
#  Scenario I: Find-ExeCached - a stale cached path (no longer exists on
#  disk) falls through to a fresh search, same as a stale -UserPath does
# ==============================================================================
Write-Host "=== Scenario I: Find-ExeCached falls through when the cached path no longer exists ===" -ForegroundColor Cyan
$settingsI = @{ CjxlPath = (Join-Path $scratchDir "cached-but-deleted.exe") }
$resultI = Find-ExeCached -Settings $settingsI -SettingsKey "CjxlPath" -ExeName "cmd"
Test-Assert ($null -ne $resultI -and (Test-Path -LiteralPath $resultI)) "fell through to a real, existing path via PATH lookup"
Test-Assert ($resultI -like "*cmd.exe") "the fresh search found cmd.exe"
Write-Host ""

# ==============================================================================
#  Scenario J: Find-ExeCached - a fresh detection result gets written back
#  into $Settings (mutated in place) so a later call can use the cache
# ==============================================================================
Write-Host "=== Scenario J: Find-ExeCached writes a fresh result back into `$Settings ===" -ForegroundColor Cyan
$settingsJ = @{ CjxlPath = "" }
$resultJ = Find-ExeCached -Settings $settingsJ -SettingsKey "CjxlPath" -ExeName "cmd"
Test-Assert ($settingsJ.CjxlPath -eq $resultJ) "the freshly-found path was cached into `$Settings.CjxlPath"

# a second call with the now-cached value present should return the same
# path without needing PATH/-Candidates at all
$settingsJ2 = @{ CjxlPath = $resultJ }
$resultJ2 = Find-ExeCached -Settings $settingsJ2 -SettingsKey "CjxlPath" -ExeName "totally-fake-exe-name-zzz" -Candidates @("C:\also\does\not\exist.exe")
Test-Assert ($resultJ2 -eq $resultJ) "a subsequent call reuses the now-cached path"
Write-Host ""

# ==============================================================================
#  Scenario K: Find-ExeCached - an explicit -UserPath wins over the cache
#  and is deliberately NOT written back into it (a one-off override should
#  not silently become the new persisted default)
# ==============================================================================
Write-Host "=== Scenario K: -UserPath wins over the cache and does not overwrite it ===" -ForegroundColor Cyan
$cachedPathK = Join-Path $scratchDir "cached-cjxl-k.exe"
"fake exe content" | Out-File -FilePath $cachedPathK -Encoding UTF8
$overridePathK = Join-Path $scratchDir "override-cjxl-k.exe"
"fake exe content" | Out-File -FilePath $overridePathK -Encoding UTF8
$settingsK = @{ CjxlPath = $cachedPathK }
$resultK = Find-ExeCached -Settings $settingsK -SettingsKey "CjxlPath" -UserPath $overridePathK -ExeName "totally-fake-exe-name-zzz"
Test-Assert ($resultK -eq $overridePathK) "the explicit -UserPath override was returned, not the cached path"
Test-Assert ($settingsK.CjxlPath -eq $cachedPathK) "the cache still holds its original value - the override was not persisted"
Write-Host ""

# ==============================================================================
#  Scenario L: Find-ExeCached - nothing found anywhere returns `$null` and
#  leaves the cache untouched (does not cache a null result)
# ==============================================================================
Write-Host "=== Scenario L: Find-ExeCached returns `$null and leaves the cache untouched when nothing is found ===" -ForegroundColor Cyan
$settingsL = @{ CjxlPath = "" }
$resultL = Find-ExeCached -Settings $settingsL -SettingsKey "CjxlPath" -ExeName "totally-fake-exe-name-zzz" -Candidates @((Join-Path $scratchDir "nope.exe"))
Test-Assert ($null -eq $resultL) "returns `$null when nothing is found anywhere"
Test-Assert ($settingsL.CjxlPath -eq "") "the cache was not polluted with a null/failed result"
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
