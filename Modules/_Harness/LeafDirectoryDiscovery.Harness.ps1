<#
.SYNOPSIS
    Standalone test harness for Modules\LeafDirectoryDiscovery.ps1.

.DESCRIPTION
    Dot-sources the real module and exercises it against real folders -
    not mocked I/O. Write-Log is a FORWARD REFERENCE this module expects
    from Logging.ps1 - stubbed here since LeafDirectoryDiscovery must
    stay standalone-testable without it. Scenario O also dot-sources the
    real ZipParallelProcessing.ps1 (for its own real dispatch/runspace
    behavior) - since that module migrated onto Logging.ps1/
    AbortPipeline.ps1 (2026-08-27, see CLAUDE.md "Known gaps"), it now
    forward-references Test-AbortSignal/Flush-ConsoleQueue/
    Initialize-LogMutex/Invoke-GracefulDrain too, all stubbed alongside
    Write-Log below for the same "stay standalone" reason - Scenario O
    never triggers an abort, so Invoke-GracefulDrain's stub is never
    actually exercised, just present so the dot-source doesn't fail
    Set-StrictMode or a future call.

    Scenario K/L reproduce the "parent/container folder" bug documented
    in CHANGELOG.md's former-container guard entry, using a folder shape
    modeled directly on the real examples in Backups\Test Images\Only
    Images (before: chapter subfolders full of images) and
    Backups\Rezip Tests\Only Images (after: chapter subfolders zipped and
    removed, leaving only .zip files at the series level) - not touching
    Backups itself, which is off-limits to every script by design; this
    harness builds its own equivalent shape in a scratch temp directory.
    CHANGELOG.md's own note says the guard's fix was "best-reasoned...
    not a confirmed root-cause diagnosis - the exact mechanism wasn't
    reproduced" - this is the first live reproduction and confirmation.

.EXAMPLE
    .\Modules\_Harness\LeafDirectoryDiscovery.Harness.ps1
#>

$ErrorActionPreference = "Stop"

# ZipParallelProcessing.ps1 now forward-references Test-AbortSignal/
# Flush-ConsoleQueue/Initialize-LogMutex/Invoke-GracefulDrain (from
# AbortPipeline.ps1/Logging.ps1 - see its own header) instead of defining
# its own inline copies, so all four need a stub defined BEFORE it's
# dot-sourced, same as Write-Log below.
$script:logMessages = [System.Collections.Generic.List[string]]::new()
function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $script:logMessages.Add($Message)
    Write-Host ("  [log:" + $Level + "] " + $Message) -ForegroundColor DarkGray
}
function Test-AbortSignal { return $false }   # Scenario O never triggers an abort
function Flush-ConsoleQueue { param($Queue) }   # no-op; nothing gets queued (SharedFunctionNames is empty in Scenario O)
function Initialize-LogMutex { param([string]$PathHash) $script:logMutex = $null }
function Invoke-GracefulDrain { param($Handles, $ResultHandler, $ConsoleQueue, $ErrorHandler, $TimeoutSeconds, $AbortWaitMessage) return @{ ForceStoppedCount = 0 } }   # never actually exercised - Scenario O never aborts

. (Join-Path $PSScriptRoot "..\ZipParallelProcessing.ps1")

. (Join-Path $PSScriptRoot "..\LeafDirectoryDiscovery.ps1")

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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("leafdiscovery-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray
Write-Host ""

$imgExts = @(".jpg", ".png", ".jxl")

function New-Dir {
    param([string]$RelativePath)
    $path = Join-Path $scratchDir $RelativePath
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}
function New-FileIn {
    param([string]$DirPath, [string]$Name, [Nullable[datetime]]$LastWriteTimeUtc = $null)
    $path = Join-Path $DirPath $Name
    "content" | Out-File -FilePath $path -Encoding UTF8
    if ($LastWriteTimeUtc) { (Get-Item -LiteralPath $path).LastWriteTimeUtc = $LastWriteTimeUtc }
    return $path
}

# ==============================================================================
#  Scenario A: basic - one leaf dir with qualifying files is found
# ==============================================================================
Write-Host "=== Scenario A: basic leaf discovery ===" -ForegroundColor Cyan
$rootA = New-Dir "scenario-a"
$leafA = New-Dir "scenario-a\Chapter 1"
New-FileIn -DirPath $leafA -Name "page1.jpg" | Out-Null

$resultA = Get-ZippableLeafDirs -ScanPath $rootA -QualifyingExtensions $imgExts
Test-Assert ($resultA.Count -eq 1) ("exactly 1 leaf found (got " + $resultA.Count + ")")
Test-Assert ($resultA[0].Dir.FullName -eq $leafA) "the found leaf's Dir matches the actual folder"
Test-Assert ($resultA[0].ZipOut -eq (Join-Path $rootA "Chapter 1.zip")) "ZipOut is correctly placed in the leaf's PARENT directory"
Write-Host ""

# ==============================================================================
#  Scenario B: a folder with subdirectories is NOT a leaf, even if it also
#  has qualifying files directly inside it.
# ==============================================================================
Write-Host "=== Scenario B: non-leaf (has subdirs) is excluded ===" -ForegroundColor Cyan
$rootB    = New-Dir "scenario-b"
$parentB  = New-Dir "scenario-b\Series"
New-FileIn -DirPath $parentB -Name "stray.jpg" | Out-Null   # qualifying file directly in the non-leaf
$childB   = New-Dir "scenario-b\Series\Chapter 1"
New-FileIn -DirPath $childB -Name "page1.jpg" | Out-Null

$resultB = Get-ZippableLeafDirs -ScanPath $rootB -QualifyingExtensions $imgExts
Test-Assert ($resultB.Count -eq 1) ("only the true leaf (Chapter 1) was found, not the parent (got " + $resultB.Count + ")")
Test-Assert ($resultB[0].Dir.FullName -eq $childB) "the one result is the leaf, not the non-leaf parent"
Write-Host ""

# ==============================================================================
#  Scenario C: former-container guard - a leaf-shaped dir containing an
#  existing .zip (and no qualifying files) is skipped, with a Warn log.
# ==============================================================================
Write-Host "=== Scenario C: former-container guard (basic) ===" -ForegroundColor Cyan
$rootC = New-Dir "scenario-c"
$dirC  = New-Dir "scenario-c\Old Chapter"
New-FileIn -DirPath $dirC -Name "Old Chapter.zip" | Out-Null
$script:logMessages.Clear()

$resultC = Get-ZippableLeafDirs -ScanPath $rootC -QualifyingExtensions $imgExts
Test-Assert ($resultC.Count -eq 0) "a folder containing only a .zip is not treated as a zip candidate"
Test-Assert (($script:logMessages | Where-Object { $_ -like "*SKIPPING*existing .zip*" }).Count -eq 1) "a Warn-level skip message was logged explaining why"
Write-Host ""

# ==============================================================================
#  Scenario D: no qualifying extensions present - silently skipped (empty
#  result for that dir, no warning - this is just "nothing to do" here,
#  not a container-guard case).
# ==============================================================================
Write-Host "=== Scenario D: no qualifying files - silently skipped ===" -ForegroundColor Cyan
$rootD = New-Dir "scenario-d"
$dirD  = New-Dir "scenario-d\Empty-ish"
New-FileIn -DirPath $dirD -Name "notes.txt" | Out-Null
$script:logMessages.Clear()

$resultD = Get-ZippableLeafDirs -ScanPath $rootD -QualifyingExtensions $imgExts
Test-Assert ($resultD.Count -eq 0) "a folder with no qualifying files produces no candidate"
Test-Assert ($script:logMessages.Count -eq 0) "no warning was logged - this isn't a container-guard case, just nothing to do"
Write-Host ""

# ==============================================================================
#  Scenario E: staleness check - existing zip newer than every qualifying
#  file is skipped (up to date already).
# ==============================================================================
Write-Host "=== Scenario E: staleness check skips an up-to-date zip ===" -ForegroundColor Cyan
$rootE = New-Dir "scenario-e"
$dirE  = New-Dir "scenario-e\Chapter 1"
$fileTimeE = (Get-Date).ToUniversalTime().AddHours(-2)
New-FileIn -DirPath $dirE -Name "page1.jpg" -LastWriteTimeUtc $fileTimeE | Out-Null
$zipOutE = Join-Path $rootE "Chapter 1.zip"
"fake zip" | Out-File -FilePath $zipOutE -Encoding UTF8
(Get-Item -LiteralPath $zipOutE).LastWriteTimeUtc = (Get-Date).ToUniversalTime()   # newer than the source file
$script:logMessages.Clear()

$resultE = Get-ZippableLeafDirs -ScanPath $rootE -QualifyingExtensions $imgExts
Test-Assert ($resultE.Count -eq 0) "an up-to-date zip means the leaf is not re-queued"
Test-Assert (($script:logMessages | Where-Object { $_ -like "*up to date*" }).Count -eq 1) "a Warn-level 'up to date' message was logged"
Write-Host ""

# ==============================================================================
#  Scenario F: staleness check - existing zip OLDER than a qualifying file
#  means the leaf IS re-queued (something changed since it was last zipped).
# ==============================================================================
Write-Host "=== Scenario F: staleness check re-includes a stale zip ===" -ForegroundColor Cyan
$rootF = New-Dir "scenario-f"
$dirF  = New-Dir "scenario-f\Chapter 1"
$zipOutF = Join-Path $rootF "Chapter 1.zip"
"fake zip" | Out-File -FilePath $zipOutF -Encoding UTF8
(Get-Item -LiteralPath $zipOutF).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-2)
New-FileIn -DirPath $dirF -Name "page1.jpg" -LastWriteTimeUtc ((Get-Date).ToUniversalTime()) | Out-Null   # newer than the zip

