<#
.SYNOPSIS
    Standalone test harness for Modules\RezipPipeline.ps1.

.DESCRIPTION
    Integration-style, like ZipPipeline.Harness.ps1 - dot-sources the real
    already-built dependency modules (FileDeletion, ZipCreation,
    ZipValidation, ImageConversionPipeline, ResumeState, AbortPipeline,
    Logging, ZipParallelProcessing) rather than stubbing them, since
    RezipPipeline.ps1 is an orchestration-tier module that composes all of
    them for real. A compiled fake_cjxl.exe (same technique as
    ImageConversionPipeline.Harness.ps1) stands in for the real cjxl.exe
    so real OS processes actually run end to end.

    DOT-SOURCE ORDER: Logging.ps1/AbortPipeline.ps1 BEFORE
    ZipParallelProcessing.ps1 - same rule ZipPipeline.Harness.ps1
    documents (ZPP forward-references them; the wrong order would leave
    Write-Log/Test-AbortSignal/Invoke-GracefulDrain undefined).

.EXAMPLE
    .\Modules\_Harness\RezipPipeline.Harness.ps1
#>

$ErrorActionPreference = "Stop"

$modulesDir = Join-Path $PSScriptRoot ".."
. (Join-Path $modulesDir "FileDeletion.ps1")
. (Join-Path $modulesDir "ZipCreation.ps1")
. (Join-Path $modulesDir "ZipValidation.ps1")
. (Join-Path $modulesDir "ImageConversionPipeline.ps1")
. (Join-Path $modulesDir "ResumeState.ps1")
. (Join-Path $modulesDir "AbortPipeline.ps1")
. (Join-Path $modulesDir "Logging.ps1")
. (Join-Path $modulesDir "ZipParallelProcessing.ps1")   # AFTER AbortPipeline.ps1/Logging.ps1 - see header note
. (Join-Path $modulesDir "RezipPipeline.ps1")

