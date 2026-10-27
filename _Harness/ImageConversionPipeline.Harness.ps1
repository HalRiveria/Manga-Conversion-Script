<#
.SYNOPSIS
    Standalone test harness for Modules\ImageConversionPipeline.ps1.

.DESCRIPTION
    Like ZipPipeline.Harness.ps1, this dot-sources the REAL already-built
    dependency modules - FileDeletion.ps1, AbortPipeline.ps1,
    LeafDirectoryDiscovery.ps1, CleanConsoleRendering.ps1, and Logging.ps1
    - since this is an orchestration-tier module. $CjxlExe/$MagickExe are
    real (if fake) compiled executables, not mocks - the conversion engine
    spawns actual OS processes via System.Diagnostics.Process, so a fake
    process is what's actually exercised, not a stand-in for the process
    layer itself.

    The fake cjxl.exe decides success/failure by sniffing the SOURCE
    file's own text content (case-sensitive "FAIL_CJXL" marker) - lets
    each scenario control per-image outcomes just by what it writes into
    the fake source files, without any harness-side process mocking.

    Scenarios cover the two-tier series/chapter walk (New-SeriesProvider +
    Get-SeriesChapters), CCR event emission, the -PostChapterCallback
    shape, the Register-AbortCancellationSource handling, and the
    chapter/conversion-coverage decoupling (see ImageConversionPipeline.ps1's
    header). The batch-conversion edge cases (WebP transcode, ICC-strip
    retry, animated-WebP detection) are exercised through the live pipeline.

    Register-/Unregister-AbortCancellationSource and Test-AbortSignal are
    wrapped with call-tracking spies (defined after dot-sourcing
    AbortPipeline.ps1, calling straight through to the real originals) so
    Scenario H can prove the actual registration/cancellation mechanics
    fired, and fire a real abort deterministically mid-batch via a call-
    count trigger instead of a wall-clock race (firing the abort before
    the call even started would never exercise the pipeline's own abort path).

.EXAMPLE
    .\_Harness\ImageConversionPipeline.Harness.ps1
#>

$ErrorActionPreference = "Stop"

$modulesDir = Join-Path $PSScriptRoot "..\Modules"
. (Join-Path $modulesDir "FileDeletion.ps1")
. (Join-Path $modulesDir "AbortPipeline.ps1")
. (Join-Path $modulesDir "LeafDirectoryDiscovery.ps1")
. (Join-Path $modulesDir "CleanConsoleRendering.ps1")
. (Join-Path $modulesDir "Logging.ps1")
# ChapterDispatch.ps1 - Invoke-LooseImageConversionPipeline's
# own real dependency. Dot-sourced before ImageConversionPipeline.ps1 itself,
# matching Conversion Script Main.ps1's own intended load order.
. (Join-Path $modulesDir "ChapterDispatch.ps1")
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

# Spy for the CCR status scenarios - same
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
        if (content.Contains("STDERR_FLOOD")) {
            // Same technique as fake magick.exe's own
            // stderr flood below - simulates a cjxl that emits more than
            // the OS anonymous-pipe buffer (~4KB/~64KB depending on
            // platform) of stderr before exiting, proving
            // the async cjxl dispatch (which polls
            // HasExited rather than reading synchronously inline) doesn't
            // deadlock on it.
            string flood = new string('E', 200);
            for (int i = 0; i < 2000; i++) { Console.Error.WriteLine(flood); }
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
            // actually invoked with (see Scenario AI below) - e.g. proving a real
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
#  Fake magick.exe (for the static-AVIF path) -
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
            // Test-AvifAnimated addresses frame [0] only
            // (a perf choice - see AnimatedConversionPipeline.ps1's own
            // header) - strip that trailing selector to find the real
            // fixture file on disk.
            string rawPath = args[args.Length - 1];
            string path = Regex.Replace(rawPath, "\\[\\d+\\]$", "");
            // Logs each identify call's target path (gated on an env var so
            // unrelated scenarios pay nothing) - lets a test count how many
            // times an identify spawn actually happened, proving the
            // cancellation check (an already-cancelled
            // -CancelToken must short-circuit the collision-guard pre-pass
            // BEFORE it ever spawns magick for AVIF classification).
            string identifyLog = Environment.GetEnvironmentVariable("HARNESS_IDENTIFY_LOG");
            if (identifyLog != null) {
                // WaitOne(timeoutMs) + AbandonedMutexException handling
                // (same as Controller.Harness.ps1's own
                // identical mutex patterns - see that file's own comment
                // for the full reasoning: a bare, timeout-less WaitOne()
                // with no AbandonedMutexException catch can cascade a
                // single killed/crashed fake process into every later
                // waiter hanging or crashing too).
                using (var mtx = new System.Threading.Mutex(false, "ICPHarnessIdentifyLogMutex")) {
                    bool acquired;
                    try {
                        acquired = mtx.WaitOne(10000);
                    } catch (System.Threading.AbandonedMutexException) {
                        acquired = true;
                    }
                    if (acquired) {
                        try { File.AppendAllText(identifyLog, path + Environment.NewLine); } finally { mtx.ReleaseMutex(); }
                    }
                }
            }
            string content = File.Exists(path) ? File.ReadAllText(path) : "";
            if (content.Contains("FAIL_IDENTIFY")) {
                Console.Error.WriteLine("simulated identify failure");
                return 1;
            }
            Match fm = Regex.Match(content, "FRAMES:(\\d+)");
            int frames = fm.Success ? int.Parse(fm.Groups[1].Value) : 1;
            // Test-AvifAnimated now reads a simulated animation delay
            // (nonzero = animated, "0" = static), not a raw frame count -
            // see AnimatedConversionPipeline.Harness.ps1's fake magick.exe
            // for the same translation.
            int delay = frames > 1 ? 1000 : 0;
            Console.Write(delay.ToString());
            return 0;
        }

        string srcArg = args[0];
        string src = srcArg.EndsWith("[0]") ? srcArg.Substring(0, srcArg.Length - 3) : srcArg;
        string dst = args[args.Length - 1];
        string srcContent = File.Exists(src) ? File.ReadAllText(src) : "";
        if (srcContent.Contains("HUGE_STDERR")) {
            // Writes a large stderr dump (well over a typical OS pipe
            // buffer) BEFORE doing anything else - proves the
            // redirect-deadlock handling (both streams drained
            // asynchronously before WaitForExit in both
            // Invoke-IccStripRetryOrFail and the WebP/AVIF-to-PNG
            // pre-conversion call) actually prevents a hang, rather than
            // just reproducing the Test-AvifAnimated case
            // in the sibling module.
            string line = new string('X', 200) + Environment.NewLine;
            for (int i = 0; i < 2000; i++) { Console.Error.Write(line); }
        }
        if (srcContent.Contains("FAIL_MAGICK_PARTIAL")) {
            // Leaves a truncated output behind, like a real magick dying mid-write.
            File.WriteAllText(dst, "partial");
            Console.Error.WriteLine("simulated magick failure after a partial write");
            return 1;
        }
        if (srcContent.Contains("FAIL_MAGICK")) {
            Console.Error.WriteLine("simulated magick pre-conversion failure");
            return 1;
        }
        // Invoke-IccStripRetryOrFail's own call shape: "<src>" -strip
        // "<dst>" (no -colorspace Gray: color data is never force-converted) -
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
#  Scenario A0: Get-LooseImageExtensions is the
#  single source of truth this module and Controller.ps1 both use as a
#  default parameter value, instead of 5 independently hardcoded copies of
#  the same 7-element array. AnimatedConversionPipeline.ps1 keeps its own
#  literal on purpose (module-independence reasons, see that file's own
#  comment) - checked here too, so a future edit to one and not the other
#  is caught immediately instead of silently drifting.
# ==============================================================================
Write-Host "=== Scenario A0: Get-LooseImageExtensions is the shared source of truth ===" -ForegroundColor Cyan
# ".gif"/".bmp"/".heic"/".heif" count as unconverted content, not
# silently invisible to chapter discovery.
$expectedExtA0 = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif", ".gif", ".bmp", ".heic", ".heif")
$actualExtA0 = @(Get-LooseImageExtensions)
Test-Assert (($actualExtA0 -join ",") -eq ($expectedExtA0 -join ",")) ("Get-LooseImageExtensions returns the expected 11-element list in order (got: " + ($actualExtA0 -join ",") + ")")

$animatedPipelinePath = Join-Path $PSScriptRoot "..\Modules\AnimatedConversionPipeline.ps1"
$animatedPipelineSource = Get-Content -LiteralPath $animatedPipelinePath -Raw
$expectedLiteral = '@(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif", ".gif", ".bmp", ".heic", ".heif")'
Test-Assert ($animatedPipelineSource.Contains($expectedLiteral)) "AnimatedConversionPipeline.ps1's own deliberately-kept-literal still matches the canonical list exactly (not drifted)"
Write-Host ""

# ==============================================================================
#  Scenario A0b: Test-OrphanedScratchFileName
#  is the single source of truth this module and Controller.ps1 both call
#  now, instead of the same 3-line regex trio hand-duplicated across this
#  module, Controller.ps1, and ZipPipeline.ps1. ZipPipeline.ps1 keeps its
#  own literal on purpose (its own standalone harness deliberately doesn't
#  dot-source this module - same reasoning as AnimatedConversionPipeline.ps1's
#  kept literal above) - checked here too, so a future edit to one and not
#  the other is caught immediately instead of silently drifting.
# ==============================================================================
Write-Host "=== Scenario A0b: Test-OrphanedScratchFileName is the shared source of truth ===" -ForegroundColor Cyan
Test-Assert (Test-OrphanedScratchFileName -Name "photo_tmp_iccstrip.png") "'_tmp_iccstrip.png' matches"
Test-Assert (Test-OrphanedScratchFileName -Name "photo_tmp_iccstrip-2.png") "'_tmp_iccstrip-N.png' (numbered) matches"
Test-Assert (Test-OrphanedScratchFileName -Name "photo_tmp_webp2png.png") "'_tmp_webp2png.png' matches"
Test-Assert (Test-OrphanedScratchFileName -Name "photo_tmp_avif2png.png") "'_tmp_avif2png.png' matches"
Test-Assert (Test-OrphanedScratchFileName -Name "photo_tmp_bmp2png.png") "'_tmp_bmp2png.png' matches"
Test-Assert (Test-OrphanedScratchFileName -Name "photo_tmp_heic2png.png") "'_tmp_heic2png.png' matches"
Test-Assert (Test-OrphanedScratchFileName -Name "photo_tmp_heif2png.png") "'_tmp_heif2png.png' matches"
Test-Assert (Test-OrphanedScratchFileName -Name "photo_tmp_tiff2png.png") "'_tmp_tiff2png.png' matches"
Test-Assert (Test-OrphanedScratchFileName -Name "anim_tmp_overwrite.webp") "'_tmp_overwrite.webp' matches"
Test-Assert (-not (Test-OrphanedScratchFileName -Name "page1.jpg")) "a genuine loose image does NOT match"

$zipPipelinePath   = Join-Path $PSScriptRoot "..\Modules\ZipPipeline.ps1"
$zipPipelineSource = Get-Content -LiteralPath $zipPipelinePath -Raw
foreach ($patternA0b in @('_tmp_iccstrip(-\d+)?\.png$', '_tmp_(webp|avif|bmp|heic|heif|tiff)2png\.png$', '_tmp_overwrite\.webp$')) {
    Test-Assert ($zipPipelineSource.Contains($patternA0b)) ("ZipPipeline.ps1's own deliberately-kept-literal still contains pattern '" + $patternA0b + "' (not drifted)")
}
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
Write-Host ""

# ==============================================================================
#  Scenario A2: the point of dispatching through ChapterDispatch.ps1, tested directly - an idle concurrency
#  slot picks up the NEXT chapter's job while the CURRENT chapter still
#  has work outstanding, instead of blocking on one chapter's conversion
#  finishing before the next chapter's images are even dispatched.
#  Chapter 1 gets a fast image + a slow image (fills both -MaxCjxlProcs
#  slots); Chapter 2 gets one fast image. The instant Chapter 1's fast
#  image finishes, Chapter 2's image must start - WHILE Chapter 1's slow
#  image is still converting, not after. Write-Log swapped to a capturing
#  version for this scenario only, same idiom as Scenarios AF/AG/AH.
# ==============================================================================
Write-Host "=== Scenario A2: an idle slot picks up the NEXT chapter's job while the current chapter still has work outstanding ===" -ForegroundColor Cyan
$rootA2 = New-Dir "scenario-a2"
$s1A2 = New-Dir "scenario-a2\Series\Chapter 1"
$s2A2 = New-Dir "scenario-a2\Series\Chapter 2"
New-FakeImage -DirPath $s1A2 -Name "fast.jpg" | Out-Null
New-FakeImage -DirPath $s1A2 -Name "slow.jpg" -SleepMs 800 | Out-Null
New-FakeImage -DirPath $s2A2 -Name "fast.jpg" | Out-Null

$script:logMessagesA2 = [System.Collections.Generic.List[string]]::new()
$realWriteLogFnA2 = ${function:Write-Log}
function Write-Log {
    param([string]$Message, [ValidateSet("Info", "Warn", "Error", "Summary")][string]$Level = "Info")
    $script:logMessagesA2.Add($Message)
    & $script:realWriteLogFnA2Ref -Message $Message -Level $Level
}
$script:realWriteLogFnA2Ref = $realWriteLogFnA2

try {
    $totalsA2 = Invoke-LooseImageConversionPipeline -Path $rootA2 -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false
} finally {
    ${function:Write-Log} = $realWriteLogFnA2
}

$idxChapter2Start = ($script:logMessagesA2 | Select-String -Pattern "Converting loose image.*Chapter 2.*fast\.jpg").LineNumber
$idxChapter1SlowDone = ($script:logMessagesA2 | Select-String -Pattern "Conversion OK.*Chapter 1.*slow\.jxl").LineNumber
Test-Assert ($totalsA2.ConvertedSuccess -eq 3 -and $totalsA2.ConvertedFail -eq 0) ("sanity check: all 3 images converted (got ConvertedSuccess=" + $totalsA2.ConvertedSuccess + ")")
Test-Assert ($null -ne $idxChapter2Start -and $null -ne $idxChapter1SlowDone -and $idxChapter2Start -lt $idxChapter1SlowDone) ("Chapter 2's image started converting BEFORE Chapter 1's slow image finished - real interleaving, not one-chapter-at-a-time (Chapter 2 start at message " + $idxChapter2Start + ", Chapter 1 slow-image finish at message " + $idxChapter1SlowDone + ")")
Write-Host ""

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
#  Scenario B2: a cjxl process that writes a PARTIAL/corrupt
#  .jxl before exiting non-zero (simulating a crash or disk-full mid-write) -
#  Complete-ImageConversionJob's normal failure path must clean that
#  partial .jxl up (not only the force-kill path). Left
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
# Force the source's timestamp strictly OLDER than the .jxl's - both
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
Write-Host ""

# ==============================================================================
#  Scenario C1b (same species as this project's other Remove-Source call sites):
#  Remove-Source's $false return must not be discarded in
#  Remove-StaleLooseSources, or a successful cleanup is reported regardless.
#  Remove-Source shadowed to return $false unconditionally.
# ==============================================================================
Write-Host "=== Scenario C1b: an already-gone stale source is not miscounted as cleaned ===" -ForegroundColor Cyan
$chC1b = New-Dir "scenario-c1b\Series\Chapter 1"
$staleSrcC1b = New-FakeImage -DirPath $chC1b -Name "already_done.jpg"
[System.IO.File]::WriteAllText((Join-Path $chC1b "already_done.jxl"), "real jxl bytes")
[System.IO.File]::SetLastWriteTimeUtc($staleSrcC1b, ([DateTime]::UtcNow.AddMinutes(-5)))

$realRemoveSourceC1b = ${function:Remove-Source}
function Remove-Source {
    param([string]$ItemPath)
    return $false
}
try {
    $totalsC1b = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-c1b") -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false
} finally {
    ${function:Remove-Source} = $realRemoveSourceC1b
}

Test-Assert ($totalsC1b.StaleCleanedSuccess -eq 0) ("StaleCleanedSuccess stays 0, not falsely incremented, when Remove-Source reports the stale source already gone (got " + $totalsC1b.StaleCleanedSuccess + ")")
Write-Host ""

# ==============================================================================
#  Scenario C2: a same-basename extension
#  collision - the .jxl exists FIRST (from a real, earlier conversion of a
#  NOW-GONE source), then a genuinely different, unconverted file with the
#  same basename shows up LATER (e.g. photo.jpg converted+deleted, then an
#  unrelated photo.png added).
#
#  Deleting it as "stale" without ever converting it, purely because the
#  basenames matched, would lose the new, unconverted source. Routing it
#  to NeedsConversion is no better: converting photo.png writes cjxl's
#  output to the SAME photo.jxl path, silently OVERWRITING the
#  pre-existing .jxl - the only remaining copy of the ORIGINAL photo.jpg's
#  content, permanently destroyed by a plain file write (not even
#  Recycle-Bin-recoverable).
#
#  So neither action is safe without knowing which file
#  produced the existing .jxl: a newer same-basename source is
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
# The collision must not be invisible outside its own log line - if it
# weren't counted anywhere, then (since it's this chapter's ONLY loose image)
# the chapter's ChapterResult would stay $null, mapping to a clean Success
# with no zip-block at all. Get-LooseImageCandidates returns it via NamingCollisions,
# counted into InspectFailedCount and used to force IsZippable=$false.
Test-Assert ($totalsC2.InspectFailedCount -eq 1) ("the naming collision is now counted in InspectFailedCount, not invisible (got " + $totalsC2.InspectFailedCount + ")")


# ==============================================================================
#  Scenario C2c: the live CCR display shows a naming-collision chapter
#  (same fixture as Scenario C2) as a Warning that names the collision -
#  and, since mode 2 never zips, says nothing about a zip. An "extra" entry with
#  no collision (a stray image in the series root) gets no warning.
# ==============================================================================
Write-Host "=== Scenario C2c: live CCR status names the real zip-block reason, and skips extras ===" -ForegroundColor Cyan
$rootC2c = New-Dir "scenario-c2c"
$chC2c = New-Dir "scenario-c2c\Series\Chapter 1"
[System.IO.File]::WriteAllText((Join-Path $chC2c "photo.jxl"), "real jxl bytes from a since-deleted photo.jpg")
Start-Sleep -Milliseconds 50
New-FakeImage -DirPath $chC2c -Name "photo.png" | Out-Null
New-FakeImage -DirPath (Join-Path $rootC2c "Series") -Name "extra.jpg" | Out-Null   # the "extra" - no chapter subfolder

$script:ccrCallsC2c = New-Object System.Collections.Generic.List[hashtable]
$realCompleteChapterProgressC2c = ${function:Complete-ChapterProgress}
function Complete-ChapterProgress {
    param([string]$SeriesName, [string]$ChapterName, [string]$Status, [string]$Detail = "")
    $script:ccrCallsC2c.Add(@{ ChapterName = $ChapterName; Status = $Status; Detail = $Detail })
    & $script:realCompleteChapterProgressC2cRef -SeriesName $SeriesName -ChapterName $ChapterName -Status $Status -Detail $Detail
}
$script:realCompleteChapterProgressC2cRef = $realCompleteChapterProgressC2c
$script:CleanConsoleOutputEnabled = $true

try {
    $totalsC2c = Invoke-LooseImageConversionPipeline -Path $rootC2c -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false
} finally {
    $script:CleanConsoleOutputEnabled = $false
    ${function:Complete-ChapterProgress} = $realCompleteChapterProgressC2c
}

$callC2cChapter = $script:ccrCallsC2c | Where-Object { $_.ChapterName -eq 'Chapter 1' } | Select-Object -First 1
$callC2cExtra   = $script:ccrCallsC2c | Where-Object { $_.ChapterName -eq 'Series' } | Select-Object -First 1
Test-Assert ($totalsC2c.ConvertedSuccess -eq 1) "sanity check: the extra's own image still converted normally"
Test-Assert ($null -ne $callC2cChapter -and $callC2cChapter.Status -eq 'Warning' -and $callC2cChapter.Detail -like '*naming collision*' -and $callC2cChapter.Detail -notlike '*zip*') ("the real chapter's live CCR status names the naming collision, with no zip wording (got Status='" + $(if ($callC2cChapter) { $callC2cChapter.Status } else { '<none>' }) + "', Detail='" + $(if ($callC2cChapter) { $callC2cChapter.Detail } else { '<none>' }) + "')")
Test-Assert ($null -ne $callC2cExtra -and $callC2cExtra.Status -eq 'Success' -and $callC2cExtra.Detail -notlike '*Zip skipped*') ("the extra entry (never zippable by design) does NOT get a spurious override (got Status='" + $(if ($callC2cExtra) { $callC2cExtra.Status } else { '<none>' }) + "', Detail='" + $(if ($callC2cExtra) { $callC2cExtra.Detail } else { '<none>' }) + "')")
Write-Host ""

# ==============================================================================
#  Scenario C2b: same collision shape as C2, but with the colliding source's timestamp
#  EXACTLY EQUAL to the pre-existing .jxl's, not newer. The comparison is
#  -ge, not -gt: with a strict -gt an equal timestamp would fall through to
#  the stale branch and be permanently deleted without ever being converted -
#  a real risk since ZIP extraction commonly produces coarse or identical timestamps.
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
#  Scenario D2: a chapter that finished
#  converting on an EARLIER run - source images already deleted, only a
#  .jxl left, zero loose files of any kind. If -FolderQualifyingExtensions
#  defaulted to the bare Get-LooseImageExtensions() list (no ".jxl", this
#  engine's own output extension), Get-SeriesChapters would never find this
#  chapter at all - silently invisible to every later run, with no
#  warning logged (same root cause as Controller.ps1's Full Pipeline - see
#  that file's own matching handling). So this function's own
#  -FolderQualifyingExtensions default includes ".jxl".
# ==============================================================================
Write-Host "=== Scenario D2: a chapter with ONLY already-converted .jxl (zero loose files) is still discovered ===" -ForegroundColor Cyan
$rootD2 = New-Dir "scenario-d2"
$chD2 = New-Dir "scenario-d2\Series\Chapter 1"
[System.IO.File]::WriteAllText((Join-Path $chD2 "page1.jxl"), "already converted on a prior run - source already deleted, nothing loose left")

$totalsD2 = Invoke-LooseImageConversionPipeline -Path $rootD2 -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsD2.ChapterCount -eq 1) ("the all-.jxl chapter was discovered at all (got ChapterCount=" + $totalsD2.ChapterCount + ")")
Test-Assert ($totalsD2.ConvertedSuccess -eq 0 -and $totalsD2.ConvertedFail -eq 0) "sanity check: nothing needed converting"
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
Test-Assert ($callbackCallsE[0].HasNamingCollision -eq $false) "a chapter with no naming collision reports HasNamingCollision=false"
Test-Assert (-not $callbackCallsE[0].ContainsKey('ZipOut') -and -not $callbackCallsE[0].ContainsKey('IsZippable')) "mode 2 never zips - the callback carries no zip fields"

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

