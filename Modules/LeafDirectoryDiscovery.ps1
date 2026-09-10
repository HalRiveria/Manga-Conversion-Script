<#
.SYNOPSIS
    LeafDirectoryDiscovery - Get-ZippableLeafDirs (the shared leaf-folder
    scan used by mode 2 loose+zip and mode 3 zip-only), plus
    New-ZippableLeafDirProvider, an incremental alternative for callers
    that want to start zipping already-found folders while the rest of a
    large tree is still being scanned - and New-SeriesProvider +
    Get-SeriesChapters, the two-tier series/chapter discovery Clean
    Console Output needs (lazy across series, eager within one series).

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
    walk, so dispatch can begin on the first qualifying folder while
    the rest of a huge tree is still being walked. Both functions share
    the exact same per-directory guard logic via the internal
    Test-ZippableLeafDirCandidate helper below, so the incremental path can never
    silently drift from the batch path's LEAF-QUALIFYING behavior.

    TRAVERSAL-ERROR PARITY (2026-08-28, real bug fix - see
    Todo.md/CHANGELOG.md): the guard-logic parity above did NOT originally
    extend to how the two paths handled an inaccessible directory -
    verified live, a single permission-denied folder anywhere in the tree
    made the old incremental provider (a single flat
    [System.IO.Directory]::EnumerateDirectories(...,
    SearchOption.AllDirectories) enumerator, which throws on the first
    inaccessible directory and cannot be resumed) silently abandon
    everything past that point, while the batch path
    (Get-ChildItem -Recurse -ErrorAction SilentlyContinue) just skipped
    that one subtree and kept going. New-ZippableLeafDirProvider now walks
    the tree manually, one directory level at a time, with each level's
    own enumeration wrapped in its own try/catch (see that function's own
    NOTES) - an inaccessible directory now only costs its own subtree,
    matching the batch path's resilience. Purely additive to this module's
    existing, already-tested surface - ZipPipeline.ps1's current use of
    New-ZippableLeafDirProvider is untouched by any of this.

    TWO-TIER SERIES/CHAPTER DISCOVERY (2026-08-18, for Clean Console
    Output - see CLAUDE.md's section of that name): under the FIXED
    Library > Series > Chapter > Images layout (decided, not a
    heuristic), a series' chapter COUNT needs to be known before
    Start-SeriesProgress can report real progress - but scanning the
    whole library up front to get every series' count is exactly the
    hang this module already fixed once. The split: New-SeriesProvider
    walks the LIBRARY lazily, one series at a time (same anti-hang
    property as New-ZippableLeafDirProvider, just one level up - series
    are always exactly one level below the library root under the fixed
    layout, so no recursion or per-item guard/filter logic is even needed
    there). Get-SeriesChapters then does an EAGER, full scan bounded to
    ONE series' chapters - small enough not to reintroduce the hang - and
    is a thin wrapper around Get-ZippableLeafDirs itself: rooting a
    RECURSIVE scan at one series folder finds exactly the same chapters a
    single-level scan would, since chapters never nest deeper under the
    fixed layout (they contain only images), so reusing
    Get-ZippableLeafDirs directly here means the guard logic can never
    drift between the whole-library and per-series scan paths - there is
    only the one implementation.

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
    .NOTES
        Uses $Dir's own .EnumerateDirectories()/.EnumerateFiles() (raw
        .NET), not Get-ChildItem, as of 2026-09-10 - same reasoning as
        Get-ZippableLeafDirs's own NOTES (real hang, not just slowness,
        live-reproduced when two runspaces both make their first-ever
        Get-ChildItem/provider-layer call at close to the same moment).
        This function is the SECOND real Get-ChildItem call site that
        needed the same fix - New-ZippableLeafDirProvider's own
        "already proven" stack-based walk calls into this exact function,
        so it was never actually safe from this race either, just never
        exercised under two engines discovering the same directory at the
        same instant before Full Pipeline's dispatch redesign. Each
        enumeration is still wrapped in try/catch, defaulting to "found
        nothing" on error - matches Get-ChildItem -ErrorAction
        SilentlyContinue's own behavior exactly (an inaccessible directory
        silently contributes zero items, not a thrown error).
    #>
    param(
        [Parameter(Mandatory)]
        [System.IO.DirectoryInfo]$Dir,
        [Parameter(Mandatory)]
        [string[]]$QualifyingExtensions,
        [System.Collections.Generic.HashSet[string]]$ExcludeStagingDirs = $null,
        [bool]$ForceRezip = $false
    )

    $hasSubDirs = $false
    try {
        $subDirEnum = $Dir.EnumerateDirectories().GetEnumerator()
        try { $hasSubDirs = $subDirEnum.MoveNext() } finally { $subDirEnum.Dispose() }
    } catch { }
    if ($hasSubDirs) { return $null }   # not a leaf

    if ($ExcludeStagingDirs -and $ExcludeStagingDirs.Count -gt 0) {
        $dirPath = $Dir.FullName
        foreach ($stagingDir in $ExcludeStagingDirs) {
            if ($dirPath.Equals($stagingDir, [System.StringComparison]::OrdinalIgnoreCase) -or
                $dirPath.StartsWith($stagingDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $null
            }
        }
    }

    $allFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    try { foreach ($f in $Dir.EnumerateFiles()) { $allFiles.Add($f) } } catch { }

    # Former-container guard: any .zip directly inside means this is very
    # likely a now-empty container, not a genuine content leaf. Skip hard.
    # Plain foreach, not Where-Object (2026-09-10) - Where-Object is ALSO
    # a real hang risk under this same race, not just filesystem cmdlets
    # like Get-ChildItem - live-reproduced with a stack-based .NET walk
    # already in place, hanging at a bare Where-Object call over an
    # in-memory List. See this function's own NOTES above.
    $existingZipsHere = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($f in $allFiles) { if ($f.Extension -ieq ".zip") { $existingZipsHere.Add($f) } }
    if ($existingZipsHere.Count -gt 0) {
        Write-Log ("SKIPPING '" + $Dir.FullName + "' as a zip candidate: contains " + $existingZipsHere.Count + " existing .zip file(s) directly inside it - likely a container folder left behind after its subfolders were individually zipped, not a genuine leaf. Not zipping to avoid archiving those .zip files into a wrapper.") -Level Warn
        return $null
    }

    $qualifyingFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($f in $allFiles) { if ($QualifyingExtensions -icontains $f.Extension) { $qualifyingFiles.Add($f) } }
    if ($qualifyingFiles.Count -eq 0) { return $null }   # empty, or nothing recognized

    # [System.IO.Path]::Combine, not Join-Path (2026-09-10) - Join-Path is
    # provider-aware (resolves against whatever provider owns the path),
    # same reasoning as this function's own NOTES above.
    $zipOut = [System.IO.Path]::Combine($Dir.Parent.FullName, $Dir.Name + ".zip")

    # Staleness check: skip if a same-named zip already exists and is
    # newer than every qualifying file in the folder. [System.IO.File]
    # (raw .NET), not Test-Path/Get-Item, and a plain foreach max-search,
    # not Sort-Object/Select-Object - same reasoning as this function's
    # own NOTES above.
    if (-not $ForceRezip -and [System.IO.File]::Exists($zipOut)) {
        $zipTime    = [System.IO.File]::GetLastWriteTimeUtc($zipOut)
        $newestFile = $qualifyingFiles[0]
        foreach ($f in $qualifyingFiles) { if ($f.LastWriteTimeUtc -gt $newestFile.LastWriteTimeUtc) { $newestFile = $f } }
        if ($newestFile.LastWriteTimeUtc -le $zipTime) {
            Write-Log ("Skipping '" + $Dir.Name + "' - existing zip is up to date.") -Level Warn
            return $null
        }
    }

    return @{ Dir = $Dir; ZipOut = $zipOut }
}

