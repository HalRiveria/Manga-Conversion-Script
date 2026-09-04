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
Test-Assert (
    $defA2.ContainsKey('AnimatedThreads') -and $defA2.ContainsKey('AnimatedQuality') -and
    $defA2.ContainsKey('AnimatedLossless') -and $defA2.ContainsKey('AnimatedOverwrite') -and
    $defA2.ContainsKey('AnimatedDeleteSource')
) "schema includes all five Animated* keys"
Test-Assert ($defA2.ContainsKey('ZipWithUnconvertedAnimated') -and $defA2.ZipWithUnconvertedAnimated -eq $false) "schema includes ZipWithUnconvertedAnimated, default `$false"
# 2026-09-03 addition, real bug fix (see CHANGELOG.md) - dedicated Full
# Pipeline shared-budget setting, defaults to match MaxCjxlProcs (8) so
# upgrading doesn't silently change real concurrency.
Test-Assert ($defA2.ContainsKey('FullPipelineMaxConcurrentProcs') -and $defA2.FullPipelineMaxConcurrentProcs -eq 8) "schema includes FullPipelineMaxConcurrentProcs, default 8 (matches MaxCjxlProcs)"
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
#  Scenario E2 (2026-08-31 fix, caught by a same-day /code-review
#  full-codebase pass): a hand-edited whole-number-with-decimal-point
#  value ("JpegQuality": 75.0) must be ACCEPTED, not silently reverted to
#  the default. ConvertFrom-Json on this real PS 5.1/.NET Framework
#  install yields [decimal] for such a value, not [double] - confirmed
#  live, not assumed - so Test-ScriptSettingValue's own [double]-only
#  integral check was dead code against real output from this project's
#  own real Import-ScriptSettings path.
# ==============================================================================
Write-Host "=== Scenario E2: a whole-number JSON value written with a decimal point (75.0) is accepted, not reverted ===" -ForegroundColor Cyan
$pathE2 = Join-Path $scratchDir "decimal-settings.json"
'{ "JpegQuality": 75.0 }' | Set-Content -LiteralPath $pathE2 -Encoding UTF8
$settingsE2 = Import-ScriptSettings -Path $pathE2
Test-Assert ($settingsE2.JpegQuality -eq 75) ("the decimal-point whole number was accepted as-is, not reverted to the default (got " + $settingsE2.JpegQuality + ")")
# [int] normalization (2026-08-31 fix, caught by verifying a same-day
# /code-review pass): storing the accepted value as-is left it a
# [decimal] - functionally harmless (every real consumer binds it to an
# [int] parameter) but cosmetically wrong (the options menu would show
# "Quality [75.0]", and Export-ScriptSettings would write "75.0" back
# out, both looking like a live bug even though nothing downstream
# actually broke).
Test-Assert ($settingsE2.JpegQuality -is [int]) ("the accepted value was normalized to [int], not left as the raw [decimal] ConvertFrom-Json produced (got type " + $settingsE2.JpegQuality.GetType().Name + ")")
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

# 2026-09-03 fix, Todo.md finding: the corrupt file used to be backed up
# but never repaired, so it re-warned and dropped a new .bak on every
# single future launch. It should now be REPAIRED with the defaults - a
# second Import-ScriptSettings call against the SAME path must load
# cleanly, with no new backup and no new Warn.
$threwF3 = $false
$settingsF3 = $null
$script:logCalls.Clear()
try { $settingsF3 = Import-ScriptSettings -Path $pathF } catch { $threwF3 = $true }
Test-Assert (-not $threwF3) "a second Import-ScriptSettings call against the now-repaired file does not throw"
Test-Assert ($null -ne $settingsF3 -and $settingsF3.JpegQuality -eq 90) "the repaired file still loads to defaults"
$backupsF3 = @(Get-ChildItem -LiteralPath (Split-Path $pathF -Parent) -Filter "corrupt-settings.json.corrupt-*.bak")
Test-Assert ($backupsF3.Count -eq 1) "no SECOND backup was created - the file is actually repaired now, not still corrupt"
Test-Assert (@($script:logCalls | Where-Object { $_ -like "Warn:*" }).Count -eq 0) "no Warn was logged on the repaired file - it's genuinely valid now"
Write-Host ""