# InspectFailedCount is Error-tier - if it weren't checked here at all, it
# would fall through to a silent Success, letting the zip gate proceed with
# a raw, completely unconverted AVIF in the chapter.
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
#  Scenario G2 (same rule as
#  Controller.ps1's Invoke-FullPipeline): a series with zero qualifying
#  chapters (e.g. already fully converted and zipped - nothing left but a
#  .cbz and an info file, no chapter subfolders at all) must never call
#  Start-SeriesProgress. Its
#  own docstring says a 0-chapter call "is rendered as an immediately-
#  frozen '0/0' line" via Update-CleanConsoleDisplay, exactly the unwanted
#  line that must be suppressed entirely.
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
#  cjxl OS process is genuinely still running - proving both the registration
#  fix and that a real abort correctly reaches Invoke-ChapterDispatch's own
#  CancelToken.
#
#  The call sequence goes through ChapterDispatch.ps1 (not a simple
#  series-loop/chapter-loop/AbortPollCallback chain - see this module's own
#  header) - $testAbortSignalTriggerAt=4 lands after the fake cjxl process
#  is dispatched and sleeping (ConvertedSuccess=1 below - the in-flight job
#  completes via the abort-drain wait, not a force-kill).
# ==============================================================================
Write-Host "=== Scenario H: abort registration actually wired up ===" -ForegroundColor Cyan
Reset-AbortState
$rootH = New-Dir "scenario-h"
$chH1 = New-Dir "scenario-h\Series\Chapter 1"
New-FakeImage -DirPath $chH1 -Name "page1.jpg" -SleepMs 300 | Out-Null

