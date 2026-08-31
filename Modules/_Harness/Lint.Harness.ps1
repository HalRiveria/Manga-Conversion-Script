<#
    Static checks for the PowerShell traps this project has actually been
    bitten by - see "Lessons learned". Six bugs, all the same species:
    code that reads correctly and behaves otherwise. Five of the six leave
    a detectable trace in the source, so they're worth catching by grep
    (or, for Rule 5, real AST parsing) instead of by a live-debugging
    session.

    Scans Modules\*.ps1 and Tools\*.ps1 (not _Harness or _Reference).

    Suppressing a finding, when the code is deliberately written that way:
      - put "# lint:ignore" on the offending line, or
      - add it to $script:LintKnownExceptions below with a reason.
    Prefer the inline marker; the list is for cases where the module is
    verified and shouldn't be touched just to add a comment. Rule 5's
    findings are per-missing-name, not per-line (a -SharedFunctionNames
    array has no single "offending line" for one missing name among many),
    so its exceptions use the list's own -Names field instead of the
    inline marker - see Test-IsExceptedName below.
#>

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# file (leaf name) + rule + why. Anything listed here is a KNOWN, decided
# case - not a backlog. If it isn't deliberate, fix the code instead.
# -Names (Rule 5 only): specific missing function names this exception
# covers - a -SharedFunctionNames array can have other, real gaps besides
# the excepted one, so suppressing the whole File+Rule combination would
# hide those too.
$script:LintKnownExceptions = @(
    @{ File = 'CleanConsoleRendering.ps1'
       Rule = 'collection-return'
       Why  = 'Split-TextToWidth / Format-SeriesLines deliberately omit the comma guard because their harness wraps every call in @() - documented in CLAUDE.md' }
    @{ File  = 'Controller.ps1'
       Rule  = 'shared-function-names'
       Names = @('Write-GatedConsoleMessage')
       Why   = 'Controller.ps1 never passes -AbortWaitMessage to Convert-ImageBatch/Convert-AnimatedBatch, so their internal call to Write-GatedConsoleMessage is unreachable here - and propagating it would be actively unsafe (CleanConsoleRendering.ps1 state is never initialized inside this worker runspace) if that ever changed without a real fix. See CLAUDE.md Known-gaps history / CHANGELOG.md 2026-08-29.' }
    @{ File  = 'RezipPipeline.ps1'
       Rule  = 'shared-function-names'
       Names = @('Write-GatedConsoleMessage')
       Why   = 'Same reason as Controller.ps1''s own exception above - RezipPipeline.ps1 no longer passes -AbortWaitMessage to its worker-side Convert-ImageBatch call (fixed 2026-08-29, see CHANGELOG.md), so this call is unreachable, and propagating it would carry the same runspace-state-unsafe risk.' }
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

function Test-IsExceptedName {
    param([string]$FileName, [string]$Rule, [string]$Name)
    foreach ($e in $script:LintKnownExceptions) {
        if ($e.File -eq $FileName -and $e.Rule -eq $Rule -and $e.Names -and ($e.Names -contains $Name)) { return $true }
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

# ------------------------------------------------------------------------
#  Rule 5: -SharedFunctionNames array missing a function it transitively needs
# ------------------------------------------------------------------------
# Invoke-ZipParallelProcessing's -SharedFunctionNames only propagates
# function DEFINITIONS into a fresh runspace, not a module's own top-level
# script-scope state - so if a listed function (or the worker scriptblock
# itself) calls another user-defined function that isn't ALSO listed, that
# call throws "term not recognized" the first time the runspace actually
# reaches it. This bit this project four separate times in one session
# (Logging.ps1's helpers, FileDeletion.ps1's helper, then both animated/
# image conversion job-completion helpers - see CHANGELOG.md 2026-08-29),
# each caught only because a harness scenario happened to exercise the
# real runspace path. AST-based, not regex - reliably finding "what
# functions does this one call" needs a real parse, not a pattern match.
Write-Host "=== Lint: -SharedFunctionNames missing a transitively-called function ===" -ForegroundColor Cyan

$fnAstByName = @{}
$fileAsts    = @{}
$allFnNames  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in $fileText.Keys) {
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($fileText[$name], [ref]$null, [ref]$null)
    $fileAsts[$name] = $ast
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $fnAstByName[$f.Name] = $f
        $null = $allFnNames.Add($f.Name)
    }
}

function Get-CalledUserFunctions {
    # Every OTHER user-defined function (from the whole scan, not just this
    # file) that $AstNode's own body calls by a static name - a dynamic
    # invocation (`& $someVar`) has no static command name and is skipped,
    # same "can't know ahead of time" limit every DI-style call in this
    # codebase already has.
    param($AstNode)
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $AstNode.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $cmdName = $c.GetCommandName()
        if ($cmdName -and $allFnNames.Contains($cmdName)) { $names.Add($cmdName) }
    }
    return ,@($names | Select-Object -Unique)
}

$fnCallees = @{}
foreach ($fname in $fnAstByName.Keys) {
    # Captured into a variable FIRST, then filtered - piping
    # Get-CalledUserFunctions' comma-guarded return STRAIGHT into
    # Where-Object is the exact pipe-collapse trap Docs\lessons-learned.md
    # documents: only one object (the whole array) crosses the pipeline
    # boundary, so $_ binds to the entire array rather than each name.
    $rawCallees = Get-CalledUserFunctions -AstNode $fnAstByName[$fname]
    $fnCallees[$fname] = @($rawCallees | Where-Object { $_ -ne $fname })
}