# ==============================================================================
#  Scenario F2 (2026-08-31 fix): a settings file whose content is valid JSON
#  but not a real settings OBJECT - the literal `null` (a realistic outcome
#  of a truncated write, since Export-ScriptSettings's Set-Content isn't
#  atomic) or a JSON array. ConvertFrom-Json doesn't throw on either, so
#  the try/catch above never catches them - a prior version let $null
#  reach ConvertTo-SettingsHashtable's [Parameter(Mandatory)] InputObject,
#  throwing a ParameterBindingValidationException that escaped this
#  function's own "never throws" contract entirely.
# ==============================================================================
Write-Host "=== Scenario F2: JSON `$null`/array (parses fine, not a settings object) -> defaults, no throw ===" -ForegroundColor Cyan
$pathF2Null = Join-Path $scratchDir "null-settings.json"
"null" | Set-Content -LiteralPath $pathF2Null -Encoding UTF8
$script:logCalls.Clear()
$threwF2Null = $false
$settingsF2Null = $null
try { $settingsF2Null = Import-ScriptSettings -Path $pathF2Null } catch { $threwF2Null = $true }
Test-Assert (-not $threwF2Null) "Import-ScriptSettings does not throw on a JSON `null` settings file"
Test-Assert ($null -ne $settingsF2Null -and $settingsF2Null.JpegQuality -eq 90) "a JSON `null` file yields default values"
$backupsF2Null = @(Get-ChildItem -LiteralPath (Split-Path $pathF2Null -Parent) -Filter "null-settings.json.corrupt-*.bak")
Test-Assert ($backupsF2Null.Count -eq 1) "the null-content file was preserved as a .bak rather than silently discarded"

$pathF2Array = Join-Path $scratchDir "array-settings.json"
'["not", "an", "object"]' | Set-Content -LiteralPath $pathF2Array -Encoding UTF8
$script:logCalls.Clear()
$threwF2Array = $false
$settingsF2Array = $null
try { $settingsF2Array = Import-ScriptSettings -Path $pathF2Array } catch { $threwF2Array = $true }
Test-Assert (-not $threwF2Array) "Import-ScriptSettings does not throw on a JSON array settings file"
Test-Assert ($null -ne $settingsF2Array -and $settingsF2Array.JpegQuality -eq 90) "a JSON array file yields default values"
Test-Assert (@($script:logCalls | Where-Object { $_ -like "Warn:*Ignoring unknown setting*" }).Count -eq 0) "a JSON array does NOT spray one bogus 'unknown setting' warning per CLR array property"
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
#  Scenario H2 (2026-08-31 fix, caught by verifying a same-day
#  /code-review pass): a value outside Int32's range is integral (passes
#  the earlier double/decimal-truncation check) but throws OverflowException
#  on the `[int]$Value` cast - unguarded, that exception escaped
#  Import-ScriptSettings entirely (no try/catch there either), violating
#  its own documented "never throws" contract by killing the WHOLE
#  settings load instead of just this one key falling back to its
#  default. Two shapes tested: a real [long] (99999999999, an integral
#  JSON number too large for [int] but exactly representable, so
#  ConvertFrom-Json itself returns [long]) and a [decimal] with the same
#  numeric value (matches the exact repro used to find this).
# ==============================================================================
Write-Host "=== Scenario H2: an Int32-range-overflowing value falls back to default instead of throwing ===" -ForegroundColor Cyan
$pathH2 = Join-Path $scratchDir "overflow-settings.json"
'{ "MaxCjxlProcs": 99999999999, "AnimatedThreads": 99999999999.0 }' | Set-Content -LiteralPath $pathH2 -Encoding UTF8
$threwH2 = $false
$settingsH2 = $null
try {
    $settingsH2 = Import-ScriptSettings -Path $pathH2
} catch {
    $threwH2 = $true
}
Test-Assert (-not $threwH2) "Import-ScriptSettings did not throw on an Int32-range-overflowing value"
Test-Assert ($null -ne $settingsH2 -and $settingsH2.MaxCjxlProcs -eq 8) "the overflowing [long] value (MaxCjxlProcs) fell back to its own default (8)"
Test-Assert ($null -ne $settingsH2 -and $settingsH2.AnimatedThreads -eq 8) "the overflowing [decimal] value (AnimatedThreads) fell back to its own default (8)"
Write-Host ""

