# See Docs/module-descriptions.md for this module's full description.

# ---- Required assembly ----
Add-Type -AssemblyName "System.IO.Compression.FileSystem"

function Compress-FolderToZip {
    param(
        [Parameter(Mandatory)]
        [string]$SourceDir,
        [Parameter(Mandatory)]
        [string]$ZipOut
    )

    if (Test-Path -LiteralPath $ZipOut) {
        $removed = Remove-Source -ItemPath $ZipOut
        if ($removed) {
            $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
            Write-Log ("Deleted existing ZIP (" + $deleteDesc + ") before re-zipping: '" + $ZipOut + "'")
        } else {
            Write-Log ("Existing ZIP already gone before re-zipping (not counted as deleted): '" + $ZipOut + "'") -Level Warn
        }
    }

    try {
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $SourceDir,
            $ZipOut,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $false
        )

        if (-not (Test-Path -LiteralPath $ZipOut)) { throw ("ZIP was not created: '" + $ZipOut + "'") }
        $zipSize = (Get-Item -LiteralPath $ZipOut).Length
        if ($zipSize -eq 0) { throw ("ZIP is 0 bytes: '" + $ZipOut + "'") }
        return $zipSize
    } catch {
        if (Test-Path -LiteralPath $ZipOut) {
            # Swallowed deliberately - this is best-effort cleanup of a
            # zip that failed its own validation above; a failure to
            # delete it shouldn't mask the real error being rethrown
            # right below.
            try { $null = Remove-ItemPermanently -ItemPath $ZipOut } catch { }
        }
        throw
    }
}

function Get-ZipCreationSharedFunctionNames {
    return @('Compress-FolderToZip')
}
