<#
    Static checks for the PowerShell traps this project has actually been
    bitten by - see "Lessons learned". Five bugs, all the same species:
    code that reads correctly and behaves otherwise. Four of the five leave
    a detectable trace in the source, so they're worth catching by grep
    instead of by a live-debugging session.

    Scans Modules\*.ps1 and Tools\*.ps1 (not _Harness or _Reference).

    Suppressing a finding, when the code is deliberately written that way:
      - put "# lint:ignore" on the offending line, or
      - add it to $script:LintKnownExceptions below with a reason.
    Prefer the inline marker; the list is for cases where the module is
    verified and shouldn't be touched just to add a comment.
#>

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# file (leaf name) + rule + why. Anything listed here is a KNOWN, decided
# case - not a backlog. If it isn't deliberate, fix the code instead.
$script:LintKnownExceptions = @(
    @{ File = 'CleanConsoleRendering.ps1'
       Rule = 'collection-return'
       Why  = 'Split-TextToWidth / Format-SeriesLines deliberately omit the comma guard because their harness wraps every call in @() - documented in CLAUDE.md' }
)

$script:passCount = 0
$script:failCount = 0

function Test-Assert {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:passCount++
        Write-Host ("  [PASS] " + $Message) -ForegroundColor Green
    } else {
        $script:failCount++
        Write-Host ("  [FAIL] " + $Message) -ForegroundColor Red
    }
}

function Test-IsExcepted {
    param([string]$FileName, [string]$Rule)
    foreach ($e in $script:LintKnownExceptions) {
        if ($e.File -eq $FileName -and $e.Rule -eq $Rule) { return $true }
    }
    return $false
}

