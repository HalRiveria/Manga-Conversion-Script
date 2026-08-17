<#
.SYNOPSIS
    ZipCreation - Compress-FolderToZip, the shared folder-to-ZIP step used
    by mode 2 (loose+zip), mode 3 (zip-only), and mode 4 (rezip).

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules. This module owns its own
    Add-Type call for System.IO.Compression.FileSystem rather than relying
    on a caller to have hoisted it - each module self-contained, matching
    FileDeletion.ps1's reasoning. No guard needed: Add-Type -AssemblyName
    is idempotent (verified live elsewhere in this project) - the guard
    ConsoleCtrl needs in AbortPipeline.ps1/ZipParallelProcessing.ps1 is
    specifically for -TypeDefinition, a different case.

    FORWARD REFERENCES (not defined in this module - callers must
    dot-source the owning module first, matching the pattern already
    established by Logging.ps1's Move-ToRecycleBin forward reference):
      - Write-Log (Modules\Logging.ps1)
      - Remove-Source and $script:PermanentDelete (Modules\FileDeletion.ps1) -
        used to clear a pre-existing same-name ZIP before overwriting, and
        to describe (Recycle Bin vs. permanent) how it was cleared.
      - Remove-ItemPermanently (Modules\FileDeletion.ps1) - used to clean up
        a stray/broken ZIP CreateFromDirectory can leave behind when it
        throws (see Compress-FolderToZip's own comment).
    Modules\_Harness\ZipCreation.Harness.ps1 stubs all three, since this
    module must stay standalone-testable without FileDeletion.ps1/
    Logging.ps1 existing.

.NOTES
    Extracted from Conversion Script Main.ps1 - see
    Modules\_Reference\ZipCreation.reference.ps1 for the verbatim source
    this was built from, with original line numbers.
#>

# ---- Required assembly ----
Add-Type -AssemblyName "System.IO.Compression.FileSystem"

function Compress-FolderToZip {
    <#
    .SYNOPSIS
        Creates a ZIP of $SourceDir at $ZipOut, deleting any pre-existing
        file at $ZipOut first (via Remove-Source, so it respects
        $script:PermanentDelete same as any other source deletion).
    .OUTPUTS
        The resulting ZIP's size in bytes (Int64).
    .NOTES
        Propagates whatever CreateFromDirectory itself throws (e.g.
        $SourceDir doesn't exist) - not caught here. Also throws directly
        if, against expectation, the ZIP doesn't exist or is 0 bytes
        immediately after creation.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SourceDir,
        [Parameter(Mandatory)]
        [string]$ZipOut
    )

    if (Test-Path -LiteralPath $ZipOut) {
        # $null = : Remove-Source now returns $true/$false (see
        # FileDeletion.ps1) - uncaptured, that return value would leak
        # into THIS function's own output stream and silently turn the
        # single Int64 $zipSize return into a 2-element array. Caught
        # live via ZipCreation.Harness.ps1 Scenario B (`$sizeB -gt 0`
        # failed with "Cannot convert System.Object[] to Boolean").
        $null = Remove-Source -ItemPath $ZipOut
        $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
        Write-Log ("Deleted existing ZIP (" + $deleteDesc + ") before re-zipping: '" + $ZipOut + "'")
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
        # CreateFromDirectory can leave a stray, broken ZIP file behind even
        # when it throws - verified live: a missing $SourceDir still leaves
        # a 22-byte empty ZIP at $ZipOut before the "directory not found"
        # failure actually surfaces (Harness Scenario C). That debris was
        # never a real "original" file, so clean it up unconditionally via
        # Remove-ItemPermanently (a forward reference to FileDeletion.ps1,
        # same as Remove-Source above) rather than $script:PermanentDelete/
        # Remove-Source - matches CLAUDE.md's deletion-semantics convention
        # for job-generated intermediates that were never legitimate source
        # data to begin with.
        if (Test-Path -LiteralPath $ZipOut) {
            try { $null = Remove-ItemPermanently -ItemPath $ZipOut } catch { }
        }
        throw
    }
}
