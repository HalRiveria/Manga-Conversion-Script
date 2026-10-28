<#
    Static checks for the PowerShell traps this project has actually been
    bitten by. Six bugs, all the same species:
    code that reads correctly and behaves otherwise. Five of the six leave
    a detectable trace in the source, so they're worth catching by grep
    (or, for Rule 5, real AST parsing) instead of by a live-debugging
    session.

    Scans Modules\*.ps1 and Tools\*.ps1 (not the harnesses or old script references).

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

$projectRoot = Split-Path -Parent $PSScriptRoot

# file (leaf name) + rule + why. Anything listed here is a KNOWN, decided
# case - not a backlog. If it isn't deliberate, fix the code instead.
# -Names (Rule 5 only): specific missing function names this exception
# covers - a -SharedFunctionNames array can have other, real gaps besides
# the excepted one, so suppressing the whole File+Rule combination would
# hide those too.
$script:LintKnownExceptions = @(
    @{ File = 'CleanConsoleRendering.ps1'
       Rule = 'collection-return'
       Why  = 'Split-TextToWidth / Format-SeriesLines deliberately omit the comma guard because their harness wraps every call in @()' }
    @{ File  = 'Controller.ps1'
       Rule  = 'shared-function-names'
       Names = @('Write-GatedConsoleMessage')
       Why   = 'Test-AbortSignal (AbortPipeline.ps1) is in this worker''s -SharedFunctionNames and its source still references Write-GatedConsoleMessage, which Rule 5''s call-graph walk correctly finds - but only past its worker early-return (a worker never announces the abort, it just returns [ConsoleCtrl]::AbortRequested), so Write-GatedConsoleMessage - unsafe in a worker, CCR state doesn''t exist there - is never reached at runtime.' }
)

# Rule 6 only: specific (function, $script: variable) pairs reviewed as safe
# on a runspace-reachable path. Keep this tiny - each entry must say why the
# read can't silently come back empty in a worker.
$script:LintScriptVarAllowed = @(
    @{ Function  = 'Get-WorkerRunspaceValue'
       Variables = @('workerConsoleQueue', 'PermanentDelete')
       Why       = 'The one sanctioned worker-state read: $script: first, $global: fallback (the worker body seeds its $script: at top level, which IS the runspace''s global scope) for when a closure context makes $script: come back empty. Explicit names only - a generic by-name lookup would be dynamically scoped and could pick up a caller''s same-named local.' }
    @{ Function  = 'Write-Log'
       Variables = @('CleanConsoleOutputEnabled', 'FullLogging')
       Why       = 'Only read after Write-Log''s own worker early-return (worker queue found -> enqueue + return), i.e. main thread only.' }
    @{ Function  = 'Write-LogLineToRunFiles'
       Variables = @('FullLogging', 'logFile', 'logErrorFile', 'logWarnFile')
       Why       = 'Only called from Write-Log past its worker early-return and from Flush-ConsoleQueue (main thread). Listed in Get-LoggingSharedFunctionNames only because Rule 5 walks Write-Log''s callees statically.' }
    @{ Function  = 'Invoke-MutexGuardedWrite'
       Variables = @('logMutex')
       Why       = 'Only reached via Write-LogLineToRunFiles (main thread, see above) inside a worker''s propagated set. Same Rule 5 static-listing reason.' }
    @{ Function  = 'Write-LogWriteFailureWarning'
       Variables = @('logWriteFailureWarned')
       Why       = 'Only called from Write-LogLineToFile''s catch, which is only reached via Write-LogLineToRunFiles (main thread, see above). Same Rule 5 static-listing reason.' }
    @{ Function  = 'Test-AbortSignal'
       Variables = @('abortRequested', 'ctrlCloseAbort', 'abortCancellationSources', 'CleanConsoleOutputEnabled')
       Why       = 'Only read after Test-AbortSignal''s own worker early-return (returns [ConsoleCtrl]::AbortRequested, never announces), i.e. main thread only.' }
)