$script:testAbortSignalTriggerAt = 4

$totalsH = Invoke-LooseImageConversionPipeline -Path $rootH -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false -AbortTimeoutSeconds 5

Test-Assert ($script:registerCtsCalls.Count -eq 1) ("Register-AbortCancellationSource called exactly once (got " + $script:registerCtsCalls.Count + ")")
Test-Assert ($script:unregisterCtsCalls.Count -eq 1) ("Unregister-AbortCancellationSource called exactly once (got " + $script:unregisterCtsCalls.Count + ")")
Test-Assert ([object]::ReferenceEquals($script:registerCtsCalls[0], $script:unregisterCtsCalls[0])) "the registered and unregistered CTS are the SAME object"
Test-Assert ($script:unregisterCtsWasCancelled[0]) "that CTS's token actually got cancelled by the real abort (captured just before the module disposed it)"
Test-Assert ($totalsH.Aborted) "pipeline reports Aborted"
# LastCompletedPaths is always empty (a deliberate
# simplification - see this module's own header): an
# "at the exact instant abort was detected" snapshot scoped to one
# chapter's own blocking call has no clean equivalent once dispatch spans
# the whole run and chapters interleave. Nothing
# outside this module and its own harness ever read it.
Test-Assert ($totalsH.LastCompletedPaths.Count -eq 0) ("LastCompletedPaths is always empty in the migrated pipeline, by design (got " + $totalsH.LastCompletedPaths.Count + ")")
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
#  zip-domain "is this worth re-zipping" guards (see
#  ImageConversionPipeline.ps1's header).
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
New-FakeImage -DirPath $seriesDirL -Name "extra.jpg" | Out-Null

$totalsL = Invoke-LooseImageConversionPipeline -Path $rootL -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsL.ConvertedSuccess -eq 1) ("series-root image converted (got ConvertedSuccess=" + $totalsL.ConvertedSuccess + ")")
Test-Assert (Test-Path -LiteralPath (Join-Path $seriesDirL "extra.jxl")) "extra.jxl created directly in the series root"

# ==============================================================================
#  Scenario M: an "extra" merged-in directory (a stray image in the series
#  root) is converted and reported through its own callback, alongside
#  the real chapters.
# ==============================================================================
Write-Host "=== Scenario M: extra entries are converted and get their own callback ===" -ForegroundColor Cyan
$rootM = New-Dir "scenario-m"
$seriesDirM = New-Dir "scenario-m\Series"
$ch1M = New-Dir "scenario-m\Series\Ch1"
$ch2M = New-Dir "scenario-m\Series\Ch2"
New-FakeImage -DirPath $ch1M -Name "p1.jpg" | Out-Null
New-FakeImage -DirPath $ch2M -Name "p1.jpg" | Out-Null
New-FakeImage -DirPath $seriesDirM -Name "extra.jpg" | Out-Null   # the "extra" - no chapter subfolder

$callbackInfoM = [System.Collections.Generic.List[hashtable]]::new()
$cbM = { param($Info) $callbackInfoM.Add($Info) }.GetNewClosure()

$totalsM = Invoke-LooseImageConversionPipeline -Path $rootM -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false -PostChapterCallback $cbM

Test-Assert ($totalsM.ConvertedSuccess -eq 3) ("all 3 images converted, including the extra (got " + $totalsM.ConvertedSuccess + ")")
$realCallbacksM  = @($callbackInfoM | Where-Object { $_.ChapterName -ne "Series" })
$extraCallbackM  = @($callbackInfoM | Where-Object { $_.ChapterName -eq "Series" })
Test-Assert ($realCallbacksM.Count -eq 2) "both real chapters fired their own callback"
Test-Assert ($extraCallbackM.Count -eq 1) "the series-root extra fired its own callback"
Test-Assert ($extraCallbackM[0].ChapterResult.ConvertedCount -eq 1 -and $extraCallbackM[0].HasNamingCollision -eq $false) "the extra's callback carries its own result, no collision"

