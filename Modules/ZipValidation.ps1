# See module-descriptions.md for this module's full description.

# ---- Required assembly ----
Add-Type -AssemblyName "System.IO.Compression.FileSystem"

function Test-ZipArchive {
    param(
        [Parameter(Mandatory)]
        [string]$ZipPath,
        [bool]$RequireJxlEntry = $true
    )

    # Inside its own try so a missing, locked or corrupt file gets a message
    # naming the zip, not a bare .NET exception.
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    } catch {
        throw ("Could not open '" + $ZipPath + "' to verify it (missing, locked by another program, or not a valid zip): " + $_.Exception.Message)
    }
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
    return @('Test-ZipArchive')
}
