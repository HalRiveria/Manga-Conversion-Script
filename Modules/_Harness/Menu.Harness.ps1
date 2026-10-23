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
# Logging.ps1/FileDeletion.ps1 dot-sourced too (for the scenario covering
# the PermanentDelete/CleanConsoleOutput re-sync on
# Show-ModeMenu's '5' branch) - just for their real, trivial
# Initialize-CleanConsoleOutput/Initialize-FileDeletion setters, which
# Menu.ps1 forward-references. Write-Log below is stubbed AFTER this,
# overriding Logging.ps1's real one - this
# harness never touches a real log file.
. (Join-Path $PSScriptRoot "..\Logging.ps1")
. (Join-Path $PSScriptRoot "..\FileDeletion.ps1")
# AbortPipeline.ps1 dot-sourced too (for the real
# Set-AbortHandlerRunActive/Complete-AbortDrain calls Show-ModeMenu's '5'
# branch makes - see its own comment in Menu.ps1).
# Same "real module, not stubbed" reasoning as Logging.ps1/FileDeletion.ps1
# above - this harness needs the real [ConsoleCtrl]::RunActive/DrainComplete
# state to assert against, not a fake.
. (Join-Path $PSScriptRoot "..\AbortPipeline.ps1")
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
#  Scenario A: Get-ModeMenuLines - expected entries present, and numbers
#  6-9 (including the retired Convert Zipped entry) are NOT listed as menu items.
# ==============================================================================
Write-Host "=== Scenario A: Get-ModeMenuLines ===" -ForegroundColor Cyan
$linesA = Get-ModeMenuLines
Test-Assert (($linesA -join "`n") -match "1 - Full Pipeline") "lists Full Pipeline (1)"
Test-Assert (($linesA -join "`n") -match "5 - Cover Deletion") "lists Cover Deletion (5)"
Test-Assert (($linesA -join "`n") -notmatch "Image Conversion \+ Zip") "does NOT list Image Conversion + Zip (Full Pipeline with its Animated Conversion toggle off does that job)"
Test-Assert (($linesA -join "`n") -notmatch "9 - Convert Zipped") "does NOT list Convert Zipped (9) - hidden from the live menu"
Test-Assert (($linesA -join "`n") -match "0 - Options") "lists Options (0)"
Test-Assert (($linesA -join "`n") -match "Ctrl\+C") "mentions Ctrl+C abort behavior"
$reservedShownA = @($linesA | Where-Object { $_ -match "^\s*[6789] - " })
Test-Assert ($reservedShownA.Count -eq 0) "numbers 6-9 are not shown as menu items"
Write-Host ""

# ==============================================================================
#  Scenario B: Resolve-ModeSelection - all four mode codes ('1'-'4')
# ==============================================================================
Write-Host "=== Scenario B: Resolve-ModeSelection valid codes ===" -ForegroundColor Cyan
$b1 = Resolve-ModeSelection -Choice '1'
Test-Assert ($b1.Mode -eq 'FullPipeline' -and $b1.RunImageConversion -and $b1.RunAnimatedConversion -and $b1.RunZip -and -not $b1.RunZipOnly) "'1' -> FullPipeline: image+animated+zip, no zip-only"

$b2 = Resolve-ModeSelection -Choice '2'
Test-Assert ($b2.Mode -eq 'ImageConversion' -and $b2.RunImageConversion -and -not $b2.RunAnimatedConversion -and -not $b2.RunZip) "'2' -> ImageConversion: image only, no animated, no zip"

$b3 = Resolve-ModeSelection -Choice '3'
Test-Assert ($b3.Mode -eq 'AnimatedConversion' -and -not $b3.RunImageConversion -and $b3.RunAnimatedConversion -and -not $b3.RunZip) "'3' -> AnimatedConversion: animated only"

$b4 = Resolve-ModeSelection -Choice '4'
Test-Assert ($b4.Mode -eq 'ZipFolders' -and $b4.RunZipOnly -and -not $b4.RunImageConversion -and -not $b4.RunAnimatedConversion -and -not $b4.RunZip) "'4' -> ZipFolders: zip-only, nothing else"

$b8 = Resolve-ModeSelection -Choice '8'
Test-Assert ($null -eq $b8) "'8' (retired Image Conversion + Zip) no longer resolves to a mode"

Write-Host ""