# Rule 9 only: specific (function, host cmdlet) pairs reviewed as safe on a
# runspace-reachable path. Each entry must say why the cmdlet can't
# actually run inside a worker.
$script:LintHostCmdletAllowed = @(
    @{ Function = 'Write-LogLineToHost'
       Cmdlets  = @('Write-Host')
       Why      = 'Only called from Write-Log past its worker early-return (worker lines go through the console queue) and from Flush-ConsoleQueue (main thread). Listed in Get-LoggingSharedFunctionNames only because Rule 5 walks Write-Log''s callees statically.' }
)

$script:passCount = 0
$script:failCount = 0

function Test-IsScriptVarAllowed {
    param([string]$Function, [string]$Variable)
    foreach ($a in $script:LintScriptVarAllowed) {
        if ($a.Function -eq $Function -and ($a.Variables -contains $Variable)) { return $true }
    }
    return $false
}

function Test-IsHostCmdletAllowed {
    param([string]$Function, [string]$Cmdlet)
    foreach ($a in $script:LintHostCmdletAllowed) {
        if ($a.Function -eq $Function -and ($a.Cmdlets -contains $Cmdlet)) { return $true }
    }
    return $false
}

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
            # lint would otherwise flag the explanation.
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
#  Rule 2: $null -eq <string param> as a "caller omitted this" check"
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
# reaches it - and only a run that really exercises that runspace path
# notices. AST-based, not regex - reliably finding "what
# functions does this one call" needs a real parse, not a pattern match.
Write-Host "=== Lint: -SharedFunctionNames missing a transitively-called function ===" -ForegroundColor Cyan