$resultF = Get-ZippableLeafDirs -ScanPath $rootF -QualifyingExtensions $imgExts
Test-Assert ($resultF.Count -eq 1) "a zip older than its source file means the leaf IS re-queued for zipping"
Write-Host ""

# ==============================================================================
#  Scenario G: -ForceRezip bypasses the staleness check even when the zip
#  is genuinely newer than every source file.
# ==============================================================================
Write-Host "=== Scenario G: -ForceRezip bypasses staleness ===" -ForegroundColor Cyan
$rootG = New-Dir "scenario-g"
$dirG  = New-Dir "scenario-g\Chapter 1"
$fileTimeG = (Get-Date).ToUniversalTime().AddHours(-2)
New-FileIn -DirPath $dirG -Name "page1.jpg" -LastWriteTimeUtc $fileTimeG | Out-Null
$zipOutG = Join-Path $rootG "Chapter 1.zip"
"fake zip" | Out-File -FilePath $zipOutG -Encoding UTF8
(Get-Item -LiteralPath $zipOutG).LastWriteTimeUtc = (Get-Date).ToUniversalTime()

$resultGNoForce = Get-ZippableLeafDirs -ScanPath $rootG -QualifyingExtensions $imgExts -ForceRezip $false
$resultGForce   = Get-ZippableLeafDirs -ScanPath $rootG -QualifyingExtensions $imgExts -ForceRezip $true
Test-Assert ($resultGNoForce.Count -eq 0) "without -ForceRezip, an up-to-date zip is still skipped (sanity check)"
Test-Assert ($resultGForce.Count -eq 1) "-ForceRezip `$true includes the leaf even though its zip is newer than the source"
Write-Host ""

# ==============================================================================
#  Scenario H: -ExcludeStagingDirs excludes a directory (and would exclude
#  anything under it) even though it would otherwise qualify.
# ==============================================================================
Write-Host "=== Scenario H: -ExcludeStagingDirs excludes a matching leaf ===" -ForegroundColor Cyan
$rootH   = New-Dir "scenario-h"
$stageH  = New-Dir "scenario-h\_staging"
New-FileIn -DirPath $stageH -Name "page1.jpg" | Out-Null
$normalH = New-Dir "scenario-h\Chapter 1"
New-FileIn -DirPath $normalH -Name "page1.jpg" | Out-Null
$excludeSetH = [System.Collections.Generic.HashSet[string]]::new()
$null = $excludeSetH.Add($stageH)

$resultH = Get-ZippableLeafDirs -ScanPath $rootH -QualifyingExtensions $imgExts -ExcludeStagingDirs $excludeSetH
Test-Assert ($resultH.Count -eq 1) ("only the non-staging leaf was found (got " + $resultH.Count + ")")
Test-Assert ($resultH[0].Dir.FullName -eq $normalH) "the one result is the normal chapter, not the staging dir"
Write-Host ""

# ==============================================================================
#  Scenario I: 0-result case - return type must stay a real, enumerable
#  List[hashtable], NOT collapse to $null. This is the exact bug class
#  documented in CLAUDE.md's "Lessons learned" (already caught twice
#  elsewhere in this project) - checked by TYPE, not just truthiness,
#  since a naive `$result.Count -eq 0` could also be satisfied by $null
#  going through `@()`-wrapping at the call site and masking the bug.
# ==============================================================================
Write-Host "=== Scenario I: 0-result return type stays List[hashtable] ===" -ForegroundColor Cyan
$rootI = New-Dir "scenario-i-empty"
$resultI = Get-ZippableLeafDirs -ScanPath $rootI -QualifyingExtensions $imgExts
Test-Assert ($null -ne $resultI) "0-result return is NOT `$null"
Test-Assert ($resultI -is [System.Collections.Generic.List[hashtable]]) ("0-result return is still a real List[hashtable] (actual type: " + $resultI.GetType().FullName + ")")
Test-Assert ($resultI.Count -eq 0) "0-result Count is 0"
Write-Host ""

