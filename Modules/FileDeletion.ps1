# See Docs/module-descriptions.md for this module's full description.

# ---- Required assembly (Recycle Bin support) ----
Add-Type -AssemblyName "Microsoft.VisualBasic"

# See Docs/function-notes.md (Move-ToRecycleBin) for why this exists.
if (-not ([System.Management.Automation.PSTypeName]'RecycleBinProbe').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32;

public static class RecycleBinProbe
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetVolumePathName(string lpszFileName, StringBuilder lpszVolumePathName, uint cchBufferLength);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetVolumeNameForVolumeMountPoint(string lpszVolumeMountPoint, StringBuilder lpszVolumeName, uint cchBufferLength);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern uint GetDriveType(string lpRootPathName);

    private const uint DRIVE_REMOVABLE = 2;
    private const uint DRIVE_REMOTE    = 4;
    private const string BitBucketVolumeKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\";
    private const string ExplorerPolicyKey  = @"Software\Microsoft\Windows\CurrentVersion\Policies\Explorer";

    // Null = recyclable, or couldn't tell (falls back to the old behavior
    // rather than blocking deletes on a probe failure). Otherwise a
    // human-readable reason the Shell would delete the item permanently.
    public static string GetUnrecyclableReason(string path)
    {
        try
        {
            if (path.StartsWith(@"\\")) { return "it's on a network share, which has no Recycle Bin"; }

            using (RegistryKey policy = Registry.CurrentUser.OpenSubKey(ExplorerPolicyKey))
            {
                if (policy != null && Convert.ToInt32(policy.GetValue("NoRecycleFiles", 0)) == 1)
                {
                    return "the Recycle Bin is turned off by policy on this PC";
                }
            }

            string root = GetVolumeRoot(path);
            if (root == null) { return null; }
            uint driveType = GetDriveType(root);
            if (driveType == DRIVE_REMOTE)    { return "it's on a network drive, which has no Recycle Bin"; }
            if (driveType == DRIVE_REMOVABLE) { return "it's on a removable drive, which has no Recycle Bin"; }

            long capacityBytes;
            bool nukeOnDelete;
            if (!TryReadVolumeSettings(root, out capacityBytes, out nukeOnDelete)) { return null; }
            if (nukeOnDelete) { return "this drive's Recycle Bin is set to delete files immediately"; }
            if (capacityBytes >= 0)
            {
                long size = GetItemSize(path);
                if (size > capacityBytes)
                {
                    return "it's " + (size / (1024L * 1024L)) + " MB, bigger than this drive's " + (capacityBytes / (1024L * 1024L)) + " MB Recycle Bin limit";
                }
            }
            return null;
        }
        catch { return null; }
    }

    // -1 = unknown. Exposed for the harness (sizing a real too-big test file).
    public static long GetCapacityBytes(string path)
    {
        try
        {
            string root = GetVolumeRoot(path);
            long capacityBytes;
            bool nukeOnDelete;
            if (root == null || !TryReadVolumeSettings(root, out capacityBytes, out nukeOnDelete)) { return -1; }
            return capacityBytes;
        }
        catch { return -1; }
    }

    private static string GetVolumeRoot(string path)
    {
        StringBuilder sb = new StringBuilder(1024);
        return GetVolumePathName(path, sb, (uint)sb.Capacity) ? sb.ToString() : null;
    }

    private static bool TryReadVolumeSettings(string root, out long capacityBytes, out bool nukeOnDelete)
    {
        capacityBytes = -1;
        nukeOnDelete  = false;
        StringBuilder vn = new StringBuilder(1024);
        if (!GetVolumeNameForVolumeMountPoint(root, vn, (uint)vn.Capacity)) { return false; }
        string volume = vn.ToString();
        int open = volume.IndexOf('{');
        int close = volume.IndexOf('}');
        if (open < 0 || close < open) { return false; }
        using (RegistryKey key = Registry.CurrentUser.OpenSubKey(BitBucketVolumeKey + volume.Substring(open, close - open + 1)))
        {
            // No key = this volume's bin was never configured; Windows'
            // defaults apply (recycling on, generous size), so treat it as fine.
            if (key == null) { return true; }
            nukeOnDelete = Convert.ToInt32(key.GetValue("NukeOnDelete", 0)) == 1;
            object cap = key.GetValue("MaxCapacity");
            if (cap != null) { capacityBytes = Convert.ToInt64(cap) * 1024L * 1024L; }
            return true;
        }
    }

    // Never follows a reparse point - a junction's target isn't recycled
    // with the folder, so it doesn't count toward its size.
    private static long GetItemSize(string path)
    {
        FileAttributes attr = File.GetAttributes(path);
        if ((attr & FileAttributes.Directory) == 0) { return new FileInfo(path).Length; }
        if ((attr & FileAttributes.ReparsePoint) != 0) { return 0; }
        long total = 0;
        foreach (FileSystemInfo entry in new DirectoryInfo(path).GetFileSystemInfos())
        {
            if ((entry.Attributes & FileAttributes.ReparsePoint) != 0) { continue; }
            if ((entry.Attributes & FileAttributes.Directory) != 0) { total += GetItemSize(entry.FullName); }
            else { total += ((FileInfo)entry).Length; }
        }
        return total;
    }
}
'@ -Language CSharp
}

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
        $unrecyclableReason = [RecycleBinProbe]::GetUnrecyclableReason($ItemPath)
        if ($unrecyclableReason) {
            throw ("Left in place, not deleted: it can't go to the Recycle Bin because " + $unrecyclableReason + " (Windows would delete it permanently instead). Turn on Permanent Delete in the options menu if items like this should be removed.")
        }
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

        if ($attr -band [System.IO.FileAttributes]::ReadOnly) {
            [System.IO.File]::SetAttributes($ItemPath, $attr -bxor [System.IO.FileAttributes]::ReadOnly)
        }

        if ($isDirectory -and $isReparsePoint) {
            [System.IO.Directory]::Delete($ItemPath, $false)
        } elseif ($isDirectory) {
            Remove-DirectoryTreePermanently -DirectoryPath $ItemPath
        } else {
            [System.IO.File]::Delete($ItemPath)
        }
    }
}