Add-Type -AssemblyName "System.IO.Compression.FileSystem"

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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("rezippipeline-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray

Initialize-FileDeletion -PermanentDelete $true   # scratch content - keeps the real Recycle Bin clean across this harness's many runs
Initialize-LogPaths -TargetPath $scratchDir -FullLogging $false -ScriptDir $scratchDir

function New-Dir {
    param([string]$RelativePath)
    $path = Join-Path $scratchDir $RelativePath
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function New-SourceZip {
    <#
    .SYNOPSIS
        Builds a real ZIP at $ZipPath from a hashtable of relative-name ->
        text-content entries (an empty hashtable makes an empty ZIP).
    #>
    param([string]$ZipPath, [hashtable]$Files = @{})

    $tempDir = Join-Path $scratchDir ("ziptmp-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    foreach ($name in $Files.Keys) {
        $filePath = Join-Path $tempDir $name
        $parent = Split-Path -Path $filePath -Parent
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Set-Content -LiteralPath $filePath -Value $Files[$name] -Encoding UTF8 -NoNewline
    }

    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $ZipPath)
    Remove-Item -LiteralPath $tempDir -Recurse -Force
    return $ZipPath
}

# ------------------------------------------------------------------
#  Fake cjxl.exe - identical technique to ImageConversionPipeline.Harness.ps1:
#  content containing "FAIL_CJXL" -> exit 1, anything else -> write
#  non-zero-byte output and exit 0.
# ------------------------------------------------------------------
$fakeCjxlSource = @'
using System;
using System.IO;
class Program {
    static int Main(string[] args) {
        string src = args[0];
        string dst = args[1];
        string content = File.Exists(src) ? File.ReadAllText(src) : "";
        if (content.Contains("FAIL_CJXL")) {
            Console.Error.WriteLine("simulated cjxl failure");
            return 1;
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
#  Scenario A: Get-RezipCandidateZips - finds real ZIPs at various depths,
#  excludes one sitting inside another ZIP's own staging folder
# ==============================================================================
Write-Host "=== Scenario A: Get-RezipCandidateZips ===" -ForegroundColor Cyan
$rootA = New-Dir "scenario-a"
New-SourceZip -ZipPath (Join-Path $rootA "Top.zip") -Files @{ "page1.jpg" = "x" } | Out-Null
$nestedDirA = New-Dir "scenario-a\Nested"
New-SourceZip -ZipPath (Join-Path $nestedDirA "Inner.zip") -Files @{ "page1.jpg" = "x" } | Out-Null

# A staging-dir case: "Staged.zip" at the root, plus a folder "Staged"
# (sibling of that zip) containing its own "Leftover.zip" - Leftover.zip
# should be excluded since it lives inside a folder that shares its name
# with a sibling ZIP (exactly the "previous partial run" shape).
New-SourceZip -ZipPath (Join-Path $rootA "Staged.zip") -Files @{ "page1.jpg" = "x" } | Out-Null
$stagedDirA = New-Dir "scenario-a\Staged"
New-SourceZip -ZipPath (Join-Path $stagedDirA "Leftover.zip") -Files @{ "page1.jpg" = "x" } | Out-Null

$candidatesA = Get-RezipCandidateZips -Path $rootA
$namesA = @($candidatesA | ForEach-Object { $_.Name })
Test-Assert ($namesA -contains "Top.zip") "top-level ZIP found"
Test-Assert ($namesA -contains "Inner.zip") "nested ZIP found"
Test-Assert ($namesA -contains "Staged.zip") "the staging ZIP itself is found (it's not inside anything)"
Test-Assert ($namesA -notcontains "Leftover.zip") "a ZIP inside another ZIP's own staging folder is excluded"
Write-Host ""

# ==============================================================================
#  Scenario B: Invoke-RezipPipeline end-to-end success - extract, convert,
#  re-zip (over the same path), delete the extraction folder
# ==============================================================================
Write-Host "=== Scenario B: end-to-end success ===" -ForegroundColor Cyan
$rootB = New-Dir "scenario-b"
$zipB = New-SourceZip -ZipPath (Join-Path $rootB "Chapter.zip") -Files @{ "page1.jpg" = "ok" }

$totalsB = Invoke-RezipPipeline -Path $rootB -MaxParallel 2 -DeleteFolders $true -FullLogging $false `
    -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile `
    -PermanentDelete $true -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2

Test-Assert ($totalsB.CandidateCount -eq 1) ("1 candidate dispatched (got " + $totalsB.CandidateCount + ")")
Test-Assert ($totalsB.ZipExtractedSuccess -eq 1 -and $totalsB.ZipExtractedFail -eq 0) "extraction succeeded"
Test-Assert ($totalsB.ImgConvertedSuccess -eq 1 -and $totalsB.ImgConvertedFail -eq 0) "1 image converted, no failures"
Test-Assert ($totalsB.ZipCreatedSuccess -eq 1 -and $totalsB.ZipCreatedFail -eq 0) "re-zip succeeded"
Test-Assert ($totalsB.FolderDeletedSuccess -eq 1) "extraction folder was deleted"
Test-Assert (-not (Test-Path -LiteralPath (Join-Path $rootB "Chapter"))) "the extraction folder is actually gone"
Test-Assert (Test-Path -LiteralPath $zipB) "the ZIP still exists at the same path (rewritten in place)"

$archiveB = [System.IO.Compression.ZipFile]::OpenRead($zipB)
try {
    $entryNamesB = @($archiveB.Entries | ForEach-Object { $_.Name })
    Test-Assert ($entryNamesB -contains "page1.jxl") "the re-zipped output contains the converted .jxl, not the original .jpg"
} finally { $archiveB.Dispose() }

Test-Assert ($null -eq $script:rezipCts) "the CTS was disposed and cleared after a normal (non-aborted) run"
Write-Host ""

# ==============================================================================
#  Scenario C: a ZIP with no convertible images is skipped (never
#  dispatched) and recorded in resume-state directly by the job provider
# ==============================================================================
Write-Host "=== Scenario C: no convertible images - skipped, recorded ===" -ForegroundColor Cyan
$rootC = New-Dir "scenario-c"
New-SourceZip -ZipPath (Join-Path $rootC "NoImages.zip") -Files @{ "readme.txt" = "hello" } | Out-Null

$totalsC = Invoke-RezipPipeline -Path $rootC -MaxParallel 2 -FullLogging $false `
    -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile `
    -PermanentDelete $true -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2

Test-Assert ($totalsC.CandidateCount -eq 0) "no-images ZIP was never dispatched as a candidate"
Test-Assert ($totalsC.Skipped -eq 1) "counted as skipped"
$mapC = Import-ResumeStateMap -StateFile (Get-ResumeStatePath -TargetPath $rootC)
Test-Assert ($mapC.Count -eq 1) "the no-images ZIP was recorded in resume-state directly (not via the worker)"
Write-Host ""

# ==============================================================================
#  Scenario D: resume-state correctly skips that same no-images ZIP on a
#  SECOND run, since its own on-disk timestamp never changes
# ==============================================================================
Write-Host "=== Scenario D: no-images ZIP is skipped again on a second run ===" -ForegroundColor Cyan
$totalsD = Invoke-RezipPipeline -Path $rootC -MaxParallel 2 -FullLogging $false `
    -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile `
    -PermanentDelete $true -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2
Test-Assert ($totalsD.CandidateCount -eq 0 -and $totalsD.Skipped -eq 1) "the second run also skips it via resume-state (stable timestamp, never rewritten)"
Write-Host ""

# ==============================================================================
#  Scenario E: REAL BEHAVIOR (see module header) - a ZIP that WAS
#  successfully converted is NOT re-dispatched to a real worker on a
#  later run, even though its resume-state entry technically doesn't
#  match anymore (re-zipping changed its timestamp) - the job provider's
#  own cheap pre-dispatch inspection finds only .jxl entries (nothing
#  matching the convertible-image pattern) and skips it that way instead,
#  then re-records it. The expensive extract/convert/re-zip cycle does
#  NOT repeat, only the cheap peek does.
# ==============================================================================
Write-Host "=== Scenario E: a completed ZIP is NOT re-dispatched on a second run ===" -ForegroundColor Cyan
$rootE = New-Dir "scenario-e"
New-SourceZip -ZipPath (Join-Path $rootE "Chapter.zip") -Files @{ "page1.jpg" = "ok" } | Out-Null

$totalsE1 = Invoke-RezipPipeline -Path $rootE -MaxParallel 2 -FullLogging $false `
    -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile `
    -PermanentDelete $true -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2
Test-Assert ($totalsE1.CandidateCount -eq 1 -and $totalsE1.ZipCreatedSuccess -eq 1) "first run: processed successfully"
$mapE1 = Import-ResumeStateMap -StateFile (Get-ResumeStatePath -TargetPath $rootE)
Test-Assert ($mapE1.Count -eq 1) "recorded in resume-state after the first successful run"

$totalsE2 = Invoke-RezipPipeline -Path $rootE -MaxParallel 2 -FullLogging $false `
    -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile `
    -PermanentDelete $true -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2
Test-Assert ($totalsE2.CandidateCount -eq 0) "second run: NOT re-dispatched to a real worker - the already-converted ZIP now only has .jxl entries, so the cheap pre-dispatch peek finds no convertible images"
$mapE2 = Import-ResumeStateMap -StateFile (Get-ResumeStatePath -TargetPath $rootE)
Test-Assert ($mapE2.Count -eq 1) "still recorded in resume-state (re-recorded via the 'no images' path, with a fresh timestamp)"
Write-Host ""

# ==============================================================================
#  Scenario F: a MIXED batch (one image converts, one fails) still gets
#  re-zipped unconditionally (confirmed-intentional, see CLAUDE.md) - the
#  output ends up with a real .jxl entry (so Test-ZipArchive's default
#  -RequireJxlEntry passes) alongside the failed source's original file -
#  and the whole ZIP does NOT get recorded in resume-state despite the
#  successful re-zip, since ResultHandler only records a FULLY-succeeded
#  job. (An ALL-images-fail batch is a different, harsher case: the
#  re-zip output would have zero .jxl entries at all, so Test-ZipArchive
#  itself throws and ZipCreated fails too - not exercised here, matches
#  the reference's own Test-ZipArchive default exactly either way.)
# ==============================================================================
Write-Host "=== Scenario F: mixed conversion outcome - not recorded in resume-state ===" -ForegroundColor Cyan
$rootF = New-Dir "scenario-f"
New-SourceZip -ZipPath (Join-Path $rootF "Chapter.zip") -Files @{ "page1.jpg" = "ok"; "page2.jpg" = "FAIL_CJXL" } | Out-Null

$totalsF = Invoke-RezipPipeline -Path $rootF -MaxParallel 2 -FullLogging $false `
    -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile `
    -PermanentDelete $true -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2

Test-Assert ($totalsF.ImgConvertedSuccess -eq 1 -and $totalsF.ImgConvertedFail -eq 1) "one image converted, one failed"
Test-Assert ($totalsF.ZipCreatedSuccess -eq 1) "the ZIP was still re-zipped despite the failure (unconditional re-zip, confirmed intentional) - at least one real .jxl entry exists"
$mapF = Import-ResumeStateMap -StateFile (Get-ResumeStatePath -TargetPath $rootF)
Test-Assert ($mapF.Count -eq 0) "NOT recorded in resume-state despite the successful re-zip - a partial failure is never recorded, will be retried next run"
Write-Host ""

# ==============================================================================
#  Scenario G: a corrupt ZIP is filtered out at the job provider's own
#  pre-dispatch inspection (ZipFile.OpenRead fails there first) - it
#  never reaches a real worker at all, so it's counted as Skipped, not
#  as a worker-level ZipExtractedFail. No crash either way.
# ==============================================================================
Write-Host "=== Scenario G: corrupt ZIP is filtered before dispatch ===" -ForegroundColor Cyan
$rootG = New-Dir "scenario-g"
$corruptZipG = Join-Path $rootG "Corrupt.zip"
"this is not a real zip file" | Set-Content -LiteralPath $corruptZipG -Encoding UTF8

$threwG = $false
$totalsG = $null
try {
    $totalsG = Invoke-RezipPipeline -Path $rootG -MaxParallel 2 -FullLogging $false `
        -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile `
        -PermanentDelete $true -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2
} catch { $threwG = $true }

Test-Assert (-not $threwG) "a corrupt ZIP does not crash the whole pipeline"
Test-Assert ($totalsG.CandidateCount -eq 0) "never dispatched to a real worker"
Test-Assert ($totalsG.Skipped -eq 1) "counted as skipped, at the inspection stage"
Test-Assert ($totalsG.ZipExtractedFail -eq 0) "no worker-level extraction failure - the corrupt ZIP never got that far"
Write-Host ""

# ==============================================================================
#  Scenario H: -DeleteFolders `$false` keeps the extraction folder
# ==============================================================================
Write-Host "=== Scenario H: -DeleteFolders `$false keeps the extraction folder ===" -ForegroundColor Cyan
$rootH = New-Dir "scenario-h"
New-SourceZip -ZipPath (Join-Path $rootH "Chapter.zip") -Files @{ "page1.jpg" = "ok" } | Out-Null

$totalsH = Invoke-RezipPipeline -Path $rootH -MaxParallel 2 -DeleteFolders $false -FullLogging $false `
    -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile `
    -PermanentDelete $true -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2

Test-Assert ($totalsH.FolderDeletedSuccess -eq 0 -and $totalsH.FolderDeletedFail -eq 0) "no delete was attempted"
Test-Assert (Test-Path -LiteralPath (Join-Path $rootH "Chapter")) "the extraction folder was kept"
Write-Host ""

# ==============================================================================
#  Scenario I: no ZIP files found at all - a clean, empty result, no error
# ==============================================================================
Write-Host "=== Scenario I: no ZIPs found ===" -ForegroundColor Cyan
$rootI = New-Dir "scenario-i-empty"
$totalsI = Invoke-RezipPipeline -Path $rootI -MaxParallel 2 -FullLogging $false `
    -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile `
    -PermanentDelete $true -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2
Test-Assert ($totalsI.CandidateCount -eq 0) "0 candidates in an empty tree"
Write-Host ""

# ==============================================================================
#  Scenario J: multiple ZIPs actually run in parallel (MaxParallel > 1
#  processed together, not serialized) - several real ZIPs, all succeed
# ==============================================================================
Write-Host "=== Scenario J: multiple ZIPs processed together ===" -ForegroundColor Cyan
$rootJ = New-Dir "scenario-j"
1..4 | ForEach-Object {
    New-SourceZip -ZipPath (Join-Path $rootJ ("Chapter" + $_ + ".zip")) -Files @{ "page1.jpg" = "ok" } | Out-Null
}

$totalsJ = Invoke-RezipPipeline -Path $rootJ -MaxParallel 4 -DeleteFolders $true -FullLogging $false `
    -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile `
    -PermanentDelete $true -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2

Test-Assert ($totalsJ.CandidateCount -eq 4) ("all 4 ZIPs dispatched (got " + $totalsJ.CandidateCount + ")")
Test-Assert ($totalsJ.ZipCreatedSuccess -eq 4 -and $totalsJ.ZipCreatedFail -eq 0) "all 4 re-zipped successfully"
$mapJ = Import-ResumeStateMap -StateFile (Get-ResumeStatePath -TargetPath $rootJ)
Test-Assert ($mapJ.Count -eq 4) "all 4 recorded in resume-state after this single successful run"
Write-Host ""

# ==============================================================================
#  Scenario K: Invoke-RezipPipeline actually calls
#  Write-ResumeStateRetainedNotice once, with the real state file path -
#  the real wiring for the "resume state file retained" gap this
#  session's docs flagged, not just that ResumeState.ps1's own function
#  works in isolation (covered by ResumeState.Harness.ps1's own Scenario
#  M).
# ==============================================================================
Write-Host "=== Scenario K: Write-ResumeStateRetainedNotice actually gets called ===" -ForegroundColor Cyan
$originalRetainedNotice = ${function:Write-ResumeStateRetainedNotice}
$script:retainedNoticeCalls = [System.Collections.Generic.List[string]]::new()
function Write-ResumeStateRetainedNotice {
    param([string]$StateFile)
    $script:retainedNoticeCalls.Add($StateFile)
    & $originalRetainedNotice -StateFile $StateFile
}

$rootK = New-Dir "scenario-k"
New-SourceZip -ZipPath (Join-Path $rootK "Chapter1.zip") -Files @{ "page1.jpg" = "ok" } | Out-Null
$null = Invoke-RezipPipeline -Path $rootK -MaxParallel 2 -FullLogging $false `
    -LogFile $script:logFile -LogErrorFile $script:logErrorFile -LogWarnFile $script:logWarnFile `
    -PermanentDelete $true -CjxlExe $fakeCjxlExe -MaxCjxlProcs 2

Test-Assert ($script:retainedNoticeCalls.Count -eq 1) ("called exactly once (got " + $script:retainedNoticeCalls.Count + ")")
Test-Assert ($script:retainedNoticeCalls.Count -gt 0 -and $script:retainedNoticeCalls[0] -eq (Get-ResumeStatePath -TargetPath $rootK)) "called with this run's real state file path"

${function:Write-ResumeStateRetainedNotice} = $originalRetainedNotice
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