function Show-Findings {
    param([array]$Findings)
    foreach ($f in $Findings) {
        Write-Host ("         " + $f.File + ":" + $f.Line + "  " + $f.Text.Trim()) -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------------------
#  Gather sources
# ------------------------------------------------------------------------
$sourceFiles = @()
foreach ($dir in @((Join-Path $projectRoot "Modules"), (Join-Path $projectRoot "Tools"))) {
    if (Test-Path -LiteralPath $dir) {
        $sourceFiles += @(Get-ChildItem -LiteralPath $dir -Filter "*.ps1" -File |
            Where-Object { $_.Length -gt 0 })
    }
}

Write-Host "=== Lint: source scan ===" -ForegroundColor Cyan
Write-Host ("  scanning " + $sourceFiles.Count + " non-empty .ps1 files under Modules\ and Tools\")
# A lint that silently scans nothing passes vacuously - which is exactly
# the kind of quiet failure this project keeps getting bitten by.
Test-Assert ($sourceFiles.Count -ge 10) "the scan actually found source files to check"
Write-Host ""

$fileText = @{}
$fileLines = @{}
foreach ($file in $sourceFiles) {
    $fileText[$file.Name] = (Get-Content -LiteralPath $file.FullName -Raw)
    $fileLines[$file.Name] = @(Get-Content -LiteralPath $file.FullName)
}

function Get-LineFindings {
    param([string]$Rule, [scriptblock]$Predicate)
    $found = @()
    foreach ($name in $fileText.Keys) {
        if (Test-IsExcepted -FileName $name -Rule $Rule) { continue }
        $lines = $fileLines[$name]
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match '#\s*lint:ignore') { continue }
            # A comment describing a bug is not the bug. AbortPipeline's
            # docstring quotes the exact broken check it fixed, and the
            # first run of this lint duly flagged the explanation.
            if ($line -match '^\s*#') { continue }
            if (& $Predicate $line $name) {
                $found += @{ File = $name; Line = ($i + 1); Text = $line }
            }
        }
    }
    return ,$found
}

# ------------------------------------------------------------------------
#  Rule 1: returning a collection without the leading-comma guard
# ------------------------------------------------------------------------
# PowerShell enumerates an IEnumerable returned from a function, so a
# 1-element List collapses to its element and a 0-element one to $null.
Write-Host "=== Lint: collection returned without ',' guard ===" -ForegroundColor Cyan
$collectionVars = @{}
foreach ($name in $fileText.Keys) {
    $text = $fileText[$name]
    $names = @()
    foreach ($m in ([regex]::Matches($text, '\$(\w+)\s*=\s*New-Object\s+System\.Collections\.Generic\.List'))) {
        $names += $m.Groups[1].Value
    }
    foreach ($m in ([regex]::Matches($text, '\$(\w+)\s*=\s*@\('))) {
        $names += $m.Groups[1].Value
    }
    $collectionVars[$name] = @($names | Select-Object -Unique)
}

$rule1 = Get-LineFindings -Rule 'collection-return' -Predicate {
    param($line, $name)
    if ($line -notmatch '^\s*return\s+\$(\w+)\s*$') { return $false }
    return ($collectionVars[$name] -contains $matches[1])
}
Test-Assert (@($rule1).Count -eq 0) "no collection is returned without a leading-comma guard"
Show-Findings -Findings @($rule1)
Write-Host ""

# ------------------------------------------------------------------------
#  Rule 2: $null -eq <string param> used to mean "caller omitted this"
# ------------------------------------------------------------------------
# An omitted [string] parameter binds to '', never $null, so the check
# never fires. This shipped undetected in AbortPipeline for its whole life.
Write-Host "=== Lint: `$null test against a [string] parameter ===" -ForegroundColor Cyan
$stringParams = @{}
foreach ($name in $fileText.Keys) {
    $names = @()
    foreach ($m in ([regex]::Matches($fileText[$name], '\[string\]\s*\$(\w+)'))) {
        $names += $m.Groups[1].Value
    }
    $stringParams[$name] = @($names | Select-Object -Unique)
}

$rule2 = Get-LineFindings -Rule 'null-string-param' -Predicate {
    param($line, $name)
    foreach ($p in $stringParams[$name]) {
        if ($line -match ('\$null\s*-eq\s*\$' + [regex]::Escape($p) + '\b')) { return $true }
        if ($line -match ('\$' + [regex]::Escape($p) + '\s*-eq\s*\$null\b')) { return $true }
    }
    return $false
}
Test-Assert (@($rule2).Count -eq 0) "no [string] parameter is tested against `$null to detect omission"
Show-Findings -Findings @($rule2)
Write-Host ""

# ------------------------------------------------------------------------
#  Rule 3: Where-Object result consumed via .Count without @()
# ------------------------------------------------------------------------
# A single match collapses to the item itself, and a Hashtable has its own
# .Count (its key count), so the check silently measures the wrong thing.
Write-Host "=== Lint: Where-Object piped into .Count without @() ===" -ForegroundColor Cyan
$rule3 = Get-LineFindings -Rule 'where-count' -Predicate {
    param($line, $name)
    if ($line -notmatch 'Where-Object') { return $false }
    if ($line -notmatch '\.Count\b') { return $false }
    return ($line -notmatch '@\(')
}
Test-Assert (@($rule3).Count -eq 0) "no Where-Object result is counted without @() around it"
Show-Findings -Findings @($rule3)
Write-Host ""

# ------------------------------------------------------------------------
#  Rule 4: the same $script: name assigned by more than one module
# ------------------------------------------------------------------------
# REPORT ONLY - deliberately not an assertion. The original bug ($script:
# consoleQueue silently killing console output) was a name collision, so
# this looks like it should fail the build. It can't: this codebase
# re-uses script-scope names across modules ON PURPOSE. A runspace worker
# has its own isolated scope, so ZipPipeline re-establishes the same names
# Logging.ps1 owns, which is the established pattern, not a defect.
# Failing on that would mean excepting half the modules and hollowing the
# rule out. Printing it keeps a genuinely surprising new pair visible
# without crying wolf on the architecture.
Write-Host "=== Lint (note only): `$script: names assigned in more than one module ===" -ForegroundColor Cyan
$owners = @{}
foreach ($name in $fileText.Keys) {
    if (Test-IsExcepted -FileName $name -Rule 'script-var-collision') { continue }
    foreach ($m in ([regex]::Matches($fileText[$name], '\$script:(\w+)\s*='))) {
        $varName = $m.Groups[1].Value
        if (-not $owners.ContainsKey($varName)) { $owners[$varName] = @() }
        if ($owners[$varName] -notcontains $name) { $owners[$varName] += $name }
    }
}
$collisions = @()
foreach ($varName in $owners.Keys) {
    if (@($owners[$varName]).Count -gt 1) {
        $collisions += @{ Name = $varName; Files = ($owners[$varName] -join ", ") }
    }
}
if (@($collisions).Count -eq 0) {
    Write-Host "  (none)" -ForegroundColor DarkGray
} else {
    foreach ($c in $collisions) {
        Write-Host ("  note: `$script:" + $c.Name + "  in  " + $c.Files) -ForegroundColor DarkGray
    }
    Write-Host ("  " + @($collisions).Count + " shared name(s). Expected for runspace-worker bootstraps;") -ForegroundColor DarkGray
    Write-Host "  worth a look if a pair here isn't one of those." -ForegroundColor DarkGray
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

if ($script:failCount -gt 0) { exit 1 } else { exit 0 }
