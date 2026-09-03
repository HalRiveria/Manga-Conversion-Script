<#
.SYNOPSIS
    Standalone test harness for Modules\ImageConversionPipeline.ps1.

.DESCRIPTION
    Like ZipPipeline.Harness.ps1, this dot-sources the REAL already-built
    dependency modules - FileDeletion.ps1, AbortPipeline.ps1,
    LeafDirectoryDiscovery.ps1, CleanConsoleRendering.ps1, and Logging.ps1
    - since this is an orchestration-tier module. $CjxlExe/$MagickExe are
    real (if fake) compiled executables, not mocks - Convert-ImageBatch
    spawns actual OS processes via System.Diagnostics.Process, so a fake
    process is what's actually exercised, not a stand-in for the process
    layer itself.

    The fake cjxl.exe decides success/failure by sniffing the SOURCE
    file's own text content (case-sensitive "FAIL_CJXL" marker) - lets
    each scenario control per-image outcomes just by what it writes into
    the fake source files, without any harness-side process mocking.

    Scenarios focus on what this session's rework actually changed: the
    two-tier series/chapter walk (New-SeriesProvider + Get-SeriesChapters,
    replacing the old -PerFolderBatching toggle), CCR event emission, the
    -PostChapterCallback shape, the Register-AbortCancellationSource fix,
    and the chapter/conversion-coverage decoupling fix (both real bugs
    found in an Opus review pass over the first version of this rework -
    see ImageConversionPipeline.ps1's header and CHANGELOG.md).
    Convert-ImageBatch (PART 1) itself is exercised as a dependency
    throughout, but its own edge cases (WebP transcode, ICC-strip retry,
    animated-WebP detection) predate this session and aren't the focus
    here.

    Register-/Unregister-AbortCancellationSource and Test-AbortSignal are
    wrapped with call-tracking spies (defined after dot-sourcing
    AbortPipeline.ps1, calling straight through to the real originals) so
    Scenario H can prove the actual registration/cancellation mechanics
    fired, and fire a real abort deterministically mid-batch via a call-
    count trigger instead of a wall-clock race - the earlier version of
    this scenario fired the abort before the call even started, so it
    never actually exercised Convert-ImageBatch's own abort path at all.

.EXAMPLE
    .\Modules\_Harness\ImageConversionPipeline.Harness.ps1
#>

$ErrorActionPreference = "Stop"

$modulesDir = Join-Path $PSScriptRoot ".."
. (Join-Path $modulesDir "FileDeletion.ps1")
. (Join-Path $modulesDir "AbortPipeline.ps1")
. (Join-Path $modulesDir "LeafDirectoryDiscovery.ps1")
. (Join-Path $modulesDir "CleanConsoleRendering.ps1")
. (Join-Path $modulesDir "Logging.ps1")
. (Join-Path $modulesDir "AnimatedConversionPipeline.ps1")
. (Join-Path $modulesDir "ImageConversionPipeline.ps1")

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
    $script:completeChapterProgressCalls.Clear()
}

# ------------------------------------------------------------------
#  Spy wrappers around AbortPipeline.ps1's real functions - redefining
#  them here (after dot-sourcing it) still wins for every later call in
#  this shared script scope, and each wrapper still calls straight
#  through to the real original via a captured reference to it, so the
#  real registry/abort mechanics are never bypassed. Used by Scenario H
#  to prove Register-/Unregister-AbortCancellationSource actually get
#  called with THIS pipeline's own CTS (not just that the registry ends
#  up empty either way - see the finding this replaced), and to fire a
#  real abort deterministically mid-batch instead of only before the
#  call starts.
# ------------------------------------------------------------------
$script:registerCtsCalls          = [System.Collections.Generic.List[System.Threading.CancellationTokenSource]]::new()
$script:unregisterCtsCalls        = [System.Collections.Generic.List[System.Threading.CancellationTokenSource]]::new()
$script:unregisterCtsWasCancelled = [System.Collections.Generic.List[bool]]::new()
$script:testAbortSignalCallCount  = 0
$script:testAbortSignalTriggerAt  = -1   # set to a call number to flip AbortRequested on that call; -1 disables

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
    # Capture cancellation state HERE, not after the call returns - the
    # module's own finally block disposes $Cts right after this call, and
    # .Token on an already-disposed CancellationTokenSource comes back as
    # $null in this environment (verified live) rather than throwing, so
    # checking it post-hoc would silently prove nothing.
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

# Spy for the -ZipStepCallback merge scenarios (Q onward) - same
# call-straight-through-to-the-real-one pattern as the abort spies above.
# Records every Status/Detail Complete-ChapterProgress is actually called
# with, so a scenario can prove the merge happened in ONE call rather than
# two, without needing to inspect CCR's internal state directly.
$script:completeChapterProgressCalls = [System.Collections.Generic.List[hashtable]]::new()
$originalCompleteChapterProgress = ${function:Complete-ChapterProgress}
function Complete-ChapterProgress {
    param([string]$SeriesName, [string]$ChapterName, [string]$Status, [string]$Detail = $null)
    $script:completeChapterProgressCalls.Add(@{ SeriesName = $SeriesName; ChapterName = $ChapterName; Status = $Status; Detail = $Detail })
    & $originalCompleteChapterProgress -SeriesName $SeriesName -ChapterName $ChapterName -Status $Status -Detail $Detail
}

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("icp-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray
Write-Host ""

Initialize-FileDeletion -PermanentDelete $true   # scratch content - keeps the real Recycle Bin clean across many runs
Initialize-LogPaths -TargetPath $scratchDir -FullLogging $false -ScriptDir $scratchDir

function New-Dir {
    param([string]$RelativePath)
    $path = Join-Path $scratchDir $RelativePath
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}
function New-FakeImage {
    param([string]$DirPath, [string]$Name, [bool]$Fail = $false, [bool]$FailPartial = $false, [int]$SleepMs = 0)
    $path = Join-Path $DirPath $Name
    $content = if ($FailPartial) { "FAIL_CJXL_PARTIAL" } elseif ($Fail) { "FAIL_CJXL" } elseif ($SleepMs -gt 0) { "SLEEP_MS:" + $SleepMs } else { "fake source pixels" }
    [System.IO.File]::WriteAllText($path, $content)
    return $path
}

# ------------------------------------------------------------------
#  Fake cjxl.exe: reads the source file's text; "FAIL_CJXL" -> exit 1,
#  "SLEEP_MS:<n>" -> real Thread.Sleep(n) before succeeding (lets a
#  scenario keep a real OS process genuinely in-flight long enough to
#  land an abort mid-batch, deterministically, without racing a real
#  wall-clock timer), anything else -> write non-zero-byte output and
#  exit 0. Ignores all cjxl-style flags after the two path args.
# ------------------------------------------------------------------
$fakeCjxlSource = @'
using System;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;
class Program {
    static int Main(string[] args) {
        string src = args[0];
        string dst = args[1];
        if (!File.Exists(src)) {
            // Real cjxl.exe fails outright on a missing input file - this
            // matters for the ICC-strip retry test: a prior bug deleted
            // the retry's own input PNG before it could be used, and a
            // fake that quietly treats "missing" as "succeeded" would mask
            // that bug entirely instead of catching it.
            Console.Error.WriteLine("cannot open input file: " + src);
            return 1;
        }
        string content = File.ReadAllText(src);
        if (content.Contains("FAIL_CJXL_PARTIAL")) {
            // Simulates a real crash/disk-full mid-write: cjxl DOES write
            // some non-zero-byte output to dst before exiting non-zero -
            // proves the caller cleans up a partial .jxl on ordinary
            // failure, not just on a force-killed process.
            File.WriteAllText(dst, "partial-corrupt-jxl-bytes");
            Console.Error.WriteLine("simulated cjxl crash after partial write");
            return 1;
        }
        if (content.Contains("FAIL_CJXL")) {
            Console.Error.WriteLine("simulated cjxl failure");
            return 1;
        }
        if (content.Contains("ICC_MISMATCH") || content.Contains("ICC_UNFIXABLE")) {
            Console.Error.WriteLine("Getting pixel data failed (simulated embedded ICC profile mismatch)");
            return 1;
        }
        Match m = Regex.Match(content, "SLEEP_MS:(\\d+)");
        if (m.Success) {
            Thread.Sleep(int.Parse(m.Groups[1].Value));
        }
        Match pm = Regex.Match(content, "PARTIAL_THEN_SLEEP:(\\d+)");
        if (pm.Success) {
            // Simulates a real cjxl that has already flushed a partial
            // output file mid-encode and is still genuinely running - lets
            // a test force-kill it (via the dispatch-loop's own outer
            // catch) WHILE a partial .jxl is already sitting on disk, to
            // prove that catch cleans it up rather than leaving a
            // truncated-but-non-zero-byte .jxl behind (a future stale-
            // source trap - see this file's own header, Scenario B2).
            File.WriteAllText(dst, "partial-in-flight-bytes");
            Thread.Sleep(int.Parse(pm.Groups[1].Value));
            return 0;
        }
        if (content.Contains("STDOUT_MARKER")) {
            // Real cjxl writes progress info to stdout - normally empty
            // here, so Complete-ImageConversionJob's own "cjxl stdout for"
            // Write-Log call (gated on -DoFullLogging) never fires. This
            // marker lets a test force that specific, UNGUARDED Write-Log
            // call to actually run (and, for that test, throw).
            Console.WriteLine("simulated cjxl progress output");
        }
        if (content.Contains("ARGS_MARKER")) {
            // Lets a test read back the exact arguments this fake was
            // actually invoked with (2026-09-02, recurring-bug-pattern
            // coverage - see Scenario AI below) - e.g. proving a real
            // --quality=<N> value was received, not just that SOME .jxl
            // got written.
            File.WriteAllText(dst, "ARGS:" + string.Join(" ", args));
            return 0;
        }
        File.WriteAllText(dst, "fake-jxl-bytes");
        return 0;
    }
}
'@
$fakeCjxlExe = Join-Path $scratchDir "fake_cjxl.exe"
Add-Type -TypeDefinition $fakeCjxlSource -Language CSharp -OutputAssembly $fakeCjxlExe -OutputType ConsoleApplication

# ------------------------------------------------------------------
#  Fake magick.exe (added 2026-08-28, for the new static-AVIF path) -
#  same technique as AnimatedConversionPipeline.Harness.ps1's own fake:
#   - "identify -format "%n" <path>": reads FRAMES:<n> from the input's
#     content (default 1 - static); FAIL_IDENTIFY -> exit 1 (an
#     inspect-failure fake_cjxl.exe never even sees).
#   - otherwise (the real "<src>[0]" "<dst>" transcode call): copies the
#     SOURCE's own text content into the destination PNG verbatim, so
#     fake_cjxl.exe's own FAIL_CJXL sniff still works correctly on
#     whatever ends up in the temp PNG it's actually handed.
# ------------------------------------------------------------------
$fakeMagickSource = @'
using System;
using System.IO;
using System.Text.RegularExpressions;
class Program {
    static int Main(string[] args) {
        if (args.Length > 0 && args[0] == "identify") {
            string path = args[args.Length - 1];
            // Logs each identify call's target path (gated on an env var so
            // unrelated scenarios pay nothing) - lets a test count how many
            // times an identify spawn actually happened, proving the
            // 2026-08-31 cancellation-check fix (an already-cancelled
            // -CancelToken must short-circuit the collision-guard pre-pass
            // BEFORE it ever spawns magick for AVIF classification).
            string identifyLog = Environment.GetEnvironmentVariable("HARNESS_IDENTIFY_LOG");
            if (identifyLog != null) {
                using (var mtx = new System.Threading.Mutex(false, "ICPHarnessIdentifyLogMutex")) {
                    mtx.WaitOne();
                    try { File.AppendAllText(identifyLog, path + Environment.NewLine); } finally { mtx.ReleaseMutex(); }
                }
            }
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

        string srcArg = args[0];
        string src = srcArg.EndsWith("[0]") ? srcArg.Substring(0, srcArg.Length - 3) : srcArg;
        string dst = args[args.Length - 1];
        string srcContent = File.Exists(src) ? File.ReadAllText(src) : "";
        if (srcContent.Contains("HUGE_STDERR")) {
            // Writes a large stderr dump (well over a typical OS pipe
            // buffer) BEFORE doing anything else - proves the 2026-08-31
            // redirect-deadlock fix (both streams now drained
            // asynchronously before WaitForExit in both
            // Invoke-IccStripRetryOrFail and the WebP/AVIF-to-PNG
            // pre-conversion call) actually prevents a hang, rather than
            // just reproducing the already-fixed Test-AvifAnimated case
            // in the sibling module.
            string line = new string('X', 200) + Environment.NewLine;
            for (int i = 0; i < 2000; i++) { Console.Error.Write(line); }
        }
        if (srcContent.Contains("FAIL_MAGICK")) {
            Console.Error.WriteLine("simulated magick pre-conversion failure");
            return 1;
        }
        // Invoke-IccStripRetryOrFail's own call shape: "<src>" -strip
        // "<dst>" - -colorspace Gray deliberately removed (2026-08-31,
        // project owner's own decision: never force-convert color data) -
        // actually remove the ICC_MISMATCH marker here, simulating a real
        // profile strip, so a retry against the resulting PNG behaves
        // differently from the original (fake cjxl.exe's own ICC_MISMATCH
        // sniff no longer fires on it).
        bool isIccStrip = args.Length == 3 && args[1] == "-strip";
        string outContent = isIccStrip ? srcContent.Replace("ICC_MISMATCH", "") : srcContent;
        File.WriteAllText(dst, outContent);
        return 0;
    }
}
'@
$fakeMagickExe = Join-Path $scratchDir "fake_magick.exe"
Add-Type -TypeDefinition $fakeMagickSource -Language CSharp -OutputAssembly $fakeMagickExe -OutputType ConsoleApplication

function New-FakeAvif {
    param([string]$DirPath, [string]$Name, [string]$Content = "FRAMES:1")
    $path = Join-Path $DirPath $Name
    [System.IO.File]::WriteAllText($path, $Content)
    return $path
}

Write-Host ""

# ==============================================================================
#  Scenario A0 (2026-08-31 reuse fix): Get-LooseImageExtensions is the
#  single source of truth this module and Controller.ps1 both use as a
#  default parameter value, instead of 5 independently hardcoded copies of
#  the same 7-element array. AnimatedConversionPipeline.ps1 keeps its own
#  literal on purpose (module-independence reasons, see that file's own
#  comment) - checked here too, so a future edit to one and not the other
#  is caught immediately instead of silently drifting.
# ==============================================================================
Write-Host "=== Scenario A0: Get-LooseImageExtensions is the shared source of truth ===" -ForegroundColor Cyan
# 2026-09-02: ".gif"/".bmp"/".heic"/".heif" added (project owner's own
# decision - these formats should count as unconverted content, not be
# silently invisible to chapter discovery).
$expectedExtA0 = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif", ".gif", ".bmp", ".heic", ".heif")
$actualExtA0 = @(Get-LooseImageExtensions)
Test-Assert (($actualExtA0 -join ",") -eq ($expectedExtA0 -join ",")) ("Get-LooseImageExtensions returns the expected 11-element list in order (got: " + ($actualExtA0 -join ",") + ")")

$animatedPipelinePath = Join-Path $PSScriptRoot "..\AnimatedConversionPipeline.ps1"
$animatedPipelineSource = Get-Content -LiteralPath $animatedPipelinePath -Raw
$expectedLiteral = '@(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif", ".gif", ".bmp", ".heic", ".heif")'
Test-Assert ($animatedPipelineSource.Contains($expectedLiteral)) "AnimatedConversionPipeline.ps1's own deliberately-kept-literal still matches the canonical list exactly (not drifted)"
Write-Host ""

# ==============================================================================
#  Scenario A: multi-series, multi-chapter conversion end to end - correct
#  per-chapter batching, source deletion on success, SeriesCount/ChapterCount.
# ==============================================================================
Write-Host "=== Scenario A: multi-series/multi-chapter conversion ===" -ForegroundColor Cyan
$rootA = New-Dir "scenario-a"
$s1c1A = New-Dir "scenario-a\Series One\Chapter 1"
$s1c2A = New-Dir "scenario-a\Series One\Chapter 2"
$s2c1A = New-Dir "scenario-a\Series Two\Chapter 1"
New-FakeImage -DirPath $s1c1A -Name "page1.jpg" | Out-Null
New-FakeImage -DirPath $s1c1A -Name "page2.jpg" | Out-Null
New-FakeImage -DirPath $s1c2A -Name "page1.jpg" | Out-Null
New-FakeImage -DirPath $s2c1A -Name "page1.jpg" | Out-Null

$totalsA = Invoke-LooseImageConversionPipeline -Path $rootA -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsA.SeriesCount -eq 2) ("2 series found (got " + $totalsA.SeriesCount + ")")
Test-Assert ($totalsA.ChapterCount -eq 3) ("3 chapters found (got " + $totalsA.ChapterCount + ")")
Test-Assert ($totalsA.ConvertedSuccess -eq 4) ("4 images converted (got " + $totalsA.ConvertedSuccess + ")")
Test-Assert ($totalsA.ConvertedFail -eq 0) "no conversion failures"
Test-Assert ($totalsA.DeletedSuccess -eq 4) ("4 sources deleted (got " + $totalsA.DeletedSuccess + ")")
Test-Assert (-not (Test-Path -LiteralPath (Join-Path $s1c1A "page1.jpg"))) "Series One/Chapter 1 page1 source gone"
Test-Assert (Test-Path -LiteralPath (Join-Path $s1c1A "page1.jxl")) "Series One/Chapter 1 page1.jxl created"
Test-Assert (Test-Path -LiteralPath (Join-Path $s2c1A "page1.jxl")) "Series Two/Chapter 1 page1.jxl created"
Test-Assert (-not $totalsA.Aborted) "not marked aborted"

# ==============================================================================
#  Scenario B: a chapter with a real conversion failure counts correctly and
#  does not get its source deleted.
# ==============================================================================
Write-Host "=== Scenario B: conversion failure ===" -ForegroundColor Cyan
$rootB = New-Dir "scenario-b"
$chB = New-Dir "scenario-b\Series\Chapter 1"
New-FakeImage -DirPath $chB -Name "good.jpg" | Out-Null
New-FakeImage -DirPath $chB -Name "bad.jpg" -Fail $true | Out-Null

$totalsB = Invoke-LooseImageConversionPipeline -Path $rootB -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsB.ConvertedSuccess -eq 1) ("1 converted (got " + $totalsB.ConvertedSuccess + ")")
Test-Assert ($totalsB.ConvertedFail -eq 1) ("1 failed (got " + $totalsB.ConvertedFail + ")")
Test-Assert (Test-Path -LiteralPath (Join-Path $chB "bad.jpg")) "failed source left in place, not deleted"
Test-Assert (-not (Test-Path -LiteralPath (Join-Path $chB "good.jpg"))) "successful source deleted"

