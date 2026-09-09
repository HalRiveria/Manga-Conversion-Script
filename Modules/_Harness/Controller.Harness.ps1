<#
.SYNOPSIS
    Standalone test harness for Modules\Controller.ps1.

.DESCRIPTION
    Integration-style, like ZipPipeline.Harness.ps1/RezipPipeline.Harness.ps1/
    ImageConversionPipeline.Harness.ps1 - dot-sources the REAL Logging.ps1/
    FileDeletion.ps1/ZipCreation.ps1/ZipValidation.ps1/LeafDirectoryDiscovery.ps1/
    AbortPipeline.ps1/CleanConsoleRendering.ps1/ZipParallelProcessing.ps1/
    ImageConversionPipeline.ps1/AnimatedConversionPipeline.ps1/Summary.ps1
    (the last one for Invoke-Mode's New-StatsTracker output shape - NOT
    ZipPipeline.ps1/RezipPipeline.ps1, since every Invoke-Mode scenario
    below injects a fake -ZipFoldersHandler/-ConvertZippedHandler rather
    than exercising the real ones; Controller.ps1 also calls
    Compress-FolderToZip/Test-ZipArchive directly for Full Pipeline's
    own zip step, not Invoke-LooseFolderZip, see Controller.ps1's own
    header for why),
    since Controller.ps1 is a top-tier orchestrator whose real value is in
    proving the two-runspace-per-chapter dispatch, the shared process
    budget, the merged CCR status, and the zip-blocking policy actually
    work end to end - not in mocking that machinery away.

    Two compiled fake executables (fake_cjxl.exe, fake_magick.exe) - same
    technique as ImageConversionPipeline.Harness.ps1/
    AnimatedConversionPipeline.Harness.ps1's own fakes, PLUS a peak-
    concurrency tracker: when the HARNESS_PEAK_DIR environment variable is
    set, both fakes increment a shared, mutex-guarded counter on start and
    decrement it on exit, recording the highest value ever seen to
    peak.txt. This is the only way to actually PROVE the shared budget
    caps combined concurrency across two real OS-process-spawning engines
    running in separate runspaces - final counts alone would look
    identical whether real sharing happened or not.

.EXAMPLE
    .\Modules\_Harness\Controller.Harness.ps1
#>

$ErrorActionPreference = "Stop"