# ==============================================================================
#  Scenario N: -FolderExcludeStagingDirs must still exclude a staging directory
#  even when it holds an unconverted image the merge would otherwise re-add -
#  the merge must not bypass this exclusion, independent of -KnownZipPaths.
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
#  distinct from Scenario N (which only covers the NeedsConversion/extras
#  path). Without that, a stale source sitting in a directory the caller
#  explicitly asked to leave alone (e.g. an in-progress extraction area)
#  would get deleted anyway.
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
#  Scenario Q: static AVIF converts through the WebP-style temp-PNG detour
#  (a static AVIF always converts).
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
#  Scenario Q2: .gif/.bmp/.heic/
#  .heif count as unconverted content, same as any other extension on
#  Get-LooseImageExtensions()'s own list. .bmp/.heic/.heif actually
#  convert, through the same magick temp-PNG detour WebP/AVIF use
#  (cjxl.exe cannot read any of the three directly, but
#  `magick -list format` confirms BMP is read/write and HEIC/HEIF are
#  read-only, both sufficient for a one-way transcode). .gif is always
#  SKIPPED, never actually converted (GIF conversion has caused real
#  problems: an animated GIF reaching the ICC-strip retry path left
#  orphaned numbered temp PNGs behind that no cleanup regex catches).
#
#  Get-LooseImageCandidates already excludes .gif entirely at discovery
#  time (Scenario AC2, above), so it never reaches conversion; the live
#  end-to-end check below proves that governing behavior.
# ==============================================================================
Write-Host "=== Scenario Q2: .gif is always skipped, never actually converted ===" -ForegroundColor Cyan
$chQ2 = New-Dir "scenario-q2\Series\Chapter 1"
$gifQ2 = New-FakeImage -DirPath $chQ2 -Name "cover.gif"

# Confirms Get-LooseImageCandidates's own exclusion is what actually
# governs the real, end-to-end pipeline - a chapter with only a .gif
# reports zero candidates of any kind and never reaches conversion.
$totalsQ2 = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-q2") -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false
Test-Assert ($totalsQ2.ConvertedSuccess -eq 0 -and $totalsQ2.ConvertedFail -eq 0 -and $totalsQ2.ConvertedSkipped -eq 0) ("through the real end-to-end pipeline, the .gif is invisible - not skipped during conversion, just never a candidate at all (got Success=" + $totalsQ2.ConvertedSuccess + ", Fail=" + $totalsQ2.ConvertedFail + ", Skipped=" + $totalsQ2.ConvertedSkipped + ")")
Test-Assert (Test-Path -LiteralPath $gifQ2) "the GIF source is still untouched after the real end-to-end pipeline run"
Write-Host ""

# ==============================================================================
#  Scenario Q2b (same species as this project's other Remove-Source call sites):
#  Remove-Source's $false return (the source already vanished before
#  deletion - a real TOCTOU gap) must not be discarded in the conversion-job
#  finalizer, or a successful delete is reported regardless.
#  Remove-Source shadowed to return $false unconditionally. Runs through
#  the live Invoke-LooseImageConversionPipeline (Complete-ImageDispatchJob's
#  $removed check).
# ==============================================================================
Write-Host "=== Scenario Q2b: an already-gone source is not miscounted as deleted ===" -ForegroundColor Cyan
$chQ2b = New-Dir "scenario-q2b\Series\Chapter 1"
$imgQ2b = New-FakeImage -DirPath $chQ2b -Name "page1.jpg"

$realRemoveSourceQ2b = ${function:Remove-Source}
function Remove-Source {
    param([string]$ItemPath)
    return $false
}
try {
    $totalsQ2b = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-q2b") -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false
} finally {
    ${function:Remove-Source} = $realRemoveSourceQ2b
}

Test-Assert ($totalsQ2b.ConvertedSuccess -eq 1) "sanity check: the conversion itself still succeeded"
Test-Assert ($totalsQ2b.DeletedSuccess -eq 0) ("DeletedSuccess stays 0, not falsely incremented, when Remove-Source reports the source already gone (got " + $totalsQ2b.DeletedSuccess + ")")
Write-Host ""

Write-Host "=== Scenario Q3: .bmp/.heic/.heif each convert through the WebP-style temp-PNG detour ===" -ForegroundColor Cyan
foreach ($extQ3 in @("bmp", "heic", "heif", "tif", "tiff")) {
    $chQ3 = New-Dir ("scenario-q3-" + $extQ3 + "\Series\Chapter 1")
    $srcQ3 = New-FakeImage -DirPath $chQ3 -Name ("cover." + $extQ3)

    $totalsQ3 = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir ("scenario-q3-" + $extQ3)) -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -FullLogging $false

    Test-Assert ($totalsQ3.ConvertedSuccess -eq 1 -and $totalsQ3.ConvertedFail -eq 0) ("." + $extQ3 + " converted successfully through the magick detour (got ConvertedSuccess=" + $totalsQ3.ConvertedSuccess + ", ConvertedFail=" + $totalsQ3.ConvertedFail + ")")
    Test-Assert (-not (Test-Path -LiteralPath $srcQ3)) ("the ." + $extQ3 + " source was deleted after a successful conversion")
    Test-Assert (Test-Path -LiteralPath (Join-Path $chQ3 "cover.jxl")) ("cover.jxl was created for ." + $extQ3)
}
Write-Host ""

# Scenario Q3b: .tif/.tiff go through the magick detour too.
# Real cjxl can't read TIFF; handing it directly would only convert by
# accident, via the ICC-strip retry, with a
# misleading "ICC profile mismatch" warning on every file. The fake cjxl
# here accepts anything, so the proof is the other direction: with no
# magick available, a TIFF must now be refused with the same "ImageMagick
# not found" failure as BMP/HEIC, instead of going straight to cjxl.
Write-Host "=== Scenario Q3b: .tif/.tiff need magick (no longer sent straight to cjxl) ===" -ForegroundColor Cyan
foreach ($extQ3b in @("tif", "tiff")) {
    $chQ3b = New-Dir ("scenario-q3b-" + $extQ3b + "\Series\Chapter 1")
    $srcQ3b = New-FakeImage -DirPath $chQ3b -Name ("scan." + $extQ3b)
    $totalsQ3b = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir ("scenario-q3b-" + $extQ3b)) -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false
    Test-Assert ($totalsQ3b.ConvertedFail -eq 1 -and $totalsQ3b.ConvertedSuccess -eq 0) ("." + $extQ3b + " without magick fails cleanly instead of going straight to cjxl (got ConvertedSuccess=" + $totalsQ3b.ConvertedSuccess + ", ConvertedFail=" + $totalsQ3b.ConvertedFail + ")")
    Test-Assert (Test-Path -LiteralPath $srcQ3b) ("the ." + $extQ3b + " source is left untouched")
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
#  FailedCount, matching the animated pipeline's identical failure mode.
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
#  Scenario W: the ICC-strip retry - fake cjxl.exe fails
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
#  falls through to a normal failure instead of retrying forever -
#  without the -not $Job.IccRetried guard, Complete-ImageConversionJob
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
#  Scenario X2: the ICC-strip retry must be reused directly
#  for a .webp/.avif source, not re-run through the webp/avif-to-PNG
#  pre-conversion branch a second time. $j.SrcPath still ends in .webp
#  even for the retry job, so an unguarded isWebp/isAvif check
#  would fire again on redispatch, redoing an entirely separate, NON-stripped
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
#  Scenario X3: both the ICC-strip magick call (Invoke-IccStripRetryOrFail) and
#  the WebP/AVIF-to-PNG pre-conversion magick call redirect
#  stdout/stderr and must read them - the same Process redirect deadlock
#  species handled in AnimatedConversionPipeline.ps1's
#  Test-AvifAnimated. A huge stderr dump (well
#  over a typical OS pipe buffer) proves neither call site hangs.
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
#  Scenario X5: Invoke-IccStripRetryOrFail's own
#  Process::Start call is wrapped in try/catch like its two siblings (the
#  WebP/AVIF pre-conversion above, and the cjxl dispatch itself). A bad/stale
#  -MagickExe path there must not throw a raw, less-clear exception instead
#  of the same clean "counted as a real failure" outcome Scenario Y already proves for a bad
#  -CjxlExe path. Must fail fast and cleanly, not hang or crash the batch.
# ==============================================================================
Write-Host "=== Scenario X5: a bad -MagickExe path during an ICC-strip retry fails fast and cleanly ===" -ForegroundColor Cyan
$imgX5 = Join-Path (New-Dir "scenario-x5\Series\Chapter 1") "cover.jpg"
[System.IO.File]::WriteAllText($imgX5, "ICC_MISMATCH")
$badMagickExeX5 = Join-Path $scratchDir "does_not_exist_magick.exe"

$swX5 = [System.Diagnostics.Stopwatch]::StartNew()
$totalsX5 = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-x5") -CjxlExe $fakeCjxlExe -MagickExe $badMagickExeX5 -MaxCjxlProcs 2 -FullLogging $false
$swX5.Stop()

Test-Assert ($swX5.Elapsed.TotalSeconds -lt 15) ("returned promptly instead of hanging (took " + [int]$swX5.Elapsed.TotalSeconds + "s)")
Test-Assert ($totalsX5.ConvertedFail -eq 1 -and $totalsX5.ConvertedSuccess -eq 0) ("the failed ICC-strip retry start is counted as a real failure, not silently dropped or crashed past (got ConvertedFail=" + $totalsX5.ConvertedFail + ", ConvertedSuccess=" + $totalsX5.ConvertedSuccess + ")")
Write-Host ""

