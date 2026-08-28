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
    param([string]$DirPath, [string]$Name, [bool]$Fail = $false, [int]$SleepMs = 0)
    $path = Join-Path $DirPath $Name
    $content = if ($Fail) { "FAIL_CJXL" } elseif ($SleepMs -gt 0) { "SLEEP_MS:" + $SleepMs } else { "fake source pixels" }
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
        string content = File.Exists(src) ? File.ReadAllText(src) : "";
        if (content.Contains("FAIL_CJXL")) {
            Console.Error.WriteLine("simulated cjxl failure");
            return 1;
        }
        Match m = Regex.Match(content, "SLEEP_MS:(\\d+)");
        if (m.Success) {
            Thread.Sleep(int.Parse(m.Groups[1].Value));
        }
        File.WriteAllText(dst, "fake-jxl-bytes");
        return 0;
    }
}
'@
$fakeCjxlExe = Join-Path $scratchDir "fake_cjxl.exe"
Add-Type -TypeDefinition $fakeCjxlSource -Language CSharp -OutputAssembly $fakeCjxlExe -OutputType ConsoleApplication

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
#  Scenario C: stale-source cleanup - a source with an existing non-zero .jxl
#  counterpart is deleted without ever being handed to cjxl, per-series.
# ==============================================================================
Write-Host "=== Scenario C: stale source cleanup ===" -ForegroundColor Cyan
$rootC = New-Dir "scenario-c"
$chC = New-Dir "scenario-c\Series\Chapter 1"
$staleSrcC = New-FakeImage -DirPath $chC -Name "already_done.jpg"
[System.IO.File]::WriteAllText((Join-Path $chC "already_done.jxl"), "real jxl bytes")

$totalsC = Invoke-LooseImageConversionPipeline -Path $rootC -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2 -FullLogging $false

Test-Assert ($totalsC.StaleCleanedSuccess -eq 1) ("1 stale source cleaned (got " + $totalsC.StaleCleanedSuccess + ")")
Test-Assert ($totalsC.ConvertedSuccess -eq 0) "nothing sent to cjxl for the stale source"
Test-Assert (-not (Test-Path -LiteralPath $staleSrcC)) "stale source deleted"

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
$budgetP.Dispose()
Write-Host ""
if ($script:failCount -eq 0) {
    Write-Host ("ALL PASSED  (" + $script:passCount + " assertions)") -ForegroundColor Green
    exit 0
} else {
    Write-Host ($script:failCount.ToString() + " FAILED, " + $script:passCount.ToString() + " passed") -ForegroundColor Red
    exit 1
}
