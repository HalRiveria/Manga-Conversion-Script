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

    MODULE-FINDING LOGIC IS INLINED, NOT DOT-SOURCED: the three functions
    right below (Get-ExpectedModuleFileNames, Test-ModulesFolderCandidate,
    Resolve-ModulesPath) can't live in Modules\ - dot-sourcing anything
    from there requires already knowing where Modules\ is, which is
    exactly the problem this logic solves. They used to also exist as a
    standalone, separately harness-tested copy (ModuleLoading.ps1, repo
    root) built to prove the logic before this rewrite existed to call
    it - removed once a review confirmed the logic had no open issues and
    this inlined copy had already been proven via real runs. See
    CLAUDE.md's "Module loading & settings persistence" section.

    DISPATCH AND MAIN LOOP (2026-08-28, Phases 3 and the following
    session): this file now just calls Controller.ps1's Invoke-MainLoop.
    Everything that used to be stubbed or inlined here - per-mode param
    translation, output normalization onto Summary.ps1's $stats shape,
    the shared abort/fatal-error catch (Invoke-Mode, Phase 3), AND the
    run loop itself including Show-PostRunPrompt (Invoke-MainLoop, built
    right after) - now lives in Controller.ps1, proven standalone by
    Controller.Harness.ps1 before ever being wired in here. This file's
    job really is just bootstrap now: find Modules\, load settings,
    dot-source everything, resolve dependencies, hand off.

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
        removed.
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

# TOP-LEVEL TRY/CATCH (2026-08-28, real bug fix - see Todo.md/CHANGELOG.md):
# this whole body used to have no catch at all - a throw anywhere in here
# (a bad -ModulesPathOverride, a missing cjxl.exe, a malformed -CjxlPath,
# any real module dot-source failure) surfaced as a raw PowerShell
# exception dump instead of a clean message, and could close the window
# before anyone read it if the script was launched by double-click rather
# than from an already-open terminal. Routes through AbortPipeline.ps1's
# own Invoke-AbortOrFatalHandler once it's dot-sourced (same
# crash-vs-own-abort disambiguation, and the same fatal-message shape,
# every real pipeline run already gets via Invoke-Mode's own catch) - but
# a failure can happen before Logging.ps1/AbortPipeline.ps1 even exist yet
# (module-finding itself, or the first few dot-source lines), so this
# falls back to a plain Write-Host when those functions aren't defined.
try {
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

    # ==========================================================================
    #  MAIN LOOP - moved into Controller.ps1's Invoke-MainLoop (2026-08-28) -
    #  this file's job is now purely bootstrap; the run loop itself, including
    #  Show-PostRunPrompt, lives in Controller.ps1.
    # ==========================================================================

    Invoke-MainLoop -TargetPath $Path -Settings $settings -SettingsPath $settingsPath -CjxlExe $resolvedCjxlPath -MagickExe $resolvedMagickPath `
        -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile
} catch {
    $wasOwnAbort = $false
    if (Get-Command Invoke-AbortOrFatalHandler -ErrorAction SilentlyContinue) {
        $logHandler = if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            { param($m) Write-Log $m -Level Error }
        } else {
            { param($m) Write-Host ("`r`n" + $m) -ForegroundColor Red }
        }
        $wasOwnAbort = Invoke-AbortOrFatalHandler -ErrorRecord $_ -LogHandler $logHandler
    } else {
        # AbortPipeline.ps1 isn't dot-sourced yet - the failure happened
        # during module-finding itself, or in the first few dot-source
        # lines. No richer handling available this early; still a clean
        # message, not a raw exception dump.
        Write-Host ("`r`nFATAL ERROR: " + $_.ToString() + "`r`nStack Trace:`r`n" + $_.ScriptStackTrace) -ForegroundColor Red
    }

    if (-not $wasOwnAbort) {
        # A genuine crash, not our own graceful abort completing early -
        # pause so the message is actually readable even when this script
        # was launched by double-click (a bare window close would
        # otherwise happen instantly). [Console]::IsInputRedirected is
        # checked FIRST and the pause skipped entirely when it's true -
        # verified live that $Host.UI.RawUI.ReadKey does NOT throw or
        # return immediately when stdin is redirected (a scheduled task, a
        # piped/non-interactive invocation), it just blocks forever, so
        # wrapping it in try/catch alone is not enough to keep this path
        # safe for non-interactive callers. The try/catch around ReadKey
        # stays too, as a second layer, for whatever other reason it might
        # fail in a real interactive console.
        Write-Host ""
        Write-Host "The script has stopped due to the error above." -ForegroundColor Red
        if (-not [Console]::IsInputRedirected) {
            Write-Host "Press any key to exit..." -ForegroundColor Red
            try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { }
        }
        exit 1
    }
}
