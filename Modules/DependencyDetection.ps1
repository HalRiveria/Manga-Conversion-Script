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

    if ($UserPath -and (Test-Path -LiteralPath $UserPath)) { return $UserPath }

    $inPath = Get-Command $ExeName -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }

    foreach ($c in $Candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }

    return $null
}
