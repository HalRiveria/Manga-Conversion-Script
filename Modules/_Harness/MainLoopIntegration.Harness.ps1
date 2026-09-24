<#
.SYNOPSIS
    Cross-module integration harness for the ONE seam no per-module
    harness (or the existing Controller.Harness.ps1) actually covers:
    Controller.ps1's real Invoke-MainLoop, driving the real Menu.ps1
    (Get-SelectedMode -> Show-ModeMenu -> Show-CoverDeletionMenu), which
    in turn calls the real UnwantedImage.ps1 (Invoke-CoverDeletionRun ->
    Invoke-UnwantedImageScan), all wired together for real - only the
    interactive prompt (-PromptFunc, scripted) and the file-scan target
    (a real scratch folder) are ever faked.

.DESCRIPTION
    Every other harness draws its boundary at (roughly) one module:
    Controller.Harness.ps1 IS already integration-style for the pipeline
    engines (dot-sources ImageConversionPipeline.ps1/
    AnimatedConversionPipeline.ps1/etc. for real), but every one of its
    own Invoke-MainLoop scenarios injects a FAKE -GetModeHandler - the
    real Get-SelectedMode (Menu.ps1) is never actually called from
    Invoke-MainLoop by any harness. Symmetrically, Menu.Harness.ps1 dot-
    sources the real Menu.ps1 but STUBS Invoke-UnwantedImageScan/
    Invoke-TrailingZeroAudit/Get-AllUnwantedImageProfiles entirely (see
    that harness's own header) - the real UnwantedImage.ps1 is never
    dot-sourced there either. And UnwantedImage.Harness.ps1 tests
    UnwantedImage.ps1 by calling its functions directly, never through
    Menu.ps1's own wrapper functions.

    Net effect (found by a 2026-09-02 full-codebase review, not by any
    existing harness): mode 5 (Cover Deletion)'s real work runs INSIDE
    Get-SelectedMode, not inside Invoke-Mode like every other mode - so
    it was the one mode never covered by Invoke-Mode's own try/catch,
    and nothing else caught that either, because no harness exercised
    the real chain connecting all three modules. This harness exists
    specifically to close that gap - see Scenario B below for the actual
    regression test proving the fix (Controller.ps1's Invoke-MainLoop,
    2026-09-02) protects this real chain end to end, not just an
    abstract fake-throwing handler.

    Deliberately does NOT dot-source ImageConversionPipeline.ps1/
    AnimatedConversionPipeline.ps1/ZipPipeline.ps1/ZipParallelProcessing.ps1/
    ZipCreation.ps1/ZipValidation.ps1/LeafDirectoryDiscovery.ps1/
    CleanConsoleRendering.ps1/Summary.ps1 - every scenario here injects a
    lightweight fake -InvokeModeHandler for any loop iteration that
    isn't mode 5 itself (mode 5 never reaches Invoke-Mode at all, and a
    fake handler returning $null skips Write-SummaryReport's own real
    dependency on Summary.ps1), so Invoke-Mode's real body - which DOES
    need all of those - is never actually invoked here. That's already
    proven, with real pipeline engines, by Controller.Harness.ps1 itself.

.EXAMPLE
    .\Modules\_Harness\MainLoopIntegration.Harness.ps1