# ==============================================================================
#  Scenario B2 (2026-08-31 fix): a cjxl process that writes a PARTIAL/corrupt
#  .jxl before exiting non-zero (simulating a crash or disk-full mid-write) -
#  Complete-ImageConversionJob's normal failure path used to leave that
#  partial .jxl on disk (only the force-kill path cleaned one up). Left
#  behind, it's a non-zero-byte file newer than its source, so the NEXT run's
#  Get-LooseImageCandidates would misclassify the source as a stale leftover
#  and permanently delete it - losing the real source over a garbage output.
# ==============================================================================
Write-Host "=== Scenario B2: a partial .jxl from a mid-write crash is cleaned up, not left as a stale-source trap ===" -ForegroundColor Cyan
$rootB2 = New-Dir "scenario-b2"
$chB2 = New-Dir "scenario-b2\Series\Chapter 1"
New-FakeImage -DirPath $chB2 -Name "crashed.jpg" -FailPartial $true | Out-Null

$totalsB2 = Invoke-LooseImageConversionPipeline -Path $rootB2 -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsB2.ConvertedFail -eq 1) ("1 failed (got " + $totalsB2.ConvertedFail + ")")
Test-Assert (Test-Path -LiteralPath (Join-Path $chB2 "crashed.jpg")) "failed source left in place, not deleted"
Test-Assert (-not (Test-Path -LiteralPath (Join-Path $chB2 "crashed.jxl"))) "the partial/corrupt .jxl left by the crashed process was cleaned up, not left behind as a future stale-source trap"

# ==============================================================================
#  Scenario C: stale-source cleanup - a source with an existing non-zero .jxl
#  counterpart is deleted without ever being handed to cjxl, per-series.
# ==============================================================================
Write-Host "=== Scenario C: stale source cleanup ===" -ForegroundColor Cyan
$rootC = New-Dir "scenario-c"
$chC = New-Dir "scenario-c\Series\Chapter 1"
$staleSrcC = New-FakeImage -DirPath $chC -Name "already_done.jpg"
[System.IO.File]::WriteAllText((Join-Path $chC "already_done.jxl"), "real jxl bytes")
# Force the source's timestamp strictly OLDER than the .jxl's (2026-08-31
# fix, caught by verifying this same day's /code-review 4th pass) - both
# writes above happen back-to-back and can land in the same filesystem
# timestamp tick, making $img.LastWriteTimeUtc -ge $jxlItem.LastWriteTimeUtc
# true on EQUALITY and misrouting this scenario into NamingCollisions
# instead of StaleSources - an intermittent (~1-in-6) harness flake, not a
# real product bug. Same technique Scenario C2b already uses below.
[System.IO.File]::SetLastWriteTimeUtc($staleSrcC, ([DateTime]::UtcNow.AddMinutes(-5)))

$totalsC = Invoke-LooseImageConversionPipeline -Path $rootC -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsC.StaleCleanedSuccess -eq 1) ("1 stale source cleaned (got " + $totalsC.StaleCleanedSuccess + ")")
Test-Assert ($totalsC.ConvertedSuccess -eq 0) "nothing sent to cjxl for the stale source"
Test-Assert (-not (Test-Path -LiteralPath $staleSrcC)) "stale source deleted"

# ==============================================================================
#  Scenario C2 (2026-08-31, corrected same day): a same-basename extension
#  collision - the .jxl exists FIRST (from a real, earlier conversion of a
#  NOW-GONE source), then a genuinely different, unconverted file with the
#  same basename shows up LATER (e.g. photo.jpg converted+deleted, then an
#  unrelated photo.png added).
#
#  Before the FIRST fix, this was silently deleted as "stale" without ever
#  being converted, purely because the basenames matched (loses the new,
#  unconverted source - Recycle-Bin-recoverable at least).
#
#  The FIRST fix's own attempt (routing a newer source to NeedsConversion)
#  was ITSELF wrong, caught by a same-day /code-review: converting
#  photo.png writes cjxl's output to the SAME photo.jxl path, silently
#  OVERWRITING the pre-existing .jxl - the only remaining copy of the
#  ORIGINAL photo.jpg's content, permanently destroyed by a plain file
#  write (not even Recycle-Bin-recoverable). Worse than the bug it
#  replaced.
#
#  The actual fix: neither action is safe without knowing which file
#  produced the existing .jxl, so a newer same-basename source is now
#  excluded from BOTH lists entirely - not converted (would overwrite),
#  not deleted (would lose an unconverted source) - logged as an Error and
#  left for the user to resolve by hand.
# ==============================================================================
Write-Host "=== Scenario C2: a newer same-basename file is left untouched (neither converted nor deleted) ===" -ForegroundColor Cyan
$chC2 = New-Dir "scenario-c2\Series\Chapter 1"
$originalJxlBytesC2 = "real jxl bytes from a since-deleted photo.jpg"
[System.IO.File]::WriteAllText((Join-Path $chC2 "photo.jxl"), $originalJxlBytesC2)
Start-Sleep -Milliseconds 50
$collidingSrcC2 = New-FakeImage -DirPath $chC2 -Name "photo.png"

$totalsC2 = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-c2") -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsC2.ConvertedSuccess -eq 0 -and $totalsC2.ConvertedFail -eq 0) ("the colliding source was neither converted nor counted as a failure - just left alone (got ConvertedSuccess=" + $totalsC2.ConvertedSuccess + ", ConvertedFail=" + $totalsC2.ConvertedFail + ")")
Test-Assert ($totalsC2.StaleCleanedSuccess -eq 0) "not counted as a stale-source cleanup either - not deleted"
Test-Assert (Test-Path -LiteralPath $collidingSrcC2) "the colliding source survives untouched on disk - not deleted"
Test-Assert ((Get-Content -LiteralPath (Join-Path $chC2 "photo.jxl") -Raw) -eq $originalJxlBytesC2) "the pre-existing .jxl survives byte-for-byte untouched - NOT silently overwritten by a conversion of the unrelated colliding source"
# 2026-08-31 fix (from a second same-day /code-review): the collision used
# to be completely invisible outside its own log line - not counted
# anywhere, and (since it's this chapter's ONLY loose image) the chapter's
# ChapterResult stayed $null, mapping to a clean Success with no zip-block
# at all. Get-LooseImageCandidates now returns it via NamingCollisions,
# counted into InspectFailedCount and used to force IsZippable=$false.
Test-Assert ($totalsC2.InspectFailedCount -eq 1) ("the naming collision is now counted in InspectFailedCount, not invisible (got " + $totalsC2.InspectFailedCount + ")")

$zipCallsC2 = [System.Collections.Generic.List[hashtable]]::new()
$zipCallbackC2 = { param($payload) $zipCallsC2.Add($payload); return @{ Status = "Success"; Detail = $null } }
$null = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-c2") -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false -ZipStepCallback $zipCallbackC2
Test-Assert ($zipCallsC2.Count -eq 0) "the chapter holding the naming collision is never treated as zippable - ZipStepCallback (mode 8's own zip-step wiring) is never invoked for it"

# ==============================================================================
#  Scenario C2b (2026-08-31 fix, found by a second same-day /code-review):
#  same collision shape as C2, but with the colliding source's timestamp
#  EXACTLY EQUAL to the pre-existing .jxl's, not newer. The comparison was
#  strict -gt, so an equal timestamp fell through to the stale branch and
#  got permanently deleted without ever being converted - a real risk here
#  since ZIP extraction commonly produces coarse or identical timestamps.
#  Fixed by changing -gt to -ge.
# ==============================================================================
Write-Host "=== Scenario C2b: a same-basename file with an EQUAL timestamp is also left untouched, not deleted as stale ===" -ForegroundColor Cyan
$chC2b = New-Dir "scenario-c2b\Series\Chapter 1"
$originalJxlBytesC2b = "real jxl bytes from a since-deleted photo.jpg"
[System.IO.File]::WriteAllText((Join-Path $chC2b "photo.jxl"), $originalJxlBytesC2b)
$jxlTimeC2b = (Get-Item -LiteralPath (Join-Path $chC2b "photo.jxl")).LastWriteTimeUtc
$collidingSrcC2b = New-FakeImage -DirPath $chC2b -Name "photo.png"
[System.IO.File]::SetLastWriteTimeUtc($collidingSrcC2b, $jxlTimeC2b)   # forced EXACTLY equal, not just close