function Get-MissingSharedFunctionNames {
    # BFS from $Roots (the worker scriptblock's own direct calls, plus
    # whatever's already listed). Stops expanding past any node NOT in
    # $ListedSet - a node already known missing would crash before ever
    # reaching whatever IT calls, so recursing past it is just noise
    # (fix the first gap, re-run, the next one surfaces on its own - an
    # iterative fixpoint, not one-shot deep transitivity).
    param([string[]]$Roots, [System.Collections.Generic.HashSet[string]]$ListedSet)
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $missing = [System.Collections.Generic.List[string]]::new()
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($r in $Roots) { if ($visited.Add($r)) { $queue.Enqueue($r) } }
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        if (-not $ListedSet.Contains($cur)) {
            $missing.Add($cur)
            continue
        }
        if ($fnCallees.ContainsKey($cur)) {
            foreach ($callee in $fnCallees[$cur]) {
                if ($visited.Add($callee)) { $queue.Enqueue($callee) }
            }
        }
    }
    return ,@($missing | Select-Object -Unique)
}

# Every $script:XXX = { ... } scriptblock assignment, so a -WorkerScript/
# -NextJobProvider $script:XXX argument can be resolved to its real body.
$scriptBlockVars = @{}
foreach ($name in $fileText.Keys) {
    foreach ($assign in $fileAsts[$name].FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ($assign.Right -is [System.Management.Automation.Language.CommandExpressionAst] -and
            $assign.Right.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
            $assign.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $scriptBlockVars[$assign.Left.VariablePath.UserPath] = $assign.Right.Expression.ScriptBlock
        }
    }
}

$rule5 = @()
foreach ($name in $fileText.Keys) {
    foreach ($call in $fileAsts[$name].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-ZipParallelProcessing' }, $true)) {
        $sharedNamesArg = $null
        $workerScriptVarName = $null
        for ($i = 0; $i -lt $call.CommandElements.Count; $i++) {
            $el = $call.CommandElements[$i]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and ($i + 1) -lt $call.CommandElements.Count) {
                if ($el.ParameterName -eq 'SharedFunctionNames') {
                    $sharedNamesArg = $call.CommandElements[$i + 1]
                } elseif ($el.ParameterName -eq 'WorkerScript' -or $el.ParameterName -eq 'NextJobProvider') {
                    $valEl = $call.CommandElements[$i + 1]
                    if ($valEl -is [System.Management.Automation.Language.VariableExpressionAst]) {
                        $workerScriptVarName = $valEl.VariablePath.UserPath
                    }
                }
            }
        }
        if ($null -eq $sharedNamesArg) { continue }

        # $sharedNamesArg may be a literal @('a','b') OR (this codebase's
        # newer pattern) a variable built earlier from Get-*SharedFunctionNames
        # calls - resolve either shape to the string literals actually in
        # play. A variable-built list can't be resolved by static AST alone
        # (its real content depends on running the Get-* functions), so
        # those call sites fall back to walking every CommandAst assigning
        # that variable and collecting string literals from ITS OWN
        # right-hand side instead - covers this codebase's actual pattern
        # (concatenated Get-*SharedFunctionNames calls) without needing a
        # real interpreter.
        $stringLiteralNodes = @($sharedNamesArg.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))
        $listed = @($stringLiteralNodes | ForEach-Object { $_.Value })
        if (@($listed).Count -eq 0 -and $sharedNamesArg -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $varName = $sharedNamesArg.VariablePath.UserPath
            foreach ($assign in $fileAsts[$name].FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                if ($assign.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $assign.Left.VariablePath.UserPath -eq $varName) {
                    foreach ($lit in $assign.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
                        $listed += $lit.Value
                    }
                    # Get-*SharedFunctionNames calls contribute names this
                    # static pass can't see without actually running them -
                    # resolve those directly against the known getter bodies.
                    foreach ($getterCall in $assign.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -like 'Get-*SharedFunctionNames' }, $true)) {
                        $getterName = $getterCall.GetCommandName()
                        if ($fnAstByName.ContainsKey($getterName)) {
                            foreach ($lit in $fnAstByName[$getterName].FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
                                $listed += $lit.Value
                            }
                        }
                    }
                }
            }
        }
        if (@($listed).Count -eq 0) { continue }
        $listedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$listed, [System.StringComparer]::OrdinalIgnoreCase)

        $roots = @($listed)
        if ($workerScriptVarName -and $scriptBlockVars.ContainsKey($workerScriptVarName)) {
            $roots += Get-CalledUserFunctions -AstNode $scriptBlockVars[$workerScriptVarName]
        }

        $lineNum = $call.Extent.StartLineNumber
        foreach ($missingName in (Get-MissingSharedFunctionNames -Roots $roots -ListedSet $listedSet)) {
            if (Test-IsExceptedName -FileName $name -Rule 'shared-function-names' -Name $missingName) { continue }
            $rule5 += @{ File = $name; Line = $lineNum; Text = ("-SharedFunctionNames is missing '" + $missingName + "' (needed transitively)") }
        }
    }
}
Test-Assert (@($rule5).Count -eq 0) "every -SharedFunctionNames array covers everything its worker/listed functions transitively call"
Show-Findings -Findings @($rule5)
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