# ==============================================================================
#  Scenario J: 1-result case - return type must stay List[hashtable], NOT
#  collapse to a bare hashtable (the other half of the same bug class -
#  a 1-element collection is the specific shape that silently unwraps).
# ==============================================================================
Write-Host "=== Scenario J: 1-result return type stays List[hashtable] (not a bare hashtable) ===" -ForegroundColor Cyan
$rootJ = New-Dir "scenario-j-single"
$leafJ = New-Dir "scenario-j-single\Only Chapter"
New-FileIn -DirPath $leafJ -Name "page1.jpg" | Out-Null
$resultJ = Get-ZippableLeafDirs -ScanPath $rootJ -QualifyingExtensions $imgExts
Test-Assert ($resultJ -is [System.Collections.Generic.List[hashtable]]) ("1-result return is still a real List[hashtable], not a bare Hashtable (actual type: " + $resultJ.GetType().FullName + ")")
Test-Assert ($resultJ.Count -eq 1) "1-result Count is 1 (not silently missing via collapse)"
Test-Assert ($resultJ[0].Dir.FullName -eq $leafJ) "indexing [0] on the 1-result list still works correctly"
Write-Host ""

# ==============================================================================
#  Scenario K (user-requested, reproduces the CHANGELOG.md former-container
#  bug for real): a series folder ("Only Images") whose every chapter has
#  already been converted, zipped, and had its source folder removed -
#  modeled directly on Backups\Rezip Tests\Only Images's real shape (only
#  .zip files, zero subdirectories). Get-ZippableLeafDirs must NOT treat
#  "Only Images" itself as a zippable leaf - it would otherwise archive
#  all the already-created per-chapter .zip files into an unwanted wrapper
#  zip and (via the caller's later Remove-Source) delete the originals
#  along with them.
# ==============================================================================
Write-Host "=== Scenario K: former-container guard on a REAL post-completion series folder ===" -ForegroundColor Cyan
$rootK        = New-Dir "scenario-k"
$onlyImagesK  = New-Dir "scenario-k\Only Images"
New-FileIn -DirPath $onlyImagesK -Name "08 - Chapter 8.zip"  | Out-Null
New-FileIn -DirPath $onlyImagesK -Name "09 - Chapter 9.zip"  | Out-Null
New-FileIn -DirPath $onlyImagesK -Name "10 - Chapter 10.zip" | Out-Null
$script:logMessages.Clear()

$resultK = Get-ZippableLeafDirs -ScanPath $rootK -QualifyingExtensions $imgExts
Test-Assert ($resultK.Count -eq 0) "'Only Images' (zero subdirs, only .zip files inside) is NOT returned as a zip candidate"
Test-Assert (($script:logMessages | Where-Object { $_ -like "*Only Images*existing .zip*" }).Count -eq 1) "the skip was logged with a clear reason, not silently dropped"
Write-Host ("  (this is the first live reproduction of the bug CHANGELOG.md's former-container guard entry describes as 'not a confirmed root-cause diagnosis - the exact mechanism wasn't reproduced' - now confirmed fixed)") -ForegroundColor DarkGray
Write-Host ""

# ==============================================================================
#  Scenario L: mixed state - "Only Images" has TWO already-zipped chapters
#  (zip-only siblings, folders removed) AND ONE chapter not yet zipped
#  (a real leaf subfolder with images still inside). The still-pending
#  chapter must be found and zipped on its own; "Only Images" itself must
#  still be excluded (now doubly so: it has a subdirectory again, AND it
#  has .zip files directly inside it).
# ==============================================================================
Write-Host "=== Scenario L: mixed state - one pending chapter alongside already-zipped ones ===" -ForegroundColor Cyan
$rootL       = New-Dir "scenario-l"
$onlyImagesL = New-Dir "scenario-l\Only Images"
New-FileIn -DirPath $onlyImagesL -Name "01 - Chapter 1.zip" | Out-Null
New-FileIn -DirPath $onlyImagesL -Name "02 - Chapter 2.zip" | Out-Null
$pendingChapterL = New-Dir "scenario-l\Only Images\03 - Chapter 3"
New-FileIn -DirPath $pendingChapterL -Name "page1.jpg" | Out-Null
$script:logMessages.Clear()

$resultL = Get-ZippableLeafDirs -ScanPath $rootL -QualifyingExtensions $imgExts
Test-Assert ($resultL.Count -eq 1) ("exactly the 1 still-pending chapter was found (got " + $resultL.Count + ")")
Test-Assert ($resultL[0].Dir.FullName -eq $pendingChapterL) "the found leaf is the pending chapter, not 'Only Images' itself"
Write-Host ""

# ==============================================================================
#  Scenario M: a nonexistent -ScanPath throws a clear error immediately,
#  instead of silently returning an empty list indistinguishable from a
#  genuinely-empty valid directory.
# ==============================================================================
Write-Host "=== Scenario M: nonexistent -ScanPath throws ===" -ForegroundColor Cyan
$missingScanPathM = Join-Path $scratchDir "this-path-does-not-exist-at-all"
$threwM = $false
$errorMessageM = $null
try {
    Get-ZippableLeafDirs -ScanPath $missingScanPathM -QualifyingExtensions $imgExts
} catch {
    $threwM = $true
    $errorMessageM = $_.Exception.Message
}
Test-Assert $threwM "a nonexistent -ScanPath throws instead of silently returning an empty list"
Test-Assert ($errorMessageM -like "*does not exist*") "the error message is clear about what went wrong"
Write-Host ""

# ==============================================================================
#  Scenario N (user-requested): New-ZippableLeafDirProvider - repeated
#  calls to the returned scriptblock correctly advance and find every
#  qualifying leaf exactly once, matching Get-ZippableLeafDirs's batch
#  result on the SAME tree (including a former-container case, proving
#  guard parity via the shared Test-ZippableLeafDirCandidate helper), then
#  consistently returns $null once exhausted. This is the closure/state-
#  persistence-across-calls risk this project has documented failures
#  with before (CLAUDE.md "Lessons learned") - verified live, not assumed
#  safe by analogy to the pattern that already worked elsewhere.
# ==============================================================================
Write-Host "=== Scenario N: New-ZippableLeafDirProvider matches batch results, advances correctly ===" -ForegroundColor Cyan
$rootN = New-Dir "scenario-n"
$leaf1N = New-Dir "scenario-n\Chapter 1"
New-FileIn -DirPath $leaf1N -Name "page1.jpg" | Out-Null
$leaf2N = New-Dir "scenario-n\Chapter 2"
New-FileIn -DirPath $leaf2N -Name "page1.jpg" | Out-Null
$leaf3N = New-Dir "scenario-n\Chapter 3"
New-FileIn -DirPath $leaf3N -Name "page1.jpg" | Out-Null
# A former-container case mixed into the same tree, to prove the
# incremental path applies the SAME guard as the batch path.
$formerContainerN = New-Dir "scenario-n\Only Images"
New-FileIn -DirPath $formerContainerN -Name "01 - Chapter 1.zip" | Out-Null

$batchResultN = @(Get-ZippableLeafDirs -ScanPath $rootN -QualifyingExtensions $imgExts)
$batchPathsN  = @($batchResultN | ForEach-Object { $_.Dir.FullName } | Sort-Object)

$provider = New-ZippableLeafDirProvider -ScanPath $rootN -QualifyingExtensions $imgExts
$incrementalPathsN = [System.Collections.Generic.List[string]]::new()
$callCountN = 0
while ($true) {
    $callCountN++
    $next = & $provider
    if ($null -eq $next) { break }
    $incrementalPathsN.Add($next.Dir.FullName)
    if ($callCountN -gt 100) { throw "Scenario N: provider did not terminate after 100 calls - possible infinite loop." }
}
$incrementalPathsN = @($incrementalPathsN | Sort-Object)

