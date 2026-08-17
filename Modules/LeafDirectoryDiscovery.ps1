<#
.SYNOPSIS
    LeafDirectoryDiscovery - Get-ZippableLeafDirs, the shared leaf-folder
    scan used by mode 2 (loose+zip) and mode 3 (zip-only).

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules.

    FORWARD REFERENCE: Write-Log (Modules\Logging.ps1) - not defined in
    this module. Modules\_Harness\LeafDirectoryDiscovery.Harness.ps1
    stubs it, since this module must stay standalone-testable without
    Logging.ps1 existing.

    Get-ZippableLeafDirs returns a List[hashtable] - per this project's
    documented "Lessons learned" (CLAUDE.md), any function returning a
    generic collection needs `return ,$collection` (leading comma) to
    stop PowerShell's pipeline output from enumerating it: a 1-element
    collection silently collapses to its bare element, and a 0-element
    one to $null, unless suppressed. This exact bug has already been
    caught live twice in this project (Modules\AbortPipeline.ps1's
    Receive-CompletedHandles, and again here) - verified live in this
    module's own harness (Scenario I/J) that the comma is genuinely
    required, not just applied defensively out of caution.

    Also fixes a live-reproduced instance of the "parent/container folder"
    bug documented in CHANGELOG.md (the former-container guard): once
    every chapter subfolder of a series folder has been individually
    zipped and its source deleted, the series folder itself can end up
    with zero subdirectories and nothing but the chapter .zip files
    directly inside it - looking, structurally, like a genuine leaf.
    CHANGELOG.md's own note on that guard says its fix was "best-reasoned
    ... not a confirmed root-cause diagnosis - the exact mechanism wasn't
    reproduced." This module's harness (Scenario K, built against a real
    folder shape modeled on Backups\Test Images\Only Images /
    Backups\Rezip Tests\Only Images) is the first actual live
    reproduction and confirmation that the guard works, not just
    reasoning about it.

.NOTES
    Extracted from Conversion Script Main.ps1 - see
    Modules\_Reference\LeafDirectoryDiscovery.reference.ps1 for the
    verbatim source this was built from, with original line numbers.
#>

function Get-ZippableLeafDirs {
    <#
    .SYNOPSIS
        Recursively scans $ScanPath for leaf directories (no
        subdirectories) that qualify for zipping, applying three guards:
        the former-container guard (any existing .zip directly inside
        means "skip, likely a former container, not a genuine leaf"),
        the qualifying-extension check (must contain at least one file
        matching -QualifyingExtensions), and the staleness check (skip if
        a same-named .zip already exists and is newer than every
        qualifying file, unless -ForceRezip).
    .PARAMETER ExcludeStagingDirs
        Directories (and anything under them) to skip entirely - e.g. a
        pipeline's own in-progress extraction/staging area, which could
        otherwise transiently look like a real leaf mid-run.
    .OUTPUTS
        List[hashtable] of @{ Dir = <DirectoryInfo>; ZipOut = <string> },
        one per qualifying leaf. See this module's own header for why the
        return statement below needs its leading comma.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ScanPath,
        [Parameter(Mandatory)]
        [string[]]$QualifyingExtensions,
        [System.Collections.Generic.HashSet[string]]$ExcludeStagingDirs = $null,
        [bool]$ForceRezip = $false
    )

    $results = [System.Collections.Generic.List[hashtable]]::new()

    Get-ChildItem -LiteralPath $ScanPath -Directory -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $dir = $_

        $subDirs = @(Get-ChildItem -LiteralPath $dir.FullName -Directory -ErrorAction SilentlyContinue)
        if ($subDirs.Count -gt 0) { return }   # not a leaf

        if ($ExcludeStagingDirs -and $ExcludeStagingDirs.Count -gt 0) {
            $dirPath   = $dir.FullName
            $isStaging = $false
            foreach ($stagingDir in $ExcludeStagingDirs) {
                if ($dirPath.Equals($stagingDir, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $dirPath.StartsWith($stagingDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isStaging = $true; break
                }
            }
            if ($isStaging) { return }
        }

        $allFiles = @(Get-ChildItem -LiteralPath $dir.FullName -File -ErrorAction SilentlyContinue)

        # Former-container guard: any .zip directly inside means this is very
        # likely a now-empty container, not a genuine content leaf. Skip hard.
        $existingZipsHere = @($allFiles | Where-Object { $_.Extension -ieq ".zip" })
        if ($existingZipsHere.Count -gt 0) {
            Write-Log ("SKIPPING '" + $dir.FullName + "' as a zip candidate: contains " + $existingZipsHere.Count + " existing .zip file(s) directly inside it - likely a container folder left behind after its subfolders were individually zipped, not a genuine leaf. Not zipping to avoid archiving those .zip files into a wrapper.") -Level Warn
            return
        }

        $qualifyingFiles = @($allFiles | Where-Object { $QualifyingExtensions -icontains $_.Extension })
        if ($qualifyingFiles.Count -eq 0) { return }   # empty, or nothing recognized

        $zipOut = Join-Path $dir.Parent.FullName ($dir.Name + ".zip")

        # Staleness check: skip if a same-named zip already exists and is
        # newer than every qualifying file in the folder.
        if (-not $ForceRezip -and (Test-Path -LiteralPath $zipOut)) {
            $zipTime    = (Get-Item -LiteralPath $zipOut).LastWriteTimeUtc
            $newestFile = $qualifyingFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            if ($newestFile.LastWriteTimeUtc -le $zipTime) {
                Write-Log ("Skipping '" + $dir.Name + "' - existing zip is up to date.") -Level Warn
                return
            }
        }

        $results.Add(@{ Dir = $dir; ZipOut = $zipOut })
    }

    # Leading comma: without it, PowerShell's pipeline output enumerates
    # this List[hashtable] on return - a 1-element list collapses to its
    # bare hashtable, and a 0-element list to $null, corrupting the
    # caller's expected type. See this module's own header and
    # CLAUDE.md's "Lessons learned" for the two prior times this exact
    # bug class was caught live in this project.
    return ,$results
}