#>

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$modulesDir = Join-Path $PSScriptRoot ".."
. (Join-Path $modulesDir "Config.ps1")
. (Join-Path $modulesDir "Logging.ps1")
. (Join-Path $modulesDir "FileDeletion.ps1")
. (Join-Path $modulesDir "AbortPipeline.ps1")
. (Join-Path $modulesDir "UnwantedImage.ps1")
. (Join-Path $modulesDir "Menu.ps1")
. (Join-Path $modulesDir "Controller.ps1")

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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("mainloop-integration-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray

Initialize-FileDeletion -PermanentDelete $true
Initialize-LogPaths -TargetPath $scratchDir -FullLogging $false -ScriptDir $scratchDir

function New-RealImage {
    param([string]$Path, [int]$Width = 40, [int]$Height = 20)
    $bitmap = New-Object System.Drawing.Bitmap($Width, $Height)
    try {
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bitmap.Dispose()
    }
    return (Get-Item -LiteralPath $Path)
}

function New-ScriptedPrompt {
    <#
    .SYNOPSIS
        Same technique as Menu.Harness.ps1's own helper of the same name:
        queues canned responses; running out throws immediately instead
        of silently falling through to a real Read-Host, so an under-
        scripted scenario fails loudly instead of hanging.
    #>
    param([string[]]$Responses)
    $queue = [System.Collections.Generic.Queue[string]]::new([string[]]$Responses)
    return {
        param($Message)
        if ($queue.Count -eq 0) { throw ("New-ScriptedPrompt: ran out of responses (last prompt: '" + $Message + "')") }
        return $queue.Dequeue()
    }.GetNewClosure()
}

function New-ThrowingPromptAfter {
    <#
    .SYNOPSIS
        Like New-ScriptedPrompt, but throws instead of returning once the
        queue is exhausted - used to simulate a genuinely uncontained
        failure somewhere in the real Menu.ps1/UnwantedImage.ps1 chain
        (nothing there wraps calls TO the injected -PromptFunc itself in
        a try/catch, by design - real production Read-Host essentially
        never throws, but nothing rules it out either, e.g. a closed/
        redirected stdin). Deliberately distinct from
        New-ScriptedPrompt's own out-of-responses throw (a harness
        authoring bug) - this one simulates a REAL failure on purpose.
    #>
    param([string[]]$Responses)
    $queue = [System.Collections.Generic.Queue[string]]::new([string[]]$Responses)
    return {
        param($Message)
        if ($queue.Count -eq 0) { throw "simulated: the interactive prompt itself failed (e.g. stdin closed)" }
        return $queue.Dequeue()
    }.GetNewClosure()
}

$fakeSettings = @{
    PermanentDelete           = $false
    CleanConsoleOutputEnabled = $false
    FullLogging               = $false
}

# Show-ModeMenu's '5' branch calls Show-CoverDeletionMenu with no
# -ProfilesPath override (Get-SelectedMode has no such param either), so
# it always resolves the REAL default (Get-UnwantedImageProfilesPath) -
# fine in production (there's only ever one real profiles file), but it
# means a caller reaching Cover Deletion through the top-level mode menu
# has no way to redirect it to a scratch file. Shadowing the function
# itself (same technique as UnwantedImage.Harness.ps1's Get-FileHash
# shadow) is the correct tool here, not a source change - adding a
# pass-through -ProfilesPath parameter through Get-SelectedMode purely
# for testability, when production never needs to vary it, would be
# exactly the kind of unneeded abstraction CLAUDE.md's own conventions
# argue against.
$script:activeProfilesPath = $null
function Get-UnwantedImageProfilesPath {
    param([string]$BaseDir)
    return $script:activeProfilesPath
}

# ==============================================================================
#  Scenario A: mode 5 (Cover Deletion -> Run) really deletes a really-
#  matching file, driven end to end through the real Invoke-MainLoop ->
#  real Get-SelectedMode -> real Show-ModeMenu -> real Show-CoverDeletionMenu
#  -> real Invoke-CoverDeletionRun -> real Invoke-UnwantedImageScan chain -
#  nothing in that chain is faked except the interactive prompt and the
#  final "now pick a real mode" step (a fake -InvokeModeHandler, so this
#  scenario doesn't also need every pipeline module dot-sourced - see
#  this file's own header).
# ==============================================================================
Write-Host "=== Scenario A: mode 5 -> Run really scans and deletes a real matching file (real Menu.ps1 + UnwantedImage.ps1 + Controller.ps1) ===" -ForegroundColor Cyan

$scanDirA = Join-Path $scratchDir "scenario-a\ToScan"
New-Item -ItemType Directory -Path $scanDirA -Force | Out-Null
$profilesPathA = Join-Path $scratchDir "scenario-a\profiles.json"
$imgA = New-RealImage -Path (Join-Path $scanDirA "cover.png") -Width 50 -Height 30
$hashA = (Get-FileHash -LiteralPath $imgA.FullName -Algorithm SHA256).Hash
$profileA = @{ Label = "Integration Test Cover"; Width = 50; Height = 30; SizeBytes = $imgA.Length; SizeTolerance = 0; Hash = $hashA }
$null = Add-UnwantedImageProfile -Profile $profileA -ProfilesPath $profilesPathA
$script:activeProfilesPath = $profilesPathA