Test-Assert ($batchPathsN.Count -eq 3) ("sanity check: batch path found the expected 3 leaves (got " + $batchPathsN.Count + ")")
Test-Assert ($incrementalPathsN.Count -eq 3) ("incremental provider found the same count (got " + $incrementalPathsN.Count + ")")
Test-Assert (($incrementalPathsN -join "|") -eq ($batchPathsN -join "|")) "incremental provider's result set exactly matches the batch function's (same guards, same tree)"
Test-Assert ($incrementalPathsN -notcontains $formerContainerN) "'Only Images' (former-container) was correctly excluded by the incremental path too"

# Exhaustion: further calls after the tree is exhausted keep returning
# $null, not an error and not a repeated/stale result.
$postExhaustion1 = & $provider
$postExhaustion2 = & $provider
Test-Assert ($null -eq $postExhaustion1 -and $null -eq $postExhaustion2) "calling the exhausted provider again keeps returning `$null, not an error or a repeat"
Write-Host ""

# ==============================================================================
#  Scenario N2 (2026-08-31 fix, caught by a same-day /code-review
#  full-codebase pass): a directory the provider just returned as a
#  candidate must NOT be on $dirStack - it's a true leaf (Test-
#  ZippableLeafDirCandidate returns $null the moment it finds a
#  subdirectory), so pushing it was pointless, and worse in mode 3: the
#  caller (Invoke-ZipOnlyPipeline) zips that SAME candidate and deletes
#  the folder before this provider's next call. The stack being LIFO
#  meant the provider then popped the now-deleted path and
#  EnumerateDirectories threw, logging a bogus "Could not enumerate -
#  skipping it" Warn for a perfectly normal deletion - on every chapter,
#  every default (-DeleteFolders $true) mode-3 run. This scenario
#  reproduces the exact production condition: return a candidate, delete
#  it (simulating the worker), call again - no Warn should be logged.
# ==============================================================================
Write-Host "=== Scenario N2: a candidate directory deleted right after being returned does not log a bogus enumerate-failure Warn ===" -ForegroundColor Cyan
$rootN2 = New-Dir "scenario-n2"
$leaf1N2 = New-Dir "scenario-n2\Chapter 1"
New-FileIn -DirPath $leaf1N2 -Name "page1.jpg" | Out-Null
$leaf2N2 = New-Dir "scenario-n2\Chapter 2"
New-FileIn -DirPath $leaf2N2 -Name "page1.jpg" | Out-Null

$script:logMessages.Clear()
$providerN2 = New-ZippableLeafDirProvider -ScanPath $rootN2 -QualifyingExtensions $imgExts
$firstN2 = & $providerN2
Test-Assert ($null -ne $firstN2) "sanity check: the first candidate was returned"
# Simulate the mode-3 worker's own zip-then-delete of the returned candidate.
Remove-Item -LiteralPath $firstN2.Dir.FullName -Recurse -Force
# Drain the provider fully (matching Scenario N's own pattern) - the bug
# only surfaces once the stack is later POPPED back down to the deleted
# entry (LIFO), which doesn't happen until the tree is otherwise exhausted,
# not on the very next call.
$resultsN2 = [System.Collections.Generic.List[string]]::new()
$callCountN2 = 0
while ($true) {
    $callCountN2++
    $next = & $providerN2
    if ($null -eq $next) { break }
    $resultsN2.Add($next.Dir.FullName)
    if ($callCountN2 -gt 100) { throw "Scenario N2: provider did not terminate after 100 calls - possible infinite loop." }
}

Test-Assert ($resultsN2.Count -eq 1 -and $resultsN2[0] -eq $leaf2N2) ("the second (still-real) candidate was still found correctly after the first was deleted, and nothing else (got: " + ($resultsN2 -join ", ") + ")")
Test-Assert (($script:logMessages | Where-Object { $_ -like "*Could not enumerate*" }).Count -eq 0) "no bogus 'Could not enumerate' Warn was logged for the deleted candidate - it was never pushed onto the stack in the first place"
Write-Host ""

# ==============================================================================
#  Scenario O: real end-to-end dispatch - New-ZippableLeafDirProvider
#  passed directly as -NextJobProvider to the REAL
#  Invoke-ZipParallelProcessing (dot-sourced for real, not stubbed),
#  proving the wiring actually works through genuine runspace dispatch,
#  not just structural correctness of the provider in isolation.
# ==============================================================================
Write-Host "=== Scenario O: New-ZippableLeafDirProvider dispatched through real Invoke-ZipParallelProcessing ===" -ForegroundColor Cyan
$rootO = New-Dir "scenario-o"
$leaf1O = New-Dir "scenario-o\Chapter 1"
New-FileIn -DirPath $leaf1O -Name "page1.jpg" | Out-Null
$leaf2O = New-Dir "scenario-o\Chapter 2"
New-FileIn -DirPath $leaf2O -Name "page1.jpg" | Out-Null

$providerO = New-ZippableLeafDirProvider -ScanPath $rootO -QualifyingExtensions $imgExts
$touchedO = [System.Collections.Generic.List[string]]::new()
$workerO = {
    param($Dir, $ZipOut, [System.Threading.CancellationToken]$CancelToken, $LogMutex, $ConsoleQueue)
    return @{ Touched = $Dir }
}
$ctsO = [System.Threading.CancellationTokenSource]::new()
$resultHandlerO = { param($r) $touchedO.Add($r.Touched) }.GetNewClosure()

# NextJobProvider yields @{ Dir; ZipOut } - map to the worker's own bound
# parameter names via a thin translating closure, since
# Invoke-ZipParallelProcessing calls -NextJobProvider with no arguments
# and expects a hashtable of the WORKER's parameter names back.
$translatingProviderO = {
    $next = & $providerO
    if ($null -eq $next) { return $null }
    return @{ Dir = $next.Dir.FullName; ZipOut = $next.ZipOut }
}.GetNewClosure()

