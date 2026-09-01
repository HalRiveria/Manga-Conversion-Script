<#
.SYNOPSIS
    DependencyDetection - Find-Exe, a generalized executable-locator used
    for cjxl/magick (and eventually ffmpeg) detection.

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules.

    Built around Convert-AnimatedToJxl.ps1's Find-Exe shape rather than
    keeping the main script's Find-Cjxl/Find-Magick as two near-identical
    hardcoded copies - per the explicit decision in this module's
    reference extraction (Modules\_Reference\DependencyDetection.reference.ps1).
    A caller migrating off Find-Cjxl/Find-Magick calls Find-Exe directly
    with its own -ExeName/-Candidates, rather than through any
    tool-specific wrapper function - none is provided here, on purpose.

    Lookup order: -UserPath (if supplied and it exists) > PATH (via
    Get-Command) > -Candidates, in order > $null if nothing matched.

    Find-ExeCached wraps Find-Exe with a settings-hashtable-backed cache
    (see Modules\Config.ps1) so a caller doesn't repeat the PATH/
    -Candidates search every single run once a tool's been found once.
    It takes/mutates a plain hashtable rather than depending on
    Config.ps1's Import-/Export-ScriptSettings directly, so this module
    stays standalone (no cross-module dependency, no forward reference to
    load/save) - the caller owns loading the settings in and persisting
    them back out (e.g. Import-ScriptSettings before, Export-ScriptSettings
    after).

.EXAMPLE
    Find-Exe -UserPath $CjxlPath -ExeName "cjxl" -Candidates @(
        ($env:ProgramFiles + "\libjxl\cjxl.exe"),
        ($env:ProgramFiles + "\cjxl\cjxl.exe"),
        ($env:LOCALAPPDATA + "\Programs\libjxl\cjxl.exe"),
        "C:\tools\cjxl.exe"
    )

.EXAMPLE
    Find-Exe -UserPath $MagickPath -ExeName "magick" -Candidates @(
        ($env:ProgramFiles + "\ImageMagick-7\magick.exe"),
        ($env:ProgramFiles + "\ImageMagick\magick.exe"),
        ($env:ProgramFiles + " (x86)\ImageMagick-7\magick.exe"),
        ($env:LOCALAPPDATA + "\Programs\ImageMagick\magick.exe"),
        "C:\tools\ImageMagick\magick.exe"
    )

.NOTES
    Extracted from Conversion Script Main.ps1 (Find-Cjxl/Find-Magick) and
    Backups\Old Scripts\Convert-AnimatedToJxl.ps1 (Find-Exe, the shape
    this module is built around) - see
    Modules\_Reference\DependencyDetection.reference.ps1 for the verbatim
    source, with original line numbers.
#>

function Test-PathSafely {
    <#
    .SYNOPSIS
        Internal helper - Test-Path, but a malformed path (illegal
        characters, etc.) is treated the same as "doesn't exist" ($false)
        instead of throwing. Verified live: Test-Path throws a real
        System.ArgumentException for a path containing characters like
        "|"/"<"/">" under $ErrorActionPreference = 'Stop' (the real
        script's own setting) - without this, Find-Exe/Find-ExeCached's
        own documented "a stale/wrong -UserPath falls through" contract
        only actually held for a NONEXISTENT path, not a malformed one.
        A System.IO.PathTooLongException (an excessively long path) is
        the same class of "can't evaluate this path" problem and is
        caught here too.
    #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        return (Test-Path -LiteralPath $Path)
    } catch [System.ArgumentException] {
        return $false
    } catch [System.IO.PathTooLongException] {
        return $false
    }
}

function Find-Exe {
    <#
    .SYNOPSIS
        Locates an executable: -UserPath override, then PATH, then a
        fallback -Candidates list, in that order. Returns $null if none
        of those found it - callers decide whether that's fatal (cjxl is
        required; magick is only required when WebP input is present).
    .PARAMETER UserPath
        Optional explicit path (e.g. from a script parameter). Used only
        if it's non-empty AND actually exists - a stale/wrong -UserPath
        falls through to PATH/-Candidates rather than failing outright.
    .PARAMETER ExeName
        The command name to look up via Get-Command (PATH search) - e.g.
        "cjxl", "magick", "ffmpeg". Does not need the .exe extension.
    .PARAMETER Candidates
        Full paths tried in order, after PATH, before giving up.
    #>
    param(
        [string]$UserPath,
        [Parameter(Mandatory)]
        [string]$ExeName,
        [string[]]$Candidates = @()
    )

    if ($UserPath -and (Test-PathSafely -Path $UserPath)) { return $UserPath }

    # -CommandType Application, and a non-empty .Source check (2026-08-31
    # fix, caught by a same-day /code-review full-codebase pass) - without
    # -CommandType, Get-Command also matches a function or alias that
    # happens to share $ExeName (a "magick"/"cjxl" helper in the user's
    # own PowerShell profile is a real, not hypothetical, case) - its
    # .Source is an EMPTY STRING, not $null, which is still truthy for
    # $inPath's own if-check, so this returned "" instead of falling
    # through to -Candidates: a real exe sitting at a candidate path was
    # never found, and the docstring's "Returns $null if none of those
    # found it" contract broke (a caller checking $null -eq $result saw a
    # false hit on "").
    $inPath = Get-Command $ExeName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($inPath -and $inPath.Source) { return $inPath.Source }

    foreach ($c in $Candidates) {
        if (Test-PathSafely -Path $c) { return $c }
    }

    return $null
}

function Find-ExeCached {
    <#
    .SYNOPSIS
        Find-Exe, but checks a cached path in $Settings[$SettingsKey]
        first (if it's still valid) before falling back to a fresh
        PATH/-Candidates search - and remembers a fresh result by writing
        it back into $Settings (mutated in place; caller persists it,
        e.g. via Config.ps1's Export-ScriptSettings).
    .PARAMETER Settings
        A settings hashtable (as returned by Config.ps1's
        Import-ScriptSettings). Mutated in place when a fresh detection
        succeeds - the caller decides whether/when to save it.
    .PARAMETER SettingsKey
        Which key in $Settings holds the cached path, e.g. "CjxlPath".
    .PARAMETER UserPath
        Same meaning as Find-Exe's -UserPath: an explicit one-off
        override. Takes priority over the cache, and deliberately does
        NOT get written back into the cache - a one-time override
        shouldn't silently become the new default for every future run.
    .DESCRIPTION
        Priority order: -UserPath (if it exists) > cached path in
        $Settings (if it still exists on disk) > fresh Find-Exe search
        (PATH, then -Candidates) - and a fresh search's result, if found,
        is written into $Settings[$SettingsKey] so the next call can use
        the cache instead. A stale cached path (tool moved/uninstalled)
        is treated exactly like Find-Exe treats a stale -UserPath: falls
        through to a fresh search rather than being trusted blindly.
    #>
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