function Remove-DirectoryTreePermanently {
    # Never recurses into a reparse point - see Docs/function-notes.md.
    param([Parameter(Mandatory)][string]$DirectoryPath)
    $readOnly = [System.IO.FileAttributes]::ReadOnly
    foreach ($entry in ([System.IO.DirectoryInfo]::new($DirectoryPath)).GetFileSystemInfos()) {
        $attr = $entry.Attributes
        if ($attr -band [System.IO.FileAttributes]::ReparsePoint) {
            if ($attr -band [System.IO.FileAttributes]::Directory) { [System.IO.Directory]::Delete($entry.FullName, $false) }
            else { [System.IO.File]::Delete($entry.FullName) }
            continue
        }
        if ($attr -band $readOnly) { $entry.Attributes = $attr -bxor $readOnly }
        if ($attr -band [System.IO.FileAttributes]::Directory) {
            Remove-DirectoryTreePermanently -DirectoryPath $entry.FullName
        } else {
            [System.IO.File]::Delete($entry.FullName)
        }
    }
    [System.IO.Directory]::Delete($DirectoryPath, $false)
}

function Remove-Source {
    param(
        [Parameter(Mandatory)]
        [string]$ItemPath
    )
    if (Get-WorkerRunspaceValue -Name PermanentDelete) {
        return Remove-ItemPermanently -ItemPath $ItemPath
    } else {
        return Move-ToRecycleBin -ItemPath $ItemPath
    }
}

function Get-FileDeletionSharedFunctionNames {
    return @('Remove-Source', 'Move-ToRecycleBin', 'Remove-ItemPermanently', 'Remove-DirectoryTreePermanently', 'Invoke-DeleteTreatingVanishedAsFalse', 'Resolve-ItemPathOrNull')
}