$totalsC2b = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-c2b") -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsC2b.ConvertedSuccess -eq 0 -and $totalsC2b.ConvertedFail -eq 0) ("the colliding source was neither converted nor counted as a failure (got ConvertedSuccess=" + $totalsC2b.ConvertedSuccess + ", ConvertedFail=" + $totalsC2b.ConvertedFail + ")")
Test-Assert ($totalsC2b.StaleCleanedSuccess -eq 0) "not counted as a stale-source cleanup either - not deleted despite the equal timestamp"
Test-Assert (Test-Path -LiteralPath $collidingSrcC2b) "the colliding source survives untouched on disk - not deleted"

# ==============================================================================
#  Scenario D: a series with zero qualifying chapters is counted and skipped
#  cleanly (no crash, no chapters processed).
# ==============================================================================
Write-Host "=== Scenario D: series with zero chapters ===" -ForegroundColor Cyan
$rootD = New-Dir "scenario-d"
New-Dir "scenario-d\Empty Series" | Out-Null   # no qualifying files inside - not a real chapter

$totalsD = Invoke-LooseImageConversionPipeline -Path $rootD -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsD.SeriesCount -eq 1) "the empty series was still walked"
Test-Assert ($totalsD.ChapterCount -eq 0) "zero chapters counted"

# ==============================================================================
#  Scenario D2 (2026-09-01 live-shakedown fix): a chapter that finished
#  converting on an EARLIER run - source images already deleted, only a
#  .jxl left, zero loose files of any kind. Confirmed live against this
#  project's real cjxl.exe: with -FolderQualifyingExtensions still
#  defaulting to the bare Get-LooseImageExtensions() list (no ".jxl", this
#  engine's own output extension), Get-SeriesChapters never finds this
#  chapter at all - it's silently invisible to every later mode-1 run,
#  permanently, with no warning logged (same root cause as
#  Controller.ps1's Full Pipeline - see that file's own matching fix).
#  Fixed by adding ".jxl" to this function's own -FolderQualifyingExtensions
#  default.
# ==============================================================================
Write-Host "=== Scenario D2: a chapter with ONLY already-converted .jxl (zero loose files) is still discovered ===" -ForegroundColor Cyan
$rootD2 = New-Dir "scenario-d2"
$chD2 = New-Dir "scenario-d2\Series\Chapter 1"
[System.IO.File]::WriteAllText((Join-Path $chD2 "page1.jxl"), "already converted on a prior run - source already deleted, nothing loose left")

$zipCallsD2 = [System.Collections.Generic.List[hashtable]]::new()
$zipStepD2 = { param($Info) $zipCallsD2.Add($Info); return @{ Status = "Success"; Detail = "1 entry" } }.GetNewClosure()

$totalsD2 = Invoke-LooseImageConversionPipeline -Path $rootD2 -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false -ZipStepCallback $zipStepD2

Test-Assert ($totalsD2.ChapterCount -eq 1) ("the all-.jxl chapter was discovered at all (got ChapterCount=" + $totalsD2.ChapterCount + ")")
Test-Assert ($totalsD2.ConvertedSuccess -eq 0 -and $totalsD2.ConvertedFail -eq 0) "sanity check: nothing needed converting"
Test-Assert ($zipCallsD2.Count -eq 1) ("the zip callback fired for the all-.jxl chapter - the exact discovery-level gap this fix closes (got " + $zipCallsD2.Count + ")")
Write-Host ""

# ==============================================================================
#  Scenario E: -PostChapterCallback fires once per chapter with the documented
#  shape (SeriesName/ChapterName/Dir/ChapterResult) - this is mode 2's hook.
# ==============================================================================
Write-Host "=== Scenario E: PostChapterCallback shape ===" -ForegroundColor Cyan
$rootE = New-Dir "scenario-e"
$chE = New-Dir "scenario-e\My Series\Ch 1"
New-FakeImage -DirPath $chE -Name "page1.jpg" | Out-Null

$callbackCallsE = [System.Collections.Generic.List[hashtable]]::new()
$cbE = {
    param($Info)
    $callbackCallsE.Add($Info)
}.GetNewClosure()

$null = Invoke-LooseImageConversionPipeline -Path $rootE -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false -PostChapterCallback $cbE

Test-Assert ($callbackCallsE.Count -eq 1) ("callback fired once (got " + $callbackCallsE.Count + ")")
Test-Assert ($callbackCallsE[0].SeriesName -eq "My Series") "callback saw the right SeriesName"
Test-Assert ($callbackCallsE[0].ChapterName -eq "Ch 1") "callback saw the right ChapterName"
Test-Assert ($callbackCallsE[0].Dir.FullName -eq $chE) "callback saw the right Dir"
Test-Assert ($callbackCallsE[0].ChapterResult.ConvertedCount -eq 1) "callback saw the real ChapterResult"
Test-Assert ($callbackCallsE[0].IsZippable -eq $true) "a real (non-extra) chapter is marked IsZippable"
Test-Assert ($callbackCallsE[0].ZipOut -eq (Join-Path (Split-Path $chE -Parent) "Ch 1.zip")) "a real chapter carries its ZipOut path"

# ==============================================================================
#  Scenario F: Get-ChapterProgressStatus mapping, tested directly (unit-level,
#  not through the full pipeline).
# ==============================================================================
Write-Host "=== Scenario F: Get-ChapterProgressStatus mapping ===" -ForegroundColor Cyan
$statusNull, $detailNull = Get-ChapterProgressStatus -ChapterResult $null
Test-Assert ($statusNull -eq "Success" -and $null -eq $detailNull) "null ChapterResult (nothing to convert) -> Success, no detail"

$statusOk, $detailOk = Get-ChapterProgressStatus -ChapterResult @{ FailedCount = 0; ForceKilledCount = 0; DeleteFailedCount = 0; SkippedCount = 0 }
Test-Assert ($statusOk -eq "Success" -and $null -eq $detailOk) "clean result -> Success, no detail"

$statusWarn, $detailWarn = Get-ChapterProgressStatus -ChapterResult @{ FailedCount = 0; ForceKilledCount = 0; DeleteFailedCount = 0; SkippedCount = 2 }
Test-Assert ($statusWarn -eq "Warning" -and $detailWarn -match "2 image") "skipped-only result -> Warning with a detail string"

$statusErr, $detailErr = Get-ChapterProgressStatus -ChapterResult @{ FailedCount = 1; ForceKilledCount = 1; DeleteFailedCount = 0; SkippedCount = 0 }
Test-Assert ($statusErr -eq "Error" -and $detailErr -match "1 failed" -and $detailErr -match "1 force-stopped") "failed+force-killed result -> Error with both reasons in detail"

# 2026-08-31 fix: InspectFailedCount is now Error-tier - previously not
# checked here AT ALL, so it fell through to a silent Success, letting the
# zip gate proceed with a raw, completely unconverted AVIF in the chapter.
$statusInspErr, $detailInspErr = Get-ChapterProgressStatus -ChapterResult @{ FailedCount = 0; ForceKilledCount = 0; DeleteFailedCount = 0; SkippedCount = 0; InspectFailedCount = 1 }
Test-Assert ($statusInspErr -eq "Error" -and $detailInspErr -match "1 inspect failure") "InspectFailedCount alone is Error tier, not silently Success - it means a file was left completely unconverted"

# ==============================================================================
#  Scenario G: CCR wiring - real CleanConsoleRendering.ps1 functions actually
#  get called and reach the expected end state (series frozen, chapter
#  statuses reflected) when the toggle is on.
# ==============================================================================
Write-Host "=== Scenario G: CCR event emission ===" -ForegroundColor Cyan
$rootG = New-Dir "scenario-g"
$chG1 = New-Dir "scenario-g\CCR Series\Chapter 1"
$chG2 = New-Dir "scenario-g\CCR Series\Chapter 2"
New-FakeImage -DirPath $chG1 -Name "page1.jpg" | Out-Null
New-FakeImage -DirPath $chG2 -Name "page1.jpg" -Fail $true | Out-Null

$script:CleanConsoleOutputEnabled = $true
try {
    $totalsG = Invoke-LooseImageConversionPipeline -Path $rootG -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false
} finally {
    $script:CleanConsoleOutputEnabled = $false
}

Test-Assert ($script:ccrActiveSeries.Count -eq 0) "series resolved and left the active registry once both chapters completed"
Test-Assert ($totalsG.ConvertedSuccess -eq 1 -and $totalsG.ConvertedFail -eq 1) "conversion counts still correct with CCR on"

# ==============================================================================
#  Scenario G2 (2026-09-03 fix, real bug, live-reported, same fix as
#  Controller.ps1's Invoke-FullPipeline): a series with zero qualifying
#  chapters (e.g. already fully converted and zipped - nothing left but a
#  .cbz and an info file, no chapter subfolders at all) must never call
#  Start-SeriesProgress. Before this fix it did - Start-SeriesProgress's
#  own docstring says a 0-chapter call "is rendered as an immediately-
#  frozen '0/0' line" via Update-CleanConsoleDisplay, exactly the unwanted
#  line the project owner asked to have suppressed entirely.
#  $script:ccrActiveSeries is NOT the right observable (a 0-chapter call
#  never enters it either way, by that same existing design) - spies
#  directly on Start-SeriesProgress instead.
# ==============================================================================
Write-Host "=== Scenario G2: a series with zero qualifying chapters never calls Start-SeriesProgress ===" -ForegroundColor Cyan
$rootG2 = New-Dir "scenario-g2"
$emptySeriesG2 = New-Dir "scenario-g2\Empty Series"
[System.IO.File]::WriteAllText((Join-Path $emptySeriesG2 "already-zipped.cbz"), "fake zip content")
[System.IO.File]::WriteAllText((Join-Path $emptySeriesG2 "info.txt"), "not an image, not a chapter")

$script:startSeriesProgressCallsG2 = New-Object System.Collections.Generic.List[string]
$realStartSeriesProgressG2 = ${function:Start-SeriesProgress}
function Start-SeriesProgress {
    param([string]$SeriesName, [int]$TotalChapters)
    $script:startSeriesProgressCallsG2.Add($SeriesName + ":" + $TotalChapters)
}

$script:CleanConsoleOutputEnabled = $true
try {
    $totalsG2 = Invoke-LooseImageConversionPipeline -Path $rootG2 -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false
} finally {
    $script:CleanConsoleOutputEnabled = $false
    ${function:Start-SeriesProgress} = $realStartSeriesProgressG2
}

Test-Assert ($script:startSeriesProgressCallsG2.Count -eq 0) ("Start-SeriesProgress was never called for the zero-chapter series (got: " + ($script:startSeriesProgressCallsG2 -join ", ") + ")")
Write-Host ""

# ==============================================================================
#  Scenario H: the abort-registration fix, exercised for real mid-batch, not
#  just before the call starts. Uses the Register-/Unregister-
#  AbortCancellationSource spies to prove THIS pipeline's own CTS was the one
#  actually registered/unregistered, and a deterministic Test-AbortSignal
#  trigger (not a real wall-clock race) to flip the abort while a real fake-
#  cjxl OS process is genuinely still running - proving both this session's
#  registration fix AND the $abortPoll closure fix (LastCompletedPaths).
# ==============================================================================
Write-Host "=== Scenario H: abort registration actually wired up ===" -ForegroundColor Cyan
Reset-AbortState
$rootH = New-Dir "scenario-h"
$chH1 = New-Dir "scenario-h\Series\Chapter 1"
New-FakeImage -DirPath $chH1 -Name "page1.jpg" -SleepMs 300 | Out-Null

# Call sequence for this exact scenario (single series, single chapter, single
# image): call 1 = the series while-loop's top-of-loop Test-AbortSignal, call
# 2 = the chapter foreach-loop's top-of-loop check, call 3 = Convert-
# ImageBatch's first AbortPollCallback (before the job is even dispatched),
# call 4 = its second AbortPollCallback - by then the fake cjxl process IS
# dispatched and still sleeping, so $running is non-empty and the closure's
# InFlightPaths actually has this image's path in it. Trigger there.
$script:testAbortSignalTriggerAt = 4

$totalsH = Invoke-LooseImageConversionPipeline -Path $rootH -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false -AbortTimeoutSeconds 5

Test-Assert ($script:registerCtsCalls.Count -eq 1) ("Register-AbortCancellationSource called exactly once (got " + $script:registerCtsCalls.Count + ")")
Test-Assert ($script:unregisterCtsCalls.Count -eq 1) ("Unregister-AbortCancellationSource called exactly once (got " + $script:unregisterCtsCalls.Count + ")")
Test-Assert ([object]::ReferenceEquals($script:registerCtsCalls[0], $script:unregisterCtsCalls[0])) "the registered and unregistered CTS are the SAME object"
Test-Assert ($script:unregisterCtsWasCancelled[0]) "that CTS's token actually got cancelled by the real abort (captured just before the module disposed it)"
Test-Assert ($totalsH.Aborted) "pipeline reports Aborted"
Test-Assert ($totalsH.LastCompletedPaths.Count -eq 1 -and $totalsH.LastCompletedPaths[0] -match "page1\.jpg") ("the in-flight image was recorded into LastCompletedPaths (got " + $totalsH.LastCompletedPaths.Count + " entr(y/ies)) - proves the closure fix, not just the registration fix")
Test-Assert ($totalsH.ConvertedSuccess -eq 1) "the in-flight job still completed successfully via the abort-drain wait, rather than being force-killed"
Test-Assert ($script:abortCancellationSources.Count -eq 0) "registry is empty again after the call (finally block ran)"
Reset-AbortState

# ==============================================================================
#  Scenario H2: the immediate pre-fetch abort path - abort already set before
#  New-SeriesProvider even returns its first series. Scenario H's rewrite
#  moved coverage to a real mid-batch abort but dropped this simpler case
#  entirely; restoring it here rather than folding it back into H, since H's
#  own call-count trigger is specifically tuned for the mid-batch timing.
# ==============================================================================
Write-Host "=== Scenario H2: abort detected before the first series is even fetched ===" -ForegroundColor Cyan
$rootH2 = New-Dir "scenario-h2"
$chH2 = New-Dir "scenario-h2\Series\Chapter 1"
New-FakeImage -DirPath $chH2 -Name "page1.jpg" | Out-Null