$fnAstByName = @{}
$fnFileByName = @{}
$fileAsts    = @{}
$allFnNames  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in $fileText.Keys) {
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($fileText[$name], [ref]$null, [ref]$null)
    $fileAsts[$name] = $ast
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $fnAstByName[$f.Name] = $f
        $fnFileByName[$f.Name] = $name
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
    # Where-Object is the classic pipe-collapse trap:
    # only one object (the whole array) crosses the pipeline
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

# The scriptblock literal an assignment's right-hand side holds - a bare
# { ... }, or { ... }.GetNewClosure(), which parses as an
# InvokeMemberExpressionAst wrapping it - or $null. The one place this is
# decided; Rule 5's worker-body lookup below and Rule 7 both call it.
function Get-AssignedScriptBlockLiteral {
    param($Right)
    if ($Right -isnot [System.Management.Automation.Language.CommandExpressionAst]) { return $null }
    $expr = $Right.Expression
    if ($expr -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $expr.Member.Extent.Text -eq 'GetNewClosure') { $expr = $expr.Expression }
    if ($expr -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $expr }
    return $null
}

# Every $script:XXX = { ... } scriptblock assignment, so a -WorkerScript/
# -NextJobProvider $script:XXX argument can be resolved to its real body.
$scriptBlockVars = @{}
$scriptBlockVarFile = @{}
foreach ($name in $fileText.Keys) {
    foreach ($assign in $fileAsts[$name].FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ($assign.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $literal = Get-AssignedScriptBlockLiteral -Right $assign.Right
            if ($null -ne $literal) {
                $scriptBlockVars[$assign.Left.VariablePath.UserPath] = $literal.ScriptBlock
                $scriptBlockVarFile[$assign.Left.VariablePath.UserPath] = $name
            }
        }
    }
}

$rule5 = @()
$runspaceReachable    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$runspaceWorkerBodies = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in $fileText.Keys) {
    foreach ($call in $fileAsts[$name].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-ZipParallelProcessing' }, $true)) {
        $sharedNamesArg = $null
        $workerScriptVarName = $null
        for ($i = 0; $i -lt $call.CommandElements.Count; $i++) {
            $el = $call.CommandElements[$i]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and ($i + 1) -lt $call.CommandElements.Count) {
                if ($el.ParameterName -eq 'SharedFunctionNames') {
                    $sharedNamesArg = $call.CommandElements[$i + 1]
                } elseif ($el.ParameterName -eq 'WorkerScript') {
                    # NextJobProvider deliberately excluded - it's invoked via
                    # `& $NextJobProvider` in Invoke-ZipParallelProcessing's own
                    # main dispatch loop (ZipParallelProcessing.ps1), never
                    # marshalled into the runspace pool, so its callees don't
                    # need -SharedFunctionNames coverage.
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

        # Rule 6 input, gathered here so it reuses Rule 5's resolved lists.
        foreach ($listedName in $listed) { $null = $runspaceReachable.Add($listedName) }
        if ($workerScriptVarName -and $scriptBlockVars.ContainsKey($workerScriptVarName)) {
            $null = $runspaceWorkerBodies.Add($workerScriptVarName)
        }
    }
}
Test-Assert (@($rule5).Count -eq 0) "every -SharedFunctionNames array covers everything its worker/listed functions transitively call"
Show-Findings -Findings @($rule5)
Write-Host ""

# Runs $Finder (param($AstNode, $FunctionName), returning @{ Line; What }
# items) over every runspace-reachable function and worker body, and shapes
# the hits for Show-Findings. $FunctionName is $null for a worker body.
function Get-RunspaceReachableFindings {
    param([scriptblock]$Finder)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($fname in $runspaceReachable) {
        if (-not $fnAstByName.ContainsKey($fname)) { continue }
        foreach ($hit in (& $Finder $fnAstByName[$fname] $fname)) {
            $out.Add(@{ File = $fnFileByName[$fname]; Line = $hit.Line; Text = ($fname + " (runspace-reachable) " + $hit.What) })
        }
    }
    foreach ($workerVar in $runspaceWorkerBodies) {
        foreach ($hit in (& $Finder $scriptBlockVars[$workerVar] $null)) {
            $out.Add(@{ File = $scriptBlockVarFile[$workerVar]; Line = $hit.Line; Text = ("worker `$" + $workerVar + " " + $hit.What) })
        }
    }
    return ,$out
}

# ------------------------------------------------------------------------
#  Rule 6: $script: variable used on a runspace-reachable path
# ------------------------------------------------------------------------
# A function propagated via -SharedFunctionNames is recreated in the worker
# runspace from its definition TEXT, so it isn't bound to any module's
# session state - its `$script:` resolves against whatever scope is calling
# it. Called straight from the worker body that's the runspace's global
# scope (where the worker seeded its state), but called from inside a
# .GetNewClosure()'d block (every [System.Lazy] factory, chapter provider,
# job builder in this codebase) it resolves to that closure's own EMPTY
# dynamic-module scope instead - every `$script:` read comes back $null,
# silently - which caused worker
# [Error]/[Warn] lines to never reach a log file and the abort
# message to be duplicated. So: no runspace-reachable function, and no nested scriptblock
# inside a worker body, may touch `$script:` at all. The worker body's own
# top level is fine (it IS the runspace's script scope). Worker-side state
# goes through the console queue (Logging.ps1's Get-WorkerRunspaceValue),
# which the main thread drains. Deliberate, reviewed exceptions only - add
# them to $script:LintScriptVarAllowed below with a reason.
Write-Host "=== Lint: `$script: variable on a runspace-reachable path ===" -ForegroundColor Cyan

$rule6 = @()
$scriptVarRefFilter = {
    param($n)
    $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.IsScript
}
foreach ($fname in $runspaceReachable) {
    if (-not $fnAstByName.ContainsKey($fname)) { continue }
    $fnAst = $fnAstByName[$fname]
    $fnFile = $fnFileByName[$fname]
    foreach ($ref in $fnAst.FindAll($scriptVarRefFilter, $true)) {
        $varName = $ref.VariablePath.UserPath -replace '^script:', ''
        if (Test-IsScriptVarAllowed -Function $fname -Variable $varName) { continue }
        $rule6 += @{ File = $fnFile; Line = $ref.Extent.StartLineNumber; Text = ($fname + " (runspace-reachable) uses `$script:" + $varName) }
    }
}
foreach ($workerVar in $runspaceWorkerBodies) {
    $body = $scriptBlockVars[$workerVar]
    $workerFile = $scriptBlockVarFile[$workerVar]
    foreach ($nested in $body.FindAll({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)) {
        foreach ($ref in $nested.FindAll($scriptVarRefFilter, $true)) {
            $varName = $ref.VariablePath.UserPath -replace '^script:', ''
            $rule6 += @{ File = $workerFile; Line = $ref.Extent.StartLineNumber; Text = ("nested scriptblock in worker `$" + $workerVar + " uses `$script:" + $varName) }
        }
    }
}
Test-Assert (@($rule6).Count -eq 0) "no runspace-reachable function or nested worker scriptblock touches `$script: state"
Show-Findings -Findings @($rule6)
Write-Host ""

# ------------------------------------------------------------------------
#  Rule 7: a scriptblock handed to .NET or stored into shared state on a runspace-reachable path
# ------------------------------------------------------------------------
# A scriptblock belongs to the runspace that created it. Run on another
# runspace's thread, every scriptblock PowerShell runs inside it (a
# Where-Object filter, a nested delegate) gets queued back to the owning
# runspace, and the calling thread waits. If the owner is itself waiting on
# that thread (a lock, a Lazy), both hang for good; if the owner is idle,
# the queued block can run against the owner's scope stack and crash the
# process.
#
# Two ways a scriptblock reaches another runspace:
#   - as a job parameter. Invoke-ZipParallelProcessing refuses those at
#     runtime (Get-ZipJobScriptBlockKey), so every harness or real run
#     that dispatches a job already catches it - no static check here.
#   - through .NET or shared state: runspace-reachable code passing a
#     scriptblock to a .NET method or constructor ($dict.TryAdd($k, $sb),
#     [System.Lazy[object]]::new($Factory)), or storing one into a
#     collection or object it didn't create itself ($Cache[$k] = $sb,
#     $Slot.Factory = { ... }) - a parameter or outer variable, so
#     possibly shared with the other engine. This rule flags a variable
#     holding a scriptblock (assigned a scriptblock literal, or a
#     [scriptblock]-typed parameter) passed to .NET, and any scriptblock
#     value stored that way. Rule 8 covers literals and casts passed to .NET.
# Add "# lint:ignore" on the line for a deliberate exception.
Write-Host "=== Lint: scriptblock handed to .NET or stored into shared state on a runspace-reachable path ===" -ForegroundColor Cyan

function Get-ScriptBlockVariableNames {
    param($AstNode)
    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($assign in $AstNode.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ($assign.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $null -ne (Get-AssignedScriptBlockLiteral -Right $assign.Right)) {
            $null = $names.Add($assign.Left.VariablePath.UserPath)
        }
    }
    foreach ($p in $AstNode.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
        foreach ($attr in $p.Attributes) {
            if ($attr -is [System.Management.Automation.Language.TypeConstraintAst] -and
                $attr.TypeName.FullName -match '^(System\.Management\.Automation\.)?scriptblock$') {
                $null = $names.Add($p.Name.VariablePath.UserPath)
            }
        }
    }
    return ,$names
}

$scriptBlockArgFinder = {
    param($AstNode)
    $found = [System.Collections.Generic.List[object]]::new()
    $sbVarNames = Get-ScriptBlockVariableNames -AstNode $AstNode
    foreach ($call in $AstNode.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        if ($null -eq $call.Arguments) { continue }
        $memberName = [string]$call.Member.Extent.Text
        if ($memberName -in @('ForEach', 'Where')) { continue }
        if ($call.Extent.StartScriptPosition.Line -match '#\s*lint:ignore') { continue }
        foreach ($argument in $call.Arguments) {
            if ($argument -is [System.Management.Automation.Language.VariableExpressionAst] -and $sbVarNames.Contains($argument.VariablePath.UserPath)) {
                $found.Add(@{ Line = $call.Extent.StartLineNumber; What = ("passes scriptblock `$" + $argument.VariablePath.UserPath + " to ." + $memberName + "()") })
            }
        }
    }
    # Stores: $x[...] = <scriptblock> / $x.Prop = <scriptblock>, unless $x
    # is a container this code built itself - every assignment to it creates
    # a new one (@{}, @(), [Type]::new(), New-Object) and it isn't a
    # parameter. An alias of something else ($c = $SharedCache), a parameter
    # or a loop variable could be shared, so those count.
    $assignments = @($AstNode.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
    $freshNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $otherNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $AstNode.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)) { $null = $otherNames.Add($p.Name.VariablePath.UserPath) }
    foreach ($assign in $assignments) {
        if ($assign.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $rhs = $assign.Right
        $isFresh = $false
        if ($rhs -is [System.Management.Automation.Language.CommandExpressionAst]) {
            $expr = $rhs.Expression
            if ($expr -is [System.Management.Automation.Language.ConvertExpressionAst]) { $expr = $expr.Child }
            $isFresh = ($expr -is [System.Management.Automation.Language.HashtableAst]) -or
                ($expr -is [System.Management.Automation.Language.ArrayExpressionAst]) -or
                ($expr -is [System.Management.Automation.Language.ArrayLiteralAst]) -or
                ($expr -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $expr.Static -and $expr.Member.Extent.Text -eq 'new')
        } elseif ($rhs -is [System.Management.Automation.Language.PipelineAst] -and $rhs.PipelineElements.Count -eq 1 -and
                  $rhs.PipelineElements[0] -is [System.Management.Automation.Language.CommandAst] -and $rhs.PipelineElements[0].GetCommandName() -eq 'New-Object') {
            $isFresh = $true
        }
        if ($isFresh) { $null = $freshNames.Add($assign.Left.VariablePath.UserPath) } else { $null = $otherNames.Add($assign.Left.VariablePath.UserPath) }
    }
    foreach ($assign in $assignments) {
        $target = $assign.Left
        if ($target -isnot [System.Management.Automation.Language.IndexExpressionAst] -and
            $target -isnot [System.Management.Automation.Language.MemberExpressionAst]) { continue }
        $value = $null
        if ($assign.Right -is [System.Management.Automation.Language.CommandExpressionAst]) { $value = $assign.Right.Expression }
        $isScriptBlock = ($null -ne (Get-AssignedScriptBlockLiteral -Right $assign.Right)) -or
            ($value -is [System.Management.Automation.Language.VariableExpressionAst] -and $sbVarNames.Contains($value.VariablePath.UserPath))
        if (-not $isScriptBlock) { continue }
        $root = $target
        while ($root -is [System.Management.Automation.Language.IndexExpressionAst] -or $root -is [System.Management.Automation.Language.MemberExpressionAst]) {
            if ($root -is [System.Management.Automation.Language.IndexExpressionAst]) { $root = $root.Target } else { $root = $root.Expression }
        }
        if ($root -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $freshNames.Contains($root.VariablePath.UserPath) -and -not $otherNames.Contains($root.VariablePath.UserPath)) { continue }
        if ($assign.Extent.StartScriptPosition.Line -match '#\s*lint:ignore') { continue }
        $found.Add(@{ Line = $assign.Extent.StartLineNumber; What = ("stores a scriptblock into " + $target.Extent.Text + ", which it didn't create") })
    }
    return ,$found
}

# Proves the finder fires, since nothing in the real code trips it.
$rule7SampleText = @'
function Sample-Worker {
    param([scriptblock]$Factory, [string]$Name, $Cache)
    $built = { 3 }.GetNewClosure()
    $result = { 4 }.Invoke()
    $lazy = [System.Lazy[object]]::new($Factory)
    $null = $dict.TryAdd('k', $built)
    $null = $dict.TryAdd('k', $Name)
    $null = $dict.TryAdd('k', $result)
    $e = @(1, 2).Where($built)
    $null = $dict.TryAdd('k', $built)   # lint:ignore - sample
    $Cache['k'] = $Factory
    $Cache.Hook = { 5 }.GetNewClosure()
    $local = @{}
    $local['k'] = $built
    $Cache['n'] = $Name
    $alias = $Cache
    $alias['a'] = $built
    foreach ($slot in $Cache.Values) { $slot.Factory = $Factory }
}
'@
$rule7SampleAst = [System.Management.Automation.Language.Parser]::ParseInput($rule7SampleText, [ref]$null, [ref]$null)
$rule7Sample = & $scriptBlockArgFinder $rule7SampleAst
$rule7SampleLines = @($rule7Sample | ForEach-Object { $_.Line })
Test-Assert ($rule7SampleLines -contains 5) "Rule 7 flags a [scriptblock] parameter passed to a constructor ([System.Lazy]::new(`$Factory))"
Test-Assert ($rule7SampleLines -contains 6) "Rule 7 flags a .GetNewClosure()'d scriptblock variable stored through a .NET method (TryAdd)"
Test-Assert ($rule7SampleLines -contains 11) "Rule 7 flags a scriptblock stored through an indexer on a container it didn't create (`$Cache['k'] = `$Factory)"
Test-Assert ($rule7SampleLines -contains 12) "Rule 7 flags a scriptblock literal stored into a property of a container it didn't create (`$Cache.Hook = { }.GetNewClosure())"
Test-Assert (($rule7SampleLines -contains 17) -and ($rule7SampleLines -contains 18)) "Rule 7 flags a store through a local alias of a shared container, and through a loop variable"
Test-Assert ($rule7Sample.Count -eq 6) ("Rule 7 leaves a plain parameter, a scriptblock's .Invoke() result, .Where(), a lint:ignore'd line, a container it built itself and a plain stored value alone (flagged " + $rule7Sample.Count + ", expected 6)")

$rule7 = Get-RunspaceReachableFindings -Finder $scriptBlockArgFinder
Test-Assert (@($rule7).Count -eq 0) "no runspace-reachable function or worker body passes a scriptblock to .NET or stores one into a container it didn't create"
Show-Findings -Findings @($rule7)
Write-Host ""

# ------------------------------------------------------------------------
#  Rule 8: scriptblock converted to a delegate on a runspace-reachable path
# ------------------------------------------------------------------------
# A PowerShell scriptblock cast to a .NET delegate ([Func[...]], [Action[...]],
# ...) runs on whichever thread .NET calls it from. On a shared object (a
# [System.Lazy] factory in a cache both engines read), that can be the
# other engine's thread - the Rule 7 problem: any scriptblock it runs inside
# (a Where-Object filter, a nested AddOrUpdate delegate) is queued back to
# the owning engine, which is blocked on the Lazy lock, and both hang.
# Runspace code uses plain loops/locks instead.
#
# Two shapes, both flagged:
#   - the written cast: [Func[...]]{ ... }
#   - the implicit one: a scriptblock literal passed straight to a .NET
#     method or constructor - $dict.GetOrAdd($k, { ... }),
#     [System.Lazy[object]]::new({ ... }). No cast is written, but .NET
#     receives a delegate all the same; this is the shape that actually
#     caused a hang. .ForEach()/.Where() are PowerShell's own and take real
#     scriptblocks, so they're exempt. Add "# lint:ignore" on the line for
#     any other method that really does take a scriptblock.
Write-Host "=== Lint: scriptblock-to-delegate cast on a runspace-reachable path ===" -ForegroundColor Cyan

$rule8 = @()
$delegateCastFinder = {
    param($AstNode)
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($cv in $AstNode.FindAll({ param($n) $n -is [System.Management.Automation.Language.ConvertExpressionAst] }, $true)) {
        if ($cv.Extent.StartScriptPosition.Line -match '#\s*lint:ignore') { continue }
        if ($cv.Type.TypeName.Name -match '^(System\.)?(Func|Action|Predicate|Comparison|Converter)(\[|$)') {
            $found.Add(@{ Line = $cv.Extent.StartLineNumber; What = ("casts to delegate " + $cv.Type.TypeName.Name) })
        }
    }
    foreach ($call in $AstNode.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        if ($null -eq $call.Arguments) { continue }
        $memberName = [string]$call.Member.Extent.Text
        if ($memberName -in @('ForEach', 'Where')) { continue }
        $passesScriptBlock = $false
        foreach ($argument in $call.Arguments) {
            if ($argument -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $passesScriptBlock = $true }
        }
        if (-not $passesScriptBlock) { continue }
        if ($call.Extent.StartScriptPosition.Line -match '#\s*lint:ignore') { continue }
        $found.Add(@{ Line = $call.Extent.StartLineNumber; What = ("passes a scriptblock to ." + $memberName + "(), which .NET turns into a delegate") })
    }
    return ,$found
}

# Proves the finder itself fires, since nothing in the real code trips it.
$rule8SampleText = @'
function Sample-Worker {
    $a = [Func[object, object]]{ param($x) $x }
    $b = $dict.GetOrAdd($key, { param($k) 1 })
    $c = [System.Lazy[object]]::new({ 2 })
    $d = @(1, 2).ForEach({ $_ })
    $e = @(1, 2).Where({ $_ -gt 1 })
    $f = $dict.GetOrAdd($key, { 3 })   # lint:ignore - sample
    $g = $dict.TryAdd($key, 4)
}
'@
$rule8SampleAst = [System.Management.Automation.Language.Parser]::ParseInput($rule8SampleText, [ref]$null, [ref]$null)
$rule8SampleFound = & $delegateCastFinder $rule8SampleAst
$rule8SampleLines = @($rule8SampleFound | ForEach-Object { $_.Line })
Test-Assert ($rule8SampleLines -contains 2) "Rule 8 flags a written delegate cast ([Func[...]]{ })"
Test-Assert ($rule8SampleLines -contains 3) "Rule 8 flags a scriptblock passed straight to a .NET method (GetOrAdd)"
Test-Assert ($rule8SampleLines -contains 4) "Rule 8 flags a scriptblock passed straight to a constructor ([System.Lazy]::new)"
Test-Assert ($rule8SampleFound.Count -eq 3) ("Rule 8 leaves .ForEach()/.Where(), a lint:ignore'd line and a plain call alone (flagged " + $rule8SampleFound.Count + ", expected 3)")
$rule8 = Get-RunspaceReachableFindings -Finder $delegateCastFinder
Test-Assert (@($rule8).Count -eq 0) "no runspace-reachable function or worker body turns a scriptblock into a delegate (written cast or implicit)"
Show-Findings -Findings @($rule8)
Write-Host ""

# ------------------------------------------------------------------------
#  Rule 9: host cmdlet on a runspace-reachable path
# ------------------------------------------------------------------------
# Worker runspaces share the real console host (the pool is built with
# $Host), so a worker writing straight to it bypasses the console queue the
# main thread drains - its lines interleave with, and scramble, Clean
# Console Output's live display - and Read-Host would prompt from a
# background thread mid-run. Worker output goes through Write-Log (the
# console queue) instead. Other cmdlets are fine in runspace code.
# Deliberate, reviewed exceptions go in $script:LintHostCmdletAllowed with
# a reason.
Write-Host "=== Lint: host cmdlet on a runspace-reachable path ===" -ForegroundColor Cyan

# The same goes for writing to the console directly: [Console]::... and
# $Host.UI. Those go in the allow-list as '[Console]' and '$Host.UI'.
$hostCmdletNames = @('Write-Host', 'Read-Host', 'Out-Host', 'Clear-Host', 'Get-Credential', 'Out-GridView')
# Aliases (cls, clear, oh, ogv, ...) resolve to the cmdlet they stand for.
$hostCmdletByName = @{}
foreach ($n in $hostCmdletNames) { $hostCmdletByName[$n] = $n }
foreach ($a in @(Get-Alias -Definition $hostCmdletNames -ErrorAction SilentlyContinue)) { $hostCmdletByName[$a.Name] = $a.Definition }
$hostCmdletFinder = {
    param($AstNode, $FunctionName)
    $found = [System.Collections.Generic.List[object]]::new()
    $hits = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $AstNode.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $cmdName = $c.GetCommandName()
        if (-not $cmdName) { continue }
        $bareName = $cmdName -replace '^[^\\]+\\', ''   # Microsoft.PowerShell.Utility\Write-Host -> Write-Host
        if (-not $hostCmdletByName.ContainsKey($bareName)) { continue }
        $hits.Add(@{ Ast = $c; Name = $hostCmdletByName[$bareName]; What = ("calls host cmdlet " + $cmdName) })
    }
    foreach ($m in $AstNode.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] }, $true)) {
        if ($m.Static -and $m.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
            $m.Expression.TypeName.FullName -match '^(System\.)?Console$') {
            $hits.Add(@{ Ast = $m; Name = '[Console]'; What = ("uses [Console]::" + $m.Member.Extent.Text) })
        } elseif ($m.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
                  $m.Expression.VariablePath.UserPath -match '^(global:)?Host$' -and $m.Member.Extent.Text -eq 'UI') {
            $hits.Add(@{ Ast = $m; Name = '$Host.UI'; What = "uses `$Host.UI" })
        }
    }
    foreach ($h in $hits) {
        if ($FunctionName -and (Test-IsHostCmdletAllowed -Function $FunctionName -Cmdlet $h.Name)) { continue }
        if ($h.Ast.Extent.StartScriptPosition.Line -match '#\s*lint:ignore') { continue }
        $found.Add(@{ Line = $h.Ast.Extent.StartLineNumber; What = $h.What })
    }
    return ,$found
}
$rule9SampleText = @'
function Sample-Worker {
    Write-Host 'x'
    $a = Read-Host
    Write-Output 'y'
    cls
    [Console]::WriteLine('z')
    $Host.UI.WriteLine('w')
    $width = $Host.Name
    Microsoft.PowerShell.Utility\Write-Host 'q'
}
'@
$rule9SampleAst = [System.Management.Automation.Language.Parser]::ParseInput($rule9SampleText, [ref]$null, [ref]$null)
$rule9Sample = & $hostCmdletFinder $rule9SampleAst 'Sample-Worker'
$rule9SampleLines = @($rule9Sample | ForEach-Object { $_.Line } | Sort-Object)
Test-Assert (($rule9SampleLines -join ',') -eq '2,3,5,6,7,9') ("Rule 9 flags Write-Host, Read-Host, an alias (cls), [Console]::, `$Host.UI and a module-qualified name, and leaves Write-Output and other `$Host members alone (flagged lines " + ($rule9SampleLines -join ',') + ", expected 2,3,5,6,7,9)")

$rule9 = Get-RunspaceReachableFindings -Finder $hostCmdletFinder
Test-Assert (@($rule9).Count -eq 0) "no runspace-reachable function or worker body calls a host cmdlet"
Show-Findings -Findings @($rule9)
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