$fakeGetModeSettingsA = $fakeSettings.Clone()
# 2026-09-23: Run scans the loop's own -TargetPath (no folder prompt, no
# confirmation); CoverDeletionDryRun off so the match is really deleted.
$fakeGetModeSettingsA.CoverDeletionDryRun = $false
$promptA = New-ScriptedPrompt -Responses @('5', '1', '0', '2')
$invokeModeCallsA = 0
$fakeInvokeModeA = { param($Resolved, $TargetPath, $Settings, $CjxlExe, $MagickExe) $script:invokeModeCallsA++; return $null }
$postRunCallsA = 0
$fakePostRunA = { $script:postRunCallsA++; return 'Exit' }
# Get-SelectedMode's own -PromptFunc is the ONLY handler this scenario
# overrides on Invoke-MainLoop itself besides -InvokeModeHandler/
# -PostRunPromptHandler - Get-SelectedMode doesn't take -PromptFunc
# through Invoke-MainLoop directly, so it's threaded via a real
# -GetModeHandler closure that calls the real Get-SelectedMode with it.
$realGetModeA = { param($Settings, $SettingsPath, $ReinitLogPathsHandler, $TargetPath) Get-SelectedMode -Settings $Settings -SettingsPath $SettingsPath -PromptFunc $promptA -TargetPath $TargetPath }.GetNewClosure()

Invoke-MainLoop -TargetPath $scanDirA -Settings $fakeGetModeSettingsA -SettingsPath (Join-Path $scratchDir "scenario-a\settings.json") -CjxlExe "fake_cjxl.exe" `
    -GetModeHandler $realGetModeA -InvokeModeHandler $fakeInvokeModeA -PostRunPromptHandler $fakePostRunA

Test-Assert (-not (Test-Path -LiteralPath $imgA.FullName)) "the real, genuinely-matching file was actually deleted by the real end-to-end chain"
Test-Assert ($invokeModeCallsA -eq 1) "the loop still reached a real mode (2) and dispatched it after Cover Deletion's own submenu returned"
Test-Assert ($postRunCallsA -eq 1) "the loop completed normally, no crash"
Write-Host ""

# ==============================================================================
#  Scenario B (2026-09-02 review fix, proven end to end): a genuinely
#  uncontained throw from inside the real chain no longer crashes
#  Invoke-MainLoop. NOTE this deliberately does NOT reuse
#  UnwantedImage.Harness.ps1's Get-FileHash-shadow trick from Scenario A's
#  sibling test in that file - THIS SAME DAY's other fix
#  (Test-UnwantedImageMatch's own try/catch around Get-FileHash) already
#  contains that exact failure internally now, so it would never reach
#  Invoke-MainLoop's own catch at all any more (proven instead by
#  UnwantedImage.Harness.ps1's own Scenario C6). To prove Invoke-MainLoop's
#  OWN containment through the real chain, this throws from the one place
#  genuinely nothing in Menu.ps1/UnwantedImage.ps1 wraps: the injected
#  -PromptFunc itself (real Read-Host essentially never throws, but
#  nothing rules it out - a closed/redirected stdin, for one). Before
#  this fix, ANY uncontained throw anywhere in this real chain - this
#  one, or the Get-FileHash one before ITS OWN fix, or a future one not
#  yet found - had nothing between it and the bootstrap's top-level
#  catch. This is the defense-in-depth layer; Scenario A above and
#  UnwantedImage.Harness.ps1's Scenario C6 together already prove the
#  specific Get-FileHash gap is closed at its source too.
# ==============================================================================
Write-Host "=== Scenario B: an uncontained throw anywhere in the real mode-5 chain doesn't crash Invoke-MainLoop ===" -ForegroundColor Cyan

$scanDirB = Join-Path $scratchDir "scenario-b\ToScan"
New-Item -ItemType Directory -Path $scanDirB -Force | Out-Null
$profilesPathB = Join-Path $scratchDir "scenario-b\profiles.json"
$script:activeProfilesPath = $profilesPathB

$fakeGetModeSettingsB = $fakeSettings.Clone()
# Throws on the THIRD prompt (the folder-path prompt inside
# Invoke-CoverDeletionRun) - '5' and '1' are answered normally so the
# throw genuinely originates deep in the real chain, not at the first
# possible call.
$promptB = New-ThrowingPromptAfter -Responses @('5', '1')
$invokeModeCallsB = 0
$fakeInvokeModeB = { param($Resolved, $TargetPath, $Settings, $CjxlExe, $MagickExe) $script:invokeModeCallsB++; return $null }
$postRunCallsB = 0
$fakePostRunB = { $script:postRunCallsB++; if ($script:postRunCallsB -ge 2) { return 'Exit' }; return 'ReturnToMenu' }
$loggedErrorsB = [System.Collections.Generic.List[string]]::new()
$fakeLogHandlerB = { param($m) $loggedErrorsB.Add($m) }.GetNewClosure()
# After the crash recovers, this second prompt drives a clean pass all
# the way through to a real mode - proving the loop didn't just survive
# the crash, but is genuinely still USABLE afterward.
$promptB2 = New-ScriptedPrompt -Responses @('2')
$callCountB = 0
$realGetModeB = {
    param($Settings, $SettingsPath)
    $script:callCountB++
    $activePrompt = if ($script:callCountB -eq 1) { $promptB } else { $promptB2 }
    Get-SelectedMode -Settings $Settings -SettingsPath $SettingsPath -PromptFunc $activePrompt
}.GetNewClosure()

$threwB = $false
try {
    Invoke-MainLoop -TargetPath $scanDirB -Settings $fakeGetModeSettingsB -SettingsPath (Join-Path $scratchDir "scenario-b\settings.json") -CjxlExe "fake_cjxl.exe" `
        -GetModeHandler $realGetModeB -InvokeModeHandler $fakeInvokeModeB -PostRunPromptHandler $fakePostRunB -LogHandler $fakeLogHandlerB
} catch {
    $threwB = $true
}

