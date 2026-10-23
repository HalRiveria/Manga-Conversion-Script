# See module-descriptions.md for this module's full description.

function Test-PathSafely {
    param([Parameter(Mandatory)][string]$Path)
    try {
        return (Test-Path -LiteralPath $Path -PathType Leaf)
    } catch [System.ArgumentException] {
        return $false
    } catch [System.IO.PathTooLongException] {
        return $false
    }
}

function Find-Exe {
    param(
        [string]$UserPath,
        [Parameter(Mandatory)]
        [string]$ExeName,
        [string[]]$Candidates = @()
    )

    if ($UserPath -and (Test-PathSafely -Path $UserPath)) { return $UserPath }

    $inPath = Get-Command $ExeName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($inPath -and $inPath.Source) { return $inPath.Source }

    foreach ($c in $Candidates) {
        # $c -and guard (2026-09-15 fix, real bug, latent) - Test-PathSafely's
        # -Path is a Mandatory [string], and PS 5.1 rejects an empty
        # string for a Mandatory string parameter at BIND time, before
        # that function's own try/catch can see it - an empty-string
        # candidate anywhere in the list aborted the ENTIRE search
        # instead of just being skipped, so a real exe at a later
        # candidate path was never found. The near-identical check two
        # lines up (-UserPath) already guards this way; this loop was the
        # one omission. Not reachable from either production call site
        # today (both build their candidate lists from literals plus
        # real Get-ChildItem .FullName values), so latent, not live.
        if ($c -and (Test-PathSafely -Path $c)) { return $c }
    }

    return $null
}

function Find-ExeCached {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,
        [Parameter(Mandatory)]
        [string]$SettingsKey,
        [string]$UserPath,
        [Parameter(Mandatory)]
        [string]$ExeName,
        [string[]]$Candidates = @()
    )

    if ($UserPath -and (Test-PathSafely -Path $UserPath)) {
        return $UserPath
    }

    $cached = $Settings[$SettingsKey]
    if ($cached -and (Test-PathSafely -Path $cached)) {
        return $cached
    }

    $found = Find-Exe -ExeName $ExeName -Candidates $Candidates
    if ($found) {
        $Settings[$SettingsKey] = $found
    }
    return $found
}
