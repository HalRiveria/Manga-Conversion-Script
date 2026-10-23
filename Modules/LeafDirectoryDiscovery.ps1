# See module-descriptions.md for this module's full description.

function Test-ZippableLeafDirCandidate {
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
    if ($hasSubDirs) { return $null }

    if ($ExcludeStagingDirs -and $ExcludeStagingDirs.Count -gt 0) {
        $dirPath = $Dir.FullName
        foreach ($stagingDir in $ExcludeStagingDirs) {
            if ($dirPath.Equals($stagingDir, [System.StringComparison]::OrdinalIgnoreCase) -or
                $dirPath.StartsWith($stagingDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $null
            }
        }
    }

    $existingZipsHere = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $qualifyingFiles  = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    try {
        foreach ($f in $Dir.EnumerateFiles()) {
            if ($f.Extension -ieq ".zip") { $existingZipsHere.Add($f) }
            elseif ($QualifyingExtensions -icontains $f.Extension) { $qualifyingFiles.Add($f) }
        }
    } catch { }

    if ($existingZipsHere.Count -gt 0) {
        Write-Log ("SKIPPING '" + $Dir.FullName + "' as a zip candidate: contains " + $existingZipsHere.Count + " existing .zip file(s) directly inside it - likely a container folder left behind after its subfolders were individually zipped, not a genuine leaf. Not zipping to avoid archiving those .zip files into a wrapper.") -Level Warn
        return $null
    }
    if ($qualifyingFiles.Count -eq 0) { return $null }

    $zipOut = [System.IO.Path]::Combine($Dir.Parent.FullName, $Dir.Name + ".zip")

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
    param(
        [Parameter(Mandatory)]
        [string]$ScanPath
    )

    $results  = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $dirStack = [System.Collections.Generic.Stack[string]]::new()
    $dirStack.Push($ScanPath)

    while ($dirStack.Count -gt 0) {
        $currentDir = $dirStack.Pop()

        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($currentDir)) {
                $results.Add([System.IO.FileInfo]::new($f))
            }
        } catch {
            Write-Log ("Could not enumerate files in '" + $currentDir + "' during recursive file scan - skipping its files, still exploring its subdirectories: " + $_) -Level Warn
        }

        try {
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($currentDir)) {
                # Reparse-point guard (2026-09-15 fix, real bug) - a
                # junction/symlink pointing back into an already-visited
                # part of the tree turns this into an unbounded (in
                # practice, MAX_PATH-bounded) cycle, multiplying every file
                # under it once per loop. Confirmed live: one chapter plus
                # one self-pointing junction produced 64 duplicate
                # candidates for the same physical folder before the walk
                # ran out of path length. DOCUMENTED DUPLICATE of the same
                # guard in Get-ZippableLeafDirs/New-ZippableLeafDirProvider/
                # Test-SeriesCategoryFolder/New-SeriesProvider below - keep
                # all five in sync.
                if (([System.IO.File]::GetAttributes($d) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $dirStack.Push($d)
            }
        } catch {
            Write-Log ("Could not enumerate subdirectories of '" + $currentDir + "' during recursive file scan - skipping the rest of it, continuing with the rest of the tree: " + $_) -Level Warn
        }
    }

    return ,$results
}

function Get-ZippableLeafDirs {
    param(
        [Parameter(Mandatory)]
        [string]$ScanPath,
        [Parameter(Mandatory)]
        [string[]]$QualifyingExtensions,
        [System.Collections.Generic.HashSet[string]]$ExcludeStagingDirs = $null,
        [bool]$ForceRezip = $false
    )

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
                # Reparse-point guard (2026-09-15 fix, real bug) - see
                # Get-FilesRecursiveSafe above for the live-reproduced
                # failure mode (a self-pointing junction produced 64
                # duplicate candidates for the same physical folder).
                # Skipped entirely, not just excluded from recursion - a
                # junction/symlink isn't real content this location owns,
                # so it's neither a leaf candidate nor safe to descend
                # into. DOCUMENTED DUPLICATE, keep in sync with the other
                # four copies in this file.
                if (($dirInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $candidate = Test-ZippableLeafDirCandidate -Dir $dirInfo -QualifyingExtensions $QualifyingExtensions `
                    -ExcludeStagingDirs $ExcludeStagingDirs -ForceRezip $ForceRezip
                if ($null -ne $candidate) {
                    $results.Add($candidate)
                } else {
                    $dirStack.Push($childPath)
                }
            }
        } finally {
            $enumerator.Dispose()
        }
    }

    return ,$results
}

function New-ZippableLeafDirProvider {
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
            # Reparse-point guard (2026-09-15 fix, real bug) - DOCUMENTED
            # DUPLICATE of the same guard in Get-FilesRecursiveSafe/
            # Get-ZippableLeafDirs above and Test-SeriesCategoryFolder/
            # New-SeriesProvider below, keep all five in sync. See
            # Get-FilesRecursiveSafe's own comment for the live-reproduced
            # failure mode.
            if (($dirInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $candidate = Test-ZippableLeafDirCandidate -Dir $dirInfo -QualifyingExtensions $QualifyingExtensions `
                -ExcludeStagingDirs $ExcludeStagingDirs -ForceRezip $ForceRezip
            if ($null -ne $candidate) { return $candidate }

            $dirStack.Push($childPath)
        }
    }.GetNewClosure()
}