Test-Assert (-not $threwB) "Invoke-MainLoop itself did not throw - the real crash was contained, not just logged-and-rethrown"
Test-Assert ($loggedErrorsB.Count -ge 1) "the real crash was actually logged, not silently swallowed"
Test-Assert ($invokeModeCallsB -eq 1) "after recovering from the crash, the loop reached the menu again and completed a real mode (2) cleanly"
Test-Assert ($postRunCallsB -eq 2) "Show-PostRunPrompt was reached both after the crash AND after the subsequent clean run - the loop is genuinely still usable, not just alive"
Write-Host ""

# ==============================================================================
#  Scenario B (2026-09-23): menu clear/redraw through the real main loop.
#  Iteration 1 goes mode menu -> Options -> back -> invalid pick -> mode 2;
#  iteration 2 picks mode 2 straight away. Prompts, clears and the (fake)
#  run are logged into one sequence. Every menu-to-menu step clears; the
#  first menu after a run does NOT (it would wipe the run's summary).
# ==============================================================================
Write-Host "=== Scenario B: menu navigation clears, the first menu after a run doesn't ===" -ForegroundColor Cyan
$seqB = [System.Collections.Generic.List[string]]::new()
$innerPromptB = New-ScriptedPrompt -Responses @('0', '0', 'x', '2', '2')
$promptB = { param($Message) $seqB.Add("PROMPT"); & $innerPromptB $Message }.GetNewClosure()
$clearB  = { $seqB.Add("CLEAR") }.GetNewClosure()
$realGetModeB = { param($Settings, $SettingsPath) Get-SelectedMode -Settings $Settings -SettingsPath $SettingsPath -PromptFunc $promptB -ClearScreenFunc $clearB }.GetNewClosure()
$fakeInvokeModeB = { param($Resolved, $TargetPath, $Settings, $CjxlExe, $MagickExe) $seqB.Add("RUN"); return $null }.GetNewClosure()
$postRunB = @{ Calls = 0 }
$fakePostRunB = { $postRunB.Calls++; if ($postRunB.Calls -ge 2) { return 'Exit' }; return 'ReturnToMenu' }.GetNewClosure()
Invoke-MainLoop -TargetPath $scratchDir -Settings $fakeSettings.Clone() -SettingsPath (Join-Path $scratchDir "scenario-b-settings.json") -CjxlExe "fake_cjxl.exe" `
    -GetModeHandler $realGetModeB -InvokeModeHandler $fakeInvokeModeB -PostRunPromptHandler $fakePostRunB
$expectedB = "PROMPT,CLEAR,PROMPT,CLEAR,PROMPT,CLEAR,PROMPT,RUN,PROMPT,RUN"
Test-Assert (($seqB -join ",") -eq $expectedB) ("clears on Options entry, on going back, and on the invalid-pick redraw - but not on the first menu of either iteration (expected " + $expectedB + ", got " + ($seqB -join ",") + ")")
Write-Host ""

# ==============================================================================
#  Scenario C (2026-09-23): Cover Deletion's defaults through the real main
#  loop - Run scans the loop's own target folder with no folder prompt and
#  no confirmation, and the default CoverDeletionDryRun (off) really
#  deletes the match. $fakeSettings has no CoverDeletion* keys, so this also proves
#  the built-in defaults apply.
# ==============================================================================
Write-Host "=== Scenario C: Cover Deletion Run defaults - target folder, no prompts, real run ===" -ForegroundColor Cyan
$scanDirC = Join-Path $scratchDir "scenario-c\ToScan"
New-Item -ItemType Directory -Path $scanDirC -Force | Out-Null
$profilesPathC = Join-Path $scratchDir "scenario-c\profiles.json"
$imgC = New-RealImage -Path (Join-Path $scanDirC "cover.png") -Width 50 -Height 30
$hashC = (Get-FileHash -LiteralPath $imgC.FullName -Algorithm SHA256).Hash
$null = Add-UnwantedImageProfile -Profile @{ Label = "Integration Test Cover C"; Width = 50; Height = 30; SizeBytes = $imgC.Length; SizeTolerance = 0; Hash = $hashC } -ProfilesPath $profilesPathC
$script:activeProfilesPath = $profilesPathC
$promptC = New-ScriptedPrompt -Responses @('5', '1', '0', '2')
$realGetModeC = { param($Settings, $SettingsPath, $ReinitLogPathsHandler, $TargetPath) Get-SelectedMode -Settings $Settings -SettingsPath $SettingsPath -PromptFunc $promptC -TargetPath $TargetPath }.GetNewClosure()
$invokeModeC = @{ Calls = 0 }
$fakeInvokeModeC = { param($Resolved, $TargetPath, $Settings, $CjxlExe, $MagickExe) $invokeModeC.Calls++; return $null }.GetNewClosure()
$fakePostRunC = { return 'Exit' }
Invoke-MainLoop -TargetPath $scanDirC -Settings $fakeSettings.Clone() -SettingsPath (Join-Path $scratchDir "scenario-c\settings.json") -CjxlExe "fake_cjxl.exe" `
    -GetModeHandler $realGetModeC -InvokeModeHandler $fakeInvokeModeC -PostRunPromptHandler $fakePostRunC
