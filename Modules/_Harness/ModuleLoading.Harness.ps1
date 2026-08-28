<#
.SYNOPSIS
    Standalone test harness for ModuleLoading.ps1.

.DESCRIPTION
    ModuleLoading.ps1 lives at the repo root (NOT Modules\ - see its own
    header for why), so this harness dot-sources it via a relative path
    up from Modules\_Harness\ rather than the usual "..\<Name>.ps1"
    Modules\ pattern every other harness uses. Fully standalone - no
    other modules needed (ModuleLoading.ps1 has zero forward references
    by design).

.EXAMPLE
    .\Modules\_Harness\ModuleLoading.Harness.ps1
#>

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\ModuleLoading.ps1")

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

function New-ScriptedPrompt {
    <#
    .SYNOPSIS
        Same idiom as Menu.Harness.ps1's own New-ScriptedPrompt - returns
        each queued response in order, throws if asked for more than
        were queued, so a real infinite-reprompt bug fails loudly
        instead of hanging the test.
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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("moduleloading-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray
Write-Host ""

function New-FakeModulesDir {
    <#
    .SYNOPSIS
        Creates a directory at $RelativePath containing every file
        Get-ExpectedModuleFileNames lists (empty placeholder content -
        only presence/name matters to Test-ModulesFolderCandidate),
        optionally omitting a few names to simulate an incomplete folder.
    #>
    param([string]$RelativePath, [string[]]$OmitFiles = @())
    $path = Join-Path $scratchDir $RelativePath
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    foreach ($fileName in (Get-ExpectedModuleFileNames)) {
        if ($OmitFiles -icontains $fileName) { continue }
        [System.IO.File]::WriteAllText((Join-Path $path $fileName), "# placeholder")
    }
    return $path
}

# ==============================================================================
#  Scenario A: Get-ExpectedModuleFileNames - real, current list (19 names,
#  matches the actual Modules\ folder as of this session - a drift check,
#  not just a shape check)
# ==============================================================================
Write-Host "=== Scenario A: Get-ExpectedModuleFileNames ===" -ForegroundColor Cyan
$expectedA = Get-ExpectedModuleFileNames
Test-Assert ($expectedA.Count -eq 19) ("19 expected module names (got " + $expectedA.Count + ")")
Test-Assert ($expectedA -icontains "Controller.ps1") "list includes Controller.ps1 (the 19th module, added the same session)"
Test-Assert (($expectedA | Sort-Object -Unique).Count -eq $expectedA.Count) "no duplicate names in the list"

$realModulesDir = Join-Path $PSScriptRoot ".."
$realFileNames = @(Get-ChildItem -LiteralPath $realModulesDir -Filter "*.ps1" -File | ForEach-Object { $_.Name })
$missingFromRealA = @($expectedA | Where-Object { $realFileNames -inotcontains $_ })
$extraInRealA     = @($realFileNames | Where-Object { $expectedA -inotcontains $_ })
Test-Assert ($missingFromRealA.Count -eq 0) ("every expected name actually exists in the real Modules\ folder (missing: " + ($missingFromRealA -join ", ") + ")")
Test-Assert ($extraInRealA.Count -eq 0) ("no real Modules\ file is missing from the expected list (extra: " + ($extraInRealA -join ", ") + ") - catches drift the moment a 20th module gets added without updating this file")
Write-Host ""

# ==============================================================================
#  Scenario B: Test-ModulesFolderCandidate - a complete folder is valid
# ==============================================================================
Write-Host "=== Scenario B: complete candidate folder is valid ===" -ForegroundColor Cyan
$completeB = New-FakeModulesDir -RelativePath "scenario-b\Modules"
$resultB = Test-ModulesFolderCandidate -CandidatePath $completeB
Test-Assert ($resultB.IsValid) "a folder with all 19 expected files is valid"
Test-Assert ($resultB.MissingFiles.Count -eq 0) "no missing files reported"
Write-Host ""

# ==============================================================================
#  Scenario C: Test-ModulesFolderCandidate - an incomplete folder is
#  invalid and names exactly what's missing
# ==============================================================================
Write-Host "=== Scenario C: incomplete candidate folder is invalid ===" -ForegroundColor Cyan
$incompleteC = New-FakeModulesDir -RelativePath "scenario-c\Modules" -OmitFiles @("Logging.ps1", "Controller.ps1")
$resultC = Test-ModulesFolderCandidate -CandidatePath $incompleteC
Test-Assert (-not $resultC.IsValid) "a folder missing 2 of 19 expected files is invalid"
Test-Assert ($resultC.MissingFiles.Count -eq 2 -and $resultC.MissingFiles -icontains "Logging.ps1" -and $resultC.MissingFiles -icontains "Controller.ps1") "names exactly the 2 missing files, nothing else"
Write-Host ""

# ==============================================================================
#  Scenario D: Test-ModulesFolderCandidate - a path that doesn't exist at
#  all is invalid, reporting the FULL expected list as missing (not left
#  ambiguous)
# ==============================================================================
Write-Host "=== Scenario D: nonexistent path ===" -ForegroundColor Cyan
$resultD = Test-ModulesFolderCandidate -CandidatePath (Join-Path $scratchDir "scenario-d\DoesNotExist")
Test-Assert (-not $resultD.IsValid) "a nonexistent path is invalid"
Test-Assert ($resultD.MissingFiles.Count -eq 19) "reports the full 19-item expected list as missing, not an empty/ambiguous result"
Write-Host ""

# ==============================================================================
#  Scenario E: Resolve-ModulesPath - the default path is valid, used
#  immediately, PromptFunc never called
# ==============================================================================
Write-Host "=== Scenario E: valid default path - no prompt needed ===" -ForegroundColor Cyan
$defaultE = New-FakeModulesDir -RelativePath "scenario-e\Modules"
$promptE = New-ScriptedPrompt -Responses @()   # any call at all should throw
$resultE = Resolve-ModulesPath -DefaultPath $defaultE -PromptFunc $promptE
Test-Assert ($resultE.Path -eq $defaultE -and $resultE.Source -eq "Default") "resolved to the valid default path, Source = Default"
Write-Host ""

# ==============================================================================
#  Scenario F: Resolve-ModulesPath - default is missing, persisted path is
#  valid, used without prompting
# ==============================================================================
Write-Host "=== Scenario F: default missing, persisted path is valid ===" -ForegroundColor Cyan
$missingDefaultF = Join-Path $scratchDir "scenario-f\NoSuchDefault"
$persistedF = New-FakeModulesDir -RelativePath "scenario-f\RealModules"
$promptF = New-ScriptedPrompt -Responses @()
$resultF = Resolve-ModulesPath -DefaultPath $missingDefaultF -PersistedPath $persistedF -PromptFunc $promptF
Test-Assert ($resultF.Path -eq $persistedF -and $resultF.Source -eq "Persisted") "resolved to the valid persisted path, Source = Persisted"
Write-Host ""

# ==============================================================================
#  Scenario G: Resolve-ModulesPath - both default AND persisted are
#  invalid, prompts, an invalid answer re-prompts, then a valid one wins
# ==============================================================================
Write-Host "=== Scenario G: both invalid, prompts until a valid path is given ===" -ForegroundColor Cyan
$missingDefaultG = Join-Path $scratchDir "scenario-g\NoSuchDefault"
$missingPersistedG = Join-Path $scratchDir "scenario-g\NoSuchPersisted"
$validG = New-FakeModulesDir -RelativePath "scenario-g\RealModules"
$promptG = New-ScriptedPrompt -Responses @("", "C:\Some\Nonexistent\Path", $validG)
$resultG = Resolve-ModulesPath -DefaultPath $missingDefaultG -PersistedPath $missingPersistedG -PromptFunc $promptG
Test-Assert ($resultG.Path -eq $validG -and $resultG.Source -eq "Prompted") "a blank answer and an invalid path both re-prompted before the real valid path was accepted"
Write-Host ""

# ==============================================================================
#  Scenario H: Resolve-ModulesPath - a blank/whitespace -PersistedPath
#  (Config.ps1's own default) is treated as "nothing persisted", not as
#  an invalid candidate worth reporting
# ==============================================================================
Write-Host "=== Scenario H: blank PersistedPath treated as none, not checked ===" -ForegroundColor Cyan
$missingDefaultH = Join-Path $scratchDir "scenario-h\NoSuchDefault"
$validH = New-FakeModulesDir -RelativePath "scenario-h\RealModules"
$promptH = New-ScriptedPrompt -Responses @($validH)
$resultH = Resolve-ModulesPath -DefaultPath $missingDefaultH -PersistedPath "" -PromptFunc $promptH
Test-Assert ($resultH.Path -eq $validH -and $resultH.Source -eq "Prompted") "blank PersistedPath was skipped entirely, went straight to prompting"
Write-Host ""

# ==============================================================================
#  Scenario I: Resolve-ModulesPath - prompting truly never gives up (no
#  hardcoded retry limit) - a longer run of bad answers still eventually
#  succeeds
# ==============================================================================
Write-Host "=== Scenario I: no retry limit - many bad answers still eventually succeeds ===" -ForegroundColor Cyan
$missingDefaultI = Join-Path $scratchDir "scenario-i\NoSuchDefault"
$validI = New-FakeModulesDir -RelativePath "scenario-i\RealModules"
$badAnswersI = 1..10 | ForEach-Object { Join-Path $scratchDir ("scenario-i\Bad" + $_) }
$promptI = New-ScriptedPrompt -Responses ($badAnswersI + @($validI))
$resultI = Resolve-ModulesPath -DefaultPath $missingDefaultI -PromptFunc $promptI
Test-Assert ($resultI.Path -eq $validI -and $resultI.Source -eq "Prompted") "survived 10 consecutive bad answers with no give-up, then accepted the valid one"
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