[ConsoleCtrl]::AbortRequested = $true
$totalsH2 = Invoke-LooseImageConversionPipeline -Path $rootH2 -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsH2.Aborted) "pipeline reports Aborted"
Test-Assert ($totalsH2.SeriesCount -eq 0) "aborted before even fetching the first series"
Test-Assert ($script:abortCancellationSources.Count -eq 0) "registry is empty again after the call (finally block ran)"
Reset-AbortState

# The spies are only needed for Scenarios H/H2 above - restore the real
# originals now (matching the capture/redefine/restore idiom
# FileDeletion.Harness.ps1/Logging.Harness.ps1 already use for the same
# need) so every scenario below runs against AbortPipeline.ps1's real,
# unwrapped functions like the rest of this suite.
${function:Register-AbortCancellationSource}   = $originalRegisterAbortCts
${function:Unregister-AbortCancellationSource} = $originalUnregisterAbortCts
${function:Test-AbortSignal}                   = $originalTestAbortSignal

# ==============================================================================
#  Scenario I: KnownZipPaths exclusion still works, scoped per-series now
#  instead of once for the whole library.
# ==============================================================================
Write-Host "=== Scenario I: KnownZipPaths exclusion, per-series ===" -ForegroundColor Cyan
$rootI = New-Dir "scenario-i"
$chI = New-Dir "scenario-i\Series\Chapter 1"
New-FakeImage -DirPath $chI -Name "page1.jpg" | Out-Null
$zipStagingI = New-Dir "scenario-i\Series\Staged"
New-FakeImage -DirPath $zipStagingI -Name "excluded.jpg" | Out-Null
$fakeZipPathI = Join-Path (Split-Path $zipStagingI -Parent) "Staged.zip"

$totalsI = Invoke-LooseImageConversionPipeline -Path $rootI -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false -KnownZipPaths @($fakeZipPathI)

Test-Assert (Test-Path -LiteralPath (Join-Path $zipStagingI "excluded.jpg")) "file under the ZIP staging dir was left untouched"
Test-Assert ($totalsI.ConvertedSuccess -eq 1) "only the non-staging chapter's image was converted"

# ==============================================================================
#  Scenario J: a chapter dir excluded by Get-SeriesChapters's former-container
#  guard (a stray .zip sitting directly inside it) must still get its
#  unconverted images converted - conversion coverage is NOT gated behind
#  zip-domain "is this worth re-zipping" guards. Real bug found in review;
#  see ImageConversionPipeline.ps1's header/CHANGELOG.md.
# ==============================================================================
Write-Host "=== Scenario J: former-container guard doesn't drop conversion coverage ===" -ForegroundColor Cyan
$rootJ = New-Dir "scenario-j"
$chJ = New-Dir "scenario-j\Series\Chapter 1"
New-FakeImage -DirPath $chJ -Name "page1.jpg" | Out-Null
[System.IO.File]::WriteAllText((Join-Path $chJ "unrelated_leftover.zip"), "not a real zip, just needs to exist")

$totalsJ = Invoke-LooseImageConversionPipeline -Path $rootJ -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsJ.ConvertedSuccess -eq 1) ("image converted despite the stray .zip (got ConvertedSuccess=" + $totalsJ.ConvertedSuccess + ")")
Test-Assert ($totalsJ.ChapterCount -eq 1) "the excluded dir still counted as a chapter-equivalent entry"

# ==============================================================================
#  Scenario K: a chapter dir excluded by Get-SeriesChapters's zip-staleness
#  guard (an up-to-date same-named sibling .zip) must still convert a
#  genuinely new, unconverted image inside it - the zip's staleness says
#  nothing about whether THIS loose image has been converted yet.
# ==============================================================================
Write-Host "=== Scenario K: zip-staleness guard doesn't drop conversion coverage ===" -ForegroundColor Cyan
$rootK = New-Dir "scenario-k"
$seriesDirK = New-Dir "scenario-k\Series"
$chK = New-Dir "scenario-k\Series\Chapter 1"
$imgK = New-FakeImage -DirPath $chK -Name "page1.jpg"
$zipK = Join-Path $seriesDirK "Chapter 1.zip"
[System.IO.File]::WriteAllText($zipK, "not a real zip, just needs to exist")
$pastUtc = [DateTime]::UtcNow.AddMinutes(-10)
[System.IO.File]::SetLastWriteTimeUtc($imgK, $pastUtc)
[System.IO.File]::SetLastWriteTimeUtc($zipK, [DateTime]::UtcNow)   # newer than the image -> "up to date" per the staleness guard

$totalsK = Invoke-LooseImageConversionPipeline -Path $rootK -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsK.ConvertedSuccess -eq 1) ("image converted despite the up-to-date sibling zip (got ConvertedSuccess=" + $totalsK.ConvertedSuccess + ")")

# ==============================================================================
#  Scenario L: a loose image sitting directly in the SERIES root (no chapter
#  subfolder at all) is never returned by Get-SeriesChapters (it only scans
#  SUBdirectories of the series path) - must still be converted, not silently
#  dropped.
# ==============================================================================
Write-Host "=== Scenario L: series-root loose image (no chapter subfolder) ===" -ForegroundColor Cyan
$rootL = New-Dir "scenario-l"
$seriesDirL = New-Dir "scenario-l\Lone Series"
New-FakeImage -DirPath $seriesDirL -Name "cover.jpg" | Out-Null

$totalsL = Invoke-LooseImageConversionPipeline -Path $rootL -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsL.ConvertedSuccess -eq 1) ("series-root image converted (got ConvertedSuccess=" + $totalsL.ConvertedSuccess + ")")
Test-Assert (Test-Path -LiteralPath (Join-Path $seriesDirL "cover.jxl")) "cover.jxl created directly in the series root"

# ==============================================================================
#  Scenario M: an "extra" merged-in directory is never treated as zippable -
#  a real second-review finding. Without IsZippable=$false, a caller wiring
#  -PostChapterCallback to ZipPipeline.ps1's Invoke-LooseFolderZip (exactly as
#  this function's own docs describe for mode 2) would wrapper-zip the whole
#  series once its real chapters are already zipped and deleted - precisely
#  what the former-container guard exists to prevent, reached through the
#  merge's back door.
# ==============================================================================
Write-Host "=== Scenario M: extra entries are never marked zippable ===" -ForegroundColor Cyan
$rootM = New-Dir "scenario-m"
$seriesDirM = New-Dir "scenario-m\Series"
$ch1M = New-Dir "scenario-m\Series\Ch1"
$ch2M = New-Dir "scenario-m\Series\Ch2"
New-FakeImage -DirPath $ch1M -Name "p1.jpg" | Out-Null
New-FakeImage -DirPath $ch2M -Name "p1.jpg" | Out-Null
New-FakeImage -DirPath $seriesDirM -Name "cover.jpg" | Out-Null   # the "extra" - no chapter subfolder

$callbackInfoM = [System.Collections.Generic.List[hashtable]]::new()
$cbM = { param($Info) $callbackInfoM.Add($Info) }.GetNewClosure()

$totalsM = Invoke-LooseImageConversionPipeline -Path $rootM -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false -PostChapterCallback $cbM

Test-Assert ($totalsM.ConvertedSuccess -eq 3) ("all 3 images converted, including the extra (got " + $totalsM.ConvertedSuccess + ")")
$realCallbacksM  = @($callbackInfoM | Where-Object { $_.ChapterName -ne "Series" })
$extraCallbackM  = @($callbackInfoM | Where-Object { $_.ChapterName -eq "Series" })
Test-Assert ($realCallbacksM.Count -eq 2 -and ($realCallbacksM | ForEach-Object { $_.IsZippable }) -notcontains $false) "both real chapters are marked IsZippable"
Test-Assert ($extraCallbackM.Count -eq 1) "the series-root extra fired its own callback"
Test-Assert ($extraCallbackM[0].IsZippable -eq $false -and $null -eq $extraCallbackM[0].ZipOut) "the extra is marked IsZippable=false with no ZipOut - a caller must not zip it"

# ==============================================================================
#  Scenario N: -FolderExcludeStagingDirs must still exclude a staging directory
#  even when it holds an unconverted image the merge would otherwise re-add -
#  the merge was bypassing this exclusion entirely (a real second-review
#  finding), independent of -KnownZipPaths.
# ==============================================================================
Write-Host "=== Scenario N: FolderExcludeStagingDirs still applies to extras ===" -ForegroundColor Cyan
$rootN = New-Dir "scenario-n"
$chN = New-Dir "scenario-n\Series\Ch1"
New-FakeImage -DirPath $chN -Name "p1.jpg" | Out-Null
$stagingN = New-Dir "scenario-n\Series\Staging"
New-FakeImage -DirPath $stagingN -Name "excluded.jpg" | Out-Null

$excludeSetN = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$null = $excludeSetN.Add($stagingN)

$totalsN = Invoke-LooseImageConversionPipeline -Path $rootN -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false -FolderExcludeStagingDirs $excludeSetN

Test-Assert ($totalsN.ChapterCount -eq 1) ("staging dir was NOT folded in as an extra chapter (got ChapterCount=" + $totalsN.ChapterCount + ")")
Test-Assert ($totalsN.ConvertedSuccess -eq 1) "only Ch1's image was converted"
Test-Assert (Test-Path -LiteralPath (Join-Path $stagingN "excluded.jpg")) "the staging dir's image was left untouched"

# ==============================================================================
#  Scenario O: -FolderExcludeStagingDirs must also protect a STALE source (one
#  with an existing non-zero .jxl counterpart) from Remove-StaleLooseSources -
#  a real second-review finding distinct from Scenario N (which only covers
#  the NeedsConversion/extras path). Get-LooseImageCandidates previously had
#  no concept of -FolderExcludeStagingDirs at all, so a stale source sitting in
#  a directory the caller explicitly asked to leave alone (e.g. mode 4's
#  in-progress extraction area) would get deleted anyway.
# ==============================================================================
Write-Host "=== Scenario O: FolderExcludeStagingDirs protects stale sources too ===" -ForegroundColor Cyan
$rootO = New-Dir "scenario-o"
$chO = New-Dir "scenario-o\Series\Ch1"
New-FakeImage -DirPath $chO -Name "p1.jpg" | Out-Null
$stagingO = New-Dir "scenario-o\Series\Staging"
$staleSrcO = New-FakeImage -DirPath $stagingO -Name "already_done.jpg"
[System.IO.File]::WriteAllText((Join-Path $stagingO "already_done.jxl"), "real jxl bytes")

$excludeSetO = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$null = $excludeSetO.Add($stagingO)

$totalsO = Invoke-LooseImageConversionPipeline -Path $rootO -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false -FolderExcludeStagingDirs $excludeSetO

Test-Assert ($totalsO.StaleCleanedSuccess -eq 0) ("the staging dir's stale source was NOT cleaned up (got StaleCleanedSuccess=" + $totalsO.StaleCleanedSuccess + ")")
Test-Assert (Test-Path -LiteralPath $staleSrcO) "the staging dir's stale source file still exists"
Write-Host ""

# ==============================================================================
#  Scenario P: -SharedBudget (Controller.ps1's Full Pipeline concurrency
#  design, 2026-08-28) - a SemaphoreSlim with FEWER slots than
#  -MaxCjxlProcs actually constrains dispatch to the semaphore's count
#  (proven by observing it get fully exhausted - CurrentCount reaching 0 -
#  mid-run via -AbortPollCallback, not just inferred from final totals,
#  which would look identical whether gating worked or not), and every
#  slot is released again (no leak) once the batch completes.
# ==============================================================================
Write-Host "=== Scenario P: -SharedBudget gates dispatch and never leaks ===" -ForegroundColor Cyan
$chP = New-Dir "scenario-p\Series\Chapter 1"
$filesP = 1..5 | ForEach-Object { Get-Item -LiteralPath (New-FakeImage -DirPath $chP -Name ("budget" + $_ + ".jpg") -SleepMs 150) }
$budgetP = [System.Threading.SemaphoreSlim]::new(2, 2)
$script:budgetSnapshotsP = [System.Collections.Generic.List[int]]::new()
$pollP = { param($inFlight) $script:budgetSnapshotsP.Add($budgetP.CurrentCount) }