$outcomeO = Invoke-ZipParallelProcessing -WorkerScript $workerO -NextJobProvider $translatingProviderO `
    -SharedFunctionNames @() -MaxParallel 2 -Cts $ctsO -ResultHandler $resultHandlerO
$ctsO.Dispose()

Test-Assert ($outcomeO.ForceStoppedCount -eq 0) "no jobs were force-stopped in a normal run"
Test-Assert ($touchedO.Count -eq 2) ("both leaf directories were actually dispatched and processed through real runspaces (got " + $touchedO.Count + ")")
Test-Assert ($touchedO -contains $leaf1O -and $touchedO -contains $leaf2O) "both the specific expected directories were dispatched"
Write-Host ""

# ==============================================================================
#  Scenario P: lightweight empirical signal (not a strict proof) that the
#  incremental provider's first call returns without needing to finish
#  scanning the whole tree first, unlike Get-ZippableLeafDirs. Relies on
#  [System.IO.Directory]::EnumerateDirectories's documented lazy-
#  enumeration contract (a well-established .NET API guarantee, not a
#  PowerShell closure/pipeline quirk like the bugs this project has
#  actually been burned by before) - this timing check is supporting
#  evidence on top of that documented contract, not the sole basis for
#  trusting it.
# ==============================================================================
Write-Host "=== Scenario P: incremental first-result is faster than a full batch scan on a larger tree ===" -ForegroundColor Cyan
$rootP = New-Dir "scenario-p"
$firstLeafP = New-Dir "scenario-p\AAA-First-Chapter"
New-FileIn -DirPath $firstLeafP -Name "page1.jpg" | Out-Null
for ($i = 1; $i -le 40; $i++) {
    $paddingDir = New-Dir ("scenario-p\padding-{0:D3}" -f $i)
    New-FileIn -DirPath $paddingDir -Name ("file{0}.txt" -f $i) | Out-Null
}

$swBatchP = [System.Diagnostics.Stopwatch]::StartNew()
$null = @(Get-ZippableLeafDirs -ScanPath $rootP -QualifyingExtensions $imgExts)
$swBatchP.Stop()

$providerP = New-ZippableLeafDirProvider -ScanPath $rootP -QualifyingExtensions $imgExts
$swIncrementalP = [System.Diagnostics.Stopwatch]::StartNew()
$firstResultP = & $providerP
$swIncrementalP.Stop()

Write-Host ("  (batch scan: " + $swBatchP.ElapsedMilliseconds + "ms, incremental first result: " + $swIncrementalP.ElapsedMilliseconds + "ms)") -ForegroundColor DarkGray
Test-Assert ($null -ne $firstResultP) "the incremental provider found a first result"
Test-Assert ($swIncrementalP.ElapsedMilliseconds -le $swBatchP.ElapsedMilliseconds) "the incremental provider's first result arrived no slower than the full batch scan (consistent with lazy enumeration, not proof alone)"
Write-Host ""

# ==============================================================================
#  Scenario Q: New-SeriesProvider - lazy, single-level series enumeration
#  across a library. Repeated calls yield every series exactly once, then
#  consistently $null - the same closure/state-persistence risk already
#  proven safe for New-ZippableLeafDirProvider, verified again here since
#  this is a genuinely separate function/closure, not a reuse of that one.
# ==============================================================================
Write-Host "=== Scenario Q: New-SeriesProvider - lazy series enumeration ===" -ForegroundColor Cyan
$libraryQ = New-Dir "scenario-q-library"
$null = New-Dir "scenario-q-library\Series A"
$null = New-Dir "scenario-q-library\Series B"
$null = New-Dir "scenario-q-library\Series C"

$seriesProviderQ = New-SeriesProvider -LibraryPath $libraryQ -QualifyingExtensions $imgExts
$foundSeriesQ = [System.Collections.Generic.List[string]]::new()
$callCountQ = 0
while ($true) {
    $callCountQ++
    $next = & $seriesProviderQ
    if ($null -eq $next) { break }
    $foundSeriesQ.Add($next.Name)
    if ($callCountQ -gt 20) { throw "Scenario Q: provider did not terminate after 20 calls - possible infinite loop." }
}
$foundSeriesQ = @($foundSeriesQ | Sort-Object)

Test-Assert ($foundSeriesQ.Count -eq 3) ("all 3 series were found (got " + $foundSeriesQ.Count + ")")
Test-Assert (($foundSeriesQ -join "|") -eq "Series A|Series B|Series C") "the correct 3 series were found, by name"

$postExhaustionQ1 = & $seriesProviderQ
$postExhaustionQ2 = & $seriesProviderQ
Test-Assert ($null -eq $postExhaustionQ1 -and $null -eq $postExhaustionQ2) "calling the exhausted provider again keeps returning `$null, not an error or a repeat"
Write-Host ""

# ==============================================================================
#  Scenario Q2 (2026-09-23): category folders are containers, not series.
#  A direct child with no qualifying images/zips of its own and no chapter
#  subfolder (a subfolder with qualifying images directly inside) is a
#  category - its subfolders become the series, recursively. Series with
#  chapters, images directly inside, or only zips stay series.
# ==============================================================================
Write-Host "=== Scenario Q2: New-SeriesProvider descends into category folders ===" -ForegroundColor Cyan
$libraryQ2 = New-Dir "scenario-q2-library"
New-FileIn -DirPath (New-Dir "scenario-q2-library\Complete\Series A\Chapter 1") -Name "page1.jpg" | Out-Null
New-FileIn -DirPath (New-Dir "scenario-q2-library\Complete\Series B") -Name "Chapter 1.zip" | Out-Null
New-FileIn -DirPath (New-Dir "scenario-q2-library\Ongoing\Nested\Series C\Chapter 1") -Name "page1.jxl" | Out-Null
New-FileIn -DirPath (New-Dir "scenario-q2-library\Series D\Chapter 1") -Name "page1.png" | Out-Null
New-FileIn -DirPath (New-Dir "scenario-q2-library\Series E") -Name "page1.jpg" | Out-Null
$null = New-Dir "scenario-q2-library\Series F"

$seriesProviderQ2 = New-SeriesProvider -LibraryPath $libraryQ2 -QualifyingExtensions $imgExts
$foundQ2 = [System.Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt 30; $i++) {
    $next = & $seriesProviderQ2
    if ($null -eq $next) { break }
    $foundQ2.Add($next.FullName.Substring($libraryQ2.Length + 1))
}
$foundQ2Sorted = @($foundQ2 | Sort-Object)
$expectedQ2 = "Complete\Series A|Complete\Series B|Ongoing\Nested\Series C|Series D|Series E|Series F"
Test-Assert (($foundQ2Sorted -join "|") -eq $expectedQ2) ("categories (Complete, Ongoing, Ongoing\Nested) are descended into; everything else is a series (got: " + ($foundQ2Sorted -join "|") + ")")
Test-Assert ($null -eq (& $seriesProviderQ2)) "the exhausted provider keeps returning `$null"
Test-Assert (Test-SeriesCategoryFolder -Path (Join-Path $libraryQ2 "Complete") -QualifyingExtensions $imgExts) "Test-SeriesCategoryFolder: 'Complete' is a category"
Test-Assert (-not (Test-SeriesCategoryFolder -Path (Join-Path $libraryQ2 "Series D") -QualifyingExtensions $imgExts)) "Test-SeriesCategoryFolder: a series with a chapter subfolder is not a category"
Test-Assert (-not (Test-SeriesCategoryFolder -Path (Join-Path $libraryQ2 "Series F") -QualifyingExtensions $imgExts)) "Test-SeriesCategoryFolder: an empty folder (no subfolders) is not a category"
Write-Host ""

