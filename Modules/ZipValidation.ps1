<#
.SYNOPSIS
    ZipValidation - Test-ZipArchive, the post-creation ZIP sanity check
    used by mode 2 (loose+zip), mode 3 (zip-only), and mode 4 (rezip).

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules. No cross-module
    dependencies - this module is fully standalone.

    This module owns its own Add-Type call for
    System.IO.Compression.FileSystem rather than relying on a caller to
    have hoisted it - same reasoning as ZipCreation.ps1/FileDeletion.ps1.
    No guard needed: Add-Type -AssemblyName is idempotent (verified live
    elsewhere in this project).

.NOTES
    Extracted from Conversion Script Main.ps1 - see
    Modules\_Reference\ZipValidation.reference.ps1 for the verbatim source
    this was built from, with original line numbers.
#>

# ---- Required assembly ----
Add-Type -AssemblyName "System.IO.Compression.FileSystem"

function Test-ZipArchive {
    <#
    .SYNOPSIS
        Opens $ZipPath and counts its entries (and, among those, how many
        are .jxl). Throws if the archive has 0 entries, or (when
        -RequireJxlEntry is true) if it has entries but none are .jxl.
    .PARAMETER RequireJxlEntry
        Existing callers (ZIP-worker re-zip, loose-folder zip) always deal
        in .jxl output and want this required (the default, $true). The
        zip-only pipeline (mode 3) archives arbitrary, possibly-
        unconverted content, so it passes $false rather than needing a
        third copy of this verification logic.
    .OUTPUTS
        @{ EntryCount = <int>; JxlCount = <int> }
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ZipPath,
        [bool]$RequireJxlEntry = $true
    )

    $archive    = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    $entryCount = 0
    $jxlCount   = 0
    try {
        foreach ($e in $archive.Entries) {
            $entryCount++
            if ($e.FullName -imatch '\.jxl$') { $jxlCount++ }
        }
    } finally {
        $archive.Dispose()
    }

    if ($entryCount -eq 0) { throw ("ZIP archive test returned 0 entries: '" + $ZipPath + "'") }
    if ($RequireJxlEntry -and $jxlCount -eq 0) { throw ("ZIP archive contains no .jxl files after conversion: '" + $ZipPath + "'") }
    return @{ EntryCount = $entryCount; JxlCount = $jxlCount }
}

function Get-ZipValidationSharedFunctionNames {
    <#
    .SYNOPSIS
        The function names a caller must add to its own -SharedFunctionNames
        list (Invoke-ZipParallelProcessing) to safely call Test-ZipArchive
        from inside a runspace worker - single source of truth for this
        group (see Logging.ps1's Get-LoggingSharedFunctionNames for why this
        exists).
    #>
    return @('Test-ZipArchive')
}