function Get-FilesRecursiveSafe {
    <#
    .SYNOPSIS
        Recursively enumerates every FILE under $ScanPath, resilient to a
        permission-denied (or otherwise inaccessible) subdirectory
        anywhere in the tree - that subtree is skipped (logged as a
        Warn), the rest of the scan continues. Same "silently continue
        past an inaccessible subtree" guarantee every real caller of this
        function used to get from Get-ChildItem -Recurse -File
        -ErrorAction SilentlyContinue directly, before 2026-09-10 (see
        this module's own header/CHANGELOG.md) - Get-ChildItem/the
        PowerShell FileSystem provider can HANG, not just run slowly,
        when two runspaces both make their first-ever provider-layer call
        at close to the same moment (real, live-reproduced bug, only
        reachable once Full Pipeline's dispatch redesign gave this
        codebase its first two runspaces that both walk the filesystem
        concurrently). Reuses the same stack-based per-directory .NET
        walk Get-ZippableLeafDirs/New-ZippableLeafDirProvider/
        Test-ZippableLeafDirCandidate already use.
    .OUTPUTS
        List[System.IO.FileInfo] - every file found, at any depth.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ScanPath
    )

    $results  = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $dirStack = [System.Collections.Generic.Stack[string]]::new()
    $dirStack.Push($ScanPath)

    while ($dirStack.Count -gt 0) {
        $currentDir = $dirStack.Pop()

        # Both enumerations attempted independently - a file-listing
        # failure must NOT skip the subdirectory walk for this same
        # directory (real bug, caught in review: an earlier version
        # `continue`'d out of the loop after the file catch, silently
        # abandoning this directory's whole subtree instead of just its
        # own files - diverged from Get-ChildItem -Recurse -File
        # -ErrorAction SilentlyContinue's own per-item resilience, which
        # this function is meant to match exactly).
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($currentDir)) {
                $results.Add([System.IO.FileInfo]::new($f))
            }
        } catch {
            Write-Log ("Could not enumerate files in '" + $currentDir + "' during recursive file scan - skipping its files, still exploring its subdirectories: " + $_) -Level Warn
        }

        try {
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($currentDir)) {
                $dirStack.Push($d)
            }
        } catch {
            Write-Log ("Could not enumerate subdirectories of '" + $currentDir + "' during recursive file scan - skipping the rest of it, continuing with the rest of the tree: " + $_) -Level Warn
        }
    }

    return ,$results
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

        MANUAL STACK-BASED .NET WALK (2026-09-10, real bug fix - see
        CHANGELOG.md), not Get-ChildItem -Recurse like this function used
        before. Live-reproduced: Get-ChildItem -Recurse (going through
        PowerShell's FileSystem provider) can hang indefinitely - not just
        run slowly - when two runspaces both make their first-ever
        filesystem-provider call at close to the same moment, a real
        engine-level thread-safety gap in the provider's own
        drive/provider initialization on this PS 5.1 install. Full
        Pipeline's dispatch-redesign migration is the first caller in this
        codebase that ever has two runspaces (the image/animated engines)
        both walk the filesystem concurrently for the very first time -
        every other caller of this function runs main-thread-only, so the
        race was never reachable before. New-SeriesProvider (below), which
        already used raw [System.IO.Directory]::EnumerateDirectories
        instead of Get-ChildItem, was NOT affected under the exact same
        concurrent conditions - confirms the provider layer itself, not
        general filesystem concurrency, is what's unsafe here. This walk
        reuses New-ZippableLeafDirProvider's own already-proven
        stack-based approach (see that function's own NOTES for why a
        single flat EnumerateDirectories(..., AllDirectories) enumerator
        isn't used instead - a permission error anywhere in the tree kills
        a flat enumerator's MoveNext() for good) rather than reintroducing
        that already-fixed bug, just collecting into a list instead of
        yielding one candidate per call. Get-FilesRecursiveSafe (below)
        is a THIRD sibling of this same stack-based-walk shape, one level
        up in this file - collecting every FILE instead of qualifying
        leaf directories - added the same day for the same reason.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ScanPath,
        [Parameter(Mandatory)]
        [string[]]$QualifyingExtensions,
        [System.Collections.Generic.HashSet[string]]$ExcludeStagingDirs = $null,
        [bool]$ForceRezip = $false
    )

    # [System.IO.Directory]::Exists, not Test-Path (2026-09-10) - same
    # reasoning as this function's own NOTES above. Called once per
    # SERIES (via Get-SeriesChapters), by both racing engines, many times
    # over a real run - not just once at startup.
    if (-not [System.IO.Directory]::Exists($ScanPath)) {
        throw ("Get-ZippableLeafDirs: -ScanPath does not exist or is not a directory: '" + $ScanPath + "'")
    }

    $results  = [System.Collections.Generic.List[hashtable]]::new()
    $dirStack = [System.Collections.Generic.Stack[string]]::new()
    $dirStack.Push($ScanPath)

    while ($dirStack.Count -gt 0) {
        $currentDir = $dirStack.Pop()
        $enumerator = $null
        try {
            $enumerator = [System.IO.Directory]::EnumerateDirectories($currentDir).GetEnumerator()
        } catch {
            Write-Log ("Could not enumerate '" + $currentDir + "' during leaf-directory scan - skipping it, continuing with the rest of the tree: " + $_) -Level Warn
            continue
        }

        try {
            while ($true) {
                $hasNext = $false
                try {
                    $hasNext = $enumerator.MoveNext()
                } catch {
                    Write-Log ("Leaf-directory scan hit an error partway through '" + $currentDir + "' - skipping the rest of it, continuing with the rest of the tree: " + $_) -Level Warn
                    break
                }
                if (-not $hasNext) { break }

                $childPath = $enumerator.Current
                $dirInfo = [System.IO.DirectoryInfo]::new($childPath)
                $candidate = Test-ZippableLeafDirCandidate -Dir $dirInfo -QualifyingExtensions $QualifyingExtensions `
                    -ExcludeStagingDirs $ExcludeStagingDirs -ForceRezip $ForceRezip
                if ($null -ne $candidate) {
                    $results.Add($candidate)
                } else {
                    # Only push a NON-candidate (same reasoning as
                    # New-ZippableLeafDirProvider's own identical fix, see
                    # that function's own header) - a real candidate is
                    # already a true leaf by Test-ZippableLeafDirCandidate's
                    # own definition, nothing further to explore under it.
                    $dirStack.Push($childPath)
                }
            }
        } finally {
            $enumerator.Dispose()
        }
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
        MANUAL STACK-BASED WALK (2026-08-28, real bug fix - see
        Todo.md/CHANGELOG.md), not a single flat
        [System.IO.Directory]::EnumerateDirectories(...,
        SearchOption.AllDirectories) enumerator like an earlier version of
        this function used. That flat enumerator is genuinely lazy (unlike
        Get-ChildItem captured into a variable, which fully materializes
        before the assignment completes), but a directory that becomes
        inaccessible ANYWHERE in the tree (permissions, a removed network
        share) throws straight out of MoveNext() - and once a .NET
        enumerator's MoveNext() throws, it cannot be resumed, so the ONLY
        way to recover was to give up on the entire rest of the scan.
        Verified live: with one permission-denied folder sitting between
        two real candidates, the old flat-enumerator version returned
        nothing past the denied folder, while the batch path
        (Get-ZippableLeafDirs, via Get-ChildItem -Recurse -ErrorAction
        SilentlyContinue) correctly found both. This function now walks
        one directory LEVEL at a time via a Stack[string] of directories
        still to explore, with each level's own EnumerateDirectories call
        (and each step of iterating it) wrapped in its own try/catch - an
        inaccessible directory now only skips exploring THAT subtree
        (logged as a Warn) and the walk continues with everything else on
        the stack, matching the batch path's own resilience. Each
        directory's own enumerator is also disposed as soon as it's
        exhausted or errors (closing a related gap: the old single flat
        enumerator's underlying native search handle was never disposed at
        all, relying entirely on GC finalization).

        $dirStack is a real, mutable Stack[string] - Push()/Pop() mutate
        the OBJECT's own internal state, they don't reassign the
        $dirStack variable itself, so it persists safely across repeated
        closure invocations the same way this project's other stateful
        providers already do (see New-SeriesProvider below). The
        per-directory enumerator is different: it genuinely needs to be
        REASSIGNED (to a new enumerator, or to $null) as the walk moves
        between directories - and a bare variable reassignment inside a
        .GetNewClosure()'d scriptblock does NOT reliably persist across
        SEPARATE invocations of that closure once dispatched through
        Invoke-ZipParallelProcessing. This is not theoretical: an early
        version of RezipPipeline.ps1's own job provider used exactly a
        bare-scalar reassignment ($zipIndex++) for its own per-call state
        and, live-reproduced, silently restarted from the beginning on
        later calls (see that module's header). Boxed in $state (a
        hashtable) instead, mutated by key - the same pattern
        Controller.ps1's $zipStatsBox and ImageConversionPipeline.ps1's
        $alreadyAbortedBox already use for the identical reason.

        The returned scriptblock is a closure over $dirStack/$state and
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

    if (-not [System.IO.Directory]::Exists($ScanPath)) {
        throw ("New-ZippableLeafDirProvider: -ScanPath does not exist or is not a directory: '" + $ScanPath + "'")
    }

    $dirStack = [System.Collections.Generic.Stack[string]]::new()
    $dirStack.Push($ScanPath)
    $state = @{ CurrentEnumerator = $null }

    return {
        while ($true) {
            if ($null -eq $state.CurrentEnumerator) {
                if ($dirStack.Count -eq 0) { return $null }
                $currentDir = $dirStack.Pop()
                try {
                    $state.CurrentEnumerator = [System.IO.Directory]::EnumerateDirectories($currentDir).GetEnumerator()
                } catch {
                    Write-Log ("Could not enumerate '" + $currentDir + "' during leaf-directory scan - skipping it, continuing with the rest of the tree: " + $_) -Level Warn
                    $state.CurrentEnumerator = $null
                    continue
                }
            }

            $hasNext = $false
            try {
                $hasNext = $state.CurrentEnumerator.MoveNext()
            } catch {
                Write-Log ("Leaf-directory scan hit an error partway through a directory - skipping the rest of it, continuing with the rest of the tree: " + $_) -Level Warn
                $state.CurrentEnumerator.Dispose()
                $state.CurrentEnumerator = $null
                continue
            }

            if (-not $hasNext) {
                $state.CurrentEnumerator.Dispose()
                $state.CurrentEnumerator = $null
                continue
            }

            $childPath = $state.CurrentEnumerator.Current

            $dirInfo = [System.IO.DirectoryInfo]::new($childPath)
            $candidate = Test-ZippableLeafDirCandidate -Dir $dirInfo -QualifyingExtensions $QualifyingExtensions `
                -ExcludeStagingDirs $ExcludeStagingDirs -ForceRezip $ForceRezip
            if ($null -ne $candidate) { return $candidate }

            # Only push a NON-candidate onto the stack (2026-08-31 fix,
            # caught by a same-day /code-review full-codebase pass) - a
            # directory that qualifies as a candidate is, by
            # Test-ZippableLeafDirCandidate's own definition, a true LEAF
            # (it returns $null the moment it finds a subdirectory), so
            # pushing one was pointless work in the best case. In mode 3 it
            # was worse than pointless: the caller (Invoke-ZipOnlyPipeline)
            # dispatches this SAME candidate, its worker zips it and then
            # deletes the folder - the stack is LIFO, so this provider
            # later pops that now-deleted path, EnumerateDirectories throws
            # DirectoryNotFoundException, and the catch above logged a
            # bogus "Could not enumerate ... skipping it" Warn for every
            # single chapter zipped, on every normal `-DeleteFolders $true`
            # run (the default) - burying the real signal that catch
            # exists for (an actual permission-denied subtree) in
            # per-chapter noise. Discovery itself stayed correct either
            # way (a deleted-and-already-returned candidate was never
            # going to be explored further), so this was diagnostics
            # damage, not a real miss.
            $dirStack.Push($childPath)
        }
    }.GetNewClosure()
}

function New-SeriesProvider {
    <#
    .SYNOPSIS
        Returns a scriptblock: each call yields the next SERIES (an
        immediate subdirectory of $LibraryPath - the fixed
        Library > Series > Chapter > Images layout, not a heuristic - see
        this module's header and CLAUDE.md's "Clean Console Output"
        section) as a [System.IO.DirectoryInfo], or $null once the
        library is exhausted.
    .PARAMETER LibraryPath
        The library root (top-level -Path). Validated to exist at the
        time THIS function is called, not re-checked on every subsequent
        scriptblock invocation.
    .OUTPUTS
        [scriptblock] - call repeatedly; returns the next series'
        DirectoryInfo, or $null once exhausted.
    .NOTES
        Uses [System.IO.Directory]::EnumerateDirectories - single level
        only (no -Recurse/AllDirectories, unlike
        New-ZippableLeafDirProvider - series are always exactly one level
        below the library root under the fixed layout) - genuinely lazy,
        same reasoning as New-ZippableLeafDirProvider's own NOTES.
        Simpler than that function in one respect: every immediate
        subdirectory of the library root IS a series by definition, so
        there is no per-item guard/filter loop needed here the way
        Test-ZippableLeafDirCandidate provides for chapters - this
        function can only find the next series or run out, never "skip"
        one.

        Pair this with Get-SeriesChapters (below): call this to get the
        next series, then Get-SeriesChapters to get ITS chapters and a
        real total count before dispatching any of them - see this
        module's header for the full two-tier reasoning.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$LibraryPath
    )
    # [System.IO.Directory]::Exists, not Test-Path (2026-09-10) - same
    # reasoning as Get-ZippableLeafDirs's own NOTES. Called once per
    # runspace, very early in Full Pipeline's two engine workers (right
    # after Add-Type, before anything else) - both racing runspaces make
    # this call at close to the same moment.
    if (-not [System.IO.Directory]::Exists($LibraryPath)) {
        throw ("New-SeriesProvider: -LibraryPath does not exist or is not a directory: '" + $LibraryPath + "'")
    }

    $enumerator = [System.IO.Directory]::EnumerateDirectories($LibraryPath).GetEnumerator()

    return {
        try {
            if ($enumerator.MoveNext()) {
                return [System.IO.DirectoryInfo]::new($enumerator.Current)
            }
        } catch {
            Write-Log ("Series scan stopped early: " + $_) -Level Error
            # Real bug fix (2026-08-28, see Todo.md/CHANGELOG.md): this
            # enumerator's underlying native search handle implements
            # IDisposable and was never disposed anywhere - confirmed live
            # that [System.IO.Directory]::EnumerateDirectories(...).GetEnumerator()'s
            # return type (FileSystemEnumerableIterator) really does
            # implement it. $enumerator is never reassigned in this
            # function (unlike New-ZippableLeafDirProvider's per-directory
            # enumerator above), so disposing it directly here is safe -
            # no boxed-hashtable indirection needed for that reason.
            $enumerator.Dispose()
            return $null
        }
        # Natural exhaustion (MoveNext returned $false, no exception) -
        # same disposal, just the other exit path.
        $enumerator.Dispose()
        return $null
    }.GetNewClosure()
}