# ==============================================================================
#  Scenario Q3 (2026-09-23 review fix): New-SeriesProvider never descends
#  into a junction. A junction back to the library root looks like a
#  category (its children are series), so without the guard every series
#  was yielded again under the junction path, recursively.
# ==============================================================================
Write-Host "=== Scenario Q3: New-SeriesProvider does not descend into a junction ===" -ForegroundColor Cyan
$libraryQ3 = New-Dir "scenario-q3-library"
New-FileIn -DirPath (New-Dir "scenario-q3-library\Series A\Chapter 1") -Name "page1.jpg" | Out-Null
New-FileIn -DirPath (New-Dir "scenario-q3-library\Series B\Chapter 1") -Name "page1.jpg" | Out-Null
$linkQ3 = Join-Path $libraryQ3 "Link"
$null = cmd /c mklink /J "$linkQ3" "$libraryQ3" 2>&1
try {
    Test-Assert ([System.IO.Directory]::Exists($linkQ3)) "sanity check: the junction was created"
    $providerQ3 = New-SeriesProvider -LibraryPath $libraryQ3 -QualifyingExtensions $imgExts
    $foundQ3 = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt 50; $i++) {
        $next = & $providerQ3
        if ($null -eq $next) { break }
        $foundQ3.Add($next.FullName.Substring($libraryQ3.Length + 1))
    }
    Test-Assert (@($foundQ3 | Where-Object { $_ -like "Link\*" }).Count -eq 0) ("nothing was yielded from inside the junction (got: " + ($foundQ3 -join "|") + ")")
    Test-Assert ((@($foundQ3 | Sort-Object) -join "|") -eq "Link|Series A|Series B") ("each folder yielded once; the junction itself is treated as a series, as before categories existed (got: " + ($foundQ3 -join "|") + ")")
} finally {
    $null = cmd /c rmdir "$linkQ3" 2>&1
}
Write-Host ""

# ==============================================================================
#  Scenario R: New-SeriesProvider edge cases - nonexistent library throws;
#  an empty (0-series) library returns $null immediately, not an error.
# ==============================================================================
Write-Host "=== Scenario R: New-SeriesProvider edge cases ===" -ForegroundColor Cyan
$threwMissingLibraryR = $false
try { New-SeriesProvider -LibraryPath (Join-Path $scratchDir "does-not-exist-library") -QualifyingExtensions $imgExts } catch { $threwMissingLibraryR = $true }
Test-Assert $threwMissingLibraryR "a nonexistent -LibraryPath throws immediately, at setup time"

$emptyLibraryR = New-Dir "scenario-r-empty-library"
$emptyProviderR = New-SeriesProvider -LibraryPath $emptyLibraryR -QualifyingExtensions $imgExts
$firstCallR = & $emptyProviderR
Test-Assert ($null -eq $firstCallR) "an empty (0-series) library's first call returns `$null, not an error"
Write-Host ""

# ==============================================================================
#  Scenario S: Get-SeriesChapters - the critical comma/collapse check for
#  0- and 1-chapter series, verifying by TYPE (not just .Count, which a
#  collapsed bare Hashtable would also satisfy misleadingly for the
#  1-chapter case) - same discipline as Scenario I/J for the whole-library
#  function, applied again here since this is this function's OWN return
#  statement, a fresh opportunity for the same collapse.
# ==============================================================================
Write-Host "=== Scenario S: Get-SeriesChapters comma/collapse check ===" -ForegroundColor Cyan
$seriesS0 = New-Dir "scenario-s-zero-chapters"
$resultS0 = Get-SeriesChapters -SeriesPath $seriesS0 -QualifyingExtensions $imgExts
Test-Assert ($null -ne $resultS0) "0-chapter series result is NOT `$null"
Test-Assert ($resultS0 -is [System.Collections.Generic.List[hashtable]]) ("0-chapter series result is still a real List[hashtable] (actual type: " + $resultS0.GetType().FullName + ")")
Test-Assert ($resultS0.Count -eq 0) "0-chapter series Count is 0"

$seriesS1 = New-Dir "scenario-s-one-chapter"
$chapterS1 = New-Dir "scenario-s-one-chapter\Chapter 1"
New-FileIn -DirPath $chapterS1 -Name "page1.jpg" | Out-Null
$resultS1 = Get-SeriesChapters -SeriesPath $seriesS1 -QualifyingExtensions $imgExts
Test-Assert ($resultS1 -is [System.Collections.Generic.List[hashtable]]) ("1-chapter series result is still a real List[hashtable], not a bare Hashtable (actual type: " + $resultS1.GetType().FullName + ")")
Test-Assert ($resultS1.Count -eq 1) "1-chapter series Count is 1 (not silently missing via collapse)"
Test-Assert ($resultS1[0].Dir.FullName -eq $chapterS1) "indexing [0] on the 1-result list still works correctly"
Write-Host ""

# ==============================================================================
#  Scenario T: Get-SeriesChapters - multi-chapter scan, and confirms the
#  SAME guards Get-ZippableLeafDirs applies (former-container guard) are
#  genuinely in effect here too, not just in principle - reusing
#  Get-ZippableLeafDirs internally means this should be automatic, but
#  verified live rather than assumed.
# ==============================================================================
Write-Host "=== Scenario T: Get-SeriesChapters - multi-chapter scan + guard reuse ===" -ForegroundColor Cyan
$seriesT = New-Dir "scenario-t-series"
$chapter1T = New-Dir "scenario-t-series\Chapter 1"
New-FileIn -DirPath $chapter1T -Name "page1.jpg" | Out-Null
$chapter2T = New-Dir "scenario-t-series\Chapter 2"
New-FileIn -DirPath $chapter2T -Name "page1.jpg" | Out-Null
$formerContainerT = New-Dir "scenario-t-series\Old Chapter"
New-FileIn -DirPath $formerContainerT -Name "Old Chapter.zip" | Out-Null

$resultT = Get-SeriesChapters -SeriesPath $seriesT -QualifyingExtensions $imgExts
Test-Assert ($resultT.Count -eq 2) ("exactly the 2 genuine chapters were found, former-container excluded (got " + $resultT.Count + ")")
$foundNamesT = @($resultT | ForEach-Object { $_.Dir.Name } | Sort-Object)
Test-Assert (($foundNamesT -join "|") -eq "Chapter 1|Chapter 2") "the correct 2 chapters were found, by name"
Write-Host ""

# ==============================================================================
#  Scenario T2 (2026-09-15 fix, real bug): a series folder that no longer
#  exists (deleted/renamed in the real TOCTOU window between
#  New-SeriesProvider listing it and Get-SeriesChapters actually
#  scanning it) must degrade to an empty result with a logged Warn, not
#  throw and kill the whole chapter-dispatch loop for every OTHER
#  series too.
# ==============================================================================
Write-Host "=== Scenario T2: Get-SeriesChapters on a vanished series folder degrades gracefully ===" -ForegroundColor Cyan
$seriesT2 = Join-Path $scratchDir "scenario-t2-series-does-not-exist"

$script:logMessages.Clear()
$threwT2 = $false
$resultT2 = $null
try {
    $resultT2 = Get-SeriesChapters -SeriesPath $seriesT2 -QualifyingExtensions $imgExts
} catch {
    $threwT2 = $true
}
Test-Assert (-not $threwT2) "Get-SeriesChapters did not throw for a vanished series folder"
Test-Assert ($resultT2.Count -eq 0) "a vanished series folder returns an empty (not `$null) chapter list"
Test-Assert (($script:logMessages | Where-Object { $_ -like "*$seriesT2*" }).Count -ge 1) "a Warn was logged naming the vanished series folder"
Write-Host ""