$resultP = Convert-ImageBatch -ImageFiles $filesP -CjxlExe $fakeCjxlExe -MaxCjxlProcs 5 -DoFullLogging $false `
    -CancelToken ([System.Threading.CancellationToken]::None) -SharedBudget $budgetP -AbortPollCallback $pollP

Test-Assert ($resultP.ConvertedCount -eq 5 -and $resultP.FailedCount -eq 0) "all 5 converted correctly through the shared budget"
Test-Assert (($script:budgetSnapshotsP | Where-Object { $_ -eq 0 }).Count -gt 0) "the 2-slot budget was actually driven to 0 at some point - proves dispatch was really gated to 2 concurrent, not just passed through unused (MaxCjxlProcs=5 would have let all 5 start at once otherwise)"
Test-Assert ($budgetP.CurrentCount -eq 2) "the budget is back to its full initial count after the call - no leaked slots"
# 2026-08-31 fix: -AbortPollCallback fires once per outer dispatch-loop
# pass, so its call count is a direct proxy for how many passes the loop
# actually made. -MaxCjxlProcs 5 with a 2-slot SharedBudget is exactly the
# shape that busy-spun before this fix (the old sleep-gate never saw
# running.Count reach MaxCjxlProcs, since the budget - not MaxCjxlProcs -
# was the real ceiling) - a prior version made tens of thousands of passes
# in the same wall-clock window; a real 50ms sleep between passes bounds
# this to roughly (total wall time / 50ms), generously under 100 even with
# scheduler jitter.
Test-Assert ($script:budgetSnapshotsP.Count -lt 100) ("the dispatch loop slept between passes instead of busy-spinning (got " + $script:budgetSnapshotsP.Count + " passes for ~450ms of simulated work)")
$budgetP.Dispose()
Write-Host ""

# ==============================================================================
#  Scenario Q: static AVIF converts through the WebP-style temp-PNG detour,
#  2026-08-28 (Todo.md's decided static-AVIF-always-converts change).
# ==============================================================================
Write-Host "=== Scenario Q: static AVIF converts to .jxl, same detour as WebP ===" -ForegroundColor Cyan
$chQ = New-Dir "scenario-q\Series\Chapter 1"
$avifQ = New-FakeAvif -DirPath $chQ -Name "cover.avif" -Content "FRAMES:1"

$totalsQ = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-q") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsQ.ConvertedSuccess -eq 1 -and $totalsQ.ConvertedFail -eq 0) ("static AVIF converted successfully (got ConvertedSuccess=" + $totalsQ.ConvertedSuccess + ", ConvertedFail=" + $totalsQ.ConvertedFail + ")")
Test-Assert (-not (Test-Path -LiteralPath $avifQ)) "the static AVIF source was deleted after a successful conversion"
Test-Assert (Test-Path -LiteralPath (Join-Path $chQ "cover.jxl")) "cover.jxl was created"
Write-Host ""

# ==============================================================================
#  Scenario R: animated AVIF is left untouched here - its own conversion
#  pipeline (AnimatedConversionPipeline.ps1) owns it, not this one.
# ==============================================================================
Write-Host "=== Scenario R: animated AVIF is skipped, not converted ===" -ForegroundColor Cyan
$chR = New-Dir "scenario-r\Series\Chapter 1"
$avifR = New-FakeAvif -DirPath $chR -Name "animated.avif" -Content "FRAMES:12"

$totalsR = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-r") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsR.ConvertedSkipped -eq 1 -and $totalsR.ConvertedSuccess -eq 0) ("animated AVIF counted as skipped, not converted (got ConvertedSkipped=" + $totalsR.ConvertedSkipped + ", ConvertedSuccess=" + $totalsR.ConvertedSuccess + ")")
Test-Assert (Test-Path -LiteralPath $avifR) "the animated AVIF source was left untouched, not deleted"
Write-Host ""

# ==============================================================================
#  Scenario Q2 (2026-09-02, project owner's own decision): .gif/.bmp/.heic/
#  .heif now count as unconverted content, same as any other extension on
#  Get-LooseImageExtensions()'s own list. .bmp/.heic/.heif actually
#  convert, through the same magick temp-PNG detour WebP/AVIF already use
#  (confirmed live - cjxl.exe cannot read any of the three directly, but
#  `magick -list format` confirms BMP is read/write and HEIC/HEIF are
#  read-only, both sufficient for a one-way transcode). .gif is always
#  SKIPPED, never actually converted (project owner's own real-world
#  experience - GIF conversion caused real problems in older script
#  versions; live-reproduced the same day, an animated GIF reaching the
#  ICC-strip retry path left orphaned numbered temp PNGs behind that no
#  cleanup regex in this project catches).
#
#  Convert-ImageBatch's own skip-check is exercised DIRECTLY here, not
#  through Invoke-LooseImageConversionPipeline (2026-09-02 follow-up fix):
#  Get-LooseImageCandidates now excludes .gif entirely (Scenario AC2,
#  above) so it never reaches Convert-ImageBatch through either real
#  caller (this one, or Controller.ps1's Full Pipeline) any more - the
#  check below is a defensive backstop for anything that calls
#  Convert-ImageBatch directly, not a live production code path.
# ==============================================================================
Write-Host "=== Scenario Q2: .gif is always skipped, never actually converted ===" -ForegroundColor Cyan
$chQ2 = New-Dir "scenario-q2\Series\Chapter 1"
$gifQ2 = New-FakeImage -DirPath $chQ2 -Name "cover.gif"

$resultQ2 = Convert-ImageBatch -ImageFiles @(Get-Item -LiteralPath $gifQ2) -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -DoFullLogging $false -CancelToken ([System.Threading.CancellationToken]::None)

Test-Assert ($resultQ2.SkippedCount -eq 1 -and $resultQ2.ConvertedCount -eq 0 -and $resultQ2.FailedCount -eq 0) ("GIF counted as skipped, not converted or failed, with no -MagickExe configured at all (got SkippedCount=" + $resultQ2.SkippedCount + ", ConvertedCount=" + $resultQ2.ConvertedCount + ", FailedCount=" + $resultQ2.FailedCount + ")")
Test-Assert (Test-Path -LiteralPath $gifQ2) "the GIF source was left untouched, not deleted"
Test-Assert (-not (Test-Path -LiteralPath (Join-Path $chQ2 "cover.jxl"))) "no .jxl was created for a skipped GIF"

# Confirms Get-LooseImageCandidates's own exclusion (not this function's
# check) is what actually governs the real, end-to-end pipeline now -
# a chapter with only a .gif reports zero candidates of any kind and
# never even reaches Convert-ImageBatch.
$totalsQ2 = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-q2") -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false
Test-Assert ($totalsQ2.ConvertedSuccess -eq 0 -and $totalsQ2.ConvertedFail -eq 0 -and $totalsQ2.ConvertedSkipped -eq 0) ("through the real end-to-end pipeline, the .gif is invisible before ever reaching Convert-ImageBatch - not skipped there, just never a candidate at all (got Success=" + $totalsQ2.ConvertedSuccess + ", Fail=" + $totalsQ2.ConvertedFail + ", Skipped=" + $totalsQ2.ConvertedSkipped + ")")
Test-Assert (Test-Path -LiteralPath $gifQ2) "the GIF source is still untouched after the real end-to-end pipeline run too"
Write-Host ""

Write-Host "=== Scenario Q3: .bmp/.heic/.heif each convert through the WebP-style temp-PNG detour ===" -ForegroundColor Cyan
foreach ($extQ3 in @("bmp", "heic", "heif")) {
    $chQ3 = New-Dir ("scenario-q3-" + $extQ3 + "\Series\Chapter 1")
    $srcQ3 = New-FakeImage -DirPath $chQ3 -Name ("cover." + $extQ3)

    $totalsQ3 = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir ("scenario-q3-" + $extQ3)) -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -FullLogging $false

    Test-Assert ($totalsQ3.ConvertedSuccess -eq 1 -and $totalsQ3.ConvertedFail -eq 0) ("." + $extQ3 + " converted successfully through the magick detour (got ConvertedSuccess=" + $totalsQ3.ConvertedSuccess + ", ConvertedFail=" + $totalsQ3.ConvertedFail + ")")
    Test-Assert (-not (Test-Path -LiteralPath $srcQ3)) ("the ." + $extQ3 + " source was deleted after a successful conversion")
    Test-Assert (Test-Path -LiteralPath (Join-Path $chQ3 "cover.jxl")) ("cover.jxl was created for ." + $extQ3)
}
Write-Host ""

Write-Host "=== Scenario Q4: .bmp/.heic/.heif fail cleanly (not silently) when -MagickExe isn't configured ===" -ForegroundColor Cyan
$chQ4 = New-Dir "scenario-q4\Series\Chapter 1"
$srcQ4 = New-FakeImage -DirPath $chQ4 -Name "cover.heic"

$totalsQ4 = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-q4") -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsQ4.ConvertedFail -eq 1 -and $totalsQ4.ConvertedSuccess -eq 0) ("HEIC fails cleanly with no -MagickExe, same as WebP/AVIF already did (got ConvertedFail=" + $totalsQ4.ConvertedFail + ", ConvertedSuccess=" + $totalsQ4.ConvertedSuccess + ")")
Test-Assert (Test-Path -LiteralPath $srcQ4) "the HEIC source survives untouched when it couldn't be converted"
Write-Host ""

# ==============================================================================
#  Scenario S: a real Test-AvifAnimated failure (couldn't determine frame
#  count) is its own InspectFailedCount outcome - NOT folded into
#  FailedCount, matching Convert-AnimatedBatch's identical failure mode.
# ==============================================================================
Write-Host "=== Scenario S: AVIF inspect-failure counts separately from FailedCount ===" -ForegroundColor Cyan
$chS = New-Dir "scenario-s\Series\Chapter 1"
$avifS = New-FakeAvif -DirPath $chS -Name "corrupt.avif" -Content "FAIL_IDENTIFY"

$totalsS = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-s") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsS.InspectFailedCount -eq 1) ("inspect-failure counted (got InspectFailedCount=" + $totalsS.InspectFailedCount + ")")
Test-Assert ($totalsS.ConvertedFail -eq 0) "NOT folded into ConvertedFail - a different kind of outcome"
Test-Assert (Test-Path -LiteralPath $avifS) "the source was left untouched - never got far enough to convert or delete"
Write-Host ""

# ==============================================================================
#  Scenario T: -ZipStepCallback (mode 8's decided CCR-fold, 2026-08-28) -
#  fires only when IsZippable and conversion didn't already hit an Error,
#  and its outcome is folded into the SAME Complete-ChapterProgress call
#  conversion already makes, not a second one.
# ==============================================================================
Write-Host "=== Scenario T: -ZipStepCallback fires and folds into ONE CCR transition ===" -ForegroundColor Cyan
Reset-AbortState
$rootT = New-Dir "scenario-t"
$chT = New-Dir "scenario-t\Series\Chapter 1"
New-FakeImage -DirPath $chT -Name "page1.jpg" | Out-Null

$zipCallsT = [System.Collections.Generic.List[hashtable]]::new()
$zipStepT = {
    param($Info)
    $zipCallsT.Add($Info)
    return @{ Status = "Success"; Detail = "1 entry" }
}.GetNewClosure()

$script:CleanConsoleOutputEnabled = $true
try {
    $totalsT = Invoke-LooseImageConversionPipeline -Path $rootT -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false -ZipStepCallback $zipStepT
} finally {
    $script:CleanConsoleOutputEnabled = $false
}

Test-Assert ($zipCallsT.Count -eq 1) ("the zip callback fired exactly once (got " + $zipCallsT.Count + ")")
Test-Assert ($zipCallsT[0].ChapterResult.ConvertedCount -eq 1) "the zip callback saw the real ChapterResult, not a stub"
Test-Assert ($script:completeChapterProgressCalls.Count -eq 1) ("exactly ONE Complete-ChapterProgress call for the chapter - not a separate second transition for the zip step (got " + $script:completeChapterProgressCalls.Count + ")")
Test-Assert ($script:completeChapterProgressCalls[0].Status -eq "Success") "merged Status is Success (both halves clean)"
Test-Assert ($script:completeChapterProgressCalls[0].Detail -eq "Convert: OK | Zip: 1 entry") ("merged Detail concatenates both halves (got '" + $script:completeChapterProgressCalls[0].Detail + "')")
Reset-AbortState
Write-Host ""

# ==============================================================================
#  Scenario U: -ZipStepCallback is NOT called for a non-zippable "extra"
#  entry, and NOT called when conversion itself already hit an Error - both
#  gates live in this module, not the callback (see .PARAMETER ZipStepCallback).
# ==============================================================================
Write-Host "=== Scenario U: -ZipStepCallback gated on IsZippable and non-Error ===" -ForegroundColor Cyan
$rootU = New-Dir "scenario-u"
# An "extra" entry: an image sitting directly in the series root, no real
# chapter subfolder - never zippable, same construction as Scenario L.
New-FakeImage -DirPath $rootU -Name "loose.jpg" | Out-Null
$chU2 = New-Dir "scenario-u\Series\Chapter 1"
New-FakeImage -DirPath $chU2 -Name "bad.jpg" -Fail $true | Out-Null

$zipCallsU = [System.Collections.Generic.List[hashtable]]::new()
$zipStepU = { param($Info) $zipCallsU.Add($Info); return @{ Status = "Success"; Detail = $null } }.GetNewClosure()

$totalsU = Invoke-LooseImageConversionPipeline -Path $rootU -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false -ZipStepCallback $zipStepU

Test-Assert ($zipCallsU.Count -eq 0) ("the zip callback never fired - neither entry qualified (extra=not zippable, Chapter 1=conversion Error) (got " + $zipCallsU.Count + " call(s))")
Write-Host ""

# ==============================================================================
#  Scenario V: $null -ZipStepCallback (mode 2's existing default) leaves
#  Get-ChapterProgressStatus's own Detail format completely unchanged - no
#  "Convert: ..." prefix ever appears unless a real callback actually ran.
# ==============================================================================
Write-Host "=== Scenario V: default (no callback) Detail format is untouched ===" -ForegroundColor Cyan
Reset-AbortState
$chV = New-Dir "scenario-v\Series\Chapter 1"
New-FakeImage -DirPath $chV -Name "skip-me.webp" -Fail $false | Out-Null   # no MagickExe supplied -> FAILED, not skipped/converted; simplest deterministic non-clean case without needing magick
$script:CleanConsoleOutputEnabled = $true
try {
    $null = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-v") -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false
} finally {
    $script:CleanConsoleOutputEnabled = $false
}
Test-Assert ($script:completeChapterProgressCalls.Count -eq 1 -and $script:completeChapterProgressCalls[0].Detail -notmatch "^Convert: ") ("Detail has no 'Convert: ' prefix when no callback ran (got '" + $script:completeChapterProgressCalls[0].Detail + "')")
Reset-AbortState
Write-Host ""

# ==============================================================================
#  Scenario W: the ICC-strip retry (2026-08-31 fix) - fake cjxl.exe fails
#  the FIRST attempt with the exact "Getting pixel data failed" signature
#  (ICC_MISMATCH marker), fake magick.exe's ICC-strip command actually
#  removes that marker into a real temp PNG, and the RETRY against that
#  PNG must succeed - proving the retry's own input file survives long
#  enough to be used. A prior version deleted that file immediately after
#  enqueuing the retry job, so the retry always failed instead.
# ==============================================================================
Write-Host "=== Scenario W: ICC-strip retry succeeds using its own (surviving) stripped PNG ===" -ForegroundColor Cyan
$chW = New-Dir "scenario-w\Series\Chapter 1"
$imgW = Join-Path $chW "cover.jpg"
[System.IO.File]::WriteAllText($imgW, "ICC_MISMATCH")

$totalsW = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-w") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsW.ConvertedSuccess -eq 1 -and $totalsW.ConvertedFail -eq 0) ("the ICC-mismatched image converted successfully via the retry, not counted as a failure (got ConvertedSuccess=" + $totalsW.ConvertedSuccess + ", ConvertedFail=" + $totalsW.ConvertedFail + ")")
Test-Assert (Test-Path -LiteralPath (Join-Path $chW "cover.jxl")) "cover.jxl was created by the retry"
Test-Assert (-not (Test-Path -LiteralPath $imgW)) "the original source was deleted after the retry's successful conversion"
$leftoverTempPngsW = @(Get-ChildItem -LiteralPath $chW -Filter "*_tmp_iccstrip.png" -File -ErrorAction SilentlyContinue)
Test-Assert (@($leftoverTempPngsW).Count -eq 0) "the stripped temp PNG was cleaned up after the retry finished, not left behind"
Write-Host ""

# ==============================================================================
#  Scenario X: an ICC-strip retry that ALSO hits the same failure signature
#  falls through to a normal failure instead of retrying forever (2026-08-31
#  fix) - without the -not $Job.IccRetried guard, Complete-ImageConversionJob
#  would strip-and-retry the same source indefinitely.
# ==============================================================================
Write-Host "=== Scenario X: a retry that fails the same way does NOT retry again ===" -ForegroundColor Cyan
$chX = New-Dir "scenario-x\Series\Chapter 1"
$imgX = Join-Path $chX "stubborn.jpg"
# ICC_UNFIXABLE (distinct from ICC_MISMATCH) trips fake cjxl.exe's same
# failure sniff, but fake magick.exe's ICC-strip step only ever removes
# the literal "ICC_MISMATCH" text - it never touches this marker, so the
# retry's own stripped PNG still contains it and fails the same way,
# simulating a source the strip genuinely can't fix.
[System.IO.File]::WriteAllText($imgX, "ICC_UNFIXABLE")

$totalsX = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-x") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsX.ConvertedFail -eq 1 -and $totalsX.ConvertedSuccess -eq 0) ("a source that still fails after stripping is counted as ONE failure, not retried forever (got ConvertedFail=" + $totalsX.ConvertedFail + ", ConvertedSuccess=" + $totalsX.ConvertedSuccess + ")")
Write-Host ""

# ==============================================================================
#  Scenario X2 (2026-08-31 fix, caught by a same-day /code-review of the
#  original ICC-retry fix): the ICC-strip retry must be reused directly
#  for a .webp/.avif source, not re-run through the webp/avif-to-PNG
#  pre-conversion branch a second time. $j.SrcPath still ends in .webp
#  even for the retry job, so before this fix the isWebp/isAvif check
#  fired again on redispatch, redoing an entirely separate, NON-stripped
#  pre-conversion from the (untouched) original .webp - overwriting
#  TempPng, orphaning the real stripped PNG Invoke-IccStripRetryOrFail
#  produced, and failing the retry the same way every time since the
#  fresh pre-conversion was never actually ICC-stripped.
# ==============================================================================
Write-Host "=== Scenario X2: ICC-strip retry succeeds for a .webp source (reuses the stripped PNG, not a fresh pre-conversion) ===" -ForegroundColor Cyan
$chX2 = New-Dir "scenario-x2\Series\Chapter 1"
$imgX2 = Join-Path $chX2 "cover.webp"
[System.IO.File]::WriteAllText($imgX2, "ICC_MISMATCH")

$totalsX2 = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-x2") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsX2.ConvertedSuccess -eq 1 -and $totalsX2.ConvertedFail -eq 0) ("the .webp source converted successfully via the retry, not counted as a failure (got ConvertedSuccess=" + $totalsX2.ConvertedSuccess + ", ConvertedFail=" + $totalsX2.ConvertedFail + ")")
Test-Assert (Test-Path -LiteralPath (Join-Path $chX2 "cover.jxl")) "cover.jxl was created by the retry"
$leftoverTempPngsX2 = @(Get-ChildItem -LiteralPath $chX2 -Filter "*_tmp_*.png" -File -ErrorAction SilentlyContinue)
Test-Assert (@($leftoverTempPngsX2).Count -eq 0) ("no orphaned temp PNG (neither the ICC-strip PNG nor a redundant webp2png one) was left behind (found: " + (($leftoverTempPngsX2 | ForEach-Object { $_.Name }) -join ', ') + ")")
Write-Host ""

# ==============================================================================
#  Scenario X3 (2026-08-31 fix, found by a THIRD same-day /code-review
#  pass): both the ICC-strip magick call (Invoke-IccStripRetryOrFail) and
#  the WebP/AVIF-to-PNG pre-conversion magick call had both stdout/stderr
#  redirected but never read - the same Process redirect deadlock species
#  already found and fixed in AnimatedConversionPipeline.ps1's
#  Test-AvifAnimated, just never applied here. A huge stderr dump (well
#  over a typical OS pipe buffer) proves neither call site hangs anymore.
# ==============================================================================
Write-Host "=== Scenario X3: a huge stderr dump does not hang the ICC-strip magick call ===" -ForegroundColor Cyan
$imgX3 = Join-Path (New-Dir "scenario-x3\Series\Chapter 1") "cover.jpg"
[System.IO.File]::WriteAllText($imgX3, "ICC_MISMATCH`nHUGE_STDERR")
$swX3 = [System.Diagnostics.Stopwatch]::StartNew()
$totalsX3 = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-x3") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -FullLogging $false
$swX3.Stop()
Test-Assert ($totalsX3.ConvertedSuccess -eq 1 -and $totalsX3.ConvertedFail -eq 0) "the ICC-strip retry still succeeded despite the huge stderr dump"
Test-Assert ($swX3.Elapsed.TotalSeconds -lt 15) ("returned promptly instead of deadlocking on the ICC-strip magick call (took " + [int]$swX3.Elapsed.TotalSeconds + "s)")
Write-Host ""