function Get-SeriesChapters {
    <#
    .SYNOPSIS
        Eagerly scans ONE series folder for its qualifying chapters - the
        second half of the two-tier model (see New-SeriesProvider). Thin
        wrapper around Get-ZippableLeafDirs - see this module's header
        for why rooting a recursive scan at one series folder is
        equivalent to a single-level scan under the fixed layout, and why
        that means reusing Get-ZippableLeafDirs directly here (rather
        than writing separate scan logic) keeps the guard behavior from
        ever drifting between the whole-library and per-series paths.
        Bounded to one series' worth of filesystem work, not the whole
        library, so calling this per series doesn't reintroduce the hang
        Get-ZippableLeafDirs's own whole-library use already caused.
    .OUTPUTS
        List[hashtable] of @{ Dir; ZipOut } - same shape as
        Get-ZippableLeafDirs. .Count is the real per-series chapter total
        (Start-SeriesProgress's -TotalChapters).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SeriesPath,
        [Parameter(Mandatory)]
        [string[]]$QualifyingExtensions,
        [System.Collections.Generic.HashSet[string]]$ExcludeStagingDirs = $null,
        [bool]$ForceRezip = $false
    )
    $result = Get-ZippableLeafDirs -ScanPath $SeriesPath -QualifyingExtensions $QualifyingExtensions `
        -ExcludeStagingDirs $ExcludeStagingDirs -ForceRezip $ForceRezip

    # Leading comma needed HERE too, at this function's own return, even
    # though $result already came from a comma-protected return one level
    # down (Get-ZippableLeafDirs's own) - each function boundary is its
    # own fresh opportunity for pipeline enumeration to collapse a 0- or
    # 1-element collection. Verified live (Harness Scenario Q/R) that
    # this comma is genuinely required here, not just copied out of
    # caution - same discipline as everywhere else in this project.
    return ,$result
}

function Get-LeafDirectoryDiscoverySharedFunctionNames {
    <#
    .SYNOPSIS
        The function names a caller must add to its own -SharedFunctionNames
        list (Invoke-ZipParallelProcessing) to safely call New-SeriesProvider/
        Get-SeriesChapters from inside a runspace worker - single source of
        truth for this group (see Logging.ps1's Get-LoggingSharedFunctionNames
        for why this exists). First real consumer (2026-09-09): Full
        Pipeline's dispatch-redesign migration (step 4) - each of its two
        concurrent engine workers walks the library itself, inside its own
        runspace, unlike every other caller of these two functions today
        (all main-thread-only). Includes Get-ZippableLeafDirs and
        Test-ZippableLeafDirCandidate too, not just the two public entry
        points - a fresh runspace's InitialSessionState only knows about
        function DEFINITIONS explicitly added to it, so a propagated
        function that calls another user-defined function by name (as
        Get-SeriesChapters calls Get-ZippableLeafDirs, which in turn calls
        Test-ZippableLeafDirCandidate) needs that callee's own name listed
        too, not just the entry point - same convention every other group
        in this codebase follows, verified against
        Modules\_Harness\Lint.Harness.ps1's own Rule 5, which walks this
        exact call graph via AST rather than by hand.
        New-ZippableLeafDirProvider is NOT included - nothing in this
        group's own call graph (New-SeriesProvider/Get-SeriesChapters/
        Get-ZippableLeafDirs/Test-ZippableLeafDirCandidate) calls it.
        Get-FilesRecursiveSafe IS included (2026-09-10) even though
        nothing in THIS module's own call graph calls it - Controller.ps1's
        own $engineWorkerSharedFunctionNames concatenates this getter's
        return value, and ImageConversionPipeline.ps1's Get-LooseImageCandidates/
        AnimatedConversionPipeline.ps1's Get-LooseAnimatedCandidates (both
        already in that same array, both called from inside the same
        runspace worker) now call it too - simplest place for it to live
        given all three call sites already pull this getter in.
    #>
    return @('New-SeriesProvider', 'Get-SeriesChapters', 'Get-ZippableLeafDirs', 'Test-ZippableLeafDirCandidate', 'Get-FilesRecursiveSafe')
}
