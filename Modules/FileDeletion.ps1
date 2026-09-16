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
        # Rooted paths (every real caller here passes $file.FullName)
        # short-circuit to a raw .NET call instead of
        # $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath
        # (2026-09-16 fix) - that call is reachable from both of Full
        # Pipeline's concurrent engine runspaces via Move-ToRecycleBin/
        # Remove-ItemPermanently, and touches the same PowerShell provider/
        # SessionState machinery that's the confirmed root cause of this
        # project's own PS 5.1 concurrent-runspace cmdlet-race bugs (see
        # Docs/lessons-learned.md) - never proven to hit that exact race
        # itself, but pointless SessionState work for an already-rooted
        # path either way.
        if ([System.IO.Path]::IsPathRooted($ItemPath)) {
            return [System.IO.Path]::GetFullPath($ItemPath)
        }
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