# ==============================================================================
#  Scenario Y: Process.Start() throwing (a stale/bad
#  -CjxlExe path) must not hang the dispatch loop - a raw .NET
#  exception there isn't terminating in this scriptblock, so execution
#  would continue with $j.Proc left $null, and $null.HasExited never becomes
#  true, so that job would sit in $running forever. Wrapped in
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
#  Scenario Z: $looseCts's construction and
#  Register-AbortCancellationSource call sit INSIDE the function's
#  try block (same species as ZipParallelProcessing.ps1's mutex-leak
#  handling). Register-AbortCancellationSource is temporarily
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
#  Scenario AA: an animated AVIF/WebP sitting next to a same-basename
#  convertible source (e.g. animated "foo.avif" + static "foo.jpg") must not
#  be misclassified as a genuine output-path collision (a pre-pass that ran
#  before the per-job animated-skip checks and only knew extensions, not
#  animation status, would fail both sources with "Resolve the name clash
#  manually"). Animation classification runs in the SAME pre-pass that
#  builds the collision count, so "foo.jpg" converts cleanly and "foo.avif" is a Warning-tier
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
#  Scenario AC: a leaked "_tmp_*" scratch file (one whose owning cleanup path couldn't
#  run - force-killed process, locked file swallowed by a bare catch) would
#  be indistinguishable from a real loose image at Get-LooseImageCandidates'
#  own discovery boundary, since its extension (.png/.webp) is in
#  $LooseImageExtensions - the NEXT run would convert it and leave the
#  garbage output behind permanently. So it is excluded by name pattern.
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

# The BMP/HEIC/HEIF scratch patterns (and the numbered iccstrip variant)
# are covered too - a "cover_tmp_bmp2png.png" must not be
# misclassified as a genuine NeedsConversion candidate.
Test-Assert ($candidatesAC.NeedsConversion.Count -eq 1 -and $candidatesAC.NeedsConversion[0].Name -eq "real.jpg") ("only the real loose image was returned, all 7 scratch-file patterns excluded (got " + $candidatesAC.NeedsConversion.Count + " candidate(s): " + (($candidatesAC.NeedsConversion | ForEach-Object { $_.Name }) -join ", ") + ")")
Test-Assert ($candidatesAC.StaleSources.Count -eq 0) "no scratch file was misclassified as a stale source either"
Write-Host ""

