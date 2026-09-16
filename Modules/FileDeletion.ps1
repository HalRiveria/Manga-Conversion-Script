# See Docs/module-descriptions.md for this module's full description.

# ---- Required assembly (Recycle Bin support) ----
Add-Type -AssemblyName "Microsoft.VisualBasic"

# ==============================================================================
#  Module-owned state
# ==============================================================================
$script:PermanentDelete = $false   # set via Initialize-FileDeletion; only read by Remove-Source

function Initialize-FileDeletion {
    param(
        [Parameter(Mandatory)]
        [bool]$PermanentDelete
    )
    $script:PermanentDelete = $PermanentDelete
}

function Invoke-DeleteTreatingVanishedAsFalse {
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

function Resolve-ItemPathOrNull {
    param([Parameter(Mandatory)][string]$ItemPath)
    try {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ItemPath)
    } catch {
        return $null
    }
}

function Move-ToRecycleBin {
    param(
        [Parameter(Mandatory)]
        [string]$ItemPath
    )
    $resolvedItemPath = Resolve-ItemPathOrNull -ItemPath $ItemPath
    if ($null -eq $resolvedItemPath) { return $false }
    $ItemPath = $resolvedItemPath

    return Invoke-DeleteTreatingVanishedAsFalse -Action {
        $attr = [System.IO.File]::GetAttributes($ItemPath)
        if ($attr -band [System.IO.FileAttributes]::Directory) {
            $null = [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $ItemPath,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
            )
        } else {
            $null = [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $ItemPath,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
            )
        }
    }
}

function Remove-ItemPermanently {
    param(
        [Parameter(Mandatory)]
        [string]$ItemPath
    )
    $resolvedItemPath = Resolve-ItemPathOrNull -ItemPath $ItemPath
    if ($null -eq $resolvedItemPath) { return $false }
    $ItemPath = $resolvedItemPath

    return Invoke-DeleteTreatingVanishedAsFalse -Action {
        $attr           = [System.IO.File]::GetAttributes($ItemPath)
        $isDirectory    = [bool]($attr -band [System.IO.FileAttributes]::Directory)
        $isReparsePoint = [bool]($attr -band [System.IO.FileAttributes]::ReparsePoint)

        # Clear ReadOnly before a permanent delete (2026-09-15 fix, real
        # bug) - [System.IO.File]::Delete throws UnauthorizedAccessException
        # on a read-only file, which meant a read-only source survived
        # right next to its already-converted .jxl and was logged as a
        # delete FAILURE. Move-ToRecycleBin (above) already handles this
        # case fine via the VisualBasic FileIO API - this is the one path
        # that didn't. Only strips ReadOnly, not other attributes, and
        # only on the top-level item being deleted (a read-only file
        # nested inside a directory being recursively deleted is a
        # separate, harder problem - see Todo.md).
        if ($attr -band [System.IO.FileAttributes]::ReadOnly) {
            [System.IO.File]::SetAttributes($ItemPath, $attr -bxor [System.IO.FileAttributes]::ReadOnly)
        }

        if ($isDirectory -and $isReparsePoint) {
            [System.IO.Directory]::Delete($ItemPath, $false)
        } elseif ($isDirectory) {
            [System.IO.Directory]::Delete($ItemPath, $true)
        } else {
            [System.IO.File]::Delete($ItemPath)
        }
    }
}

function Remove-Source {
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
    return @('Remove-Source', 'Move-ToRecycleBin', 'Remove-ItemPermanently', 'Invoke-DeleteTreatingVanishedAsFalse', 'Resolve-ItemPathOrNull')
}
