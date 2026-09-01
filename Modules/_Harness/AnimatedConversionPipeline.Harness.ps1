<#
.SYNOPSIS
    Standalone test harness for Modules\AnimatedConversionPipeline.ps1.

.DESCRIPTION
    PART 1 (Scenarios A-M): dot-sources the real module and stubs
    Write-Log/Remove-Source/$script:PermanentDelete (same pattern as
    ImageConversionPipeline.Harness.ps1) so this module doesn't need
    Logging.ps1/FileDeletion.ps1 built/working to be tested. A compiled
    fake magick.exe (same technique as that harness's fake cjxl.exe)
    handles both "identify -format %n <path>" (animation-frame-count
    detection) and the real conversion call, so real OS processes
    actually run end to end - the fake's conversion branch writes the
    exact argument string it received into the output file so a scenario
    can assert which flags (lossless vs quality) were actually passed.

    PART 2 (Scenarios N onward, added 2026-08-28): also dot-sources the
    REAL AbortPipeline.ps1/LeafDirectoryDiscovery.ps1/
    CleanConsoleRendering.ps1 - same integration-style choice
    ImageConversionPipeline.Harness.ps1 made for its own PART 2, since
    Invoke-LooseAnimatedConversionPipeline is an orchestration-tier
    function whose real value is in proving the two-tier walk/coverage-
    completeness/CCR wiring actually work against real directory trees,
    not in mocking that machinery away. Write-Log/Remove-Source stay the
    lightweight local stubs from PART 1 - AbortPipeline.ps1 and
    LeafDirectoryDiscovery.ps1 both only need Write-Log stubbed (verified
    against each module's own FORWARD REFERENCE header text), not the
    real Logging.ps1/FileDeletion.ps1 modules, so PART 1's existing
    scenarios needed no changes at all.

.EXAMPLE
    .\Modules\_Harness\AnimatedConversionPipeline.Harness.ps1
#>

$ErrorActionPreference = "Stop"

$modulesDirAC = Join-Path $PSScriptRoot ".."
. (Join-Path $modulesDirAC "AnimatedConversionPipeline.ps1")
. (Join-Path $modulesDirAC "AbortPipeline.ps1")
. (Join-Path $modulesDirAC "LeafDirectoryDiscovery.ps1")
. (Join-Path $modulesDirAC "CleanConsoleRendering.ps1")

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

# ------------------------------------------------------------------
#  PART 2 abort spies - same idiom as
#  ImageConversionPipeline.Harness.ps1's own (capture the real
#  originals, wrap with call-tracking, restore afterward). Only used by
#  the abort scenario below.
# ------------------------------------------------------------------
$script:registerCtsCalls          = [System.Collections.Generic.List[System.Threading.CancellationTokenSource]]::new()
$script:unregisterCtsCalls        = [System.Collections.Generic.List[System.Threading.CancellationTokenSource]]::new()
$script:unregisterCtsWasCancelled = [System.Collections.Generic.List[bool]]::new()
$script:testAbortSignalCallCount  = 0
$script:testAbortSignalTriggerAt  = -1

$originalRegisterAbortCts   = ${function:Register-AbortCancellationSource}
$originalUnregisterAbortCts = ${function:Unregister-AbortCancellationSource}
$originalTestAbortSignal    = ${function:Test-AbortSignal}

function Register-AbortCancellationSource {
    param([System.Threading.CancellationTokenSource]$Cts)
    $script:registerCtsCalls.Add($Cts)
    & $originalRegisterAbortCts -Cts $Cts
}
function Unregister-AbortCancellationSource {
    param([System.Threading.CancellationTokenSource]$Cts)
    $script:unregisterCtsCalls.Add($Cts)
    $script:unregisterCtsWasCancelled.Add([bool]$Cts.Token.IsCancellationRequested)
    & $originalUnregisterAbortCts -Cts $Cts
}
function Test-AbortSignal {
    $script:testAbortSignalCallCount++
    if ($script:testAbortSignalCallCount -eq $script:testAbortSignalTriggerAt) {
        [ConsoleCtrl]::AbortRequested = $true
    }
    & $originalTestAbortSignal
}
function Reset-AbortState {
    [ConsoleCtrl]::AbortRequested = $false
    [ConsoleCtrl]::IsCloseEvent   = $false
    [ConsoleCtrl]::DrainComplete.Reset()
    $script:abortRequested = $false
    $script:ctrlCloseAbort = $false
    $script:abortCancellationSources.Clear()
    $script:CleanConsoleOutputEnabled = $false
    $script:registerCtsCalls.Clear()
    $script:unregisterCtsCalls.Clear()
    $script:unregisterCtsWasCancelled.Clear()
    $script:testAbortSignalCallCount = 0
    $script:testAbortSignalTriggerAt = -1
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
#  PART 2 helpers - mirror ImageConversionPipeline.Harness.ps1's own
#  New-Dir/New-FakeImage exactly (same shape, "animated" instead of
#  "image" naming).
# ------------------------------------------------------------------
function New-Dir {
    param([string]$RelativePath)
    $path = Join-Path $scratchDir $RelativePath
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}
function New-FakeAvifIn {
    param([string]$DirPath, [string]$Name, [int]$Frames = 5, [bool]$Fail = $false)
    $path = Join-Path $DirPath $Name
    $content = "FRAMES:" + $Frames + $(if ($Fail) { "`nFAIL_MAGICK" } else { "" })
    [System.IO.File]::WriteAllText($path, $content)
    return $path
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
            if (content.Contains("FAIL_IDENTIFY_HUGE_STDERR")) {
                // Simulates a malformed AVIF producing a large stderr
                // warning/error dump - large enough to fill the OS pipe
                // buffer (typically 4-64KB) if the parent isn't actively
                // draining stderr while this process is still running.
                // Proves the 2026-08-31 deadlock fix (Test-AvifAnimated
                // now reads both streams asynchronously before
                // WaitForExit) - without it, this would hang the whole
                // test instead of completing quickly.
                string line = new string('X', 200) + Environment.NewLine;
                for (int i = 0; i < 2000; i++) { Console.Error.Write(line); }
                return 1;
            }
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

        if (srcContent.Contains("FAIL_MAGICK_AFTER_PARTIAL_WRITE")) {
            // Simulates magick actually opening/writing to its output
            // path before crashing mid-encode - proves the 2026-08-31
            // fix (magick is pointed at a temp path when overwriting a
            // pre-existing file, not the real path directly) actually
            // protects the original: without the fix, this would
            // overwrite dst (the real .webp) with garbage BEFORE failing,
            // corrupting it regardless of what the failure-cleanup code
            // decides afterward.
            File.WriteAllText(dst, "garbage-partial-write-from-a-crashed-magick");
            Console.Error.WriteLine("simulated magick crash after partial write");
            return 1;
        }
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

# 2026-08-31 fix: Test-AvifAnimated used to read stdout to completion,
# then stderr, then call WaitForExit - the classic Process redirect
# deadlock ordering. A huge stderr dump (simulating a malformed AVIF's
# real identify output) large enough to fill the OS pipe buffer would
# hang this call forever before the fix (both async reads draining
# concurrently now prevent either pipe from ever filling). Same
# precedent as this file's own Scenario Y-equivalent hang-fix tests -
# a real regression here would hang the whole harness run, not just fail
# an assertion, same tradeoff already accepted elsewhere in this project
# for this exact class of fix.
$hugeStderrA = New-FakeAvif -Name "fail-identify-huge-a.avif" -Content "FAIL_IDENTIFY_HUGE_STDERR"
$swA = [System.Diagnostics.Stopwatch]::StartNew()
$threwHugeA = $false
try { Test-AvifAnimated -AvifPath $hugeStderrA.FullName -MagickExe $fakeMagickExe } catch { $threwHugeA = $true }
$swA.Stop()
Test-Assert $threwHugeA "a huge-stderr identify failure still throws (not silently swallowed)"
Test-Assert ($swA.Elapsed.TotalSeconds -lt 15) ("returned promptly instead of deadlocking on a full stderr pipe (took " + [int]$swA.Elapsed.TotalSeconds + "s)")
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
#  Scenario F2 (2026-08-31 fix): -DoAnimatedOverwrite $true points a
#  (now-failing) re-conversion at an already-existing, good .webp from a
#  prior successful run - the failure must NOT delete that pre-existing
#  file. Before the fix, the failure catch deleted $Job.WebpPath
#  unconditionally whenever it existed, destroying a previously-good
#  output over an unrelated later failure.
# ==============================================================================
Write-Host "=== Scenario F2: a failed re-conversion does NOT delete the pre-existing good .webp it was overwriting ===" -ForegroundColor Cyan
$fileF2 = New-FakeAvif -Name "chapter-f2\page1.avif" -Content "FRAMES:8`nFAIL_MAGICK"
$webpF2 = [System.IO.Path]::ChangeExtension($fileF2.FullName, ".webp")
"pre-existing good webp bytes from a prior successful run" | Set-Content -LiteralPath $webpF2 -Encoding UTF8 -NoNewline

$resultF2 = Convert-AnimatedBatch -AnimatedFiles @($fileF2) -MagickExe $fakeMagickExe -AnimatedThreads 2 -DoAnimatedOverwrite $true -CancelToken ([System.Threading.CancellationToken]::None)

Test-Assert ($resultF2.FailedCount -eq 1 -and $resultF2.ConvertedCount -eq 0) "counted as failed"
Test-Assert (Test-Path -LiteralPath $webpF2) "the pre-existing .webp still exists - NOT deleted by the failed re-conversion attempt"
Test-Assert ((Get-Content -LiteralPath $webpF2 -Raw) -eq "pre-existing good webp bytes from a prior successful run") "the pre-existing .webp's own content survives untouched"
Write-Host ""

# ==============================================================================
#  Scenario F3 (2026-08-31 fix): -DoAnimatedOverwrite $true points a
#  re-conversion at an already-existing, good .webp - the conversion
#  attempt actually WRITES PARTIAL GARBAGE to its output path before
#  crashing (unlike F2's FAIL_MAGICK, which fails before writing
#  anything). Scenario F2's own "not deleted" guard is not enough here -
#  WebpExistedBeforeJob only ever stopped THIS SCRIPT from deleting the
#  file, it never stopped magick.exe itself from overwriting it in
#  place. Fixed by pointing magick at a temp path when overwriting an
#  existing file, only replacing the real path after a verified success.
# ==============================================================================
Write-Host "=== Scenario F3: a crash mid-write does NOT corrupt the pre-existing good .webp (magick targets a temp path, not the original) ===" -ForegroundColor Cyan
$fileF3 = New-FakeAvif -Name "chapter-f3\page1.avif" -Content "FRAMES:8`nFAIL_MAGICK_AFTER_PARTIAL_WRITE"
$webpF3 = [System.IO.Path]::ChangeExtension($fileF3.FullName, ".webp")
"pre-existing good webp bytes from a prior successful run" | Set-Content -LiteralPath $webpF3 -Encoding UTF8 -NoNewline

$resultF3 = Convert-AnimatedBatch -AnimatedFiles @($fileF3) -MagickExe $fakeMagickExe -AnimatedThreads 2 -DoAnimatedOverwrite $true -CancelToken ([System.Threading.CancellationToken]::None)

Test-Assert ($resultF3.FailedCount -eq 1 -and $resultF3.ConvertedCount -eq 0) "counted as failed"
Test-Assert (Test-Path -LiteralPath $webpF3) "the pre-existing .webp still exists"
Test-Assert ((Get-Content -LiteralPath $webpF3 -Raw) -eq "pre-existing good webp bytes from a prior successful run") "the pre-existing .webp's own content survives BYTE-FOR-BYTE untouched - magick's crash-mid-write landed on a temp file, never the original"
$leftoverTempF3 = @(Get-ChildItem -LiteralPath (Split-Path -Path $webpF3 -Parent) -Filter "*_tmp_overwrite.webp" -File -ErrorAction SilentlyContinue)
Test-Assert (@($leftoverTempF3).Count -eq 0) "the temp file magick actually wrote garbage to was cleaned up, not left behind"
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
#  Scenario L2 (2026-08-31 fix): the force-kill path (past -AbortTimeoutSeconds,
#  NOT the graceful-drain-lets-it-finish path Scenario L covers) must not
#  delete a pre-existing good .webp it was overwriting. Before the fix,
#  this separate cleanup site deleted $j.WebpPath unconditionally whenever
#  it existed - the same bug Scenario F2 (Convert-AnimatedBatch's own
#  failure catch) already covers, left open on this different code path.
#  SLEEP_MS deliberately exceeds -AbortTimeoutSeconds so the job is still
#  running when the drain gives up and force-kills it.
# ==============================================================================
Write-Host "=== Scenario L2: a force-killed job does NOT delete the pre-existing good .webp it was overwriting ===" -ForegroundColor Cyan
$fileL2 = New-FakeAvif -Name "chapter-l2\slow.avif" -Content "FRAMES:6`nSLEEP_MS:3000"
$webpL2 = [System.IO.Path]::ChangeExtension($fileL2.FullName, ".webp")
"pre-existing good webp bytes from a prior successful run" | Set-Content -LiteralPath $webpL2 -Encoding UTF8 -NoNewline
$ctsL2 = New-Object System.Threading.CancellationTokenSource
$pollCallbackL2 = {
    param($inFlight)
    if ($inFlight.Count -gt 0) { $ctsL2.Cancel() }
}.GetNewClosure()

$resultL2 = Convert-AnimatedBatch -AnimatedFiles @($fileL2) -MagickExe $fakeMagickExe -AnimatedThreads 1 -DoAnimatedOverwrite $true `
    -CancelToken $ctsL2.Token -AbortPollCallback $pollCallbackL2 -AbortTimeoutSeconds 1
$ctsL2.Dispose()

Test-Assert ($resultL2.ForceKilledCount -eq 1) ("sanity check: the job was actually force-killed, not allowed to finish (got ForceKilledCount=" + $resultL2.ForceKilledCount + ")")
Test-Assert (Test-Path -LiteralPath $webpL2) "the pre-existing .webp still exists - NOT deleted by the force-kill cleanup"
Test-Assert ((Get-Content -LiteralPath $webpL2 -Raw) -eq "pre-existing good webp bytes from a prior successful run") "the pre-existing .webp's own content survives untouched"
Write-Host ""

# ==============================================================================
#  Scenario M: empty input returns a clean zeroed result, no error
# ==============================================================================
Write-Host "=== Scenario M: empty input ===" -ForegroundColor Cyan
$resultM = Convert-AnimatedBatch -AnimatedFiles @() -MagickExe $fakeMagickExe -AnimatedThreads 2 -CancelToken ([System.Threading.CancellationToken]::None)
Test-Assert ($resultM.ConvertedCount -eq 0 -and $resultM.FailedCount -eq 0) "no work, no error, for an empty batch"
Write-Host ""

# ==============================================================================
#  Scenario N: multi-series, multi-chapter conversion end to end -
#  correct per-chapter batching, source deletion, SeriesCount/ChapterCount.
# ==============================================================================
Write-Host "=== Scenario N: multi-series/multi-chapter conversion ===" -ForegroundColor Cyan
$s1c1N = New-Dir "scenario-n\Series One\Chapter 1"
$s1c2N = New-Dir "scenario-n\Series One\Chapter 2"
$s2c1N = New-Dir "scenario-n\Series Two\Chapter 1"
New-FakeAvifIn -DirPath $s1c1N -Name "page1.avif" | Out-Null
New-FakeAvifIn -DirPath $s1c1N -Name "page2.avif" | Out-Null
New-FakeAvifIn -DirPath $s1c2N -Name "page1.avif" | Out-Null
New-FakeAvifIn -DirPath $s2c1N -Name "page1.avif" | Out-Null

$totalsN = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-n") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false

Test-Assert ($totalsN.SeriesCount -eq 2) ("2 series found (got " + $totalsN.SeriesCount + ")")
Test-Assert ($totalsN.ChapterCount -eq 3) ("3 chapters found (got " + $totalsN.ChapterCount + ")")
Test-Assert ($totalsN.ConvertedSuccess -eq 4) ("4 files converted (got " + $totalsN.ConvertedSuccess + ")")
Test-Assert ($totalsN.ConvertedFail -eq 0) "no conversion failures"
Test-Assert ($totalsN.DeletedSuccess -eq 4) ("4 sources deleted (got " + $totalsN.DeletedSuccess + ")")
Test-Assert (-not (Test-Path -LiteralPath (Join-Path $s1c1N "page1.avif"))) "Series One/Chapter 1 page1 source gone"
Test-Assert (Test-Path -LiteralPath (Join-Path $s1c1N "page1.webp")) "Series One/Chapter 1 page1.webp created"
Test-Assert (-not $totalsN.Aborted) "not marked aborted"
Write-Host ""

# ==============================================================================
#  Scenario O: a chapter with a real conversion failure counts correctly
#  and does not get its source deleted.
# ==============================================================================
Write-Host "=== Scenario O: conversion failure ===" -ForegroundColor Cyan
$chO = New-Dir "scenario-o\Series\Chapter 1"
New-FakeAvifIn -DirPath $chO -Name "good.avif" | Out-Null
New-FakeAvifIn -DirPath $chO -Name "bad.avif" -Fail $true | Out-Null

$totalsO = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-o") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false

Test-Assert ($totalsO.ConvertedSuccess -eq 1) ("1 converted (got " + $totalsO.ConvertedSuccess + ")")
Test-Assert ($totalsO.ConvertedFail -eq 1) ("1 failed (got " + $totalsO.ConvertedFail + ")")
Test-Assert (Test-Path -LiteralPath (Join-Path $chO "bad.avif")) "failed source left in place, not deleted"
Test-Assert (-not (Test-Path -LiteralPath (Join-Path $chO "good.avif"))) "successful source deleted"
Write-Host ""

# ==============================================================================
#  Scenario P: a series with zero qualifying chapters is counted and
#  skipped cleanly (no crash, no chapters processed).
# ==============================================================================
Write-Host "=== Scenario P: series with zero chapters ===" -ForegroundColor Cyan
New-Dir "scenario-p\Empty Series" | Out-Null

$totalsP = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-p") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false

Test-Assert ($totalsP.SeriesCount -eq 1) "the empty series was still walked"
Test-Assert ($totalsP.ChapterCount -eq 0) "zero chapters counted"
Write-Host ""

# ==============================================================================
#  Scenario Q: -PostChapterCallback fires once per chapter with the
#  documented shape - no ZipOut/IsZippable (mode 3 never zips, unlike
#  the image pipeline's callback shape).
# ==============================================================================
Write-Host "=== Scenario Q: PostChapterCallback shape ===" -ForegroundColor Cyan
$chQ = New-Dir "scenario-q\My Series\Ch 1"
New-FakeAvifIn -DirPath $chQ -Name "page1.avif" | Out-Null

$callbackCallsQ = [System.Collections.Generic.List[hashtable]]::new()
$cbQ = { param($Info) $callbackCallsQ.Add($Info) }.GetNewClosure()

$null = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-q") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false -PostChapterCallback $cbQ

Test-Assert ($callbackCallsQ.Count -eq 1) ("callback fired once (got " + $callbackCallsQ.Count + ")")
Test-Assert ($callbackCallsQ[0].SeriesName -eq "My Series") "callback saw the right SeriesName"
Test-Assert ($callbackCallsQ[0].ChapterName -eq "Ch 1") "callback saw the right ChapterName"
Test-Assert ($callbackCallsQ[0].Dir.FullName -eq $chQ) "callback saw the right Dir"
Test-Assert ($callbackCallsQ[0].ChapterResult.ConvertedCount -eq 1) "callback saw the real ChapterResult"
Test-Assert (-not $callbackCallsQ[0].ContainsKey("ZipOut")) "callback payload has no ZipOut field - mode 3 never zips"
Test-Assert (-not $callbackCallsQ[0].ContainsKey("IsZippable")) "callback payload has no IsZippable field - mode 3 never zips"
Write-Host ""

# ==============================================================================
#  Scenario R: Get-ChapterAnimatedStatus mapping, tested directly
#  (unit-level) - Error > Warning > Success ordering, and StaticSkippedCount
#  deliberately does NOT trigger Warning.
# ==============================================================================
Write-Host "=== Scenario R: Get-ChapterAnimatedStatus mapping ===" -ForegroundColor Cyan
$statusNullR, $detailNullR = Get-ChapterAnimatedStatus -ChapterResult $null
Test-Assert ($statusNullR -eq "Success" -and $null -eq $detailNullR) "`$null ChapterResult (nothing to convert) maps to a clean Success"

$statusErrR, $detailErrR = Get-ChapterAnimatedStatus -ChapterResult @{ FailedCount = 2; ForceKilledCount = 1; DeleteFailedCount = 0; SkippedCount = 0; InspectFailedCount = 0 }
Test-Assert ($statusErrR -eq "Error" -and $detailErrR -match "2 failed" -and $detailErrR -match "1 force-stopped") "Error tier wins and lists both failure kinds"

# 2026-08-31 fix: InspectFailedCount is now Error-tier, not Warning - an
# inspect failure leaves a raw, completely unconverted .avif on disk, which
# must block Controller.ps1's zip gate the same way a real FailedCount does
# (a Warning-tier chapter still zips). Confirmed via a same-day /code-review.
$statusInspErrR, $detailInspErrR = Get-ChapterAnimatedStatus -ChapterResult @{ FailedCount = 0; ForceKilledCount = 0; DeleteFailedCount = 0; SkippedCount = 0; InspectFailedCount = 1 }
Test-Assert ($statusInspErrR -eq "Error" -and $detailInspErrR -match "1 inspect failure") "InspectFailedCount alone is Error tier, not Warning - it means a file was left completely unconverted"

$statusWarnR, $detailWarnR = Get-ChapterAnimatedStatus -ChapterResult @{ FailedCount = 0; ForceKilledCount = 0; DeleteFailedCount = 0; SkippedCount = 3; InspectFailedCount = 0 }
Test-Assert ($statusWarnR -eq "Warning" -and $detailWarnR -match "3 skipped") "Warning tier covers Skipped (output already exists - not a problem)"

$statusStaticR, $detailStaticR = Get-ChapterAnimatedStatus -ChapterResult @{ FailedCount = 0; ForceKilledCount = 0; DeleteFailedCount = 0; SkippedCount = 0; InspectFailedCount = 0; StaticSkippedCount = 5 }
Test-Assert ($statusStaticR -eq "Success" -and $null -eq $detailStaticR) "StaticSkippedCount alone does NOT trigger Warning - a static AVIF being left alone is expected, not a problem"
Write-Host ""

# ==============================================================================
#  Scenario S: CCR wiring - real CleanConsoleRendering.ps1 functions
#  actually get called and reach the expected end state.
# ==============================================================================
Write-Host "=== Scenario S: CCR event emission ===" -ForegroundColor Cyan
$chS1 = New-Dir "scenario-s\CCR Series\Chapter 1"
$chS2 = New-Dir "scenario-s\CCR Series\Chapter 2"
New-FakeAvifIn -DirPath $chS1 -Name "page1.avif" | Out-Null
New-FakeAvifIn -DirPath $chS2 -Name "page1.avif" -Fail $true | Out-Null

$script:CleanConsoleOutputEnabled = $true
try {
    $totalsS = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-s") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false
} finally {
    $script:CleanConsoleOutputEnabled = $false
}

Test-Assert ($script:ccrActiveSeries.Count -eq 0) "series resolved and left the active registry once both chapters completed"
Test-Assert ($totalsS.ConvertedSuccess -eq 1 -and $totalsS.ConvertedFail -eq 1) "conversion counts still correct with CCR on"
Write-Host ""

# ==============================================================================
#  Scenario T: a chapter dir excluded by Get-SeriesChapters's
#  former-container guard (a stray .zip sitting alongside real,
#  unconverted .avif files) is still folded in and converted - same
#  coverage-completeness fix as ImageConversionPipeline.ps1's own.
# ==============================================================================
Write-Host "=== Scenario T: former-container guard doesn't drop conversion coverage ===" -ForegroundColor Cyan
$chT = New-Dir "scenario-t\Series\Chapter 1"
New-FakeAvifIn -DirPath $chT -Name "page1.avif" | Out-Null
[System.IO.File]::WriteAllText((Join-Path $chT "Chapter 1.zip"), "not a real zip, just a stray file triggering the former-container guard")

$totalsT = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-t") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false

Test-Assert ($totalsT.ChapterCount -eq 1) "the guard-excluded directory was still folded in as a chapter-equivalent entry"
Test-Assert ($totalsT.ConvertedSuccess -eq 1) "its real .avif file was still converted, not silently skipped"
Write-Host ""

# ==============================================================================
#  Scenario U: abort mid-batch - registration/cancellation actually wired
#  up for real (same technique as ImageConversionPipeline.Harness.ps1's
#  own Scenario H).
# ==============================================================================
Write-Host "=== Scenario U: abort registration actually wired up ===" -ForegroundColor Cyan
Reset-AbortState
$chU = New-Dir "scenario-u\Series\Chapter 1"
New-FakeAvifIn -DirPath $chU -Name "page1.avif" | Out-Null
[System.IO.File]::AppendAllText((Join-Path $chU "page1.avif"), "`nSLEEP_MS:300")

# Same call-sequence reasoning as ImageConversionPipeline.Harness.ps1's
# Scenario H: call 1 = series while-loop top check, call 2 = chapter
# foreach-loop top check, call 3 = Convert-AnimatedBatch's first
# AbortPollCallback (before dispatch), call 4 = its second - by then the
# fake magick process is dispatched and still sleeping.
$script:testAbortSignalTriggerAt = 4

$totalsU = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-u") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false -AbortTimeoutSeconds 5

Test-Assert ($script:registerCtsCalls.Count -eq 1) ("Register-AbortCancellationSource called exactly once (got " + $script:registerCtsCalls.Count + ")")
Test-Assert ($script:unregisterCtsCalls.Count -eq 1) ("Unregister-AbortCancellationSource called exactly once (got " + $script:unregisterCtsCalls.Count + ")")
Test-Assert ([object]::ReferenceEquals($script:registerCtsCalls[0], $script:unregisterCtsCalls[0])) "the registered and unregistered CTS are the SAME object"
Test-Assert ($script:unregisterCtsWasCancelled[0]) "that CTS's token actually got cancelled by the real abort"
Test-Assert ($totalsU.Aborted) "pipeline reports Aborted"
Test-Assert ($totalsU.ConvertedSuccess -eq 1) "the in-flight job still completed successfully via the abort-drain wait, rather than being force-killed"
Test-Assert ($script:abortCancellationSources.Count -eq 0) "registry is empty again after the call (finally block ran)"
Reset-AbortState

${function:Register-AbortCancellationSource}   = $originalRegisterAbortCts
${function:Unregister-AbortCancellationSource} = $originalUnregisterAbortCts
${function:Test-AbortSignal}                   = $originalTestAbortSignal
Write-Host ""

# ==============================================================================
#  Scenario V: -SharedBudget (Controller.ps1's Full Pipeline concurrency
#  design, 2026-08-28) - a SemaphoreSlim with FEWER slots than
#  -AnimatedThreads actually constrains dispatch to the semaphore's count
#  (proven by observing it get fully exhausted mid-run via
#  -AbortPollCallback, not just inferred from final totals), and every
#  slot is released again (no leak) once the batch completes. Same
#  technique as ImageConversionPipeline.Harness.ps1's own Scenario P.
# ==============================================================================
Write-Host "=== Scenario V: -SharedBudget gates dispatch and never leaks ===" -ForegroundColor Cyan
$filesV = 1..5 | ForEach-Object { New-FakeAvif -Name ("scenario-v\budget" + $_ + ".avif") -Content "FRAMES:6`nSLEEP_MS:150" }
$budgetV = [System.Threading.SemaphoreSlim]::new(2, 2)
$script:budgetSnapshotsV = [System.Collections.Generic.List[int]]::new()
$pollV = { param($inFlight) $script:budgetSnapshotsV.Add($budgetV.CurrentCount) }

$resultV = Convert-AnimatedBatch -AnimatedFiles $filesV -MagickExe $fakeMagickExe -AnimatedThreads 5 -DoFullLogging $false `
    -CancelToken ([System.Threading.CancellationToken]::None) -SharedBudget $budgetV -AbortPollCallback $pollV

Test-Assert ($resultV.ConvertedCount -eq 5 -and $resultV.FailedCount -eq 0) "all 5 converted correctly through the shared budget"
Test-Assert (($script:budgetSnapshotsV | Where-Object { $_ -eq 0 }).Count -gt 0) "the 2-slot budget was actually driven to 0 at some point - proves dispatch was really gated to 2 concurrent, not just passed through unused (AnimatedThreads=5 would have let all 5 start at once otherwise)"
Test-Assert ($budgetV.CurrentCount -eq 2) "the budget is back to its full initial count after the call - no leaked slots"
# 2026-08-31 fix: same busy-spin bug and same proof technique as
# ImageConversionPipeline.Harness.ps1's Scenario P - AnimatedThreads=5 with
# a 2-slot SharedBudget is exactly the shape that spun at ~100% CPU before
# this fix (the old sleep-gate never saw running.Count reach
# AnimatedThreads, since the budget was the real ceiling).
Test-Assert ($script:budgetSnapshotsV.Count -lt 100) ("the dispatch loop slept between passes instead of busy-spinning (got " + $script:budgetSnapshotsV.Count + " passes for ~450ms of simulated work)")
$budgetV.Dispose()
Write-Host ""

# ==============================================================================
#  Scenario W (2026-08-31 fix): $animatedCts's construction and
#  Register-AbortCancellationSource call were moved INSIDE the function's
#  try block (same species as ZipParallelProcessing.ps1's mutex-leak fix
#  from earlier today, and ImageConversionPipeline.ps1's own analogous
#  fix). Register-AbortCancellationSource is temporarily replaced with a
#  fake that captures the real $Cts (so the test can inspect it
#  afterward) and throws, simulating a real registration failure.
#  Verified via a disposed Cts's own .Cancel() throwing
#  ObjectDisposedException (wrapped by PowerShell as
#  MethodInvocationException) - proof Dispose() actually ran via the
#  finally path.
# ==============================================================================
Write-Host "=== Scenario W: a throw during Register-AbortCancellationSource still disposes the already-constructed Cts ===" -ForegroundColor Cyan
$realRegisterFnW = ${function:Register-AbortCancellationSource}
$script:capturedCtsW = $null
function Register-AbortCancellationSource {
    param([System.Threading.CancellationTokenSource]$Cts)
    $script:capturedCtsW = $Cts
    throw "simulated Register-AbortCancellationSource failure"
}
New-FakeAvif -Name "scenario-w\Series\Chapter 1\page1.avif" | Out-Null
$threwW = $false
try {
    $null = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-w") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false
} catch {
    $threwW = $true
}
${function:Register-AbortCancellationSource} = $realRegisterFnW

Test-Assert $threwW "the registration failure propagated out of the pipeline, not silently swallowed"
Test-Assert ($null -ne $script:capturedCtsW) "sanity check: the fake actually captured the real Cts object before throwing"
$disposedW = $false
try { $script:capturedCtsW.Cancel() } catch { $disposedW = ($_.Exception.InnerException -is [System.ObjectDisposedException]) }
Test-Assert $disposedW "the Cts was disposed via the finally block despite the throw happening before the old try's own opening brace"
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
