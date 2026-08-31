<#
.SYNOPSIS
    FileDeletion - Move-ToRecycleBin, Remove-ItemPermanently, and the
    Remove-Source wrapper every mode calls to delete an original/source
    file or folder.

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules (matches Logging.ps1/
    AbortPipeline.ps1's pattern). This module owns its own Add-Type call
    for Microsoft.VisualBasic (Recycle Bin support) rather than relying on
    a caller to have hoisted it - each module self-contained. NO GUARD
    NEEDED around it (unlike ConsoleCtrl in AbortPipeline.ps1/
    ZipParallelProcessing.ps1): verified live, in this same project, that
    Add-Type -AssemblyName is idempotent - calling it twice does not
    throw. The guard those two modules use is specifically for
    -TypeDefinition (compiling custom C# source), which DOES throw on a
    duplicate type name - a different case, not applicable here.

    State this module owns: $script:PermanentDelete, set once via
    Initialize-FileDeletion (matches Initialize-LogPaths's "call once
    before anything else" pattern) rather than being re-passed as a
    parameter to every Remove-Source call.

    Deletion-semantics convention (see CLAUDE.md): deletion of
    original/source files goes through Remove-Source, which respects
    $PermanentDelete (Recycle Bin by default). Deletion of job-generated
    intermediates (extracted folders, temp files - never "original" data)
    should call Remove-ItemPermanently directly, unconditionally,
    regardless of $PermanentDelete - Remove-Source is not the right call
    for that case.

    Logging.ps1's Initialize-LogPaths already calls Move-ToRecycleBin as a
    FORWARD REFERENCE (it was built before this module existed for real).
    That call site uses `-ItemPath <string>`, a single file path - matches
    this module's real signature exactly, so no changes needed there now
    that this module exists. Dot-source FileDeletion.ps1 before
    Logging.ps1 (or in either order, as long as both are dot-sourced
    before Initialize-LogPaths's full-logging branch actually runs) so
    Move-ToRecycleBin resolves when that cleanup code executes.

    All three deletion functions return $true if ItemPath existed and was
    processed, $false if it didn't exist (nothing to do) - lets a caller
    log "skipped, already gone" vs. "deleted" instead of assuming the
    latter. This is beyond the original reference extraction, which was
    void.

    Remove-ItemPermanently special-cases directory reparse points
    (junctions/symlinks): a plain recursive Directory.Delete on a reparse
    point is a known .NET footgun that can delete through the link into
    the real target's contents instead of just unlinking it, so that path
    uses a non-recursive delete instead. Verified live against a real
    NTFS junction (Harness Scenarios K/L) that both this and
    Move-ToRecycleBin (via the Shell-based VB FileIO Recycle Bin API,
    which turned out to already be junction-safe without any change)
    correctly unlink only, leaving the real target's contents untouched.

.NOTES
    Extracted from Conversion Script Main.ps1 - see
    Modules\_Reference\FileDeletion.reference.ps1 for the verbatim source
    this was built from, with original line numbers.
#>

# ---- Required assembly (Recycle Bin support) ----
Add-Type -AssemblyName "Microsoft.VisualBasic"

# ==============================================================================
#  Module-owned state
# ==============================================================================
$script:PermanentDelete = $false   # set via Initialize-FileDeletion; only read by Remove-Source

function Initialize-FileDeletion {
    <#
    .SYNOPSIS
        Sets $script:PermanentDelete. Call once, before anything calls
        Remove-Source (Move-ToRecycleBin/Remove-ItemPermanently
        themselves don't depend on this - they're the two unconditional
        branches Remove-Source picks between).
    .PARAMETER PermanentDelete
        $true: Remove-Source bypasses the Recycle Bin entirely.
        $false (default toggle state elsewhere in this project): Remove-Source
        sends the item to the Recycle Bin.
    #>
    param(
        [Parameter(Mandatory)]
        [bool]$PermanentDelete
    )
    $script:PermanentDelete = $PermanentDelete
}

function Invoke-DeleteTreatingVanishedAsFalse {
    <#
    .SYNOPSIS
        Private helper - runs $Action (a delete), returning $true on
        success. A TOCTOU race (the item vanishes between the caller's
        own Test-Path check and here - a concurrent cleanup, antivirus,
        or the user) is treated as $false ("nothing to do"), same as the
        original Test-Path check itself would have returned, rather than
        throwing. Verified live: Get-Item throws ItemNotFoundException
        directly for a missing path; the static .NET/VB FileIO delete
        calls throw MethodInvocationException wrapping a real
        FileNotFoundException/DirectoryNotFoundException as
        .InnerException (PowerShell's own wrapping of a static method
        call's exception) - both shapes are checked here. Any OTHER
        exception (a locked file, a permissions error) still propagates -
        only a genuinely-vanished target is swallowed. Shared by
        Move-ToRecycleBin and Remove-ItemPermanently, which previously
        each carried this exact catch block by hand.
    #>
    param([Parameter(Mandatory)][scriptblock]$Action)

    try {
        & $Action
        return $true
    } catch [System.Management.Automation.ItemNotFoundException] {
        return $false
    } catch {
        if ($_.Exception.InnerException -is [System.IO.FileNotFoundException] -or
            $_.Exception.InnerException -is [System.IO.DirectoryNotFoundException]) {
            return $false
        }
        throw
    }
}

function Move-ToRecycleBin {
    <#
    .SYNOPSIS
        Sends a file or directory to the Recycle Bin. No-ops silently if
        ItemPath doesn't exist. Propagates any exception the underlying
        Recycle Bin operation throws (a locked file, for instance) -
        callers that want a best-effort "clean up if possible" call
        (e.g. Logging.ps1's old-log-file cleanup) wrap this in their own
        try/catch; this function does not swallow errors itself.
    .OUTPUTS
        $true if ItemPath existed and was sent to the Recycle Bin; $false
        if it didn't exist (nothing to do) - lets a caller log "skipped,
        already gone" vs. "deleted" instead of always assuming the latter.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ItemPath
    )
    if (-not (Test-Path -LiteralPath $ItemPath)) { return $false }

    return Invoke-DeleteTreatingVanishedAsFalse -Action {
        $attr = (Get-Item -LiteralPath $ItemPath).Attributes
        if ($attr -band [System.IO.FileAttributes]::Directory) {
            # Verified live (Harness Scenario L) against a real NTFS directory
            # junction: the Shell-based Recycle Bin operation this VB API goes
            # through recycles the junction/link itself, not the target it
            # points at - unlike System.IO.Directory.Delete's recursive=$true
            # footgun below, this one doesn't need a reparse-point special case.
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $ItemPath,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
            ) | Out-Null
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $ItemPath,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
            ) | Out-Null
        }
    }
}

function Remove-ItemPermanently {
    <#
    .SYNOPSIS
        Deletes a file or directory outright, bypassing the Recycle Bin.
        No-ops silently if ItemPath doesn't exist. Also used unconditionally
        (regardless of $PermanentDelete) for job-generated intermediates
        that are never "original" files - see this module's own header
        and CLAUDE.md's deletion-semantics convention.
    .OUTPUTS
        $true if ItemPath existed and was deleted; $false if it didn't
        exist (nothing to do).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ItemPath
    )
    if (-not (Test-Path -LiteralPath $ItemPath)) { return $false }

    return Invoke-DeleteTreatingVanishedAsFalse -Action {
        $attr           = (Get-Item -LiteralPath $ItemPath).Attributes
        $isDirectory    = [bool]($attr -band [System.IO.FileAttributes]::Directory)
        $isReparsePoint = [bool]($attr -band [System.IO.FileAttributes]::ReparsePoint)

        if ($isDirectory -and $isReparsePoint) {
            # Directory junction/symlink - unlink the link itself only, do NOT
            # recurse into whatever it points at. Directory.Delete(path, $true)
            # on a reparse point is a known .NET footgun: recursive=$true can
            # delete through the link into the real target's contents instead
            # of just removing the link - non-recursive delete correctly
            # removes just the link. Verified live against a real NTFS junction
            # (Harness Scenario K): the target directory and its contents
            # survive untouched.
            [System.IO.Directory]::Delete($ItemPath, $false)
        } elseif ($isDirectory) {
            [System.IO.Directory]::Delete($ItemPath, $true)
        } else {
            # A file symlink also carries ReparsePoint, but not Directory, so
            # it lands here - File.Delete on a file symlink already correctly
            # removes just the link, no special case needed.
            [System.IO.File]::Delete($ItemPath)
        }
    }
}

function Remove-Source {
    <#
    .SYNOPSIS
        The call every mode actually uses to delete an original/source
        file or folder - routes to Move-ToRecycleBin or
        Remove-ItemPermanently based on $script:PermanentDelete (set via
        Initialize-FileDeletion). Not meant to be bypassed in favor of
        calling the two branches directly, except for the "always
        permanent" intermediate-cleanup case noted above.
    .OUTPUTS
        Whatever the chosen branch returns - $true if ItemPath existed and
        was processed, $false if it didn't exist.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ItemPath
    )
    if ($script:PermanentDelete) {
        return Remove-ItemPermanently -ItemPath $ItemPath
    } else {
        return Move-ToRecycleBin -ItemPath $ItemPath
    }
}

function Get-FileDeletionSharedFunctionNames {
    <#
    .SYNOPSIS
        The function names a caller must add to its own -SharedFunctionNames
        list (Invoke-ZipParallelProcessing) to safely call Remove-Source (or
        Move-ToRecycleBin/Remove-ItemPermanently directly) from inside a
        runspace worker. Single source of truth for this group - see
        Logging.ps1's Get-LoggingSharedFunctionNames for why this exists.
    #>
    return @('Remove-Source', 'Move-ToRecycleBin', 'Remove-ItemPermanently', 'Invoke-DeleteTreatingVanishedAsFalse')
}