Test-Assert (-not (Test-Path -LiteralPath $imgC.FullName)) "the matching file was deleted - the default is a real run, and the four scripted answers were enough (no folder or confirmation prompt)"
Test-Assert ($invokeModeC.Calls -eq 1) "the loop went 5 -> Run -> back -> mode 2 with no extra prompts in between (Run asked for no folder and no confirmation)"
Write-Host ""

# ==============================================================================
#  Scenario D (2026-09-23): Mode 8 is retired - through the real main loop,
#  picking 8 is an invalid selection (the menu redraws) and the next pick
#  (2) is what actually gets dispatched.
# ==============================================================================
Write-Host "=== Scenario D: retired Mode 8 is rejected by the real menu ===" -ForegroundColor Cyan
$promptD = New-ScriptedPrompt -Responses @('8', '2')
$realGetModeD = { param($Settings, $SettingsPath, $ReinitLogPathsHandler, $TargetPath) Get-SelectedMode -Settings $Settings -SettingsPath $SettingsPath -PromptFunc $promptD -TargetPath $TargetPath -ClearScreenFunc { } }.GetNewClosure()
$modesD = [System.Collections.Generic.List[string]]::new()
$fakeInvokeModeD = { param($Resolved, $TargetPath, $Settings, $CjxlExe, $MagickExe) $modesD.Add([string]$Resolved.Mode); return $null }.GetNewClosure()
Invoke-MainLoop -TargetPath $scratchDir -Settings $fakeSettings.Clone() -SettingsPath (Join-Path $scratchDir "scenario-d-settings.json") -CjxlExe "fake_cjxl.exe" `
    -GetModeHandler $realGetModeD -InvokeModeHandler $fakeInvokeModeD -PostRunPromptHandler { return 'Exit' }
Test-Assert (($modesD -join ",") -eq "ImageConversion") ("'8' was rejected and the follow-up '2' ran Image Conversion (got: " + ($modesD -join ",") + ")")
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