# ==============================================================================
#  Scenario AC2: a never-converted
#  extension (currently just .gif - Get-NeverConvertedExtensions) must
#  NEVER be classified as a stale source, no matter its timestamp relative
#  to a same-basename .jxl. Otherwise a chapter with "01.jpg" and
#  "01.gif" would convert "01.jpg" to "01.jxl" (deleting "01.jpg"
#  normally) and leave "01.gif" untouched - but on the VERY NEXT
#  run, "01.gif" (older than the freshly-written "01.jxl") would be classified
#  as StaleSources and DELETED.
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
#  Scenario AD: the WebP VP8X-header read in the
#  collision-guard pre-pass (Scenario AA above) is wrapped in try/catch - an
#  inaccessible .webp (locked by another process, here) must not throw
#  straight out and end the whole run; it fails just that one
#  file like every other per-file I/O error here. Runs through the live
#  Invoke-LooseImageConversionPipeline (jobBuilder's try/catch around
#  Test-WebPAnimated).
# ==============================================================================
Write-Host "=== Scenario AD: a locked/unreadable .webp fails just that file, not the whole batch ===" -ForegroundColor Cyan
$chAD = New-Dir "scenario-ad\Series\Chapter 1"
$webpAD = Join-Path $chAD "locked.webp"
[System.IO.File]::WriteAllText($webpAD, "fake webp bytes")
$lockAD = [System.IO.File]::Open($webpAD, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
$threwAD = $false
$totalsAD = $null
try {
    $totalsAD = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-ad") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -FullLogging $false
} catch {
    $threwAD = $true
} finally {
    $lockAD.Dispose()
}

Test-Assert (-not $threwAD) "did NOT throw - the pipeline survives one unreadable file"
Test-Assert ($null -ne $totalsAD -and $totalsAD.ConvertedFail -eq 1) ("the locked file was counted as a real failure, not silently dropped (got ConvertedFail=" + $(if ($totalsAD) { $totalsAD.ConvertedFail } else { "<null>" }) + ")")
Write-Host ""

# ==============================================================================
#  Scenario AD2: direct
#  coverage of Test-WebPAnimated itself (see its own header) and of the
#  pipeline actually skipping a real animated WebP (the
#  animation-flag-detected/skip path, as opposed to the locked-file/error
#  path above), through the live Invoke-LooseImageConversionPipeline.
# ==============================================================================
Write-Host "=== Scenario AD2: Test-WebPAnimated direct coverage + the pipeline skips a real animated WebP ===" -ForegroundColor Cyan
function New-FakeWebp {
    <#
    .SYNOPSIS
        A minimal real WebP RIFF/VP8X header (24 bytes - the same amount
        Test-WebPAnimated itself reads) - "RIFF"/size/"WEBP"/"VP8X"/
        chunk-size/flags, with the animation bit (0x02) in the flags'
        least-significant byte set or clear per -Animated.
    #>
    param([string]$Path, [bool]$Animated)
    $bytes = New-Object byte[] 24
    [System.Text.Encoding]::ASCII.GetBytes("RIFF").CopyTo($bytes, 0)
    [System.Text.Encoding]::ASCII.GetBytes("WEBP").CopyTo($bytes, 8)
    [System.Text.Encoding]::ASCII.GetBytes("VP8X").CopyTo($bytes, 12)
    if ($Animated) { $bytes[20] = 0x02 }
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

$chAD2 = New-Dir "scenario-ad2\Series\Chapter 1"
$animatedWebpAD2 = Join-Path $chAD2 "animated.webp"
$staticWebpAD2 = Join-Path $chAD2 "static.webp"
# Deliberately OUTSIDE $chAD2 - this fixture is only for the
# direct Test-WebPAnimated unit check below, not the live-pipeline check
# further down, which scans $chAD2's real directory contents and
# would otherwise pick this up as a third file to convert.
$noVp8xWebpAD2 = Join-Path $scratchDir "scenario-ad2-no-vp8x.webp"
New-FakeWebp -Path $animatedWebpAD2 -Animated $true
New-FakeWebp -Path $staticWebpAD2 -Animated $false
[System.IO.File]::WriteAllBytes($noVp8xWebpAD2, [System.Text.Encoding]::ASCII.GetBytes("not a real webp at all"))

Test-Assert ((Test-WebPAnimated -WebPPath $animatedWebpAD2) -eq $true) "Test-WebPAnimated detects a real VP8X animation flag"
Test-Assert ((Test-WebPAnimated -WebPPath $staticWebpAD2) -eq $false) "Test-WebPAnimated reports false for a VP8X chunk with the animation bit clear"
Test-Assert ((Test-WebPAnimated -WebPPath $noVp8xWebpAD2) -eq $false) "Test-WebPAnimated reports false (not a throw) for a file with no VP8X chunk at all"

$totalsAD2 = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-ad2") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -FullLogging $false
Test-Assert ($totalsAD2.ConvertedSkipped -eq 1) ("the pipeline actually skips a real animated WebP, not converted or counted as failed (got ConvertedSkipped=" + $totalsAD2.ConvertedSkipped + ")")
Test-Assert (Test-Path -LiteralPath $animatedWebpAD2) "the real animated WebP source was left untouched, not deleted"
Test-Assert ($totalsAD2.ConvertedSuccess -eq 1) "the real static WebP in the same chapter still converts normally"
Write-Host ""

# ==============================================================================
#  Scenario AF: the outer dispatch-
#  loop catch's own bulk cleanup iterates a $running list that can
#  be STALE if Complete-ImageConversionJob throws partway through the poll
#  loop's per-pass foreach - it may still list jobs that function's own
#  finally already finished processing, including a job that already
#  converted successfully. Without the SlotReleased guard, the outer
#  catch's force-cleanup would delete that job's real, already-converted
#  .jxl output as if it belonged to a genuinely still-running, force-killed
#  job - data loss.
# ==============================================================================
#  Scenario AG: the dispatch loop's own force-kill cleanup
#  must delete a partial/corrupt .jxl a killed cjxl
#  process may have already written. Left behind, that's a non-zero-byte
#  .jxl NEWER than its source - the NEXT run's Get-LooseImageCandidates
#  classifies the source as stale and deletes it, keeping only the
#  garbage output (same species Scenario B2 already covers for the
#  ORDINARY failure path).
#
#  The generic force-kill cleanup lives in ChapterDispatch.ps1's
#  Invoke-ChapterDispatch (its own drain-loop force-kill block, proven
#  generically by ChapterDispatch.Harness.ps1's Scenarios 12/13). What's
#  still THIS pipeline's own responsibility, and wasn't otherwise proven
#  through the real pipeline, is that its own -JobAbortCleanup closure
#  (the thing that block calls per job) actually deletes a force-killed
#  job's partial .jxl - proven here with a real end-to-end abort/
#  force-kill, using the same
#  Test-AbortSignal call-count trigger as Scenario H above.
# ==============================================================================
Write-Host "=== Scenario AG: a force-killed job's partial .jxl is cleaned up by the pipeline's own JobAbortCleanup ===" -ForegroundColor Cyan
Reset-AbortState
$chAG = New-Dir "scenario-ag\Series\Chapter 1"
$fileAG = Get-Item -LiteralPath (New-FakeImage -DirPath $chAG -Name "stillrunning_ag.jpg")
[System.IO.File]::WriteAllText($fileAG.FullName, "PARTIAL_THEN_SLEEP:5000")
$expectedJxlAG = Join-Path $chAG "stillrunning_ag.jxl"

function Test-AbortSignal {
    $script:testAbortSignalCallCount++
    if ($script:testAbortSignalCallCount -eq $script:testAbortSignalTriggerAt) {
        [ConsoleCtrl]::AbortRequested = $true
    }
    & $originalTestAbortSignal
}
$script:testAbortSignalTriggerAt = 4

$totalsAG = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-ag") -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false -AbortTimeoutSeconds 1

${function:Test-AbortSignal} = $originalTestAbortSignal
Reset-AbortState

Test-Assert ($totalsAG.Aborted) "sanity check: the run was actually aborted"
Test-Assert ($totalsAG.ForceKilledCount -eq 1) ("sanity check: the still-running job was actually force-killed, not drained gracefully (got ForceKilledCount=" + $totalsAG.ForceKilledCount + ")")
Test-Assert (-not (Test-Path -LiteralPath $expectedJxlAG)) "the partial .jxl left by the force-killed job was deleted, not left as a future stale-source trap"
Write-Host ""

# ==============================================================================
#  Scenario AI: omitting
#  -DoJpegQuality falls back to a safe default (90), not 0. The risk is a
#  parameter default silently diverging from its sibling function's
#  own default (-AnimatedQuality also defaults to 90); both real call sites
#  pass it explicitly, so only this test proves the omitted-key fallback
#  itself is safe. Reads back the fake cjxl.exe's own real argument string
#  (via the ARGS_MARKER trigger) to prove --quality=90 was actually
#  received, not just that some default value exists somewhere unverified.
#  Runs through the live Invoke-LooseImageConversionPipeline (jobStarter's
#  arg-construction branches).
# ==============================================================================
Write-Host "=== Scenario AI: -JpegQuality defaults to 90 when omitted ===" -ForegroundColor Cyan
$chAI = New-Dir "scenario-ai\Series\Chapter 1"
$fileAI = Join-Path $chAI "page1.jpg"
[System.IO.File]::WriteAllText($fileAI, "ARGS_MARKER")

$totalsAI = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-ai") -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false

$expectedJxlAI = Join-Path $chAI "page1.jxl"
Test-Assert ($totalsAI.ConvertedSuccess -eq 1 -and $totalsAI.ConvertedFail -eq 0) "sanity check: the conversion itself succeeded"
$argsTextAI = Get-Content -LiteralPath $expectedJxlAI -Raw
Test-Assert ($argsTextAI -match "--quality=90(\s|$)") ("omitting -JpegQuality produced --quality=90, not --quality=0 (got: '" + $argsTextAI.Trim() + "')")
Write-Host ""

# ==============================================================================
#  Scenario AJ: every cjxl
#  invocation passes --num_threads=1, on all three argument-building
#  branches (lossless JPEG, lossy JPEG, non-JPEG). Otherwise cjxl's
#  own default ("-1" = use machine default) would apply, and each
#  concurrently-dispatched process would grab its own machine-default thread
#  pool independently of -MaxCjxlProcs. Same ARGS_MARKER
#  technique as Scenario AI, one file per branch, as three live
#  Invoke-LooseImageConversionPipeline runs (-JpegLossless/-JpegQuality are
#  pipeline-level, not per-file).
# ==============================================================================
Write-Host "=== Scenario AJ: every cjxl invocation pins --num_threads=1 ===" -ForegroundColor Cyan
$chAJLossless = New-Dir "scenario-aj-lossless\Series\Chapter 1"
$chAJLossy    = New-Dir "scenario-aj-lossy\Series\Chapter 1"
$chAJPng      = New-Dir "scenario-aj-png\Series\Chapter 1"

$fileAJLosslessJpeg = Join-Path $chAJLossless "lossless.jpg"
[System.IO.File]::WriteAllText($fileAJLosslessJpeg, "ARGS_MARKER")
$fileAJLossyJpeg = Join-Path $chAJLossy "lossy.jpg"
[System.IO.File]::WriteAllText($fileAJLossyJpeg, "ARGS_MARKER")
$fileAJPng = Join-Path $chAJPng "plain.png"
[System.IO.File]::WriteAllText($fileAJPng, "ARGS_MARKER")

$null = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-aj-lossless") -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false -JpegLossless $true
$null = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-aj-lossy") -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false -JpegLossless $false -JpegQuality 80
$null = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-aj-png") -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false

$argsLosslessAJ = Get-Content -LiteralPath (Join-Path $chAJLossless "lossless.jxl") -Raw
$argsLossyAJ    = Get-Content -LiteralPath (Join-Path $chAJLossy "lossy.jxl") -Raw
$argsPngAJ      = Get-Content -LiteralPath (Join-Path $chAJPng "plain.jxl") -Raw
Test-Assert ($argsLosslessAJ -match "--num_threads=1(\s|$)") ("lossless-JPEG branch pins --num_threads=1 (got: '" + $argsLosslessAJ.Trim() + "')")
Test-Assert ($argsLossyAJ -match "--num_threads=1(\s|$)") ("lossy-JPEG branch pins --num_threads=1 (got: '" + $argsLossyAJ.Trim() + "')")
Test-Assert ($argsPngAJ -match "--num_threads=1(\s|$)") ("non-JPEG branch pins --num_threads=1 (got: '" + $argsPngAJ.Trim() + "')")
Write-Host ""

# ==============================================================================
#  Scenario AL: the cjxl job in the dispatch
#  loop is polled via HasExited, not read synchronously inline - both
#  redirected streams must be drained as soon as the process starts (not
#  only once it's found HasExited), or a cjxl that writes more than the
#  OS pipe buffer to stderr before exiting would block on that write
#  forever, hanging the whole batch with no error and no timeout.
#  Run on a background runspace with a bounded wait, NOT called directly -
#  a real regression here would hang forever, and this proves it fails
#  the assertion instead of hanging the whole harness process. Runs the
#  live Invoke-LooseImageConversionPipeline (jobStarter's async
#  stdout/stderr-drain pattern).
# ==============================================================================
Write-Host "=== Scenario AL: a cjxl job with a stderr flood does not deadlock the dispatch loop ===" -ForegroundColor Cyan
$chAL = New-Dir "scenario-al\Series\Chapter 1"
$fileAL = Join-Path $chAL "flood_al.jpg"
[System.IO.File]::WriteAllText($fileAL, "STDERR_FLOOD")

$runspaceAL = [runspacefactory]::CreateRunspace()
$runspaceAL.Open()
$psAL = [PowerShell]::Create()
$psAL.Runspace = $runspaceAL
$null = $psAL.AddScript({
    param($ModulesDir, $CjxlExe, $LibraryPath)
    . (Join-Path $ModulesDir "FileDeletion.ps1")
    . (Join-Path $ModulesDir "AbortPipeline.ps1")
    . (Join-Path $ModulesDir "LeafDirectoryDiscovery.ps1")
    . (Join-Path $ModulesDir "CleanConsoleRendering.ps1")
    . (Join-Path $ModulesDir "Logging.ps1")
    . (Join-Path $ModulesDir "ChapterDispatch.ps1")
    . (Join-Path $ModulesDir "AnimatedConversionPipeline.ps1")
    . (Join-Path $ModulesDir "ImageConversionPipeline.ps1")
    Initialize-FileDeletion -PermanentDelete $true
    Initialize-LogPaths -TargetPath $LibraryPath -FullLogging $false -ScriptDir $LibraryPath
    Invoke-LooseImageConversionPipeline -Path $LibraryPath -CjxlExe $CjxlExe -MaxCjxlProcs 2 -FullLogging $false
}).AddArgument($modulesDir).AddArgument($fakeCjxlExe).AddArgument((Join-Path $scratchDir "scenario-al"))

$handleAL = $psAL.BeginInvoke()
$completedAL = $handleAL.AsyncWaitHandle.WaitOne(15000)
if ($completedAL) {
    $totalsAL = $psAL.EndInvoke($handleAL)[0]
} else {
    $psAL.Stop()
}
$psAL.Dispose()
$runspaceAL.Close()
$runspaceAL.Dispose()

Test-Assert $completedAL "the pipeline returned within 15s instead of hanging on the stderr flood"
if ($completedAL) {
    Test-Assert ($totalsAL.ConvertedSuccess -eq 1) ("the file still converted successfully despite the stderr flood (got ConvertedSuccess=" + $totalsAL.ConvertedSuccess + ")")
}
Write-Host ""

# ==============================================================================
#  Scenario AM: an abort raised mid-jobBuilder stops per-file AVIF
#  classification - no further magick identify spawns for the rest of the
#  chapter. Test-AbortSignal flips the abort as soon as the first identify
#  call has been logged, so exactly 1 of the 3 AVIFs gets classified.
# ==============================================================================
Write-Host "=== Scenario AM: abort mid-chapter stops per-file AVIF identify spawns ===" -ForegroundColor Cyan
Reset-AbortState
$chAM = New-Dir "scenario-am\Series\Chapter 1"
foreach ($n in 1..3) { $null = New-FakeAvif -DirPath $chAM -Name ("p" + $n + ".avif") -Content "FRAMES:1" }
$identifyLogAM = Join-Path $scratchDir "scenario-am-identify.log"
$env:HARNESS_IDENTIFY_LOG = $identifyLogAM
function Test-AbortSignal {
    if ([System.IO.File]::Exists($identifyLogAM) -and [System.IO.File]::ReadAllLines($identifyLogAM).Count -ge 1) {
        [ConsoleCtrl]::AbortRequested = $true
    }
    & $originalTestAbortSignal
}
try {
    $totalsAM = Invoke-LooseImageConversionPipeline -Path (Join-Path $scratchDir "scenario-am") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -FullLogging $false -AbortTimeoutSeconds 1
} finally {
    ${function:Test-AbortSignal} = $originalTestAbortSignal
    Remove-Item Env:\HARNESS_IDENTIFY_LOG -ErrorAction SilentlyContinue
    Reset-AbortState
}
$identifyCountAM = if ([System.IO.File]::Exists($identifyLogAM)) { [System.IO.File]::ReadAllLines($identifyLogAM).Count } else { 0 }
Test-Assert ($totalsAM.Aborted) "sanity check: the run was actually aborted"
Test-Assert ($identifyCountAM -eq 1) ("only the AVIF classified before the abort spawned magick identify (got " + $identifyCountAM + " identify call(s), expected 1)")
Test-Assert ($totalsAM.ConvertedSuccess -eq 0) ("nothing converted after the abort (got ConvertedSuccess=" + $totalsAM.ConvertedSuccess + ")")
Test-Assert (@([System.IO.Directory]::GetFiles($chAM, "*.avif")).Count -eq 3) "all 3 AVIF sources left untouched"
Write-Host ""

# ==============================================================================
#  Scenario QD: CCR shows a walk-ahead chapter as "queued" until its first job
#  actually starts. Two chapters, one conversion slot: the dispatch builds
#  (announces) both before starting anything, so when Chapter 1's first job
#  starts, Chapter 2 must still be showing as queued - it flips only when its
#  own job starts. Spies wrap the real CCR functions.
# ==============================================================================
Write-Host "=== Scenario QD: queued -> in progress flip happens at first job start, once per chapter ===" -ForegroundColor Cyan
$rootQD = New-Dir "scenario-qd"
$chQD1 = New-Dir "scenario-qd\Series QD\Chapter 1"
$chQD2 = New-Dir "scenario-qd\Series QD\Chapter 2"
New-FakeImage -DirPath $chQD1 -Name "page1.jpg" | Out-Null
New-FakeImage -DirPath $chQD2 -Name "page1.jpg" | Out-Null
$script:startsQD = New-Object System.Collections.Generic.List[hashtable]
$script:flipsQD  = New-Object System.Collections.Generic.List[hashtable]
$script:realStartQDRef = ${function:Start-ChapterProgress}
$script:realFlipQDRef  = ${function:Set-ChapterInProgress}
function Start-ChapterProgress {
    param([string]$SeriesName, [string]$ChapterName, [switch]$Queued)
    $script:startsQD.Add(@{ ChapterName = $ChapterName; Queued = [bool]$Queued })
    & $script:realStartQDRef -SeriesName $SeriesName -ChapterName $ChapterName -Queued:$Queued
}
function Set-ChapterInProgress {
    param([string]$SeriesName, [string]$ChapterName)
    $e = $script:ccrActiveSeries[$SeriesName]
    $script:flipsQD.Add(@{ ChapterName = $ChapterName; WasQueued = $e.QueuedChapters.Contains($ChapterName); OthersQueued = @($e.QueuedChapters | Where-Object { $_ -ne $ChapterName }) })
    & $script:realFlipQDRef -SeriesName $SeriesName -ChapterName $ChapterName
}
$script:CleanConsoleOutputEnabled = $true
try {
    $totalsQD = Invoke-LooseImageConversionPipeline -Path $rootQD -CjxlExe $fakeCjxlExe -MaxCjxlProcs 1 -FullLogging $false
} finally {
    $script:CleanConsoleOutputEnabled = $false
    ${function:Start-ChapterProgress} = $script:realStartQDRef
    ${function:Set-ChapterInProgress} = $script:realFlipQDRef
}
$flip1QD = @($script:flipsQD | Where-Object { $_.ChapterName -eq "Chapter 1" })
$flip2QD = @($script:flipsQD | Where-Object { $_.ChapterName -eq "Chapter 2" })
Test-Assert (@($script:startsQD | Where-Object { $_.Queued }).Count -eq 2) ("both chapters were announced as queued (got " + @($script:startsQD | Where-Object { $_.Queued }).Count + " of " + $script:startsQD.Count + ")")
Test-Assert ($flip1QD.Count -eq 1 -and $flip2QD.Count -eq 1) ("each chapter flipped to in progress exactly once (got " + $flip1QD.Count + "/" + $flip2QD.Count + ")")
Test-Assert ($flip1QD.Count -eq 1 -and $flip1QD[0].WasQueued -and ($flip1QD[0].OthersQueued -contains "Chapter 2")) "when Chapter 1's first job started, Chapter 2 was still showing as queued (the walk-ahead case)"
Test-Assert ($flip2QD.Count -eq 1 -and $flip2QD[0].WasQueued) "Chapter 2 was queued right up until its own first job started"
Test-Assert ($script:ccrActiveSeries.Count -eq 0) "the series still resolves and leaves the live region"
Test-Assert ($totalsQD.ConvertedSuccess -eq 2) ("both chapters still converted (got ConvertedSuccess=" + $totalsQD.ConvertedSuccess + ")")
Write-Host ""

# ==============================================================================
#  Scenario AN: Complete-ImageDispatchJob's read of the finished
#  process's stdout/stderr is bounded and tolerates a failed read. A bare
#  GetAwaiter().GetResult() would let a pipe held open (a delegate process
#  magick spawned) stall the engine forever, and a faulted read would throw out
#  of JobFinalize. Success is still judged by exit code and output file.
#  DOCUMENTED DUPLICATE of AnimatedConversionPipeline.Harness.ps1's own Scenario AN -
#  keep both in sync.
# ==============================================================================
Write-Host "=== Scenario AN: a stuck or failed output-stream read does not stall or crash job finalize ===" -ForegroundColor Cyan
$dirAN = New-Dir "scenario-an"
function New-StreamJobAN {
    param([string]$Name, $StdoutTask, $StderrTask)
    $srcAN = Join-Path $dirAN ($Name + ".src")
    $outAN = Join-Path $dirAN ($Name + ".out")
    [System.IO.File]::WriteAllText($srcAN, "source")
    [System.IO.File]::WriteAllText($outAN, "converted")
    return @{ SrcPath = $srcAN; JxlPath = $outAN; Proc = [pscustomobject]@{ ExitCode = 0 }; StdoutTask = $StdoutTask; StderrTask = $StderrTask; ChapterKey = "an" }
}
$doneAN = [System.Threading.Tasks.TaskCompletionSource[string]]::new(); $doneAN.SetResult("")
$neverAN = [System.Threading.Tasks.TaskCompletionSource[string]]::new()
$faultAN = [System.Threading.Tasks.TaskCompletionSource[string]]::new(); $faultAN.SetException([System.IO.IOException]::new("simulated broken pipe"))

$crAN = @{ ConvertedCount = 0; FailedCount = 0; DeletedCount = 0; DeleteFailedCount = 0 }
$swAN = [System.Diagnostics.Stopwatch]::StartNew()
$outputAN = @(& { Complete-ImageDispatchJob -Job (New-StreamJobAN -Name "stuck" -StdoutTask $neverAN.Task -StderrTask $doneAN.Task) -ChapterResult $crAN -PendingQueue ([System.Collections.Generic.Queue[hashtable]]::new()) -MagickExe "" -DoFullLogging $false -StreamReadTimeoutMs 300 } 6>&1)
$swAN.Stop()
$resultAN = @($outputAN | Where-Object { $_ -is [hashtable] })
Test-Assert ($swAN.Elapsed.TotalSeconds -lt 5) ("a stream that never finishes reading is given up on after the timeout (took " + [math]::Round($swAN.Elapsed.TotalSeconds, 2) + "s)")
Test-Assert ($resultAN.Count -eq 1 -and $resultAN[0].Success -eq $true -and $crAN.ConvertedCount -eq 1) "the conversion still counts as a success - exit code 0 and a real output file"
Test-Assert (@($outputAN | Where-Object { "$_" -like "*did not finish reading within*" }).Count -eq 1) "the timed-out read is logged as a warning"

$crAN2 = @{ ConvertedCount = 0; FailedCount = 0; DeletedCount = 0; DeleteFailedCount = 0 }
$threwAN2 = $false
$outputAN2 = @()
try {
    $outputAN2 = @(& { Complete-ImageDispatchJob -Job (New-StreamJobAN -Name "faulted" -StdoutTask $doneAN.Task -StderrTask $faultAN.Task) -ChapterResult $crAN2 -PendingQueue ([System.Collections.Generic.Queue[hashtable]]::new()) -MagickExe "" -DoFullLogging $false -StreamReadTimeoutMs 300 } 6>&1)
} catch {
    $threwAN2 = $true
}
$resultAN2 = @($outputAN2 | Where-Object { $_ -is [hashtable] })
Test-Assert (-not $threwAN2) "a faulted stream read does not throw out of job finalize"
Test-Assert ($resultAN2.Count -eq 1 -and $resultAN2[0].Success -eq $true -and $crAN2.ConvertedCount -eq 1) "and the conversion is still judged by exit code and output file"
Test-Assert (@($outputAN2 | Where-Object { "$_" -like "*simulated broken pipe*" }).Count -eq 1) "the failed read is logged as a warning with its cause"
Write-Host ""

# ==============================================================================
#  Scenario AO: series covers. A cover.* directly in a series folder is never
#  converted as a loose image; once per series it is normalised to a
#  lower-case cover.jpg. A cover.* inside a chapter folder is an ordinary page.
# ==============================================================================
Write-Host "=== Scenario AO: series cover is skipped and normalised to cover.jpg ===" -ForegroundColor Cyan
$rootAO = New-Dir "scenario-ao"
$seriesNamesAO = @("Webp", "Jpeg", "Jpg", "MixedCase", "Both", "Fail", "ChapterCover")
foreach ($n in $seriesNamesAO) { New-FakeImage -DirPath (New-Dir ("scenario-ao\" + $n + "\Ch1")) -Name "p1.jpg" | Out-Null }
$sAO = @{}; foreach ($n in $seriesNamesAO) { $sAO[$n] = Join-Path $rootAO $n }

[System.IO.File]::WriteAllText((Join-Path $sAO.Webp "cover.webp"), "webp cover pixels")
[System.IO.File]::WriteAllText((Join-Path $sAO.Jpeg "Cover.JPEG"), "jpeg cover pixels")
$jpgAO = Join-Path $sAO.Jpg "COVER.Jpg"
[System.IO.File]::WriteAllText($jpgAO, "jpg cover pixels")
$jpgStampAO = [datetime]::new(2020, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc)
[System.IO.File]::SetLastWriteTimeUtc($jpgAO, $jpgStampAO)
[System.IO.File]::WriteAllText((Join-Path $sAO.MixedCase "CoVeR.PNG"), "png cover pixels")
[System.IO.File]::WriteAllText((Join-Path $sAO.Both "cover.jpg"), "jpg cover pixels")
[System.IO.File]::WriteAllText((Join-Path $sAO.Both "cover.webp"), "webp cover pixels")
[System.IO.File]::WriteAllText((Join-Path $sAO.Fail "cover.webp"), "FAIL_MAGICK_PARTIAL")
New-FakeImage -DirPath (Join-Path $sAO.ChapterCover "Ch1") -Name "cover.jpg" | Out-Null

$candidatesAO = Get-LooseImageCandidates -ScanPath $sAO.Webp
Test-Assert (@($candidatesAO.NeedsConversion | Where-Object { $_.Name -eq 'cover.webp' }).Count -eq 0) "Get-LooseImageCandidates leaves the series-root cover out"
Test-Assert (@($candidatesAO.NeedsConversion | Where-Object { $_.Name -eq 'p1.jpg' }).Count -eq 1) "and still returns the chapter's page"

$script:logEntriesAO = [System.Collections.Generic.List[hashtable]]::new()
$realWriteLogFnAO = ${function:Write-Log}
function Write-Log {
    param([string]$Message, [ValidateSet("Info", "Warn", "Error", "Summary")][string]$Level = "Info")
    $script:logEntriesAO.Add(@{ Message = $Message; Level = $Level })
    & $script:realWriteLogFnAORef -Message $Message -Level $Level
}
$script:realWriteLogFnAORef = $realWriteLogFnAO
try {
    $totalsAO = Invoke-LooseImageConversionPipeline -Path $rootAO -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -MaxCjxlProcs 2 -FullLogging $false
} finally {
    ${function:Write-Log} = $realWriteLogFnAO
}
function Read-TextOrNullAO { param([string]$Path) if ([System.IO.File]::Exists($Path)) { return [System.IO.File]::ReadAllText($Path) } return $null }
function Get-NamesAO { param([string]$Dir) return ,@([System.IO.Directory]::GetFiles($Dir) | ForEach-Object { [System.IO.Path]::GetFileName($_) }) }

Test-Assert ($totalsAO.ConvertedSuccess -eq 8 -and $totalsAO.ConvertedFail -eq 0) ("only the 7 chapter pages and the chapter-folder cover.jpg were converted (got ConvertedSuccess=" + $totalsAO.ConvertedSuccess + ", ConvertedFail=" + $totalsAO.ConvertedFail + ")")
Test-Assert (@($seriesNamesAO | Where-Object { Test-Path -LiteralPath (Join-Path $sAO[$_] "cover.jxl") }).Count -eq 0) "no series-root cover was converted to cover.jxl"
Test-Assert ($totalsAO.CoverNormalizedSuccess -eq 3 -and $totalsAO.CoverNormalizedFail -eq 1) ("3 covers normalised, 1 failed (got Success=" + $totalsAO.CoverNormalizedSuccess + ", Fail=" + $totalsAO.CoverNormalizedFail + ")")

$namesWebpAO = Get-NamesAO $sAO.Webp
Test-Assert (($namesWebpAO -ccontains 'cover.jpg') -and -not ($namesWebpAO -contains 'cover.webp')) ("cover.webp was converted to cover.jpg and the original removed (files: " + ($namesWebpAO -join ', ') + ")")
Test-Assert ((Read-TextOrNullAO (Join-Path $sAO.Webp "cover.jpg")) -eq "webp cover pixels") "cover.jpg was produced from the webp (fake magick copies the source)"

$namesJpegAO = Get-NamesAO $sAO.Jpeg
Test-Assert (($namesJpegAO -ccontains 'cover.jpg') -and $namesJpegAO.Count -eq 1) ("Cover.JPEG was renamed to lower-case cover.jpg (files: " + ($namesJpegAO -join ', ') + ")")
Test-Assert ((Read-TextOrNullAO (Join-Path $sAO.Jpeg "cover.jpg")) -eq "jpeg cover pixels") "the rename kept the original bytes - no re-encode"

$namesJpgAO = Get-NamesAO $sAO.Jpg
Test-Assert (($namesJpgAO -ccontains 'COVER.Jpg') -and $namesJpgAO.Count -eq 1) ("COVER.Jpg was left exactly as named (files: " + ($namesJpgAO -join ', ') + ")")
Test-Assert ([System.IO.File]::GetLastWriteTimeUtc($jpgAO) -eq $jpgStampAO) "COVER.Jpg's timestamp is unchanged - not touched"

$namesMixedAO = Get-NamesAO $sAO.MixedCase
Test-Assert (($namesMixedAO -ccontains 'cover.jpg') -and $namesMixedAO.Count -eq 1) ("CoVeR.PNG was converted to lower-case cover.jpg (files: " + ($namesMixedAO -join ', ') + ")")

$namesBothAO = Get-NamesAO $sAO.Both
Test-Assert (($namesBothAO -contains 'cover.jpg') -and ($namesBothAO -contains 'cover.webp') -and $namesBothAO.Count -eq 2) ("a JPEG cover plus another cover: both left alone (files: " + ($namesBothAO -join ', ') + ")")
Test-Assert (@($script:logEntriesAO | Where-Object { $_.Level -eq 'Warn' -and $_.Message -like "*more than one cover file*" -and $_.Message -like "*Both*" }).Count -eq 1) "and a warning was logged for it"

$namesFailAO = Get-NamesAO $sAO.Fail
Test-Assert (($namesFailAO -contains 'cover.webp') -and -not ($namesFailAO -contains 'cover.jpg')) ("a failed conversion leaves the original and removes the partial cover.jpg (files: " + ($namesFailAO -join ', ') + ")")
Test-Assert (@($script:logEntriesAO | Where-Object { $_.Level -eq 'Error' -and $_.Message -like "*FAILED to convert series cover*Fail*" }).Count -eq 1) "and an error was logged for it"
Test-Assert (Test-Path -LiteralPath (Join-Path $sAO.Fail "Ch1\p1.jxl")) "the failed cover's series still converted its chapter"

Test-Assert (Test-Path -LiteralPath (Join-Path $sAO.ChapterCover "Ch1\cover.jxl")) "a cover.jpg inside a chapter folder is still converted as a page"
Test-Assert (@($script:logEntriesAO | Where-Object { $_.Message -like "*series cover*" -and $_.Level -eq 'Info' }).Count -eq 3) "one log line per cover renamed or converted"
Write-Host ""

# ==============================================================================
#  Scenario AO2: a non-image cover.* (cover.json, cover.txt) sitting next to
#  the real cover isn't counted as a second cover.
# ==============================================================================
Write-Host "=== Scenario AO2: non-image cover.* files don't block normalisation ===" -ForegroundColor Cyan
$seriesAO2 = New-Dir "scenario-ao2\Series"
[System.IO.File]::WriteAllText((Join-Path $seriesAO2 "cover.webp"), "webp cover pixels")
[System.IO.File]::WriteAllText((Join-Path $seriesAO2 "cover.json"), "{}")
[System.IO.File]::WriteAllText((Join-Path $seriesAO2 "Cover.TXT"), "notes")
$resultAO2 = Invoke-SeriesCoverNormalization -SeriesPath $seriesAO2 -MagickExe $fakeMagickExe
$namesAO2 = @([System.IO.Directory]::GetFiles($seriesAO2) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
Test-Assert ($resultAO2.Success -eq 1 -and $resultAO2.Fail -eq 0) ("the webp cover was converted (got Success=" + $resultAO2.Success + ", Fail=" + $resultAO2.Fail + ")")
Test-Assert (($namesAO2 -ccontains 'cover.jpg') -and -not ($namesAO2 -contains 'cover.webp') -and ($namesAO2 -contains 'cover.json') -and ($namesAO2 -contains 'Cover.TXT')) ("cover.jpg made, the json/txt left alone (files: " + ($namesAO2 -join ', ') + ")")
Write-Host ""

# ==============================================================================
#  Scenario AO3: Invoke-BoundedProcess (ChapterDispatch.ps1), the shared
#  bounded run behind the cover conversion, ICC-strip retry and AVIF probe.
# ==============================================================================
Write-Host "=== Scenario AO3: Invoke-BoundedProcess ===" -ForegroundColor Cyan
$cmdAO3 = Join-Path $env:SystemRoot "System32\cmd.exe"
$okAO3 = Invoke-BoundedProcess -FilePath $cmdAO3 -Arguments "/c echo out-text& echo err-text 1>&2& exit 3" -ExitTimeoutMs 30000
Test-Assert ($null -eq $okAO3.StartError -and -not $okAO3.TimedOut -and -not $okAO3.StreamTimedOut) "a quick process finishes cleanly"
Test-Assert ($okAO3.ExitCode -eq 3) ("its exit code comes back (got " + $okAO3.ExitCode + ")")
Test-Assert (($okAO3.Stdout -like "*out-text*") -and ($okAO3.Stderr -like "*err-text*")) "stdout and stderr are both captured"
$slowAO3 = Invoke-BoundedProcess -FilePath $cmdAO3 -Arguments "/c ping -n 30 127.0.0.1 >nul" -ExitTimeoutMs 500
Test-Assert ($slowAO3.TimedOut -and $null -eq $slowAO3.ExitCode) "a process past its exit timeout is reported as timed out"
$missingAO3 = Invoke-BoundedProcess -FilePath (Join-Path $scratchDir "no-such.exe") -Arguments "x" -ExitTimeoutMs 1000
Test-Assert ($null -ne $missingAO3.StartError) "a missing executable comes back as StartError, not a throw"
Write-Host ""

if ($script:failCount -eq 0) {
    Write-Host ("ALL PASSED  (" + $script:passCount + " assertions)") -ForegroundColor Green
    exit 0
} else {
    Write-Host ($script:failCount.ToString() + " FAILED, " + $script:passCount.ToString() + " passed") -ForegroundColor Red
    exit 1
}
