<#
.SYNOPSIS
    ModuleLoading - resolves where Modules\ actually is: try the default
    location next to the script, fall back to a previously-persisted
    path, then prompt INDEFINITELY until a valid one is given. See
    Docs/module-loading-design.md for the full chicken-and-egg reasoning
    behind why this exists at all.

.DESCRIPTION
    Deliberately built OUTSIDE Modules\, at the repo root - this logic
    can never actually BE one of the normal dot-sourced Modules\*.ps1
    files, because it's the code that finds Modules\ in the first place;
    dot-sourcing it FROM Modules\ would require already knowing where
    Modules\ is, which is exactly the problem it solves. It's genuinely
    destined to be merged wholesale into the main script at rewrite time
    (the project owner's own framing: "build module loading as a
    separate script for now... it can be merged into the main script
    later"), not to remain a permanently dot-sourced module like the
    other 19. Built and tested standalone first anyway, same "prove it
    before merging" process every other module here follows - see
    Modules\_Harness\ModuleLoading.Harness.ps1 (normal harness location;
    Tools\Run-Harness.ps1 discovers harnesses by that folder regardless
    of where the tested source file itself lives, so this needed no
    special-casing there).

    CONFIRMED WITH THE PROJECT OWNER (2026-08-28):
      - "the expected modules are actually there" means ALL real module
        files present by name (Get-ExpectedModuleFileNames below) - not
        just a subset. Kept as an explicit, hardcoded, plainly-visible
        list rather than derived by scanning a candidate folder - that
        would be circular, since this list is what VALIDATES a
        candidate folder in the first place. 19 files today (the
        original 18 plus Controller.ps1, added the same session this
        module was built) - update this list by hand whenever a real
        module is added or removed, it will not update itself.
      - An invalid/rejected path re-prompts INDEFINITELY - no retry
        limit, no give-up. The user can close the window manually if
        they want out.
      - This file does NOT persist anything itself - no
        Export-ScriptSettings call anywhere here. It only RESOLVES a
        path and reports where it came from (Default/Persisted/
        Prompted); the caller (eventually the main script's own
        bootstrap) decides whether/how to save the result.
        Config.ps1 already has the ModulesPath settings key waiting for
        it (Modules\Config.ps1's schema, no change needed there).

    FORWARD REFERENCES: none - fully standalone, same "must work before
    anything else can be dot-sourced" reasoning as
    DependencyDetection.ps1's own no-dependencies design, taken one step
    further here (this runs before even DependencyDetection.ps1 CAN be
    dot-sourced, since dot-sourcing anything from Modules\ requires
    already knowing where Modules\ is).

    TESTABILITY: Resolve-ModulesPath takes an injectable -PromptFunc,
    same pattern used throughout this project (Menu.ps1,
    UnwantedImage.ps1's Show-AddUnwantedImageProfileFlow) - a harness
    scenario queues canned responses via a scripted prompt that throws
    if exhausted, so an accidental real infinite loop fails the test
    immediately instead of hanging.

.NOTES
    New file, no reference extraction - the original script never had
    this logic (Docs/module-loading-design.md records a design decision
    made ahead of any code existing, not something ported from the
    original script).
#>

function Get-ExpectedModuleFileNames {
    <#
    .SYNOPSIS
        The real, current list of every module file Modules\ is expected
        to contain - hardcoded, not derived from scanning a candidate
        folder (see this file's header for why that would be circular).
    #>
    return @(
        "AbortPipeline.ps1"
        "AnimatedConversionPipeline.ps1"
        "CleanConsoleRendering.ps1"
        "Config.ps1"
        "Controller.ps1"
        "DependencyDetection.ps1"
        "FileDeletion.ps1"
        "ImageConversionPipeline.ps1"
        "LeafDirectoryDiscovery.ps1"
        "Logging.ps1"
        "Menu.ps1"
        "ResumeState.ps1"
        "RezipPipeline.ps1"
        "Summary.ps1"
        "UnwantedImage.ps1"
        "ZipCreation.ps1"
        "ZipParallelProcessing.ps1"
        "ZipPipeline.ps1"
        "ZipValidation.ps1"
    )
}

function Test-ModulesFolderCandidate {
    <#
    .SYNOPSIS
        True only if $CandidatePath exists as a real directory AND
        contains every file Get-ExpectedModuleFileNames lists.
    .OUTPUTS
        @{ IsValid = <bool>; MissingFiles = <string[]> } - MissingFiles
        is empty when IsValid is true; when the path doesn't exist at
        all, IsValid is false and MissingFiles is the FULL expected
        list (not left ambiguous), so a caller always has something
        concrete to show.
    #>
    param([Parameter(Mandatory)][string]$CandidatePath)

    $expected = Get-ExpectedModuleFileNames
    if (-not (Test-Path -LiteralPath $CandidatePath -PathType Container)) {
        return @{ IsValid = $false; MissingFiles = $expected }
    }

    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($fileName in $expected) {
        if (-not (Test-Path -LiteralPath (Join-Path $CandidatePath $fileName) -PathType Leaf)) {
            $missing.Add($fileName)
        }
    }
    return @{ IsValid = ($missing.Count -eq 0); MissingFiles = $missing.ToArray() }
}

function Resolve-ModulesPath {
    <#
    .SYNOPSIS
        Finds a real, validated Modules\ folder: tries -DefaultPath
        first (normally "<script folder>\Modules"), then -PersistedPath
        (a previously-remembered location, if any), then prompts
        INDEFINITELY via -PromptFunc until a valid path is given - never
        gives up, matching the project owner's explicit call ("the
        script can just be closed manually" if the user wants out).
    .PARAMETER PersistedPath
        Optional - a previously-saved ModulesPath setting value, if any
        (Config.ps1's own ModulesPath key). Checked only if -DefaultPath
        didn't pan out. A blank/whitespace value (Config.ps1's own
        default) is treated the same as "nothing persisted yet".
    .OUTPUTS
        @{ Path = <string>; Source = "Default"|"Persisted"|"Prompted" } -
        Source tells the caller whether the result needs (re)persisting:
        "Prompted" always does (it's new information); "Default"/
        "Persisted" only need it if they differ from what's already
        saved - this function doesn't know or care what's currently on
        disk, the caller does.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$DefaultPath,
        [string]$PersistedPath = $null,
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message }
    )

    $defaultCheck = Test-ModulesFolderCandidate -CandidatePath $DefaultPath
    if ($defaultCheck.IsValid) { return @{ Path = $DefaultPath; Source = "Default" } }

    if (-not [string]::IsNullOrWhiteSpace($PersistedPath)) {
        $persistedCheck = Test-ModulesFolderCandidate -CandidatePath $PersistedPath
        if ($persistedCheck.IsValid) { return @{ Path = $PersistedPath; Source = "Persisted" } }
    }

    while ($true) {
        $entered = (& $PromptFunc "Could not find the Modules folder. Enter its full path (drag & drop the folder in, or paste the path)")
        if ($null -ne $entered) { $entered = $entered.Trim().Trim('"') }
        if ([string]::IsNullOrWhiteSpace($entered)) {
            Write-Host "No path entered." -ForegroundColor Yellow
            continue
        }

        $check = Test-ModulesFolderCandidate -CandidatePath $entered
        if ($check.IsValid) { return @{ Path = $entered; Source = "Prompted" } }

        Write-Host ("That folder doesn't have everything expected - missing: " + ($check.MissingFiles -join ", ")) -ForegroundColor Yellow
    }
}