# ==============================================================================
#  Scenario U: integration - New-SeriesProvider + Get-SeriesChapters paired
#  together across a small library, mimicking how a real caller (mode 1's
#  restructured orchestration) would actually use the two-tier model: walk
#  the library lazily series by series, and for each one, get its real
#  chapter count via an eager per-series scan - exactly what
#  Start-SeriesProgress's -TotalChapters needs.
# ==============================================================================
Write-Host "=== Scenario U: two-tier integration - series provider + per-series chapter scan ===" -ForegroundColor Cyan
$libraryU = New-Dir "scenario-u-library"
$seriesU1 = New-Dir "scenario-u-library\Series One"
New-Dir "scenario-u-library\Series One\Chapter 1" | ForEach-Object { New-FileIn -DirPath $_ -Name "page1.jpg" | Out-Null }
New-Dir "scenario-u-library\Series One\Chapter 2" | ForEach-Object { New-FileIn -DirPath $_ -Name "page1.jpg" | Out-Null }
New-Dir "scenario-u-library\Series One\Chapter 3" | ForEach-Object { New-FileIn -DirPath $_ -Name "page1.jpg" | Out-Null }
$seriesU2 = New-Dir "scenario-u-library\Series Two"
New-Dir "scenario-u-library\Series Two\Chapter 1" | ForEach-Object { New-FileIn -DirPath $_ -Name "page1.jpg" | Out-Null }

$seriesProviderU = New-SeriesProvider -LibraryPath $libraryU -QualifyingExtensions $imgExts
$perSeriesCountsU = @{}
while ($true) {
    $series = & $seriesProviderU
    if ($null -eq $series) { break }
    $chapters = Get-SeriesChapters -SeriesPath $series.FullName -QualifyingExtensions $imgExts
    $perSeriesCountsU[$series.Name] = $chapters.Count
}

Test-Assert ($perSeriesCountsU.Count -eq 2) ("both series were walked and scanned (got " + $perSeriesCountsU.Count + ")")
Test-Assert ($perSeriesCountsU["Series One"] -eq 3) ("Series One's real chapter total is 3 (got " + $perSeriesCountsU["Series One"] + ") - exactly what Start-SeriesProgress -TotalChapters needs")
Test-Assert ($perSeriesCountsU["Series Two"] -eq 1) ("Series Two's real chapter total is 1 (got " + $perSeriesCountsU["Series Two"] + ")")
Write-Host ""

# ==============================================================================
#  Scenario V: New-ZippableLeafDirProvider survives a permission-denied
#  directory - real bug fix (2026-08-28, see Todo.md/CHANGELOG.md). Before
#  the stack-based rewrite, the old single flat AllDirectories enumerator
#  threw on the FIRST inaccessible directory anywhere in the tree and
#  could never resume, silently abandoning everything past that point -
#  verified live during the review with the exact icacls setup below: the
#  batch path (Get-ZippableLeafDirs) found candidates on both sides of a
#  denied folder, the incremental provider found nothing past it. Real
#  NTFS permissions via icacls, not a mock - a fake/mocked
#  UnauthorizedAccessException wouldn't prove the real .NET enumerator
#  actually throws where this scenario expects it to.
# ==============================================================================
Write-Host "=== Scenario V: incremental provider survives a real permission-denied directory ===" -ForegroundColor Cyan
$libraryV = Join-Path $scratchDir "scenario-v"
$deniedV  = Join-Path $libraryV "denied-sub"
$beforeV  = Join-Path $libraryV "a-allowed-before"
$afterV   = Join-Path $libraryV "z-allowed-after"
New-Item -ItemType Directory -Path $deniedV -Force | Out-Null
New-Item -ItemType Directory -Path $beforeV -Force | Out-Null
New-Item -ItemType Directory -Path $afterV -Force | Out-Null
"x" | Out-File -LiteralPath (Join-Path $beforeV "page1.jpg") -Encoding ASCII
"x" | Out-File -LiteralPath (Join-Path $afterV "page1.jpg") -Encoding ASCII

$userV = "$env:USERDOMAIN\$env:USERNAME"
$icaclsOutV = icacls $deniedV /deny "${userV}:(RX)" 2>&1
$icaclsOkV = ($LASTEXITCODE -eq 0)

if (-not $icaclsOkV) {
    Write-Host "  [SKIP] icacls could not deny access in this environment - skipping Scenario V's real-permission assertions" -ForegroundColor Yellow
} else {
    try {
        $providerV = New-ZippableLeafDirProvider -ScanPath $libraryV -QualifyingExtensions $imgExts
        $foundV = [System.Collections.Generic.List[string]]::new()
        $i = 0
        while ($i -lt 10) {
            $r = & $providerV
            if ($null -eq $r) { break }
            $foundV.Add($r.Dir.Name)
            $i++
        }
        Test-Assert ($foundV.Contains("a-allowed-before")) "the candidate BEFORE the denied folder was still found"
        Test-Assert ($foundV.Contains("z-allowed-after")) "the exact bug this closes: the candidate AFTER the denied folder was ALSO found, not silently abandoned"
        Test-Assert ($foundV.Count -eq 2) ("exactly the 2 real candidates were found, nothing extra (got " + $foundV.Count + ")")
    } finally {
        icacls $deniedV /remove:d $userV 2>&1 | Out-Null
    }
}
Write-Host ""

# ==============================================================================
#  Scenario W: Get-FilesRecursiveSafe (2026-09-10, added with no dedicated
#  coverage of its own during the Full Pipeline hang fix - caught by
#  /code-review medium, real gap given this function's own resilience
#  claims are exactly the kind of thing this project's history shows
#  needs a real test, not just reasoning). Two parts: basic recursive
#  discovery (multiple levels, confirms it isn't accidentally
#  single-level), and the same real icacls permission-denial pattern
#  Scenario V above uses - proves content on both sides of an
#  inaccessible directory is still found, the exact resilience property
#  a code-review pass also caught a real regression in (an earlier
#  version `continue`'d past a directory's own subdirectory walk after
#  its file walk failed, silently dropping that whole subtree - fixed
#  before this scenario was even written, but this scenario is what
#  should catch a REGRESSION of that fix later).
# ==============================================================================
Write-Host "=== Scenario W: Get-FilesRecursiveSafe - basic recursive discovery ===" -ForegroundColor Cyan
$libraryW = Join-Path $scratchDir "scenario-w"
$subW1 = Join-Path $libraryW "sub1"
$subW2 = Join-Path (Join-Path $libraryW "sub1") "sub2"
New-Item -ItemType Directory -Path $subW2 -Force | Out-Null
"x" | Out-File -LiteralPath (Join-Path $libraryW "root.txt") -Encoding ASCII
"x" | Out-File -LiteralPath (Join-Path $subW1 "level1.txt") -Encoding ASCII
"x" | Out-File -LiteralPath (Join-Path $subW2 "level2.txt") -Encoding ASCII

$foundW = Get-FilesRecursiveSafe -ScanPath $libraryW
$foundNamesW = @($foundW | ForEach-Object { $_.Name })
Test-Assert ($foundW.Count -eq 3) ("all 3 files across all levels were found (got " + $foundW.Count + ")")
Test-Assert ($foundNamesW -contains "root.txt" -and $foundNamesW -contains "level1.txt" -and $foundNamesW -contains "level2.txt") "files at every depth (root, 1 level down, 2 levels down) were all found"
Write-Host ""

