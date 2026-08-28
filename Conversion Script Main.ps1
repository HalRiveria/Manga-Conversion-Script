#Requires -Version 5.1

#Conversion Script Version 17.0 (modular rewrite)

<#
.SYNOPSIS
    Bootstrap entry point for the modularized conversion script. Resolves
    Modules\, loads persisted settings, dot-sources all 19 modules, then
    runs the interactive mode menu in a loop until the user exits.

.DESCRIPTION
    This is a REWRITE, not the original monolithic script - see
    Modules\_Reference\Conversion Script Main - Old.ps1 for that (now the
    frozen reference copy; the guard's freeze protection moved to it, see
    Docs/repo-guard.md). All real conversion/zip/deletion/logging logic
    now lives in Modules\ - built and harness-tested independently first,
    per this repo's own development process (see CLAUDE.md). This file's
    only job is bootstrap (find Modules\, load settings, dot-source
    everything) and the top-level dispatch loop.

    MODULE-FINDING LOGIC IS INLINED, NOT DOT-SOURCED (2026-08-28): the
    three functions right below (Get-ExpectedModuleFileNames,
    Test-ModulesFolderCandidate, Resolve-ModulesPath) are a direct copy
    of ModuleLoading.ps1's own functions. Dot-sourcing that file instead
    was tried first and rejected - it would still leave this script
    unable to find Modules\ without ALSO already knowing where
    ModuleLoading.ps1 itself is, which doesn't actually solve the
    bootstrap problem, just moves it one file sideways. ModuleLoading.ps1
    stays in the repo as a standalone, separately harness-tested copy of
    this same logic (project owner's explicit call) - if this logic ever
    needs to change, update BOTH copies; Modules\_Harness\ModuleLoading.Harness.ps1
    is what proves the logic itself is correct, this file just carries a
    copy of it.

    DISPATCH (2026-08-28, Phase 3 of the build plan): the main loop below
    calls Controller.ps1's real Invoke-Mode - the Phase 1/2 work that
    used to be stubbed inline in this file (per-mode param translation,
    output normalization onto Summary.ps1's $stats shape, the shared
    abort/fatal-error catch) now lives there for real, proven standalone
    by Controller.Harness.ps1 before ever being wired in here. The ONE
    piece still NOT moved into Controller.ps1: Show-PostRunPrompt's run
    loop (the `while ($true) { ... }` below) - that's bigger, separate,
    unscoped work (see Todo.md's Open Decisions), so this file still owns
    the literal loop, just delegates each iteration's real work to
    Invoke-Mode instead of doing it inline.

.PARAMETER Path
    Root directory to operate in. Defaults to the current working
    directory.
.PARAMETER CjxlPath
    Optional explicit path to cjxl.exe if not found automatically.
.PARAMETER MagickPath
    Optional explicit path to magick.exe if not found automatically.
    Required only for WebP/AVIF input.
.PARAMETER ModulesPathOverride
    Optional explicit path to the Modules\ folder, bypassing the default
    script-relative location and any persisted path.
#>

param(
    [string]$Path,
    [string]$CjxlPath,
    [string]$MagickPath,
    [string]$ModulesPathOverride
)

$ErrorActionPreference = 'Stop'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# ==============================================================================
#  MODULE-FINDING LOGIC - inlined copy of ModuleLoading.ps1, see header above
# ==============================================================================

function Get-ExpectedModuleFileNames {
    <#
    .SYNOPSIS
        The real, current list of every module file Modules\ is expected
        to contain. Update by hand whenever a real module is added or
        removed - kept in sync with ModuleLoading.ps1's own copy and its
        drift-checking harness scenario.
    #>
    return @(
        "AbortPipeline.ps1"
        "AnimatedConversionPipeline.ps1"
        "CleanConsoleRendering.ps1"
        "Config.ps1"
        "Controller.ps1"
        "DependencyDetection.ps1"
        "FileDeletion.ps1"
        "ImageConversionPipeline.ps1"
        "LeafDirectoryDiscovery.ps1"
        "Logging.ps1"
        "Menu.ps1"
        "ResumeState.ps1"
        "RezipPipeline.ps1"
        "Summary.ps1"
        "UnwantedImage.ps1"
        "ZipCreation.ps1"
        "ZipParallelProcessing.ps1"
        "ZipPipeline.ps1"
        "ZipValidation.ps1"
    )
}

function Test-ModulesFolderCandidate {
    <#
    .SYNOPSIS
        True only if $CandidatePath exists as a real directory AND
        contains every file Get-ExpectedModuleFileNames lists.
    .OUTPUTS
        @{ IsValid = <bool>; MissingFiles = <string[]> }
    #>
    param([Parameter(Mandatory)][string]$CandidatePath)

    $expected = Get-ExpectedModuleFileNames
    if (-not (Test-Path -LiteralPath $CandidatePath -PathType Container)) {
        return @{ IsValid = $false; MissingFiles = $expected }
    }

    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($fileName in $expected) {
        if (-not (Test-Path -LiteralPath (Join-Path $CandidatePath $fileName) -PathType Leaf)) {
            $missing.Add($fileName)
        }
    }
    return @{ IsValid = ($missing.Count -eq 0); MissingFiles = $missing.ToArray() }
}

function Resolve-ModulesPath {
    <#
    .SYNOPSIS
        Finds a real, validated Modules\ folder: tries -DefaultPath
        first, then -PersistedPath, then prompts INDEFINITELY via
        -PromptFunc until a valid path is given.
    .OUTPUTS
        @{ Path = <string>; Source = "Default"|"Persisted"|"Prompted" }
    #>
    param(
        [Parameter(Mandatory)]
        [string]$DefaultPath,
        [string]$PersistedPath = $null,
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message }
    )

    $defaultCheck = Test-ModulesFolderCandidate -CandidatePath $DefaultPath
    if ($defaultCheck.IsValid) { return @{ Path = $DefaultPath; Source = "Default" } }

    if (-not [string]::IsNullOrWhiteSpace($PersistedPath)) {
        $persistedCheck = Test-ModulesFolderCandidate -CandidatePath $PersistedPath
        if ($persistedCheck.IsValid) { return @{ Path = $PersistedPath; Source = "Persisted" } }
    }

    while ($true) {
        $entered = (& $PromptFunc "Could not find the Modules folder. Enter its full path (drag & drop the folder in, or paste the path)")
        if ($null -ne $entered) { $entered = $entered.Trim().Trim('"') }
        if ([string]::IsNullOrWhiteSpace($entered)) {
            Write-Host "No path entered." -ForegroundColor Yellow
            continue
        }

        $check = Test-ModulesFolderCandidate -CandidatePath $entered
        if ($check.IsValid) { return @{ Path = $entered; Source = "Prompted" } }

        Write-Host ("That folder doesn't have everything expected - missing: " + ($check.MissingFiles -join ", ")) -ForegroundColor Yellow
    }
}

# ==============================================================================
#  BOOTSTRAP - resolve Modules\, load settings, dot-source everything
# ==============================================================================

$defaultModulesPath = Join-Path $scriptDir "Modules"
$persistedModulesPath = $null

if (-not [string]::IsNullOrWhiteSpace($ModulesPathOverride)) {
    $modulesCheck = Test-ModulesFolderCandidate -CandidatePath $ModulesPathOverride
    if (-not $modulesCheck.IsValid) {
        throw ("-ModulesPathOverride '" + $ModulesPathOverride + "' is missing: " + ($modulesCheck.MissingFiles -join ", "))
    }
    $resolvedModules = @{ Path = $ModulesPathOverride; Source = "Override" }
} else {
    # Config.ps1 itself lives inside Modules\, so its ModulesPath setting
    # can't be read until Modules\ is already found - only useful as a
    # fallback once a previous run persisted a non-default location, read
    # here by hand rather than via Config.ps1.
    try {
        $rawSettingsPath = Join-Path $env:LOCALAPPDATA "ConversionScript\settings.json"
        if (Test-Path -LiteralPath $rawSettingsPath) {
            $rawSettings = Get-Content -LiteralPath $rawSettingsPath -Raw | ConvertFrom-Json
            if ($rawSettings.PSObject.Properties.Name -contains 'ModulesPath') {
                $persistedModulesPath = $rawSettings.ModulesPath
            }
        }
    } catch {
        # Corrupt/missing settings file - Config.ps1's own Import-ScriptSettings
        # handles this properly once dot-sourced; here it just means no
        # persisted fallback is available, same as never having persisted one.
    }
    $resolvedModules = Resolve-ModulesPath -DefaultPath $defaultModulesPath -PersistedPath $persistedModulesPath
}

$modulesPath = $resolvedModules.Path

# Config.ps1 first - settings drive how everything else below initializes.
. (Join-Path $modulesPath "Config.ps1")
. (Join-Path $modulesPath "Logging.ps1")
. (Join-Path $modulesPath "FileDeletion.ps1")
. (Join-Path $modulesPath "AbortPipeline.ps1")
. (Join-Path $modulesPath "DependencyDetection.ps1")
. (Join-Path $modulesPath "ZipCreation.ps1")
. (Join-Path $modulesPath "ZipValidation.ps1")
. (Join-Path $modulesPath "CleanConsoleRendering.ps1")
. (Join-Path $modulesPath "LeafDirectoryDiscovery.ps1")
. (Join-Path $modulesPath "ZipParallelProcessing.ps1")
. (Join-Path $modulesPath "ZipPipeline.ps1")
. (Join-Path $modulesPath "ImageConversionPipeline.ps1")
. (Join-Path $modulesPath "AnimatedConversionPipeline.ps1")
. (Join-Path $modulesPath "ResumeState.ps1")
. (Join-Path $modulesPath "RezipPipeline.ps1")
. (Join-Path $modulesPath "Summary.ps1")
. (Join-Path $modulesPath "UnwantedImage.ps1")
. (Join-Path $modulesPath "Menu.ps1")
. (Join-Path $modulesPath "Controller.ps1")

$settingsPath = Get-ScriptSettingsPath
$settings = Import-ScriptSettings -Path $settingsPath

if ($settings.ModulesPath -ne $modulesPath -and $resolvedModules.Source -ne "Default") {
    # Only re-persist when the resolved path differs from what's already
    # saved AND it isn't just the plain default location - matches
    # Resolve-ModulesPath's own "Source tells the caller whether the
    # result needs (re)persisting" contract.
    $settings.ModulesPath = $modulesPath
    Export-ScriptSettings -Settings $settings -Path $settingsPath
}

Register-AbortHandler

if ([string]::IsNullOrWhiteSpace($Path)) { $Path = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw ("-Path '" + $Path + "' does not exist or is not a directory.")
}

Initialize-LogPaths -TargetPath $Path -FullLogging $settings.FullLogging -DisableSummaryFile $settings.DisableSummaryFile -ScriptDir $scriptDir
Initialize-LogMutex
Initialize-CleanConsoleOutput -Enabled $settings.CleanConsoleOutputEnabled
Initialize-FileDeletion -PermanentDelete $settings.PermanentDelete

$resolvedCjxlPath = Find-ExeCached -Settings $settings -SettingsKey "CjxlPath" -UserPath $CjxlPath -ExeName "cjxl" -Candidates @(
    "C:\Program Files\libjxl\cjxl.exe",
    "C:\libjxl\cjxl.exe"
)
if ([string]::IsNullOrWhiteSpace($resolvedCjxlPath)) {
    throw "cjxl.exe could not be found. Install libjxl, add it to PATH, or pass -CjxlPath."
}
$resolvedMagickPath = Find-ExeCached -Settings $settings -SettingsKey "MagickPath" -UserPath $MagickPath -ExeName "magick" -Candidates @(
    "C:\Program Files\ImageMagick-7.1.1-Q16-HDRI\magick.exe",
    "C:\Program Files\ImageMagick-7.1.1-Q16\magick.exe"
)
Export-ScriptSettings -Settings $settings -Path $settingsPath

Write-Log ("Conversion Script starting. Path: '" + $Path + "'. cjxl: '" + $resolvedCjxlPath + "'. magick: '" + $(if ($resolvedMagickPath) { $resolvedMagickPath } else { "(not found - WebP/AVIF input will fail)" }) + "'.")

# ==============================================================================
#  MAIN LOOP - Show-PostRunPrompt's loop is the one piece that stays here
#  rather than moving into Controller.ps1 (see header above); each
#  iteration's real work is entirely Controller.ps1's Invoke-Mode now.
# ==============================================================================

while ($true) {
    $resolved = Get-SelectedMode -Settings $settings -SettingsPath $settingsPath

    $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $stats = Invoke-Mode -Resolved $resolved -TargetPath $Path -Settings $settings -CjxlExe $resolvedCjxlPath -MagickExe $resolvedMagickPath `
        -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile
    $runStopwatch.Stop()

    if ($null -eq $stats) {
        # Invoke-Mode's own shared catch already logged the real cause
        # (Invoke-AbortOrFatalHandler - either a genuine crash or the
        # rare abort-exception race) - a $null return here means the run
        # did NOT complete, so there is no real $stats to report. Skip
        # the summary rather than printing a misleading all-zeros report.
        Write-Log "Run did not complete - see the error above." -Level Warn
    } else {
        $elapsedString = Format-ElapsedTime -Elapsed $runStopwatch.Elapsed
        $summaryLines = Get-SummaryLines -Stats $stats -ElapsedString $elapsedString -ModeFlags $resolved
        Write-SummaryReport -Lines $summaryLines -FullLogging $settings.FullLogging
    }

    $postRun = Show-PostRunPrompt
    if ($postRun -eq 'Exit') { break }
    Write-Host ""
}
