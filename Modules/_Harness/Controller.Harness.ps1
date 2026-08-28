<#
.SYNOPSIS
    Standalone test harness for Modules\Controller.ps1.

.DESCRIPTION
    Integration-style, like ZipPipeline.Harness.ps1/RezipPipeline.Harness.ps1/
    ImageConversionPipeline.Harness.ps1 - dot-sources the REAL Logging.ps1/
    FileDeletion.ps1/ZipCreation.ps1/ZipValidation.ps1/LeafDirectoryDiscovery.ps1/
    AbortPipeline.ps1/CleanConsoleRendering.ps1/ZipParallelProcessing.ps1/
    ImageConversionPipeline.ps1/AnimatedConversionPipeline.ps1 (NOT
    ZipPipeline.ps1 - Controller.ps1 calls Compress-FolderToZip/
    Test-ZipArchive directly, not Invoke-LooseFolderZip, see
    Controller.ps1's own header for why),
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

function Reset-AbortState {
    [ConsoleCtrl]::AbortRequested = $false
    [ConsoleCtrl]::IsCloseEvent   = $false
    [ConsoleCtrl]::DrainComplete.Reset()
    $script:abortRequested = $false
    $script:ctrlCloseAbort = $false
    $script:abortCancellationSources.Clear()
    $script:CleanConsoleOutputEnabled = $false
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
