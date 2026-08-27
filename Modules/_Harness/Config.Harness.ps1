<#
.SYNOPSIS
    Standalone test harness for Modules\Config.ps1.

.DESCRIPTION
    Dot-sources the real module and exercises it against real files in a
    scratch directory (never the real %LOCALAPPDATA% - every call passes
    an explicit -Path/-BaseDir into the scratch dir). Stubs Write-Log with
    call tracking, same pattern as AbortPipeline.Harness.ps1, so scenarios
    can assert a warning actually fired without needing the real Logging
    module built first.

.EXAMPLE
    .\Modules\_Harness\Config.Harness.ps1
#>

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\Config.ps1")

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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("config-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray
Write-Host ""

# ==============================================================================
#  Scenario A: Get-DefaultScriptSettings returns a fresh, independent copy
# ==============================================================================
Write-Host "=== Scenario A: Get-DefaultScriptSettings returns an independent copy each call ===" -ForegroundColor Cyan
$defA1 = Get-DefaultScriptSettings
$defA2 = Get-DefaultScriptSettings
$defA1.JpegQuality = 12345
Test-Assert ($defA2.JpegQuality -eq 90) "mutating one returned hashtable does not affect a second call's result"
Test-Assert ($defA2.ContainsKey('ZipParallelThreads') -and $defA2.ContainsKey('DeleteExtractedFoldersAfterRezip')) "schema includes ZipParallelThreads and DeleteExtractedFoldersAfterRezip"
Write-Host ""

# ==============================================================================
#  Scenario B: Get-ScriptSettingsPath default and -BaseDir override
# ==============================================================================
Write-Host "=== Scenario B: Get-ScriptSettingsPath ===" -ForegroundColor Cyan
$pathB = Get-ScriptSettingsPath -BaseDir $scratchDir
Test-Assert ($pathB -eq (Join-Path $scratchDir "ConversionScript\settings.json")) "BaseDir override builds the expected path"
Write-Host ""

# ==============================================================================
#  Scenario C: Import-ScriptSettings with no file present returns defaults
# ==============================================================================
Write-Host "=== Scenario C: Import-ScriptSettings, missing file -> defaults ===" -ForegroundColor Cyan
$missingPath = Join-Path $scratchDir "missing\settings.json"
$settingsC = Import-ScriptSettings -Path $missingPath
$defC = Get-DefaultScriptSettings
$mismatchC = @($defC.Keys | Where-Object { $settingsC[$_] -ne $defC[$_] })
Test-Assert ($mismatchC.Count -eq 0) "missing settings file yields all-default values"
Write-Host ""

# ==============================================================================
#  Scenario D: Export then Import round-trips real (non-default) values
# ==============================================================================
Write-Host "=== Scenario D: Export-ScriptSettings then Import-ScriptSettings round-trips ===" -ForegroundColor Cyan
$pathD = Join-Path $scratchDir "roundtrip\settings.json"
$toSaveD = Get-DefaultScriptSettings
$toSaveD.ZipParallelThreads = 4
$toSaveD.JpegQuality = 77
$toSaveD.PermanentDelete = $true
$toSaveD.CjxlPath = "C:\Tools\cjxl.exe"
Export-ScriptSettings -Settings $toSaveD -Path $pathD
Test-Assert (Test-Path -LiteralPath $pathD) "Export-ScriptSettings created the file (and its parent directory)"
$loadedD = Import-ScriptSettings -Path $pathD
Test-Assert ($loadedD.ZipParallelThreads -eq 4) "ZipParallelThreads round-tripped"
Test-Assert ($loadedD.JpegQuality -eq 77) "JpegQuality round-tripped"
Test-Assert ($loadedD.PermanentDelete -eq $true) "PermanentDelete (bool) round-tripped"
Test-Assert ($loadedD.CjxlPath -eq "C:\Tools\cjxl.exe") "CjxlPath (string) round-tripped"
Write-Host ""

# ==============================================================================
#  Scenario E: a settings file from an older/smaller schema still comes
#  back with every current key (missing keys filled from defaults)
# ==============================================================================
Write-Host "=== Scenario E: partial/older-schema file merges onto defaults ===" -ForegroundColor Cyan
$pathE = Join-Path $scratchDir "partial-settings.json"
'{ "JpegQuality": 55 }' | Set-Content -LiteralPath $pathE -Encoding UTF8
$settingsE = Import-ScriptSettings -Path $pathE
Test-Assert ($settingsE.JpegQuality -eq 55) "the one present key was loaded"
Test-Assert ($settingsE.MaxCjxlProcs -eq 8) "a key absent from the file fell back to its default"
Test-Assert ($settingsE.ContainsKey('ModulesPath')) "the merged result still contains every schema key"
Write-Host ""

# ==============================================================================
#  Scenario F: corrupt (unparsable) JSON falls back to defaults, backs up
#  the bad file, and warns via Write-Log - does not throw
# ==============================================================================
Write-Host "=== Scenario F: corrupt JSON -> defaults + backup + Write-Log Warn, no throw ===" -ForegroundColor Cyan
$pathF = Join-Path $scratchDir "corrupt-settings.json"
"{ this is not valid json " | Set-Content -LiteralPath $pathF -Encoding UTF8
$script:logCalls.Clear()
$threwF = $false
$settingsF = $null
try { $settingsF = Import-ScriptSettings -Path $pathF } catch { $threwF = $true }
Test-Assert (-not $threwF) "Import-ScriptSettings does not throw on corrupt JSON"
Test-Assert ($settingsF.JpegQuality -eq 90) "corrupt file yields default values"
$backupsF = @(Get-ChildItem -LiteralPath (Split-Path $pathF -Parent) -Filter "corrupt-settings.json.corrupt-*.bak")
Test-Assert ($backupsF.Count -eq 1) "the corrupt file was preserved as a .bak rather than silently discarded"
Test-Assert (@($script:logCalls | Where-Object { $_ -like "Warn:*" }).Count -ge 1) "a Warn-level Write-Log call fired for the corrupt file"
Write-Host ""

# ==============================================================================
#  Scenario G: an unknown key in the file is ignored (not merged in), with
#  a warning, rather than polluting the returned settings or crashing
# ==============================================================================
Write-Host "=== Scenario G: unknown key in file is dropped with a warning ===" -ForegroundColor Cyan
$pathG = Join-Path $scratchDir "unknown-key-settings.json"
'{ "JpegQuality": 60, "SomeFutureSettingNotYetInvented": true }' | Set-Content -LiteralPath $pathG -Encoding UTF8
$script:logCalls.Clear()
$settingsG = Import-ScriptSettings -Path $pathG
Test-Assert (-not $settingsG.ContainsKey('SomeFutureSettingNotYetInvented')) "unknown key was not merged into the returned settings"
Test-Assert ($settingsG.JpegQuality -eq 60) "the known key alongside it still loaded correctly"
Test-Assert (@($script:logCalls | Where-Object { $_ -like "Warn:*unknown*" }).Count -ge 1) "a Warn-level Write-Log call named the unknown key"
Write-Host ""

# ==============================================================================
#  Scenario H: a bad value for a known key (wrong type, or out of range)
#  falls back to that key's default individually - the rest of the file
#  still loads normally
# ==============================================================================
Write-Host "=== Scenario H: invalid value for a known key falls back to its own default ===" -ForegroundColor Cyan
$pathH = Join-Path $scratchDir "bad-value-settings.json"
'{ "JpegQuality": 999, "ZipParallelThreads": "not-a-number", "PermanentDelete": "yes", "CjxlPath": "C:\\ok.exe" }' | Set-Content -LiteralPath $pathH -Encoding UTF8
$script:logCalls.Clear()
$settingsH = Import-ScriptSettings -Path $pathH
Test-Assert ($settingsH.JpegQuality -eq 90) "out-of-range JpegQuality (999) fell back to default (90)"
Test-Assert ($settingsH.ZipParallelThreads -eq 1) "wrong-type ZipParallelThreads fell back to default (1)"
Test-Assert ($settingsH.PermanentDelete -eq $false) "wrong-type PermanentDelete fell back to default (`$false)"
Test-Assert ($settingsH.CjxlPath -eq "C:\ok.exe") "a valid sibling key (CjxlPath) still loaded despite the other bad values"
Test-Assert (@($script:logCalls | Where-Object { $_ -like "Warn:*" }).Count -eq 3) "exactly one warning per invalid key (3 bad keys -> 3 warnings)"
Write-Host ""

# ==============================================================================
#  Scenario I: Export-ScriptSettings defaults -Path to Get-ScriptSettingsPath
#  when omitted (verified via -BaseDir env override, not the real AppData)
# ==============================================================================
Write-Host "=== Scenario I: -Path defaults to Get-ScriptSettingsPath ===" -ForegroundColor Cyan
$fakeLocalAppData = Join-Path $scratchDir "fake-appdata"
New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
$origLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $fakeLocalAppData
try {
    $expectedPathI = Get-ScriptSettingsPath
    Export-ScriptSettings -Settings (Get-DefaultScriptSettings)
    Test-Assert (Test-Path -LiteralPath $expectedPathI) "Export-ScriptSettings with no -Path wrote to Get-ScriptSettingsPath's default location"
    $settingsI = Import-ScriptSettings
    Test-Assert ($settingsI.JpegQuality -eq 90) "Import-ScriptSettings with no -Path read it back correctly"
} finally {
    $env:LOCALAPPDATA = $origLocalAppData
}
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
