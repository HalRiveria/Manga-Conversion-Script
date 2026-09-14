#Requires -Version 5.1

#Conversion Script Version 17.0 (modular rewrite)

# See Docs/module-descriptions.md for this file's full description.

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
    return @(
        "AbortPipeline.ps1"
        "AnimatedConversionPipeline.ps1"
        "ChapterDispatch.ps1"
        "CleanConsoleRendering.ps1"
        "Config.ps1"
        "Controller.ps1"
        "DependencyDetection.ps1"
        "FileDeletion.ps1"
        "ImageConversionPipeline.ps1"
        "LeafDirectoryDiscovery.ps1"
        "Logging.ps1"
        "Menu.ps1"
        "Summary.ps1"
        "UnwantedImage.ps1"
        "ZipCreation.ps1"
        "ZipParallelProcessing.ps1"
        "ZipPipeline.ps1"
        "ZipValidation.ps1"
    )
}

function Test-ModulesFolderCandidate {
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
        # A non-interactive launch (scheduled task, CI, piped/redirected
        # stdin) can't answer this prompt - Read-Host against redirected/
        # EOF stdin returns "" rather than throwing, so without this guard
        # a bad -or-missing Modules\ path spins here forever printing "No
        # path entered." (2026-09-14 fix, Todo.md finding). Same
        # [Console]::IsInputRedirected check the exit-keypress prompt
        # further down this file already uses.
        if ([Console]::IsInputRedirected) {
            throw "Could not find the Modules folder, and this session's input is redirected/non-interactive - can't prompt for a path. Pass -ModulesPathOverride explicitly instead."
        }

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
        try {
            $rawSettingsPath = Join-Path $env:LOCALAPPDATA "ConversionScript\settings.json"
            if (Test-Path -LiteralPath $rawSettingsPath) {
                $rawSettings = Get-Content -LiteralPath $rawSettingsPath -Raw | ConvertFrom-Json
                if ($rawSettings.PSObject.Properties.Name -contains 'ModulesPath') {
                    $persistedModulesPath = $rawSettings.ModulesPath
                }
            }
        } catch { }   # missing/corrupt/unreadable settings file is fine here - just means no persisted Modules path to try; Resolve-ModulesPath below still has -DefaultPath and, failing that, an interactive prompt
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
    . (Join-Path $modulesPath "ChapterDispatch.ps1")
    . (Join-Path $modulesPath "ZipParallelProcessing.ps1")
    . (Join-Path $modulesPath "ZipPipeline.ps1")
    . (Join-Path $modulesPath "ImageConversionPipeline.ps1")
    . (Join-Path $modulesPath "AnimatedConversionPipeline.ps1")
    . (Join-Path $modulesPath "Summary.ps1")
    . (Join-Path $modulesPath "UnwantedImage.ps1")
    . (Join-Path $modulesPath "Menu.ps1")
    . (Join-Path $modulesPath "Controller.ps1")

    $settingsPath = Get-ScriptSettingsPath
    $settings = Import-ScriptSettings -Path $settingsPath

    if ($settings.ModulesPath -ne $modulesPath -and $resolvedModules.Source -ne "Default") {
        $settings.ModulesPath = $modulesPath
        Export-ScriptSettings -Settings $settings -Path $settingsPath
    }

    Register-AbortHandler

    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw ("-Path '" + $Path + "' does not exist or is not a directory.")
    }
    $Path = (Resolve-Path -LiteralPath $Path).ProviderPath

    Initialize-LogPaths -TargetPath $Path -FullLogging ([bool]$settings.FullLogging) -DisableSummaryFile ([bool]$settings.DisableSummaryFile) -ScriptDir $scriptDir
    Initialize-LogMutex
    Initialize-CleanConsoleOutput -Enabled ([bool]$settings.CleanConsoleOutputEnabled)
    Initialize-FileDeletion -PermanentDelete ([bool]$settings.PermanentDelete)

    $magickGlobCandidates = @(Get-ChildItem -Path (Join-Path $env:ProgramFiles "ImageMagick-*\magick.exe") -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

    $resolvedCjxlPath = Find-ExeCached -Settings $settings -SettingsKey "CjxlPath" -UserPath $CjxlPath -ExeName "cjxl" -Candidates @(
        "C:\Program Files\libjxl\cjxl.exe",
        "C:\libjxl\cjxl.exe",
        (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\cjxl.exe")
    )
    if ([string]::IsNullOrWhiteSpace($resolvedCjxlPath)) {
        throw "cjxl.exe could not be found. Install libjxl, add it to PATH, or pass -CjxlPath."
    }
    $resolvedMagickPath = Find-ExeCached -Settings $settings -SettingsKey "MagickPath" -UserPath $MagickPath -ExeName "magick" -Candidates ($magickGlobCandidates + @(
        "C:\Program Files\ImageMagick-7.1.1-Q16-HDRI\magick.exe",
        "C:\Program Files\ImageMagick-7.1.1-Q16\magick.exe"
    ))
    Export-ScriptSettings -Settings $settings -Path $settingsPath

    Write-Log ("Conversion Script starting. Path: '" + $Path + "'. cjxl: '" + $resolvedCjxlPath + "'. magick: '" + $(if ($resolvedMagickPath) { $resolvedMagickPath } else { "(not found - WebP/AVIF/BMP/HEIC/HEIF input will fail)" }) + "'.")

    # ==========================================================================
    #  MAIN LOOP - lives in Controller.ps1's Invoke-MainLoop
    # ==========================================================================

    Invoke-MainLoop -TargetPath $Path -Settings $settings -SettingsPath $settingsPath -CjxlExe $resolvedCjxlPath -MagickExe $resolvedMagickPath -ScriptDir $scriptDir `
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
        Write-Host ("`r`nFATAL ERROR: " + $_.ToString() + "`r`nStack Trace:`r`n" + $_.ScriptStackTrace) -ForegroundColor Red
    }

    if (-not $wasOwnAbort) {
        Write-Host ""
        Write-Host "The script has stopped due to the error above." -ForegroundColor Red
        if (-not [Console]::IsInputRedirected) {
            Write-Host "Press any key to exit..." -ForegroundColor Red
            try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { }   # some hosts (ISE, certain terminals) don't support ReadKey - fine to just fall through to exit below
        }
        exit 1
    }
}
