<#
.SYNOPSIS
    Standalone test harness for Modules\FileDeletion.ps1.

.DESCRIPTION
    Dot-sources the real module (not a reimplementation) and exercises it
    against real files/folders in a scratch temp directory - not mocked
    I/O - so it tests actual behavior, not a guess at it. Scenario G goes
    one step further and verifies via the Windows Shell.Application COM
    object that Move-ToRecycleBin's target genuinely lands in the Recycle
    Bin (recoverable), not just "gone from its original location" - the
    same check Test-Path alone can't distinguish from
    Remove-ItemPermanently's behavior.

.EXAMPLE
    .\Modules\_Harness\FileDeletion.Harness.ps1
#>

$ErrorActionPreference = "Stop"

# Real Logging.ps1 for Get-WorkerRunspaceValue (Remove-Source's Permanent
# Delete lookup) - Scenario P needs the real $global: fallback, not a stub.
. (Join-Path $PSScriptRoot "..\Logging.ps1")
. (Join-Path $PSScriptRoot "..\FileDeletion.ps1")

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

$scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("filedeletion-harness-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
Write-Host ("Scratch dir: " + $scratchDir) -ForegroundColor DarkGray
Write-Host ""

function New-ScratchFile {
    param([string]$Name, [string]$Content = "scratch content")
    $path = Join-Path $scratchDir $Name
    $Content | Out-File -FilePath $path -Encoding UTF8
    return $path
}

function New-ScratchDir {
    param([string]$Name)
    $path = Join-Path $scratchDir $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    "nested content" | Out-File -FilePath (Join-Path $path "nested.txt") -Encoding UTF8
    return $path
}

function Test-ItemInRecycleBin {
    <#
    .SYNOPSIS
        Real check (not simulated) - true if an item named $FileName
        currently exists in the Windows Recycle Bin, via the
        Shell.Application COM object (Namespace 10 = Recycle Bin).
    #>
    param([string]$FileName)
    $shell = New-Object -ComObject Shell.Application
    $recycleBin = $shell.Namespace(10)
    $found = $false
    foreach ($item in $recycleBin.Items()) {
        if ($item.Name -eq $FileName) { $found = $true; break }
    }
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($recycleBin) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
    return $found
}

# ==============================================================================
#  Scenario A: Move-ToRecycleBin removes a file from its original location
# ==============================================================================
Write-Host "=== Scenario A: Move-ToRecycleBin removes a file ===" -ForegroundColor Cyan
$fileA = New-ScratchFile -Name "scenario-a.txt"
Test-Assert (Test-Path -LiteralPath $fileA) "file exists before Move-ToRecycleBin"
$resultA = Move-ToRecycleBin -ItemPath $fileA
Test-Assert (-not (Test-Path -LiteralPath $fileA)) "file is gone from its original location after Move-ToRecycleBin"
Test-Assert ($resultA -eq $true) "Move-ToRecycleBin returns `$true when it actually processed an existing item"
Write-Host ""

# ==============================================================================
#  Scenario B: Move-ToRecycleBin removes a directory (with nested contents)
# ==============================================================================
Write-Host "=== Scenario B: Move-ToRecycleBin removes a directory ===" -ForegroundColor Cyan
$dirB = New-ScratchDir -Name "scenario-b-dir"
Test-Assert (Test-Path -LiteralPath $dirB) "directory exists before Move-ToRecycleBin"
$resultB = Move-ToRecycleBin -ItemPath $dirB
Test-Assert (-not (Test-Path -LiteralPath $dirB)) "directory (with nested contents) is gone after Move-ToRecycleBin"
Test-Assert ($resultB -eq $true) "Move-ToRecycleBin returns `$true when it actually processed an existing directory"
Write-Host ""

# ==============================================================================
#  Scenario C: Move-ToRecycleBin on a nonexistent path is a silent no-op
# ==============================================================================
Write-Host "=== Scenario C: Move-ToRecycleBin on a nonexistent path ===" -ForegroundColor Cyan
$missingC = Join-Path $scratchDir "does-not-exist.txt"
$threwC = $false
$resultC = $null
try { $resultC = Move-ToRecycleBin -ItemPath $missingC } catch { $threwC = $true }
Test-Assert (-not $threwC) "Move-ToRecycleBin on a nonexistent path does not throw"
Test-Assert ($resultC -eq $false) "Move-ToRecycleBin returns `$false for a nonexistent path"
Write-Host ""

# ==============================================================================
#  Scenario D: Remove-ItemPermanently removes a file from its original location
# ==============================================================================
Write-Host "=== Scenario D: Remove-ItemPermanently removes a file ===" -ForegroundColor Cyan
$fileD = New-ScratchFile -Name "scenario-d.txt"
Test-Assert (Test-Path -LiteralPath $fileD) "file exists before Remove-ItemPermanently"
$resultD = Remove-ItemPermanently -ItemPath $fileD
Test-Assert (-not (Test-Path -LiteralPath $fileD)) "file is gone from its original location after Remove-ItemPermanently"
Test-Assert ($resultD -eq $true) "Remove-ItemPermanently returns `$true when it actually processed an existing item"
Write-Host ""

# ==============================================================================
#  Scenario E: Remove-ItemPermanently removes a directory (with nested contents)
# ==============================================================================
Write-Host "=== Scenario E: Remove-ItemPermanently removes a directory ===" -ForegroundColor Cyan
$dirE = New-ScratchDir -Name "scenario-e-dir"
Test-Assert (Test-Path -LiteralPath $dirE) "directory exists before Remove-ItemPermanently"
$resultE = Remove-ItemPermanently -ItemPath $dirE
Test-Assert (-not (Test-Path -LiteralPath $dirE)) "directory (with nested contents) is gone after Remove-ItemPermanently"
Test-Assert ($resultE -eq $true) "Remove-ItemPermanently returns `$true when it actually processed an existing directory"
Write-Host ""

# ==============================================================================
#  Scenario F: Remove-ItemPermanently on a nonexistent path is a silent no-op
# ==============================================================================
Write-Host "=== Scenario F: Remove-ItemPermanently on a nonexistent path ===" -ForegroundColor Cyan
$missingF = Join-Path $scratchDir "also-does-not-exist.txt"
$threwF = $false
$resultF = $null
try { $resultF = Remove-ItemPermanently -ItemPath $missingF } catch { $threwF = $true }
Test-Assert (-not $threwF) "Remove-ItemPermanently on a nonexistent path does not throw"
Test-Assert ($resultF -eq $false) "Remove-ItemPermanently returns `$false for a nonexistent path"
Write-Host ""

# ==============================================================================
#  Scenario G: Move-ToRecycleBin's target is genuinely recoverable in the
#  real Windows Recycle Bin - not just "gone from disk" (which alone
#  wouldn't distinguish it from Remove-ItemPermanently). Uses a
#  guid-stamped filename so the Shell.Application lookup is unambiguous
#  even if the Recycle Bin already has other items in it.
# ==============================================================================
Write-Host "=== Scenario G: Move-ToRecycleBin target actually lands in the Recycle Bin ===" -ForegroundColor Cyan
$uniqueNameG = "filedeletion-harness-" + [guid]::NewGuid().ToString("N") + ".txt"
$fileG = New-ScratchFile -Name $uniqueNameG
$null = Move-ToRecycleBin -ItemPath $fileG
$foundInBinG = Test-ItemInRecycleBin -FileName $uniqueNameG
Test-Assert $foundInBinG "Move-ToRecycleBin's target is found in the real Windows Recycle Bin (genuinely recoverable, not just deleted)"
Write-Host ""

# ==============================================================================
#  Scenario H: Remove-Source routes to Move-ToRecycleBin when
#  $PermanentDelete is $false (default). Verified via a temporary
#  call-tracking override, not just a filesystem side effect, so the
#  routing decision itself is what's being tested.
# ==============================================================================
Write-Host "=== Scenario H: Remove-Source routes to Move-ToRecycleBin ===" -ForegroundColor Cyan
Initialize-FileDeletion -PermanentDelete $false

$script:moveCallsH = [System.Collections.Generic.List[string]]::new()
$script:permCallsH = [System.Collections.Generic.List[string]]::new()
$originalMove = ${function:Move-ToRecycleBin}
$originalPerm = ${function:Remove-ItemPermanently}
function Move-ToRecycleBin     { param([string]$ItemPath) $script:moveCallsH.Add($ItemPath); return $true }
function Remove-ItemPermanently { param([string]$ItemPath) $script:permCallsH.Add($ItemPath); return $true }

$resultH = Remove-Source -ItemPath "C:\Fake\Path\For\Routing\Test.txt"

Test-Assert ($script:moveCallsH.Count -eq 1) "Remove-Source called Move-ToRecycleBin exactly once when PermanentDelete=`$false"
Test-Assert ($script:permCallsH.Count -eq 0) "Remove-Source did NOT call Remove-ItemPermanently when PermanentDelete=`$false"
Test-Assert ($resultH -eq $true) "Remove-Source propagates the chosen branch's return value"

${function:Move-ToRecycleBin}     = $originalMove
${function:Remove-ItemPermanently} = $originalPerm
Write-Host ""

# ==============================================================================
#  Scenario I: Remove-Source routes to Remove-ItemPermanently when
#  $PermanentDelete is $true. Same call-tracking technique as Scenario H.
# ==============================================================================
Write-Host "=== Scenario I: Remove-Source routes to Remove-ItemPermanently ===" -ForegroundColor Cyan
Initialize-FileDeletion -PermanentDelete $true

$script:moveCallsI = [System.Collections.Generic.List[string]]::new()
$script:permCallsI = [System.Collections.Generic.List[string]]::new()
$originalMove = ${function:Move-ToRecycleBin}
$originalPerm = ${function:Remove-ItemPermanently}
function Move-ToRecycleBin     { param([string]$ItemPath) $script:moveCallsI.Add($ItemPath); return $true }
function Remove-ItemPermanently { param([string]$ItemPath) $script:permCallsI.Add($ItemPath); return $true }

$resultI = Remove-Source -ItemPath "C:\Fake\Path\For\Routing\Test2.txt"

Test-Assert ($script:permCallsI.Count -eq 1) "Remove-Source called Remove-ItemPermanently exactly once when PermanentDelete=`$true"
Test-Assert ($script:moveCallsI.Count -eq 0) "Remove-Source did NOT call Move-ToRecycleBin when PermanentDelete=`$true"
Test-Assert ($resultI -eq $true) "Remove-Source propagates the chosen branch's return value"

${function:Move-ToRecycleBin}     = $originalMove
${function:Remove-ItemPermanently} = $originalPerm
Initialize-FileDeletion -PermanentDelete $false   # restore the default for any later scenario
Write-Host ""

# ==============================================================================
#  Scenario J: -ItemPath is Mandatory on all three functions. Checked via
#  parameter METADATA (Get-Command), not by actually calling each function
#  with -ItemPath omitted (2026-09-09 fix, a real bug caught live in a
#  sibling harness - DependencyDetection.Harness.ps1's own former Scenario
#  G): PowerShell only THROWS on a missing Mandatory parameter when it
#  can't prompt for one - when a real interactive console IS attached, it
#  instead blocks the whole process waiting on stdin for a human to type a
#  value, forever, with zero CPU/disk activity. Matches
#  ZipParallelProcessing.Harness.ps1's own Scenario E, which already
#  documented and avoided this exact host-dependent hang - checking
#  parameter metadata is host-independent, it can never hang in any
#  invocation context.
# ==============================================================================
Write-Host "=== Scenario J: -ItemPath is Mandatory ===" -ForegroundColor Cyan
function Test-ItemPathIsMandatoryJ {
    param([string]$FunctionName)
    $attr = (Get-Command $FunctionName).Parameters['ItemPath'].Attributes |
        Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | Select-Object -First 1
    return [bool]$attr.Mandatory
}
Test-Assert (Test-ItemPathIsMandatoryJ 'Move-ToRecycleBin') "-ItemPath is Mandatory on Move-ToRecycleBin"
Test-Assert (Test-ItemPathIsMandatoryJ 'Remove-ItemPermanently') "-ItemPath is Mandatory on Remove-ItemPermanently"
Test-Assert (Test-ItemPathIsMandatoryJ 'Remove-Source') "-ItemPath is Mandatory on Remove-Source"
Write-Host ""

# ==============================================================================
#  Scenario K: Remove-ItemPermanently on a directory junction (a reparse
#  point) must unlink the junction itself, NOT recurse into the real
#  target's contents. Directory.Delete(path, $true) on a reparse point is
#  a known .NET footgun - recursive=$true can delete through the link
#  into the target instead of just removing the link. Verified live with
#  a real NTFS junction (New-Item -ItemType Junction, no elevation
#  needed), not reasoned about from documentation - per this project's
#  "test, don't assume" philosophy, especially given this exact category
#  of bug (a plausible-sounding assumption about filesystem/.NET behavior
#  turning out wrong) has bitten this codebase before.
# ==============================================================================
Write-Host "=== Scenario K: Remove-ItemPermanently on a directory junction unlinks only ===" -ForegroundColor Cyan
$targetK  = New-ScratchDir -Name "scenario-k-real-target"
$canaryK  = Join-Path $targetK "canary.txt"
"do not delete me" | Out-File -FilePath $canaryK -Encoding UTF8
$junctionK = Join-Path $scratchDir "scenario-k-junction"
New-Item -ItemType Junction -Path $junctionK -Target $targetK | Out-Null
Test-Assert (Test-Path -LiteralPath $junctionK) "junction was created"

$null = Remove-ItemPermanently -ItemPath $junctionK

Test-Assert (-not (Test-Path -LiteralPath $junctionK)) "the junction itself is gone"
Test-Assert (Test-Path -LiteralPath $targetK) "the REAL target directory still exists (was not recursed into)"
Test-Assert (Test-Path -LiteralPath $canaryK) "the canary file inside the real target survives (proves this wasn't a recursive delete through the link)"
Write-Host ""

# ==============================================================================
#  Scenario K2 (2026-09-23, Todo.md item): a junction or read-only file
#  NESTED inside a folder being permanently deleted. Before the fix,
#  Directory.Delete($path, $true) threw part-way ("Access to the path
#  'link' is denied") and left the folder behind with the read-only file
#  still in it - confirmed live against the pre-fix module. The junction's
#  target was never deleted-through even then; this scenario proves the
#  replacement walk (Remove-DirectoryTreePermanently) keeps it that way:
#  unlinks nested reparse points, never recurses into them, and clears
#  ReadOnly only on real entries.
# ==============================================================================
Write-Host "=== Scenario K2: permanent delete of a folder with a nested junction + read-only files ===" -ForegroundColor Cyan
$targetK2 = New-ScratchDir -Name "scenario-k2-real-target"
$canaryK2 = Join-Path $targetK2 "canary.txt"
"do not delete me" | Out-File -FilePath $canaryK2 -Encoding UTF8
$victimK2 = New-ScratchDir -Name "scenario-k2-victim"
$subK2    = Join-Path $victimK2 "sub"
$roDirK2  = Join-Path $victimK2 "readonly-dir"
$null = [System.IO.Directory]::CreateDirectory($subK2)
$null = [System.IO.Directory]::CreateDirectory($roDirK2)
"a" | Out-File -FilePath (Join-Path $victimK2 "a.txt") -Encoding UTF8
"top ro" | Out-File -FilePath (Join-Path $victimK2 "top-ro.txt") -Encoding UTF8
"deep ro" | Out-File -FilePath (Join-Path $subK2 "deep-ro.txt") -Encoding UTF8
"in ro dir" | Out-File -FilePath (Join-Path $roDirK2 "x.txt") -Encoding UTF8
[System.IO.File]::SetAttributes((Join-Path $victimK2 "top-ro.txt"), [System.IO.FileAttributes]::ReadOnly)
[System.IO.File]::SetAttributes((Join-Path $subK2 "deep-ro.txt"), [System.IO.FileAttributes]::ReadOnly)
(New-Object System.IO.DirectoryInfo $roDirK2).Attributes = [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::ReadOnly
New-Item -ItemType Junction -Path (Join-Path $subK2 "link") -Target $targetK2 | Out-Null
$targetAttrBeforeK2 = [System.IO.File]::GetAttributes($targetK2)

$threwK2 = $null
$resultK2 = $null
try { $resultK2 = Remove-ItemPermanently -ItemPath $victimK2 } catch { $threwK2 = $_ }

Test-Assert ($null -eq $threwK2) ("the delete did not throw (got: " + $threwK2 + ")")
Test-Assert ($resultK2 -eq $true) "Remove-ItemPermanently returned `$true"
Test-Assert (-not (Test-Path -LiteralPath $victimK2)) "the whole folder is gone, nested junction and read-only entries included"
Test-Assert (Test-Path -LiteralPath $canaryK2) "the junction's real target and its canary file survive (never recursed into)"
Test-Assert ([System.IO.File]::GetAttributes($targetK2) -eq $targetAttrBeforeK2) "the junction target's own attributes were not touched"
Write-Host ""

# ==============================================================================
#  Scenario L: same concern, checked against Move-ToRecycleBin. Unlike
#  Remove-ItemPermanently's raw Directory.Delete, this goes through the
#  Shell-based VB FileIO Recycle Bin API - untested assumption otherwise,
#  so checked live rather than assumed safe just because the API is
#  different.
# ==============================================================================
Write-Host "=== Scenario L: Move-ToRecycleBin on a directory junction ===" -ForegroundColor Cyan
$targetL  = New-ScratchDir -Name "scenario-l-real-target"
$canaryL  = Join-Path $targetL "canary.txt"
"do not delete me either" | Out-File -FilePath $canaryL -Encoding UTF8
$junctionL = Join-Path $scratchDir "scenario-l-junction"
New-Item -ItemType Junction -Path $junctionL -Target $targetL | Out-Null
Test-Assert (Test-Path -LiteralPath $junctionL) "junction was created"

$null = Move-ToRecycleBin -ItemPath $junctionL

Test-Assert (-not (Test-Path -LiteralPath $junctionL)) "the junction itself is gone"
Test-Assert (Test-Path -LiteralPath $targetL) "the REAL target directory still exists (was not recursed into)"
Test-Assert (Test-Path -LiteralPath $canaryL) "the canary file inside the real target survives"
Write-Host ""

# ==============================================================================
#  Scenario M: a Hidden/System file or directory can actually be deleted
#  (2026-08-31 fix) - Get-Item -LiteralPath without -Force can't see a
#  Hidden/System item even though Test-Path (the guard both functions
#  already have) can, so it used to throw "Could not find item" for
#  something sitting right there, on all three real-world shapes: a
#  hidden file, a system file, and a hidden directory.
# ==============================================================================
Write-Host "=== Scenario M: Move-ToRecycleBin/Remove-ItemPermanently on Hidden/System items ===" -ForegroundColor Cyan

$hiddenFileM = Join-Path $scratchDir "scenario-m-hidden.txt"
"hidden content" | Out-File -FilePath $hiddenFileM -Encoding UTF8
(Get-Item -LiteralPath $hiddenFileM -Force).Attributes = [System.IO.FileAttributes]::Hidden
$null = Remove-ItemPermanently -ItemPath $hiddenFileM
Test-Assert (-not (Test-Path -LiteralPath $hiddenFileM)) "Remove-ItemPermanently deletes a Hidden file instead of throwing"

$systemFileM = Join-Path $scratchDir "scenario-m-system.txt"
"system content" | Out-File -FilePath $systemFileM -Encoding UTF8
(Get-Item -LiteralPath $systemFileM -Force).Attributes = [System.IO.FileAttributes]::System
$null = Remove-ItemPermanently -ItemPath $systemFileM
Test-Assert (-not (Test-Path -LiteralPath $systemFileM)) "Remove-ItemPermanently deletes a System file instead of throwing"

$hiddenDirM = Join-Path $scratchDir "scenario-m-hiddendir"
New-Item -ItemType Directory -Path $hiddenDirM | Out-Null
(Get-Item -LiteralPath $hiddenDirM -Force).Attributes = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::Directory
$null = Remove-ItemPermanently -ItemPath $hiddenDirM
Test-Assert (-not (Test-Path -LiteralPath $hiddenDirM)) "Remove-ItemPermanently deletes a Hidden directory instead of throwing"

$hiddenFileM2 = Join-Path $scratchDir "scenario-m-hidden-recycle.txt"
"hidden content 2" | Out-File -FilePath $hiddenFileM2 -Encoding UTF8
(Get-Item -LiteralPath $hiddenFileM2 -Force).Attributes = [System.IO.FileAttributes]::Hidden
$null = Move-ToRecycleBin -ItemPath $hiddenFileM2
Test-Assert (-not (Test-Path -LiteralPath $hiddenFileM2)) "Move-ToRecycleBin deletes a Hidden file instead of throwing"

# 2026-09-15 fix, real bug: [System.IO.File]::Delete throws
# UnauthorizedAccessException on a read-only file, which meant a
# read-only source survived right next to its already-converted .jxl
# and was misreported as a delete FAILURE.
$readOnlyFileM = Join-Path $scratchDir "scenario-m-readonly.txt"
"read-only content" | Out-File -FilePath $readOnlyFileM -Encoding UTF8
(Get-Item -LiteralPath $readOnlyFileM -Force).Attributes = [System.IO.FileAttributes]::ReadOnly
$resultM3 = Remove-ItemPermanently -ItemPath $readOnlyFileM
Test-Assert (-not (Test-Path -LiteralPath $readOnlyFileM)) "Remove-ItemPermanently deletes a read-only file instead of leaving it behind"
Test-Assert ($resultM3 -eq $true) "Remove-ItemPermanently reports the read-only file's deletion as a real success, not a failure"
Write-Host ""

# ==============================================================================
#  Scenario N (2026-09-03 fix, Todo.md finding - latent, not live: every
#  real call site already passes an absolute path): a RELATIVE -ItemPath
#  used to pass Test-Path (resolved against PowerShell's own $PWD/provider
#  location) but then get deleted via .NET/VB FileIO calls that resolve
#  relative paths against the PROCESS's real current directory instead -
#  which Push-Location/Set-Location does NOT change (only PowerShell's
#  own $PWD moves; [System.Environment]::CurrentDirectory does not,
#  confirmed live earlier this session by ZipPipeline.Harness.ps1's own
#  Scenario D3 hitting the identical gotcha). Both functions now resolve
#  -ItemPath via GetUnresolvedProviderPathFromPSPath FIRST, so the actual
#  delete always targets the exact same file Test-Path already confirmed
#  exists - proven here by Push-Location'ing somewhere PS $PWD and the
#  process CWD genuinely diverge, then passing a bare relative filename.
# ==============================================================================
Write-Host "=== Scenario N: a relative -ItemPath resolves against PowerShell's `$PWD, not a stale process CWD ===" -ForegroundColor Cyan
$relDirN = Join-Path $scratchDir "scenario-n"
New-Item -ItemType Directory -Path $relDirN -Force | Out-Null
$relFileN = Join-Path $relDirN "relative-target.txt"
"relative-path content" | Out-File -FilePath $relFileN -Encoding UTF8

Push-Location $relDirN
try {
    Test-Assert ((Get-Location).Path -eq (Get-Item -LiteralPath $relDirN).FullName) "sanity check: PowerShell's `$PWD is genuinely the scratch dir now"
    $null = Remove-ItemPermanently -ItemPath "relative-target.txt"
} finally {
    Pop-Location
}
Test-Assert (-not (Test-Path -LiteralPath $relFileN)) "Remove-ItemPermanently with a bare relative filename deleted the REAL file at PowerShell's `$PWD, not a stale/wrong location"

$relFileN2 = Join-Path $relDirN "relative-target-2.txt"
"relative-path content 2" | Out-File -FilePath $relFileN2 -Encoding UTF8
Push-Location $relDirN
try {
    $null = Move-ToRecycleBin -ItemPath "relative-target-2.txt"
} finally {
    Pop-Location
}
Test-Assert (-not (Test-Path -LiteralPath $relFileN2)) "Move-ToRecycleBin with a bare relative filename also resolves against PowerShell's `$PWD correctly"
Write-Host ""

# ==============================================================================
#  Scenario O (2026-09-03 fix, real bug caught by a same-session
#  /code-review pass on the fix above): a path on a drive letter that
#  isn't currently mounted must still degrade to $false, not throw.
#  GetUnresolvedProviderPathFromPSPath (unlike Test-Path) throws for a
#  path whose drive doesn't exist as a PowerShell drive at all - verified
#  live during that review against a genuinely unmounted letter. This
#  scenario finds a real unmounted letter on whatever machine it runs on
#  rather than hardcoding one, so it stays valid across environments.
# ==============================================================================
Write-Host "=== Scenario O: a path on an unmounted drive letter degrades to `$false, not a throw ===" -ForegroundColor Cyan
$unmountedLetterO = $null
foreach ($candidate in @('Z', 'Y', 'X', 'W', 'V', 'U', 'T')) {
    if (-not (Test-Path -LiteralPath ($candidate + ":\"))) { $unmountedLetterO = $candidate; break }
}
if ($null -eq $unmountedLetterO) {
    Write-Host "  (skipped - no unmounted drive letter found on this machine to test against)" -ForegroundColor DarkYellow
} else {
    $fakeUnmountedPathO = $unmountedLetterO + ":\nonexistent-dir\nonexistent-file.txt"
    $threwO1 = $false
    $resultO1 = $null
    try { $resultO1 = Move-ToRecycleBin -ItemPath $fakeUnmountedPathO } catch { $threwO1 = $true }
    Test-Assert (-not $threwO1) "Move-ToRecycleBin does not throw for a path on an unmounted drive"
    Test-Assert ($resultO1 -eq $false) "...and returns `$false, same as any other nonexistent path"

    $threwO2 = $false
    $resultO2 = $null
    try { $resultO2 = Remove-ItemPermanently -ItemPath $fakeUnmountedPathO } catch { $threwO2 = $true }
    Test-Assert (-not $threwO2) "Remove-ItemPermanently does not throw for a path on an unmounted drive either"
    Test-Assert ($resultO2 -eq $false) "...and also returns `$false"
}
Write-Host ""

# ==============================================================================
#  Scenario P (2026-09-22, the worker-state fix): Remove-Source honours
#  Permanent Delete inside a REAL runspace worker, including when called from
#  a .GetNewClosure()'d block created inside another propagated function
#  (the shape of every Full Pipeline job builder / [System.Lazy] factory).
#  There, a propagated function's $script: resolves to the closure's own
#  empty module scope - the old Remove-Source read $script:PermanentDelete
#  as $null and silently sent the file to the Recycle Bin instead
#  (confirmed against the pre-fix FileDeletion.ps1: the closure call took
#  the Recycle Bin branch). The two deletion primitives are recorders here,
#  so nothing real is deleted or recycled.
# ==============================================================================
Write-Host "=== Scenario P: Remove-Source honours Permanent Delete in a runspace closure ===" -ForegroundColor Cyan
function Invoke-HarnessRemoveSourceFromClosure {
    $closure = { Remove-Source -ItemPath "C:\not\a\real\file.png" }.GetNewClosure()
    return (& $closure)
}
$pIss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
foreach ($fn in @('Remove-Source', 'Get-WorkerRunspaceValue', 'Invoke-HarnessRemoveSourceFromClosure')) {
    $pIss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $fn, (Get-Item ("Function:\" + $fn)).Definition))
}
$pIss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList 'Remove-ItemPermanently', 'param($ItemPath) "permanent"'))
$pIss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList 'Move-ToRecycleBin', 'param($ItemPath) "recycle"'))
$pPool = [RunspaceFactory]::CreateRunspacePool(1, 1, $pIss, $Host)
$pPool.Open()
$pPs = [PowerShell]::Create()
$pPs.RunspacePool = $pPool
$null = $pPs.AddScript({
    $script:PermanentDelete = $true   # seeded exactly like the real worker bodies
    @{ Direct = (Remove-Source -ItemPath "C:\not\a\real\file.png"); Closure = (Invoke-HarnessRemoveSourceFromClosure) }
})
$pResult = @($pPs.Invoke())[0]
$pErrors = @($pPs.Streams.Error)
$pPs.Dispose()
$pPool.Close(); $pPool.Dispose()

Test-Assert ($pErrors.Count -eq 0) ("the worker ran without errors (got " + $pErrors.Count + ": " + ($pErrors -join '; ') + ")")
Test-Assert ($pResult.Direct -eq "permanent") "a direct worker Remove-Source call takes the permanent-delete branch"
Test-Assert ($pResult.Closure -eq "permanent") ("a worker Remove-Source call from inside a .GetNewClosure()'d block ALSO takes the permanent-delete branch (got '" + $pResult.Closure + "')")
Write-Host ""

# ==============================================================================
#  Scenario Q (2026-09-23, Todo.md item): Move-ToRecycleBin must NOT
#  silently delete permanently when an item can't actually be recycled.
#  The VB FileIO call with OnlyErrorDialogs (= no confirmation) deletes
#  such an item outright and returns normally - confirmed live 2026-09-23
#  with a 100 GB sparse file (over C:'s 97,350 MB Recycle Bin limit): the
#  call succeeded, the file was gone, and it was NOT in the Recycle Bin
#  (a small control file sent the same way WAS). Owner decision: leave it
#  in place instead. Uses a real sparse file just over this drive's
#  limit (logical size only - no real disk space) so the check runs
#  against the real Shell behavior boundary. Confirmed failing against the
#  pre-fix module (the file was deleted outright).
# ==============================================================================
Write-Host "=== Scenario Q: Move-ToRecycleBin leaves an unrecyclable item in place ===" -ForegroundColor Cyan
$capQ = [RecycleBinProbe]::GetCapacityBytes($scratchDir)
if ($capQ -le 0) {
    Write-Host "  [SKIP] this drive's Recycle Bin size limit isn't readable here - Q1/Q2 need it to size a too-big file" -ForegroundColor DarkYellow
} else {
    # Returns $false (and leaves nothing behind) unless the file really is
    # sparse - SetLength on a non-sparse file would allocate ~100 GB for real.
    function New-SparseFileQ {
        param([string]$Path, [long]$Length)
        [System.IO.File]::WriteAllBytes($Path, [byte[]]@())
        $null = & fsutil.exe sparse setflag $Path 2>$null
        if (-not ([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::SparseFile)) {
            [System.IO.File]::Delete($Path)
            return $false
        }
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite)
        try { $fs.SetLength($Length) } finally { $fs.Dispose() }
        return $true
    }
    $bigQ = Join-Path $scratchDir "scenario-q-too-big.bin"
    if (-not (New-SparseFileQ -Path $bigQ -Length ($capQ + 1GB))) {
        Write-Host "  [SKIP] %TEMP%'s volume can't make sparse files - skipping rather than allocate a real over-the-limit file" -ForegroundColor DarkYellow
        $capQ = 0
    }
}
if ($capQ -gt 0) {
    $threwQ1 = $null
    try { $null = Move-ToRecycleBin -ItemPath $bigQ } catch { $threwQ1 = "$_" }
    Test-Assert ($threwQ1 -like "Left in place*bigger than this drive*") ("a file over this drive's Recycle Bin limit is refused with a clear reason (got: " + $threwQ1 + ")")
    Test-Assert (Test-Path -LiteralPath $bigQ) "...and the file is still on disk, NOT silently deleted permanently"
    if (Test-Path -LiteralPath $bigQ) { [System.IO.File]::Delete($bigQ) }

    $dirQ = New-ScratchDir -Name "scenario-q-too-big-dir"
    $null = New-SparseFileQ -Path (Join-Path $dirQ "huge.bin") -Length ($capQ + 1GB)
    "small" | Out-File -FilePath (Join-Path $dirQ "small.txt") -Encoding UTF8
    $threwQ2 = $null
    try { $null = Move-ToRecycleBin -ItemPath $dirQ } catch { $threwQ2 = "$_" }
    Test-Assert ($threwQ2 -like "Left in place*") "a folder whose total size is over the limit is refused too"
    Test-Assert ((Test-Path -LiteralPath (Join-Path $dirQ "huge.bin")) -and (Test-Path -LiteralPath (Join-Path $dirQ "small.txt"))) "...and every file in it is still there"
    Remove-ItemPermanently -ItemPath $dirQ | Out-Null
}
Test-Assert ([RecycleBinProbe]::GetUnrecyclableReason('\\server\share\chapter\001.jpg') -like "*network share*") "a UNC path is recognized as having no Recycle Bin"
$smallQ = Join-Path $scratchDir "scenario-q-small.txt"
"small" | Out-File -FilePath $smallQ -Encoding UTF8
Test-Assert ($null -eq [RecycleBinProbe]::GetUnrecyclableReason($smallQ)) "a normal small local file is still considered recyclable (no false refusals)"
[System.IO.File]::Delete($smallQ)
Write-Host ""

# ==============================================================================
#  Scenario R (2026-09-23, /code-review findings): RecycleBinProbe's
#  network / removable / delete-immediately / policy branches, driven by
#  its test-only overrides (this PC has only fixed NTFS drives and none of
#  those settings), plus the up-front run refusal and the vanished-path
#  classifier the tree walk now uses.
# ==============================================================================
Write-Host "=== Scenario R: RecycleBinProbe branches via test overrides; run refusal; vanished-path classifier ===" -ForegroundColor Cyan
$smallR = Join-Path $scratchDir "scenario-r-small.txt"
"small" | Out-File -FilePath $smallR -Encoding UTF8
try {
    [RecycleBinProbe]::ResetTestOverrides()
    [RecycleBinProbe]::TestDriveType = 4
    Test-Assert ([RecycleBinProbe]::GetUnrecyclableReason($smallR) -like "*network drive*") "DRIVE_REMOTE (4) -> 'network drive' reason"
    [RecycleBinProbe]::TestDriveType = 2
    Test-Assert ([RecycleBinProbe]::GetUnrecyclableReason($smallR) -like "*removable drive*") "DRIVE_REMOVABLE (2) -> 'removable drive' reason"
    $threwR = $null
    try { $null = Move-ToRecycleBin -ItemPath $smallR } catch { $threwR = "$_" }
    Test-Assert ($threwR -like "Left in place*removable drive*" -and (Test-Path -LiteralPath $smallR)) "Move-ToRecycleBin leaves a file on a removable drive in place"
    [RecycleBinProbe]::TestDriveType = 3
    [RecycleBinProbe]::TestNukeOnDelete = $true
    Test-Assert ([RecycleBinProbe]::GetUnrecyclableReason($smallR) -like "*delete files immediately*") "a drive set to 'delete immediately' is refused"
    [RecycleBinProbe]::TestNukeOnDelete = $false
    [RecycleBinProbe]::TestPolicyNoRecycle = $true
    Test-Assert ([RecycleBinProbe]::GetUnrecyclableReason($smallR) -like "*turned off by policy*") "the NoRecycleFiles policy is refused"
    [RecycleBinProbe]::TestPolicyNoRecycle = $false
    [RecycleBinProbe]::TestCapacityBytes = 1
    Test-Assert ([RecycleBinProbe]::GetUnrecyclableReason($smallR) -like "*bigger than this drive*") "an item over a (forced tiny) size limit is refused"
    [RecycleBinProbe]::TestCapacityBytes = $null
    Test-Assert ($null -eq [RecycleBinProbe]::GetUnrecyclableReason($smallR)) "a fixed drive with none of those set is fine"

    [RecycleBinProbe]::TestDriveType = 4
    $refusalR = Get-RecycleBinRefusalMessage -TargetPath $scratchDir -PermanentDelete $false
    Test-Assert ($refusalR -like "Not starting*network drive*Permanent Delete*") ("a no-Recycle-Bin library with Permanent Delete off gets a refusal that says why and what to do (got: " + $refusalR + ")")
    Test-Assert ($null -eq (Get-RecycleBinRefusalMessage -TargetPath $scratchDir -PermanentDelete $true)) "...but not when Permanent Delete is on"
    [RecycleBinProbe]::TestDriveType = $null
    Test-Assert ($null -eq (Get-RecycleBinRefusalMessage -TargetPath $scratchDir -PermanentDelete $false)) "a local fixed-drive library is never refused"
} finally {
    [RecycleBinProbe]::ResetTestOverrides()
    if (Test-Path -LiteralPath $smallR) { [System.IO.File]::Delete($smallR) }
}

# Remove-DirectoryTreePermanently treats a child that vanishes mid-walk as
# already done (only the TOP-level item missing means "already gone"). The
# race itself can't be staged reliably here; this pins the classifier the
# walk and Invoke-DeleteTreatingVanishedAsFalse both use.
function New-ErrorRecordR { param([System.Exception]$Ex) return [System.Management.Automation.ErrorRecord]::new($Ex, "R", [System.Management.Automation.ErrorCategory]::NotSpecified, $null) }
$wrappedR = [System.Management.Automation.MethodInvocationException]::new("wrapped", [System.IO.FileNotFoundException]::new("gone"))
Test-Assert (Test-VanishedPathException -ErrorRecord (New-ErrorRecordR $wrappedR)) "a .NET FileNotFound wrapped in MethodInvocationException counts as vanished"
Test-Assert (Test-VanishedPathException -ErrorRecord (New-ErrorRecordR ([System.IO.DirectoryNotFoundException]::new("gone")))) "a bare DirectoryNotFound counts as vanished"
Test-Assert (-not (Test-VanishedPathException -ErrorRecord (New-ErrorRecordR ([System.UnauthorizedAccessException]::new("locked"))))) "access denied does NOT count as vanished - it still fails the delete"
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
