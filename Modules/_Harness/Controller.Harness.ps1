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
            Match m = Regex.Match(content, "SLEEP_MS:(\\d+)");
            if (m.Success) { Thread.Sleep(int.Parse(m.Groups[1].Value)); }
            File.WriteAllText(dst, "fake-jxl-bytes");
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
#  ~50ms in - the job still dispatches and completes normally (Cts wasn't
#  cancelled when it started, and a running process has no cancellation
#  check of its own), so -ResultHandler fires for real and the merged
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

$cancelRunspaceC4 = [runspacefactory]::CreateRunspace()
$cancelRunspaceC4.Open()
$cancelPsC4 = [PowerShell]::Create()
$cancelPsC4.Runspace = $cancelRunspaceC4
$null = $cancelPsC4.AddScript({ param($Cts) Start-Sleep -Milliseconds 50; $Cts.Cancel() }).AddArgument($ctsC4)
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
}

Write-Host "=== Scenario J: Invoke-Mode / ImageConversion - param translation + result mapping ===" -ForegroundColor Cyan
$capturedJ = @{}
$fakeImageHandlerJ = {
    param($Path, $CjxlExe, $MagickExe, $JpegLossless, $JpegQuality, $MaxCjxlProcs, $FullLogging)
    $capturedJ.Path = $Path; $capturedJ.CjxlExe = $CjxlExe; $capturedJ.MagickExe = $MagickExe
    $capturedJ.JpegQuality = $JpegQuality; $capturedJ.MaxCjxlProcs = $MaxCjxlProcs; $capturedJ.FullLogging = $FullLogging
    return @{ ConvertedSuccess = 3; ConvertedFail = 1; ConvertedSkipped = 2; DeletedSuccess = 3; DeletedFail = 0; StaleCleanedSuccess = 1; StaleCleanedFail = 0; InspectFailedCount = 2 }
}.GetNewClosure()
$statsJ = Invoke-Mode -Resolved @{ Mode = 'ImageConversion' } -TargetPath "C:\fake\lib" -Settings $fakeSettings -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ImageConversionHandler $fakeImageHandlerJ

Test-Assert ($capturedJ.Path -eq "C:\fake\lib" -and $capturedJ.CjxlExe -eq "fake_cjxl.exe" -and $capturedJ.JpegQuality -eq 77 -and $capturedJ.MaxCjxlProcs -eq 6) "ImageConversion: real Settings values reached the handler"
Test-Assert ($statsJ.LooseImgConverted.Success -eq 3 -and $statsJ.LooseImgConverted.Fail -eq 1 -and $statsJ.LooseImgConverted.Skipped -eq 2) "ImageConversion: LooseImgConverted mapped correctly"
Test-Assert ($statsJ.LooseImgDeleted.Success -eq 3 -and $statsJ.LooseStaleCleaned.Success -eq 1) "ImageConversion: LooseImgDeleted/LooseStaleCleaned mapped correctly"
Test-Assert ($statsJ.InspectFailed.Count -eq 2) "ImageConversion: InspectFailedCount mapped onto InspectFailed.Count"
Write-Host ""

Write-Host "=== Scenario K: Invoke-Mode / AnimatedConversion - param translation + result mapping ===" -ForegroundColor Cyan
$fakeAnimHandlerK = { param($Path, $MagickExe, $AnimatedLossless, $AnimatedQuality, $AnimatedThreads, $AnimatedOverwrite, $AnimatedDeleteSource, $FullLogging)
    return @{ ConvertedSuccess = 4; ConvertedFail = 0; ConvertedSkipped = 1; DeletedSuccess = 4; DeletedFail = 0; InspectFailedCount = 1 }
}
$statsK = Invoke-Mode -Resolved @{ Mode = 'AnimatedConversion' } -TargetPath "C:\fake\lib" -Settings $fakeSettings -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -AnimatedConversionHandler $fakeAnimHandlerK
Test-Assert ($statsK.LooseAnimatedConverted.Success -eq 4 -and $statsK.LooseAnimatedConverted.Skipped -eq 1) "AnimatedConversion: LooseAnimatedConverted mapped correctly"
Test-Assert ($statsK.LooseAnimatedDeleted.Success -eq 4) "AnimatedConversion: LooseAnimatedDeleted mapped correctly"
Test-Assert ($statsK.InspectFailed.Count -eq 1) "AnimatedConversion: InspectFailedCount mapped onto InspectFailed.Count"
Write-Host ""

