# See Docs/module-descriptions.md for this module's full description.

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
        if (Test-PathSafely -Path $c) { return $c }
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
