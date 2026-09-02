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
# Logging.ps1/FileDeletion.ps1 dot-sourced too (2026-08-31 addition, for
# Scenario covering the PermanentDelete/CleanConsoleOutput re-sync fix on
# Show-ModeMenu's '5' branch) - just for their real, trivial
# Initialize-CleanConsoleOutput/Initialize-FileDeletion setters, which
# Menu.ps1 now forward-references. Write-Log below is stubbed AFTER this,
# overriding Logging.ps1's real one, same as before this addition - this
# harness still never touches a real log file.
. (Join-Path $PSScriptRoot "..\Logging.ps1")
. (Join-Path $PSScriptRoot "..\FileDeletion.ps1")
. (Join-Path $PSScriptRoot "..\Menu.ps1")

$script:logCalls = New-Object System.Collections.Generic.List[string]
function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $script:logCalls.Add($Level + ": " + $Message)
}

# Stub for UnwantedImage.ps1's Get-UnwantedImageProfilesPath - only its
# default-parameter-value evaluation is exercised here (Show-ModeMenu's
# '5' dispatch calls Show-CoverDeletionMenu without -ProfilesPath); the
# real scan/add/action behavior is verified via injected -RunHandler/
# -AddHandler/-ActionHandler below, not the real UnwantedImage.ps1
# functions, so this module is not dot-sourced.
function Get-UnwantedImageProfilesPath {
    param([string]$BaseDir)
    return (Join-Path ([System.IO.Path]::GetTempPath()) "menu-harness-unused-profiles.json")
}
# Same reason/shape as the stub above - only Invoke-TrailingZeroAuditRun's
# own default -ReportPath parameter value needs this to resolve; the real
# scan/report behavior is verified via an injected -TrailingZeroHandler.
function Get-TrailingZeroReportPath {
    param([string]$BaseDir)
    return (Join-Path ([System.IO.Path]::GetTempPath()) "menu-harness-unused-trailing-zero-report.txt")
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
Test-Assert (($linesA -join "`n") -match "5 - Cover Deletion") "lists Cover Deletion (5)"
Test-Assert (($linesA -join "`n") -match "8 - Image Conversion \+ Zip") "lists Image Conversion + Zip (8)"
Test-Assert (($linesA -join "`n") -match "9 - Convert Zipped") "lists Convert Zipped (9)"
Test-Assert (($linesA -join "`n") -match "DEPRECATED") "Convert Zipped is marked DEPRECATED on the menu text itself"
Test-Assert (($linesA -join "`n") -match "0 - Options") "lists Options (0)"
Test-Assert (($linesA -join "`n") -match "Ctrl\+C") "mentions Ctrl+C abort behavior"
$reservedShownA = @($linesA | Where-Object { $_ -match "^\s*[67] - " })
Test-Assert ($reservedShownA.Count -eq 0) "reserved numbers 6/7 are not shown as menu items"
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
$promptD = New-ScriptedPrompt -Responses @('abc', '6', '2')
$resultD = Show-ModeMenu -Settings $settingsD -SettingsPath $pathD -PromptFunc $promptD
Test-Assert ($resultD.Mode -eq 'ImageConversion') "invalid ('abc') and reserved ('6') inputs were rejected before the valid '2' was accepted"
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
#  Scenario P: Get-CoverDeletionMenuLines - shape, 0-Back last
# ==============================================================================
Write-Host "=== Scenario P: Get-CoverDeletionMenuLines ===" -ForegroundColor Cyan
$linesP = Get-CoverDeletionMenuLines
Test-Assert (($linesP -join "`n") -match "1 - Run") "lists Run (1)"
Test-Assert (($linesP -join "`n") -match "2 - Add Image") "lists Add Image (2)"
Test-Assert (($linesP -join "`n") -match "4 - Open Profile Location") "lists Open Profile Location (4)"
Test-Assert (($linesP -join "`n") -match "5 - Trailing-Zero Report") "lists Trailing-Zero Report (5) - 2026-08-31 addition, project owner's own decision"
Test-Assert ($linesP[-1] -eq "  0 - Back") "last line is always 0 - Back"
Write-Host ""

# ==============================================================================
#  Scenario Q: Show-ModeMenu - '5' opens the Cover Deletion submenu (via
#  a stubbed RunHandler pass-through), then re-shows the main prompt
#  afterward instead of resolving to a mode
# ==============================================================================
Write-Host "=== Scenario Q: Show-ModeMenu dispatches '5' into Cover Deletion, returns to main prompt after Back ===" -ForegroundColor Cyan
$settingsQ = Get-DefaultScriptSettings
$pathQ = New-ScratchSettingsPath "scenario-q"
$promptQ = New-ScriptedPrompt -Responses @('5', '0', '2')
$resultQ = Show-ModeMenu -Settings $settingsQ -SettingsPath $pathQ -PromptFunc $promptQ
Test-Assert ($resultQ.Mode -eq 'ImageConversion') "after Back ('0') out of Cover Deletion, the main prompt re-showed and '2' resolved to ImageConversion"
Write-Host ""

# ==============================================================================
#  Scenario Q2 (2026-08-31 fix, caught by a same-day /code-review
#  full-codebase pass): turning PermanentDelete off via Options, THEN
#  picking Cover Deletion in the SAME menu visit, must have Show-ModeMenu's
#  '5' branch re-sync $script:PermanentDelete BEFORE Show-CoverDeletionMenu
#  runs - Controller.ps1's Invoke-MainLoop only re-syncs AFTER Get-SelectedMode
#  returns, which is too late for option 5's own real, permanent-deletion-
#  capable work done INSIDE that same call. Live-reproduced before the fix:
#  a just-turned-off Permanent Delete toggle had no effect on the very Cover
#  Deletion run that immediately followed it, deleting permanently instead
#  of to the Recycle Bin. $script:PermanentDelete/CleanConsoleOutputEnabled
#  are set by the REAL Initialize-FileDeletion/Initialize-CleanConsoleOutput
#  (dot-sourced above) - checked directly here since Show-CoverDeletionMenu
#  itself is stubbed out (this scenario only needs to prove the re-sync
#  happened before it was called, not exercise a real scan).
# ==============================================================================
Write-Host "=== Scenario Q2: turning PermanentDelete off then picking Cover Deletion re-syncs BEFORE the submenu runs, not after ===" -ForegroundColor Cyan
Initialize-FileDeletion -PermanentDelete $true
Initialize-CleanConsoleOutput -Enabled $true
$settingsQ2 = Get-DefaultScriptSettings
$settingsQ2.PermanentDelete = $true
$settingsQ2.CleanConsoleOutputEnabled = $true
Export-ScriptSettings -Settings $settingsQ2 -Path (New-ScratchSettingsPath "scenario-q2-init") | Out-Null
$pathQ2 = New-ScratchSettingsPath "scenario-q2"
# '0' -> Options, '5' -> toggle Permanent Delete off (Options loops back
# to show itself again), '0' -> back out of Options to the main prompt,
# '5' -> Cover Deletion (re-sync should fire here, BEFORE the stubbed
# submenu below runs - the stub itself consumes no prompt), '2' -> resolve
# a mode so the loop can return.
$promptQ2 = New-ScriptedPrompt -Responses @('0', '5', '0', '5', '2')
$script:permDeleteAtCoverDeletionQ2 = $null
$stubCoverMenuQ2 = { param($PromptFunc) $script:permDeleteAtCoverDeletionQ2 = $script:PermanentDelete }
$realShowCoverDeletionMenuQ2 = ${function:Show-CoverDeletionMenu}
${function:Show-CoverDeletionMenu} = $stubCoverMenuQ2
try {
    $resultQ2 = Show-ModeMenu -Settings $settingsQ2 -SettingsPath $pathQ2 -PromptFunc $promptQ2
} finally {
    ${function:Show-CoverDeletionMenu} = $realShowCoverDeletionMenuQ2
}

Test-Assert ($settingsQ2.PermanentDelete -eq $false) "sanity check: the Options toggle actually flipped PermanentDelete to false in `$Settings"
Test-Assert ($script:permDeleteAtCoverDeletionQ2 -eq $false) ("`$script:PermanentDelete was re-synced to the just-toggled value BEFORE Cover Deletion ran, not left at the stale bootstrap `$true (got " + $script:permDeleteAtCoverDeletionQ2 + ")")
Test-Assert ($resultQ2.Mode -eq 'ImageConversion') "the loop still resolved a mode normally afterward"
Write-Host ""

# ==============================================================================
#  Scenario R: Show-CoverDeletionMenu - Run, Add, and Trailing-Zero (5,
#  2026-08-31 addition) all dispatch through their injected handlers and
#  return to the SAME submenu (not the caller) until Back is chosen
# ==============================================================================
Write-Host "=== Scenario R: Show-CoverDeletionMenu Run/Add/TrailingZero dispatch, stay in submenu until Back ===" -ForegroundColor Cyan
$callsR = New-Object System.Collections.Generic.List[string]
$runHandlerR = { param($ProfilesPath, $PromptFunc) $callsR.Add('Run') }.GetNewClosure()
$addHandlerR = { param($ProfilesPath, $PromptFunc) $callsR.Add('Add') }.GetNewClosure()
$trailingZeroHandlerR = { param($PromptFunc) $callsR.Add('TrailingZero') }.GetNewClosure()
$promptR = New-ScriptedPrompt -Responses @('1', '2', '5', '1', '0')
Show-CoverDeletionMenu -ProfilesPath "unused" -PromptFunc $promptR -RunHandler $runHandlerR -AddHandler $addHandlerR -TrailingZeroHandler $trailingZeroHandlerR
Test-Assert (($callsR -join ",") -eq "Run,Add,TrailingZero,Run") "Run/Add/TrailingZero/Run all dispatched in order, staying in the submenu each time, before Back exited it"
Write-Host ""

# ==============================================================================
#  Scenario S: Show-CoverDeletionMenu - Open Profile Location (4)
#  dispatches through -ActionHandler without exiting the submenu, and an
#  invalid choice re-prompts instead of throwing
# ==============================================================================
Write-Host "=== Scenario S: Open Profile Location dispatches via -ActionHandler; invalid choice re-prompts ===" -ForegroundColor Cyan
$actionCallsS = New-Object System.Collections.Generic.List[string]
$actionHandlerS = { param($ActionName, $ProfilesPath) $actionCallsS.Add($ActionName) }.GetNewClosure()
$promptS = New-ScriptedPrompt -Responses @('9', '4', '0')
$threwS = $false
try {
    Show-CoverDeletionMenu -ProfilesPath "unused" -PromptFunc $promptS -ActionHandler $actionHandlerS
} catch { $threwS = $true }
Test-Assert (-not $threwS) "an invalid choice ('9') did not throw - just re-prompted"
Test-Assert ($actionCallsS.Count -eq 1 -and $actionCallsS[0] -eq 'OpenProfileLocation') "picking 4 dispatched 'OpenProfileLocation' exactly once through the injected handler"
Write-Host ""

# ==============================================================================
#  Scenario S2 (2026-08-31 fix, caught by a same-day /code-review
#  full-codebase pass): Invoke-CoverDeletionRun and Invoke-TrailingZeroAuditRun
#  had zero direct test coverage of their own (every scenario above
#  injects the handler instead) - both real-deletion/real-scan functions,
#  called here directly with their real UnwantedImage.ps1 dependencies
#  stubbed locally (that module isn't dot-sourced in this harness - see
#  this file's own header). Covers the -PathType Container fix (a
#  dropped FILE, not a folder, is now rejected instead of silently
#  becoming a one-file scan target) for both functions, and
#  Invoke-TrailingZeroAuditRun's own "only open the report if something
#  was actually found" branch.
# ==============================================================================
Write-Host "=== Scenario S2: Invoke-CoverDeletionRun / Invoke-TrailingZeroAuditRun direct coverage, including the -PathType Container fix ===" -ForegroundColor Cyan
$fileS2 = Join-Path $scratchDir "not-a-folder-s2.txt"
"not a folder" | Set-Content -LiteralPath $fileS2 -Encoding UTF8
$realFolderS2 = Join-Path $scratchDir "real-folder-s2"
New-Item -ItemType Directory -Path $realFolderS2 -Force | Out-Null

function Invoke-UnwantedImageScan { param($Path, $Profiles) $script:unwantedScanCallsS2.Add($Path); return @{ ScannedPath = $Path } }
function Get-AllUnwantedImageProfiles { param($ProfilesPath) return @() }
$script:unwantedScanCallsS2 = New-Object System.Collections.Generic.List[string]

$promptFileS2 = { param($m) $fileS2 }
$resultRunFileS2 = Invoke-CoverDeletionRun -ProfilesPath "unused" -PromptFunc $promptFileS2
Test-Assert (-not $resultRunFileS2.Ran) "Invoke-CoverDeletionRun rejects a FILE dropped on the folder prompt, not a silent one-file scan"
Test-Assert ($script:unwantedScanCallsS2.Count -eq 0) "the real scan function was never called for a rejected file path"

$promptFolderS2 = { param($m) $realFolderS2 }
$resultRunFolderS2 = Invoke-CoverDeletionRun -ProfilesPath "unused" -PromptFunc $promptFolderS2
Test-Assert ($resultRunFolderS2.Ran -and $script:unwantedScanCallsS2.Count -eq 1 -and $script:unwantedScanCallsS2[0] -eq $realFolderS2) "a real folder is accepted and passed through to the real scan function"

function Invoke-TrailingZeroAudit {
    param($Path, $ReportPath)
    $script:trailingZeroAuditCallsS2.Add($Path)
    if ($script:trailingZeroFoundS2) { return @{ UniqueFileCount = 1; HashFailureCount = 0; ReportPath = $ReportPath } }
    return @{ UniqueFileCount = 0; HashFailureCount = 0; ReportPath = $null }
}
$script:trailingZeroAuditCallsS2 = New-Object System.Collections.Generic.List[string]
$script:trailingZeroOpenCallsS2 = New-Object System.Collections.Generic.List[string]
$openHandlerS2 = { param($Path) $script:trailingZeroOpenCallsS2.Add($Path) }.GetNewClosure()

$resultTZFileS2 = Invoke-TrailingZeroAuditRun -ReportPath (Join-Path $scratchDir "report-s2.txt") -PromptFunc $promptFileS2 -OpenHandler $openHandlerS2
Test-Assert (-not $resultTZFileS2.Ran) "Invoke-TrailingZeroAuditRun rejects a FILE dropped on the folder prompt too"
Test-Assert ($script:trailingZeroAuditCallsS2.Count -eq 0) "the real audit function was never called for a rejected file path"

$script:trailingZeroFoundS2 = $false
$reportPathS2 = Join-Path $scratchDir "report-s2.txt"
$resultTZNoneS2 = Invoke-TrailingZeroAuditRun -ReportPath $reportPathS2 -PromptFunc $promptFolderS2 -OpenHandler $openHandlerS2
Test-Assert ($resultTZNoneS2.Ran -and $script:trailingZeroAuditCallsS2.Count -eq 1) "a real folder with nothing found still ran the audit"
Test-Assert ($script:trailingZeroOpenCallsS2.Count -eq 0) "nothing was opened when the audit found nothing (Invoke-TrailingZeroAudit's own 'no empty report' contract)"

$script:trailingZeroFoundS2 = $true
$resultTZFoundS2 = Invoke-TrailingZeroAuditRun -ReportPath $reportPathS2 -PromptFunc $promptFolderS2 -OpenHandler $openHandlerS2
Test-Assert ($resultTZFoundS2.Ran -and $script:trailingZeroAuditCallsS2.Count -eq 2) "a real folder with something found ran the audit again"
Test-Assert ($script:trailingZeroOpenCallsS2.Count -eq 1 -and $script:trailingZeroOpenCallsS2[0] -eq $reportPathS2) "the report was opened exactly once, at its real path, when something was found"
Write-Host ""

# ==============================================================================
#  Scenario T: Show-PostRunPrompt - Escape returns 'Exit', any other key
#  returns 'ReturnToMenu'
# ==============================================================================
Write-Host "=== Scenario T: Show-PostRunPrompt key handling ===" -ForegroundColor Cyan
$escKeyReader = { [pscustomobject]@{ VirtualKeyCode = 27 } }
$otherKeyReader = { [pscustomobject]@{ VirtualKeyCode = 65 } }
Test-Assert ((Show-PostRunPrompt -KeyReader $escKeyReader) -eq 'Exit') "Escape (VirtualKeyCode 27) returns 'Exit'"
Test-Assert ((Show-PostRunPrompt -KeyReader $otherKeyReader) -eq 'ReturnToMenu') "any other key (e.g. 'A') returns 'ReturnToMenu'"
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