$modulesDir = Join-Path $PSScriptRoot ".."
. (Join-Path $modulesDir "Logging.ps1")
. (Join-Path $modulesDir "FileDeletion.ps1")
. (Join-Path $modulesDir "ZipCreation.ps1")
. (Join-Path $modulesDir "ZipValidation.ps1")
. (Join-Path $modulesDir "LeafDirectoryDiscovery.ps1")
. (Join-Path $modulesDir "AbortPipeline.ps1")
. (Join-Path $modulesDir "CleanConsoleRendering.ps1")
. (Join-Path $modulesDir "ZipParallelProcessing.ps1")
. (Join-Path $modulesDir "ImageConversionPipeline.ps1")
. (Join-Path $modulesDir "AnimatedConversionPipeline.ps1")
. (Join-Path $modulesDir "Summary.ps1")
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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("controller-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray

Initialize-FileDeletion -PermanentDelete $true
Initialize-LogPaths -TargetPath $scratchDir -FullLogging $false -ScriptDir $scratchDir

function New-Dir {
    param([string]$RelativePath)
    $path = Join-Path $scratchDir $RelativePath
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}
function New-FakeImageIn {
    param([string]$DirPath, [string]$Name, [bool]$Fail = $false, [int]$SleepMs = 0)
    $path = Join-Path $DirPath $Name
    $content = if ($Fail) { "FAIL_CJXL" } elseif ($SleepMs -gt 0) { "SLEEP_MS:" + $SleepMs } else { "fake source pixels" }
    [System.IO.File]::WriteAllText($path, $content)
    return $path
}
function New-FakeAvifIn {
    param([string]$DirPath, [string]$Name, [int]$Frames = 5, [bool]$Fail = $false, [int]$SleepMs = 0)
    $path = Join-Path $DirPath $Name
    $content = "FRAMES:" + $Frames + $(if ($Fail) { "`nFAIL_MAGICK" } else { "" }) + $(if ($SleepMs -gt 0) { "`nSLEEP_MS:" + $SleepMs } else { "" })
    [System.IO.File]::WriteAllText($path, $content)
    return $path
}

# ------------------------------------------------------------------
#  Fake cjxl.exe / fake magick.exe - same behavior as
#  ImageConversionPipeline.Harness.ps1's / AnimatedConversionPipeline.
#  Harness.ps1's own fakes, PLUS peak-concurrency tracking gated on the
#  HARNESS_PEAK_DIR environment variable (a mutex-guarded increment on
#  start, decrement on exit, recording the max value ever seen to
#  peak.txt in that directory) - the only way to prove real cross-
#  process, cross-engine concurrency sharing rather than just inferring
#  it from final counts.
# ------------------------------------------------------------------
$peakTrackerSource = @'
static void PeakBump(int delta) {
    string dir = Environment.GetEnvironmentVariable("HARNESS_PEAK_DIR");
    if (dir == null) return;
    using (var mtx = new System.Threading.Mutex(false, "ControllerHarnessPeakMutex")) {
        mtx.WaitOne();
        try {
            string curPath = System.IO.Path.Combine(dir, "current.txt");
            string peakPath = System.IO.Path.Combine(dir, "peak.txt");
            int cur = System.IO.File.Exists(curPath) ? int.Parse(System.IO.File.ReadAllText(curPath)) : 0;
            cur += delta;
            if (cur < 0) cur = 0;
            System.IO.File.WriteAllText(curPath, cur.ToString());
            int peak = System.IO.File.Exists(peakPath) ? int.Parse(System.IO.File.ReadAllText(peakPath)) : 0;
            if (cur > peak) System.IO.File.WriteAllText(peakPath, cur.ToString());
        } finally { mtx.ReleaseMutex(); }
    }
}
'@

$fakeCjxlSourceTemplate = @'
using System;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;
class Program {
##PEAKTRACKER##
    static int Main(string[] args) {
        string src = args[0];
        string dst = args[1];
        string content = File.Exists(src) ? File.ReadAllText(src) : "";
        if (content.Contains("FAIL_CJXL")) {
            Console.Error.WriteLine("simulated cjxl failure");
            return 1;
        }
        PeakBump(1);
        try {
            // Written before the sleep so a test can poll for "the job has
            // actually started" instead of guessing a wall-clock delay -
            // see Scenario C4/C6's own comments in Controller.Harness.ps1.
            File.WriteAllText(dst + ".started", "");
            Match m = Regex.Match(content, "SLEEP_MS:(\\d+)");
            if (m.Success) { Thread.Sleep(int.Parse(m.Groups[1].Value)); }
            if (content.Contains("ARGS_MARKER")) {
                // Lets a test read back the real arguments this fake was
                // invoked with (2026-09-02, recurring-bug-pattern coverage -
                // see Scenario Z3) - e.g. proving a real --quality=<N> value
                // was actually received from the worker scriptblock's own
                // default, not just that SOME .jxl got written.
                File.WriteAllText(dst, "ARGS:" + string.Join(" ", args));
            } else {
                File.WriteAllText(dst, "fake-jxl-bytes");
            }
        } finally { PeakBump(-1); }
        return 0;
    }
}
'@
$fakeCjxlSource = $fakeCjxlSourceTemplate.Replace('##PEAKTRACKER##', $peakTrackerSource)
$fakeCjxlExe = Join-Path $scratchDir "fake_cjxl.exe"
Add-Type -TypeDefinition $fakeCjxlSource -Language CSharp -OutputAssembly $fakeCjxlExe -OutputType ConsoleApplication

$fakeMagickSourceTemplate = @'
using System;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;
class Program {
##PEAKTRACKER##
    static int Main(string[] args) {
        if (args.Length > 0 && args[0] == "identify") {
            // 2026-09-09: Test-AvifAnimated now addresses frame [0] only
            // (a real perf fix - see AnimatedConversionPipeline.ps1's own
            // header) - strip that trailing selector to find the real
            // fixture file on disk.
            string rawPath = args[args.Length - 1];
            string path = Regex.Replace(rawPath, "\\[\\d+\\]$", "");
            // Logs each identify call's target path (gated on an env var
            // so unrelated scenarios pay nothing) - lets a test count how
            // many times Test-AvifAnimated actually spawned magick for a
            // given file, proving the 2026-08-31 double-classification fix
            // (Controller.ps1's own classification result threaded through
            // to Convert-AnimatedBatch instead of it re-checking).
            string identifyLog = Environment.GetEnvironmentVariable("HARNESS_IDENTIFY_LOG");
            if (identifyLog != null) {
                using (var mtx = new System.Threading.Mutex(false, "ControllerHarnessIdentifyLogMutex")) {
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
            // Test-AvifAnimated now reads a simulated animation delay
            // (nonzero = animated, "0" = static), not a raw frame count -
            // see AnimatedConversionPipeline.Harness.ps1's fake magick.exe
            // for the same translation.
            int delay = frames > 1 ? 1000 : 0;
            Console.Write(delay.ToString());
            return 0;
        }

        string src = args[0];
        string dst = args[args.Length - 1];
        string srcContent = File.Exists(src) ? File.ReadAllText(src) : "";

        if (srcContent.Contains("FAIL_MAGICK")) {
            Console.Error.WriteLine("simulated magick conversion failure");
            return 1;
        }
        PeakBump(1);
        try {
            Match sm = Regex.Match(srcContent, "SLEEP_MS:(\\d+)");
            if (sm.Success) { Thread.Sleep(int.Parse(sm.Groups[1].Value)); }
            File.WriteAllText(dst, "ARGS:" + string.Join(" ", args));
        } finally { PeakBump(-1); }
        return 0;
    }
}
'@
$fakeMagickSource = $fakeMagickSourceTemplate.Replace('##PEAKTRACKER##', $peakTrackerSource)
$fakeMagickExe = Join-Path $scratchDir "fake_magick.exe"
Add-Type -TypeDefinition $fakeMagickSource -Language CSharp -OutputAssembly $fakeMagickExe -OutputType ConsoleApplication

Write-Host ""

# ==============================================================================
#  Scenario A: one chapter, both engines have work, both succeed - real
#  concurrent dispatch, correct merged Success status, real zip created,
#  both sources deleted.
# ==============================================================================
Write-Host "=== Scenario A: both engines succeed, chapter zips ===" -ForegroundColor Cyan
$rootA = New-Dir "scenario-a"
$chA = New-Dir "scenario-a\Series\Chapter 1"
New-FakeImageIn -DirPath $chA -Name "page1.jpg" | Out-Null
New-FakeAvifIn -DirPath $chA -Name "anim1.avif" | Out-Null

$totalsA = Invoke-FullPipeline -Path $rootA -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true

Test-Assert ($totalsA.SeriesCount -eq 1 -and $totalsA.ChapterCount -eq 1) "1 series, 1 chapter"
Test-Assert ($totalsA.ConvertedImageSuccess -eq 1 -and $totalsA.ConvertedImageFail -eq 0) "the image converted"
Test-Assert ($totalsA.ConvertedAnimatedSuccess -eq 1 -and $totalsA.ConvertedAnimatedFail -eq 0) "the animated file converted"
Test-Assert ($totalsA.ZipCreatedSuccess -eq 1 -and $totalsA.ZipCreatedFail -eq 0) "the chapter was zipped"
Test-Assert (Test-Path -LiteralPath (Join-Path (Split-Path $chA -Parent) "Chapter 1.zip")) "the real zip file exists on disk"
Test-Assert (-not (Test-Path -LiteralPath $chA)) "the chapter folder was deleted after a successful zip"
Test-Assert (-not $totalsA.Aborted) "not marked aborted"
Write-Host ""

# ==============================================================================
#  Scenario B: animated engine fails - merged status is Error, chapter is
#  NOT zipped (zip-blocking policy), even though the image half succeeded.
# ==============================================================================
Write-Host "=== Scenario B: animated failure blocks zipping (image half still succeeded) ===" -ForegroundColor Cyan
$chB = New-Dir "scenario-b\Series\Chapter 1"
New-FakeImageIn -DirPath $chB -Name "page1.jpg" | Out-Null
New-FakeAvifIn -DirPath $chB -Name "anim1.avif" -Fail $true | Out-Null

$totalsB = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-b") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true

Test-Assert ($totalsB.ConvertedImageSuccess -eq 1) "the image half still converted successfully"
Test-Assert ($totalsB.ConvertedAnimatedFail -eq 1) "the animated half failed"
Test-Assert ($totalsB.ZipCreatedSuccess -eq 0 -and $totalsB.ZipSkippedDueToError -eq 1) "zipping was skipped due to the animated engine's Error status, not attempted"
Test-Assert (Test-Path -LiteralPath $chB) "the chapter folder still exists - never zipped, never deleted"
Write-Host ""

# ==============================================================================
#  Scenario C: image engine fails (symmetric case) - same zip-blocking
#  result, proving the policy checks BOTH engines, not just one.
# ==============================================================================
Write-Host "=== Scenario C: image failure blocks zipping (animated half still succeeded) ===" -ForegroundColor Cyan
$chC = New-Dir "scenario-c\Series\Chapter 1"
New-FakeImageIn -DirPath $chC -Name "page1.jpg" -Fail $true | Out-Null
New-FakeAvifIn -DirPath $chC -Name "anim1.avif" | Out-Null

$totalsC = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-c") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true

Test-Assert ($totalsC.ConvertedImageFail -eq 1) "the image half failed"
Test-Assert ($totalsC.ConvertedAnimatedSuccess -eq 1) "the animated half still converted successfully"
Test-Assert ($totalsC.ZipCreatedSuccess -eq 0 -and $totalsC.ZipSkippedDueToError -eq 1) "zipping was still skipped, driven by the image engine's Error status this time"
Write-Host ""

# ==============================================================================
#  Scenario C2 (2026-08-31 fix): a DISPATCHED engine whose runspace crashes
#  with an UNCAUGHT exception - not a normal "cjxl exited 1" failure
#  (that's Scenario C above, already handled) but a genuine runspace-level
#  crash (e.g. Process.Start() throwing because the exe path is bad) that
#  ZipParallelProcessing.ps1's own EndInvoke() try/catch swallows into a
#  log line without ever calling -ResultHandler. Before the fix, a missing
#  result read as "nothing to convert" -> clean Success -> the chapter got
#  zipped with the crashed engine's files completely untouched. Real
#  -CjxlExe pointed at a nonexistent path - Convert-ImageBatch has no
#  try/catch around its own Process.Start() call, so this reliably crashes
#  the image engine's runspace outright rather than producing a normal,
#  caught cjxl-exit-1 failure.
# ==============================================================================
Write-Host "=== Scenario C2: a crashed (not just failed) engine still blocks zipping, not read as Success ===" -ForegroundColor Cyan
$chC2 = New-Dir "scenario-c2\Series\Chapter 1"
New-FakeImageIn -DirPath $chC2 -Name "page1.jpg" | Out-Null

$totalsC2 = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-c2") -CjxlExe (Join-Path $scratchDir "does_not_exist_cjxl.exe") -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true

Test-Assert ($totalsC2.ConvertedImageFail -eq 1 -and $totalsC2.ConvertedImageSuccess -eq 0) ("the crashed image engine is counted as a failure, not silently dropped (got Fail=" + $totalsC2.ConvertedImageFail + ", Success=" + $totalsC2.ConvertedImageSuccess + ")")
Test-Assert ($totalsC2.ZipCreatedSuccess -eq 0 -and $totalsC2.ZipSkippedDueToError -eq 1) "zipping was skipped - the crashed engine correctly blocked it instead of reading as a clean Success"
Test-Assert (Test-Path -LiteralPath $chC2) "the chapter folder still exists - never zipped, never deleted, despite the engine crash"
Write-Host ""

# ==============================================================================
#  Scenario C3 (2026-08-31 fix): AVIF classification used to only look at
#  $imageCandidates.NeedsConversion, never .StaleSources - Get-LooseImageCandidates
#  matches staleness purely by basename (ANY same-basename non-zero .jxl
#  counts, regardless of which source produced it), so an animated AVIF
#  can look "stale" the moment an UNRELATED file with the same basename
#  already has a .jxl. Before the fix, that AVIF was deleted by
#  Remove-StaleLooseSources while still sitting unfiltered in
#  $animatedCandidates - deleted out from under the engine that still
#  owned it.
# ==============================================================================
Write-Host "=== Scenario C3: an animated AVIF wrongly matched as a stale image source is preserved, not deleted ===" -ForegroundColor Cyan
$chC3 = New-Dir "scenario-c3\Series\Chapter 1"
New-FakeAvifIn -DirPath $chC3 -Name "anim1.avif" -Frames 5 | Out-Null
# Pre-existing anim1.jxl with the SAME basename, simulating an unrelated
# earlier conversion (e.g. from a since-deleted anim1.webp) - this is
# exactly what makes Get-LooseImageCandidates classify anim1.avif as stale.
New-FakeImageIn -DirPath $chC3 -Name "anim1.jxl" | Out-Null

$totalsC3 = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-c3") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true

Test-Assert ($totalsC3.ConvertedAnimatedSuccess -eq 1 -and $totalsC3.ConvertedAnimatedFail -eq 0) ("the animated AVIF was actually converted by the animated engine, not deleted out from under it (got Success=" + $totalsC3.ConvertedAnimatedSuccess + ", Fail=" + $totalsC3.ConvertedAnimatedFail + ")")
Test-Assert ($totalsC3.StaleImageCleanedSuccess -eq 0) "the AVIF was NOT deleted as a stale image source despite sharing a basename with an unrelated pre-existing .jxl"
Write-Host ""

# ==============================================================================
#  Scenario C4 (2026-08-31 fix): calls Invoke-FullPipelineChapter DIRECTLY
#  (not through Invoke-FullPipeline, which has its own EARLIER per-chapter
#  abort check that would just skip the chapter entirely, never reaching
#  this function). The image job runs for real (SLEEP_MS:200, a genuine OS
#  process) while a background runspace cancels the SAME $ctsC4 object
#  once the fake-cjxl process's own ".started" marker file appears (2026-08-31
#  correction: originally a flat 50ms Start-Sleep, which was a real timing
#  race - a cold/loaded machine's RunspacePool/ISS setup is not reliably
#  under 50ms, so the cancel could land before the job even dispatched or
#  miss its 200ms window entirely; polling for the job's own start signal
#  makes the ordering deterministic instead of guessed) - the job still
#  dispatches and completes normally (Cts wasn't cancelled when it
#  started, and a running process has no cancellation check of its own),
#  so -ResultHandler fires for real and the merged
#  status reads a clean Success. The zip gate is reached with the run
#  already aborted - the exact "engine says Success, but the run is
#  already aborted" case: before the fix, the zip gate had no
#  Cts-awareness at all and zipped anyway, producing a misleadingly
#  "successful", permanently-archived, potentially half-converted chapter.
# ==============================================================================
Write-Host "=== Scenario C4: a Cts cancelled mid-flight still blocks zipping even though the engine reports Success ===" -ForegroundColor Cyan
$chC4 = New-Dir "scenario-c4\Series\Chapter 1"
$imgC4 = New-FakeImageIn -DirPath $chC4 -Name "page1.jpg" -SleepMs 200
$budgetC4 = [System.Threading.SemaphoreSlim]::new(2, 2)
$ctsC4 = [System.Threading.CancellationTokenSource]::new()

$markerC4 = [System.IO.Path]::ChangeExtension($imgC4, ".jxl") + ".started"
$cancelRunspaceC4 = [runspacefactory]::CreateRunspace()
$cancelRunspaceC4.Open()
$cancelPsC4 = [PowerShell]::Create()
$cancelPsC4.Runspace = $cancelRunspaceC4
$null = $cancelPsC4.AddScript({
    param($Cts, $MarkerPath)
    # Poll for the fake-cjxl process's own started-marker instead of a flat
    # Start-Sleep - a fixed guess would either cancel before the job even
    # dispatches (on a slow/cold machine) or blow past its 200ms sleep
    # entirely, making the scenario flaky rather than a reliable proof.
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $MarkerPath) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 5 }
    $Cts.Cancel()
}).AddArgument($ctsC4).AddArgument($markerC4)
$cancelHandleC4 = $cancelPsC4.BeginInvoke()

$resultC4 = Invoke-FullPipelineChapter -ChapterDir $chC4 -ChapterImageFiles @((Get-Item -LiteralPath $imgC4)) -IsZippable $true -ZipOut (Join-Path $scratchDir "scenario-c4.zip") `
    -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullLogging $false -PermanentDelete $true -SharedBudget $budgetC4 -Cts $ctsC4

$cancelPsC4.EndInvoke($cancelHandleC4)
$cancelPsC4.Dispose()
$cancelRunspaceC4.Close()
$cancelRunspaceC4.Dispose()
$budgetC4.Dispose()
$ctsC4.Dispose()

Test-Assert ($resultC4.Status -ne 'Error') ("sanity check: the engine itself reported a clean status, not an Error - proves the zip block below is really about the cancelled Cts, not a conversion failure (got " + $resultC4.Status + ")")
Test-Assert ($resultC4.Zipped -eq $false) "zipping was blocked because the Cts was cancelled mid-flight, even though the engine reported a clean status"
Test-Assert (-not (Test-Path -LiteralPath (Join-Path $scratchDir "scenario-c4.zip"))) "no zip file was actually created"
Write-Host ""

# ==============================================================================
#  Scenario C4b (2026-08-31 fix): a Cts already cancelled BEFORE dispatch
#  even begins is a third, legitimate reason a result stays $null - not
#  the two causes ("crashed" or "force-stopped past the drain timeout")
#  the original code's own comment named. Invoke-ZipParallelProcessing's
#  dispatch loop never starts a job once cancellation is already
#  signaled, so -ResultHandler is never invoked at all for this chapter's
#  job - a real, graceful outcome, not a crash. No timing/race needed
#  here (unlike C4) - the Cts is cancelled synchronously before the call.
# ==============================================================================
Write-Host "=== Scenario C4b: a Cts already cancelled before dispatch is not logged/counted as a crash ===" -ForegroundColor Cyan
$chC4b = New-Dir "scenario-c4b\Series\Chapter 1"
$imgC4b = New-FakeImageIn -DirPath $chC4b -Name "page1.jpg"
$budgetC4b = [System.Threading.SemaphoreSlim]::new(2, 2)
$ctsC4b = [System.Threading.CancellationTokenSource]::new()
$ctsC4b.Cancel()   # already cancelled BEFORE Invoke-FullPipelineChapter is ever called

$resultC4b = Invoke-FullPipelineChapter -ChapterDir $chC4b -ChapterImageFiles @((Get-Item -LiteralPath $imgC4b)) -IsZippable $true -ZipOut (Join-Path $scratchDir "scenario-c4b.zip") `
    -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullLogging $false -PermanentDelete $true -SharedBudget $budgetC4b -Cts $ctsC4b

$budgetC4b.Dispose()
$ctsC4b.Dispose()

Test-Assert ($null -eq $resultC4b.ImageResult -or $resultC4b.ImageResult.FailedCount -ne 1) "a pre-cancelled dispatch does NOT synthesize a false FailedCount=1 - the null result is recognized as a graceful abort, not a crash"
Test-Assert (Test-Path -LiteralPath (Join-Path $chC4b "page1.jpg")) "the source file is left untouched - never actually dispatched, so nothing to have converted or deleted"
Write-Host ""

# ==============================================================================
#  Scenario C4c (2026-09-04 fix, real bug, same species as
#  UnwantedImage.ps1's Invoke-UnwantedImageScan Scenario G2): Remove-Source
#  returns $false (not an exception) when the chapter folder already
#  vanished before deletion - a real TOCTOU gap between the zip finishing
#  and this call. This used to be discarded, reporting a successful
#  delete anyway. Remove-Source shadowed to return $false unconditionally.
# ==============================================================================
Write-Host "=== Scenario C4c: a chapter folder already gone before deletion is not miscounted as deleted ===" -ForegroundColor Cyan
$chC4c = New-Dir "scenario-c4c\Series\Chapter 1"
$imgC4c = New-FakeImageIn -DirPath $chC4c -Name "page1.jpg"
$budgetC4c = [System.Threading.SemaphoreSlim]::new(2, 2)
$ctsC4c = [System.Threading.CancellationTokenSource]::new()

$realRemoveSourceC4c = ${function:Remove-Source}
function Remove-Source {
    param([string]$ItemPath)
    return $false
}

try {
    $resultC4c = Invoke-FullPipelineChapter -ChapterDir $chC4c -ChapterImageFiles @((Get-Item -LiteralPath $imgC4c)) -IsZippable $true -ZipOut (Join-Path $scratchDir "scenario-c4c.zip") `
        -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullLogging $false -PermanentDelete $true -SharedBudget $budgetC4c -Cts $ctsC4c
} finally {
    ${function:Remove-Source} = $realRemoveSourceC4c
    $budgetC4c.Dispose()
    $ctsC4c.Dispose()
}

Test-Assert ($resultC4c.ZipResult.Status -eq 'Success') "sanity check: the zip itself still succeeded"
Test-Assert ($resultC4c.ZipResult.FolderDeleted -eq $false) "FolderDeleted is `$false, not miscounted as a real delete, when Remove-Source reports the folder already gone"
Test-Assert ($resultC4c.ZipResult.FolderDeleteFailed -eq $false) "FolderDeleteFailed is also `$false - an already-gone folder is neither a success nor a real failure"
Write-Host ""

# ==============================================================================
#  Scenario C5 (2026-08-31 fix): $resultHandler's else branch used to
#  treat ANY non-Image object as the animated result - Invoke-ZipParallelProcessing
#  passes every object a worker's runspace emits to -ResultHandler, not
#  just its own explicit return value, so a stray unsuppressed object
#  anywhere in the real worker's call chain would silently overwrite
#  $resultBox.Animated with $null. Temporarily swaps the REAL
#  $script:fullPipelineChapterWorker for a fake that emits a stray string
#  BEFORE its real return value, for an image-only chapter (no animated
#  job dispatched at all) - proves the stray object is correctly ignored
#  (Animated stays $null, its untouched starting value) rather than being
#  mistaken for a real Animated result.
# ==============================================================================
Write-Host "=== Scenario C5: a stray object from the worker's own output is ignored, not mistaken for the Animated result ===" -ForegroundColor Cyan
$chC5 = New-Dir "scenario-c5\Series\Chapter 1"
$imgC5 = New-FakeImageIn -DirPath $chC5 -Name "page1.jpg"
$budgetC5 = [System.Threading.SemaphoreSlim]::new(2, 2)
$ctsC5 = [System.Threading.CancellationTokenSource]::new()

$realWorkerC5 = $script:fullPipelineChapterWorker
$script:fullPipelineChapterWorker = {
    param(
        [string]$EngineType, [System.IO.FileInfo[]]$Files, [string]$CjxlExe, [string]$MagickExe,
        [bool]$DoJpegLossless, [int]$DoJpegQuality, [bool]$DoAnimatedLossless, [int]$AnimatedQuality,
        [bool]$DoAnimatedOverwrite, [bool]$DoAnimatedDeleteSource, [bool]$DoFullLogging,
        [string]$LogFile, [string]$LogErrorFile, [string]$LogWarnFile, [bool]$DoPermanentDelete,
        [bool]$CleanConsoleOutputEnabled, [System.Threading.SemaphoreSlim]$SharedBudget,
        [System.Threading.Mutex]$LogMutex, [System.Collections.Concurrent.ConcurrentQueue[object]]$ConsoleQueue,
        [System.Threading.CancellationToken]$CancelToken
    )
    # A stray, unsuppressed object - simulating an accidental cmdlet
    # output somewhere in a real worker's call chain - emitted BEFORE the
    # real, expected return value. Invoke-ZipParallelProcessing's own
    # dispatch loop passes BOTH to -ResultHandler, one at a time. Carries
    # its own non-null, recognizable .Result so a wrongly-attributed
    # write is distinguishable from AnimatedResult's correct, untouched
    # $null starting value - a stray value that itself evaluated to $null
    # would make "corrupted" and "correctly untouched" look identical.
    @{ EngineType = 'SomethingElse'; Result = 'STRAY-NOT-A-REAL-RESULT' }
    return @{ EngineType = $EngineType; Result = @{ ConvertedCount = 1; FailedCount = 0 } }
}

try {
    $resultC5 = Invoke-FullPipelineChapter -ChapterDir $chC5 -ChapterImageFiles @((Get-Item -LiteralPath $imgC5)) -IsZippable $false `
        -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullLogging $false -PermanentDelete $true -SharedBudget $budgetC5 -Cts $ctsC5
} finally {
    $script:fullPipelineChapterWorker = $realWorkerC5
    $budgetC5.Dispose()
    $ctsC5.Dispose()
}

Test-Assert ($null -ne $resultC5.ImageResult -and $resultC5.ImageResult.ConvertedCount -eq 1) "the real Image result still came through correctly despite the stray object sharing its runspace's output"
Test-Assert ($null -eq $resultC5.AnimatedResult) "the stray object did NOT get mistaken for the Animated result - AnimatedResult stays `$null (no animated job was even dispatched), not the stray object's own 'STRAY-NOT-A-REAL-RESULT' value"
Write-Host ""

# ==============================================================================
#  Scenario C6 (2026-08-31 fix): an abort-blocked zip (Scenario C4's own
#  shape, but through the REAL Invoke-FullPipeline this time, not a direct
#  Invoke-FullPipelineChapter call) used to be invisible in the run's own
#  summary counters - Zipped is $false and Status is 'Success' (the
#  engine finished cleanly before the abort was noticed), so neither the
#  ZipCreated* nor the (pre-fix) ZipSkippedDueToError branch fired. Same
#  real-runspace timing technique as Scenario C4 (marker-polling, not a
#  flat sleep): a background runspace sets the REAL
#  [ConsoleCtrl]::AbortRequested flag once the 200ms-sleeping fake-cjxl
#  job's own ".started" marker appears, so Test-AbortSignal (polled by
#  Invoke-ZipParallelProcessing's own dispatch loop) cancels the
#  chapter's real, registered Cts while the job still completes normally.
# ==============================================================================
Write-Host "=== Scenario C6: an abort-blocked zip is now counted in ZipSkippedDueToError ===" -ForegroundColor Cyan
Reset-AbortState
$chC6 = New-Dir "scenario-c6\Series\Chapter 1"
$imgC6 = New-FakeImageIn -DirPath $chC6 -Name "page1.jpg" -SleepMs 200
$markerC6 = [System.IO.Path]::ChangeExtension($imgC6, ".jxl") + ".started"

$cancelRunspaceC6 = [runspacefactory]::CreateRunspace()
$cancelRunspaceC6.Open()
$cancelPsC6 = [PowerShell]::Create()
$cancelPsC6.Runspace = $cancelRunspaceC6
$null = $cancelPsC6.AddScript({
    param($MarkerPath)
    # Same started-marker polling as Scenario C4 - see its comment for why
    # a flat Start-Sleep is not a reliable way to land a mid-flight cancel.
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $MarkerPath) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 5 }
    [ConsoleCtrl]::AbortRequested = $true
}).AddArgument($markerC6)
$cancelHandleC6 = $cancelPsC6.BeginInvoke()

try {
    $totalsC6 = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-c6") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true
} finally {
    $cancelPsC6.EndInvoke($cancelHandleC6)
    $cancelPsC6.Dispose()
    $cancelRunspaceC6.Close()
    $cancelRunspaceC6.Dispose()
    Reset-AbortState
}

Test-Assert ($totalsC6.Aborted -eq $true) "sanity check: the run genuinely registered as aborted"
Test-Assert ($totalsC6.ZipCreatedSuccess -eq 0) "sanity check: the chapter was not actually zipped"
Test-Assert ($totalsC6.ZipSkippedDueToError -eq 1) ("the abort-blocked zip is now counted, not invisible (got ZipSkippedDueToError=" + $totalsC6.ZipSkippedDueToError + ")")
Write-Host ""

# ==============================================================================
#  Scenario D: a chapter with ONLY image files - the animated engine is
#  never dispatched at all (AnimatedResult stays $null), not run with an
#  empty file list.
# ==============================================================================
Write-Host "=== Scenario D: image-only chapter - animated engine never dispatched ===" -ForegroundColor Cyan
$chD = New-Dir "scenario-d\Series\Chapter 1"
New-FakeImageIn -DirPath $chD -Name "page1.jpg" | Out-Null

$totalsD = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-d") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true

Test-Assert ($totalsD.ConvertedImageSuccess -eq 1) "the image converted"
Test-Assert ($totalsD.ConvertedAnimatedSuccess -eq 0 -and $totalsD.ConvertedAnimatedFail -eq 0 -and $totalsD.ConvertedAnimatedSkipped -eq 0) "zero animated activity of any kind - the engine was never run, not run against nothing"
Test-Assert ($totalsD.ZipCreatedSuccess -eq 1) "still zipped cleanly (a clean, empty animated result is Success, not Error)"
Write-Host ""

# ==============================================================================
#  Scenario D2 (2026-08-31 fix): a chapter Get-SeriesChapters discovers
#  (it has a qualifying loose-image extension) but whose only loose file
#  is a STALE leftover - a valid, same-basename .jxl already exists (e.g.
#  a prior run's source-deletion failed after a real successful
#  conversion). Get-LooseImageCandidates classifies it as StaleSources,
#  Remove-StaleLooseSources cleans it up before the per-chapter loop runs,
#  leaving $chImages.Count -eq 0 for a chapter that's otherwise completely
#  ready to zip. Before the fix, ANY chapter reaching the per-chapter loop
#  with 0 images and 0 animated files short-circuited straight to
#  `Zipped = $false` without ever trying - stranding an already-fully-
#  converted chapter as a loose folder forever, since a chapter with zero
#  qualifying loose files left is never rediscovered by Get-SeriesChapters
#  on any later run either.
# ==============================================================================
Write-Host "=== Scenario D2: a chapter with only a stale leftover source (0 NeedsConversion) still gets zipped ===" -ForegroundColor Cyan
$chD2 = New-Dir "scenario-d2\Series\Chapter 1"
New-FakeImageIn -DirPath $chD2 -Name "page1.jpg" | Out-Null
Start-Sleep -Milliseconds 50
[System.IO.File]::WriteAllText((Join-Path $chD2 "page1.jxl"), "already converted - source deletion failed on a prior run")

$totalsD2 = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-d2") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true

Test-Assert ($totalsD2.ConvertedImageSuccess -eq 0 -and $totalsD2.ConvertedImageFail -eq 0) ("sanity check: nothing was actually converted this run - the chapter had 0 NeedsConversion candidates (got Success=" + $totalsD2.ConvertedImageSuccess + ", Fail=" + $totalsD2.ConvertedImageFail + ")")
Test-Assert ($totalsD2.StaleImageCleanedSuccess -eq 1) "the stale leftover source was cleaned up"
Test-Assert ($totalsD2.ZipCreatedSuccess -eq 1) ("the chapter was still zipped despite 0 conversion candidates - the exact gap this fix closes (got ZipCreatedSuccess=" + $totalsD2.ZipCreatedSuccess + ")")
Test-Assert (-not (Test-Path -LiteralPath $chD2)) "the chapter folder was deleted after the successful zip, same as any other successfully-zipped chapter"
Write-Host ""

# ==============================================================================
#  Scenario D3 (2026-09-01 live-shakedown fix): the discovery-level twin of
#  D2's gap, actually reproduced this time. D2 keeps one real loose-
#  extension file around (stale though it is), so Get-SeriesChapters still
#  DISCOVERS the chapter - only the per-chapter "0 candidates" short-
#  circuit needed fixing there. Here there is no loose file at all - a
#  chapter that finished converting cleanly on an earlier run (source
#  already deleted) and has ONLY a .jxl left. Confirmed live against this
#  project's real cjxl.exe/magick.exe: with -FolderQualifyingExtensions
#  still defaulting to the bare Get-LooseImageExtensions() list (no
#  ".jxl"), Test-ZippableLeafDirCandidate's own qualifying-file check
#  never matches anything in this folder, so Get-SeriesChapters never
#  finds it - the chapter is silently invisible to every later Full
#  Pipeline run, permanently, with no warning logged. Fixed by adding
#  ".jxl" to Invoke-FullPipeline's own -FolderQualifyingExtensions
#  default - see that parameter's own comment in Controller.ps1.
# ==============================================================================
Write-Host "=== Scenario D3: a chapter with ONLY already-converted .jxl (zero loose files) is still discovered and zipped ===" -ForegroundColor Cyan
$chD3 = New-Dir "scenario-d3\Series\Chapter 1"
[System.IO.File]::WriteAllText((Join-Path $chD3 "page1.jxl"), "already converted on a prior run - source already deleted, nothing loose left")

$totalsD3 = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-d3") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true

Test-Assert ($totalsD3.ChapterCount -eq 1) ("the all-.jxl chapter was discovered at all (got ChapterCount=" + $totalsD3.ChapterCount + ")")
Test-Assert ($totalsD3.ConvertedImageSuccess -eq 0 -and $totalsD3.ConvertedImageFail -eq 0) "sanity check: nothing needed converting"
Test-Assert ($totalsD3.ZipCreatedSuccess -eq 1) ("the all-.jxl chapter was still zipped - the exact discovery-level gap this fix closes (got ZipCreatedSuccess=" + $totalsD3.ZipCreatedSuccess + ")")
Test-Assert (-not (Test-Path -LiteralPath $chD3)) "the chapter folder was deleted after the successful zip"
Write-Host ""

# ==============================================================================
#  Scenario E: a chapter with ONLY animated files - symmetric to D, the
#  image engine is never dispatched.
# ==============================================================================
Write-Host "=== Scenario E: animated-only chapter - image engine never dispatched ===" -ForegroundColor Cyan
$chE = New-Dir "scenario-e\Series\Chapter 1"
New-FakeAvifIn -DirPath $chE -Name "anim1.avif" | Out-Null

$totalsE = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-e") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true

Test-Assert ($totalsE.ConvertedAnimatedSuccess -eq 1) "the animated file converted"
Test-Assert ($totalsE.ConvertedImageSuccess -eq 0 -and $totalsE.ConvertedImageFail -eq 0 -and $totalsE.ConvertedImageSkipped -eq 0) "zero image activity of any kind - the engine was never run"
Test-Assert ($totalsE.ZipCreatedSuccess -eq 1) "still zipped cleanly"
Write-Host ""

# ==============================================================================
#  Scenario F: a chapter/series with neither file type - counted, skipped
#  cleanly, no dispatch at all.
# ==============================================================================
Write-Host "=== Scenario F: chapter with no unconverted content of either type ===" -ForegroundColor Cyan
New-Dir "scenario-f\Empty Series" | Out-Null

$totalsF = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-f") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true

Test-Assert ($totalsF.SeriesCount -eq 1 -and $totalsF.ChapterCount -eq 0) "the empty series was walked, zero chapters counted"
Write-Host ""

# ==============================================================================
#  Scenario G: the shared budget REALLY caps combined concurrency across
#  both engines - the central point of this whole design. Multiple
#  chapters, each with a slow image AND a slow animated file, budget
#  smaller than the total possible concurrent processes - proven via the
#  peak-concurrency tracker (real OS-process overlap measured through the
#  fake executables), not inferred from final counts (which would look
#  identical either way).
# ==============================================================================
Write-Host "=== Scenario G: shared budget caps REAL combined concurrency across both engines ===" -ForegroundColor Cyan
$peakDir = New-Dir "scenario-g-peaks"
[System.IO.File]::WriteAllText((Join-Path $peakDir "current.txt"), "0")
[System.IO.File]::WriteAllText((Join-Path $peakDir "peak.txt"), "0")
$env:HARNESS_PEAK_DIR = $peakDir

$rootG = New-Dir "scenario-g"
1..3 | ForEach-Object {
    $chG = New-Dir ("scenario-g\Series\Chapter " + $_)
    New-FakeImageIn -DirPath $chG -Name "page1.jpg" -SleepMs 200 | Out-Null
    New-FakeAvifIn -DirPath $chG -Name "anim1.avif" -SleepMs 200 | Out-Null
}

try {
    $totalsG = Invoke-FullPipeline -Path $rootG -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 2 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true
} finally {
    $env:HARNESS_PEAK_DIR = $null
}

$observedPeak = [int]([System.IO.File]::ReadAllText((Join-Path $peakDir "peak.txt")))
Test-Assert ($totalsG.ConvertedImageSuccess -eq 3 -and $totalsG.ConvertedAnimatedSuccess -eq 3) "all 3 chapters' image and animated files converted correctly despite the tight shared budget"
Test-Assert ($observedPeak -le 2) ("real peak concurrent OS processes across BOTH engines never exceeded the shared budget of 2 (observed peak: " + $observedPeak + ")")
Test-Assert ($observedPeak -eq 2) ("the budget was actually driven to its full 2 at some point - proves real concurrent sharing happened, not accidental serialization (observed peak: " + $observedPeak + ")")
Write-Host ""

# ==============================================================================
#  Scenario H: CCR wiring - real CleanConsoleRendering.ps1 functions get
#  called, series resolves once its one chapter completes, merged Detail
#  string actually concatenates both engines' sub-summaries.
# ==============================================================================
Write-Host "=== Scenario H: CCR event emission with a merged Warning detail ===" -ForegroundColor Cyan
$chH = New-Dir "scenario-h\CCR Series\Chapter 1"
New-FakeImageIn -DirPath $chH -Name "page1.jpg" | Out-Null
$webpH = [System.IO.Path]::ChangeExtension((New-FakeAvifIn -DirPath $chH -Name "anim1.avif"), ".webp")
[System.IO.File]::WriteAllText($webpH, "pre-existing webp")   # forces a Skipped (Warning) animated outcome, Overwrite defaults false

$script:CleanConsoleOutputEnabled = $true
try {
    $totalsH = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-h") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true
} finally {
    $script:CleanConsoleOutputEnabled = $false
}

Test-Assert ($script:ccrActiveSeries.Count -eq 0) "the series resolved and left the active registry once its chapter completed"
Test-Assert ($totalsH.ConvertedAnimatedSkipped -eq 1) "the animated file was skipped (pre-existing output, Overwrite off)"
Test-Assert ($totalsH.ZipCreatedSuccess -eq 1) "a Warning-tier outcome (a skip, not a failure) did NOT block zipping"
Write-Host ""

# ==============================================================================
#  Scenario H2 (2026-09-03 fix, real bug, live-reported): a series with zero
#  qualifying chapters (e.g. already fully converted and zipped - nothing
#  left in the folder but a .cbz and an info file, no chapter subfolders at
#  all) must NEVER call Start-SeriesProgress at all. Before this fix it did
#  - Start-SeriesProgress's own docstring says a 0-chapter call "is
#  rendered as an immediately-frozen '0/0' line" via Update-CleanConsoleDisplay,
#  which is exactly the unwanted line the project owner asked to have
#  suppressed entirely, not just re-rendered differently. $script:ccrActiveSeries
#  itself is NOT the right observable here (a 0-chapter call never enters
#  it either way, by that same existing design) - spies directly on
#  Start-SeriesProgress instead (same function-swap technique as Scenario
#  Q2's Show-CoverDeletionMenu swap) to prove it's never invoked at all for
#  the zero-chapter case.
# ==============================================================================
Write-Host "=== Scenario H2: a series with zero qualifying chapters never calls Start-SeriesProgress ===" -ForegroundColor Cyan
$rootH2 = New-Dir "scenario-h2\Empty Series"
[System.IO.File]::WriteAllText((Join-Path $rootH2 "already-zipped.cbz"), "fake zip content")
[System.IO.File]::WriteAllText((Join-Path $rootH2 "info.txt"), "not an image, not a chapter")

$script:startSeriesProgressCallsH2 = New-Object System.Collections.Generic.List[string]
$realStartSeriesProgressH2 = ${function:Start-SeriesProgress}
function Start-SeriesProgress {
    param([string]$SeriesName, [int]$TotalChapters)
    $script:startSeriesProgressCallsH2.Add($SeriesName + ":" + $TotalChapters)
}

$script:CleanConsoleOutputEnabled = $true
try {
    $totalsH2 = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-h2") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true
} finally {
    $script:CleanConsoleOutputEnabled = $false
    ${function:Start-SeriesProgress} = $realStartSeriesProgressH2
}

Test-Assert ($script:startSeriesProgressCallsH2.Count -eq 0) ("Start-SeriesProgress was never called for the zero-chapter series (got: " + ($script:startSeriesProgressCallsH2 -join ", ") + ")")
Test-Assert ($totalsH2.SeriesCount -eq 1) "sanity check: the series WAS discovered and counted, just had no qualifying chapters"
Write-Host ""

# ==============================================================================
#  Scenario I: a chapter whose only "image" file is an ANIMATED WebP (cjxl
#  has no multi-frame support - Convert-ImageBatch SKIPS it, does not fail
#  it) plus a real animated .avif that converts successfully - zero .jxl
#  entries despite ChapterImageFiles.Count > 0, a legitimate Warning, not
#  an Error. Regression test for a real bug this session's code review
#  found: -RequireJxlEntry was originally computed from "did this chapter
#  have image files queued" rather than "did the image engine actually
#  convert anything" - this exact case would have wrongly required a
#  .jxl entry and thrown, turning a correct Warning-tier chapter into a
#  reported zip failure.
# ==============================================================================
Write-Host "=== Scenario I: all-skipped image files (animated WebP) don't force a spurious RequireJxlEntry ===" -ForegroundColor Cyan
$chI = New-Dir "scenario-i\Series\Chapter 1"
# A minimal real VP8X chunk with the animation bit (0x02) set at the flags
# byte (offset 20) - this is what Convert-ImageBatch's own animated-WebP
# detection actually reads (see ImageConversionPipeline.ps1), not
# something the fake cjxl.exe needs to understand at all.
$animatedWebpBytes = New-Object byte[] 24
$animatedWebpBytes[12] = [byte][char]'V'
$animatedWebpBytes[13] = [byte][char]'P'
$animatedWebpBytes[14] = [byte][char]'8'
$animatedWebpBytes[15] = [byte][char]'X'
$animatedWebpBytes[20] = 0x02
[System.IO.File]::WriteAllBytes((Join-Path $chI "animated.webp"), $animatedWebpBytes)
New-FakeAvifIn -DirPath $chI -Name "anim1.avif" | Out-Null

$totalsI = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-i") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true

Test-Assert ($totalsI.ConvertedImageSkipped -eq 1 -and $totalsI.ConvertedImageSuccess -eq 0) "the animated WebP was skipped, not converted - zero real .jxl entries despite having an image file queued"
Test-Assert ($totalsI.ConvertedAnimatedSuccess -eq 1) "the real animated file still converted successfully"
Test-Assert ($totalsI.ZipCreatedSuccess -eq 1 -and $totalsI.ZipCreatedFail -eq 0) "zipped successfully - did NOT wrongly require a .jxl entry just because an image file was queued"
Write-Host ""

# ==============================================================================
#  Invoke-Mode scenarios (J onward) - the top-level dispatcher. Every
#  scenario injects fake handlers rather than exercising the real
#  pipelines - proving dispatch/translation/error-catch logic, not
#  re-testing pipelines already covered by their own harnesses. Never
#  needs real cjxl/magick or a ZipPipeline.ps1/RezipPipeline.ps1 dot-
#  source - see Controller.ps1's own header.
# ==============================================================================

function New-FakeErrorRecord {
    <#
    .SYNOPSIS
        Constructs an ErrorRecord directly rather than throwing the
        exception through the pipeline - see AbortPipeline.Harness.ps1's
        own real bug (a literally-thrown PipelineStoppedException killed
        the whole harness process, even caught) for why this matters.
    #>
    param([Parameter(Mandatory)][System.Exception]$Exception)
    return [System.Management.Automation.ErrorRecord]::new($Exception, "TestError", [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
}

$fakeSettings = @{
    JpegLossless = $false; JpegQuality = 77; MaxCjxlProcs = 6; FullLogging = $false
    AnimatedLossless = $false; AnimatedQuality = 88; AnimatedThreads = 3; AnimatedOverwrite = $false; AnimatedDeleteSource = $true
    ZipParallelThreads = 2; PermanentDelete = $true; DeleteExtractedFoldersAfterRezip = $true
    CleanConsoleOutputEnabled = $false
    # Deliberately distinct from MaxCjxlProcs (2026-09-03 addition, real
    # bug fix, see CHANGELOG.md) - Scenario N below asserts THIS value,
    # not MaxCjxlProcs, reaches Invoke-Mode's FullPipeline dispatch; the
    # two used to be silently the same because the call site reused
    # MaxCjxlProcs directly.
    FullPipelineMaxConcurrentProcs = 9
}

Write-Host "=== Scenario J: Invoke-Mode / ImageConversion - param translation + result mapping ===" -ForegroundColor Cyan
$capturedJ = @{}
$fakeImageHandlerJ = {
    param($Path, $CjxlExe, $MagickExe, $JpegLossless, $JpegQuality, $MaxCjxlProcs, $FullLogging)
    $capturedJ.Path = $Path; $capturedJ.CjxlExe = $CjxlExe; $capturedJ.MagickExe = $MagickExe
    $capturedJ.JpegQuality = $JpegQuality; $capturedJ.MaxCjxlProcs = $MaxCjxlProcs; $capturedJ.FullLogging = $FullLogging
    return @{ ConvertedSuccess = 3; ConvertedFail = 1; ConvertedSkipped = 2; DeletedSuccess = 3; DeletedFail = 0; StaleCleanedSuccess = 1; StaleCleanedFail = 0; InspectFailedCount = 2; Aborted = $true; ForceKilledCount = 5 }
}.GetNewClosure()
$statsJ = Invoke-Mode -Resolved @{ Mode = 'ImageConversion' } -TargetPath "C:\fake\lib" -Settings $fakeSettings -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ImageConversionHandler $fakeImageHandlerJ

Test-Assert ($capturedJ.Path -eq "C:\fake\lib" -and $capturedJ.CjxlExe -eq "fake_cjxl.exe" -and $capturedJ.JpegQuality -eq 77 -and $capturedJ.MaxCjxlProcs -eq 6) "ImageConversion: real Settings values reached the handler"
Test-Assert ($statsJ.LooseImgConverted.Success -eq 3 -and $statsJ.LooseImgConverted.Fail -eq 1 -and $statsJ.LooseImgConverted.Skipped -eq 2) "ImageConversion: LooseImgConverted mapped correctly"
Test-Assert ($statsJ.LooseImgDeleted.Success -eq 3 -and $statsJ.LooseStaleCleaned.Success -eq 1) "ImageConversion: LooseImgDeleted/LooseStaleCleaned mapped correctly"
Test-Assert ($statsJ.InspectFailed.Count -eq 2) "ImageConversion: InspectFailedCount mapped onto InspectFailed.Count"
Test-Assert ($statsJ.Aborted -eq $true -and $statsJ.ForceKilledCount -eq 5) "ImageConversion: Aborted/ForceKilledCount mapped onto Stats (2026-09-03 fix, Todo.md finding)"
Write-Host ""

Write-Host "=== Scenario K: Invoke-Mode / AnimatedConversion - param translation + result mapping ===" -ForegroundColor Cyan
$fakeAnimHandlerK = { param($Path, $MagickExe, $AnimatedLossless, $AnimatedQuality, $AnimatedThreads, $AnimatedOverwrite, $AnimatedDeleteSource, $FullLogging)
    return @{ ConvertedSuccess = 4; ConvertedFail = 0; ConvertedSkipped = 1; DeletedSuccess = 4; DeletedFail = 0; InspectFailedCount = 1; Aborted = $true; ForceKilledCount = 2 }
}
$statsK = Invoke-Mode -Resolved @{ Mode = 'AnimatedConversion' } -TargetPath "C:\fake\lib" -Settings $fakeSettings -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -AnimatedConversionHandler $fakeAnimHandlerK
Test-Assert ($statsK.LooseAnimatedConverted.Success -eq 4 -and $statsK.LooseAnimatedConverted.Skipped -eq 1) "AnimatedConversion: LooseAnimatedConverted mapped correctly"
Test-Assert ($statsK.LooseAnimatedDeleted.Success -eq 4) "AnimatedConversion: LooseAnimatedDeleted mapped correctly"
Test-Assert ($statsK.InspectFailed.Count -eq 1) "AnimatedConversion: InspectFailedCount mapped onto InspectFailed.Count"
Test-Assert ($statsK.Aborted -eq $true -and $statsK.ForceKilledCount -eq 2) "AnimatedConversion: Aborted/ForceKilledCount mapped onto Stats (2026-09-03 fix, Todo.md finding)"
Write-Host ""

Write-Host "=== Scenario L: Invoke-Mode / ZipFolders - result mapping ===" -ForegroundColor Cyan
$fakeZipHandlerL = { param($Path, $MaxParallel, $DeleteFolders, $FullLogging, $LogFile, $LogErrorFile, $LogWarnFile, $PermanentDelete)
    return @{ CandidateCount = 5; ZippedSuccess = 4; ZippedFail = 1; FolderDeletedSuccess = 4; FolderDeletedFail = 0; ForceStoppedCount = 3; Aborted = $true }
}
$statsL = Invoke-Mode -Resolved @{ Mode = 'ZipFolders' } -TargetPath "C:\fake\lib" -Settings $fakeSettings -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ZipFoldersHandler $fakeZipHandlerL
Test-Assert ($statsL.ZipOnlyZipped.Success -eq 4 -and $statsL.ZipOnlyZipped.Fail -eq 1) "ZipFolders: ZipOnlyZipped mapped correctly"
Test-Assert ($statsL.ZipOnlyFolderDeleted.Success -eq 4) "ZipFolders: ZipOnlyFolderDeleted mapped correctly"
# 2026-09-03 fix, real bug caught by a same-session /code-review pass:
# ZipFolders used to map neither Aborted nor a force-killed count at all.
Test-Assert ($statsL.Aborted -eq $true -and $statsL.ForceKilledCount -eq 3) "ZipFolders: Aborted/ForceKilledCount (from ForceStoppedCount) mapped onto Stats"
Write-Host ""

Write-Host "=== Scenario M: Invoke-Mode / ConvertZipped - result mapping ===" -ForegroundColor Cyan
$fakeRezipHandlerM = { param($Path, $MaxParallel, $DeleteFolders, $FullLogging, $LogFile, $LogErrorFile, $LogWarnFile, $PermanentDelete, $CjxlExe, $MagickExe, $MaxCjxlProcs, $JpegLossless, $JpegQuality)
    return @{ CandidateCount = 2; ZipExtractedSuccess = 2; ZipExtractedFail = 0; ImgConvertedSuccess = 6; ImgConvertedFail = 0; ImgConvertedSkipped = 1; ImgDeletedSuccess = 6; ImgDeletedFail = 0; ZipCreatedSuccess = 2; ZipCreatedFail = 0; FolderDeletedSuccess = 2; FolderDeletedFail = 0; Skipped = 0; ForceStoppedCount = 0 }
}
$statsM = Invoke-Mode -Resolved @{ Mode = 'ConvertZipped' } -TargetPath "C:\fake\lib" -Settings $fakeSettings -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ConvertZippedHandler $fakeRezipHandlerM
Test-Assert ($statsM.ZipExtracted.Success -eq 2 -and $statsM.ImgConverted.Success -eq 6 -and $statsM.ImgConverted.Skipped -eq 1) "ConvertZipped: ZipExtracted/ImgConverted mapped correctly"
Test-Assert ($statsM.ZipCreated.Success -eq 2 -and $statsM.FolderDeleted.Success -eq 2) "ConvertZipped: ZipCreated/FolderDeleted mapped correctly"
Write-Host ""

Write-Host "=== Scenario N: Invoke-Mode / FullPipeline - all three stat groups populated at once ===" -ForegroundColor Cyan
$capturedN = @{ FullPipelineMaxConcurrentProcs = $null }
$fakeFullHandlerN = { param($Path, $CjxlExe, $MagickExe, $JpegLossless, $JpegQuality, $AnimatedLossless, $AnimatedQuality, $AnimatedOverwrite, $AnimatedDeleteSource, $FullPipelineMaxConcurrentProcs, $FullLogging, $LogFile, $LogErrorFile, $LogWarnFile, $PermanentDelete)
    $capturedN.FullPipelineMaxConcurrentProcs = $FullPipelineMaxConcurrentProcs
    return @{
        ConvertedImageSuccess = 5; ConvertedImageFail = 0; ConvertedImageSkipped = 0; DeletedImageSuccess = 5; DeletedImageFail = 0
        StaleImageCleanedSuccess = 0; StaleImageCleanedFail = 0
        ConvertedAnimatedSuccess = 2; ConvertedAnimatedFail = 0; ConvertedAnimatedSkipped = 0; DeletedAnimatedSuccess = 2; DeletedAnimatedFail = 0
        ZipCreatedSuccess = 3; ZipCreatedFail = 0; ZipSkippedDueToError = 0; FolderDeletedSuccess = 3; FolderDeletedFail = 0
        ForceKilledCount = 7; InspectFailedCount = 4; SeriesCount = 1; ChapterCount = 3; Aborted = $true
    }
}
$statsN = Invoke-Mode -Resolved @{ Mode = 'FullPipeline' } -TargetPath "C:\fake\lib" -Settings $fakeSettings -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -FullPipelineHandler $fakeFullHandlerN
Test-Assert ($statsN.LooseImgConverted.Success -eq 5 -and $statsN.LooseAnimatedConverted.Success -eq 2 -and $statsN.LooseFolderZipped.Success -eq 3) "FullPipeline: image + animated + zip stat groups all mapped in one call"
Test-Assert ($statsN.InspectFailed.Count -eq 4) "FullPipeline: InspectFailedCount (both engines summed by Controller.ps1) mapped onto InspectFailed.Count"
Test-Assert ($statsN.Aborted -eq $true -and $statsN.ForceKilledCount -eq 7) "FullPipeline: Aborted/ForceKilledCount mapped onto Stats (2026-09-03 fix, Todo.md finding)"
# 2026-09-03 addition, real bug fix (see CHANGELOG.md) - this call site
# used to reuse $Settings.MaxCjxlProcs (6 in $fakeSettings) directly;
# confirms it now reads the dedicated $Settings.FullPipelineMaxConcurrentProcs
# (9) instead, not silently the same value.
Test-Assert ($capturedN.FullPipelineMaxConcurrentProcs -eq 9) ("FullPipeline: Settings.FullPipelineMaxConcurrentProcs (9), not MaxCjxlProcs (6), reached the handler (got " + $capturedN.FullPipelineMaxConcurrentProcs + ")")
Write-Host ""

# ==============================================================================
#  Scenario N2 (2026-08-31 fix): Invoke-Mode's ZipFolders/ConvertZipped/
#  FullPipeline branches used to pass $Settings.FullLogging/PermanentDelete
#  UNCAST into the real handlers' own [Parameter(Mandatory)][bool] params -
#  the same crash-on-$null-key species already fixed today at other call
#  sites (Invoke-MainLoop's re-sync, the bootstrap script). The earlier
#  fake handlers above (L/M/N) use untyped params, so they'd silently
#  accept a $null and never catch this - these fakes instead declare
#  Mandatory [bool] params matching the REAL ZipPipeline.ps1/
#  RezipPipeline.ps1/Controller.ps1 function signatures exactly, so a
#  missing $Settings key would genuinely throw if passed uncast.
#
#  NOTE: Invoke-Mode's own outer try/catch (see the end of this function)
#  already swallows ANY exception from a handler call via
#  Invoke-AbortOrFatalHandler and returns $null - so "did Invoke-Mode
#  itself throw" is ALWAYS false regardless of this fix, and is NOT a
#  valid signal (an earlier draft of this test used exactly that check
#  and failed to catch the bug even with the fix reverted). The real
#  signal is whether the mode actually COMPLETES (returns the handler's
#  real stats) instead of silently falling into the fatal-handler path
#  and returning $null.
# ==============================================================================
Write-Host "=== Scenario N2: Invoke-Mode completes normally despite a `$Settings missing FullLogging/PermanentDelete (ZipFolders/ConvertZipped/FullPipeline) ===" -ForegroundColor Cyan
$fakeSettingsN2 = @{ ZipParallelThreads = 2; DeleteExtractedFoldersAfterRezip = $false; MaxCjxlProcs = 2; JpegLossless = $false; JpegQuality = 90; AnimatedLossless = $false; AnimatedQuality = 90; AnimatedThreads = 2; AnimatedOverwrite = $false; AnimatedDeleteSource = $true }

$fakeZipHandlerN2 = { param([string]$Path, [int]$MaxParallel, [bool]$DeleteFolders, [Parameter(Mandatory)][bool]$FullLogging, [string]$LogFile, [string]$LogErrorFile, [string]$LogWarnFile, [Parameter(Mandatory)][bool]$PermanentDelete)
    return @{ CandidateCount = 3; ZippedSuccess = 3; ZippedFail = 0; FolderDeletedSuccess = 3; FolderDeletedFail = 0; ForceStoppedCount = 0 }
}
$statsN2Zip = Invoke-Mode -Resolved @{ Mode = 'ZipFolders' } -TargetPath "C:\fake\lib" -Settings $fakeSettingsN2 -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ZipFoldersHandler $fakeZipHandlerN2
Test-Assert ($null -ne $statsN2Zip -and $statsN2Zip.ZipOnlyZipped.Success -eq 3) "ZipFolders completes normally (not swallowed into the fatal-handler `$null path) despite `$Settings missing FullLogging/PermanentDelete"

$fakeRezipHandlerN2 = { param([string]$Path, [int]$MaxParallel, [bool]$DeleteFolders, [Parameter(Mandatory)][bool]$FullLogging, [string]$LogFile, [string]$LogErrorFile, [string]$LogWarnFile, [Parameter(Mandatory)][bool]$PermanentDelete, [string]$CjxlExe, [string]$MagickExe, [int]$MaxCjxlProcs, [bool]$JpegLossless, [int]$JpegQuality)
    return @{ CandidateCount = 1; ZipExtractedSuccess = 1; ZipExtractedFail = 0; ImgConvertedSuccess = 3; ImgConvertedFail = 0; ImgConvertedSkipped = 0; ImgDeletedSuccess = 3; ImgDeletedFail = 0; ZipCreatedSuccess = 1; ZipCreatedFail = 0; FolderDeletedSuccess = 1; FolderDeletedFail = 0; Skipped = 0; ForceStoppedCount = 0 }
}
$statsN2Rezip = Invoke-Mode -Resolved @{ Mode = 'ConvertZipped' } -TargetPath "C:\fake\lib" -Settings $fakeSettingsN2 -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ConvertZippedHandler $fakeRezipHandlerN2
Test-Assert ($null -ne $statsN2Rezip -and $statsN2Rezip.ImgConverted.Success -eq 3) "ConvertZipped completes normally (not swallowed into the fatal-handler `$null path) despite `$Settings missing FullLogging/PermanentDelete"

$fakeFullHandlerN2 = { param([string]$Path, [string]$CjxlExe, [string]$MagickExe, [bool]$JpegLossless, [int]$JpegQuality, [bool]$AnimatedLossless, [int]$AnimatedQuality, [bool]$AnimatedOverwrite, [bool]$AnimatedDeleteSource, [int]$FullPipelineMaxConcurrentProcs, [Parameter(Mandatory)][bool]$FullLogging, [string]$LogFile, [string]$LogErrorFile, [string]$LogWarnFile, [Parameter(Mandatory)][bool]$PermanentDelete)
    return @{
        ConvertedImageSuccess = 7; ConvertedImageFail = 0; ConvertedImageSkipped = 0; DeletedImageSuccess = 7; DeletedImageFail = 0
        StaleImageCleanedSuccess = 0; StaleImageCleanedFail = 0
        ConvertedAnimatedSuccess = 0; ConvertedAnimatedFail = 0; ConvertedAnimatedSkipped = 0; DeletedAnimatedSuccess = 0; DeletedAnimatedFail = 0
        ZipCreatedSuccess = 0; ZipCreatedFail = 0; ZipSkippedDueToError = 0; FolderDeletedSuccess = 0; FolderDeletedFail = 0
        ForceKilledCount = 0; InspectFailedCount = 0; SeriesCount = 0; ChapterCount = 0; Aborted = $false
    }
}
$statsN2Full = Invoke-Mode -Resolved @{ Mode = 'FullPipeline' } -TargetPath "C:\fake\lib" -Settings $fakeSettingsN2 -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -FullPipelineHandler $fakeFullHandlerN2
Test-Assert ($null -ne $statsN2Full -and $statsN2Full.LooseImgConverted.Success -eq 7) "FullPipeline completes normally (not swallowed into the fatal-handler `$null path) despite `$Settings missing FullLogging/PermanentDelete"

# 2026-08-31 fix (found by a FOURTH-pass re-review): confirmed directly
# that a non-Mandatory [bool]$X = $false parameter ALSO throws on an
# explicitly-passed $null - Mandatory only affects whether OMITTING the
# param is allowed, not the [bool] type coercion once a value (even
# $null) is actually passed. $fakeSettingsN2 above still includes
# JpegLossless/AnimatedLossless/AnimatedOverwrite/AnimatedDeleteSource
# (matching real defaults), so it never exercised THIS specific class -
# this scenario uses a $Settings missing those entirely.
$fakeSettingsN3 = @{ MaxCjxlProcs = 2; JpegQuality = 90; AnimatedQuality = 90; AnimatedThreads = 2 }
$statsN3Full = Invoke-Mode -Resolved @{ Mode = 'FullPipeline' } -TargetPath "C:\fake\lib" -Settings $fakeSettingsN3 -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -FullPipelineHandler $fakeFullHandlerN2
Test-Assert ($null -ne $statsN3Full -and $statsN3Full.LooseImgConverted.Success -eq 7) "FullPipeline completes normally despite `$Settings missing JpegLossless/AnimatedLossless/AnimatedOverwrite/AnimatedDeleteSource/FullLogging/PermanentDelete entirely (non-Mandatory bool params, not just Mandatory ones)"

# 2026-08-31 fix (found by a re-review after the first N2 pass): the
# ImageConversion/AnimatedConversion cases were missed by the original
# bool-cast fix - same species, same file, just two more switch cases.
$fakeImageHandlerN2 = { param([string]$Path, [string]$CjxlExe, [string]$MagickExe, [bool]$JpegLossless, [int]$JpegQuality, [int]$MaxCjxlProcs, [Parameter(Mandatory)][bool]$FullLogging)
    return @{ ConvertedSuccess = 4; ConvertedFail = 0; ConvertedSkipped = 0; DeletedSuccess = 4; DeletedFail = 0; StaleCleanedSuccess = 0; StaleCleanedFail = 0; ForceKilledCount = 0; InspectFailedCount = 0 }
}
$statsN2Image = Invoke-Mode -Resolved @{ Mode = 'ImageConversion' } -TargetPath "C:\fake\lib" -Settings $fakeSettingsN2 -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ImageConversionHandler $fakeImageHandlerN2
Test-Assert ($null -ne $statsN2Image -and $statsN2Image.LooseImgConverted.Success -eq 4) "ImageConversion completes normally (not swallowed into the fatal-handler `$null path) despite `$Settings missing FullLogging"

$fakeAnimHandlerN2 = { param([string]$Path, [string]$MagickExe, [bool]$AnimatedLossless, [int]$AnimatedQuality, [int]$AnimatedThreads, [bool]$AnimatedOverwrite, [bool]$AnimatedDeleteSource, [Parameter(Mandatory)][bool]$FullLogging)
    return @{ ConvertedSuccess = 2; ConvertedFail = 0; ConvertedSkipped = 0; DeletedSuccess = 2; DeletedFail = 0; ForceKilledCount = 0; InspectFailedCount = 0 }
}
$statsN2Anim = Invoke-Mode -Resolved @{ Mode = 'AnimatedConversion' } -TargetPath "C:\fake\lib" -Settings $fakeSettingsN2 -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -AnimatedConversionHandler $fakeAnimHandlerN2
Test-Assert ($null -ne $statsN2Anim -and $statsN2Anim.LooseAnimatedConverted.Success -eq 2) "AnimatedConversion completes normally (not swallowed into the fatal-handler `$null path) despite `$Settings missing FullLogging"

# 2026-08-31 fix (found by a THIRD-pass re-review): the ImageConversionZip
# (mode 8) case was missed by both earlier bool-cast fix passes.
$fakeImageHandlerN2Zip = { param([string]$Path, [string]$CjxlExe, [string]$MagickExe, [bool]$JpegLossless, [int]$JpegQuality, [int]$MaxCjxlProcs, [Parameter(Mandatory)][bool]$FullLogging, [scriptblock]$ZipStepCallback)
    return @{ ConvertedSuccess = 1; ConvertedFail = 0; ConvertedSkipped = 0; DeletedSuccess = 1; DeletedFail = 0; StaleCleanedSuccess = 0; StaleCleanedFail = 0; InspectFailedCount = 0 }
}
$fakeZipFolderHandlerN2 = { param($FolderPath, $ZipOut, $LooseImageExtensions) return @{ Status = "Success"; ZipSize = 1; EntryCount = 1; FolderDeleted = $true; FolderDeleteFailed = $false } }
$statsN2Zip = Invoke-Mode -Resolved @{ Mode = 'ImageConversionZip' } -TargetPath $scratchDir -Settings $fakeSettingsN2 -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ImageConversionHandler $fakeImageHandlerN2Zip -ZipFolderHandler $fakeZipFolderHandlerN2
Test-Assert ($null -ne $statsN2Zip -and $statsN2Zip.LooseImgConverted.Success -eq 1) "ImageConversionZip (mode 8) completes normally (not swallowed into the fatal-handler `$null path) despite `$Settings missing FullLogging"
Write-Host ""

Write-Host "=== Scenario O: Invoke-Mode / ImageConversionZip (mode 8) - real zip-step wiring, 2026-08-28 ===" -ForegroundColor Cyan
# This fake -ImageConversionHandler simulates what the real
# Invoke-LooseImageConversionPipeline does: actually invokes the
# -ZipStepCallback it was given, so this scenario proves the CALLBACK's
# own logic (extension selection, Status/Detail mapping) - not just that
# a callback object gets constructed and never used.
$zipHandlerCallsO = [System.Collections.Generic.List[hashtable]]::new()
$fakeZipFolderHandlerO = {
    param($FolderPath, $ZipOut, $LooseImageExtensions, $RequireJxlEntry)
    $zipHandlerCallsO.Add(@{ FolderPath = $FolderPath; ZipOut = $ZipOut; LooseImageExtensions = $LooseImageExtensions; RequireJxlEntry = $RequireJxlEntry })
    return @{ Status = "Success"; ZipSize = 123; EntryCount = 4; FolderDeleted = $true; FolderDeleteFailed = $false }
}.GetNewClosure()
$zipOutcomeBoxO = @{ Value = $null }
$fakeImageHandlerO = {
    param($Path, $CjxlExe, $MagickExe, $JpegLossless, $JpegQuality, $MaxCjxlProcs, $FullLogging, $ZipStepCallback)
    # Mutate the boxed hashtable's key, not reassign a bare/$script: var -
    # .GetNewClosure() puts this scriptblock in its own dynamic module, so
    # a bare "$zipOutcomeSeenO = ..." (or even "$script:zipOutcomeSeenO =
    # ..." for a variable that doesn't already exist in script scope
    # before the closure is created) would silently write to a
    # disconnected copy the outer scope never sees - see
    # Docs/lessons-learned.md and CLAUDE.md's "Lessons learned", same
    # trap this project has been bitten by before. $capturedJ (Scenario
    # J, above) already uses this exact box pattern successfully.
    # ChapterResult omitted (2026-09-04: this is the "nothing needed
    # converting" shape - e.g. an all-.gif or all-avif-routed-elsewhere
    # chapter) - $Info.ChapterResult reads as $null, same as the real
    # ImageConversionPipeline.ps1 passes when $chapterResult stayed $null.
    $zipOutcome = & $ZipStepCallback @{ Dir = (Get-Item -LiteralPath $Path); ZipOut = (Join-Path $Path "Chapter.zip") }
    $zipOutcomeBoxO.Value = $zipOutcome
    return @{ ConvertedSuccess = 1; ConvertedFail = 0; ConvertedSkipped = 0; DeletedSuccess = 1; DeletedFail = 0; StaleCleanedSuccess = 0; StaleCleanedFail = 0; InspectFailedCount = 0; Aborted = $true; ForceKilledCount = 2 }
}.GetNewClosure()

$fakeSettingsO = $fakeSettings.Clone()
$fakeSettingsO.ZipWithUnconvertedAnimated = $false
$statsO = Invoke-Mode -Resolved @{ Mode = 'ImageConversionZip' } -TargetPath $scratchDir -Settings $fakeSettingsO -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ImageConversionHandler $fakeImageHandlerO -ZipFolderHandler $fakeZipFolderHandlerO

Test-Assert ($statsO.LooseImgConverted.Success -eq 1) "ImageConversionZip: image conversion still ran and mapped correctly"
# 2026-09-03 fix, real bug caught by a same-session /code-review pass:
# mode 8 used to map neither Aborted nor ForceKilledCount at all, despite
# $ImageConversionHandler's own result already carrying both fields.
Test-Assert ($statsO.Aborted -eq $true -and $statsO.ForceKilledCount -eq 2) "ImageConversionZip: Aborted/ForceKilledCount mapped onto Stats"
Test-Assert ($zipHandlerCallsO.Count -eq 1) ("the zip-folder handler fired exactly once (got " + $zipHandlerCallsO.Count + ")")
Test-Assert ($zipHandlerCallsO[0].LooseImageExtensions -contains ".avif") "ZipWithUnconvertedAnimated=false (default): .avif is in the blocking extension list"
# 2026-09-02 follow-up fix (a second same-day review, after the first
# 2026-09-02 fix below): ".gif" must NOT be in this list in EITHER
# branch, not just the toggle-on one. An earlier version of this fix
# deliberately kept ".gif" as a permanent blocker, reasoning it "counts
# as unconverted content" - but Convert-ImageBatch never even attempts
# to convert it and Get-LooseImageCandidates never returns it as a
# candidate, so there is no failure for the user to ever resolve - a
# chapter containing a ".gif" could NEVER be zipped by mode 8, on any
# run, forever. Live-confirmed. Full Pipeline has no such gate at all
# and simply sweeps a never-converted file into the zip; mode 8 now
# matches that already-validated behavior in both toggle states.
Test-Assert ($zipHandlerCallsO[0].LooseImageExtensions -notcontains ".gif") "ZipWithUnconvertedAnimated=false (default): .gif is NOT in the blocking list - it can never be 'resolved', so blocking on it would deadlock mode 8 forever"
Test-Assert ($zipOutcomeBoxO.Value.Status -eq "Success" -and $zipOutcomeBoxO.Value.Detail -eq "4 entries") "the callback mapped the zip result into @{ Status; Detail } correctly"
Test-Assert ($statsO.LooseFolderZipped.Success -eq 1 -and $statsO.LooseFolderZipped.Fail -eq 0 -and $statsO.LooseFolderZipped.Skipped -eq 0) ("mode 8's zip outcome IS reflected in LooseFolderZipped now (2026-08-28 fix) - got Success=" + $statsO.LooseFolderZipped.Success)
Test-Assert ($statsO.LooseFolderDeleted.Success -eq 1 -and $statsO.LooseFolderDeleted.Fail -eq 0) "mode 8's folder-deletion outcome IS reflected in LooseFolderDeleted now"
# 2026-09-04 fix, real bug: mode 8's zip step used to omit -RequireJxlEntry
# entirely, always taking Invoke-LooseFolderZip's $true default - a
# chapter with nothing to convert (ChapterResult $null, this call's own
# shape) must pass $false, or a real gif-only/never-converted chapter
# would fail Test-ZipArchive's ".jxl entry required" check forever.
Test-Assert ($zipHandlerCallsO[0].RequireJxlEntry -eq $false) "RequireJxlEntry is `$false when ChapterResult is `$null (nothing needed converting)"

# Same callback, but this time with a real ChapterResult carrying a
# ConvertedCount > 0 - RequireJxlEntry must be $true.
$zipHandlerCallsO.Clear()
$fakeImageHandlerOConverted = {
    param($Path, $CjxlExe, $MagickExe, $JpegLossless, $JpegQuality, $MaxCjxlProcs, $FullLogging, $ZipStepCallback)
    $zipOutcome = & $ZipStepCallback @{ Dir = (Get-Item -LiteralPath $Path); ZipOut = (Join-Path $Path "Chapter.zip"); ChapterResult = @{ ConvertedCount = 3 } }
    return @{ ConvertedSuccess = 1; ConvertedFail = 0; ConvertedSkipped = 0; DeletedSuccess = 1; DeletedFail = 0; StaleCleanedSuccess = 0; StaleCleanedFail = 0; InspectFailedCount = 0; Aborted = $false; ForceKilledCount = 0 }
}.GetNewClosure()
$null = Invoke-Mode -Resolved @{ Mode = 'ImageConversionZip' } -TargetPath $scratchDir -Settings $fakeSettingsO -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ImageConversionHandler $fakeImageHandlerOConverted -ZipFolderHandler $fakeZipFolderHandlerO
Test-Assert ($zipHandlerCallsO[0].RequireJxlEntry -eq $true) "RequireJxlEntry is `$true when ChapterResult.ConvertedCount is greater than 0"

# Flip the setting: .avif should be EXCLUDED from the blocking list, so an
# unconverted .avif sitting in the folder no longer blocks zipping.
$zipHandlerCallsO.Clear()
$fakeSettingsO2 = $fakeSettings.Clone()
$fakeSettingsO2.ZipWithUnconvertedAnimated = $true
$null = Invoke-Mode -Resolved @{ Mode = 'ImageConversionZip' } -TargetPath $scratchDir -Settings $fakeSettingsO2 -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ImageConversionHandler $fakeImageHandlerO -ZipFolderHandler $fakeZipFolderHandlerO
Test-Assert ($zipHandlerCallsO[0].LooseImageExtensions -notcontains ".avif") "ZipWithUnconvertedAnimated=true: .avif is EXCLUDED from the blocking extension list"
# 2026-09-02 review fix: this list used to be a hand-retyped literal
# snapshot of the canonical list minus ".avif", taken BEFORE ".gif"/
# ".bmp"/".heic"/".heif" were added to Get-LooseImageExtensions() - it
# silently never picked those up, so with the toggle ON, an unconverted
# BMP/HEIC/HEIF sailed past this gate and got zipped raw.
Test-Assert ($zipHandlerCallsO[0].LooseImageExtensions -contains ".bmp" -and $zipHandlerCallsO[0].LooseImageExtensions -contains ".heic" -and $zipHandlerCallsO[0].LooseImageExtensions -contains ".heif") "ZipWithUnconvertedAnimated=true: .bmp/.heic/.heif still block - the toggle is AVIF-specific, not a blanket relax"
Test-Assert ($zipHandlerCallsO[0].LooseImageExtensions -notcontains ".gif") "ZipWithUnconvertedAnimated=true: .gif is NOT in the blocking list either - see the toggle-off assertion above for why"
Write-Host ""

Write-Host "=== Scenario P: Invoke-Mode / blank MagickExe fails fast for magick-dependent modes ===" -ForegroundColor Cyan
$fatalMsgsP = [System.Collections.Generic.List[string]]::new()
$logHandlerP = { param($m) $fatalMsgsP.Add($m) }.GetNewClosure()
$neverCalledHandler = { param($Path) throw "should never be invoked" }
$statsP1 = Invoke-Mode -Resolved @{ Mode = 'AnimatedConversion' } -TargetPath "C:\fake\lib" -Settings $fakeSettings -CjxlExe "fake_cjxl.exe" -MagickExe "" -AnimatedConversionHandler $neverCalledHandler -LogHandler $logHandlerP
Test-Assert ($null -eq $statsP1) "AnimatedConversion with blank MagickExe returns `$null, not a stats object"
Test-Assert ($fatalMsgsP.Count -eq 1 -and $fatalMsgsP[0] -match "requires magick\.exe") "the fail-fast message names the mode and the missing dependency"
Write-Host ""

Write-Host "=== Scenario Q: Invoke-Mode / a genuine crash inside a handler is caught, not left uncaught ===" -ForegroundColor Cyan
$fatalMsgsQ = [System.Collections.Generic.List[string]]::new()
$logHandlerQ = { param($m) $fatalMsgsQ.Add($m) }.GetNewClosure()
$crashingHandler = { param($Path, $CjxlExe, $MagickExe, $JpegLossless, $JpegQuality, $MaxCjxlProcs, $FullLogging)
    $errorRecord = New-FakeErrorRecord -Exception ([System.InvalidOperationException]::new("simulated real crash, not an abort"))
    throw $errorRecord
}
$statsQ = Invoke-Mode -Resolved @{ Mode = 'ImageConversion' } -TargetPath "C:\fake\lib" -Settings $fakeSettings -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ImageConversionHandler $crashingHandler -LogHandler $logHandlerQ
Test-Assert ($null -eq $statsQ) "a genuine crash returns `$null rather than a partial/misleading stats object"
Test-Assert ($fatalMsgsQ.Count -eq 1 -and $fatalMsgsQ[0] -match "FATAL ERROR" -and $fatalMsgsQ[0] -match "simulated real crash") "Invoke-AbortOrFatalHandler actually ran and classified it as a genuine fatal error"
Write-Host ""

Write-Host "=== Scenario R: Invoke-Mode / an unrecognized mode is a caught error, not an uncaught throw ===" -ForegroundColor Cyan
$fatalMsgsR = [System.Collections.Generic.List[string]]::new()
$logHandlerR = { param($m) $fatalMsgsR.Add($m) }.GetNewClosure()
$statsR = Invoke-Mode -Resolved @{ Mode = 'NotARealMode' } -TargetPath "C:\fake\lib" -Settings $fakeSettings -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -LogHandler $logHandlerR
Test-Assert ($null -eq $statsR) "an unrecognized mode returns `$null"
Test-Assert ($fatalMsgsR.Count -eq 1 -and $fatalMsgsR[0] -match "unrecognized mode") "the fatal message names the bad mode string"
Write-Host ""

# ==============================================================================
#  Scenario S: back to the REAL Invoke-FullPipeline (not Invoke-Mode) -
#  Convert-ImageBatch's new InspectFailedCount field (a real
#  Test-AvifAnimated failure) is summed into Invoke-FullPipeline's own
#  totals (2026-08-28), same as the pre-existing animated-engine field.
#
#  NOTE ON SCOPE: Invoke-FullPipeline's own -LooseImageExtensions default
#  deliberately still does NOT include .avif (unlike
#  ImageConversionPipeline.ps1's own default, which now does) - adding it
#  would make BOTH engines independently discover and dispatch the SAME
#  .avif file at once (Get-LooseImageCandidates AND
#  Get-LooseAnimatedCandidates both defaulting to .avif), a real race
#  between two concurrently-running engines that could delete a file out
#  from under the other mid-identify. That's a genuine, pre-existing gap
#  (Full Pipeline never routed static AVIF to the image engine before
#  this session either) surfaced while verifying THIS change, not solved
#  by it - flagged in Todo.md, not fixed here. This scenario isolates
#  Invoke-FullPipeline's own accumulation line by explicitly routing the
#  AVIF only to the image engine (-AnimatedFileExtensions @()) - a test
#  construction, not a claim that's a supported real configuration.
# ==============================================================================
Write-Host "=== Scenario S: Invoke-FullPipeline sums the image engine's InspectFailedCount too ===" -ForegroundColor Cyan
$chS = New-Dir "scenario-s\Series\Chapter 1"
[System.IO.File]::WriteAllText((Join-Path $chS "corrupt.avif"), "FAIL_IDENTIFY")

$totalsS = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-s") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true `
    -LooseImageExtensions @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif") -AnimatedFileExtensions @()

Test-Assert ($totalsS.InspectFailedCount -eq 1) ("the image engine's inspect-failure was summed into Invoke-FullPipeline's own totals (got " + $totalsS.InspectFailedCount + ")")
Write-Host ""

# ==============================================================================
#  Scenario T: Invoke-MainLoop (2026-08-28) - the run loop moved out of the
#  main script. Every handler injected, so this proves the LOOP's own
#  control flow (how many iterations, what stops it) without a real
#  interactive prompt or real pipeline.
# ==============================================================================
Write-Host "=== Scenario T: Invoke-MainLoop runs until Show-PostRunPrompt returns Exit ===" -ForegroundColor Cyan
$getModeCallsT = 0
$fakeGetModeT = { param($Settings, $SettingsPath) $script:getModeCallsT++; return @{ Mode = 'ImageConversion'; RunImageConversion = $true; RunAnimatedConversion = $false; RunZip = $false; RunZipOnly = $false; RunConvertZipped = $false } }
$invokeModeCallsT = 0
$fakeInvokeModeT = { param($Resolved, $TargetPath, $Settings, $CjxlExe, $MagickExe, $LogFile, $LogErrorFile, $LogWarnFile)
    $script:invokeModeCallsT++
    $s = New-StatsTracker
    $s.LooseImgConverted.Success = $script:invokeModeCallsT
    return $s
}
$postRunCallsT = 0
$fakePostRunT = {
    $script:postRunCallsT++
    if ($script:postRunCallsT -ge 3) { return 'Exit' }
    return 'ReturnToMenu'
}
# 2026-08-28: proves Invoke-MainLoop calls -ResetAbortHandler once per
# iteration, BEFORE resolving that iteration's mode (real bug fix - see
# CHANGELOG.md/Todo.md, "abort state never reset" - a Ctrl+C used to
# poison every later run in the same session). Order matters, not just
# count: recorded here so the assertion below can confirm reset genuinely
# happens before GetMode, not just somewhere in the iteration.
$resetAbortCallsT = 0
$resetOrderT = [System.Collections.Generic.List[string]]::new()
$fakeResetAbortT = { $script:resetAbortCallsT++; $script:resetOrderT.Add("Reset") }
$fakeGetModeTOrdered = { param($Settings, $SettingsPath) $script:resetOrderT.Add("GetMode"); & $fakeGetModeT -Settings $Settings -SettingsPath $SettingsPath }
$script:getModeCallsT = 0; $script:invokeModeCallsT = 0; $script:postRunCallsT = 0; $script:resetAbortCallsT = 0
Invoke-MainLoop -TargetPath "C:\fake\lib" -Settings $fakeSettings -SettingsPath "C:\fake\settings.json" -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" `
    -GetModeHandler $fakeGetModeTOrdered -InvokeModeHandler $fakeInvokeModeT -PostRunPromptHandler $fakePostRunT -ResetAbortHandler $fakeResetAbortT

Test-Assert ($script:getModeCallsT -eq 3 -and $script:invokeModeCallsT -eq 3) ("the loop ran exactly 3 iterations before Exit (got GetMode=" + $script:getModeCallsT + ", InvokeMode=" + $script:invokeModeCallsT + ")")
Test-Assert ($script:postRunCallsT -eq 3) "Show-PostRunPrompt was consulted after every iteration, including the one that stopped the loop"
Test-Assert ($script:resetAbortCallsT -eq 3) ("-ResetAbortHandler was called exactly once per iteration (got " + $script:resetAbortCallsT + ")")
Test-Assert (@($resetOrderT)[0] -eq "Reset" -and @($resetOrderT)[1] -eq "GetMode") "abort state is reset BEFORE the mode is resolved, not after - so a stray abort can never carry into the mode this iteration picks"
Write-Host ""

# ==============================================================================
#  Scenario T2: Invoke-MainLoop's DEFAULT -ResetAbortHandler resolves to
#  the real AbortPipeline.ps1 Reset-AbortState (this harness dot-sources
#  the real module) - proves the wiring works end to end, not just that
#  an injected fake gets called. Same real-world sequence as
#  AbortPipeline.Harness.ps1's own Scenario R: one abort, then a second
#  loop iteration with no new Ctrl+C.
# ==============================================================================
Write-Host "=== Scenario T2: Invoke-MainLoop's real default ResetAbortHandler actually clears abort state ===" -ForegroundColor Cyan
[ConsoleCtrl]::AbortRequested = $true
$null = Test-AbortSignal
Test-Assert ($script:abortRequested -eq $true) "sanity check: an abort is genuinely in progress before the loop runs"

$pollsT2 = [System.Collections.Generic.List[bool]]::new()
$fakeGetModeT2 = { param($Settings, $SettingsPath) $script:pollsT2.Add($script:abortRequested); return @{ Mode = 'ImageConversion'; RunImageConversion = $true; RunAnimatedConversion = $false; RunZip = $false; RunZipOnly = $false; RunConvertZipped = $false } }
$fakeInvokeModeT2 = { param($Resolved, $TargetPath, $Settings, $CjxlExe, $MagickExe, $LogFile, $LogErrorFile, $LogWarnFile) return New-StatsTracker }
$callsT2 = 0
$fakePostRunT2 = { $script:callsT2++; if ($script:callsT2 -ge 1) { return 'Exit' }; return 'ReturnToMenu' }
$script:pollsT2 = [System.Collections.Generic.List[bool]]::new()
$script:callsT2 = 0
# No -ResetAbortHandler override here - relying on the REAL default.
Invoke-MainLoop -TargetPath "C:\fake\lib" -Settings $fakeSettings -SettingsPath "C:\fake\settings.json" -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" `
    -GetModeHandler $fakeGetModeT2 -InvokeModeHandler $fakeInvokeModeT2 -PostRunPromptHandler $fakePostRunT2

Test-Assert (@($script:pollsT2)[0] -eq $false) "the real Reset-AbortState ran before GetModeHandler, so `$script:abortRequested already reads `$false by the time the mode is resolved - the exact bug this fix closes"
Reset-AbortState
Write-Host ""

# ==============================================================================
#  Scenario T3 (2026-08-31 fix): the per-iteration re-sync
#  (Initialize-CleanConsoleOutput/-FileDeletion) must not hard-crash the
#  whole run loop just because $Settings is missing one of the two keys
#  it reads - both are [Parameter(Mandatory)][bool], and an omitted
#  hashtable key is $null, which used to fail PowerShell's own boolean
#  type coercion with an uncaught terminating error. Uses a $Settings
#  hashtable with NEITHER CleanConsoleOutputEnabled nor PermanentDelete
#  set - Config.ps1 always defaults both in real use, so this only
#  matters for a future caller building $Settings by hand, but the loop
#  should still degrade gracefully (treat missing as $false) rather than
#  crash outright.
# ==============================================================================
Write-Host "=== Scenario T3: a `$Settings hashtable missing CleanConsoleOutputEnabled/PermanentDelete does not crash the loop ===" -ForegroundColor Cyan
# FullLogging deliberately included (unlike the other two) - Write-SummaryReport
# has its own separate Mandatory bool on that key, a pre-existing, unrelated
# requirement this scenario isn't testing; omitting it would make this
# scenario throw for the wrong reason.
$fakeSettingsT3 = @{ FullLogging = $false }
$fakeGetModeT3 = { param($Settings, $SettingsPath) return @{ Mode = 'ImageConversion'; RunImageConversion = $true; RunAnimatedConversion = $false; RunZip = $false; RunZipOnly = $false; RunConvertZipped = $false } }
$fakeInvokeModeT3 = { param($Resolved, $TargetPath, $Settings, $CjxlExe, $MagickExe, $LogFile, $LogErrorFile, $LogWarnFile) return New-StatsTracker }
$script:callsT3 = 0
$fakePostRunT3 = { $script:callsT3++; return 'Exit' }
$threwT3 = $false
try {
    Invoke-MainLoop -TargetPath "C:\fake\lib" -Settings $fakeSettingsT3 -SettingsPath "C:\fake\settings.json" -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" `
        -GetModeHandler $fakeGetModeT3 -InvokeModeHandler $fakeInvokeModeT3 -PostRunPromptHandler $fakePostRunT3
} catch {
    $threwT3 = $true
}
Test-Assert (-not $threwT3) "the loop did not crash despite `$Settings missing both CleanConsoleOutputEnabled and PermanentDelete"
Test-Assert ($script:callsT3 -eq 1) "the loop still ran a full iteration and reached Show-PostRunPrompt"
Write-Host ""

# ==============================================================================
#  Scenario T4 (2026-08-31 fix): Invoke-FullPipeline's own $fullCts/
#  $sharedBudget construction and Register-AbortCancellationSource call were
#  moved INSIDE the function's try block (same species as
#  ZipParallelProcessing.ps1's mutex-leak fix from earlier today) - if
#  Register-AbortCancellationSource throws, the finally block must still
#  run and dispose $fullCts (already constructed by that point).
#  Register-AbortCancellationSource is temporarily replaced with a fake
#  that captures the real $Cts object (so the test can inspect it
#  afterward) and then throws, simulating a real registration failure.
#  Verified via $capturedCts.Token throwing ObjectDisposedException -
#  proof Dispose() actually ran via the finally path, not just that the
#  exception propagated.
# ==============================================================================
Write-Host "=== Scenario T4: a throw during Register-AbortCancellationSource still disposes the already-constructed Cts ===" -ForegroundColor Cyan
$realRegisterFnT4 = ${function:Register-AbortCancellationSource}
$script:capturedCtsT4 = $null
function Register-AbortCancellationSource {
    param([System.Threading.CancellationTokenSource]$Cts)
    $script:capturedCtsT4 = $Cts
    throw "simulated Register-AbortCancellationSource failure"
}
$rootT4 = New-Dir "scenario-t4"
New-Dir "scenario-t4\Series\Chapter 1" | Out-Null
$threwT4 = $false
try {
    $null = Invoke-FullPipeline -Path $rootT4 -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true
} catch {
    $threwT4 = $true
}
${function:Register-AbortCancellationSource} = $realRegisterFnT4

Test-Assert $threwT4 "the registration failure propagated out of Invoke-FullPipeline, not silently swallowed"
Test-Assert ($null -ne $script:capturedCtsT4) "sanity check: the fake actually captured the real Cts object before throwing"
# A disposed CancellationTokenSource's own .Token getter does NOT throw
# (verified directly) - .Cancel() is the operation that does, wrapped by
# PowerShell as a MethodInvocationException whose InnerException is the
# real System.ObjectDisposedException.
$disposedT4 = $false
try { $script:capturedCtsT4.Cancel() } catch { $disposedT4 = ($_.Exception.InnerException -is [System.ObjectDisposedException]) }
Test-Assert $disposedT4 "the Cts was disposed via the finally block despite the throw happening before the old try's own opening brace"
Write-Host ""

# ==============================================================================
#  Scenario T5 (2026-08-31 fix, found by a THIRD-pass re-review):
#  Invoke-MainLoop's own call to Write-SummaryReport (after a real,
#  non-null $stats comes back) was missed by both earlier bool-cast fix
#  passes - unlike T3 (which deliberately included FullLogging specifically
#  to NOT exercise this exact call), this scenario omits FullLogging
#  entirely and drives the loop all the way to Write-SummaryReport.
#  Invoke-MainLoop has NO try/catch of its own around its while loop body
#  (see this function's own comment above Initialize-CleanConsoleOutput),
#  so unlike Invoke-Mode's switch (which swallows exceptions via its own
#  outer catch), "did it throw" IS a valid signal here.
# ==============================================================================
Write-Host "=== Scenario T5: Invoke-MainLoop's own Write-SummaryReport call does not crash on a `$Settings missing FullLogging ===" -ForegroundColor Cyan
$fakeSettingsT5 = @{}
$fakeGetModeT5 = { param($Settings, $SettingsPath) return @{ Mode = 'ImageConversion'; RunImageConversion = $true; RunAnimatedConversion = $false; RunZip = $false; RunZipOnly = $false; RunConvertZipped = $false } }
$fakeInvokeModeT5 = { param($Resolved, $TargetPath, $Settings, $CjxlExe, $MagickExe, $LogFile, $LogErrorFile, $LogWarnFile) return New-StatsTracker }
$script:callsT5 = 0
$fakePostRunT5 = { $script:callsT5++; return 'Exit' }
$threwT5 = $false
try {
    Invoke-MainLoop -TargetPath "C:\fake\lib" -Settings $fakeSettingsT5 -SettingsPath "C:\fake\settings.json" -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" `
        -GetModeHandler $fakeGetModeT5 -InvokeModeHandler $fakeInvokeModeT5 -PostRunPromptHandler $fakePostRunT5
} catch {
    $threwT5 = $true
}
Test-Assert (-not $threwT5) "the loop did not crash at Write-SummaryReport despite `$Settings missing FullLogging entirely"
Test-Assert ($script:callsT5 -eq 1) "the loop still ran a full iteration and reached Show-PostRunPrompt"
Write-Host ""

# ==============================================================================
#  Scenario U: Invoke-MainLoop - a $null Invoke-Mode result (a run that
#  didn't complete) is logged, not treated as a clean summary, and does
#  NOT stop the loop by itself - only Show-PostRunPrompt's own Exit does.
# ==============================================================================
Write-Host "=== Scenario U: Invoke-MainLoop handles a `$null Invoke-Mode result without crashing the loop ===" -ForegroundColor Cyan
$fakeGetModeU = { param($Settings, $SettingsPath) return @{ Mode = 'ImageConversion'; RunImageConversion = $true; RunAnimatedConversion = $false; RunZip = $false; RunZipOnly = $false; RunConvertZipped = $false } }
$fakeInvokeModeU = { param($Resolved, $TargetPath, $Settings, $CjxlExe, $MagickExe, $LogFile, $LogErrorFile, $LogWarnFile) return $null }
$script:postRunCallsU = 0
$fakePostRunU = { $script:postRunCallsU++; return 'Exit' }
Invoke-MainLoop -TargetPath "C:\fake\lib" -Settings $fakeSettings -SettingsPath "C:\fake\settings.json" -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" `
    -GetModeHandler $fakeGetModeU -InvokeModeHandler $fakeInvokeModeU -PostRunPromptHandler $fakePostRunU

Test-Assert ($script:postRunCallsU -eq 1) "a `$null Invoke-Mode result still reaches Show-PostRunPrompt - the loop doesn't crash or skip the prompt"
Write-Host ""

# ==============================================================================
#  Scenario U2: Invoke-MainLoop re-syncs PermanentDelete/CleanConsoleOutput
#  from $Settings on every iteration (2026-08-31 fix) - an options-menu
#  change made during one iteration's Get-SelectedMode call must take
#  effect on THAT SAME iteration's run, not just the next process launch.
#  Uses the real Initialize-FileDeletion/Initialize-CleanConsoleOutput
#  (both dot-sourced for real by this harness), not fakes, so this proves
#  the actual $script: state changes, not just that some function got called.
# ==============================================================================
Write-Host "=== Scenario U2: options-menu toggles re-apply every loop iteration, not just at bootstrap ===" -ForegroundColor Cyan
$fakeSettingsU2 = @{ PermanentDelete = $true; CleanConsoleOutputEnabled = $false; FullLogging = $false }
$script:permDeleteSeenU2 = [System.Collections.Generic.List[bool]]::new()
$script:ccrSeenU2        = [System.Collections.Generic.List[bool]]::new()
$fakeGetModeU2 = { param($Settings, $SettingsPath) return @{ Mode = 'ImageConversion'; RunImageConversion = $true; RunAnimatedConversion = $false; RunZip = $false; RunZipOnly = $false; RunConvertZipped = $false } }
$fakeInvokeModeU2 = {
    param($Resolved, $TargetPath, $Settings, $CjxlExe, $MagickExe, $LogFile, $LogErrorFile, $LogWarnFile)
    # Record what the module-level state actually is AT THE TIME this
    # iteration's mode runs - the real bug was these staying stuck at
    # their bootstrap values across iterations.
    $script:permDeleteSeenU2.Add($script:PermanentDelete)
    $script:ccrSeenU2.Add($script:CleanConsoleOutputEnabled)
    # Simulate the user flipping both toggles in the options menu during
    # THIS iteration, before the next one starts.
    $Settings.PermanentDelete = -not $Settings.PermanentDelete
    $Settings.CleanConsoleOutputEnabled = -not $Settings.CleanConsoleOutputEnabled
    return New-StatsTracker
}
$script:postRunCallsU2 = 0
$fakePostRunU2 = { $script:postRunCallsU2++; if ($script:postRunCallsU2 -ge 2) { return 'Exit' }; return 'ReturnToMenu' }
Invoke-MainLoop -TargetPath "C:\fake\lib" -Settings $fakeSettingsU2 -SettingsPath "C:\fake\settings.json" -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" `
    -GetModeHandler $fakeGetModeU2 -InvokeModeHandler $fakeInvokeModeU2 -PostRunPromptHandler $fakePostRunU2

Test-Assert (@($script:permDeleteSeenU2)[0] -eq $true -and @($script:permDeleteSeenU2)[1] -eq $false) ("`$script:PermanentDelete reflected the CURRENT `$Settings value on both iterations, not just the first (got " + (@($script:permDeleteSeenU2) -join ',') + ")")
Test-Assert (@($script:ccrSeenU2)[0] -eq $false -and @($script:ccrSeenU2)[1] -eq $true) ("`$script:CleanConsoleOutputEnabled reflected the CURRENT `$Settings value on both iterations, not just the first (got " + (@($script:ccrSeenU2) -join ',') + ")")
Write-Host ""

# ==============================================================================
#  Scenario U2b (2026-09-03 fix - Todo.md's mid-session Full Logging /
#  DisableSummaryFile toggle finding): Invoke-MainLoop only re-calls
#  Initialize-LogPaths when FullLogging/DisableSummaryFile actually
#  changed since the last iteration, not on every one (unlike
#  PermanentDelete/CleanConsoleOutput above, which ARE safe to re-apply
#  unconditionally) - and when it does, $LogFile/$LogErrorFile/$LogWarnFile
#  passed to THIS and every later iteration's InvokeModeHandler reflect
#  the refreshed paths, not the ones frozen at bootstrap.
# ==============================================================================
Write-Host "=== Scenario U2b: FullLogging/DisableSummaryFile re-sync only fires on an actual change ===" -ForegroundColor Cyan
$fakeSettingsU2b = @{ PermanentDelete = $false; CleanConsoleOutputEnabled = $false; FullLogging = $false; DisableSummaryFile = $false }
$script:initLogPathsCallsU2b   = [System.Collections.Generic.List[bool]]::new()   # the -FullLogging value each call was made with
$script:initLogMutexCallsU2b   = 0
$script:completeLogRunCallsU2b = 0
$script:startLogRunCallsU2b    = 0
$fakeInitLogPathsU2b = {
    param($TargetPath, $FullLogging, $DisableSummaryFile, $ScriptDir)
    $script:initLogPathsCallsU2b.Add($FullLogging)
    $script:logFile      = "fake-log-" + $FullLogging + ".log"
    $script:logErrorFile = "fake-errors-" + $FullLogging + ".log"
    $script:logWarnFile  = "fake-warn-" + $FullLogging + ".log"
}
$fakeInitLogMutexU2b   = { $script:initLogMutexCallsU2b++ }
$fakeCompleteLogRunU2b = { $script:completeLogRunCallsU2b++ }
$fakeStartLogRunU2b    = { $script:startLogRunCallsU2b++ }
$fakeGetModeU2b = { param($Settings, $SettingsPath) return @{ Mode = 'ImageConversion'; RunImageConversion = $true; RunAnimatedConversion = $false; RunZip = $false; RunZipOnly = $false; RunConvertZipped = $false } }
$script:logFilesSeenU2b = [System.Collections.Generic.List[string]]::new()
$fakeInvokeModeU2b = {
    param($Resolved, $TargetPath, $Settings, $CjxlExe, $MagickExe, $LogFile, $LogErrorFile, $LogWarnFile)
    $script:logFilesSeenU2b.Add($LogFile)
    # Iteration 1: no change (baseline). Iteration 2: flip FullLogging on.
    # Iteration 3: leave it on - proves the handler is skipped again once
    # things are stable at the new value, not just re-triggered forever.
    if ($script:logFilesSeenU2b.Count -eq 1) { $Settings.FullLogging = $true }
    return New-StatsTracker
}
$script:postRunCallsU2b = 0
$fakePostRunU2b = { $script:postRunCallsU2b++; if ($script:postRunCallsU2b -ge 3) { return 'Exit' }; return 'ReturnToMenu' }

Invoke-MainLoop -TargetPath "C:\fake\lib" -Settings $fakeSettingsU2b -SettingsPath "C:\fake\settings.json" -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ScriptDir "C:\fake\scriptdir" `
    -GetModeHandler $fakeGetModeU2b -InvokeModeHandler $fakeInvokeModeU2b -PostRunPromptHandler $fakePostRunU2b `
    -InitializeLogPathsHandler $fakeInitLogPathsU2b -InitializeLogMutexHandler $fakeInitLogMutexU2b -CompleteLogRunHandler $fakeCompleteLogRunU2b -StartLogRunHandler $fakeStartLogRunU2b

Test-Assert ($script:initLogPathsCallsU2b.Count -eq 1 -and @($script:initLogPathsCallsU2b)[0] -eq $true) ("Initialize-LogPaths was re-called exactly once, only on the iteration where FullLogging actually changed (got " + (@($script:initLogPathsCallsU2b) -join ',') + ")")
Test-Assert ($script:initLogMutexCallsU2b -eq 1) "Initialize-LogMutex was re-called the same one time"
Test-Assert (@($script:logFilesSeenU2b)[0] -notlike "fake-log-*") "iteration 1 (no change yet) saw the ORIGINAL LogFile, not a re-synced one"
Test-Assert (@($script:logFilesSeenU2b)[1] -eq "fake-log-True.log") "iteration 2 (FullLogging just flipped true) saw the REFRESHED LogFile from the re-sync"
Test-Assert (@($script:logFilesSeenU2b)[2] -eq "fake-log-True.log") "iteration 3 (no further change) still sees the SAME refreshed LogFile, not reset or re-fetched again"
Test-Assert ($script:completeLogRunCallsU2b -eq 3) "Complete-LogRun runs every iteration regardless of whether the toggle changed"
# 2026-09-03 fix, real bug caught by a same-session /code-review pass:
# Start-LogRun must ALSO run every iteration (paired with Complete-LogRun),
# unlike Initialize-LogPaths which only re-fires on an actual toggle
# change - conflating the two used to leave every run after the first in
# a session with no run header and a stale prior-content snapshot.
Test-Assert ($script:startLogRunCallsU2b -eq 3) "Start-LogRun runs every iteration too - not gated on the FullLogging/DisableSummaryFile toggle"
# Reset the fake handler's relative "fake-log-*.log" paths back to $null -
# left set, they'd leak into every LATER scenario in this same harness run
# that logs an Error/Warn relying on ambient $script:logErrorFile/
# $script:logWarnFile state, writing real content into stray relative-path
# files at the harness's own CWD instead of nowhere/a real scratch path.
$script:logFile      = $null
$script:logErrorFile = $null
$script:logWarnFile  = $null
Write-Host ""

# ==============================================================================
#  Scenario U2c (2026-09-03 fix, real bug caught by a same-session
#  /code-review pass): the mid-loop mutex re-init used to abandon the
#  PREVIOUS mutex object without disposing it - $TargetPath never changes
#  mid-session, so every toggle flip re-created a handle to the exact same
#  named mutex, leaking the old .NET object. Uses the REAL Initialize-
#  LogPaths/Initialize-LogMutex (not fakes) so a real Mutex's Dispose
#  state can actually be observed.
# ==============================================================================
Write-Host "=== Scenario U2c: the previous log mutex is disposed when the toggle re-sync creates a new one ===" -ForegroundColor Cyan
$scratchDirU2c = Join-Path ([System.IO.Path]::GetTempPath()) ("controller-u2c-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDirU2c -Force | Out-Null
$fakeSettingsU2c = @{ PermanentDelete = $false; CleanConsoleOutputEnabled = $false; FullLogging = $false; DisableSummaryFile = $false }
Initialize-LogPaths -TargetPath $scratchDirU2c -FullLogging $false -ScriptDir $scratchDirU2c
Initialize-LogMutex
$mutexBeforeU2c = $script:logMutex

$fakeGetModeU2c = { param($Settings, $SettingsPath) return @{ Mode = 'ImageConversion'; RunImageConversion = $true; RunAnimatedConversion = $false; RunZip = $false; RunZipOnly = $false; RunConvertZipped = $false } }
$fakeInvokeModeU2c = {
    param($Resolved, $TargetPath, $Settings, $CjxlExe, $MagickExe, $LogFile, $LogErrorFile, $LogWarnFile)
    $Settings.FullLogging = $true
    return New-StatsTracker
}
$script:postRunCallsU2c = 0
$fakePostRunU2c = { $script:postRunCallsU2c++; if ($script:postRunCallsU2c -ge 2) { return 'Exit' }; return 'ReturnToMenu' }

Invoke-MainLoop -TargetPath $scratchDirU2c -Settings $fakeSettingsU2c -SettingsPath "C:\fake\settings.json" -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ScriptDir $scratchDirU2c `
    -GetModeHandler $fakeGetModeU2c -InvokeModeHandler $fakeInvokeModeU2c -PostRunPromptHandler $fakePostRunU2c

Test-Assert (-not [object]::ReferenceEquals($script:logMutex, $mutexBeforeU2c)) "sanity check: the toggle flip really did create a NEW mutex object"
$disposedU2c = $false
try { $null = $mutexBeforeU2c.WaitOne(0) } catch [System.ObjectDisposedException] { $disposedU2c = $true } catch { }
Test-Assert $disposedU2c "the PREVIOUS mutex object was disposed, not abandoned, when the toggle created a new one"
$newMutexUsableU2c = $false
try { $null = $script:logMutex.WaitOne(0); $script:logMutex.ReleaseMutex(); $newMutexUsableU2c = $true } catch { }
Test-Assert $newMutexUsableU2c "the NEW mutex is still genuinely usable (disposing the OLD one didn't affect it)"
Write-Host ""

# ==============================================================================
#  Scenario U2d (2026-09-04 fix, real bug): when $InvokeModeHandler returns
#  $null (a crashed/aborted run), the "Run did not complete" Warn used to
#  be logged AFTER CompleteLogRunHandler had already run - in split-log
#  mode that meant the Warn landed appended below the just-reordered
#  block instead of being part of it, and the NEXT run's Start-LogRun then
#  captured it as stale prior content, so it was never correctly reordered
#  on any later pass either. The Warn must now be logged BEFORE
#  CompleteLogRunHandler runs. Write-Log itself is shadowed (not just the
#  injected handler) since the Warn comes from a real Write-Log call
#  inside Invoke-MainLoop, not from an injectable handler.
# ==============================================================================
Write-Host "=== Scenario U2d: the `"Run did not complete`" Warn is logged BEFORE Complete-LogRun runs, not after ===" -ForegroundColor Cyan
$script:eventOrderU2d = [System.Collections.Generic.List[string]]::new()
$realWriteLogU2d = ${function:Write-Log}
function Write-Log {
    param([string]$Message, [string]$Level = "Info", [switch]$ForceConsole)
    if ($Message -like "*Run did not complete*") { $script:eventOrderU2d.Add("WARN") }
    & $script:realWriteLogU2dRef -Message $Message -Level $Level -ForceConsole:$ForceConsole
}
$script:realWriteLogU2dRef = $realWriteLogU2d

$fakeSettingsU2d = @{ PermanentDelete = $false; CleanConsoleOutputEnabled = $false; FullLogging = $false; DisableSummaryFile = $false }
$fakeGetModeU2d = { param($Settings, $SettingsPath) return @{ Mode = 'ImageConversion'; RunImageConversion = $true; RunAnimatedConversion = $false; RunZip = $false; RunZipOnly = $false; RunConvertZipped = $false } }
$fakeInvokeModeU2d = { param($Resolved, $TargetPath, $Settings, $CjxlExe, $MagickExe, $LogFile, $LogErrorFile, $LogWarnFile) return $null }
$fakeStartLogRunU2d    = { }
$fakeCompleteLogRunU2d = { $script:eventOrderU2d.Add("COMPLETE") }
$script:postRunCallsU2d = 0
$fakePostRunU2d = { $script:postRunCallsU2d++; return 'Exit' }

try {
    Invoke-MainLoop -TargetPath "C:\fake\lib" -Settings $fakeSettingsU2d -SettingsPath "C:\fake\settings.json" -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ScriptDir "C:\fake\scriptdir" `
        -GetModeHandler $fakeGetModeU2d -InvokeModeHandler $fakeInvokeModeU2d -PostRunPromptHandler $fakePostRunU2d `
        -StartLogRunHandler $fakeStartLogRunU2d -CompleteLogRunHandler $fakeCompleteLogRunU2d
} finally {
    ${function:Write-Log} = $realWriteLogU2d
}

Test-Assert ($script:eventOrderU2d.Count -eq 2) ("both the Warn and Complete-LogRun fired exactly once each (got " + ($script:eventOrderU2d -join ',') + ")")
Test-Assert (@($script:eventOrderU2d)[0] -eq "WARN" -and @($script:eventOrderU2d)[1] -eq "COMPLETE") ("the Warn was logged BEFORE Complete-LogRun ran, not after (order: " + ($script:eventOrderU2d -join ',') + ")")
Write-Host ""

# ==============================================================================
#  Scenario U2e (2026-09-08 addition): SetQuickEditHandler is called
#  $false right before InvokeModeHandler and $true right after, even when
#  InvokeModeHandler throws - same try/finally bracketing as
#  SetRunActiveHandler, proving Console QuickEdit mode can never be left
#  disabled by a crashed run.
# ==============================================================================
Write-Host "=== Scenario U2e: SetQuickEditHandler brackets InvokeModeHandler, even on a throw ===" -ForegroundColor Cyan
$fakeSettingsU2e = @{ PermanentDelete = $false; CleanConsoleOutputEnabled = $false; FullLogging = $false; DisableSummaryFile = $false }
$fakeGetModeU2e = { param($Settings, $SettingsPath) return @{ Mode = 'ImageConversion'; RunImageConversion = $true; RunAnimatedConversion = $false; RunZip = $false; RunZipOnly = $false; RunConvertZipped = $false } }
$script:quickEditCallsU2e = [System.Collections.Generic.List[bool]]::new()
$fakeSetQuickEditU2e = { param($Enabled) $script:quickEditCallsU2e.Add($Enabled) }.GetNewClosure()
$fakeInvokeModeU2e = { param($Resolved, $TargetPath, $Settings, $CjxlExe, $MagickExe, $LogFile, $LogErrorFile, $LogWarnFile) throw "simulated crash mid-run" }
$script:postRunCallsU2e = 0
$fakePostRunU2e = { $script:postRunCallsU2e++; return 'Exit' }

# Invoke-MainLoop's own try/finally around InvokeModeHandler has no catch
# (a real InvokeModeHandler - Invoke-Mode - already catches everything
# itself; this fake deliberately bypasses that to prove the finally still
# runs) - so the throw propagates OUT of Invoke-MainLoop itself here,
# same as it would for a real uncaught crash. Caught here just so this
# scenario's own assertions can still run afterward.
$threwU2e = $false
try {
    Invoke-MainLoop -TargetPath "C:\fake\lib" -Settings $fakeSettingsU2e -SettingsPath "C:\fake\settings.json" -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ScriptDir "C:\fake\scriptdir" `
        -GetModeHandler $fakeGetModeU2e -InvokeModeHandler $fakeInvokeModeU2e -PostRunPromptHandler $fakePostRunU2e -SetQuickEditHandler $fakeSetQuickEditU2e
} catch {
    $threwU2e = $true
}

Test-Assert $threwU2e "sanity check: the simulated crash really did propagate out of Invoke-MainLoop (this fake bypasses Invoke-Mode's own catch)"
Test-Assert ($script:quickEditCallsU2e.Count -eq 2) ("SetQuickEditHandler fired exactly twice, even though InvokeModeHandler threw (got " + $script:quickEditCallsU2e.Count + ")")
Test-Assert ((@($script:quickEditCallsU2e)[0] -eq $false) -and (@($script:quickEditCallsU2e)[1] -eq $true)) ("QuickEdit was disabled ($false) before the run and re-enabled ($true) after, in that order (got " + ($script:quickEditCallsU2e -join ',') + ")")
Write-Host ""

# ==============================================================================
#  Scenario U3 (2026-09-02 review fix): mode 5 (Cover Deletion)'s real work
#  runs INSIDE $GetModeHandler (Get-SelectedMode -> Show-ModeMenu ->
#  Show-CoverDeletionMenu), not inside $InvokeModeHandler like every other
#  mode - so it was never covered by Invoke-Mode's own try/catch. Before
#  this fix, a throw from $GetModeHandler had nothing to catch it in this
#  loop at all - it escaped straight to the bootstrap's top-level catch,
#  taking down the whole script instead of being logged and returning to
#  the menu like every other mode's own crash already does (Scenario U,
#  above, proves the $InvokeModeHandler side of this same contract).
# ==============================================================================
Write-Host "=== Scenario U3: Invoke-MainLoop handles a throwing GetModeHandler without crashing the loop ===" -ForegroundColor Cyan
$fakeGetModeU3 = { param($Settings, $SettingsPath) throw "simulated crash inside mode 5's own Cover Deletion work" }
$script:invokeModeCallsU3 = 0
$fakeInvokeModeU3 = { param($Resolved, $TargetPath, $Settings, $CjxlExe, $MagickExe, $LogFile, $LogErrorFile, $LogWarnFile) $script:invokeModeCallsU3++; return New-StatsTracker }
$script:postRunCallsU3 = 0
$fakePostRunU3 = { $script:postRunCallsU3++; return 'Exit' }
$loggedErrorsU3 = [System.Collections.Generic.List[string]]::new()
$fakeLogHandlerU3 = { param($m) $loggedErrorsU3.Add($m) }.GetNewClosure()

Invoke-MainLoop -TargetPath "C:\fake\lib" -Settings $fakeSettings -SettingsPath "C:\fake\settings.json" -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" `
    -GetModeHandler $fakeGetModeU3 -InvokeModeHandler $fakeInvokeModeU3 -PostRunPromptHandler $fakePostRunU3 -LogHandler $fakeLogHandlerU3

Test-Assert ($loggedErrorsU3.Count -ge 1) "the throw from GetModeHandler was actually logged, not silently lost"
Test-Assert ($script:invokeModeCallsU3 -eq 0) "InvokeModeHandler was never called - the loop didn't try to run a mode from a failed resolution"
Test-Assert ($script:postRunCallsU3 -eq 1) "the loop still reached Show-PostRunPrompt after the crash - same recovery path as a `$null Invoke-Mode result"
Write-Host ""

# ==============================================================================
#  Scenario V: the Full-Pipeline AVIF race fix (2026-08-28) - a static and
#  an animated AVIF in the SAME chapter are each routed to exactly one
#  engine, proving the reconciliation actually prevents double-discovery/
#  double-dispatch, not just that both engines still individually work.
# ==============================================================================
Write-Host "=== Scenario V: AVIF race fix - static/animated AVIF each routed to exactly one engine ===" -ForegroundColor Cyan
$chV = New-Dir "scenario-v\Series\Chapter 1"
New-FakeAvifIn -DirPath $chV -Name "static.avif" -Frames 1 | Out-Null
New-FakeAvifIn -DirPath $chV -Name "animated.avif" -Frames 5 | Out-Null

$totalsV = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-v") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true

Test-Assert ($totalsV.ConvertedImageSuccess -eq 1) ("exactly one file converted by the IMAGE engine - the static one (got " + $totalsV.ConvertedImageSuccess + ")")
Test-Assert ($totalsV.ConvertedAnimatedSuccess -eq 1) ("exactly one file converted by the ANIMATED engine - the animated one (got " + $totalsV.ConvertedAnimatedSuccess + ")")
Test-Assert ($totalsV.InspectFailedCount -eq 0) "no classification failures for two cleanly-identifiable files"
Write-Host ""

# ==============================================================================
#  Scenario V2 (2026-08-31 efficiency fix): the animated AVIF from Scenario
#  V's own setup is classified by Controller.ps1's own reconciliation step
#  AND handed to Convert-AnimatedBatch - before the fix, that meant TWO
#  separate `magick identify` spawns for the same file (one during
#  classification, one from Convert-AnimatedBatch's own re-check). The
#  fake magick.exe now logs every identify call's target path (gated on
#  HARNESS_IDENTIFY_LOG so other scenarios pay nothing); this counts how
#  many times "animated.avif" was actually identified.
# ==============================================================================
Write-Host "=== Scenario V2: an ambiguous AVIF is identified ONCE, not twice (classification result is reused, not re-checked) ===" -ForegroundColor Cyan
$identifyLogV2 = Join-Path $scratchDir "scenario-v2-identify.log"
[System.IO.File]::WriteAllText($identifyLogV2, "")
$env:HARNESS_IDENTIFY_LOG = $identifyLogV2

$chV2 = New-Dir "scenario-v2\Series\Chapter 1"
New-FakeAvifIn -DirPath $chV2 -Name "animated.avif" -Frames 5 | Out-Null

try {
    $totalsV2 = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-v2") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true
} finally {
    $env:HARNESS_IDENTIFY_LOG = $null
}

$identifyCallsV2 = @(Get-Content -LiteralPath $identifyLogV2 | Where-Object { $_ -like "*animated.avif" })
Test-Assert ($totalsV2.ConvertedAnimatedSuccess -eq 1) "sanity check: the file still converted correctly through the animated engine"
Test-Assert ($identifyCallsV2.Count -eq 1) ("the file was identified exactly once, not twice (got " + $identifyCallsV2.Count + " identify call(s))")
Write-Host ""

# ==============================================================================
#  Scenario V3 (2026-08-31 efficiency fix, mirror of V2): a STATIC ambiguous
#  AVIF is identified ONCE too - before this fix, only the animated side
#  got a -KnownAnimatedPaths equivalent; a Static-classified file still
#  fell through to Convert-ImageBatch's own unconditional Test-AvifAnimated
#  re-check. Convert-ImageBatch now takes -KnownStaticPaths, mirroring
#  Convert-AnimatedBatch's own parameter exactly.
# ==============================================================================
Write-Host "=== Scenario V3: a static ambiguous AVIF is identified ONCE, not twice (mirror of V2 for the image engine) ===" -ForegroundColor Cyan
$identifyLogV3 = Join-Path $scratchDir "scenario-v3-identify.log"
[System.IO.File]::WriteAllText($identifyLogV3, "")
$env:HARNESS_IDENTIFY_LOG = $identifyLogV3

$chV3 = New-Dir "scenario-v3\Series\Chapter 1"
New-FakeAvifIn -DirPath $chV3 -Name "static.avif" -Frames 1 | Out-Null

try {
    $totalsV3 = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-v3") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true
} finally {
    $env:HARNESS_IDENTIFY_LOG = $null
}

$identifyCallsV3 = @(Get-Content -LiteralPath $identifyLogV3 | Where-Object { $_ -like "*static.avif" })
Test-Assert ($totalsV3.ConvertedImageSuccess -eq 1) "sanity check: the file still converted correctly through the image engine"
Test-Assert ($identifyCallsV3.Count -eq 1) ("the file was identified exactly once, not twice (got " + $identifyCallsV3.Count + " identify call(s))")
Write-Host ""

# ==============================================================================
#  Scenario W: a file the reconciliation can't classify is excluded from
#  BOTH engines for that run, not guessed at or left to race - the
#  "fail safe" half of the same fix.
# ==============================================================================
Write-Host "=== Scenario W: AVIF race fix - an unclassifiable file is excluded from BOTH engines ===" -ForegroundColor Cyan
$chW = New-Dir "scenario-w\Series\Chapter 1"
[System.IO.File]::WriteAllText((Join-Path $chW "corrupt.avif"), "FAIL_IDENTIFY")
New-FakeAvifIn -DirPath $chW -Name "animated.avif" -Frames 5 | Out-Null

$totalsW = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-w") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true

Test-Assert ($totalsW.ConvertedImageSuccess -eq 0 -and $totalsW.ConvertedImageFail -eq 0 -and $totalsW.ConvertedImageSkipped -eq 0) "the unclassifiable file was NOT dispatched to the image engine at all"
Test-Assert ($totalsW.ConvertedAnimatedSuccess -eq 1) "the OTHER, real animated file in the same chapter still converted normally"
Test-Assert ($totalsW.InspectFailedCount -eq 1) ("the classification failure was counted exactly once, directly in Invoke-FullPipeline's own InspectFailedCount, not through either engine (got " + $totalsW.InspectFailedCount + ")")
Test-Assert (Test-Path -LiteralPath (Join-Path $chW "corrupt.avif")) "the unclassifiable source file was left untouched, not deleted by either engine"
Test-Assert ($totalsW.ZipCreatedSuccess -eq 0) "the chapter was NOT zipped at all - a real bug this scenario caught live: without blocking zip here too, the unclassified source got swept into the zip in raw form and its loose folder deleted anyway"
# 2026-08-31 fix: a chapter forced un-zippable by a classification
# failure used to be invisible in EVERY zip-outcome counter (IsZippable
# was already false, so the existing ZipSkippedDueToError elseif never
# fired for it) - the run summary's zip section looked complete while
# silently omitting a chapter that should have zipped and didn't.
Test-Assert ($totalsW.ZipSkippedDueToError -eq 1) ("the classification-blocked chapter is now counted in ZipSkippedDueToError, not invisible (got " + $totalsW.ZipSkippedDueToError + ")")
Write-Host ""

# ==============================================================================
#  Scenario X (2026-08-31 fix, from ImageConversionPipeline.ps1's own
#  dedicated per-module /code-review): a same-basename naming collision
#  (a source not older than a pre-existing, unrelated .jxl it did not
#  produce) used to be completely invisible to Full Pipeline - Get-
#  LooseImageCandidates excluded it from both NeedsConversion and
#  StaleSources with no counter and no zip-block, so a chapter whose only
#  loose file was such a collision reported a clean Success and could get
#  zipped with the raw, unconverted collision file still inside it.
#  Get-LooseImageCandidates now returns it via NamingCollisions, and
#  Controller.ps1 folds it into InspectFailedCount and
#  $failedClassificationDirs the same way an AVIF classification failure
#  already was.
# ==============================================================================
Write-Host "=== Scenario X: a naming collision blocks its own chapter from zipping, same as an AVIF classification failure ===" -ForegroundColor Cyan
$chX = New-Dir "scenario-x\Series\Chapter 1"
[System.IO.File]::WriteAllText((Join-Path $chX "photo.jxl"), "real jxl bytes from a since-deleted photo.jpg")
Start-Sleep -Milliseconds 50
New-FakeImageIn -DirPath $chX -Name "photo.png" | Out-Null

$totalsX = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-x") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true

Test-Assert ($totalsX.ConvertedImageSuccess -eq 0 -and $totalsX.ConvertedImageFail -eq 0) "the colliding source was neither converted nor counted as a failure - just left alone"
Test-Assert ($totalsX.InspectFailedCount -eq 1) ("the naming collision was counted in Invoke-FullPipeline's own InspectFailedCount, not invisible (got " + $totalsX.InspectFailedCount + ")")
Test-Assert (Test-Path -LiteralPath (Join-Path $chX "photo.png")) "the colliding source survives untouched on disk - not deleted"
Test-Assert ($totalsX.ZipCreatedSuccess -eq 0) "the chapter was NOT zipped - the raw, unconverted collision file did not get swept into an archive"
Test-Assert ($totalsX.ZipSkippedDueToError -eq 1) ("the naming-collision-blocked chapter is counted in ZipSkippedDueToError, same as the AVIF classification case (got " + $totalsX.ZipSkippedDueToError + ")")
Write-Host ""

# ==============================================================================
#  Scenario Y (2026-08-31 fix, caught by verifying a same-day /code-review
#  4th pass on ImageConversionPipeline.ps1): an orphaned "_tmp_*" scratch
#  file (its owning cleanup couldn't run) sitting in a chapter this
#  function is about to zip. Full Pipeline calls Compress-FolderToZip
#  DIRECTLY (this function's own comment above explains why - .webp is
#  ambiguous here, both a possible leftover source AND the animated
#  engine's own real output, so it can't reuse Invoke-LooseFolderZip's
#  guard) - without a matching sweep, the debris gets permanently archived
#  into the .cbz as a junk page, the only mode able to produce
#  "_tmp_overwrite.webp" in the first place (-DoAnimatedOverwrite only
#  ever runs here).
# ==============================================================================
Write-Host "=== Scenario Y: an orphaned _tmp_* scratch file is deleted before zipping, not archived ===" -ForegroundColor Cyan
$chY = New-Dir "scenario-y\Series\Chapter 1"
New-FakeImageIn -DirPath $chY -Name "page1.jpg" | Out-Null
[System.IO.File]::WriteAllText((Join-Path $chY "photo_tmp_iccstrip.png"), "orphaned strip scratch")
[System.IO.File]::WriteAllText((Join-Path $chY "photo_tmp_iccstrip-0.png"), "orphaned NUMBERED strip scratch")
[System.IO.File]::WriteAllText((Join-Path $chY "photo_tmp_bmp2png.png"), "orphaned bmp scratch")
[System.IO.File]::WriteAllText((Join-Path $chY "photo_tmp_heic2png.png"), "orphaned heic scratch")
[System.IO.File]::WriteAllText((Join-Path $chY "photo_tmp_heif2png.png"), "orphaned heif scratch")
[System.IO.File]::WriteAllText((Join-Path $chY "photo_tmp_overwrite.webp"), "orphaned overwrite scratch")

$totalsY = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-y") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true

# 2026-09-02 review fix: the BMP/HEIC/HEIF scratch patterns (and the
# numbered iccstrip variant) were confirmed live to be missed by the
# pre-widening regex here.
Test-Assert ($totalsY.ZipCreatedSuccess -eq 1) ("the chapter still zipped cleanly, not blocked by the scratch files (got ZipCreatedSuccess=" + $totalsY.ZipCreatedSuccess + ")")
$zipOutY = Join-Path $scratchDir "scenario-y\Series\Chapter 1.zip"
Test-Assert (Test-Path -LiteralPath $zipOutY) "the zip file was created"
$zipEntriesY = [System.IO.Compression.ZipFile]::OpenRead($zipOutY)
try {
    $entryNamesY = @($zipEntriesY.Entries | ForEach-Object { $_.Name })
} finally {
    $zipEntriesY.Dispose()
}
Test-Assert (@($entryNamesY | Where-Object { $_ -match '_tmp_' }).Count -eq 0) ("none of the 6 scratch files were archived into the zip (got entries: " + ($entryNamesY -join ", ") + ")")
Write-Host ""

# ==============================================================================
#  Scenario Y2 (2026-09-02 review fix): a chapter whose ONLY content is an
#  orphaned scratch file - Get-LooseImageCandidates excludes it from both
#  engines, so nothing gets dispatched or blocks zipping, but the scratch
#  sweep right before zipping then empties the folder entirely. The
#  resulting zip has 0 entries - Test-ZipArchive throws even before
#  checking -RequireJxlEntry - a REAL failure that leaves a REAL,
#  complete-looking (if empty) zip file on disk, exactly the gap
#  ZipPipeline.ps1's own Invoke-LooseFolderZip had (same day's matching
#  fix, ZipPipeline.Harness.ps1 Scenario H). Confirms the broken zip is
#  now deleted here too, not left behind to permanently hide this
#  chapter from Get-SeriesChapters on every later run via the staleness
#  guard.
# ==============================================================================
Write-Host "=== Scenario Y2: a chapter emptied by the scratch sweep produces a 0-entry zip, which gets deleted, not left behind ===" -ForegroundColor Cyan
$chY2 = New-Dir "scenario-y2\Series\Chapter 1"
[System.IO.File]::WriteAllText((Join-Path $chY2 "photo_tmp_iccstrip.png"), "orphaned strip scratch, nothing else in this chapter")

$totalsY2 = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-y2") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true

$zipOutY2 = Join-Path $scratchDir "scenario-y2\Series\Chapter 1.zip"
Test-Assert ($totalsY2.ZipCreatedFail -eq 1) ("the 0-entry zip was correctly counted as a failure, not a success (got ZipCreatedFail=" + $totalsY2.ZipCreatedFail + ")")
Test-Assert (-not (Test-Path -LiteralPath $zipOutY2)) "the broken 0-entry zip itself was deleted on validation failure, not left behind to permanently hide this chapter from later runs"
Write-Host ""

# ==============================================================================
#  Scenario Z2 (2026-08-31 fix, caught by a same-day /code-review
#  full-codebase pass): every -FullLogging/-DoFullLogging argument Invoke-Mode
#  passes now reads $script:FullLogging (the value Initialize-LogPaths froze
#  at bootstrap, matching the ALSO-frozen $LogFile/$LogErrorFile/$LogWarnFile
#  paths threaded alongside it), NOT live $Settings.FullLogging. Before this
#  fix, a user toggling Full Logging in the Options menu mid-session changed
#  ONLY the live flag - the frozen paths never moved - so a worker runspace
#  (which sets its OWN fresh $script:FullLogging from whatever this switch
#  passed it) ended up with a live post-toggle flag paired against the OLD
#  pre-toggle paths, sending every worker-side Write-Log call to a $null
#  path in split-mode and silently dropping it. This scenario simulates a
#  toggle having happened: $script:FullLogging (frozen, pre-toggle) is
#  $true, $fakeSettings.FullLogging (live, post-toggle) is $false - the
#  handler must see the FROZEN value, not the live one.
# ==============================================================================
Write-Host "=== Scenario Z2: Invoke-Mode passes the FROZEN `$script:FullLogging, not live `$Settings.FullLogging ===" -ForegroundColor Cyan
$fakeSettingsZ2 = $fakeSettings.Clone()
$fakeSettingsZ2.FullLogging = $false
$script:FullLogging = $true
$capturedZ2 = @{}
$fakeImageHandlerZ2 = {
    param($Path, $CjxlExe, $MagickExe, $JpegLossless, $JpegQuality, $MaxCjxlProcs, $FullLogging)
    $capturedZ2.FullLogging = $FullLogging
    return @{ ConvertedSuccess = 1; ConvertedFail = 0; ConvertedSkipped = 0; DeletedSuccess = 1; DeletedFail = 0; StaleCleanedSuccess = 0; StaleCleanedFail = 0; InspectFailedCount = 0 }
}.GetNewClosure()
$null = Invoke-Mode -Resolved @{ Mode = 'ImageConversion' } -TargetPath "C:\fake\lib" -Settings $fakeSettingsZ2 -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ImageConversionHandler $fakeImageHandlerZ2
$script:FullLogging = $false

Test-Assert ($capturedZ2.FullLogging -eq $true) ("the handler received the frozen `$script:FullLogging (`$true), not the live `$Settings.FullLogging (`$false) (got " + $capturedZ2.FullLogging + ")")
Write-Host ""

# ==============================================================================
#  Scenario Z3 (2026-09-02, recurring-bug-pattern coverage): the REAL
#  $script:fullPipelineChapterWorker scriptblock's own defaults, invoked
#  directly - distinct from Convert-ImageBatch/Convert-AnimatedBatch's OWN
#  defaults (already proven safe by ImageConversionPipeline.Harness.ps1's
#  own Scenario AI). This worker forwards -DoJpegQuality/-AnimatedQuality/
#  -DoAnimatedDeleteSource to those functions EXPLICITLY, so an omitted
#  key here overrides whatever safe default they have, regardless of it.
#  Two real divergences of this exact shape were found in this seam on
#  2026-09-02 (a same-day full-codebase review found -DoJpegQuality/
#  -AnimatedQuality; a same-day cross-module-seam review then found
#  -DoAnimatedDeleteSource) and neither had a test proving the WORKER's
#  own fallback - as opposed to the downstream function's - was safe.
#  This closes that for all three at once, directly, rather than only
#  ever proving it indirectly through Invoke-FullPipelineChapter (which
#  always sets every key explicitly and so could never have caught this).
# ==============================================================================
Write-Host "=== Scenario Z3: the worker scriptblock's own DoJpegQuality/AnimatedQuality/DoAnimatedDeleteSource defaults are safe when omitted ===" -ForegroundColor Cyan

$chZ3 = New-Dir "scenario-z3\Series\Chapter 1"
$imgZ3 = Join-Path $chZ3 "page1.jpg"
[System.IO.File]::WriteAllText($imgZ3, "ARGS_MARKER")
$avifZ3 = Join-Path $chZ3 "anim1.avif"
[System.IO.File]::WriteAllText($avifZ3, "FRAMES:2")

$budgetZ3 = [System.Threading.SemaphoreSlim]::new(4, 4)
$imageResultZ3 = & $script:fullPipelineChapterWorker -EngineType 'Image' -Files @(Get-Item -LiteralPath $imgZ3) `
    -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -DoFullLogging $false -CancelToken ([System.Threading.CancellationToken]::None) `
    -SharedBudget $budgetZ3 -DoPermanentDelete $true
$expectedJxlZ3 = Join-Path $chZ3 "page1.jxl"
$argsTextZ3 = Get-Content -LiteralPath $expectedJxlZ3 -Raw
Test-Assert ($imageResultZ3.Result.ConvertedCount -eq 1) "sanity check: the worker's own Image-engine call succeeded"
Test-Assert ($argsTextZ3 -match "--quality=90(\s|$)") ("the worker's own -DoJpegQuality default is 90 when omitted, not 0 (got: '" + $argsTextZ3.Trim() + "')")

$animatedResultZ3 = & $script:fullPipelineChapterWorker -EngineType 'Animated' -Files @(Get-Item -LiteralPath $avifZ3) `
    -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -DoFullLogging $false -CancelToken ([System.Threading.CancellationToken]::None) `
    -SharedBudget $budgetZ3 -DoPermanentDelete $true
$expectedWebpZ3 = Join-Path $chZ3 "anim1.webp"
$animArgsTextZ3 = Get-Content -LiteralPath $expectedWebpZ3 -Raw
Test-Assert ($animatedResultZ3.Result.ConvertedCount -eq 1) "sanity check: the worker's own Animated-engine call succeeded"
Test-Assert ($animArgsTextZ3 -match "-quality 90(\s|$)") ("the worker's own -AnimatedQuality default is 90 when omitted, not 0 (got: '" + $animArgsTextZ3.Trim() + "')")
Test-Assert (-not (Test-Path -LiteralPath $avifZ3)) "the worker's own -DoAnimatedDeleteSource default is `$true when omitted - the source .avif was deleted, not left behind to double up with its own .webp in the eventual zip"
$budgetZ3.Dispose()
Write-Host ""

# ==============================================================================
#  Scenario Z4 (2026-09-03 fix, real bug, live-reported and quantified via
#  two real user logs): AVIF classification must happen PER-CHAPTER, not as
#  one series-wide pre-pass before any chapter starts. Before this fix, a
#  series-wide pass classified EVERY avif across the WHOLE series (via
#  Test-AvifAnimated) before the "=== Series ===" log line, let alone any
#  chapter's own dispatch - a 100+-chapter series with a few hundred avifs
#  meant tens of minutes of silence before the first chapter even started.
#
#  Builds a 2-chapter series: Chapter 1 has a plain image (no avif at all);
#  Chapter 2 has one avif. Spies on BOTH Start-ChapterProgress and
#  Test-AvifAnimated (real pass-through wrappers, same technique used
#  elsewhere in this file) into ONE shared ordered timeline - NOT Write-Log,
#  which is also called from inside the worker runspaces Invoke-FullPipeline
#  dispatches, where a locally-redefined function referencing this scope's
#  own $script: state isn't available (a runspace doesn't share the parent
#  scope - see CLAUDE.md); Start-ChapterProgress and Test-AvifAnimated are
#  both only ever called from the main thread, in Controller.ps1's own
#  per-chapter loop, so spying on them is safe. The distinguishing signal:
#  in the OLD series-wide-pre-pass code, classifying chapter 2's avif would
#  happen BEFORE chapter 1's own Start-ChapterProgress call (classification
#  ran before the per-chapter loop even started, chapter 1 included). In the
#  per-chapter code, it can only happen once the loop actually REACHES
#  chapter 2's own iteration - necessarily after chapter 1's call. This is a
#  deterministic ORDERING assertion, not a timing one - no SLEEP_MS/
#  Stopwatch flakiness risk. Requires Clean Console Output on, since
#  Start-ChapterProgress is only called when that toggle is enabled.
# ==============================================================================
Write-Host "=== Scenario Z4: AVIF classification happens per-chapter, not as one series-wide pre-pass ===" -ForegroundColor Cyan
$chZ4a = New-Dir "scenario-z4\Series\01 - Chapter 1"
$chZ4b = New-Dir "scenario-z4\Series\02 - Chapter 2"
New-FakeImageIn -DirPath $chZ4a -Name "page1.jpg" | Out-Null
$avifZ4 = New-FakeAvifIn -DirPath $chZ4b -Name "anim1.avif" -Frames 4

$script:eventOrderZ4 = New-Object System.Collections.Generic.List[string]
$realStartChapterProgressZ4 = ${function:Start-ChapterProgress}
function Start-ChapterProgress {
    param([string]$SeriesName, [string]$ChapterName)
    $script:eventOrderZ4.Add("CHAPTER:" + $ChapterName)
    & $script:realStartChapterProgressZ4Ref -SeriesName $SeriesName -ChapterName $ChapterName
}
$script:realStartChapterProgressZ4Ref = $realStartChapterProgressZ4
$realTestAvifAnimatedZ4 = ${function:Test-AvifAnimated}
function Test-AvifAnimated {
    param([string]$AvifPath, [string]$MagickExe)
    $script:eventOrderZ4.Add("CLASSIFY:" + $AvifPath)
    & $script:realTestAvifAnimatedZ4Ref -AvifPath $AvifPath -MagickExe $MagickExe
}
$script:realTestAvifAnimatedZ4Ref = $realTestAvifAnimatedZ4

$script:CleanConsoleOutputEnabled = $true
try {
    $totalsZ4 = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-z4") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true
} finally {
    $script:CleanConsoleOutputEnabled = $false
    ${function:Start-ChapterProgress} = $realStartChapterProgressZ4
    ${function:Test-AvifAnimated} = $realTestAvifAnimatedZ4
}

$chapter1IndexZ4 = $script:eventOrderZ4.FindIndex({ param($e) $e -eq "CHAPTER:01 - Chapter 1" })
$classifyIndexZ4 = $script:eventOrderZ4.FindIndex({ param($e) $e -eq ("CLASSIFY:" + $avifZ4) })
Test-Assert ($chapter1IndexZ4 -ge 0) "sanity check: chapter 1's own Start-ChapterProgress call was found in the event timeline"
Test-Assert ($classifyIndexZ4 -ge 0) "sanity check: chapter 2's avif was actually classified during this run"
Test-Assert ($chapter1IndexZ4 -lt $classifyIndexZ4) ("chapter 1's own dispatch started BEFORE chapter 2's avif was classified (chapter1 index=" + $chapter1IndexZ4 + ", classify index=" + $classifyIndexZ4 + ") - proves classification is per-chapter, not a series-wide pre-pass")
Test-Assert ($totalsZ4.ConvertedImageSuccess -eq 1 -and $totalsZ4.ConvertedAnimatedSuccess -eq 1) "sanity check: both chapters still converted correctly end to end"
Write-Host ""

# ==============================================================================
#  Scenario Z5 (2026-09-03 fix, real bug found by code review): a directory
#  Get-SeriesChapters doesn't discover as a real chapter (e.g. because it's
#  already fully converted and zipped, excluded by that function's own "up
#  to date" guard) but that still holds a leftover STALE source file must
#  still get that file cleaned up - not silently orphaned forever. Before
#  this fix, $extraDirPaths (the "chapter discovery missed this directory"
#  completeness fallback) only looked at $imagesByDir/$animatedByDir
#  (directories with something to CONVERT), never $staleByDir (directories
#  with only something to CLEAN UP) - so a stale-only directory never
#  entered $chapterEntries at all, and its own $chStale was never reached.
#
#  Function-swaps Get-SeriesChapters to simulate real exclusion (calls the
#  REAL function, then filters OUT the stale-only chapter's directory from
#  its result) rather than trying to reverse-engineer the exact real-world
#  trigger for that exclusion - the fix under test is entirely about what
#  Invoke-FullPipeline does once a directory is ALREADY excluded, not about
#  how Get-SeriesChapters decides to exclude it.
# ==============================================================================
Write-Host "=== Scenario Z5: a directory chapter-discovery missed, holding only a stale source, still gets cleaned up ===" -ForegroundColor Cyan
$chZ5Normal = New-Dir "scenario-z5\Series\01 - Chapter 1"
New-FakeImageIn -DirPath $chZ5Normal -Name "page1.jpg" | Out-Null
$chZ5StaleOnly = New-Dir "scenario-z5\Series\02 - Chapter 2"
New-FakeImageIn -DirPath $chZ5StaleOnly -Name "old.jpg" | Out-Null
Start-Sleep -Milliseconds 50
[System.IO.File]::WriteAllText((Join-Path $chZ5StaleOnly "old.jxl"), "already converted on a prior run")

$realGetSeriesChaptersZ5 = ${function:Get-SeriesChapters}
function Get-SeriesChapters {
    param([string]$SeriesPath, [string[]]$QualifyingExtensions, [string[]]$ExcludeStagingDirs, [bool]$ForceRezip)
    $real = & $script:realGetSeriesChaptersZ5Ref -SeriesPath $SeriesPath -QualifyingExtensions $QualifyingExtensions -ExcludeStagingDirs $ExcludeStagingDirs -ForceRezip $ForceRezip
    return @($real | Where-Object { $_.Dir.FullName -ne $script:chZ5StaleOnlyRef })
}
$script:realGetSeriesChaptersZ5Ref = $realGetSeriesChaptersZ5
$script:chZ5StaleOnlyRef = (Get-Item -LiteralPath $chZ5StaleOnly).FullName

try {
    $totalsZ5 = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-z5") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true
} finally {
    ${function:Get-SeriesChapters} = $realGetSeriesChaptersZ5
}

Test-Assert ($totalsZ5.ConvertedImageSuccess -eq 1) "sanity check: chapter 1's real image still converted normally"
Test-Assert ($totalsZ5.StaleImageCleanedSuccess -eq 1) ("chapter 2's stale leftover was cleaned up despite chapter-discovery missing the directory entirely (got StaleImageCleanedSuccess=" + $totalsZ5.StaleImageCleanedSuccess + ")")
Write-Host ""

# ==============================================================================
#  Scenario Z6 (2026-09-04 fix, real bug): an abort raised mid per-chapter
#  AVIF classification must (a) stop classifying further contested files in
#  THAT chapter immediately, not spawn every remaining ~10-17s magick
#  identify first, and (b) stop that chapter's own Remove-StaleLooseSources
#  deletion from running at all - not just be picked up by the NEXT
#  chapter's own top-of-loop check. Test-AvifAnimated shadowed so the
#  FIRST classification call raises the abort - a second contested AVIF in
#  the SAME chapter must never be classified.
# ==============================================================================
Write-Host "=== Scenario Z6: abort mid-AVIF-classification stops further classification AND this chapter's own stale cleanup ===" -ForegroundColor Cyan
$chZ6 = New-Dir "scenario-z6\Series\Chapter 1"
New-FakeAvifIn -DirPath $chZ6 -Name "animated1.avif" -Frames 5 | Out-Null
New-FakeAvifIn -DirPath $chZ6 -Name "animated2.avif" -Frames 5 | Out-Null
New-FakeImageIn -DirPath $chZ6 -Name "stale.jpg" | Out-Null
Start-Sleep -Milliseconds 50
[System.IO.File]::WriteAllText((Join-Path $chZ6 "stale.jxl"), "already converted on a prior run")

$script:classifyCallsZ6 = 0
$realTestAvifAnimatedZ6 = ${function:Test-AvifAnimated}
function Test-AvifAnimated {
    param([string]$AvifPath, [string]$MagickExe)
    $script:classifyCallsZ6++
    [ConsoleCtrl]::AbortRequested = $true
    & $script:realTestAvifAnimatedZ6Ref -AvifPath $AvifPath -MagickExe $MagickExe
}
$script:realTestAvifAnimatedZ6Ref = $realTestAvifAnimatedZ6

try {
    $totalsZ6 = Invoke-FullPipeline -Path (Join-Path $scratchDir "scenario-z6") -CjxlExe $fakeCjxlExe -MagickExe $fakeMagickExe -FullPipelineMaxConcurrentProcs 4 -FullLogging $false -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile -PermanentDelete $true
} finally {
    ${function:Test-AvifAnimated} = $realTestAvifAnimatedZ6
    Reset-AbortState
}

Test-Assert ($script:classifyCallsZ6 -eq 1) ("classification stopped after the first call once abort was raised, not both (got " + $script:classifyCallsZ6 + ")")
Test-Assert ($totalsZ6.Aborted -eq $true) "the run's own totals record the abort"
Test-Assert ($totalsZ6.StaleImageCleanedSuccess -eq 0 -and $totalsZ6.StaleImageCleanedFail -eq 0) ("this chapter's own stale cleanup did NOT run after the abort (got Success=" + $totalsZ6.StaleImageCleanedSuccess + ", Fail=" + $totalsZ6.StaleImageCleanedFail + ")")
Test-Assert (Test-Path -LiteralPath (Join-Path $chZ6 "stale.jpg")) "the stale source file is still there - it was never touched"
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
