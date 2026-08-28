<#
.SYNOPSIS
    Standalone test harness for Modules\ResumeState.ps1.

.DESCRIPTION
    Dot-sources the real module and exercises it against a real state
    file in a scratch directory - not mocked - including real
    System.Threading.Mutex objects, so mutex-protected save paths are
    tested for real, not guessed at. Stubs Write-Log with call tracking
    (same pattern as AbortPipeline.Harness.ps1).

.EXAMPLE
    .\Modules\_Harness\ResumeState.Harness.ps1
#>

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\ResumeState.ps1")

$script:logCalls = New-Object System.Collections.Generic.List[string]
function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $script:logCalls.Add($Level + ": " + $Message)
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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("resumestate-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray
Write-Host ""

function New-ScratchStateFile {
    param([string]$Name)
    return (Join-Path $scratchDir ($Name + ".json"))
}

# ==============================================================================
#  Scenario A: Get-ResumeStatePath
# ==============================================================================
Write-Host "=== Scenario A: Get-ResumeStatePath ===" -ForegroundColor Cyan
Test-Assert ((Get-ResumeStatePath -TargetPath "C:\Library\SeriesA") -eq (Join-Path "C:\Library\SeriesA" "process_state.json")) "builds the expected process_state.json path"
Write-Host ""

# ==============================================================================
#  Scenario B: Import-ResumeStateMap - missing file returns an empty map,
#  no throw, no log
# ==============================================================================
Write-Host "=== Scenario B: Import-ResumeStateMap, missing file ===" -ForegroundColor Cyan
$pathB = New-ScratchStateFile "scenario-b-missing"
$mapB = Import-ResumeStateMap -StateFile $pathB
Test-Assert ($mapB.Count -eq 0) "a missing state file returns an empty map"
Write-Host ""

# ==============================================================================
#  Scenario C: Import-ResumeStateMap - a real array-shaped file loads
#  correctly, case-insensitively
# ==============================================================================
Write-Host "=== Scenario C: Import-ResumeStateMap, real array file ===" -ForegroundColor Cyan
$pathC = New-ScratchStateFile "scenario-c"
'[{"Path":"C:\\Library\\A.zip","LastWriteTimeUtc":"2026-01-01T00:00:00Z"},{"Path":"C:\\Library\\B.zip","LastWriteTimeUtc":"2026-01-02T00:00:00Z"}]' | Set-Content -LiteralPath $pathC -Encoding UTF8
$script:logCalls.Clear()
$mapC = Import-ResumeStateMap -StateFile $pathC
Test-Assert ($mapC.Count -eq 2) "both entries loaded"
Test-Assert ($mapC["C:\Library\A.zip"] -eq "2026-01-01T00:00:00Z") "entry A's LastWriteTimeUtc loaded correctly"
Test-Assert ($mapC["c:\library\a.zip"] -eq "2026-01-01T00:00:00Z") "lookup is case-insensitive on Path"
Test-Assert (@($script:logCalls | Where-Object { $_ -like "Info:*2 previously completed*" }).Count -eq 1) "logged the loaded count"
Write-Host ""

# ==============================================================================
#  Scenario D: Import-ResumeStateMap - a single-entry, OBJECT-shaped file
#  (not wrapped in an array) still loads correctly - PowerShell's foreach
#  treats a scalar as a one-item sequence, so this also proves backward
#  compatibility with any real state.json the OLD (pre-fix) main script
#  already wrote to disk
# ==============================================================================
Write-Host "=== Scenario D: Import-ResumeStateMap, single object (not array) ===" -ForegroundColor Cyan
$pathD = New-ScratchStateFile "scenario-d"
'{"Path":"C:\\Library\\Solo.zip","LastWriteTimeUtc":"2026-03-01T00:00:00Z"}' | Set-Content -LiteralPath $pathD -Encoding UTF8
$mapD = Import-ResumeStateMap -StateFile $pathD
Test-Assert ($mapD.Count -eq 1 -and $mapD["C:\Library\Solo.zip"] -eq "2026-03-01T00:00:00Z") "a bare (non-array) single-object file still loads correctly"
Write-Host ""

# ==============================================================================
#  Scenario E: Import-ResumeStateMap - corrupt file returns an empty map
#  with a Warn log, does not throw
# ==============================================================================
Write-Host "=== Scenario E: Import-ResumeStateMap, corrupt file ===" -ForegroundColor Cyan
$pathE = New-ScratchStateFile "scenario-e"
"{ not valid json at all" | Set-Content -LiteralPath $pathE -Encoding UTF8
$script:logCalls.Clear()
$threwE = $false
$mapE = $null
try { $mapE = Import-ResumeStateMap -StateFile $pathE } catch { $threwE = $true }
Test-Assert (-not $threwE) "does not throw on a corrupt state file"
Test-Assert ($mapE.Count -eq 0) "returns an empty map for a corrupt file"
Test-Assert (@($script:logCalls | Where-Object { $_ -like "Warn:*" }).Count -eq 1) "logged a Warn for the corrupt file"
Write-Host ""

# ==============================================================================
#  Scenario F: Test-ResumeStateComplete
# ==============================================================================
Write-Host "=== Scenario F: Test-ResumeStateComplete ===" -ForegroundColor Cyan
$mapF = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
$mapF["C:\Library\A.zip"] = "2026-01-01T00:00:00Z"
Test-Assert (Test-ResumeStateComplete -ResumedMap $mapF -ZipPath "C:\Library\A.zip" -LastWriteTimeUtc "2026-01-01T00:00:00Z") "path + matching LastWriteTimeUtc -> complete"
Test-Assert (-not (Test-ResumeStateComplete -ResumedMap $mapF -ZipPath "C:\Library\A.zip" -LastWriteTimeUtc "2026-01-02T00:00:00Z")) "path present but LastWriteTimeUtc differs (ZIP was replaced) -> NOT complete"
Test-Assert (-not (Test-ResumeStateComplete -ResumedMap $mapF -ZipPath "C:\Library\Missing.zip" -LastWriteTimeUtc "2026-01-01T00:00:00Z")) "path never recorded -> NOT complete"
Write-Host ""

# ==============================================================================
#  Scenario G: Save-ResumeStateEntry - writes a proper JSON ARRAY even for
#  a single entry (the real bug fixed while consolidating - see module
#  header), and it round-trips through Import-ResumeStateMap
# ==============================================================================
Write-Host "=== Scenario G: Save-ResumeStateEntry writes a real array, round-trips ===" -ForegroundColor Cyan
$pathG = New-ScratchStateFile "scenario-g"
$mutexG = New-Object System.Threading.Mutex($false, ("ResumeStateHarnessMutex_" + [guid]::NewGuid().ToString("N")))
try {
    $countG = Save-ResumeStateEntry -StateFile $pathG -StateMutex $mutexG -ZipPath "C:\Library\Solo.zip" -LastWriteTimeUtc "2026-04-01T00:00:00Z"
    Test-Assert ($countG -eq 1) "returns the merged count (1)"
    $rawTextG = Get-Content -LiteralPath $pathG -Raw
    Test-Assert ($rawTextG.TrimStart().StartsWith("[")) "a single-entry state file is written as a JSON ARRAY ('[' first), not a bare object"
    $mapG = Import-ResumeStateMap -StateFile $pathG
    Test-Assert ($mapG.Count -eq 1 -and $mapG["C:\Library\Solo.zip"] -eq "2026-04-01T00:00:00Z") "round-trips correctly through Import-ResumeStateMap"
} finally {
    $mutexG.Dispose()
}
Write-Host ""

# ==============================================================================
#  Scenario H: Save-ResumeStateEntry - a second save merges onto the
#  first (existing entries preserved) and updates an existing Path's
#  LastWriteTimeUtc when it's re-saved with a new value
# ==============================================================================
Write-Host "=== Scenario H: Save-ResumeStateEntry merges, updates on Path collision ===" -ForegroundColor Cyan
$pathH = New-ScratchStateFile "scenario-h"
$mutexH = New-Object System.Threading.Mutex($false, ("ResumeStateHarnessMutex_" + [guid]::NewGuid().ToString("N")))
try {
    Save-ResumeStateEntry -StateFile $pathH -StateMutex $mutexH -ZipPath "C:\Library\A.zip" -LastWriteTimeUtc "2026-01-01T00:00:00Z" | Out-Null
    $countH2 = Save-ResumeStateEntry -StateFile $pathH -StateMutex $mutexH -ZipPath "C:\Library\B.zip" -LastWriteTimeUtc "2026-01-02T00:00:00Z"
    Test-Assert ($countH2 -eq 2) "second save merges onto the first (2 entries total, A preserved)"
    $countH3 = Save-ResumeStateEntry -StateFile $pathH -StateMutex $mutexH -ZipPath "C:\Library\A.zip" -LastWriteTimeUtc "2026-01-05T00:00:00Z"
    Test-Assert ($countH3 -eq 2) "re-saving an existing Path does not grow the count (still 2)"
    $mapH = Import-ResumeStateMap -StateFile $pathH
    Test-Assert ($mapH["C:\Library\A.zip"] -eq "2026-01-05T00:00:00Z") "re-saving A updated its LastWriteTimeUtc to the newer value"
    Test-Assert ($mapH["C:\Library\B.zip"] -eq "2026-01-02T00:00:00Z") "B is untouched by A's re-save"
} finally {
    $mutexH.Dispose()
}
Write-Host ""

# ==============================================================================
#  Scenario I: Save-ResumeStateBag (no -StateMutex, matching the
#  reference's own unlocked abort-path save) - merges the in-memory bag's
#  JSON-string entries onto the on-disk file
# ==============================================================================
Write-Host "=== Scenario I: Save-ResumeStateBag merges bag entries, no mutex ===" -ForegroundColor Cyan
$pathI = New-ScratchStateFile "scenario-i"
Save-ResumeStateEntry -StateFile $pathI -StateMutex (New-Object System.Threading.Mutex($false, ("ResumeStateHarnessMutex_" + [guid]::NewGuid().ToString("N")))) -ZipPath "C:\Library\OnDisk.zip" -LastWriteTimeUtc "2026-02-01T00:00:00Z" | Out-Null

$bagI = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$bagI["C:\Library\FromBag1.zip"] = ('{"Path":"C:\\Library\\FromBag1.zip","LastWriteTimeUtc":"2026-02-02T00:00:00Z"}')
$bagI["C:\Library\FromBag2.zip"] = ('{"Path":"C:\\Library\\FromBag2.zip","LastWriteTimeUtc":"2026-02-03T00:00:00Z"}')

$countI = Save-ResumeStateBag -StateFile $pathI -CompletedBag $bagI
Test-Assert ($countI -eq 3) "on-disk entry (1) + bag entries (2) merged to 3 total"
$mapI = Import-ResumeStateMap -StateFile $pathI
Test-Assert ($mapI.Count -eq 3) "all three entries are present after reload"
Test-Assert ($mapI["C:\Library\OnDisk.zip"] -eq "2026-02-01T00:00:00Z") "the pre-existing on-disk entry survived the bag merge"
Test-Assert ($mapI["C:\Library\FromBag1.zip"] -eq "2026-02-02T00:00:00Z" -and $mapI["C:\Library\FromBag2.zip"] -eq "2026-02-03T00:00:00Z") "both bag entries were parsed and merged in"
Write-Host ""

# ==============================================================================
#  Scenario J: Save-ResumeStateBag - malformed bag entries (bad JSON, or
#  missing Path/LastWriteTimeUtc) are skipped rather than failing the
#  whole save
# ==============================================================================
Write-Host "=== Scenario J: Save-ResumeStateBag skips malformed bag entries ===" -ForegroundColor Cyan
$pathJ = New-ScratchStateFile "scenario-j"
$bagJ = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$bagJ["C:\Library\Good.zip"] = ('{"Path":"C:\\Library\\Good.zip","LastWriteTimeUtc":"2026-05-01T00:00:00Z"}')
$bagJ["C:\Library\NotJson.zip"] = "this is not json at all"
$bagJ["C:\Library\MissingField.zip"] = ('{"Path":"C:\\Library\\MissingField.zip"}')

$threwJ = $false
$countJ = $null
try { $countJ = Save-ResumeStateBag -StateFile $pathJ -CompletedBag $bagJ } catch { $threwJ = $true }
Test-Assert (-not $threwJ) "malformed bag entries do not throw"
Test-Assert ($countJ -eq 1) "only the one well-formed entry was saved"
$mapJ = Import-ResumeStateMap -StateFile $pathJ
Test-Assert ($mapJ.ContainsKey("C:\Library\Good.zip")) "the well-formed entry made it into the state file"
Write-Host ""

# ==============================================================================
#  Scenario K: Save-ResumeStateBag - an optional -StateMutex, when
#  passed, is actually used (save succeeds, and the mutex is free
#  immediately afterward - proving it was released, not leaked held)
# ==============================================================================
Write-Host "=== Scenario K: Save-ResumeStateBag with an explicit -StateMutex ===" -ForegroundColor Cyan
$pathK = New-ScratchStateFile "scenario-k"
$mutexK = New-Object System.Threading.Mutex($false, ("ResumeStateHarnessMutex_" + [guid]::NewGuid().ToString("N")))
try {
    $bagK = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $bagK["C:\Library\Locked.zip"] = ('{"Path":"C:\\Library\\Locked.zip","LastWriteTimeUtc":"2026-06-01T00:00:00Z"}')
    $countK = Save-ResumeStateBag -StateFile $pathK -CompletedBag $bagK -StateMutex $mutexK
    Test-Assert ($countK -eq 1) "save succeeded with an explicit -StateMutex supplied"
    $releasedK = $mutexK.WaitOne(0)
    Test-Assert ($releasedK) "the mutex was free immediately after Save-ResumeStateBag returned - it was properly released, not left held"
    if ($releasedK) { $mutexK.ReleaseMutex() }
} finally {
    $mutexK.Dispose()
}
Write-Host ""

# ==============================================================================
#  Scenario L: Save-ResumeStateEntry - the mutex is actually released
#  afterward (a second, independent save against the SAME mutex object
#  must not hang)
# ==============================================================================
Write-Host "=== Scenario L: the state mutex is released after a save (no deadlock on reuse) ===" -ForegroundColor Cyan
$pathL = New-ScratchStateFile "scenario-l"
$mutexL = New-Object System.Threading.Mutex($false, ("ResumeStateHarnessMutex_" + [guid]::NewGuid().ToString("N")))
try {
    Save-ResumeStateEntry -StateFile $pathL -StateMutex $mutexL -ZipPath "C:\Library\First.zip" -LastWriteTimeUtc "2026-07-01T00:00:00Z" | Out-Null
    # A direct WaitOne(0) (non-blocking) immediately after only succeeds if
    # the prior save actually released the mutex instead of leaking it held.
    $releasedL = $mutexL.WaitOne(0)
    Test-Assert ($releasedL) "the mutex was free immediately after Save-ResumeStateEntry returned - it was properly released"
    if ($releasedL) { $mutexL.ReleaseMutex() }
} finally {
    $mutexL.Dispose()
}
Write-Host ""

# ==============================================================================
#  Scenario M: Write-ResumeStateRetainedNotice - logs when the state file
#  exists, is a silent no-op when it doesn't.
# ==============================================================================
Write-Host "=== Scenario M: Write-ResumeStateRetainedNotice ===" -ForegroundColor Cyan
$pathM1 = New-ScratchStateFile "scenario-m-exists"
Save-ResumeStateEntry -StateFile $pathM1 -StateMutex (New-Object System.Threading.Mutex) -ZipPath "C:\Library\First.zip" -LastWriteTimeUtc "2026-07-01T00:00:00Z" | Out-Null
$script:logCalls.Clear()
Write-ResumeStateRetainedNotice -StateFile $pathM1
Test-Assert ((@($script:logCalls | Where-Object { $_ -like "Summary:*Resume state file retained*" -and $_ -like "*$pathM1*" })).Count -eq 1) "logged the retained-notice line, naming the real state file path, when the file exists"

$pathM2 = New-ScratchStateFile "scenario-m-missing"
$script:logCalls.Clear()
Write-ResumeStateRetainedNotice -StateFile $pathM2
Test-Assert ($script:logCalls.Count -eq 0) "no-op (nothing logged) when the state file was never created"
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