Write-Host "=== Scenario X4: a huge stderr dump does not hang the WebP-to-PNG pre-conversion magick call ===" -ForegroundColor Cyan
$imgX4 = Join-Path (New-Dir "scenario-x4\Series\Chapter 1") "cover.webp"
[System.IO.File]::WriteAllText($imgX4, "HUGE_STDERR")
$swX4 = [System.Diagnostics.Stopwatch]::StartNew()
$totalsX4 = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-x4") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -FullLogging $false
$swX4.Stop()
Test-Assert ($totalsX4.ConvertedSuccess -eq 1 -and $totalsX4.ConvertedFail -eq 0) "the WebP pre-conversion still succeeded despite the huge stderr dump"
Test-Assert ($swX4.Elapsed.TotalSeconds -lt 15) ("returned promptly instead of deadlocking on the WebP-to-PNG magick call (took " + [int]$swX4.Elapsed.TotalSeconds + "s)")
Write-Host ""

# ==============================================================================
#  Scenario Y (2026-08-31 fix): Process.Start() throwing (a stale/bad
#  -CjxlExe path) used to hang the dispatch loop indefinitely - a raw .NET
#  exception there isn't terminating in this scriptblock, so execution
#  continued with $j.Proc left $null, and $null.HasExited never becomes
#  true, so that job sat in $running forever. Confirmed live before the fix
#  (this exact repro hung past 40s with no progress). Now wrapped in
#  try/catch, so it must fail fast and cleanly instead.
# ==============================================================================
Write-Host "=== Scenario Y: a bad -CjxlExe path fails fast instead of hanging the dispatch loop ===" -ForegroundColor Cyan
$chY = New-Dir "scenario-y\Series\Chapter 1"
New-FakeImage -DirPath $chY -Name "page1.jpg" | Out-Null
$badCjxlExeY = Join-Path $scratchDir "does_not_exist_cjxl.exe"

$swY = [System.Diagnostics.Stopwatch]::StartNew()
$totalsY = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-y") -CjxlExe $badCjxlExeY -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -FullLogging $false
$swY.Stop()

Test-Assert ($swY.Elapsed.TotalSeconds -lt 15) ("returned promptly instead of hanging (took " + [int]$swY.Elapsed.TotalSeconds + "s)")
Test-Assert ($totalsY.ConvertedFail -eq 1 -and $totalsY.ConvertedSuccess -eq 0) ("the failed process start is counted as a real failure, not silently dropped (got ConvertedFail=" + $totalsY.ConvertedFail + ", ConvertedSuccess=" + $totalsY.ConvertedSuccess + ")")
Write-Host ""

# ==============================================================================
#  Scenario Z (2026-08-31 fix): $looseCts's construction and
#  Register-AbortCancellationSource call were moved INSIDE the function's
#  try block (same species as ZipParallelProcessing.ps1's mutex-leak fix
#  from earlier today). Register-AbortCancellationSource is temporarily
#  replaced with a fake that captures the real $Cts (so the test can
#  inspect it afterward) and throws, simulating a real registration
#  failure. Verified via a disposed Cts's own .Cancel() throwing
#  ObjectDisposedException (wrapped by PowerShell as
#  MethodInvocationException) - proof Dispose() actually ran via the
#  finally path.
# ==============================================================================
Write-Host "=== Scenario Z: a throw during Register-AbortCancellationSource still disposes the already-constructed Cts ===" -ForegroundColor Cyan
$realRegisterFnZ = ${function:Register-AbortCancellationSource}
$script:capturedCtsZ = $null
function Register-AbortCancellationSource {
    param([System.Threading.CancellationTokenSource]$Cts)
    $script:capturedCtsZ = $Cts
    throw "simulated Register-AbortCancellationSource failure"
}
$rootZ = New-Dir "scenario-z\Series\Chapter 1"
New-FakeImage -DirPath $rootZ -Name "page1.jpg" | Out-Null
$threwZ = $false
try {
    $null = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-z") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -FullLogging $false
} catch {
    $threwZ = $true
}
${function:Register-AbortCancellationSource} = $realRegisterFnZ

Test-Assert $threwZ "the registration failure propagated out of the pipeline, not silently swallowed"
Test-Assert ($null -ne $script:capturedCtsZ) "sanity check: the fake actually captured the real Cts object before throwing"
$disposedZ = $false
try { $script:capturedCtsZ.Cancel() } catch { $disposedZ = ($_.Exception.InnerException -is [System.ObjectDisposedException]) }
Test-Assert $disposedZ "the Cts was disposed via the finally block despite the throw happening before the old try's own opening brace"
Write-Host ""

# ==============================================================================
#  Scenario AA (2026-08-31 fix, caught by a same-day /code-review 4th pass):
#  an animated AVIF/WebP sitting next to a same-basename convertible source
#  (e.g. animated "foo.avif" + static "foo.jpg") used to be misclassified as
#  a genuine output-path collision, since the collision pre-pass ran BEFORE
#  the per-job animated-skip checks and only knew extensions, not animation
#  status - both sources failed with "Resolve the name clash manually" and
#  neither the real conversion nor the animated-skip ever happened. Animation
#  classification now runs in the SAME pre-pass that builds the collision
#  count, so "foo.jpg" converts cleanly and "foo.avif" is a Warning-tier
#  skip, not an Error-tier false collision.
# ==============================================================================
Write-Host "=== Scenario AA: an animated file does not false-positive as a name clash with a same-basename convertible source ===" -ForegroundColor Cyan
$chAA = New-Dir "scenario-aa\Series\Chapter 1"
$avifAA = New-FakeAvif -DirPath $chAA -Name "foo.avif" -Content "FRAMES:12"
$jpgAA  = New-FakeImage -DirPath $chAA -Name "foo.jpg"

$totalsAA = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-aa") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsAA.ConvertedSuccess -eq 1 -and $totalsAA.ConvertedFail -eq 0) ("the static same-basename source converted cleanly, not counted as a collision failure (got ConvertedSuccess=" + $totalsAA.ConvertedSuccess + ", ConvertedFail=" + $totalsAA.ConvertedFail + ")")
Test-Assert ($totalsAA.ConvertedSkipped -eq 1) ("the animated AVIF is a Warning-tier skip, not a collision failure (got ConvertedSkipped=" + $totalsAA.ConvertedSkipped + ")")
Test-Assert (-not (Test-Path -LiteralPath $jpgAA)) "foo.jpg was deleted after a successful conversion"
Test-Assert (Test-Path -LiteralPath (Join-Path $chAA "foo.jxl")) "foo.jxl was created"
Test-Assert (Test-Path -LiteralPath $avifAA) "the animated foo.avif source was left untouched, not deleted"
Write-Host ""