function Test-SeriesCategoryFolder {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string[]]$QualifyingExtensions
    )
    $extSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$QualifyingExtensions, [System.StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($Path)) {
            $ext = [System.IO.Path]::GetExtension($f)
            if ($ext -ieq ".zip" -or $extSet.Contains($ext)) { return $false }
        }
        $hasSubfolder = $false
        foreach ($d in [System.IO.Directory]::EnumerateDirectories($Path)) {
            # DOCUMENTED DUPLICATE of the reparse-point guard in
            # Get-FilesRecursiveSafe (see there) - keep all five in sync.
            if (([System.IO.File]::GetAttributes($d) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $hasSubfolder = $true
            foreach ($f in [System.IO.Directory]::EnumerateFiles($d)) {
                if ($extSet.Contains([System.IO.Path]::GetExtension($f))) { return $false }
            }
        }
        return $hasSubfolder
    } catch {
        Write-Log ("Could not check whether '" + $Path + "' is a category folder - treating it as a series: " + $_) -Level Warn
        return $false
    }
}

function New-SeriesProvider {
    param(
        [Parameter(Mandatory)]
        [string]$LibraryPath,
        [Parameter(Mandatory)]
        [string[]]$QualifyingExtensions
    )
    if (-not [System.IO.Directory]::Exists($LibraryPath)) {
        throw ("New-SeriesProvider: -LibraryPath does not exist or is not a directory: '" + $LibraryPath + "'")
    }

    $enumeratorStack = [System.Collections.Generic.Stack[object]]::new()
    $enumeratorStack.Push([System.IO.Directory]::EnumerateDirectories($LibraryPath).GetEnumerator())

    return {
        while ($enumeratorStack.Count -gt 0) {
            $top = $enumeratorStack.Peek()
            $dir = $null
            try {
                if ($top.MoveNext()) { $dir = $top.Current }
            } catch {
                Write-Log ("Series scan stopped early for this folder level: " + $_) -Level Error
            }
            if ($null -eq $dir) {
                $top.Dispose()
                $null = $enumeratorStack.Pop()
                continue
            }
            # DOCUMENTED DUPLICATE of the reparse-point guard in
            # Get-FilesRecursiveSafe (see there) - keep all five in sync.
            try {
                $isReparse = ([System.IO.File]::GetAttributes($dir) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            } catch {
                # Folder moved/deleted since it was listed - skip it, same as Test-SeriesCategoryFolder's catch.
                Write-Log ("Series folder '" + $dir + "' vanished during the scan - skipping it: " + $_) -Level Warn
                continue
            }
            if ((-not $isReparse) -and (Test-SeriesCategoryFolder -Path $dir -QualifyingExtensions $QualifyingExtensions)) {
                try {
                    $enumeratorStack.Push([System.IO.Directory]::EnumerateDirectories($dir).GetEnumerator())
                } catch {
                    Write-Log ("Could not list category folder '" + $dir + "' - skipping it: " + $_) -Level Warn
                }
                continue
            }
            return [System.IO.DirectoryInfo]::new($dir)
        }
        return $null
    }.GetNewClosure()
}

function Get-SeriesChapters {
    param(
        [Parameter(Mandatory)]
        [string]$SeriesPath,
        [Parameter(Mandatory)]
        [string[]]$QualifyingExtensions,
        [System.Collections.Generic.HashSet[string]]$ExcludeStagingDirs = $null,
        [bool]$ForceRezip = $false
    )
    # try/catch around a real TOCTOU window (2026-09-15 fix, real bug) -
    # New-SeriesProvider enumerates series lazily, so there's a genuine
    # gap between a series folder being listed and Get-SeriesChapters
    # actually scanning it - someone reorganizing their library mid-scan
    # can delete/rename it in that window. Get-ZippableLeafDirs's own
    # throw for a missing -ScanPath is correct for ITS OWN direct callers
    # (catching a mistyped path at startup), but every OTHER traversal
    # failure in this module is a skip-it-and-log-a-Warn case - this was
    # the one outlier that would kill the entire chapter-dispatch loop
    # for every OTHER series too, not just the one that vanished.
    try {
        $result = Get-ZippableLeafDirs -ScanPath $SeriesPath -QualifyingExtensions $QualifyingExtensions `
            -ExcludeStagingDirs $ExcludeStagingDirs -ForceRezip $ForceRezip
        return ,$result
    } catch {
        Write-Log ("Could not scan series '" + $SeriesPath + "' for chapters - it may have been moved or deleted since it was found: " + $_) -Level Warn
        return ,@()
    }
}

function Get-LeafDirectoryDiscoverySharedFunctionNames {
    return @('New-SeriesProvider', 'Test-SeriesCategoryFolder', 'Get-SeriesChapters', 'Get-ZippableLeafDirs', 'Test-ZippableLeafDirCandidate', 'Get-FilesRecursiveSafe')
}
