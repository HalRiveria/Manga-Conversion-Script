<#
.SYNOPSIS
    Standalone test harness for Modules\AnimatedConversionPipeline.ps1.

.DESCRIPTION
    Dot-sources the real module and stubs Write-Log/Remove-Source/
    $script:PermanentDelete (same pattern as
    ImageConversionPipeline.Harness.ps1) so this module doesn't need
    Logging.ps1/FileDeletion.ps1 built/working to be tested. A compiled
    fake magick.exe (same technique as that harness's fake cjxl.exe)
    handles both "identify -format %n <path>" (animation-frame-count
    detection) and the real conversion call, so real OS processes
    actually run end to end - the fake's conversion branch writes the
    exact argument string it received into the output file so a scenario
    can assert which flags (lossless vs quality) were actually passed.

.EXAMPLE
    .\Modules\_Harness\AnimatedConversionPipeline.Harness.ps1
#>

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\AnimatedConversionPipeline.ps1")

$script:logCalls = New-Object System.Collections.Generic.List[string]
function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $script:logCalls.Add($Level + ": " + $Message)
}

$script:removeSourceCalls = New-Object System.Collections.Generic.List[string]
$script:PermanentDelete = $true
function Remove-Source {
    param([string]$ItemPath)
    $script:removeSourceCalls.Add($ItemPath)
    if (Test-Path -LiteralPath $ItemPath) { Remove-Item -LiteralPath $ItemPath -Force }
    return $true
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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("animatedconv-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray

function New-FakeAvif {
    param([string]$Name, [string]$Content = "FRAMES:5")
    $path = Join-Path $scratchDir $Name
    $parent = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $path -Value $Content -Encoding UTF8 -NoNewline
    return (Get-Item -LiteralPath $path)
}

# ------------------------------------------------------------------
#  Fake magick.exe:
#   - "identify -format "%n" <path>": reads FRAMES:<n> from the input's
#     content (default 1 if absent); FAIL_IDENTIFY -> exit 1.
#   - otherwise (a real conversion call): FAIL_MAGICK -> exit 1;
#     SLEEP_MS:<n> -> real Thread.Sleep(n) first; writes the exact
#     argument string it received into the output file, so a scenario
#     can assert which flags were actually passed.
# ------------------------------------------------------------------
$fakeMagickSource = @'
using System;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;
class Program {
    static int Main(string[] args) {
        if (args.Length > 0 && args[0] == "identify") {
            string path = args[args.Length - 1];
            string content = File.Exists(path) ? File.ReadAllText(path) : "";
            if (content.Contains("FAIL_IDENTIFY")) {
                Console.Error.WriteLine("simulated identify failure");
                return 1;
            }
            Match fm = Regex.Match(content, "FRAMES:(\\d+)");
            int frames = fm.Success ? int.Parse(fm.Groups[1].Value) : 1;
            Console.Write(frames.ToString());
            return 0;
        }

        string src = args[0];
        string dst = args[args.Length - 1];
        string srcContent = File.Exists(src) ? File.ReadAllText(src) : "";

        if (srcContent.Contains("FAIL_MAGICK")) {
            Console.Error.WriteLine("simulated magick conversion failure");
            return 1;
        }
        Match sm = Regex.Match(srcContent, "SLEEP_MS:(\\d+)");
        if (sm.Success) { Thread.Sleep(int.Parse(sm.Groups[1].Value)); }

        File.WriteAllText(dst, "ARGS:" + string.Join(" ", args));
        return 0;
    }
}
'@
$fakeMagickExe = Join-Path $scratchDir "fake_magick.exe"
Add-Type -TypeDefinition $fakeMagickSource -Language CSharp -OutputAssembly $fakeMagickExe -OutputType ConsoleApplication

Write-Host ""

# ==============================================================================
#  Scenario A: Test-AvifAnimated
# ==============================================================================
Write-Host "=== Scenario A: Test-AvifAnimated ===" -ForegroundColor Cyan
$animA = New-FakeAvif -Name "animated-a.avif" -Content "FRAMES:12"
Test-Assert ((Test-AvifAnimated -AvifPath $animA.FullName -MagickExe $fakeMagickExe) -eq $true) "a 12-frame AVIF is detected as animated"

$staticA = New-FakeAvif -Name "static-a.avif" -Content "FRAMES:1"
Test-Assert ((Test-AvifAnimated -AvifPath $staticA.FullName -MagickExe $fakeMagickExe) -eq $false) "a 1-frame AVIF is detected as static"

$failA = New-FakeAvif -Name "fail-identify-a.avif" -Content "FAIL_IDENTIFY"
$threwA = $false
try { Test-AvifAnimated -AvifPath $failA.FullName -MagickExe $fakeMagickExe } catch { $threwA = $true }
Test-Assert $threwA "a failed identify call throws, letting the caller decide how to handle it"
Write-Host ""

# ==============================================================================
#  Scenario B: Convert-AnimatedBatch end-to-end success - converts,
#  deletes source (default DoAnimatedDeleteSource)
# ==============================================================================
Write-Host "=== Scenario B: end-to-end success ===" -ForegroundColor Cyan
$fileB = New-FakeAvif -Name "chapter-b\page1.avif" -Content "FRAMES:8"
$resultB = Convert-AnimatedBatch -AnimatedFiles @($fileB) -MagickExe $fakeMagickExe -AnimatedThreads 2 -CancelToken ([System.Threading.CancellationToken]::None)

Test-Assert ($resultB.ConvertedCount -eq 1 -and $resultB.FailedCount -eq 0) "1 converted, 0 failed"
Test-Assert ($resultB.DeletedCount -eq 1) "source deleted (DoAnimatedDeleteSource defaults true)"
Test-Assert (-not (Test-Path -LiteralPath $fileB.FullName)) "source file is actually gone"
$webpB = [System.IO.Path]::ChangeExtension($fileB.FullName, ".webp")
Test-Assert (Test-Path -LiteralPath $webpB) "output .webp was created"
Write-Host ""

# ==============================================================================
#  Scenario C: static AVIF is left entirely untouched
# ==============================================================================
Write-Host "=== Scenario C: static AVIF left untouched ===" -ForegroundColor Cyan
$fileC = New-FakeAvif -Name "static-c.avif" -Content "FRAMES:1"
$resultC = Convert-AnimatedBatch -AnimatedFiles @($fileC) -MagickExe $fakeMagickExe -AnimatedThreads 2 -CancelToken ([System.Threading.CancellationToken]::None)

Test-Assert ($resultC.StaticSkippedCount -eq 1 -and $resultC.ConvertedCount -eq 0) "counted as StaticSkipped, not converted"
Test-Assert (Test-Path -LiteralPath $fileC.FullName) "the static source file was NOT deleted"
$webpC = [System.IO.Path]::ChangeExtension($fileC.FullName, ".webp")
Test-Assert (-not (Test-Path -LiteralPath $webpC)) "no .webp was ever created for a static AVIF"
Write-Host ""

# ==============================================================================
#  Scenario D: -DoAnimatedOverwrite $false skips a file whose output
#  already exists, without even inspecting it
# ==============================================================================
Write-Host "=== Scenario D: skip when output exists and Overwrite is off ===" -ForegroundColor Cyan
$fileD = New-FakeAvif -Name "chapter-d\page1.avif" -Content "FRAMES:8"
$webpD = [System.IO.Path]::ChangeExtension($fileD.FullName, ".webp")
Set-Content -LiteralPath $webpD -Value "pre-existing webp" -Encoding UTF8 -NoNewline

$resultD = Convert-AnimatedBatch -AnimatedFiles @($fileD) -MagickExe $fakeMagickExe -AnimatedThreads 2 -DoAnimatedOverwrite $false -CancelToken ([System.Threading.CancellationToken]::None)

Test-Assert ($resultD.SkippedCount -eq 1 -and $resultD.ConvertedCount -eq 0) "counted as Skipped, not converted"
Test-Assert ((Get-Content -LiteralPath $webpD -Raw) -eq "pre-existing webp") "the existing output was left untouched"
Test-Assert (Test-Path -LiteralPath $fileD.FullName) "the source file was NOT deleted (never dispatched)"
Write-Host ""

# ==============================================================================
#  Scenario E: -DoAnimatedOverwrite $true reconverts even when the
#  output already exists
# ==============================================================================
Write-Host "=== Scenario E: Overwrite `$true reconverts an existing output ===" -ForegroundColor Cyan
$fileE = New-FakeAvif -Name "chapter-e\page1.avif" -Content "FRAMES:8"
$webpE = [System.IO.Path]::ChangeExtension($fileE.FullName, ".webp")
Set-Content -LiteralPath $webpE -Value "stale webp" -Encoding UTF8

$resultE = Convert-AnimatedBatch -AnimatedFiles @($fileE) -MagickExe $fakeMagickExe -AnimatedThreads 2 -DoAnimatedOverwrite $true -CancelToken ([System.Threading.CancellationToken]::None)

Test-Assert ($resultE.ConvertedCount -eq 1) "reconverted despite the existing output"
Test-Assert ((Get-Content -LiteralPath $webpE -Raw) -ne "stale webp") "the output file's content actually changed"
Write-Host ""

# ==============================================================================
#  Scenario F: conversion failure - not deleted, no leftover partial webp
# ==============================================================================
Write-Host "=== Scenario F: conversion failure ===" -ForegroundColor Cyan
$fileF = New-FakeAvif -Name "chapter-f\page1.avif" -Content "FRAMES:8`nFAIL_MAGICK"
$resultF = Convert-AnimatedBatch -AnimatedFiles @($fileF) -MagickExe $fakeMagickExe -AnimatedThreads 2 -CancelToken ([System.Threading.CancellationToken]::None)

Test-Assert ($resultF.FailedCount -eq 1 -and $resultF.ConvertedCount -eq 0) "counted as failed"
Test-Assert (Test-Path -LiteralPath $fileF.FullName) "the source was NOT deleted after a failure"
$webpF = [System.IO.Path]::ChangeExtension($fileF.FullName, ".webp")
Test-Assert (-not (Test-Path -LiteralPath $webpF)) "no leftover partial .webp"
Write-Host ""

# ==============================================================================
#  Scenario G: identify (inspection) failure - counted distinctly, no
#  conversion attempted, source untouched
# ==============================================================================
Write-Host "=== Scenario G: inspection failure ===" -ForegroundColor Cyan
$fileG = New-FakeAvif -Name "chapter-g\page1.avif" -Content "FAIL_IDENTIFY"
$resultG = Convert-AnimatedBatch -AnimatedFiles @($fileG) -MagickExe $fakeMagickExe -AnimatedThreads 2 -CancelToken ([System.Threading.CancellationToken]::None)

Test-Assert ($resultG.InspectFailedCount -eq 1 -and $resultG.ConvertedCount -eq 0 -and $resultG.FailedCount -eq 0) "counted distinctly as InspectFailed, not a conversion failure"
Test-Assert (Test-Path -LiteralPath $fileG.FullName) "the source was untouched"
Write-Host ""

# ==============================================================================
#  Scenario H: -DoAnimatedDeleteSource $false keeps the source after a
#  successful conversion
# ==============================================================================
Write-Host "=== Scenario H: DoAnimatedDeleteSource `$false keeps the source ===" -ForegroundColor Cyan
$fileH = New-FakeAvif -Name "chapter-h\page1.avif" -Content "FRAMES:8"
$resultH = Convert-AnimatedBatch -AnimatedFiles @($fileH) -MagickExe $fakeMagickExe -AnimatedThreads 2 -DoAnimatedDeleteSource $false -CancelToken ([System.Threading.CancellationToken]::None)

Test-Assert ($resultH.ConvertedCount -eq 1 -and $resultH.DeletedCount -eq 0) "converted but not deleted"
Test-Assert (Test-Path -LiteralPath $fileH.FullName) "the source file is still there"
Write-Host ""

# ==============================================================================
#  Scenario I: -DoAnimatedLossless controls the actual magick args passed
# ==============================================================================
Write-Host "=== Scenario I: Lossless vs Quality args ===" -ForegroundColor Cyan
$fileI1 = New-FakeAvif -Name "chapter-i\lossless.avif" -Content "FRAMES:8"
Convert-AnimatedBatch -AnimatedFiles @($fileI1) -MagickExe $fakeMagickExe -AnimatedThreads 2 -DoAnimatedLossless $true -CancelToken ([System.Threading.CancellationToken]::None) | Out-Null
$argsI1 = Get-Content -LiteralPath ([System.IO.Path]::ChangeExtension($fileI1.FullName, ".webp")) -Raw
Test-Assert ($argsI1 -match "webp:lossless=true") "lossless mode passed the lossless define"

$fileI2 = New-FakeAvif -Name "chapter-i\quality.avif" -Content "FRAMES:8"
Convert-AnimatedBatch -AnimatedFiles @($fileI2) -MagickExe $fakeMagickExe -AnimatedThreads 2 -DoAnimatedLossless $false -AnimatedQuality 77 -CancelToken ([System.Threading.CancellationToken]::None) | Out-Null
$argsI2 = Get-Content -LiteralPath ([System.IO.Path]::ChangeExtension($fileI2.FullName, ".webp")) -Raw
Test-Assert ($argsI2 -match "-quality 77") "lossy mode passed the configured quality value"
Write-Host ""

# ==============================================================================
#  Scenario J: multiple files convert together (AnimatedThreads > 1)
# ==============================================================================
Write-Host "=== Scenario J: multiple files convert together ===" -ForegroundColor Cyan
$filesJ = 1..4 | ForEach-Object { New-FakeAvif -Name ("chapter-j\page" + $_ + ".avif") -Content "FRAMES:6" }
$resultJ = Convert-AnimatedBatch -AnimatedFiles $filesJ -MagickExe $fakeMagickExe -AnimatedThreads 4 -CancelToken ([System.Threading.CancellationToken]::None)
Test-Assert ($resultJ.ConvertedCount -eq 4 -and $resultJ.FailedCount -eq 0) ("all 4 converted (got " + $resultJ.ConvertedCount + ")")
Write-Host ""

# ==============================================================================
#  Scenario K: heartbeat - a slow job logs a "still converting" line with
#  batch progress once it exceeds -HeartbeatIntervalSeconds
# ==============================================================================
Write-Host "=== Scenario K: heartbeat logging ===" -ForegroundColor Cyan
$fileK = New-FakeAvif -Name "chapter-k\slow.avif" -Content "FRAMES:6`nSLEEP_MS:1500"
$script:logCalls.Clear()
$resultK = Convert-AnimatedBatch -AnimatedFiles @($fileK) -MagickExe $fakeMagickExe -AnimatedThreads 1 -HeartbeatIntervalSeconds 1 -CancelToken ([System.Threading.CancellationToken]::None)
Test-Assert ($resultK.ConvertedCount -eq 1) "the slow job still completed successfully"
$heartbeatLines = @($script:logCalls | Where-Object { $_ -like "*Still converting*" })
Test-Assert ($heartbeatLines.Count -ge 1) "at least one heartbeat line was logged for the slow job"
Test-Assert (($heartbeatLines -join "`n") -match "batch progress: \d+/1 done") "the heartbeat line includes batch-level progress"
Write-Host ""

# ==============================================================================
#  Scenario L: cancellation mid-batch - graceful drain lets an in-flight
#  job finish, force-kill triggers only past -AbortTimeoutSeconds
# ==============================================================================
Write-Host "=== Scenario L: cancellation mid-batch (graceful drain) ===" -ForegroundColor Cyan
$fileL = New-FakeAvif -Name "chapter-l\slow.avif" -Content "FRAMES:6`nSLEEP_MS:500"
$ctsL = New-Object System.Threading.CancellationTokenSource
$pollCallbackL = {
    param($inFlight)
    # Cancel only once the slow job is actually dispatched and in flight -
    # the poll callback also fires once BEFORE the very first dispatch
    # (nothing running yet), and cancelling there would prevent the job
    # from ever starting at all, which isn't what this scenario tests.
    if ($inFlight.Count -gt 0) { $ctsL.Cancel() }
}.GetNewClosure()

$resultL = Convert-AnimatedBatch -AnimatedFiles @($fileL) -MagickExe $fakeMagickExe -AnimatedThreads 1 `
    -CancelToken $ctsL.Token -AbortPollCallback $pollCallbackL -AbortTimeoutSeconds 10

Test-Assert ($resultL.ConvertedCount -eq 1 -and $resultL.ForceKilledCount -eq 0) "the in-flight job was allowed to finish naturally during the graceful drain, not force-killed"
$ctsL.Dispose()
Write-Host ""

# ==============================================================================
#  Scenario M: empty input returns a clean zeroed result, no error
# ==============================================================================
Write-Host "=== Scenario M: empty input ===" -ForegroundColor Cyan
$resultM = Convert-AnimatedBatch -AnimatedFiles @() -MagickExe $fakeMagickExe -AnimatedThreads 2 -CancelToken ([System.Threading.CancellationToken]::None)
Test-Assert ($resultM.ConvertedCount -eq 0 -and $resultM.FailedCount -eq 0) "no work, no error, for an empty batch"
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
