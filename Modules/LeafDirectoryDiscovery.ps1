<#
.SYNOPSIS
    LeafDirectoryDiscovery - Get-ZippableLeafDirs (the shared leaf-folder
    scan used by mode 2 loose+zip and mode 3 zip-only), plus
    New-ZippableLeafDirProvider, an incremental alternative for callers
    that want to start zipping already-found folders while the rest of a
    large tree is still being scanned.

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

    INCREMENTAL SCANNING (2026-08-17): Get-ZippableLeafDirs itself scans
    the ENTIRE tree before returning anything - a caller building
    -JobParams from its full result has to wait out the whole scan before
    any work can start, which is slow and looks like a hang on a large
    library. Invoke-ZipParallelProcessing already has a
    -NextJobProvider parameter built specifically to solve this
    ("interleave scanning/peeking with dispatch instead of discovering
    everything up front" - CHANGELOG.md v16.1) but it was never actually
    wired up anywhere until now. New-ZippableLeafDirProvider below
    provides that: a scriptblock, compatible with -NextJobProvider, that
    evaluates one candidate directory at a time via a genuinely lazy .NET
    enumerator, so dispatch can begin on the first qualifying folder while
    the rest of a huge tree is still being walked. Both functions share
    the exact same per-directory guard logic via the internal
    Test-ZippableLeafDirCandidate helper below, so the incremental path can never
    silently drift from the batch path's behavior.

.NOTES
    Extracted from Conversion Script Main.ps1 - see
    Modules\_Reference\LeafDirectoryDiscovery.reference.ps1 for the
    verbatim source this was built from, with original line numbers.
#>

function Test-ZippableLeafDirCandidate {
    <#
    .SYNOPSIS
        Internal helper (not meant to be called from outside this
        module) - evaluates ONE directory against every guard
        Get-ZippableLeafDirs applies (leaf check, staging exclusion,
        former-container guard, qualifying-extension check, staleness
        check). Shared by the batch and incremental discovery paths so
        the guard logic itself is defined exactly once.
    .OUTPUTS
        @{ Dir; ZipOut } if $Dir qualifies; $null if it doesn't.
    #>
    param(
        [Parameter(Mandatory)]
        [System.IO.DirectoryInfo]$Dir,
        [Parameter(Mandatory)]
        [string[]]$QualifyingExtensions,
        [System.Collections.Generic.HashSet[string]]$ExcludeStagingDirs = $null,
        [bool]$ForceRezip = $false
    )

    $subDirs = @(Get-ChildItem -LiteralPath $Dir.FullName -Directory -ErrorAction SilentlyContinue)
    if ($subDirs.Count -gt 0) { return $null }   # not a leaf

    if ($ExcludeStagingDirs -and $ExcludeStagingDirs.Count -gt 0) {
        $dirPath = $Dir.FullName
        foreach ($stagingDir in $ExcludeStagingDirs) {
            if ($dirPath.Equals($stagingDir, [System.StringComparison]::OrdinalIgnoreCase) -or
                $dirPath.StartsWith($stagingDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $null
            }
        }
    }

    $allFiles = @(Get-ChildItem -LiteralPath $Dir.FullName -File -ErrorAction SilentlyContinue)

    # Former-container guard: any .zip directly inside means this is very
    # likely a now-empty container, not a genuine content leaf. Skip hard.
    $existingZipsHere = @($allFiles | Where-Object { $_.Extension -ieq ".zip" })
    if ($existingZipsHere.Count -gt 0) {
        Write-Log ("SKIPPING '" + $Dir.FullName + "' as a zip candidate: contains " + $existingZipsHere.Count + " existing .zip file(s) directly inside it - likely a container folder left behind after its subfolders were individually zipped, not a genuine leaf. Not zipping to avoid archiving those .zip files into a wrapper.") -Level Warn
        return $null
    }

    $qualifyingFiles = @($allFiles | Where-Object { $QualifyingExtensions -icontains $_.Extension })
    if ($qualifyingFiles.Count -eq 0) { return $null }   # empty, or nothing recognized

    $zipOut = Join-Path $Dir.Parent.FullName ($Dir.Name + ".zip")

    # Staleness check: skip if a same-named zip already exists and is
    # newer than every qualifying file in the folder.
    if (-not $ForceRezip -and (Test-Path -LiteralPath $zipOut)) {
        $zipTime    = (Get-Item -LiteralPath $zipOut).LastWriteTimeUtc
        $newestFile = $qualifyingFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($newestFile.LastWriteTimeUtc -le $zipTime) {
            Write-Log ("Skipping '" + $Dir.Name + "' - existing zip is up to date.") -Level Warn
            return $null
        }
    }

    return @{ Dir = $Dir; ZipOut = $zipOut }
}

function Get-ZippableLeafDirs {
    <#
    .SYNOPSIS
        Recursively scans $ScanPath for leaf directories (no
        subdirectories) that qualify for zipping, applying three guards -
        see Test-ZippableLeafDirCandidate. Scans the WHOLE tree before
        returning anything; for a large library, prefer
        New-ZippableLeafDirProvider (below) when the caller can dispatch
        work incrementally instead of needing the complete list upfront.
    .PARAMETER ExcludeStagingDirs
        Directories (and anything under them) to skip entirely - e.g. a
        pipeline's own in-progress extraction/staging area, which could
        otherwise transiently look like a real leaf mid-run.
    .OUTPUTS
        List[hashtable] of @{ Dir = <DirectoryInfo>; ZipOut = <string> },
        one per qualifying leaf. See this module's own header for why the
        return statement below needs its leading comma.
    .NOTES
        Throws immediately if -ScanPath doesn't exist (or isn't a
        directory) rather than silently returning an empty list - a
        mistyped -ScanPath previously produced the same "0 candidates
        found" result as a genuinely empty, valid directory, with no way
        to tell the two apart from the caller's side.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ScanPath,
        [Parameter(Mandatory)]
        [string[]]$QualifyingExtensions,
        [System.Collections.Generic.HashSet[string]]$ExcludeStagingDirs = $null,
        [bool]$ForceRezip = $false
    )

    if (-not (Test-Path -LiteralPath $ScanPath -PathType Container)) {
        throw ("Get-ZippableLeafDirs: -ScanPath does not exist or is not a directory: '" + $ScanPath + "'")
    }

    $results = [System.Collections.Generic.List[hashtable]]::new()

    Get-ChildItem -LiteralPath $ScanPath -Directory -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $candidate = Test-ZippableLeafDirCandidate -Dir $_ -QualifyingExtensions $QualifyingExtensions `
            -ExcludeStagingDirs $ExcludeStagingDirs -ForceRezip $ForceRezip
        if ($null -ne $candidate) { $results.Add($candidate) }
    }

    # Leading comma: without it, PowerShell's pipeline output enumerates
    # this List[hashtable] on return - a 1-element list collapses to its
    # bare hashtable, and a 0-element list to $null, corrupting the
    # caller's expected type. See this module's own header and
    # CLAUDE.md's "Lessons learned" for the two prior times this exact
    # bug class was caught live in this project.
    return ,$results
}

function New-ZippableLeafDirProvider {
    <#
    .SYNOPSIS
        Returns a scriptblock compatible with
        Invoke-ZipParallelProcessing's -NextJobProvider: each call
        evaluates the NEXT candidate directory and returns it (as
        @{ Dir; ZipOut }) the moment a qualifying one is found, or $null
        once the whole tree has been exhausted with nothing left. Lets a
        caller start dispatching work on already-found folders while the
        rest of a large tree is still being walked, instead of the whole
        tree needing to finish scanning before any work can begin.
    .PARAMETER ScanPath
        Same meaning as Get-ZippableLeafDirs's -ScanPath. Validated to
        exist at the time THIS function is called (setup time), not
        re-checked on every subsequent scriptblock invocation.
    .OUTPUTS
        [scriptblock] - pass directly as -NextJobProvider.
    .NOTES
        Uses [System.IO.Directory]::EnumerateDirectories, which is
        genuinely lazy (unlike Get-ChildItem captured into a variable,
        which fully materializes before the assignment completes) - so
        the underlying filesystem walk is spread across repeated calls to
        the returned scriptblock instead of happening all at once on the
        first call. A directory that becomes inaccessible mid-enumeration
        (permissions, a removed network share, etc.) would otherwise throw
        UnauthorizedAccessException/IOException straight out of
        MoveNext() and into Invoke-ZipParallelProcessing's dispatch loop,
        which isn't designed to handle a throwing provider - guarded here
        by treating that as "nothing more to offer" (logs a warning, ends
        the scan) rather than propagating. This specific error path is
        defensively coded but not live-verified against a real
        permission-denied directory (awkward to set up portably in a
        test harness without elevation) - flagging that honestly rather
        than claiming full coverage.

        The returned scriptblock is a closure over an enumerator and
        parameters captured HERE, outside Invoke-ZipParallelProcessing -
        the specific pattern this project's CLAUDE.md "Lessons learned"
        confirms works reliably (a closure defined and invoked entirely
        within Invoke-ParallelFolderJobs's own body was the pattern that
        failed live, twice, even after a [ref]-wrapping fix attempt).
        Verified live in this module's own harness (Scenario N) with a
        real multi-directory tree dispatched through real
        Invoke-ZipParallelProcessing runspaces, and a real timing check
        proving work starts on early folders before later parts of the
        tree have been scanned - not just structural correctness.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ScanPath,
        [Parameter(Mandatory)]
        [string[]]$QualifyingExtensions,
        [System.Collections.Generic.HashSet[string]]$ExcludeStagingDirs = $null,
        [bool]$ForceRezip = $false
    )

    if (-not (Test-Path -LiteralPath $ScanPath -PathType Container)) {
        throw ("New-ZippableLeafDirProvider: -ScanPath does not exist or is not a directory: '" + $ScanPath + "'")
    }

    $enumerator = [System.IO.Directory]::EnumerateDirectories($ScanPath, "*", [System.IO.SearchOption]::AllDirectories).GetEnumerator()

    return {
        while ($true) {
            $hasNext = $false
            try {
                $hasNext = $enumerator.MoveNext()
            } catch {
                Write-Log ("Leaf-directory scan stopped early: " + $_) -Level Error
                return $null
            }
            if (-not $hasNext) { return $null }

            $dirInfo = [System.IO.DirectoryInfo]::new($enumerator.Current)
            $candidate = Test-ZippableLeafDirCandidate -Dir $dirInfo -QualifyingExtensions $QualifyingExtensions `
                -ExcludeStagingDirs $ExcludeStagingDirs -ForceRezip $ForceRezip
            if ($null -ne $candidate) { return $candidate }
        }
    }.GetNewClosure()
}