# ==============================================================================
#  Scenario C: Resolve-ModeSelection - invalid/reserved codes return $null.
#  '9' is included - Convert Zipped no longer exists, so it resolves the
#  same as any other unrecognized code.
# ==============================================================================
Write-Host "=== Scenario C: Resolve-ModeSelection invalid codes ===" -ForegroundColor Cyan
foreach ($badChoice in @('0', '5', '6', '7', '9', '', 'abc', '10')) {
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
$promptF = New-ScriptedPrompt -Responses @('0', '6', '0', '4')
$resultF = Show-ModeMenu -Settings $settingsF -SettingsPath $pathF -PromptFunc $promptF
Test-Assert ($settingsF.PermanentDelete -eq $true) "toggling item 6 (Permanent Delete) flipped it to `$true in the live hashtable"
$reloadedF = Import-ScriptSettings -Path $pathF
Test-Assert ($reloadedF.PermanentDelete -eq $true) "the toggle was actually persisted to disk immediately, not just in memory"
Test-Assert ($resultF.Mode -eq 'ZipFolders') "after backing out of Options, '4' resolved to ZipFolders"
Write-Host ""

# ==============================================================================
#  Scenario H: Get-SelectedMode delegates to Show-ModeMenu and logs the
#  actual selection
# ==============================================================================
Write-Host "=== Scenario H: Get-SelectedMode delegates to Show-ModeMenu ===" -ForegroundColor Cyan
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
Test-Assert ($schemaI.Count -eq 7) "seven top-level items (Full Pipeline, Image Conversion, Animated Conversion, Zip, Logging, Permanent Delete, Open Settings Location)"
# A top-level Full Pipeline Settings submenu comes first, everything else follows it.
Test-Assert ($schemaI[0].Type -eq 'Submenu' -and $schemaI[0].Items.Count -eq 3) "Full Pipeline Settings is a 3-item submenu"
$animToggleI = @($schemaI[0].Items | Where-Object { $_.SettingsKey -eq 'FullPipelineAnimatedConversion' })
Test-Assert ($animToggleI.Count -eq 1 -and $animToggleI[0].Type -eq 'Bool' -and $animToggleI[0].Key -eq '3') "Full Pipeline Settings item 3 is the Animated Conversion toggle (FullPipelineAnimatedConversion)"
Test-Assert ((Get-DefaultScriptSettings).FullPipelineAnimatedConversion -eq $true) "Animated Conversion defaults to ON (today's behavior)"
$fpLinesI = @(Format-OptionsMenuLines -Items $schemaI[0].Items -Settings (Get-DefaultScriptSettings) -Title "Full Pipeline Settings")
Test-Assert (@($fpLinesI | Where-Object { $_ -match "Animated Conversion.*\[On\]" }).Count -eq 1) "the Full Pipeline Settings menu shows Animated Conversion's current state"
Test-Assert ($schemaI[0].Items[0].SettingsKey -eq 'FullPipelineMaxConcurrentProcs') "Full Pipeline Settings item 1 is Max Concurrent Processes"
Test-Assert ($schemaI[0].Items[1].SettingsKey -eq 'RunCoverDeletionBeforeConversion') "Full Pipeline Settings item 2 is the Run Cover Deletion Before Conversion placeholder"
Test-Assert ($schemaI[1].Type -eq 'Submenu' -and $schemaI[1].Items.Count -eq 3) "Image Conversion Settings is a 3-item submenu"
Test-Assert ($schemaI[2].Type -eq 'Submenu' -and $schemaI[2].Items.Count -eq 5) "Animated Conversion Settings is a 5-item submenu"
Test-Assert ($schemaI[3].Type -eq 'Submenu' -and $schemaI[3].Items.Count -eq 1) "Zip Settings is a 1-item submenu"
Test-Assert ($schemaI[4].Type -eq 'Submenu' -and $schemaI[4].Items.Count -eq 3) "Logging is a 3-item submenu"
Test-Assert ($schemaI[4].Items[1].Label -eq 'Disable Summary File' -and $schemaI[4].Items[1].SettingsKey -eq 'DisableSummaryFile') "Logging item 2's label matches its own settings key's sense"
Test-Assert ($schemaI[5].Type -eq 'Bool' -and $schemaI[5].SettingsKey -eq 'PermanentDelete') "item 6 is the direct Permanent Delete Bool toggle"
Test-Assert ($schemaI[6].Type -eq 'Action' -and $schemaI[6].Action -eq 'OpenSettingsLocation') "item 7 is the Open Settings File Location action"

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
$promptK = New-ScriptedPrompt -Responses @('2', '3', '0', '0')
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
$promptL = New-ScriptedPrompt -Responses @('2', '2', '55', '0', '0')
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
$promptM = New-ScriptedPrompt -Responses @('2', '2', '500', '0', '0')
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
$promptM2 = New-ScriptedPrompt -Responses @('2', '2', '', '0', '0')
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
$promptN = New-ScriptedPrompt -Responses @('7', '0')
Show-OptionsMenuLevel -Items (Get-OptionsMenuSchema) -Settings $settingsN -SettingsPath $pathN -PromptFunc $promptN -ActionHandler $actionHandlerN
Test-Assert ($actionCallsN.Count -eq 1 -and $actionCallsN[0] -eq 'OpenSettingsLocation') "picking item 7 dispatched the 'OpenSettingsLocation' action exactly once through the injected handler"
Write-Host ""

# ==============================================================================
#  Scenario O: Show-OptionsMenuLevel - an invalid selection at any level
#  re-prompts instead of throwing
# ==============================================================================
Write-Host "=== Scenario O: invalid selection at a menu level re-prompts, does not throw ===" -ForegroundColor Cyan
$settingsO = Get-DefaultScriptSettings
$pathO = New-ScratchSettingsPath "scenario-o"
$promptO = New-ScriptedPrompt -Responses @('8', '0')
$threwO = $false
try {
    Show-OptionsMenuLevel -Items (Get-OptionsMenuSchema) -Settings $settingsO -SettingsPath $pathO -PromptFunc $promptO
} catch { $threwO = $true }
Test-Assert (-not $threwO) "an invalid top-level choice ('8', not in the schema - the schema has 7 items) did not throw - just re-prompted"
Write-Host ""

# ==============================================================================
#  Scenario P: Get-CoverDeletionMenuLines - shape, 0-Back last
# ==============================================================================
Write-Host "=== Scenario P: Get-CoverDeletionMenuLines ===" -ForegroundColor Cyan
$linesP = Get-CoverDeletionMenuLines
Test-Assert (($linesP -join "`n") -match "1 - Run") "lists Run (1)"
Test-Assert (($linesP -join "`n") -match "2 - Add Image") "lists Add Image (2)"
Test-Assert (($linesP -join "`n") -match "4 - Open Profile Location") "lists Open Profile Location (4)"
Test-Assert (($linesP -join "`n") -match "5 - Trailing-Zero Report") "lists Trailing-Zero Report (5)"
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
#  Scenario Q2: turning PermanentDelete off via Options, THEN
#  picking Cover Deletion in the SAME menu visit, must have Show-ModeMenu's
#  '5' branch re-sync $script:PermanentDelete BEFORE Show-CoverDeletionMenu
#  runs - Controller.ps1's Invoke-MainLoop only re-syncs AFTER Get-SelectedMode
#  returns, which is too late for option 5's own real, permanent-deletion-
#  capable work done INSIDE that same call. Without the re-sync,
#  a just-turned-off Permanent Delete toggle would have no effect on the very Cover
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
# '0' -> Options, '6' -> toggle Permanent Delete off (Options loops back
# to show itself again), '0' -> back out of Options to the main prompt,
# '5' -> Cover Deletion (re-sync should fire here, BEFORE the stubbed
# submenu below runs - the stub itself consumes no prompt), '2' -> resolve
# a mode so the loop can return.
$promptQ2 = New-ScriptedPrompt -Responses @('0', '6', '0', '5', '2')
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
#  Scenario Q3: Cover Deletion's own real work
#  (Show-CoverDeletionMenu) never goes through Invoke-MainLoop's own
#  Invoke-Mode dispatch, so it isn't bracketed by that loop's
#  Start-LogRun/Complete-LogRun pair - in split-log mode its Warn/Error
#  lines would land with no run-separator header, and the next real run's
#  Start-LogRun would mis-capture them as belonging to whatever ran
#  before. Show-ModeMenu's own '5' branch must bracket the call
#  itself. Start-LogRun/Complete-LogRun are shadowed (real Logging.ps1
#  functions, not injectable handlers here) to record call order.
# ==============================================================================
Write-Host "=== Scenario Q3: choosing Cover Deletion brackets it with Start-LogRun/Complete-LogRun ===" -ForegroundColor Cyan
$settingsQ3 = Get-DefaultScriptSettings
$pathQ3 = New-ScratchSettingsPath "scenario-q3"
$promptQ3 = New-ScriptedPrompt -Responses @('5', '2')

$script:eventOrderQ3 = [System.Collections.Generic.List[string]]::new()
$realStartLogRunQ3 = ${function:Start-LogRun}
$realCompleteLogRunQ3 = ${function:Complete-LogRun}
$realShowCoverDeletionMenuQ3 = ${function:Show-CoverDeletionMenu}
function Start-LogRun { $script:eventOrderQ3.Add("START") }
function Complete-LogRun { $script:eventOrderQ3.Add("COMPLETE") }
${function:Show-CoverDeletionMenu} = { param($PromptFunc) $script:eventOrderQ3.Add("COVER") }.GetNewClosure()
try {
    $resultQ3 = Show-ModeMenu -Settings $settingsQ3 -SettingsPath $pathQ3 -PromptFunc $promptQ3
} finally {
    ${function:Start-LogRun} = $realStartLogRunQ3
    ${function:Complete-LogRun} = $realCompleteLogRunQ3
    ${function:Show-CoverDeletionMenu} = $realShowCoverDeletionMenuQ3
}

Test-Assert (($script:eventOrderQ3 -join ',') -eq "START,COVER,COMPLETE") ("Start-LogRun, then Cover Deletion's own work, then Complete-LogRun, in that order (got " + ($script:eventOrderQ3 -join ',') + ")")
Test-Assert ($resultQ3.Mode -eq 'ImageConversion') "the loop still resolved a mode normally afterward"

# ==============================================================================
#  Scenario Q3b:
#  (a) Cover Deletion never bracketed [ConsoleCtrl]::RunActive around its
#  own real, permanent-deletion-capable work, unlike every dispatched mode
#  via Invoke-MainLoop - a Ctrl+C during a real scan hit the OS default
#  action instead of draining gracefully. (b) Complete-LogRun (see
#  Q3) must ALSO fire when Show-CoverDeletionMenu
#  itself throws, not just on the happy path - it runs in a finally.
# ==============================================================================
Write-Host "=== Scenario Q3b: Cover Deletion brackets RunActive, and Complete-LogRun still fires if the submenu throws ===" -ForegroundColor Cyan
$settingsQ3b = Get-DefaultScriptSettings
$pathQ3b = New-ScratchSettingsPath "scenario-q3b"
$promptQ3b = New-ScriptedPrompt -Responses @('5', '2')

$realShowCoverDeletionMenuQ3b = ${function:Show-CoverDeletionMenu}
$script:runActiveDuringCoverQ3b = $null
# Deliberately NOT .GetNewClosure()'d - this stub references no outer local
# variable (only a $script:-prefixed one, already directly visible without
# closure capture, and a .NET static member read) - .GetNewClosure() would
# actually BREAK the $script: write here (a $script:-prefixed write inside
# a .GetNewClosure()'d scriptblock doesn't reach the real script-scope variable).
${function:Show-CoverDeletionMenu} = { param($PromptFunc) $script:runActiveDuringCoverQ3b = [ConsoleCtrl]::RunActive }
[ConsoleCtrl]::RunActive = $false
[ConsoleCtrl]::DrainComplete.Reset()
try {
    $null = Show-ModeMenu -Settings $settingsQ3b -SettingsPath $pathQ3b -PromptFunc $promptQ3b
} finally {
    ${function:Show-CoverDeletionMenu} = $realShowCoverDeletionMenuQ3b
}

Test-Assert ($script:runActiveDuringCoverQ3b -eq $true) "RunActive was true WHILE Cover Deletion's own real work was running"
Test-Assert ([ConsoleCtrl]::RunActive -eq $false) "RunActive was set back to false after Cover Deletion finished"
Test-Assert ([ConsoleCtrl]::DrainComplete.IsSet) "DrainComplete was signalled after Cover Deletion finished (unblocks the native Ctrl+C handler thread rather than leaving it waiting up to 65s)"

# Part (b): Complete-LogRun still fires when the submenu itself throws.
$settingsQ3c = Get-DefaultScriptSettings
$pathQ3c = New-ScratchSettingsPath "scenario-q3c"
$promptQ3c = New-ScriptedPrompt -Responses @('5', '2')

$script:eventOrderQ3c = [System.Collections.Generic.List[string]]::new()
$realStartLogRunQ3c = ${function:Start-LogRun}
$realCompleteLogRunQ3c = ${function:Complete-LogRun}
$realShowCoverDeletionMenuQ3c = ${function:Show-CoverDeletionMenu}
function Start-LogRun { $script:eventOrderQ3c.Add("START") }
function Complete-LogRun { $script:eventOrderQ3c.Add("COMPLETE") }
${function:Show-CoverDeletionMenu} = { param($PromptFunc) throw "simulated failure inside the Cover Deletion submenu" }
$threwQ3c = $false
try {
    try {
        $null = Show-ModeMenu -Settings $settingsQ3c -SettingsPath $pathQ3c -PromptFunc $promptQ3c
    } catch {
        $threwQ3c = $true
    }
} finally {
    ${function:Start-LogRun} = $realStartLogRunQ3c
    ${function:Complete-LogRun} = $realCompleteLogRunQ3c
    ${function:Show-CoverDeletionMenu} = $realShowCoverDeletionMenuQ3c
    [ConsoleCtrl]::RunActive = $false
}

Test-Assert $threwQ3c "sanity check: the simulated submenu failure really did propagate out"
Test-Assert ($script:eventOrderQ3c -contains "COMPLETE") ("Complete-LogRun still fired even though the submenu threw (got " + ($script:eventOrderQ3c -join ',') + ") - without the fix this is where the log run would have stayed open")
Write-Host ""
Write-Host ""

# ==============================================================================
#  Scenario Q4 (same species as Q2/Q3 above):
#  toggling Full Logging via Options, THEN picking Cover Deletion in the
#  SAME menu visit, must have Show-ModeMenu's '5' branch re-init log paths
#  BEFORE Show-CoverDeletionMenu runs, via the injected
#  -ReinitLogPathsHandler - Invoke-MainLoop's own equivalent re-init check
#  only runs AFTER Get-SelectedMode returns, too late for option 5's own
#  real work done INSIDE that same call. Without the re-init, Cover Deletion's
#  Write-Log calls would land in the pre-toggle log files. Full Logging is
#  nested under the Options schema's 'Logging' submenu (key '5', item
#  '1'), so the navigation needs an extra level of '0' to back all the
#  way out before reaching '5' at the main prompt.
# ==============================================================================
Write-Host "=== Scenario Q4: toggling Full Logging then picking Cover Deletion re-inits log paths BEFORE the submenu runs ===" -ForegroundColor Cyan
$settingsQ4 = Get-DefaultScriptSettings
$settingsQ4.FullLogging = $false
$pathQ4 = New-ScratchSettingsPath "scenario-q4"
# '0' -> Options, '5' -> Logging submenu, '1' -> toggle Full Logging on
# (submenu redisplays), '0' -> back out of Logging submenu, '0' -> back
# out of Options to the main prompt, '5' -> Cover Deletion (re-init should
# fire here, BEFORE the stubbed submenu below runs), '2' -> resolve a mode.
$promptQ4 = New-ScriptedPrompt -Responses @('0', '5', '1', '0', '0', '5', '2')
$script:reinitCallCountQ4 = 0
# NOT .GetNewClosure()'d - it only touches a $script:-scoped variable,
# which resolves correctly on its own; .GetNewClosure() is the fix for a
# DIFFERENT trap (a local variable read across a function boundary) and
# actively breaks $script:-prefixed reads/writes inside the closure it
# wraps (the increment would silently go to the wrong
# scope and $script:reinitCallCountQ4 would never move).
$reinitHandlerQ4 = { $script:reinitCallCountQ4++ }
$stubCoverMenuQ4 = { param($PromptFunc) $script:reinitCallCountAtCoverQ4 = $script:reinitCallCountQ4 }
$realShowCoverDeletionMenuQ4 = ${function:Show-CoverDeletionMenu}
${function:Show-CoverDeletionMenu} = $stubCoverMenuQ4
try {
    $resultQ4 = Show-ModeMenu -Settings $settingsQ4 -SettingsPath $pathQ4 -PromptFunc $promptQ4 -ReinitLogPathsHandler $reinitHandlerQ4
} finally {
    ${function:Show-CoverDeletionMenu} = $realShowCoverDeletionMenuQ4
}

Test-Assert ($settingsQ4.FullLogging -eq $true) "sanity check: the Options toggle actually flipped FullLogging to true in `$Settings"
Test-Assert ($script:reinitCallCountAtCoverQ4 -eq 1) ("the log-path re-init handler had already fired exactly once BEFORE Cover Deletion ran (got " + $script:reinitCallCountAtCoverQ4 + ")")
Test-Assert ($resultQ4.Mode -eq 'ImageConversion') "the loop still resolved a mode normally afterward"

# Second visit to Cover Deletion in the SAME call, nothing changed since -
# must NOT re-init again (no-op when the tracked values haven't moved).
$promptQ4b = New-ScriptedPrompt -Responses @('5', '5', '2')
$script:reinitCallCountQ4b = 0
$reinitHandlerQ4b = { $script:reinitCallCountQ4b++ }
${function:Show-CoverDeletionMenu} = { param($PromptFunc) $script:reinitCallCountAtCoverQ4b = $script:reinitCallCountQ4b }
try {
    $null = Show-ModeMenu -Settings (Get-DefaultScriptSettings) -SettingsPath (New-ScratchSettingsPath "scenario-q4b") -PromptFunc $promptQ4b -ReinitLogPathsHandler $reinitHandlerQ4b
} finally {
    ${function:Show-CoverDeletionMenu} = $realShowCoverDeletionMenuQ4
}
Test-Assert ($script:reinitCallCountAtCoverQ4b -eq 0) "visiting Cover Deletion twice with no settings change in between does not re-init log paths either time"
Write-Host ""

# ==============================================================================
#  Scenario R: Show-CoverDeletionMenu - Run, Add, and Trailing-Zero (5)
#  all dispatch through their injected handlers and
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
#  Scenario S2: Invoke-CoverDeletionRun and Invoke-TrailingZeroAuditRun
#  get direct coverage here (every scenario above
#  injects the handler instead) - both real-deletion/real-scan functions,
#  called here directly with their real UnwantedImage.ps1 dependencies
#  stubbed locally (that module isn't dot-sourced in this harness - see
#  this file's own header). Covers the -PathType Container check (a
#  dropped FILE, not a folder, is rejected instead of silently
#  becoming a one-file scan target) for both functions, and
#  Invoke-TrailingZeroAuditRun's own "only open the report if something
#  was actually found" branch.
# ==============================================================================
Write-Host "=== Scenario S2: Invoke-CoverDeletionRun / Invoke-TrailingZeroAuditRun direct coverage, including the -PathType Container fix ===" -ForegroundColor Cyan
$fileS2 = Join-Path $scratchDir "not-a-folder-s2.txt"
"not a folder" | Set-Content -LiteralPath $fileS2 -Encoding UTF8
$realFolderS2 = Join-Path $scratchDir "real-folder-s2"
New-Item -ItemType Directory -Path $realFolderS2 -Force | Out-Null

function Invoke-UnwantedImageScan { param($Path, $Profiles, $DryRun) $script:unwantedScanCallsS2.Add($Path); $script:unwantedScanDryRunCallsS2.Add([bool]$DryRun); return @{ ScannedPath = $Path } }
function Get-AllUnwantedImageProfiles { param($ProfilesPath) return @() }
$script:unwantedScanCallsS2 = New-Object System.Collections.Generic.List[string]
$script:unwantedScanDryRunCallsS2 = New-Object System.Collections.Generic.List[bool]

$promptFileS2 = { param($m) $fileS2 }
$resultRunFileS2 = Invoke-CoverDeletionRun -ProfilesPath "unused" -PromptFunc $promptFileS2
Test-Assert (-not $resultRunFileS2.Ran) "Invoke-CoverDeletionRun rejects a FILE dropped on the folder prompt, not a silent one-file scan"
Test-Assert ($script:unwantedScanCallsS2.Count -eq 0) "the real scan function was never called for a rejected file path"

$promptFolderS2 = { param($m) $realFolderS2 }
# No confirmation prompt - the dry-run choice is the
# saved CoverDeletionDryRun setting, passed in as -DryRun. A one-response
# scripted prompt proves only the folder prompt is asked.
$resultRunFolderS2 = Invoke-CoverDeletionRun -ProfilesPath "unused" -PromptFunc (New-ScriptedPrompt -Responses @($realFolderS2)) -DryRun $false
Test-Assert ($resultRunFolderS2.Ran -and $script:unwantedScanCallsS2.Count -eq 1 -and $script:unwantedScanCallsS2[0] -eq $realFolderS2) "a prompted real folder is scanned straight away - no confirmation prompt"
Test-Assert ($resultRunFolderS2.DryRun -eq $false -and $script:unwantedScanDryRunCallsS2[0] -eq $false) "-DryRun `$false runs for real"

# A real (non-dry) run on a drive with no Recycle Bin, with
# Permanent Delete off, is refused up front - same rule as Invoke-Mode.
# A dry run deletes nothing, so it still runs. Drive type forced via
# RecycleBinProbe's test override.
try {
    [RecycleBinProbe]::ResetTestOverrides()
    [RecycleBinProbe]::TestDriveType = 4
    $callsBeforeS2r = $script:unwantedScanCallsS2.Count
    $resultRefusedS2 = & { Invoke-CoverDeletionRun -ProfilesPath "unused" -PromptFunc (New-ScriptedPrompt -Responses @($realFolderS2)) -DryRun $false } 6>$null
    Test-Assert ((-not $resultRefusedS2.Ran) -and $script:unwantedScanCallsS2.Count -eq $callsBeforeS2r) "a real Cover Deletion run on a no-Recycle-Bin drive (Permanent Delete off) is refused, scan never called"
    $resultDryOkS2 = & { Invoke-CoverDeletionRun -ProfilesPath "unused" -PromptFunc (New-ScriptedPrompt -Responses @($realFolderS2)) -DryRun $true } 6>$null
    Test-Assert ($resultDryOkS2.Ran -and $resultDryOkS2.DryRun) "...but a dry run on the same drive still runs (it deletes nothing)"
} finally {
    [RecycleBinProbe]::ResetTestOverrides()
    # Undo this block's own dry-run call so the call-count assertions below see the same state as before.
    while ($script:unwantedScanCallsS2.Count -gt $callsBeforeS2r) {
        $script:unwantedScanCallsS2.RemoveAt($script:unwantedScanCallsS2.Count - 1)
        $script:unwantedScanDryRunCallsS2.RemoveAt($script:unwantedScanDryRunCallsS2.Count - 1)
    }
}

# -FolderPath (the target folder, when "Ask for folder" is
# off) skips the prompt entirely, and an omitted -DryRun defaults to a
# real run.
$noPromptS2 = { param($m) throw ("unexpected prompt: " + $m) }
$resultTargetS2 = Invoke-CoverDeletionRun -ProfilesPath "unused" -PromptFunc $noPromptS2 -FolderPath $realFolderS2
Test-Assert ($resultTargetS2.Ran -and $resultTargetS2.ResolvedPath -eq $realFolderS2) "-FolderPath scans that folder without prompting"
Test-Assert ($script:unwantedScanCallsS2.Count -eq 2 -and $script:unwantedScanDryRunCallsS2[1] -eq $false) "an omitted -DryRun defaults to a real run"

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
#  Scenario S2b: -OpenHandler's own
#  return value must not leak into Invoke-TrailingZeroAuditRun's output
#  stream - a handler returning something (the shipped default,
#  Start-Process with no -PassThru, never does) would turn this
#  function's single-hashtable return into a 2-element array.
# ==============================================================================
Write-Host "=== Scenario S2b: a chatty -OpenHandler's return value does not leak into the function's own output ===" -ForegroundColor Cyan
$chattyOpenHandlerS2b = { param($Path) return "some object a real Start-Process -PassThru might return" }
$resultTZChattyS2b = Invoke-TrailingZeroAuditRun -ReportPath $reportPathS2 -PromptFunc $promptFolderS2 -OpenHandler $chattyOpenHandlerS2b
Test-Assert ($resultTZChattyS2b -is [hashtable]) ("the function still returns a single hashtable, not an array, even when -OpenHandler itself returns something (got type: " + $resultTZChattyS2b.GetType().Name + ")")
Write-Host ""

# ==============================================================================
#  Scenario S3:
#  Invoke-CoverDeletionRun/Invoke-TrailingZeroAuditRun's -DefaultPath
#  (remembered-folder reuse on blank input) and Invoke-TrailingZeroAuditRun's
#  -Path bypass (skip the prompt entirely) - both real functions, same
#  stubbed UnwantedImage.ps1 dependencies as Scenario S2.
# ==============================================================================
Write-Host "=== Scenario S3: -DefaultPath reuse and -Path bypass ===" -ForegroundColor Cyan
$script:unwantedScanCallsS2.Clear()
$script:unwantedScanDryRunCallsS2.Clear()

# Blank input (just pressing Enter) at BOTH the path prompt and the
# confirmation reuses -DefaultPath and still runs for real - Y is the
# scripted confirmation answer here, not blank, since only the PATH
# prompt is meant to fall back to the remembered default.
$promptBlankReuseS3 = New-ScriptedPrompt -Responses @('', 'Y')
$resultReuseS3 = Invoke-CoverDeletionRun -ProfilesPath "unused" -PromptFunc $promptBlankReuseS3 -DefaultPath $realFolderS2
Test-Assert ($resultReuseS3.Ran -and $resultReuseS3.ResolvedPath -eq $realFolderS2) "blank input at the path prompt reuses -DefaultPath (got ResolvedPath='$($resultReuseS3.ResolvedPath)')"
Test-Assert ($script:unwantedScanCallsS2.Count -eq 1 -and $script:unwantedScanCallsS2[0] -eq $realFolderS2) "the reused default path was what actually got scanned"

# Blank input with NO -DefaultPath still cancels exactly like before -
# reuse is additive, not a change to the no-default case.
$promptBlankNoDefaultS3 = New-ScriptedPrompt -Responses @('')
$resultNoDefaultS3 = Invoke-CoverDeletionRun -ProfilesPath "unused" -PromptFunc $promptBlankNoDefaultS3
Test-Assert (-not $resultNoDefaultS3.Ran -and $null -eq $resultNoDefaultS3.ResolvedPath) "blank input with no -DefaultPath still cancels (unchanged behavior)"

# Same reuse convention for Invoke-TrailingZeroAuditRun.
$script:trailingZeroAuditCallsS2.Clear()
$script:trailingZeroFoundS2 = $false
$promptTZReuseS3 = New-ScriptedPrompt -Responses @('')
$resultTZReuseS3 = Invoke-TrailingZeroAuditRun -ReportPath $reportPathS2 -PromptFunc $promptTZReuseS3 -OpenHandler $openHandlerS2 -DefaultPath $realFolderS2
Test-Assert ($resultTZReuseS3.Ran -and $resultTZReuseS3.ResolvedPath -eq $realFolderS2) "Invoke-TrailingZeroAuditRun also reuses -DefaultPath on blank input"

# -Path bypass: no prompt at all, even one that would throw if called
# (New-ScriptedPrompt throws when asked for more responses than queued -
# an empty queue here means ANY prompt call fails this scenario).
$script:trailingZeroAuditCallsS2.Clear()
$noPromptS3 = New-ScriptedPrompt -Responses @()
$resultTZPathS3 = Invoke-TrailingZeroAuditRun -ReportPath $reportPathS2 -PromptFunc $noPromptS3 -OpenHandler $openHandlerS2 -Path $realFolderS2
Test-Assert ($resultTZPathS3.Ran -and $resultTZPathS3.ResolvedPath -eq $realFolderS2) "-Path bypasses the prompt entirely and scans the given path directly"
Test-Assert ($script:trailingZeroAuditCallsS2.Count -eq 1 -and $script:trailingZeroAuditCallsS2[0] -eq $realFolderS2) "the real audit function received the -Path value, not a prompted one"
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
#  Scenario U: Show-CoverDeletionMenu's
#  own switch cases must not leak a handler's non-$null return value (Run/
#  Add/TrailingZero all return real hashtables in production) into ITS OWN
#  output stream. Calls Show-CoverDeletionMenu directly and captures every
#  bit of output from the whole call - without the $null = assignments, this would come
#  back with the handlers' own return values mixed in.
# ==============================================================================
Write-Host "=== Scenario U: Show-CoverDeletionMenu doesn't leak Run/Add/TrailingZero handler return values ===" -ForegroundColor Cyan
$runHandlerU = { param($ProfilesPath, $PromptFunc) @{ Ran = $true; Reason = $null } }
$addHandlerU = { param($ProfilesPath, $PromptFunc) @{ Added = $true } }
$trailingZeroHandlerU = { param($PromptFunc) @{ Ran = $true; Reason = $null; Result = @{ ReportPath = $null } } }
$promptU = New-ScriptedPrompt -Responses @('1', '2', '5', '0')
$outputU = Show-CoverDeletionMenu -ProfilesPath "unused" -PromptFunc $promptU -RunHandler $runHandlerU -AddHandler $addHandlerU -TrailingZeroHandler $trailingZeroHandlerU
Test-Assert ($null -eq $outputU) ("Show-CoverDeletionMenu's own call produced no output despite its Run/Add/TrailingZero handlers all returning non-`$null hashtables (got: " + $outputU + ")")
Write-Host ""

# ==============================================================================
#  Scenario U3:
#  Show-CoverDeletionMenu's two behaviors - (a) persisting
#  $Settings.LastCoverDeletionPath immediately after item 1 OR item 5
#  resolves a real path, and (b) item 1 firing -AutoTrailingZeroHandler
#  automatically with that same resolved path, no second prompt.
#  -RunHandler/-AutoTrailingZeroHandler stay fakes (same technique as
#  Scenario U above) so this proves DISPATCH, not real scan/report
#  behavior - that's Scenario S3's job. Persistence itself is tested
#  against a REAL scratch settings.json (Scenario K/L/M's own pattern),
#  not an injectable save handler, since a default handler calling
#  Export-ScriptSettings bare/unassigned would reintroduce the
#  output-stream leak Scenario U guards against. This scenario's own call
#  is captured and asserted $null (matching Scenario U's own
#  leak-regression check).
# ==============================================================================
Write-Host "=== Scenario U3: persisted LastCoverDeletionPath + automatic post-scan trailing-zero report ===" -ForegroundColor Cyan
$fakePathU3 = "C:\fake\resolved\path"
$runHandlerU3 = { param($ProfilesPath, $PromptFunc, $DefaultPath) $script:defaultPathSeenU3 = $DefaultPath; @{ Ran = $true; Reason = $null; ResolvedPath = $fakePathU3 } }
$autoTZHandlerU3 = { param($Path) $script:autoTZCallsU3.Add($Path); @{ Ran = $true } }
$script:autoTZCallsU3 = New-Object System.Collections.Generic.List[string]
$settingsU3 = Get-DefaultScriptSettings
$settingsU3.LastCoverDeletionPath = "C:\old\remembered\path"
$settingsPathU3 = New-ScratchSettingsPath "scenario-u3"
$promptU3 = New-ScriptedPrompt -Responses @('1', '0')

$outputU3 = Show-CoverDeletionMenu -ProfilesPath "unused" -PromptFunc $promptU3 -RunHandler $runHandlerU3 `
    -AutoTrailingZeroHandler $autoTZHandlerU3 -Settings $settingsU3 -SettingsPath $settingsPathU3

Test-Assert ($null -eq $outputU3) "Show-CoverDeletionMenu's own call produced no output despite the real Export-ScriptSettings call this branch now makes"
Test-Assert ($script:defaultPathSeenU3 -eq "C:\old\remembered\path") "the previously-remembered path was offered to -RunHandler as -DefaultPath"
Test-Assert ($script:autoTZCallsU3.Count -eq 1 -and $script:autoTZCallsU3[0] -eq $fakePathU3) "the auto trailing-zero handler fired exactly once, with item 1's own resolved path"
Test-Assert ($settingsU3.LastCoverDeletionPath -eq $fakePathU3) "`$Settings itself was mutated in place, not just a copy - same convention Show-OptionsMenuLevel already uses"
$reloadedU3 = Import-ScriptSettings -Path $settingsPathU3
Test-Assert ($reloadedU3.LastCoverDeletionPath -eq $fakePathU3) "the resolved path was saved immediately to REAL disk (not batched) - reloading the settings file confirms it, not just the in-memory hashtable"

# No -Settings supplied at all (the original, still-default behavior for
# every existing caller/test) - persistence is skipped entirely, but the
# auto trailing-zero report still fires unconditionally, since that
# doesn't depend on remembering anything.
$script:autoTZCallsU3.Clear()
$promptU3b = New-ScriptedPrompt -Responses @('1', '0')
$outputU3b = Show-CoverDeletionMenu -ProfilesPath "unused" -PromptFunc $promptU3b -RunHandler $runHandlerU3 -AutoTrailingZeroHandler $autoTZHandlerU3
Test-Assert ($null -eq $outputU3b) "still no output leak with -Settings entirely omitted"
Test-Assert ($script:autoTZCallsU3.Count -eq 1) "the auto trailing-zero report still fires with no -Settings at all"
Write-Host ""

# ==============================================================================
#  Scenario U4 (Cover Deletion avoids a redundant directory walk):
#  Show-CoverDeletionMenu's '1' branch reuses -RunHandler's own
#  AllScannedFiles for the auto-chained trailing-zero audit instead of
#  making it walk $path again - existence-filtered first, since item 1
#  may have just deleted some of what it found. Two real files created on
#  disk; one is deleted between the fake -RunHandler returning and the
#  -AutoTrailingZeroHandler firing, simulating item 1's own real deletion
#  pass. Fakes still stand in for the real scan/audit functions (that's
#  Scenario S2/S3's job) - this proves ONLY the existence-filtered
#  plumbing between them.
# ==============================================================================
Write-Host "=== Scenario U4: AllScannedFiles reused + existence-filtered for the auto trailing-zero audit ===" -ForegroundColor Cyan
$survivingFileU4 = Join-Path $scratchDir "u4-survives.png"
"x" | Set-Content -LiteralPath $survivingFileU4 -Encoding UTF8
$deletedFileU4 = Join-Path $scratchDir "u4-deleted.png"
"x" | Set-Content -LiteralPath $deletedFileU4 -Encoding UTF8
$allScannedU4 = @((Get-Item -LiteralPath $survivingFileU4), (Get-Item -LiteralPath $deletedFileU4))

$runHandlerU4 = {
    param($ProfilesPath, $PromptFunc, $DefaultPath)
    # Simulates item 1's own real scan-then-delete: the "deleted" file is
    # removed from disk here, same as Invoke-UnwantedImageScan's own
    # Remove-Source call would, AFTER the walk that produced AllScannedFiles.
    Remove-Item -LiteralPath $deletedFileU4 -Force
    @{ Ran = $true; Reason = $null; ResolvedPath = $fakePathU3; AllScannedFiles = $allScannedU4 }
}
$script:preScannedSeenU4 = $null
$autoTZHandlerU4 = { param($Path, $PreScannedFiles) $script:preScannedSeenU4 = $PreScannedFiles; @{ Ran = $true } }
$promptU4 = New-ScriptedPrompt -Responses @('1', '0')

$outputU4 = Show-CoverDeletionMenu -ProfilesPath "unused" -PromptFunc $promptU4 -RunHandler $runHandlerU4 -AutoTrailingZeroHandler $autoTZHandlerU4
Test-Assert ($null -eq $outputU4) "no output leak with the new AllScannedFiles plumbing in play"
Test-Assert ($null -ne $script:preScannedSeenU4) "the auto trailing-zero handler received a non-null -PreScannedFiles"
Test-Assert (($script:preScannedSeenU4 | Where-Object { $_.FullName -eq $survivingFileU4 }).Count -eq 1) "the file that's still on disk survives the existence filter"
Test-Assert (($script:preScannedSeenU4 | Where-Object { $_.FullName -eq $deletedFileU4 }).Count -eq 0) "the file item 1 just deleted is filtered OUT before reaching the trailing-zero audit"
Write-Host ""

# ==============================================================================
#  Scenario U2: the full
#  real chain - Show-ModeMenu's '5' branch into the REAL Show-CoverDeletionMenu,
#  whose default -TrailingZeroHandler resolves to the real
#  Invoke-TrailingZeroAuditRun (function-swapped here to a fake returning a
#  real hashtable with no real file scan, same technique as Scenario Q2's
#  Show-CoverDeletionMenu swap). Without the $null = assignments in both functions,
#  Get-SelectedMode's `$resolved` would come back as a 2-element array (the leaked
#  hashtable, then the real resolved mode) the first time a real mode was
#  picked right after visiting the trailing-zero audit (CCO off -> mode 5 ->
#  trailing-zero audit -> CCO back on -> attempt mode 1 -> crash).
# ==============================================================================
Write-Host "=== Scenario U2: Show-ModeMenu's real chain into Cover Deletion's real TrailingZeroHandler default doesn't corrupt `$resolved ===" -ForegroundColor Cyan
$settingsU2 = Get-DefaultScriptSettings
$pathU2 = New-ScratchSettingsPath "scenario-u2"
$promptU2 = New-ScriptedPrompt -Responses @('5', '5', '0', '2')
$fakeTrailingZeroU2 = { param($PromptFunc) @{ Ran = $true; Reason = $null; Result = @{ ReportPath = $null } } }
$realInvokeTrailingZeroAuditRunU2 = ${function:Invoke-TrailingZeroAuditRun}
${function:Invoke-TrailingZeroAuditRun} = $fakeTrailingZeroU2
try {
    $resultU2 = Show-ModeMenu -Settings $settingsU2 -SettingsPath $pathU2 -PromptFunc $promptU2
} finally {
    ${function:Invoke-TrailingZeroAuditRun} = $realInvokeTrailingZeroAuditRunU2
}
Test-Assert ($resultU2 -isnot [array]) ("`$resolved came back as a single object, not an array, after visiting the trailing-zero audit (got type: " + $resultU2.GetType().Name + ")")
Test-Assert ($resultU2 -is [hashtable]) "`$resolved is a hashtable"
Test-Assert ($resultU2.Mode -eq 'ImageConversion') "the real mode selection ('2') still resolved correctly right after the leak-prone branch ran"
Write-Host ""

# ==============================================================================
#  Scenario V: menu-to-menu navigation clears and redraws.
#  A spy -ClearScreenFunc and -PromptFunc log into one sequence, plus a
#  temporary Write-Host override so a carried notice's position is visible.
#  V1: Show-ModeMenu's first render never clears (it follows startup/run
#  output); an invalid pick clears, redraws, and shows "Invalid selection."
#  under the redrawn menu. V2/V3: Cover Deletion clears on entry, never
#  right after a work option (1/2/5), and reports via -ScreenState whether
#  work output is still on screen when it returns.
# ==============================================================================
Write-Host "=== Scenario V: menu navigation clears/redraws, never right after output ===" -ForegroundColor Cyan

$seqV1 = New-Object System.Collections.Generic.List[string]
$innerPromptV1 = New-ScriptedPrompt -Responses @('x', '2')
$promptV1 = { param($Message) $seqV1.Add("PROMPT"); & $innerPromptV1 $Message }.GetNewClosure()
$clearV1  = { $seqV1.Add("CLEAR") }.GetNewClosure()
function Write-Host { param([Parameter(Position = 0)]$Object, $ForegroundColor, [switch]$NoNewline) $seqV1.Add("OUT:" + $Object) }
try {
    $resolvedV1 = Show-ModeMenu -Settings (Get-DefaultScriptSettings) -SettingsPath (New-ScratchSettingsPath "scenario-v1") -PromptFunc $promptV1 -ClearScreenFunc $clearV1
} finally {
    Remove-Item -Path function:\Write-Host
}
$lastClearV1  = $seqV1.LastIndexOf("CLEAR")
$noticeV1     = $seqV1.IndexOf("OUT:Invalid selection.")
$lastPromptV1 = $seqV1.LastIndexOf("PROMPT")
Test-Assert ($seqV1[0] -ne "CLEAR") "Show-ModeMenu's first render does not clear (keeps startup/run output above it)"
Test-Assert (@($seqV1 | Where-Object { $_ -eq "CLEAR" }).Count -eq 1) ("exactly one clear - for the redraw after the invalid pick (got " + @($seqV1 | Where-Object { $_ -eq "CLEAR" }).Count + ")")
Test-Assert ($noticeV1 -gt $lastClearV1 -and $noticeV1 -lt $lastPromptV1) "'Invalid selection.' is printed after the clear, under the redrawn menu, before the next prompt"
Test-Assert ($resolvedV1.Mode -eq 'ImageConversion') "the menu still resolves the valid pick after the redraw"

$seqV2 = New-Object System.Collections.Generic.List[string]
$innerPromptV2 = New-ScriptedPrompt -Responses @('1', 'x', '0')
$promptV2 = { param($Message) $seqV2.Add("PROMPT"); & $innerPromptV2 $Message }.GetNewClosure()
$clearV2  = { $seqV2.Add("CLEAR") }.GetNewClosure()
$screenV2 = @{ HasOutput = $null }
Show-CoverDeletionMenu -ProfilesPath (Join-Path $scratchDir "scenario-v2-profiles.json") -PromptFunc $promptV2 -ClearScreenFunc $clearV2 -ClearOnFirstRender $true -ScreenState $screenV2 `
    -RunHandler { param($ProfilesPath, $PromptFunc, $DefaultPath) return $null } | Out-Null
Test-Assert (($seqV2 -join ",") -eq "CLEAR,PROMPT,PROMPT,CLEAR,PROMPT") ("Cover Deletion clears on entry, NOT right after Run, then clears again after the invalid pick (got " + ($seqV2 -join ",") + ")")
Test-Assert ($screenV2.HasOutput -eq $false) "once a later redraw has cleared, -ScreenState reports no work output left on screen"

$seqV3 = New-Object System.Collections.Generic.List[string]
$innerPromptV3 = New-ScriptedPrompt -Responses @('1', '0')
$promptV3 = { param($Message) $seqV3.Add("PROMPT"); & $innerPromptV3 $Message }.GetNewClosure()
$clearV3  = { $seqV3.Add("CLEAR") }.GetNewClosure()
$screenV3 = @{ HasOutput = $null }
Show-CoverDeletionMenu -ProfilesPath (Join-Path $scratchDir "scenario-v3-profiles.json") -PromptFunc $promptV3 -ClearScreenFunc $clearV3 -ClearOnFirstRender $true -ScreenState $screenV3 `
    -RunHandler { param($ProfilesPath, $PromptFunc, $DefaultPath) return $null } | Out-Null
Test-Assert (($seqV3 -join ",") -eq "CLEAR,PROMPT,PROMPT") ("backing out right after Run doesn't clear (got " + ($seqV3 -join ",") + ")")
Test-Assert ($screenV3.HasOutput -eq $true) "-ScreenState tells Show-ModeMenu the Run output is still on screen, so it won't clear it either"
Write-Host ""

# ==============================================================================
#  Scenario W: Cover Deletion's saved settings. Run and the
#  trailing-zero report get the target folder (no prompt) while "Ask for
#  folder" is off, and "" (= prompt) once it's on; Run gets the saved
#  dry-run value. 6/7 toggle and persist both settings, and the menu shows
#  their current state.
# ==============================================================================
Write-Host "=== Scenario W: Cover Deletion dry-run / ask-for-folder settings ===" -ForegroundColor Cyan
$settingsW = Get-DefaultScriptSettings
$settingsPathW = New-ScratchSettingsPath "scenario-w"
$runCallsW = New-Object System.Collections.Generic.List[hashtable]
$tzCallsW  = New-Object System.Collections.Generic.List[string]
$runHandlerW = { param($ProfilesPath, $PromptFunc, $DefaultPath, $Path, $DryRun) $runCallsW.Add(@{ Path = $Path; DryRun = $DryRun }); return $null }.GetNewClosure()
$tzHandlerW  = { param($PromptFunc, $DefaultPath, $Path) $tzCallsW.Add([string]$Path); return $null }.GetNewClosure()
$linesW = New-Object System.Collections.Generic.List[string]
function Write-Host { param([Parameter(Position = 0)]$Object, $ForegroundColor, [switch]$NoNewline) $linesW.Add([string]$Object) }
try {
    Show-CoverDeletionMenu -ProfilesPath (Join-Path $scratchDir "scenario-w-profiles.json") -Settings $settingsW -SettingsPath $settingsPathW -TargetPath "C:\fake\target" `
        -PromptFunc (New-ScriptedPrompt -Responses @('1', '5', '6', '7', '1', '5', '0')) -RunHandler $runHandlerW -TrailingZeroHandler $tzHandlerW -ClearScreenFunc { } | Out-Null
} finally {
    Remove-Item -Path function:\Write-Host
}
Test-Assert ($runCallsW.Count -eq 2 -and $runCallsW[0].Path -eq "C:\fake\target" -and $runCallsW[0].DryRun -eq $false) "by default Run gets the target folder (no prompt) and a real run"
Test-Assert ($tzCallsW.Count -eq 2 -and $tzCallsW[0] -eq "C:\fake\target") "the trailing-zero report follows the same folder logic"
Test-Assert ($runCallsW.Count -eq 2 -and [string]::IsNullOrEmpty($runCallsW[1].Path) -and $runCallsW[1].DryRun -eq $true) "after toggling 6 and 7, Run asks for a folder and does a dry run"
Test-Assert ($tzCallsW.Count -eq 2 -and [string]::IsNullOrEmpty($tzCallsW[1])) "...and so does the trailing-zero report"
$savedW = Import-ScriptSettings -Path $settingsPathW
Test-Assert ($savedW.CoverDeletionDryRun -eq $true -and $savedW.CoverDeletionAskForFolder -eq $true) "both toggles were saved to the settings file"
Test-Assert (@($linesW | Where-Object { $_ -like "*6 - Dry Run*[On]*" }).Count -ge 1 -and @($linesW | Where-Object { $_ -like "*6 - Dry Run*[Off]*" }).Count -ge 1) "the menu shows Dry Run's current state, before and after the toggle"
Test-Assert (@($linesW | Where-Object { $_ -like "*7 - Ask For Folder*[Off]*C:\fake\target*" }).Count -ge 1) "with Ask For Folder off, the menu names the target folder it will scan"
Write-Host ""

# ==============================================================================
#  Summary
# ==============================================================================
# ==============================================================================
#  Scenario W2: a default Run on the target folder
#  must not overwrite LastCoverDeletionPath - that's the folder the user
#  last typed in, offered again when "Ask for folder" is turned back on.
# ==============================================================================
Write-Host "=== Scenario W2: only a typed-in folder is remembered ===" -ForegroundColor Cyan
$settingsW2 = Get-DefaultScriptSettings
$settingsW2.LastCoverDeletionPath = "D:\typed-earlier"
$runHandlerW2 = { param($ProfilesPath, $PromptFunc, $DefaultPath, $Path, $DryRun) $resolvedPathW2 = if ([string]::IsNullOrEmpty($Path)) { "D:\typed-now" } else { $Path }; return @{ Ran = $true; ResolvedPath = $resolvedPathW2; AllScannedFiles = $null } }
$tzHandlerW2  = { param($PromptFunc, $DefaultPath, $Path) $resolvedPathW2 = if ([string]::IsNullOrEmpty($Path)) { "D:\typed-now" } else { $Path }; return @{ Ran = $true; ResolvedPath = $resolvedPathW2 } }
$menuArgsW2 = @{ ProfilesPath = (Join-Path $scratchDir "scenario-w2-profiles.json"); Settings = $settingsW2; SettingsPath = (New-ScratchSettingsPath "scenario-w2"); TargetPath = "C:\fake\target"
                 RunHandler = $runHandlerW2; TrailingZeroHandler = $tzHandlerW2; AutoTrailingZeroHandler = { param($Path, $PreScannedFiles) }; ClearScreenFunc = { } }
Show-CoverDeletionMenu @menuArgsW2 -PromptFunc (New-ScriptedPrompt -Responses @('1', '5', '0')) 6>$null | Out-Null
Test-Assert ($settingsW2.LastCoverDeletionPath -eq "D:\typed-earlier") ("runs on the target folder left the remembered folder alone (got '" + $settingsW2.LastCoverDeletionPath + "')")
Show-CoverDeletionMenu @menuArgsW2 -PromptFunc (New-ScriptedPrompt -Responses @('7', '1', '0')) 6>$null | Out-Null
Test-Assert ($settingsW2.LastCoverDeletionPath -eq "D:\typed-now") ("with Ask For Folder on, the typed-in folder is remembered (got '" + $settingsW2.LastCoverDeletionPath + "')")
Write-Host ""

Write-Host "==============================================="
if ($script:failCount -eq 0) {
    Write-Host ("ALL PASSED  (" + $script:passCount + " assertions)") -ForegroundColor Green
} else {
    Write-Host ($script:failCount.ToString() + " FAILED, " + $script:passCount + " passed") -ForegroundColor Red
}
Write-Host "==============================================="

try { Remove-Item -LiteralPath $scratchDir -Recurse -Force } catch { }

if ($script:failCount -gt 0) { exit 1 } else { exit 0 }