# ==============================================================================
#  Scenario AB (2026-08-31 fix, caught by a same-day /code-review 4th pass):
#  an unexpected throw from INSIDE the dispatch loop (here, -AbortPollCallback
#  throwing on its second pass, once a job is genuinely in flight) used to
#  propagate straight out of Convert-ImageBatch with the still-running job's
#  process handle undisposed and its SharedBudget slot unreleased - a
#  permanent leak under Controller.ps1's Full Pipeline, where the budget is
#  shared with the animated engine. The dispatch loop's own try/catch now
#  force-kills/disposes/releases anything left in $running before rethrowing.
# ==============================================================================
Write-Host "=== Scenario AB: an unexpected throw mid-dispatch still releases the running job's process and budget slot ===" -ForegroundColor Cyan
$chAB = New-Dir "scenario-ab\Series\Chapter 1"
$fileAB = Get-Item -LiteralPath (New-FakeImage -DirPath $chAB -Name "page1.jpg" -SleepMs 300)
$budgetAB = [System.Threading.SemaphoreSlim]::new(1, 1)
$script:pollCountAB = 0
$pollAB = {
    param($inFlight)
    $script:pollCountAB++
    if ($script:pollCountAB -ge 2) { throw "simulated AbortPollCallback failure" }
}

$threwAB = $false
try {
    $null = Convert-ImageBatch -ImageFiles @($fileAB) -CjxlExe $fakeCjxlExe -MaxCjxlProcs 5 -DoFullLogging $false `
        -CancelToken ([System.Threading.CancellationToken]::None) -SharedBudget $budgetAB -AbortPollCallback $pollAB
} catch {
    $threwAB = $true
}

Test-Assert $threwAB "the injected failure propagated out of Convert-ImageBatch, not silently swallowed"
Test-Assert ($budgetAB.CurrentCount -eq 1) ("the running job's SharedBudget slot was released despite the throw (got CurrentCount=" + $budgetAB.CurrentCount + ")")
$budgetAB.Dispose()
Write-Host ""

# ==============================================================================
#  Scenario AC (2026-08-31 fix, caught by a same-day /code-review 4th pass):
#  a leaked "_tmp_*" scratch file (one whose owning cleanup path couldn't
#  run - force-killed process, locked file swallowed by a bare catch) used
#  to be indistinguishable from a real loose image at Get-LooseImageCandidates'
#  own discovery boundary, since its extension (.png/.webp) is in
#  $LooseImageExtensions - the NEXT run would convert it and leave the
#  garbage output behind permanently. Now excluded by name pattern.
# ==============================================================================
Write-Host "=== Scenario AC: orphaned _tmp_* scratch files are excluded from loose-image discovery ===" -ForegroundColor Cyan
$chAC = New-Dir "scenario-ac\Series\Chapter 1"
[System.IO.File]::WriteAllText((Join-Path $chAC "photo_tmp_iccstrip.png"), "orphaned strip scratch")
[System.IO.File]::WriteAllText((Join-Path $chAC "photo_tmp_iccstrip-0.png"), "orphaned NUMBERED strip scratch")
[System.IO.File]::WriteAllText((Join-Path $chAC "photo_tmp_webp2png.png"), "orphaned webp scratch")
[System.IO.File]::WriteAllText((Join-Path $chAC "photo_tmp_avif2png.png"), "orphaned avif scratch")
[System.IO.File]::WriteAllText((Join-Path $chAC "photo_tmp_bmp2png.png"), "orphaned bmp scratch")
[System.IO.File]::WriteAllText((Join-Path $chAC "photo_tmp_heic2png.png"), "orphaned heic scratch")
[System.IO.File]::WriteAllText((Join-Path $chAC "photo_tmp_heif2png.png"), "orphaned heif scratch")
[System.IO.File]::WriteAllText((Join-Path $chAC "photo_tmp_overwrite.webp"), "orphaned overwrite scratch")
$realAC = New-FakeImage -DirPath $chAC -Name "real.jpg"

$candidatesAC = Get-LooseImageCandidates -ScanPath (Join-Path $scratchDir "scenario-ac")

# 2026-09-02 review fix: the BMP/HEIC/HEIF scratch patterns (and the
# numbered iccstrip variant) were confirmed live to be missed by the
# pre-widening regexes here - a real "cover_tmp_bmp2png.png" was
# misclassified as a genuine NeedsConversion candidate.
Test-Assert ($candidatesAC.NeedsConversion.Count -eq 1 -and $candidatesAC.NeedsConversion[0].Name -eq "real.jpg") ("only the real loose image was returned, all 7 scratch-file patterns excluded (got " + $candidatesAC.NeedsConversion.Count + " candidate(s): " + (($candidatesAC.NeedsConversion | ForEach-Object { $_.Name }) -join ", ") + ")")
Test-Assert ($candidatesAC.StaleSources.Count -eq 0) "no scratch file was misclassified as a stale source either"
Write-Host ""

# ==============================================================================
#  Scenario AC2 (2026-09-02 review fix, live-confirmed): a never-converted
#  extension (currently just .gif - Get-NeverConvertedExtensions) must
#  NEVER be classified as a stale source, no matter its timestamp relative
#  to a same-basename .jxl. Before this fix, a chapter with "01.jpg" and
#  "01.gif" would convert "01.jpg" to "01.jxl" (deleting "01.jpg"
#  normally) and leave "01.gif" untouched with a "File left untouched"
#  promise (Convert-ImageBatch's own skip message) - but on the VERY NEXT
#  run, "01.gif" (older than the freshly-written "01.jxl") was classified
#  as StaleSources and DELETED, breaking that promise one run later.
#  Reproduced directly against Get-LooseImageCandidates with a real,
#  already-older .gif sitting next to a real .jxl.
# ==============================================================================
Write-Host "=== Scenario AC2: a never-converted extension (.gif) is never classified as stale, regardless of timestamp ===" -ForegroundColor Cyan
$chAC2 = New-Dir "scenario-ac2\Series\Chapter 1"
$gifAC2 = New-FakeImage -DirPath $chAC2 -Name "01.gif"
Start-Sleep -Milliseconds 50
[System.IO.File]::WriteAllText((Join-Path $chAC2 "01.jxl"), "a real .jxl, newer than the .gif above")

$candidatesAC2 = Get-LooseImageCandidates -ScanPath (Join-Path $scratchDir "scenario-ac2")

Test-Assert ($candidatesAC2.StaleSources.Count -eq 0) ("the older .gif was NOT classified as a stale source, despite being older than the same-basename .jxl (got " + $candidatesAC2.StaleSources.Count + " stale candidate(s))")
Test-Assert ($candidatesAC2.NeedsConversion.Count -eq 0) "the .gif was also not classified as needing conversion - it's simply invisible to this function, same as an orphaned scratch file"
Test-Assert ($candidatesAC2.NamingCollisions.Count -eq 0) "the .gif was not flagged as a naming collision either"
Test-Assert (Test-Path -LiteralPath $gifAC2) "the .gif itself is untouched on disk (Get-LooseImageCandidates never deletes anything - this just confirms the file wasn't affected by the scan)"
Write-Host ""

# ==============================================================================
#  Scenario AD (2026-08-31 fix, caught by verifying this same day's
#  /code-review 4th pass): the WebP VP8X-header read moved into the
#  collision-guard pre-pass (fix 1, Scenario AA above) lost the try/catch it
#  had inside the dispatch loop's own per-job error handling - an
#  inaccessible .webp (locked by another process, here) used to throw
#  straight out of Convert-ImageBatch and end the whole run, instead of
#  failing just that one file like every other per-file I/O error here.
# ==============================================================================
Write-Host "=== Scenario AD: a locked/unreadable .webp fails just that file, not the whole batch ===" -ForegroundColor Cyan
$chAD = New-Dir "scenario-ad\Series\Chapter 1"
$webpAD = Join-Path $chAD "locked.webp"
[System.IO.File]::WriteAllText($webpAD, "fake webp bytes")
$lockAD = [System.IO.File]::Open($webpAD, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
$threwAD = $false
$resultAD = $null
try {
    $resultAD = Convert-ImageBatch -ImageFiles @(Get-Item -LiteralPath $webpAD) -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -DoFullLogging $false `
        -CancelToken ([System.Threading.CancellationToken]::None)
} catch {
    $threwAD = $true
} finally {
    $lockAD.Dispose()
}

Test-Assert (-not $threwAD) "did NOT throw out of Convert-ImageBatch - the batch survives one unreadable file"
Test-Assert ($null -ne $resultAD -and $resultAD.FailedCount -eq 1) ("the locked file was counted as a real failure, not silently dropped (got FailedCount=" + $(if ($resultAD) { $resultAD.FailedCount } else { "<null>" }) + ")")
Write-Host ""

# ==============================================================================
#  Scenario AE (2026-08-31 fix, caught by verifying this same day's
#  /code-review 4th pass): the collision-guard pre-pass (fix 1) never
#  checked $CancelToken, so cancelling mid-run still ran a real `magick
#  identify` spawn for every remaining .avif before the (by-then pointless)
#  dispatch loop declined to run - potentially thousands of spawns after
#  the user asked the run to stop. A token already cancelled BEFORE the
#  call is the simplest deterministic repro of "cancelled mid-batch."
# ==============================================================================
Write-Host "=== Scenario AE: an already-cancelled token short-circuits the pre-pass - no classification work, everything reported pending ===" -ForegroundColor Cyan
$chAE = New-Dir "scenario-ae\Series\Chapter 1"
$avifAE = New-FakeAvif -DirPath $chAE -Name "cover.avif" -Content "FRAMES:1"
$identifyLogAE = Join-Path $scratchDir "scenario-ae-identify.log"
[System.IO.File]::WriteAllText($identifyLogAE, "")
$env:HARNESS_IDENTIFY_LOG = $identifyLogAE
$ctsAE = [System.Threading.CancellationTokenSource]::new()
$ctsAE.Cancel()

try {
    $resultAE = Convert-ImageBatch -ImageFiles @(Get-Item -LiteralPath $avifAE) -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -DoFullLogging $false `
        -CancelToken $ctsAE.Token
} finally {
    $env:HARNESS_IDENTIFY_LOG = $null
    $ctsAE.Dispose()
}

$identifyCallsAE = @(Get-Content -LiteralPath $identifyLogAE | Where-Object { $_ -like "*cover.avif" })
Test-Assert ($identifyCallsAE.Count -eq 0) ("the cancelled token stopped the pre-pass BEFORE it ever spawned magick identify for classification (got " + $identifyCallsAE.Count + " identify call(s))")
Test-Assert ($resultAE.PendingPaths.Count -eq 1 -and $resultAE.PendingPaths[0] -eq $avifAE) ("the AVIF was reported pending, not classified or converted (got PendingPaths=[" + ($resultAE.PendingPaths -join ", ") + "])")
Test-Assert ($resultAE.ConvertedCount -eq 0 -and $resultAE.FailedCount -eq 0 -and $resultAE.SkippedCount -eq 0 -and $resultAE.InspectFailedCount -eq 0) "no classification or conversion work happened at all"
Test-Assert (Test-Path -LiteralPath $avifAE) "the source was left untouched"
Write-Host ""

# ==============================================================================
#  Scenario AF (2026-08-31 fix, caught by verifying this same day's
#  /code-review 4th pass, then CORRECTED by a second verification pass that
#  showed the fix WAS observably testable after all): the outer dispatch-
#  loop catch's own bulk cleanup (fix 3) iterates a $running list that can
#  be STALE if Complete-ImageConversionJob throws partway through the poll
#  loop's per-pass foreach - it may still list jobs that function's own
#  finally already released. A same-budget scenario can't show the bug
#  (SemaphoreSlim self-caps at max once every acquired slot is legitimately
#  released), but a SHARED budget with real headroom (simulating the
#  animated engine holding some slots, the actual Full Pipeline shape) can:
#  a double-release there doesn't hit the ceiling, it erroneously refunds
#  slots that belong to jobs OUTSIDE this batch entirely.
# ==============================================================================
Write-Host "=== Scenario AF: a same-pass throw does not double-release an EARLIER job's already-released shared-budget slot, or delete its already-converted output ===" -ForegroundColor Cyan
$chAF = New-Dir "scenario-af\Series\Chapter 1"
$fileAF1 = Get-Item -LiteralPath (New-FakeImage -DirPath $chAF -Name "jobA_af.jpg")
$expectedJxlAF = Join-Path $chAF "jobA_af.jxl"
$fileAF2 = Get-Item -LiteralPath (New-FakeImage -DirPath $chAF -Name "jobB_af.jpg" -SleepMs 0)
[System.IO.File]::WriteAllText($fileAF2.FullName, "STDOUT_MARKER")
$budgetAF = [System.Threading.SemaphoreSlim]::new(4, 4)
# Pre-acquire 2 slots to stand in for the animated engine's own real,
# still-in-use share of the budget - the exact condition under which the
# bug's damage (refunding slots that were never this batch's to release)
# is actually observable.
$budgetAF.Wait(0) | Out-Null
$budgetAF.Wait(0) | Out-Null

$realWriteLogFnAF = ${function:Write-Log}
function Write-Log {
    param([string]$Message, [ValidateSet("Info", "Warn", "Error", "Summary")][string]$Level = "Info")
    if ($Message -like "*cjxl stdout for*jobB_af.jpg*") { throw "simulated Write-Log failure on jobB's own UNGUARDED stdout-log call" }
    & $script:realWriteLogFnAF -Message $Message -Level $Level
}
$script:realWriteLogFnAF = $realWriteLogFnAF

$threwAF = $false
try {
    $null = Convert-ImageBatch -ImageFiles @($fileAF1, $fileAF2) -CjxlExe $fakeCjxlExe -MaxCjxlProcs 5 -DoFullLogging $true `
        -CancelToken ([System.Threading.CancellationToken]::None) -SharedBudget $budgetAF
} catch {
    $threwAF = $true
} finally {
    ${function:Write-Log} = $realWriteLogFnAF
}

Test-Assert $threwAF "the injected Write-Log failure propagated out of Convert-ImageBatch"
Test-Assert ($budgetAF.CurrentCount -eq 2) ("only this batch's own 2 acquired slots were released, not the 2 pre-acquired ones standing in for the OTHER engine (got CurrentCount=" + $budgetAF.CurrentCount + ", would be 4 if both jobs were double-released)")
Test-Assert (Test-Path -LiteralPath $expectedJxlAF) "jobA's already-converted .jxl survived - the outer catch's force-cleanup must not touch a job that already completed successfully earlier in the same poll pass (a real data-loss bug found and fixed by a third verification pass: the SAME stale-$running condition that causes the double-release also let the outer catch delete a completed job's real output)"
$budgetAF.Dispose()
Write-Host ""