# ==============================================================================
#  Scenario H2: the Animated* keys round-trip and are range-validated the
#  same way as their non-animated counterparts (JpegQuality/ZipParallelThreads)
# ==============================================================================
Write-Host "=== Scenario H2: Animated* keys round-trip and validate ===" -ForegroundColor Cyan
$pathH2 = Join-Path $scratchDir "animated-settings.json"
$toSaveH2 = Get-DefaultScriptSettings
$toSaveH2.AnimatedThreads = 6
$toSaveH2.AnimatedQuality = 80
$toSaveH2.AnimatedLossless = $true
$toSaveH2.AnimatedOverwrite = $true
$toSaveH2.AnimatedDeleteSource = $false
Export-ScriptSettings -Settings $toSaveH2 -Path $pathH2
$loadedH2 = Import-ScriptSettings -Path $pathH2
Test-Assert ($loadedH2.AnimatedThreads -eq 6 -and $loadedH2.AnimatedQuality -eq 80) "AnimatedThreads/AnimatedQuality round-tripped"
Test-Assert ($loadedH2.AnimatedLossless -eq $true -and $loadedH2.AnimatedOverwrite -eq $true -and $loadedH2.AnimatedDeleteSource -eq $false) "the three Animated* bools round-tripped"

$pathH3 = Join-Path $scratchDir "animated-bad-settings.json"
'{ "AnimatedQuality": 0, "AnimatedThreads": -1, "FullPipelineMaxConcurrentProcs": 0 }' | Set-Content -LiteralPath $pathH3 -Encoding UTF8
$settingsH3 = Import-ScriptSettings -Path $pathH3
Test-Assert ($settingsH3.AnimatedQuality -eq 90) "out-of-range AnimatedQuality (0) fell back to default (90)"
Test-Assert ($settingsH3.AnimatedThreads -eq 8) "out-of-range AnimatedThreads (-1) fell back to default (8)"
Test-Assert ($settingsH3.FullPipelineMaxConcurrentProcs -eq 8) "out-of-range FullPipelineMaxConcurrentProcs (0) fell back to default (8)"

$pathH3b = Join-Path $scratchDir "full-pipeline-good-settings.json"
'{ "FullPipelineMaxConcurrentProcs": 12 }' | Set-Content -LiteralPath $pathH3b -Encoding UTF8
$settingsH3b = Import-ScriptSettings -Path $pathH3b
Test-Assert ($settingsH3b.FullPipelineMaxConcurrentProcs -eq 12) "a valid FullPipelineMaxConcurrentProcs (12) round-trips, independent of MaxCjxlProcs"
Write-Host ""

# ==============================================================================
#  Scenario H4: ZipWithUnconvertedAnimated round-trips as a real bool
# ==============================================================================
Write-Host "=== Scenario H4: ZipWithUnconvertedAnimated round-trips ===" -ForegroundColor Cyan
$pathH4 = Join-Path $scratchDir "zip-unconverted-settings.json"
$toSaveH4 = Get-DefaultScriptSettings
$toSaveH4.ZipWithUnconvertedAnimated = $true
Export-ScriptSettings -Settings $toSaveH4 -Path $pathH4
$loadedH4 = Import-ScriptSettings -Path $pathH4
Test-Assert ($loadedH4.ZipWithUnconvertedAnimated -eq $true) "ZipWithUnconvertedAnimated round-tripped as `$true"
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
