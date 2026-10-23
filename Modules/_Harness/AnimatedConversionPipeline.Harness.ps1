<#
.SYNOPSIS
    Standalone test harness for Modules\AnimatedConversionPipeline.ps1.

.DESCRIPTION
    Scenario A: direct unit coverage of Test-AvifAnimated (a standalone
    exported function, not part of the dead Convert-AnimatedBatch that
    used to anchor a "PART 1"). Dot-sources the real module and stubs
    Write-Log/Remove-Source/$script:PermanentDelete so this module doesn't
    need Logging.ps1/FileDeletion.ps1 built/working to be tested.

    Every other scenario (B onward, 2026-09-14: originally split into a
    lightweight "PART 1" against the now-deleted Convert-AnimatedBatch and
    an integration-style "PART 2" against the live
    Invoke-LooseAnimatedConversionPipeline - collapsed into one style once
    PART 1's direct-call scenarios were ported to the live pipeline, see
    Todo.md's matching entry) dot-sources the REAL
    AbortPipeline.ps1/LeafDirectoryDiscovery.ps1/CleanConsoleRendering.ps1/
    ChapterDispatch.ps1 too, since Invoke-LooseAnimatedConversionPipeline
    is an orchestration-tier function whose real value is in proving the
    two-tier walk/coverage-completeness/CCR wiring actually work against
    real directory trees, not in mocking that machinery away.
    Write-Log/Remove-Source stay the lightweight local stubs declared once
    at the top of this file - AbortPipeline.ps1 and LeafDirectoryDiscovery.ps1
    both only need Write-Log stubbed (verified against each module's own
    FORWARD REFERENCE header text), not the real Logging.ps1/FileDeletion.ps1
    modules. A compiled fake magick.exe (same technique as
    ImageConversionPipeline.Harness.ps1's own fake cjxl.exe) handles both
    "identify -format %n <path>" (animation-frame-count detection) and the
    real conversion call, so real OS processes actually run end to end -
    the fake's conversion branch writes the exact argument string it
    received into the output file so a scenario can assert which flags
    (lossless vs quality) were actually passed.

.EXAMPLE
    .\Modules\_Harness\AnimatedConversionPipeline.Harness.ps1
#>

$ErrorActionPreference = "Stop"

$modulesDirAC = Join-Path $PSScriptRoot ".."
$script:logCalls = New-Object System.Collections.Generic.List[string]
function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $script:logCalls.Add($Level + ": " + $Message)
}
. (Join-Path $modulesDirAC "AbortPipeline.ps1")
. (Join-Path $modulesDirAC "LeafDirectoryDiscovery.ps1")
. (Join-Path $modulesDirAC "CleanConsoleRendering.ps1")
# ChapterDispatch.ps1 (2026-09-09) - Invoke-LooseAnimatedConversionPipeline's
# own real dependency now, PART 2's migration onto it. Dot-sourced before
# AnimatedConversionPipeline.ps1 itself, matching Conversion Script Main.ps1's
# own intended load order once this module is wired in for real.
. (Join-Path $modulesDirAC "ChapterDispatch.ps1")
. (Join-Path $modulesDirAC "AnimatedConversionPipeline.ps1")

$script:removeSourceCalls = New-Object System.Collections.Generic.List[string]
$script:PermanentDelete = $true
# Real ones live in FileDeletion.ps1/Logging.ps1 (not dot-sourced here).
function Get-WorkerRunspaceValue { param($Name) if ($Name -eq 'PermanentDelete') { return [bool]$script:PermanentDelete }; return ,$script:workerConsoleQueue }
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
#   - "identify -ping -format "%T" <path>[0]": reads FRAMES:<n> from the
#     real fixture (the trailing "[0]" frame-selector is stripped first
#     to find it) and writes back a simulated animation delay - "0" for
#     FRAMES:1 (static), nonzero for FRAMES:N>1 (animated), written
#     exactly once (2026-09-09: Test-AvifAnimated now addresses frame [0]
#     only, so the format string is never repeated per-frame the way the
#     old no-index "%n" call was). Also writes the raw args it received
#     to "<path>.identify-args.txt" so a scenario can assert the real
#     -ping/%T/[0] shape actually reached the process, not just that
#     classification came out correct. FAIL_IDENTIFY -> exit 1.
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
            string rawPath = args[args.Length - 1];
            string path = Regex.Replace(rawPath, "\\[\\d+\\]$", "");
            try { File.WriteAllText(path + ".identify-args.txt", string.Join(" ", args)); } catch { }
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
            int delay = frames > 1 ? 1000 : 0;
            Console.Write(delay.ToString() + "\n");
            return 0;
        }

        string src = args[0];
        string dst = args[args.Length - 1];
        string srcContent = File.Exists(src) ? File.ReadAllText(src) : "";

        if (srcContent.Contains("STDERR_FLOOD")) {
            // 2026-09-08 addition, same technique as the "identify" branch's
            // own FAIL_IDENTIFY_HUGE_STDERR above and ImageConversionPipeline's
            // fake cjxl.exe - simulates a magick conversion (not identify)
            // that emits more than the OS pipe buffer of stderr before
            // exiting, proving Convert-AnimatedBatch's async dispatch
            // (polled via HasExited rather than read synchronously inline)
            // doesn't deadlock on it.
            string floodLine = new string('E', 200) + Environment.NewLine;
            for (int i = 0; i < 2000; i++) { Console.Error.Write(floodLine); }
        }
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
        Match pm = Regex.Match(srcContent, "PARTIAL_THEN_SLEEP:(\\d+)");
        if (pm.Success) {
            // Simulates a real magick that has already flushed a partial
            // output file mid-encode and is still genuinely running - lets
            // a test force-kill it while a partial .webp is already on
            // disk, proving the outer dispatch-loop catch cleans up
            // $j.MagickOutputPath for a genuinely-still-running job (not
            // just the ordinary force-kill drain path, which already had
            // this coverage).
            File.WriteAllText(dst, "partial-in-flight-bytes");
            Thread.Sleep(int.Parse(pm.Groups[1].Value));
            return 0;
        }
        if (srcContent.Contains("STDOUT_MARKER")) {
            // Real magick writes progress info to stdout - normally empty
            // here, so Complete-AnimatedConversionJob's own "magick stdout
            // for" Write-Log call (gated on -DoFullLogging) never fires.
            // This marker lets a test force that specific, UNGUARDED
            // Write-Log call to actually run (and, for that test, throw).
            Console.WriteLine("simulated magick progress output");
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

# 2026-09-09 perf fix verification: proves the REAL command shape reached
# the process (-ping, %T format, trailing "[0]" frame selector), not just
# that classification came out correct - a regression back to the old
# "%n", no-index, no-ping call would still pass the two assertions above
# (the fake derives its answer from FRAMES:<n> either way) but would fail
# this one.
$argsFileA = $animA.FullName + ".identify-args.txt"
Test-Assert (Test-Path -LiteralPath $argsFileA) "identify call left a captured-args marker behind"
$capturedArgsA = Get-Content -LiteralPath $argsFileA -Raw
Test-Assert ($capturedArgsA -match '-ping') "the real identify call passes -ping (skip pixel decode)"
Test-Assert ($capturedArgsA -match '%T') "the real identify call reads %T (delay), not %n (frame count)"
Test-Assert ($capturedArgsA -match [regex]::Escape($animA.FullName + "[0]")) "the real identify call addresses frame [0] only, not the whole sequence"

# Bracket-in-filename safety (2026-09-09, live-verified against real
# scanlation-group-style names before this fix shipped): appending "[0]"
# must not misfire when the real filename/path already contains literal
# "["/"]" - ImageMagick only treats a TRAILING bracket construct as a
# frame selector, so an earlier bracket pair must be left alone.
$bracketA = New-FakeAvif -Name "[Scanlation Group] Series\Chapter [Special]\page[01].avif" -Content "FRAMES:9"
Test-Assert ((Test-AvifAnimated -AvifPath $bracketA.FullName -MagickExe $fakeMagickExe) -eq $true) "a real bracket-containing filename/path still classifies correctly"

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
#  Scenarios B through L2 (2026-09-14, dead-code-removal, Todo.md's
#  matching entry): ported from direct Convert-AnimatedBatch calls to the
#  live Invoke-LooseAnimatedConversionPipeline path - jobBuilder/
#  jobStarter/jobPollCompleted/Complete-AnimatedDispatchJob (PART 2's live
#  twins) have the identical logic these scenarios exercise, but nothing
#  previously proved most of it through the real pipeline. Scenario M
#  (empty-batch input) was dropped outright rather than ported - every
#  other scenario in this file already exercises a chapter with zero
#  qualifying animated files as a side effect of its own setup, so there's
#  no real gap to close by adding a scenario for it explicitly.
# ==============================================================================
Write-Host "=== Scenario B: end-to-end success ===" -ForegroundColor Cyan
$chB = New-Dir "scenario-b\Series\Chapter 1"
$fileB = Get-Item -LiteralPath (New-FakeAvifIn -DirPath $chB -Name "page1.avif" -Frames 8)
$totalsB = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-b") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false

Test-Assert ($totalsB.ConvertedSuccess -eq 1 -and $totalsB.ConvertedFail -eq 0) "1 converted, 0 failed"
Test-Assert ($totalsB.DeletedSuccess -eq 1) "source deleted (AnimatedDeleteSource defaults true)"
Test-Assert (-not (Test-Path -LiteralPath $fileB.FullName)) "source file is actually gone"
$webpB = [System.IO.Path]::ChangeExtension($fileB.FullName, ".webp")
Test-Assert (Test-Path -LiteralPath $webpB) "output .webp was created"
Write-Host ""

# ==============================================================================
#  Scenario B2 (2026-09-08 fix, real bug, live-reproduced): the magick
#  conversion job in the dispatch loop is polled via HasExited, not read
#  synchronously inline - both redirected streams must be drained as soon
#  as the process starts (not only once it's found HasExited), or a
#  magick that writes more than the OS pipe buffer to stderr before
#  exiting would block on that write forever, hanging the whole batch
#  with no error and no timeout - the exact species already fixed in
#  ImageConversionPipeline.ps1's cjxl dispatch, missed here.
#  Run on a background runspace with a bounded wait, NOT called directly -
#  a real regression here would hang forever, and this proves it fails the
#  assertion instead of hanging the whole harness process.
# ==============================================================================
Write-Host "=== Scenario B2: a magick job with a stderr flood does not deadlock the dispatch loop ===" -ForegroundColor Cyan
$chB2 = New-Dir "scenario-b2\Series\Chapter 1"
New-FakeAvifIn -DirPath $chB2 -Name "flood.avif" -Frames 5 | Out-Null
[System.IO.File]::AppendAllText((Join-Path $chB2 "flood.avif"), "`nSTDERR_FLOOD")

$runspaceB2 = [runspacefactory]::CreateRunspace()
$runspaceB2.Open()
$psB2 = [PowerShell]::Create()
$psB2.Runspace = $runspaceB2
$null = $psB2.AddScript({
    param($ModulesDir, $MagickExe, $LibraryPath)
    . (Join-Path $ModulesDir "AbortPipeline.ps1")
    . (Join-Path $ModulesDir "LeafDirectoryDiscovery.ps1")
    . (Join-Path $ModulesDir "CleanConsoleRendering.ps1")
    . (Join-Path $ModulesDir "ChapterDispatch.ps1")
    . (Join-Path $ModulesDir "AnimatedConversionPipeline.ps1")
    function Write-Log { param([string]$Message, [string]$Level = "Info") }
    function Remove-Source {
        param([string]$ItemPath)
        if (Test-Path -LiteralPath $ItemPath) { Remove-Item -LiteralPath $ItemPath -Force }
        return $true
    }
    $script:PermanentDelete = $true
    function Get-WorkerRunspaceValue { param($Name) if ($Name -eq 'PermanentDelete') { return [bool]$script:PermanentDelete }; return ,$script:workerConsoleQueue }
    Invoke-LooseAnimatedConversionPipeline -Path $LibraryPath -MagickExe $MagickExe -AnimatedThreads 2 -FullLogging $false
}).AddArgument($modulesDirAC).AddArgument($fakeMagickExe).AddArgument((Join-Path $scratchDir "scenario-b2"))

$handleB2 = $psB2.BeginInvoke()
$completedB2 = $handleB2.AsyncWaitHandle.WaitOne(15000)
if ($completedB2) {
    $totalsB2 = $psB2.EndInvoke($handleB2)[0]
} else {
    $psB2.Stop()
}
$psB2.Dispose()
$runspaceB2.Close()
$runspaceB2.Dispose()

Test-Assert $completedB2 "the pipeline returned within 15s instead of hanging on the stderr flood"
if ($completedB2) {
    Test-Assert ($totalsB2.ConvertedSuccess -eq 1) ("the file still converted successfully despite the stderr flood (got ConvertedSuccess=" + $totalsB2.ConvertedSuccess + ")")
}
Write-Host ""

# ==============================================================================
#  Scenario B3 (2026-09-08 fix, real bug caught by a full-codebase audit,
#  same species as this project's other Remove-Source call sites):
#  Remove-Source's $false return (the source already vanished before
#  deletion - a real TOCTOU gap) was discarded here, reporting a
#  successful delete regardless. Remove-Source shadowed to return $false
#  unconditionally.
# ==============================================================================
Write-Host "=== Scenario B3: an already-gone source is not miscounted as deleted ===" -ForegroundColor Cyan
$chB3 = New-Dir "scenario-b3\Series\Chapter 1"
New-FakeAvifIn -DirPath $chB3 -Name "page1.avif" -Frames 8 | Out-Null

$realRemoveSourceB3 = ${function:Remove-Source}
function Remove-Source {
    param([string]$ItemPath)
    return $false
}
try {
    $totalsB3 = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-b3") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false
} finally {
    ${function:Remove-Source} = $realRemoveSourceB3
}

Test-Assert ($totalsB3.ConvertedSuccess -eq 1) "sanity check: the conversion itself still succeeded"
Test-Assert ($totalsB3.DeletedSuccess -eq 0) ("DeletedSuccess stays 0, not falsely incremented, when Remove-Source reports the source already gone (got " + $totalsB3.DeletedSuccess + ")")
Write-Host ""

# ==============================================================================
#  Scenario C: static AVIF is left entirely untouched
# ==============================================================================
Write-Host "=== Scenario C: static AVIF left untouched ===" -ForegroundColor Cyan
$chC = New-Dir "scenario-c\Series\Chapter 1"
$fileC = Get-Item -LiteralPath (New-FakeAvifIn -DirPath $chC -Name "static.avif" -Frames 1)
$totalsC = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-c") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false

Test-Assert ($totalsC.StaticSkippedCount -eq 1 -and $totalsC.ConvertedSuccess -eq 0) "counted as StaticSkipped, not converted"
Test-Assert (Test-Path -LiteralPath $fileC.FullName) "the static source file was NOT deleted"
$webpC = [System.IO.Path]::ChangeExtension($fileC.FullName, ".webp")
Test-Assert (-not (Test-Path -LiteralPath $webpC)) "no .webp was ever created for a static AVIF"
Write-Host ""

# ==============================================================================
#  Scenario D: -AnimatedOverwrite $false skips a file whose output
#  already exists, without even inspecting it
# ==============================================================================
Write-Host "=== Scenario D: skip when output exists and Overwrite is off ===" -ForegroundColor Cyan
$chD = New-Dir "scenario-d\Series\Chapter 1"
$fileD = Get-Item -LiteralPath (New-FakeAvifIn -DirPath $chD -Name "page1.avif" -Frames 8)
$webpD = [System.IO.Path]::ChangeExtension($fileD.FullName, ".webp")
Set-Content -LiteralPath $webpD -Value "pre-existing webp" -Encoding UTF8 -NoNewline

$totalsD = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-d") -MagickExe $fakeMagickExe -AnimatedThreads 2 -AnimatedOverwrite $false -FullLogging $false

Test-Assert ($totalsD.ConvertedSkipped -eq 1 -and $totalsD.ConvertedSuccess -eq 0) "counted as Skipped, not converted"
Test-Assert ((Get-Content -LiteralPath $webpD -Raw) -eq "pre-existing webp") "the existing output was left untouched"
Test-Assert (Test-Path -LiteralPath $fileD.FullName) "the source file was NOT deleted (never dispatched)"
Write-Host ""

# ==============================================================================
#  Scenario E: -AnimatedOverwrite $true reconverts even when the
#  output already exists
# ==============================================================================
Write-Host "=== Scenario E: Overwrite `$true reconverts an existing output ===" -ForegroundColor Cyan
$chE = New-Dir "scenario-e\Series\Chapter 1"
$fileE = Get-Item -LiteralPath (New-FakeAvifIn -DirPath $chE -Name "page1.avif" -Frames 8)
$webpE = [System.IO.Path]::ChangeExtension($fileE.FullName, ".webp")
Set-Content -LiteralPath $webpE -Value "stale webp" -Encoding UTF8

$totalsE = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-e") -MagickExe $fakeMagickExe -AnimatedThreads 2 -AnimatedOverwrite $true -FullLogging $false

Test-Assert ($totalsE.ConvertedSuccess -eq 1) "reconverted despite the existing output"
Test-Assert ((Get-Content -LiteralPath $webpE -Raw) -ne "stale webp") "the output file's content actually changed"
Write-Host ""

# ==============================================================================
#  Scenario F: conversion failure - not deleted, no leftover partial webp
# ==============================================================================
Write-Host "=== Scenario F: conversion failure ===" -ForegroundColor Cyan
$chF = New-Dir "scenario-f\Series\Chapter 1"
$fileF = Get-Item -LiteralPath (New-FakeAvifIn -DirPath $chF -Name "page1.avif" -Frames 8 -Fail $true)
$totalsF = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-f") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false

Test-Assert ($totalsF.ConvertedFail -eq 1 -and $totalsF.ConvertedSuccess -eq 0) "counted as failed"
Test-Assert (Test-Path -LiteralPath $fileF.FullName) "the source was NOT deleted after a failure"
$webpF = [System.IO.Path]::ChangeExtension($fileF.FullName, ".webp")
Test-Assert (-not (Test-Path -LiteralPath $webpF)) "no leftover partial .webp"
Write-Host ""

# ==============================================================================
#  Scenario F2 (2026-08-31 fix): -AnimatedOverwrite $true points a
#  (now-failing) re-conversion at an already-existing, good .webp from a
#  prior successful run - the failure must NOT delete that pre-existing
#  file. Before the fix, the failure catch deleted $Job.WebpPath
#  unconditionally whenever it existed, destroying a previously-good
#  output over an unrelated later failure.
# ==============================================================================
Write-Host "=== Scenario F2: a failed re-conversion does NOT delete the pre-existing good .webp it was overwriting ===" -ForegroundColor Cyan
$chF2 = New-Dir "scenario-f2\Series\Chapter 1"
$fileF2 = Get-Item -LiteralPath (New-FakeAvifIn -DirPath $chF2 -Name "page1.avif" -Frames 8 -Fail $true)
$webpF2 = [System.IO.Path]::ChangeExtension($fileF2.FullName, ".webp")
"pre-existing good webp bytes from a prior successful run" | Set-Content -LiteralPath $webpF2 -Encoding UTF8 -NoNewline

$totalsF2 = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-f2") -MagickExe $fakeMagickExe -AnimatedThreads 2 -AnimatedOverwrite $true -FullLogging $false

Test-Assert ($totalsF2.ConvertedFail -eq 1 -and $totalsF2.ConvertedSuccess -eq 0) "counted as failed"
Test-Assert (Test-Path -LiteralPath $webpF2) "the pre-existing .webp still exists - NOT deleted by the failed re-conversion attempt"
Test-Assert ((Get-Content -LiteralPath $webpF2 -Raw) -eq "pre-existing good webp bytes from a prior successful run") "the pre-existing .webp's own content survives untouched"
Write-Host ""

# ==============================================================================
#  Scenario F3 (2026-08-31 fix): -AnimatedOverwrite $true points a
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
$chF3 = New-Dir "scenario-f3\Series\Chapter 1"
$fileF3 = Join-Path $chF3 "page1.avif"
[System.IO.File]::WriteAllText($fileF3, "FRAMES:8`nFAIL_MAGICK_AFTER_PARTIAL_WRITE")
$webpF3 = [System.IO.Path]::ChangeExtension($fileF3, ".webp")
"pre-existing good webp bytes from a prior successful run" | Set-Content -LiteralPath $webpF3 -Encoding UTF8 -NoNewline

$totalsF3 = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-f3") -MagickExe $fakeMagickExe -AnimatedThreads 2 -AnimatedOverwrite $true -FullLogging $false

Test-Assert ($totalsF3.ConvertedFail -eq 1 -and $totalsF3.ConvertedSuccess -eq 0) "counted as failed"
Test-Assert (Test-Path -LiteralPath $webpF3) "the pre-existing .webp still exists"
Test-Assert ((Get-Content -LiteralPath $webpF3 -Raw) -eq "pre-existing good webp bytes from a prior successful run") "the pre-existing .webp's own content survives BYTE-FOR-BYTE untouched - magick's crash-mid-write landed on a temp file, never the original"
$leftoverTempF3 = @(Get-ChildItem -LiteralPath $chF3 -Filter "*_tmp_overwrite.webp" -File -ErrorAction SilentlyContinue)
Test-Assert (@($leftoverTempF3).Count -eq 0) "the temp file magick actually wrote garbage to was cleaned up, not left behind"
Write-Host ""

# ==============================================================================
#  Scenario G: identify (inspection) failure - counted distinctly, no
#  conversion attempted, source untouched
# ==============================================================================
Write-Host "=== Scenario G: inspection failure ===" -ForegroundColor Cyan
$chG = New-Dir "scenario-g\Series\Chapter 1"
$fileG = Join-Path $chG "page1.avif"
[System.IO.File]::WriteAllText($fileG, "FAIL_IDENTIFY")
$totalsG = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-g") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false

Test-Assert ($totalsG.InspectFailedCount -eq 1 -and $totalsG.ConvertedSuccess -eq 0 -and $totalsG.ConvertedFail -eq 0) "counted distinctly as InspectFailed, not a conversion failure"
Test-Assert (Test-Path -LiteralPath $fileG) "the source was untouched"
Write-Host ""

# ==============================================================================
#  Scenario H: -AnimatedDeleteSource $false keeps the source after a
#  successful conversion
# ==============================================================================
Write-Host "=== Scenario H: AnimatedDeleteSource `$false keeps the source ===" -ForegroundColor Cyan
$chH = New-Dir "scenario-h\Series\Chapter 1"
$fileH = Get-Item -LiteralPath (New-FakeAvifIn -DirPath $chH -Name "page1.avif" -Frames 8)
$totalsH = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-h") -MagickExe $fakeMagickExe -AnimatedThreads 2 -AnimatedDeleteSource $false -FullLogging $false

Test-Assert ($totalsH.ConvertedSuccess -eq 1 -and $totalsH.DeletedSuccess -eq 0) "converted but not deleted"
Test-Assert (Test-Path -LiteralPath $fileH.FullName) "the source file is still there"
Write-Host ""

# ==============================================================================
#  Scenario I: -AnimatedLossless controls the actual magick args passed
# ==============================================================================
Write-Host "=== Scenario I: Lossless vs Quality args ===" -ForegroundColor Cyan
$chI1 = New-Dir "scenario-i-lossless\Series\Chapter 1"
$fileI1 = Get-Item -LiteralPath (New-FakeAvifIn -DirPath $chI1 -Name "lossless.avif" -Frames 8)
$null = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-i-lossless") -MagickExe $fakeMagickExe -AnimatedThreads 2 -AnimatedLossless $true -FullLogging $false
$argsI1 = Get-Content -LiteralPath ([System.IO.Path]::ChangeExtension($fileI1.FullName, ".webp")) -Raw
Test-Assert ($argsI1 -match "webp:lossless=true") "lossless mode passed the lossless define"

$chI2 = New-Dir "scenario-i-quality\Series\Chapter 1"
$fileI2 = Get-Item -LiteralPath (New-FakeAvifIn -DirPath $chI2 -Name "quality.avif" -Frames 8)
$null = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-i-quality") -MagickExe $fakeMagickExe -AnimatedThreads 2 -AnimatedLossless $false -AnimatedQuality 77 -FullLogging $false
$argsI2 = Get-Content -LiteralPath ([System.IO.Path]::ChangeExtension($fileI2.FullName, ".webp")) -Raw
Test-Assert ($argsI2 -match "-quality 77") "lossy mode passed the configured quality value"
Write-Host ""

# ==============================================================================
#  Scenario J: multiple files convert together (AnimatedThreads > 1)
# ==============================================================================
Write-Host "=== Scenario J: multiple files convert together ===" -ForegroundColor Cyan
$chJ = New-Dir "scenario-j\Series\Chapter 1"
1..4 | ForEach-Object { New-FakeAvifIn -DirPath $chJ -Name ("page" + $_ + ".avif") -Frames 6 | Out-Null }
$totalsJ = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-j") -MagickExe $fakeMagickExe -AnimatedThreads 4 -FullLogging $false
Test-Assert ($totalsJ.ConvertedSuccess -eq 4 -and $totalsJ.ConvertedFail -eq 0) ("all 4 converted (got " + $totalsJ.ConvertedSuccess + ")")
Write-Host ""

# ==============================================================================
#  Scenario K: heartbeat - a slow job logs a "still converting" line with
#  batch progress once it exceeds -HeartbeatIntervalSeconds
# ==============================================================================
Write-Host "=== Scenario K: heartbeat logging ===" -ForegroundColor Cyan
$chK = New-Dir "scenario-k\Series\Chapter 1"
$fileK = Join-Path $chK "slow.avif"
[System.IO.File]::WriteAllText($fileK, "FRAMES:6`nSLEEP_MS:1500")
$script:logCalls.Clear()
$totalsK = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-k") -MagickExe $fakeMagickExe -AnimatedThreads 1 -HeartbeatIntervalSeconds 1 -FullLogging $false
Test-Assert ($totalsK.ConvertedSuccess -eq 1) "the slow job still completed successfully"
$heartbeatLines = @($script:logCalls | Where-Object { $_ -like "*Still converting*" })
Test-Assert ($heartbeatLines.Count -ge 1) "at least one heartbeat line was logged for the slow job"
Test-Assert (($heartbeatLines -join "`n") -match "batch progress: \d+/1 done") "the heartbeat line includes batch-level progress"
Write-Host ""

# ==============================================================================
#  Scenario L: cancellation mid-batch - graceful drain lets an in-flight
#  job finish, force-kill triggers only past -AbortTimeoutSeconds. Uses
#  the same Test-AbortSignal call-count trigger as Scenario U further
#  down (a real still-sleeping fake magick process, cancelled via a
#  deterministic call count rather than a wall-clock race) - see that
#  scenario's own header for why call 4 lands once the job is genuinely
#  in flight.
# ==============================================================================
Write-Host "=== Scenario L: cancellation mid-batch (graceful drain) ===" -ForegroundColor Cyan
Reset-AbortState
$chL = New-Dir "scenario-l\Series\Chapter 1"
$fileL = Join-Path $chL "slow.avif"
[System.IO.File]::WriteAllText($fileL, "FRAMES:6`nSLEEP_MS:500")

$script:testAbortSignalTriggerAt = 4
$totalsL = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-l") -MagickExe $fakeMagickExe -AnimatedThreads 1 -FullLogging $false -AbortTimeoutSeconds 10
Reset-AbortState

Test-Assert ($totalsL.ConvertedSuccess -eq 1 -and $totalsL.ForceKilledCount -eq 0) "the in-flight job was allowed to finish naturally during the graceful drain, not force-killed"
Write-Host ""

# ==============================================================================
#  Scenario L2 (2026-08-31 fix): the force-kill path (past -AbortTimeoutSeconds,
#  NOT the graceful-drain-lets-it-finish path Scenario L covers) must not
#  delete a pre-existing good .webp it was overwriting. Before the fix,
#  this separate cleanup site deleted $j.WebpPath unconditionally whenever
#  it existed - the same bug Scenario F2 already covers, left open on this
#  different code path. SLEEP_MS deliberately exceeds -AbortTimeoutSeconds
#  so the job is still running when the drain gives up and force-kills it.
# ==============================================================================
Write-Host "=== Scenario L2: a force-killed job does NOT delete the pre-existing good .webp it was overwriting ===" -ForegroundColor Cyan
Reset-AbortState
$chL2 = New-Dir "scenario-l2\Series\Chapter 1"
$fileL2 = Join-Path $chL2 "slow.avif"
[System.IO.File]::WriteAllText($fileL2, "FRAMES:6`nSLEEP_MS:3000")
$webpL2 = [System.IO.Path]::ChangeExtension($fileL2, ".webp")
"pre-existing good webp bytes from a prior successful run" | Set-Content -LiteralPath $webpL2 -Encoding UTF8 -NoNewline

$script:testAbortSignalTriggerAt = 4
$totalsL2 = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-l2") -MagickExe $fakeMagickExe -AnimatedThreads 1 -AnimatedOverwrite $true -FullLogging $false -AbortTimeoutSeconds 1
Reset-AbortState

Test-Assert ($totalsL2.ForceKilledCount -eq 1) ("sanity check: the job was actually force-killed, not allowed to finish (got ForceKilledCount=" + $totalsL2.ForceKilledCount + ")")
Test-Assert (Test-Path -LiteralPath $webpL2) "the pre-existing .webp still exists - NOT deleted by the force-kill cleanup"
Test-Assert ((Get-Content -LiteralPath $webpL2 -Raw) -eq "pre-existing good webp bytes from a prior successful run") "the pre-existing .webp's own content survives untouched"
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
#  Scenario N2 (2026-09-09, mode 3's ChapterDispatch.ps1 migration): THE
#  actual point of the migration, tested directly - an idle concurrency
#  slot picks up the NEXT chapter's job while the CURRENT chapter still
#  has work outstanding, instead of blocking on one chapter's conversion
#  finishing before the next chapter's files are even dispatched. Chapter
#  1 gets a fast file + a slow file (fills both -AnimatedThreads slots);
#  Chapter 2 gets one fast file. The instant Chapter 1's fast file
#  finishes, Chapter 2's file must start - WHILE Chapter 1's slow file is
#  still converting, not after.
# ==============================================================================
Write-Host "=== Scenario N2: an idle slot picks up the NEXT chapter's job while the current chapter still has work outstanding ===" -ForegroundColor Cyan
$s1N2 = New-Dir "scenario-n2\Series\Chapter 1"
$s2N2 = New-Dir "scenario-n2\Series\Chapter 2"
[System.IO.File]::WriteAllText((Join-Path $s1N2 "fast.avif"), "FRAMES:5")
[System.IO.File]::WriteAllText((Join-Path $s1N2 "slow.avif"), "FRAMES:5`nSLEEP_MS:800")
[System.IO.File]::WriteAllText((Join-Path $s2N2 "fast.avif"), "FRAMES:5")

$script:logCalls.Clear()
$totalsN2 = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-n2") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false

$idxChapter2Start = ($script:logCalls | Select-String -Pattern "Converting animated.*Chapter 2.*fast\.avif").LineNumber
$idxChapter1SlowDone = ($script:logCalls | Select-String -Pattern "Conversion OK.*Chapter 1.*slow\.webp").LineNumber
Test-Assert ($totalsN2.ConvertedSuccess -eq 3 -and $totalsN2.ConvertedFail -eq 0) ("sanity check: all 3 files converted (got ConvertedSuccess=" + $totalsN2.ConvertedSuccess + ")")
Test-Assert ($null -ne $idxChapter2Start -and $null -ne $idxChapter1SlowDone -and $idxChapter2Start -lt $idxChapter1SlowDone) ("Chapter 2's file started converting BEFORE Chapter 1's slow file finished - real interleaving, not one-chapter-at-a-time (Chapter 2 start at log line " + $idxChapter2Start + ", Chapter 1 slow-file finish at log line " + $idxChapter1SlowDone + ")")
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

# 2026-09-08 fix, real bug caught by a full-codebase review - same fix as
# ImageConversionPipeline.ps1/Controller.ps1 already got 2026-09-03: the
# empty-chapters check used to run AFTER Start-SeriesProgress, so a series
# with nothing to convert still registered a 0/0-chapter entry with CCR,
# printing a frozen "0/0 chapters" line. Start-SeriesProgress shadowed to
# prove it's never called for an empty series with Clean Console Output on.
$script:startSeriesProgressCallsP = 0
$realStartSeriesProgressP = ${function:Start-SeriesProgress}
function Start-SeriesProgress {
    param([string]$SeriesName, [int]$TotalChapters)
    $script:startSeriesProgressCallsP++
    & $script:realStartSeriesProgressPRef -SeriesName $SeriesName -TotalChapters $TotalChapters
}
$script:realStartSeriesProgressPRef = $realStartSeriesProgressP
$script:CleanConsoleOutputEnabled = $true
try {
    $totalsP2 = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-p") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false
} finally {
    $script:CleanConsoleOutputEnabled = $false
    ${function:Start-SeriesProgress} = $realStartSeriesProgressP
}
Test-Assert ($script:startSeriesProgressCallsP -eq 0) ("Start-SeriesProgress was never called for the empty series - no 0/0-chapter CCR entry registered (got " + $script:startSeriesProgressCallsP + " call(s))")
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
#  Scenarios X/Z/AA/AB (2026-09-14, dead-code-removal, Todo.md's matching
#  entry) removed outright rather than ported: X/AA/AB proved generic
#  dispatch-loop mechanics (stale-list SlotReleased guard, straggler-drain
#  throw cleanup, IsCloseEvent force-kill) that now live in the SHARED
#  Invoke-ChapterDispatch, not this module - that coverage now lives in
#  ChapterDispatch.Harness.ps1's Scenarios 11/13/12. Z proved a bug shape
#  specific to Complete-AnimatedConversionJob's own internal structure (it
#  set SlotReleased in its OWN try/finally, before its success/failure
#  logic could throw) - the live twin, Complete-AnimatedDispatchJob, has
#  no such internal try/finally; SlotReleased is now set by
#  Invoke-ChapterDispatch itself, only after JobFinalize returns without
#  throwing, so the specific "already-SlotReleased-but-still-orphaned-temp-
#  file" condition Z exercised can no longer occur - nothing to port.
#
#  Scenario Y ported to the live pipeline below, analogous to
#  ImageConversionPipeline.Harness.ps1's own ported Scenario AG: what's
#  still THIS pipeline's own responsibility, and wasn't otherwise proven
#  through the real pipeline, is that its own -JobAbortCleanup closure
#  actually deletes a force-killed job's partial output - proven here as a
#  real end-to-end abort/force-kill using the same Test-AbortSignal
#  call-count trigger as Scenario L above and Scenario U below.
# ==============================================================================
Write-Host "=== Scenario Y: a force-killed job's partial output is cleaned up by the pipeline's own JobAbortCleanup ===" -ForegroundColor Cyan
Reset-AbortState
$chY = New-Dir "scenario-y\Series\Chapter 1"
$fileY = Join-Path $chY "stillrunning_y.avif"
[System.IO.File]::WriteAllText($fileY, "FRAMES:5`nPARTIAL_THEN_SLEEP:5000")
$expectedWebpY = Join-Path $chY "stillrunning_y.webp"

# Re-install the call-count spy (Scenario U's own teardown, above, already
# restored the real Test-AbortSignal) - same idiom as
# ImageConversionPipeline.Harness.ps1's ported Scenario AG.
function Test-AbortSignal {
    $script:testAbortSignalCallCount++
    if ($script:testAbortSignalCallCount -eq $script:testAbortSignalTriggerAt) {
        [ConsoleCtrl]::AbortRequested = $true
    }
    & $originalTestAbortSignal
}
$script:testAbortSignalTriggerAt = 4

$totalsY = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-y") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false -AbortTimeoutSeconds 1

${function:Test-AbortSignal} = $originalTestAbortSignal
Reset-AbortState

Test-Assert ($totalsY.Aborted) "sanity check: the run was actually aborted"
Test-Assert ($totalsY.ForceKilledCount -eq 1) ("sanity check: the still-running job was actually force-killed, not drained gracefully (got ForceKilledCount=" + $totalsY.ForceKilledCount + ")")
Test-Assert (-not (Test-Path -LiteralPath $expectedWebpY)) "the partial output left by the force-killed job was deleted, not left as debris"
Write-Host ""

# ==============================================================================
#  Summary
# ==============================================================================
#  Scenario AM: an abort raised mid-jobBuilder stops per-file AVIF
#  classification - no further magick identify spawns for the rest of the
#  chapter. The fake magick.exe leaves a <path>.identify-args.txt marker
#  per identify call; Test-AbortSignal flips the abort as soon as the
#  first marker exists, so exactly 1 of the 3 AVIFs gets classified.
# ==============================================================================
Write-Host "=== Scenario AM: abort mid-chapter stops per-file AVIF identify spawns ===" -ForegroundColor Cyan
Reset-AbortState
$chAM = New-Dir "scenario-am\Series\Chapter 1"
foreach ($n in 1..3) { $null = New-FakeAvifIn -DirPath $chAM -Name ("p" + $n + ".avif") -Frames 8 }
function Test-AbortSignal {
    if (@([System.IO.Directory]::GetFiles($chAM, "*.identify-args.txt")).Count -ge 1) {
        [ConsoleCtrl]::AbortRequested = $true
    }
    & $originalTestAbortSignal
}
try {
    $totalsAM = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-am") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false -AbortTimeoutSeconds 1
} finally {
    ${function:Test-AbortSignal} = $originalTestAbortSignal
    Reset-AbortState
}
$identifyCountAM = @([System.IO.Directory]::GetFiles($chAM, "*.identify-args.txt")).Count
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
$null = New-FakeAvifIn -DirPath $chQD1 -Name "page1.avif" -Frames 8
$null = New-FakeAvifIn -DirPath $chQD2 -Name "page1.avif" -Frames 8
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
    $totalsQD = Invoke-LooseAnimatedConversionPipeline -Path $rootQD -MagickExe $fakeMagickExe -AnimatedThreads 1 -FullLogging $false
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
#  Scenario AN (2026-10-12): Complete-AnimatedDispatchJob's read of the finished
#  process's stdout/stderr is bounded and tolerates a failed read. It used to
#  be a bare GetAwaiter().GetResult(): a pipe held open (a delegate process
#  magick spawned) stalled the engine forever, and a faulted read threw out
#  of JobFinalize. Success is still judged by exit code and output file.
#  DOCUMENTED DUPLICATE of ImageConversionPipeline.Harness.ps1's own Scenario AN -
#  keep both in sync.
# ==============================================================================
#  Scenario AO: with an abort already in progress, the chapter provider
#  doesn't walk into any series (same as Image Conversion's provider).
# ==============================================================================
Write-Host "=== Scenario AO: abort in progress -> no series walked ===" -ForegroundColor Cyan
foreach ($seriesAO in @("Series One", "Series Two")) {
    $chAO = New-Dir ("scenario-ao\" + $seriesAO + "\Chapter 1")
    New-FakeAvifIn -DirPath $chAO -Name "anim.avif" | Out-Null
}
[ConsoleCtrl]::AbortRequested = $true
try {
    $totalsAO = Invoke-LooseAnimatedConversionPipeline -Path (Join-Path $scratchDir "scenario-ao") -MagickExe $fakeMagickExe -AnimatedThreads 2 -FullLogging $false
} finally {
    Reset-AbortState
}
Test-Assert ($totalsAO.SeriesCount -eq 0 -and $totalsAO.ConvertedSuccess -eq 0) ("no series is walked once an abort is in progress (got SeriesCount=" + $totalsAO.SeriesCount + ")")
Test-Assert ($totalsAO.Aborted -eq $true) "the run reports itself as aborted"
Write-Host ""

# ==============================================================================
Write-Host "=== Scenario AN: a stuck or failed output-stream read does not stall or crash job finalize ===" -ForegroundColor Cyan
$dirAN = New-Dir "scenario-an"
function New-StreamJobAN {
    param([string]$Name, $StdoutTask, $StderrTask)
    $srcAN = Join-Path $dirAN ($Name + ".src")
    $outAN = Join-Path $dirAN ($Name + ".out")
    [System.IO.File]::WriteAllText($srcAN, "source")
    [System.IO.File]::WriteAllText($outAN, "converted")
    return @{ SrcPath = $srcAN; WebpPath = $outAN; MagickOutputPath = $outAN; Proc = [pscustomobject]@{ ExitCode = 0 }; StdoutTask = $StdoutTask; StderrTask = $StderrTask; ChapterKey = "an" }
}
$doneAN = [System.Threading.Tasks.TaskCompletionSource[string]]::new(); $doneAN.SetResult("")
$neverAN = [System.Threading.Tasks.TaskCompletionSource[string]]::new()
$faultAN = [System.Threading.Tasks.TaskCompletionSource[string]]::new(); $faultAN.SetException([System.IO.IOException]::new("simulated broken pipe"))

$crAN = @{ ConvertedCount = 0; FailedCount = 0; DeletedCount = 0; DeleteFailedCount = 0 }
$swAN = [System.Diagnostics.Stopwatch]::StartNew()
$outputAN = @(& { Complete-AnimatedDispatchJob -Job (New-StreamJobAN -Name "stuck" -StdoutTask $neverAN.Task -StderrTask $doneAN.Task) -ChapterResult $crAN -DoFullLogging $false -DoAnimatedDeleteSource $true -StreamReadTimeoutMs 300 } 6>&1)
$swAN.Stop()
$resultAN = @($outputAN | Where-Object { $_ -is [hashtable] })
Test-Assert ($swAN.Elapsed.TotalSeconds -lt 5) ("a stream that never finishes reading is given up on after the timeout (took " + [math]::Round($swAN.Elapsed.TotalSeconds, 2) + "s)")
Test-Assert ($resultAN.Count -eq 1 -and $resultAN[0].Success -eq $true -and $crAN.ConvertedCount -eq 1) "the conversion still counts as a success - exit code 0 and a real output file"
Test-Assert (@($script:logCalls | Where-Object { $_ -like "Warn: *did not finish reading within*" }).Count -eq 1) "the timed-out read is logged as a warning"

$crAN2 = @{ ConvertedCount = 0; FailedCount = 0; DeletedCount = 0; DeleteFailedCount = 0 }
$threwAN2 = $false
$outputAN2 = @()
try {
    $outputAN2 = @(& { Complete-AnimatedDispatchJob -Job (New-StreamJobAN -Name "faulted" -StdoutTask $doneAN.Task -StderrTask $faultAN.Task) -ChapterResult $crAN2 -DoFullLogging $false -DoAnimatedDeleteSource $true -StreamReadTimeoutMs 300 } 6>&1)
} catch {
    $threwAN2 = $true
}
$resultAN2 = @($outputAN2 | Where-Object { $_ -is [hashtable] })
Test-Assert (-not $threwAN2) "a faulted stream read does not throw out of job finalize"
Test-Assert ($resultAN2.Count -eq 1 -and $resultAN2[0].Success -eq $true -and $crAN2.ConvertedCount -eq 1) "and the conversion is still judged by exit code and output file"
Test-Assert (@($script:logCalls | Where-Object { $_ -like "Warn: *simulated broken pipe*" }).Count -eq 1) "the failed read is logged as a warning with its cause"
Write-Host ""

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
