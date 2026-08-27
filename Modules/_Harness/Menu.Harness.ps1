<#
.SYNOPSIS
    Standalone test harness for Modules\Menu.ps1.

.DESCRIPTION
    Dot-sources the real Config.ps1 (Menu.ps1 forward-references
    Export-ScriptSettings from it - real module, not stubbed, so
    persistence assertions check an actual file on disk) then the real
    Menu.ps1, and stubs Write-Log with call tracking (same pattern as
    AbortPipeline.Harness.ps1).

    Every interactive scenario drives Show-ModeMenu/Show-OptionsMenuLevel
    through -PromptFunc, using New-ScriptedPrompt below to queue canned
    responses - no real Read-Host/console interaction happens. A
    scriptblock that runs out of queued responses throws immediately
    (rather than silently falling through to a real Read-Host), so an
    under-scripted scenario fails loudly instead of hanging.

.EXAMPLE
    .\Modules\_Harness\Menu.Harness.ps1
#>

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\Config.ps1")
. (Join-Path $PSScriptRoot "..\Menu.ps1")

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

function New-ScriptedPrompt {
    <#
    .SYNOPSIS
        Builds a -PromptFunc scriptblock that returns each of $Responses
        in order, one per call, and throws if asked for more than were
        queued - so an under-scripted scenario fails loudly instead of
        blocking on a real Read-Host.
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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("menu-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray
Write-Host ""

function New-ScratchSettingsPath {
    param([string]$Name)
    return (Join-Path $scratchDir ($Name + ".json"))
}

# ==============================================================================
#  Scenario A: Get-ModeMenuLines - expected entries present, reserved
#  numbers (5/6/7) are NOT listed as menu items
# ==============================================================================
Write-Host "=== Scenario A: Get-ModeMenuLines ===" -ForegroundColor Cyan
$linesA = Get-ModeMenuLines
Test-Assert (($linesA -join "`n") -match "1 - Full Pipeline") "lists Full Pipeline (1)"
Test-Assert (($linesA -join "`n") -match "8 - Image Conversion \+ Zip") "lists Image Conversion + Zip (8)"
Test-Assert (($linesA -join "`n") -match "9 - Convert Zipped") "lists Convert Zipped (9)"
Test-Assert (($linesA -join "`n") -match "DEPRECATED") "Convert Zipped is marked DEPRECATED on the menu text itself"
Test-Assert (($linesA -join "`n") -match "0 - Options") "lists Options (0)"
Test-Assert (($linesA -join "`n") -match "Ctrl\+C") "mentions Ctrl+C abort behavior"
$reservedShownA = @($linesA | Where-Object { $_ -match "^\s*[567] - " })
Test-Assert ($reservedShownA.Count -eq 0) "reserved numbers 5/6/7 are not shown as menu items"
Write-Host ""

# ==============================================================================
#  Scenario B: Resolve-ModeSelection - all six valid codes
# ==============================================================================
Write-Host "=== Scenario B: Resolve-ModeSelection valid codes ===" -ForegroundColor Cyan
$b1 = Resolve-ModeSelection -Choice '1'
Test-Assert ($b1.Mode -eq 'FullPipeline' -and $b1.RunImageConversion -and $b1.RunAnimatedConversion -and $b1.RunZip -and -not $b1.RunZipOnly -and -not $b1.RunConvertZipped) "'1' -> FullPipeline: image+animated+zip, no zip-only, no convert-zipped"

$b2 = Resolve-ModeSelection -Choice '2'
Test-Assert ($b2.Mode -eq 'ImageConversion' -and $b2.RunImageConversion -and -not $b2.RunAnimatedConversion -and -not $b2.RunZip) "'2' -> ImageConversion: image only, no animated, no zip"

$b3 = Resolve-ModeSelection -Choice '3'
Test-Assert ($b3.Mode -eq 'AnimatedConversion' -and -not $b3.RunImageConversion -and $b3.RunAnimatedConversion -and -not $b3.RunZip) "'3' -> AnimatedConversion: animated only"

$b4 = Resolve-ModeSelection -Choice '4'
Test-Assert ($b4.Mode -eq 'ZipFolders' -and $b4.RunZipOnly -and -not $b4.RunImageConversion -and -not $b4.RunAnimatedConversion -and -not $b4.RunZip) "'4' -> ZipFolders: zip-only, nothing else"

$b8 = Resolve-ModeSelection -Choice '8'
Test-Assert ($b8.Mode -eq 'ImageConversionZip' -and $b8.RunImageConversion -and $b8.RunZip -and -not $b8.RunAnimatedConversion -and -not $b8.RunZipOnly) "'8' -> ImageConversionZip: image+zip, no animated"

$b9 = Resolve-ModeSelection -Choice '9'
Test-Assert ($b9.Mode -eq 'ConvertZipped' -and $b9.RunConvertZipped -and -not $b9.RunImageConversion -and -not $b9.RunAnimatedConversion -and -not $b9.RunZip) "'9' -> ConvertZipped: only RunConvertZipped set"
Write-Host ""

# ==============================================================================
#  Scenario C: Resolve-ModeSelection - invalid/reserved codes return $null
# ==============================================================================
Write-Host "=== Scenario C: Resolve-ModeSelection invalid codes ===" -ForegroundColor Cyan
foreach ($badChoice in @('0', '5', '6', '7', '', 'abc', '10')) {
    $resultC = Resolve-ModeSelection -Choice $badChoice
    Test-Assert ($null -eq $resultC) ("'" + $badChoice + "' resolves to `$null (not a valid mode code)")
}
Write-Host ""

# ==============================================================================
#  Scenario D: Show-ModeMenu - invalid input re-prompts, then a valid
#  choice is returned; Options is never entered
# ==============================================================================
Write-Host "=== Scenario D: Show-ModeMenu re-prompts on invalid input ===" -ForegroundColor Cyan
$settingsD = Get-DefaultScriptSettings
$pathD = New-ScratchSettingsPath "scenario-d"
$promptD = New-ScriptedPrompt -Responses @('abc', '5', '2')
$resultD = Show-ModeMenu -Settings $settingsD -SettingsPath $pathD -PromptFunc $promptD
Test-Assert ($resultD.Mode -eq 'ImageConversion') "invalid ('abc') and reserved ('5') inputs were rejected before the valid '2' was accepted"
Test-Assert (-not (Test-Path -LiteralPath $pathD)) "Options was never entered, so no settings file was written"
Write-Host ""

# ==============================================================================
#  Scenario E: Show-ModeMenu - entering Options and immediately backing
#  out (no changes) still returns correctly to mode selection afterward
# ==============================================================================
Write-Host "=== Scenario E: Show-ModeMenu enters and exits Options with no changes ===" -ForegroundColor Cyan
$settingsE = Get-DefaultScriptSettings
$pathE = New-ScratchSettingsPath "scenario-e"
$promptE = New-ScriptedPrompt -Responses @('0', '0', '1')
$resultE = Show-ModeMenu -Settings $settingsE -SettingsPath $pathE -PromptFunc $promptE
Test-Assert ($resultE.Mode -eq 'FullPipeline') "after backing straight out of Options, the mode menu re-prompted and '1' resolved to FullPipeline"
Test-Assert ($settingsE.PermanentDelete -eq $false) "no setting was changed by just entering and backing out of Options"
Write-Host ""

# ==============================================================================
#  Scenario F: Show-ModeMenu - a change made inside Options persists
#  (saved immediately) even though the run continues on to pick a mode
# ==============================================================================
Write-Host "=== Scenario F: a change inside Options saves immediately, then mode selection continues ===" -ForegroundColor Cyan
$settingsF = Get-DefaultScriptSettings
$pathF = New-ScratchSettingsPath "scenario-f"
$promptF = New-ScriptedPrompt -Responses @('0', '5', '0', '4')
$resultF = Show-ModeMenu -Settings $settingsF -SettingsPath $pathF -PromptFunc $promptF
Test-Assert ($settingsF.PermanentDelete -eq $true) "toggling item 5 (Permanent Delete) flipped it to `$true in the live hashtable"
$reloadedF = Import-ScriptSettings -Path $pathF
Test-Assert ($reloadedF.PermanentDelete -eq $true) "the toggle was actually persisted to disk immediately, not just in memory"
Test-Assert ($resultF.Mode -eq 'ZipFolders') "after backing out of Options, '4' resolved to ZipFolders"
Write-Host ""

# ==============================================================================
#  Scenario G: Get-SelectedMode - EnableModePrompt=$false skips the
#  interactive prompt entirely (PromptFunc is never called) and logs once
# ==============================================================================
Write-Host "=== Scenario G: Get-SelectedMode with EnableModePrompt=`$false ===" -ForegroundColor Cyan
$settingsG = Get-DefaultScriptSettings
$settingsG.EnableModePrompt = $false
$pathG = New-ScratchSettingsPath "scenario-g"
$script:logCalls.Clear()
$promptG = New-ScriptedPrompt -Responses @()   # any call at all should throw
$resultG = Get-SelectedMode -Settings $settingsG -SettingsPath $pathG -PromptFunc $promptG
Test-Assert ($resultG.Mode -eq 'ImageConversion') "disabled-prompt default matches the old main script's default (loose image conversion only)"
Test-Assert (@($script:logCalls | Where-Object { $_ -like "*Mode (prompt disabled)*ImageConversion*" }).Count -eq 1) "logged the disabled-prompt default exactly once"
Write-Host ""

# ==============================================================================
#  Scenario H: Get-SelectedMode - EnableModePrompt=$true delegates to
#  Show-ModeMenu and logs the actual selection
# ==============================================================================
Write-Host "=== Scenario H: Get-SelectedMode with EnableModePrompt=`$true ===" -ForegroundColor Cyan
$settingsH = Get-DefaultScriptSettings
$pathH = New-ScratchSettingsPath "scenario-h"
$script:logCalls.Clear()
$promptH = New-ScriptedPrompt -Responses @('3')
$resultH = Get-SelectedMode -Settings $settingsH -SettingsPath $pathH -PromptFunc $promptH
Test-Assert ($resultH.Mode -eq 'AnimatedConversion') "delegated to Show-ModeMenu and returned its result"
Test-Assert (@($script:logCalls | Where-Object { $_ -like "*Mode selected*AnimatedConversion*" }).Count -eq 1) "logged the selected mode exactly once"
Write-Host ""

# ==============================================================================
#  Scenario I: Get-OptionsMenuSchema - shape, and every SettingsKey it
#  references actually exists in Config.ps1's real schema (catches the
#  two schemas drifting apart)
# ==============================================================================
Write-Host "=== Scenario I: Get-OptionsMenuSchema shape and Config cross-check ===" -ForegroundColor Cyan
$schemaI = Get-OptionsMenuSchema
Test-Assert ($schemaI.Count -eq 6) "six top-level items (Image Conversion, Animated Conversion, Zip, Logging, Permanent Delete, Open Settings Location)"
Test-Assert ($schemaI[0].Type -eq 'Submenu' -and $schemaI[0].Items.Count -eq 3) "Image Conversion Settings is a 3-item submenu"
Test-Assert ($schemaI[1].Type -eq 'Submenu' -and $schemaI[1].Items.Count -eq 5) "Animated Conversion Settings is a 5-item submenu"
Test-Assert ($schemaI[2].Type -eq 'Submenu' -and $schemaI[2].Items.Count -eq 2) "Zip Settings is a 2-item submenu"
Test-Assert ($schemaI[3].Type -eq 'Submenu' -and $schemaI[3].Items.Count -eq 3) "Logging is a 3-item submenu"
Test-Assert ($schemaI[4].Type -eq 'Bool' -and $schemaI[4].SettingsKey -eq 'PermanentDelete') "item 5 is the direct Permanent Delete Bool toggle"
Test-Assert ($schemaI[5].Type -eq 'Action' -and $schemaI[5].Action -eq 'OpenSettingsLocation') "item 6 is the Open Settings File Location action"

$defaultsI = Get-DefaultScriptSettings
function Get-AllSettingsKeysInSchema {
    param([array]$Items)
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Items) {
        if ($item.SettingsKey) { $keys.Add($item.SettingsKey) }
        if ($item.Type -eq 'Submenu') { foreach ($k in (Get-AllSettingsKeysInSchema -Items $item.Items)) { $keys.Add($k) } }
    }
    return ,$keys.ToArray()
}
$allKeysI = Get-AllSettingsKeysInSchema -Items $schemaI
$missingFromConfigI = @($allKeysI | Where-Object { -not $defaultsI.ContainsKey($_) })
Test-Assert ($missingFromConfigI.Count -eq 0) ("every SettingsKey referenced by the options menu exists in Config.ps1's schema (missing: " + ($missingFromConfigI -join ", ") + ")")
Write-Host ""

# ==============================================================================
#  Scenario J: Format-OptionsMenuLines - Title, On/Off for Bool, bracketed
#  value for Int, trailing Back line
# ==============================================================================
Write-Host "=== Scenario J: Format-OptionsMenuLines ===" -ForegroundColor Cyan
$itemsJ = @(
    @{ Key = '1'; Label = 'A Bool Item'; Type = 'Bool'; SettingsKey = 'PermanentDelete'; Description = 'desc' }
    @{ Key = '2'; Label = 'An Int Item'; Type = 'Int';  SettingsKey = 'JpegQuality';     Description = 'desc' }
)
$settingsJ = Get-DefaultScriptSettings
$settingsJ.PermanentDelete = $true
$linesJ = Format-OptionsMenuLines -Items $itemsJ -Settings $settingsJ -Title "Test Title"
Test-Assert ($linesJ[0] -eq "Test Title") "first line is the given Title"
Test-Assert (($linesJ -join "`n") -match "\[On\]") "a `$true Bool item shows [On]"
Test-Assert (($linesJ -join "`n") -match "\[90\]") "the Int item shows its current bracketed value"
Test-Assert ($linesJ[-1] -eq "  0 - Back") "last line is always 0 - Back"
Write-Host ""

# ==============================================================================
#  Scenario K: Show-OptionsMenuLevel - Bool toggle inside a submenu,
#  saved immediately, verified against a fresh Import-ScriptSettings
# ==============================================================================
Write-Host "=== Scenario K: Bool toggle inside a submenu persists ===" -ForegroundColor Cyan
$settingsK = Get-DefaultScriptSettings
$pathK = New-ScratchSettingsPath "scenario-k"
$promptK = New-ScriptedPrompt -Responses @('1', '3', '0', '0')
Show-OptionsMenuLevel -Items (Get-OptionsMenuSchema) -Settings $settingsK -SettingsPath $pathK -PromptFunc $promptK
Test-Assert ($settingsK.JpegLossless -eq $true) "Lossless Toggle inside Image Conversion Settings flipped to `$true"
$reloadedK = Import-ScriptSettings -Path $pathK
Test-Assert ($reloadedK.JpegLossless -eq $true) "the toggle was persisted to disk before the submenu was even backed out of"
Write-Host ""

# ==============================================================================
#  Scenario L: Show-OptionsMenuLevel - valid Int entry updates and saves
# ==============================================================================
Write-Host "=== Scenario L: valid Int entry updates and saves ===" -ForegroundColor Cyan
$settingsL = Get-DefaultScriptSettings
$pathL = New-ScratchSettingsPath "scenario-l"
$promptL = New-ScriptedPrompt -Responses @('1', '2', '55', '0', '0')
Show-OptionsMenuLevel -Items (Get-OptionsMenuSchema) -Settings $settingsL -SettingsPath $pathL -PromptFunc $promptL
Test-Assert ($settingsL.JpegQuality -eq 55) "Quality was updated to the entered value (55)"
$reloadedL = Import-ScriptSettings -Path $pathL
Test-Assert ($reloadedL.JpegQuality -eq 55) "the new value was persisted to disk"
Write-Host ""

# ==============================================================================
#  Scenario M: Show-OptionsMenuLevel - an out-of-range Int entry is
#  rejected, leaves the value unchanged, and does not save
# ==============================================================================
Write-Host "=== Scenario M: out-of-range Int entry is rejected, value unchanged ===" -ForegroundColor Cyan
$settingsM = Get-DefaultScriptSettings
$pathM = New-ScratchSettingsPath "scenario-m"
$promptM = New-ScriptedPrompt -Responses @('1', '2', '500', '0', '0')
Show-OptionsMenuLevel -Items (Get-OptionsMenuSchema) -Settings $settingsM -SettingsPath $pathM -PromptFunc $promptM
Test-Assert ($settingsM.JpegQuality -eq 90) "Quality (500, out of the 1-100 range) was rejected - stayed at its default (90)"
Test-Assert (-not (Test-Path -LiteralPath $pathM)) "nothing was ever saved, since no valid change was made in this session"
Write-Host ""

# ==============================================================================
#  Scenario M2: a blank Int entry cancels without changing or saving
# ==============================================================================
Write-Host "=== Scenario M2: blank Int entry cancels ===" -ForegroundColor Cyan
$settingsM2 = Get-DefaultScriptSettings
$pathM2 = New-ScratchSettingsPath "scenario-m2"
$promptM2 = New-ScriptedPrompt -Responses @('1', '2', '', '0', '0')
Show-OptionsMenuLevel -Items (Get-OptionsMenuSchema) -Settings $settingsM2 -SettingsPath $pathM2 -PromptFunc $promptM2
Test-Assert ($settingsM2.JpegQuality -eq 90) "a blank entry cancelled - Quality stayed at its default"
Test-Assert (-not (Test-Path -LiteralPath $pathM2)) "nothing was saved for a cancelled edit"
Write-Host ""

# ==============================================================================
#  Scenario N: Show-OptionsMenuLevel - Action item dispatches through
#  -ActionHandler (stubbed here to avoid a real Explorer launch)
# ==============================================================================
Write-Host "=== Scenario N: Action item dispatches via -ActionHandler ===" -ForegroundColor Cyan
$settingsN = Get-DefaultScriptSettings
$pathN = New-ScratchSettingsPath "scenario-n"
$actionCallsN = New-Object System.Collections.Generic.List[string]
$actionHandlerN = {
    param($ActionName, $Settings, $SettingsPath)
    $actionCallsN.Add($ActionName)
}.GetNewClosure()
$promptN = New-ScriptedPrompt -Responses @('6', '0')
Show-OptionsMenuLevel -Items (Get-OptionsMenuSchema) -Settings $settingsN -SettingsPath $pathN -PromptFunc $promptN -ActionHandler $actionHandlerN
Test-Assert ($actionCallsN.Count -eq 1 -and $actionCallsN[0] -eq 'OpenSettingsLocation') "picking item 6 dispatched the 'OpenSettingsLocation' action exactly once through the injected handler"
Write-Host ""

# ==============================================================================
#  Scenario O: Show-OptionsMenuLevel - an invalid selection at any level
#  re-prompts instead of throwing
# ==============================================================================
Write-Host "=== Scenario O: invalid selection at a menu level re-prompts, does not throw ===" -ForegroundColor Cyan
$settingsO = Get-DefaultScriptSettings
$pathO = New-ScratchSettingsPath "scenario-o"
$promptO = New-ScriptedPrompt -Responses @('7', '0')
$threwO = $false
try {
    Show-OptionsMenuLevel -Items (Get-OptionsMenuSchema) -Settings $settingsO -SettingsPath $pathO -PromptFunc $promptO
} catch { $threwO = $true }
Test-Assert (-not $threwO) "an invalid top-level choice ('7', not in the schema) did not throw - just re-prompted"
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