Write-Host "=== Scenario W2: Get-FilesRecursiveSafe survives a real permission-denied directory ===" -ForegroundColor Cyan
$libraryW2 = Join-Path $scratchDir "scenario-w2"
$deniedW2  = Join-Path $libraryW2 "denied-sub"
$beforeW2  = Join-Path $libraryW2 "a-allowed-before"
$afterW2   = Join-Path $libraryW2 "z-allowed-after"
New-Item -ItemType Directory -Path $deniedW2 -Force | Out-Null
New-Item -ItemType Directory -Path $beforeW2 -Force | Out-Null
New-Item -ItemType Directory -Path $afterW2 -Force | Out-Null
"x" | Out-File -LiteralPath (Join-Path $deniedW2 "hidden.txt") -Encoding ASCII
"x" | Out-File -LiteralPath (Join-Path $beforeW2 "before.txt") -Encoding ASCII
"x" | Out-File -LiteralPath (Join-Path $afterW2 "after.txt") -Encoding ASCII

$userW2 = "$env:USERDOMAIN\$env:USERNAME"
$icaclsOutW2 = icacls $deniedW2 /deny "${userW2}:(RX)" 2>&1
$icaclsOkW2 = ($LASTEXITCODE -eq 0)

if (-not $icaclsOkW2) {
    Write-Host "  [SKIP] icacls could not deny access in this environment - skipping Scenario W2's real-permission assertions" -ForegroundColor Yellow
} else {
    try {
        $foundW2 = Get-FilesRecursiveSafe -ScanPath $libraryW2
        $foundNamesW2 = @($foundW2 | ForEach-Object { $_.Name })
        Test-Assert ($foundNamesW2 -contains "before.txt") "the file BEFORE the denied folder was still found"
        Test-Assert ($foundNamesW2 -contains "after.txt") "the exact bug this closes: the file AFTER the denied folder was ALSO found, not silently abandoned"
        Test-Assert ($foundNamesW2 -notcontains "hidden.txt") "the file INSIDE the denied folder was correctly NOT found (real access denial, not a mock)"
    } finally {
        icacls $deniedW2 /remove:d $userW2 2>&1 | Out-Null
    }
}
Write-Host ""

# ==============================================================================
#  Scenario W3 (2026-09-15 fix, real bug found by the full line-by-line
#  review series): a junction pointing back at an ancestor directory used
#  to make every one of these stack-walk traversals loop, multiplying
#  every file under the cycle once per loop - live-reproduced by a
#  reviewer as 64 duplicate candidates for one real chapter before the
#  synthesized path length finally exceeded MAX_PATH. Junctions don't
#  need admin rights on Windows (unlike symlinks), so this is a real,
#  unprivileged repro, not a mock.
# ==============================================================================
Write-Host "=== Scenario W3: Get-FilesRecursiveSafe does not loop through a junction cycle ===" -ForegroundColor Cyan
$libraryW3 = Join-Path $scratchDir "scenario-w3"
$subW3     = Join-Path $libraryW3 "sub"
New-Item -ItemType Directory -Path $subW3 -Force | Out-Null
"x" | Out-File -LiteralPath (Join-Path $libraryW3 "root.txt") -Encoding ASCII
"x" | Out-File -LiteralPath (Join-Path $subW3 "sub.txt") -Encoding ASCII

$junctionW3 = Join-Path $subW3 "loop-back"
$mklinkOutW3 = cmd /c mklink /J "`"$junctionW3`"" "`"$libraryW3`"" 2>&1
$junctionOkW3 = (Test-Path -LiteralPath $junctionW3)

if (-not $junctionOkW3) {
    Write-Host "  [SKIP] could not create a real junction in this environment - skipping Scenario W3's assertions" -ForegroundColor Yellow
} else {
    $foundW3 = Get-FilesRecursiveSafe -ScanPath $libraryW3
    $foundNamesW3 = @($foundW3 | ForEach-Object { $_.Name })
    Test-Assert (($foundNamesW3 | Where-Object { $_ -eq "root.txt" }).Count -eq 1) ("root.txt was found exactly once, not once per loop through the junction (got " + (($foundNamesW3 | Where-Object { $_ -eq "root.txt" }).Count) + ")")
    Test-Assert (($foundNamesW3 | Where-Object { $_ -eq "sub.txt" }).Count -eq 1) ("sub.txt was found exactly once (got " + (($foundNamesW3 | Where-Object { $_ -eq "sub.txt" }).Count) + ")")
}
Write-Host ""

# ==============================================================================
#  Scenario X (2026-09-15 fix, same bug, the other two traversals):
#  Get-ZippableLeafDirs and New-ZippableLeafDirProvider must not multiply
#  candidates through the same kind of junction cycle either.
# ==============================================================================
Write-Host "=== Scenario X: Get-ZippableLeafDirs / New-ZippableLeafDirProvider do not loop through a junction cycle ===" -ForegroundColor Cyan
$libraryX = Join-Path $scratchDir "scenario-x"
$chapterX = Join-Path $libraryX "Chapter 1"
New-Item -ItemType Directory -Path $chapterX -Force | Out-Null
"x" | Out-File -LiteralPath (Join-Path $chapterX "page1.jpg") -Encoding ASCII

$junctionX = Join-Path $libraryX "loop-back"
$mklinkOutX = cmd /c mklink /J "`"$junctionX`"" "`"$libraryX`"" 2>&1
$junctionOkX = (Test-Path -LiteralPath $junctionX)

if (-not $junctionOkX) {
    Write-Host "  [SKIP] could not create a real junction in this environment - skipping Scenario X's assertions" -ForegroundColor Yellow
} else {
    $foundX = Get-ZippableLeafDirs -ScanPath $libraryX -QualifyingExtensions @(".jpg")
    $matchingX = @($foundX | Where-Object { $_.Dir.Name -eq "Chapter 1" })
    Test-Assert ($matchingX.Count -eq 1) ("Get-ZippableLeafDirs found 'Chapter 1' exactly once, not once per loop through the junction (got " + $matchingX.Count + ")")

    $providerX = New-ZippableLeafDirProvider -ScanPath $libraryX -QualifyingExtensions @(".jpg")
    $yieldedX = [System.Collections.Generic.List[hashtable]]::new()
    $callCountX = 0
    while ($true) {
        $callCountX++
        if ($callCountX -gt 200) { throw "Scenario X: New-ZippableLeafDirProvider did not terminate after 200 calls - possible infinite loop through the junction." }
        $nextX = & $providerX
        if ($null -eq $nextX) { break }
        $yieldedX.Add($nextX)
    }
    $matchingProviderX = @($yieldedX | Where-Object { $_.Dir.Name -eq "Chapter 1" })
    Test-Assert ($matchingProviderX.Count -eq 1) ("New-ZippableLeafDirProvider yielded 'Chapter 1' exactly once, not once per loop through the junction (got " + $matchingProviderX.Count + ")")
}
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