# ==============================================================================
#  Scenario AG (2026-08-31 fix, caught by verifying this same day's
#  /code-review 4th pass): the outer dispatch-loop catch's own force-kill
#  cleanup (fix 3, Scenario AB above) claimed to mirror the force-kill
#  block below but dropped ONE step - deleting a partial/corrupt .jxl a
#  killed cjxl process may have already written. Left behind, that's a
#  non-zero-byte .jxl NEWER than its source - the NEXT run's
#  Get-LooseImageCandidates classifies the source as stale and deletes it,
#  keeping only the garbage output (same species Scenario B2 already
#  covers for the ORDINARY failure path).
# ==============================================================================
Write-Host "=== Scenario AG: the outer catch deletes a partial .jxl left by a force-killed job, not just the temp PNG ===" -ForegroundColor Cyan
$chAG = New-Dir "scenario-ag\Series\Chapter 1"
$fileAG1 = Get-Item -LiteralPath (New-FakeImage -DirPath $chAG -Name "stillrunning_ag.jpg" -SleepMs 0)
[System.IO.File]::WriteAllText($fileAG1.FullName, "PARTIAL_THEN_SLEEP:5000")
$fileAG2 = Get-Item -LiteralPath (New-FakeImage -DirPath $chAG -Name "throws_ag.jpg" -SleepMs 0)
[System.IO.File]::WriteAllText($fileAG2.FullName, "STDOUT_MARKER")
$expectedJxlAG = Join-Path $chAG "stillrunning_ag.jxl"

$realWriteLogFnAG = ${function:Write-Log}
function Write-Log {
    param([string]$Message, [ValidateSet("Info", "Warn", "Error", "Summary")][string]$Level = "Info")
    if ($Message -like "*cjxl stdout for*throws_ag.jpg*") { throw "simulated Write-Log failure on the second job's UNGUARDED stdout-log call" }
    & $script:realWriteLogFnAG -Message $Message -Level $Level
}
$script:realWriteLogFnAG = $realWriteLogFnAG

$threwAG = $false
try {
    $null = Convert-ImageBatch -ImageFiles @($fileAG1, $fileAG2) -CjxlExe $fakeCjxlExe -MaxCjxlProcs 5 -DoFullLogging $true `
        -CancelToken ([System.Threading.CancellationToken]::None)
} catch {
    $threwAG = $true
} finally {
    ${function:Write-Log} = $realWriteLogFnAG
}

Test-Assert $threwAG "the injected failure propagated out of Convert-ImageBatch"
Test-Assert (-not (Test-Path -LiteralPath $expectedJxlAG)) "the partial .jxl left by the force-killed still-running job was deleted, not left as a future stale-source trap"
Write-Host ""

# ==============================================================================
#  Scenario AH (2026-08-31 addition, project owner approved as an easy
#  fix mirroring the main dispatch loop's own try/catch): the straggler-
#  drain block (only reached after a real cancel, when $running.Count -gt 0)
#  had no equivalent guard. The force-kill sub-block's own "Force-stopping
#  N job(s)..." Write-Log call is the realistic trigger - unlike every
#  Write-Log call inside Complete-ImageConversionJob (all guarded by that
#  function's own try/catch, confirmed by trying the success-path "Conversion
#  OK (abort drain)" line first: it's swallowed and miscounted as a normal
#  failure, not a genuine propagating throw), this one sits directly in the
#  drain block's own body, unguarded. A job that never finishes within
#  -AbortTimeoutSeconds (so it's still genuinely running, SlotReleased
#  never set) must still be force-killed/disposed/released by the new catch.
# ==============================================================================
Write-Host "=== Scenario AH: an unexpected throw during the straggler-drain's force-kill step still cleans up correctly ===" -ForegroundColor Cyan
$chAH = New-Dir "scenario-ah\Series\Chapter 1"
$fileAH = Get-Item -LiteralPath (New-FakeImage -DirPath $chAH -Name "neverfinishes_ah.jpg" -SleepMs 30000)
$expectedJxlAH = Join-Path $chAH "neverfinishes_ah.jxl"
$budgetAH = [System.Threading.SemaphoreSlim]::new(3, 3)
$budgetAH.Wait(0) | Out-Null   # one slot pre-acquired to stand in for another engine
$ctsAH = [System.Threading.CancellationTokenSource]::new()
$pollAH = { param($inFlight) if ($inFlight.Count -gt 0) { $ctsAH.Cancel() } }

$realWriteLogFnAH = ${function:Write-Log}
function Write-Log {
    param([string]$Message, [ValidateSet("Info", "Warn", "Error", "Summary")][string]$Level = "Info")
    if ($Message -like "*Force-stopping*") { throw "simulated Write-Log failure during the straggler-drain's own force-kill logging" }
    & $script:realWriteLogFnAH -Message $Message -Level $Level
}
$script:realWriteLogFnAH = $realWriteLogFnAH

$threwAH = $false
try {
    $null = Convert-ImageBatch -ImageFiles @($fileAH) -CjxlExe $fakeCjxlExe -MaxCjxlProcs 5 -DoFullLogging $false `
        -CancelToken $ctsAH.Token -SharedBudget $budgetAH -AbortPollCallback $pollAH -AbortTimeoutSeconds 1
} catch {
    $threwAH = $true
} finally {
    ${function:Write-Log} = $realWriteLogFnAH
    $ctsAH.Dispose()
}

Test-Assert $threwAH "the injected failure propagated out of Convert-ImageBatch during the straggler-drain, not silently swallowed"
Test-Assert ($budgetAH.CurrentCount -eq 2) ("the never-finished job's slot was still released exactly once by the new catch (got CurrentCount=" + $budgetAH.CurrentCount + ", would stay 1 if the catch never ran and leaked it)")
Test-Assert (-not (Test-Path -LiteralPath $expectedJxlAH)) "no .jxl was ever created for a job that was force-killed mid-sleep (sanity check - fake cjxl only writes output AFTER its SLEEP_MS completes)"
$budgetAH.Dispose()
Write-Host ""

# ==============================================================================
#  Scenario AI (2026-09-02, recurring-bug-pattern coverage): omitting
#  -DoJpegQuality falls back to a safe default (90), not 0. Same species
#  of bug as the 2026-09-01 .jxl-discovery gap (Todo.md/CHANGELOG.md) -
#  a parameter default silently diverging from its sibling function's
#  own default (Convert-AnimatedBatch's -AnimatedQuality already
#  defaulted to 90) - fixed the same day this scenario was added, but
#  was latent (both real call sites already pass it explicitly) and had
#  NO test anywhere proving the omitted-key fallback itself was safe.
#  Reads back the fake cjxl.exe's own real argument string (via the new
#  ARGS_MARKER trigger) to prove --quality=90 was actually received, not
#  just that some default value exists somewhere unverified.
# ==============================================================================
Write-Host "=== Scenario AI: Convert-ImageBatch's -DoJpegQuality defaults to 90 when omitted ===" -ForegroundColor Cyan
$chAI = New-Dir "scenario-ai\Series\Chapter 1"
$fileAI = Join-Path $chAI "page1.jpg"
[System.IO.File]::WriteAllText($fileAI, "ARGS_MARKER")

$resultAI = Convert-ImageBatch -ImageFiles @(Get-Item -LiteralPath $fileAI) -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -DoFullLogging $false `
    -CancelToken ([System.Threading.CancellationToken]::None)

$expectedJxlAI = Join-Path $chAI "page1.jxl"
Test-Assert ($resultAI.ConvertedCount -eq 1 -and $resultAI.FailedCount -eq 0) "sanity check: the conversion itself succeeded"
$argsTextAI = Get-Content -LiteralPath $expectedJxlAI -Raw
Test-Assert ($argsTextAI -match "--quality=90(\s|$)") ("omitting -DoJpegQuality produced --quality=90, not --quality=0 (got: '" + $argsTextAI.Trim() + "')")
Write-Host ""

# ==============================================================================
#  Scenario AJ (2026-09-03 fix, real bug, live-reported): every cjxl
#  invocation passes --num_threads=1, on all three argument-building
#  branches (lossless JPEG, lossy JPEG, non-JPEG). Before this fix, cjxl's
#  own default ("-1" = use machine default) was never overridden, so each
#  concurrently-dispatched process grabbed its own machine-default thread
#  pool independently of -MaxCjxlProcs - confirmed live (4 configured
#  processes saturated far more than 4 real threads). Same ARGS_MARKER
#  technique as Scenario AI, one file per branch.
# ==============================================================================
Write-Host "=== Scenario AJ: every cjxl invocation pins --num_threads=1 ===" -ForegroundColor Cyan
$chAJ = New-Dir "scenario-aj\Series\Chapter 1"

$fileAJLosslessJpeg = Join-Path $chAJ "lossless.jpg"
[System.IO.File]::WriteAllText($fileAJLosslessJpeg, "ARGS_MARKER")
$fileAJLossyJpeg = Join-Path $chAJ "lossy.jpg"
[System.IO.File]::WriteAllText($fileAJLossyJpeg, "ARGS_MARKER")
$fileAJPng = Join-Path $chAJ "plain.png"
[System.IO.File]::WriteAllText($fileAJPng, "ARGS_MARKER")

$null = Convert-ImageBatch -ImageFiles @(Get-Item -LiteralPath $fileAJLosslessJpeg) -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -DoFullLogging $false `
    -DoJpegLossless $true -CancelToken ([System.Threading.CancellationToken]::None)
$null = Convert-ImageBatch -ImageFiles @(Get-Item -LiteralPath $fileAJLossyJpeg) -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -DoFullLogging $false `
    -DoJpegLossless $false -DoJpegQuality 80 -CancelToken ([System.Threading.CancellationToken]::None)
$null = Convert-ImageBatch -ImageFiles @(Get-Item -LiteralPath $fileAJPng) -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -DoFullLogging $false `
    -CancelToken ([System.Threading.CancellationToken]::None)

$argsLosslessAJ = Get-Content -LiteralPath (Join-Path $chAJ "lossless.jxl") -Raw
$argsLossyAJ    = Get-Content -LiteralPath (Join-Path $chAJ "lossy.jxl") -Raw
$argsPngAJ      = Get-Content -LiteralPath (Join-Path $chAJ "plain.jxl") -Raw
Test-Assert ($argsLosslessAJ -match "--num_threads=1(\s|$)") ("lossless-JPEG branch pins --num_threads=1 (got: '" + $argsLosslessAJ.Trim() + "')")
Test-Assert ($argsLossyAJ -match "--num_threads=1(\s|$)") ("lossy-JPEG branch pins --num_threads=1 (got: '" + $argsLossyAJ.Trim() + "')")
Test-Assert ($argsPngAJ -match "--num_threads=1(\s|$)") ("non-JPEG branch pins --num_threads=1 (got: '" + $argsPngAJ.Trim() + "')")
Write-Host ""

# ==============================================================================
#  Scenario AK (2026-09-03 fix, real bug, live-reported and live-tested):
#  the straggler-drain's wait-for-natural-completion loop must be skipped
#  entirely when [ConsoleCtrl]::IsCloseEvent is true (a window-close abort),
#  going straight to the force-kill block instead. Windows force-kills the
#  whole process ~5s after a close event regardless, so waiting out any
#  part of -AbortTimeoutSeconds can never fit. Same pattern as Scenario AH
#  (a real still-sleeping fake cjxl process, cancelled via -AbortPollCallback)
#  but with a LONG -AbortTimeoutSeconds (30s) that would normally still be
#  waiting - timed with a Stopwatch to prove the whole call returns almost
#  immediately instead of anywhere near that.
# ==============================================================================
Write-Host "=== Scenario AK: IsCloseEvent skips the straggler-drain wait entirely, force-kills immediately ===" -ForegroundColor Cyan
$chAK = New-Dir "scenario-ak\Series\Chapter 1"
$fileAK = Get-Item -LiteralPath (New-FakeImage -DirPath $chAK -Name "neverfinishes_ak.jpg" -SleepMs 30000)
$ctsAK = [System.Threading.CancellationTokenSource]::new()
$pollAK = { param($inFlight) if ($inFlight.Count -gt 0) { $ctsAK.Cancel() } }

[ConsoleCtrl]::IsCloseEvent = $true
$swAK = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $resultAK = Convert-ImageBatch -ImageFiles @($fileAK) -CjxlExe $fakeCjxlExe -MaxCjxlProcs 5 -DoFullLogging $false `
        -CancelToken $ctsAK.Token -AbortPollCallback $pollAK -AbortTimeoutSeconds 30
} finally {
    $swAK.Stop()
    [ConsoleCtrl]::IsCloseEvent = $false
    $ctsAK.Dispose()
}

Test-Assert ($swAK.Elapsed.TotalSeconds -lt 5) ("returned in under 5s despite a 30s -AbortTimeoutSeconds and a 30s-sleeping job (took " + [int]$swAK.Elapsed.TotalSeconds + "s)")
Test-Assert ($resultAK.ForceKilledCount -eq 1) ("the still-sleeping job was force-killed, not waited for (got ForceKilledCount=" + $resultAK.ForceKilledCount + ")")
Write-Host ""

if ($script:failCount -eq 0) {
    Write-Host ("ALL PASSED  (" + $script:passCount + " assertions)") -ForegroundColor Green
    exit 0
} else {
    Write-Host ($script:failCount.ToString() + " FAILED, " + $script:passCount.ToString() + " passed") -ForegroundColor Red
    exit 1
}