Write-Host "=== Scenario L: Invoke-Mode / ZipFolders - result mapping ===" -ForegroundColor Cyan
$fakeZipHandlerL = { param($Path, $MaxParallel, $DeleteFolders, $FullLogging, $LogFile, $LogErrorFile, $LogWarnFile, $PermanentDelete)
    return @{ CandidateCount = 5; ZippedSuccess = 4; ZippedFail = 1; FolderDeletedSuccess = 4; FolderDeletedFail = 0; ForceStoppedCount = 0 }
}
$statsL = Invoke-Mode -Resolved @{ Mode = 'ZipFolders' } -TargetPath "C:\fake\lib" -Settings $fakeSettings -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ZipFoldersHandler $fakeZipHandlerL
Test-Assert ($statsL.ZipOnlyZipped.Success -eq 4 -and $statsL.ZipOnlyZipped.Fail -eq 1) "ZipFolders: ZipOnlyZipped mapped correctly"
Test-Assert ($statsL.ZipOnlyFolderDeleted.Success -eq 4) "ZipFolders: ZipOnlyFolderDeleted mapped correctly"
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
$fakeFullHandlerN = { param($Path, $CjxlExe, $MagickExe, $JpegLossless, $JpegQuality, $AnimatedLossless, $AnimatedQuality, $AnimatedOverwrite, $AnimatedDeleteSource, $FullPipelineMaxConcurrentProcs, $FullLogging, $LogFile, $LogErrorFile, $LogWarnFile, $PermanentDelete)
    return @{
        ConvertedImageSuccess = 5; ConvertedImageFail = 0; ConvertedImageSkipped = 0; DeletedImageSuccess = 5; DeletedImageFail = 0
        StaleImageCleanedSuccess = 0; StaleImageCleanedFail = 0
        ConvertedAnimatedSuccess = 2; ConvertedAnimatedFail = 0; ConvertedAnimatedSkipped = 0; DeletedAnimatedSuccess = 2; DeletedAnimatedFail = 0
        ZipCreatedSuccess = 3; ZipCreatedFail = 0; ZipSkippedDueToError = 0; FolderDeletedSuccess = 3; FolderDeletedFail = 0
        ForceKilledCount = 0; InspectFailedCount = 4; SeriesCount = 1; ChapterCount = 3; Aborted = $false
    }
}
$statsN = Invoke-Mode -Resolved @{ Mode = 'FullPipeline' } -TargetPath "C:\fake\lib" -Settings $fakeSettings -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -FullPipelineHandler $fakeFullHandlerN
Test-Assert ($statsN.LooseImgConverted.Success -eq 5 -and $statsN.LooseAnimatedConverted.Success -eq 2 -and $statsN.LooseFolderZipped.Success -eq 3) "FullPipeline: image + animated + zip stat groups all mapped in one call"
Test-Assert ($statsN.InspectFailed.Count -eq 4) "FullPipeline: InspectFailedCount (both engines summed by Controller.ps1) mapped onto InspectFailed.Count"
Write-Host ""

Write-Host "=== Scenario O: Invoke-Mode / ImageConversionZip (mode 8) - real zip-step wiring, 2026-08-28 ===" -ForegroundColor Cyan
# This fake -ImageConversionHandler simulates what the real
# Invoke-LooseImageConversionPipeline does: actually invokes the
# -ZipStepCallback it was given, so this scenario proves the CALLBACK's
# own logic (extension selection, Status/Detail mapping) - not just that
# a callback object gets constructed and never used.
$zipHandlerCallsO = [System.Collections.Generic.List[hashtable]]::new()
$fakeZipFolderHandlerO = {
    param($FolderPath, $ZipOut, $LooseImageExtensions)
    $zipHandlerCallsO.Add(@{ FolderPath = $FolderPath; ZipOut = $ZipOut; LooseImageExtensions = $LooseImageExtensions })
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
    $zipOutcome = & $ZipStepCallback @{ Dir = (Get-Item -LiteralPath $Path); ZipOut = (Join-Path $Path "Chapter.zip") }
    $zipOutcomeBoxO.Value = $zipOutcome
    return @{ ConvertedSuccess = 1; ConvertedFail = 0; ConvertedSkipped = 0; DeletedSuccess = 1; DeletedFail = 0; StaleCleanedSuccess = 0; StaleCleanedFail = 0; InspectFailedCount = 0 }
}.GetNewClosure()

$fakeSettingsO = $fakeSettings.Clone()
$fakeSettingsO.ZipWithUnconvertedAnimated = $false
$statsO = Invoke-Mode -Resolved @{ Mode = 'ImageConversionZip' } -TargetPath $scratchDir -Settings $fakeSettingsO -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ImageConversionHandler $fakeImageHandlerO -ZipFolderHandler $fakeZipFolderHandlerO

Test-Assert ($statsO.LooseImgConverted.Success -eq 1) "ImageConversionZip: image conversion still ran and mapped correctly"
Test-Assert ($zipHandlerCallsO.Count -eq 1) ("the zip-folder handler fired exactly once (got " + $zipHandlerCallsO.Count + ")")
Test-Assert ($zipHandlerCallsO[0].LooseImageExtensions -contains ".avif") "ZipWithUnconvertedAnimated=false (default): .avif is in the blocking extension list"
Test-Assert ($zipOutcomeBoxO.Value.Status -eq "Success" -and $zipOutcomeBoxO.Value.Detail -eq "4 entries") "the callback mapped the zip result into @{ Status; Detail } correctly"
Test-Assert ($statsO.LooseFolderZipped.Success -eq 1 -and $statsO.LooseFolderZipped.Fail -eq 0 -and $statsO.LooseFolderZipped.Skipped -eq 0) ("mode 8's zip outcome IS reflected in LooseFolderZipped now (2026-08-28 fix) - got Success=" + $statsO.LooseFolderZipped.Success)
Test-Assert ($statsO.LooseFolderDeleted.Success -eq 1 -and $statsO.LooseFolderDeleted.Fail -eq 0) "mode 8's folder-deletion outcome IS reflected in LooseFolderDeleted now"

# Flip the setting: .avif should be EXCLUDED from the blocking list, so an
# unconverted .avif sitting in the folder no longer blocks zipping.
$zipHandlerCallsO.Clear()
$fakeSettingsO2 = $fakeSettings.Clone()
$fakeSettingsO2.ZipWithUnconvertedAnimated = $true
$null = Invoke-Mode -Resolved @{ Mode = 'ImageConversionZip' } -TargetPath $scratchDir -Settings $fakeSettingsO2 -CjxlExe "fake_cjxl.exe" -MagickExe "fake_magick.exe" -ImageConversionHandler $fakeImageHandlerO -ZipFolderHandler $fakeZipFolderHandlerO
Test-Assert ($zipHandlerCallsO[0].LooseImageExtensions -notcontains ".avif") "ZipWithUnconvertedAnimated=true: .avif is EXCLUDED from the blocking extension list"
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
