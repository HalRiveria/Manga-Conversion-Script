# See module-descriptions.md for this module's full description.

# ---- Required assembly (Recycle Bin support) ----
Add-Type -AssemblyName "Microsoft.VisualBasic"

# RecycleBinProbe: lets Move-ToRecycleBin detect items the Recycle Bin cannot hold (see Move-ToRecycleBin).
if (-not ([System.Management.Automation.PSTypeName]'RecycleBinProbe').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
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

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetDiskFreeSpaceEx(string lpDirectoryName, out ulong lpFreeBytesAvailable, out ulong lpTotalNumberOfBytes, out ulong lpTotalNumberOfFreeBytes);

    private const uint DRIVE_REMOVABLE = 2;
    private const uint DRIVE_REMOTE    = 4;
    private const string BitBucketVolumeKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\";
    private const string ExplorerPolicyKey  = @"Software\Microsoft\Windows\CurrentVersion\Policies\Explorer";

    private sealed class VolumeFacts
    {
        public uint DriveType;
        public bool NukeOnDelete;
        public long CapacityBytes = -1;
        public long TotalBytes = -1;
    }

    private static readonly ConcurrentDictionary<string, VolumeFacts> Cache =
        new ConcurrentDictionary<string, VolumeFacts>(StringComparer.OrdinalIgnoreCase);

    public static uint? TestDriveType;
    public static bool? TestNukeOnDelete;
    public static long? TestCapacityBytes;
    public static bool? TestPolicyNoRecycle;

    public static void ResetCache() { Cache.Clear(); }

    public static void ResetTestOverrides()
    {
        TestDriveType = null; TestNukeOnDelete = null; TestCapacityBytes = null; TestPolicyNoRecycle = null;
        Cache.Clear();
    }

    public static string GetVolumeUnrecyclableReason(string path)
    {
        try { return GetVolumeReason(path); }
        catch { return null; }
    }

    public static string GetUnrecyclableReason(string path)
    {
        try
        {
            string reason = GetVolumeReason(path);
            if (reason != null) { return reason; }
            string root = GetVolumeRoot(path);
            if (root == null) { return null; }
            VolumeFacts facts = GetFacts(root);
            long capacity = TestCapacityBytes.HasValue ? TestCapacityBytes.Value : facts.CapacityBytes;
            if (capacity < 0) { return null; }
            if (!TestCapacityBytes.HasValue && facts.TotalBytes > 0 && capacity >= facts.TotalBytes) { return null; }
            long size = GetItemSize(path);
            if (size > capacity)
            {
                return "it's " + (size / (1024L * 1024L)) + " MB, bigger than this drive's " + (capacity / (1024L * 1024L)) + " MB Recycle Bin limit";
            }
            return null;
        }
        catch { return null; }
    }

    public static long GetCapacityBytes(string path)
    {
        try
        {
            string root = GetVolumeRoot(path);
            return root == null ? -1 : GetFacts(root).CapacityBytes;
        }
        catch { return -1; }
    }

    private static string GetVolumeReason(string path)
    {
        if (path.StartsWith(@"\\")) { return "it's on a network share, which has no Recycle Bin"; }
        bool policy = TestPolicyNoRecycle.HasValue ? TestPolicyNoRecycle.Value : (ReadPolicy(Registry.CurrentUser) || ReadPolicy(Registry.LocalMachine));
        if (policy) { return "the Recycle Bin is turned off by policy on this PC"; }
        string root = GetVolumeRoot(path);
        if (root == null) { return null; }
        VolumeFacts facts = GetFacts(root);
        uint driveType = TestDriveType.HasValue ? TestDriveType.Value : facts.DriveType;
        if (driveType == DRIVE_REMOTE)    { return "it's on a network drive, which has no Recycle Bin"; }
        if (driveType == DRIVE_REMOVABLE) { return "it's on a removable drive, which has no Recycle Bin"; }
        bool nuke = TestNukeOnDelete.HasValue ? TestNukeOnDelete.Value : facts.NukeOnDelete;
        if (nuke) { return "this drive's Recycle Bin is set to delete files immediately"; }
        return null;
    }

    private static bool ReadPolicy(RegistryKey hive)
    {
        using (RegistryKey key = hive.OpenSubKey(ExplorerPolicyKey))
        {
            return key != null && Convert.ToInt32(key.GetValue("NoRecycleFiles", 0)) == 1;
        }
    }

    private static string GetVolumeRoot(string path)
    {
        StringBuilder sb = new StringBuilder(1024);
        return GetVolumePathName(path, sb, (uint)sb.Capacity) ? sb.ToString() : null;
    }

    private static VolumeFacts GetFacts(string root)
    {
        return Cache.GetOrAdd(root, ReadFacts);
    }

    private static VolumeFacts ReadFacts(string root)
    {
        VolumeFacts facts = new VolumeFacts();
        facts.DriveType = GetDriveType(root);
        ulong free, total, totalFree;
        if (GetDiskFreeSpaceEx(root, out free, out total, out totalFree)) { facts.TotalBytes = (long)total; }
        StringBuilder vn = new StringBuilder(1024);
        if (!GetVolumeNameForVolumeMountPoint(root, vn, (uint)vn.Capacity)) { return facts; }
        string volume = vn.ToString();
        int open = volume.IndexOf('{');
        int close = volume.IndexOf('}');
        if (open < 0 || close < open) { return facts; }
        using (RegistryKey key = Registry.CurrentUser.OpenSubKey(BitBucketVolumeKey + volume.Substring(open, close - open + 1)))
        {
            if (key == null) { return facts; }
            facts.NukeOnDelete = Convert.ToInt32(key.GetValue("NukeOnDelete", 0)) == 1;
            object cap = key.GetValue("MaxCapacity");
            if (cap != null) { facts.CapacityBytes = Convert.ToInt64(cap) * 1024L * 1024L; }
        }
        return facts;
    }

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

function Test-VanishedPathException {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $ex = $ErrorRecord.Exception
    return ($ex -is [System.Management.Automation.ItemNotFoundException] -or
            $ex -is [System.IO.FileNotFoundException] -or $ex -is [System.IO.DirectoryNotFoundException] -or
            $ex.InnerException -is [System.IO.FileNotFoundException] -or
            $ex.InnerException -is [System.IO.DirectoryNotFoundException])
}

function Invoke-DeleteTreatingVanishedAsFalse {
    param([Parameter(Mandatory)][scriptblock]$Action)

    try {
        & $Action
        return $true
    } catch {
        if (Test-VanishedPathException -ErrorRecord $_) { return $false }
        throw
    }
}

function Resolve-ItemPathOrNull {
    param([Parameter(Mandatory)][string]$ItemPath)
    try {
        # Rooted paths (every real caller here passes $file.FullName)
        # short-circuit to a raw .NET call instead of
        # $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath
        # - pointless SessionState work for an already-rooted path.
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
    # Never recurses into a reparse point.
    param([Parameter(Mandatory)][string]$DirectoryPath)
    $readOnly = [System.IO.FileAttributes]::ReadOnly
    foreach ($entry in ([System.IO.DirectoryInfo]::new($DirectoryPath)).GetFileSystemInfos()) {
        try {
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
        } catch {
            if (-not (Test-VanishedPathException -ErrorRecord $_)) { throw }
            # A child that vanished mid-walk is already deleted - keep going.
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

function Get-RecycleBinRefusalMessage {
    param([Parameter(Mandatory)][string]$TargetPath, [Parameter(Mandatory)][bool]$PermanentDelete)
    if ($PermanentDelete) { return $null }
    [RecycleBinProbe]::ResetCache()
    $reason = [RecycleBinProbe]::GetVolumeUnrecyclableReason($TargetPath)
    if (-not $reason) { return $null }
    return ("Not starting: files under '" + $TargetPath + "' can't go to the Recycle Bin - " + $reason + ". With Permanent Delete off, nothing would be deleted: every converted source and zipped folder would be left in place and reported as a failure, and no chapter would get zipped. Either turn on Permanent Delete in the options menu (deleted files are then gone for good, not recoverable from a Recycle Bin), or run on a copy of the library on a local drive.")
}

function Get-FileDeletionSharedFunctionNames {
    return @('Remove-Source', 'Move-ToRecycleBin', 'Remove-ItemPermanently', 'Remove-DirectoryTreePermanently', 'Test-VanishedPathException', 'Invoke-DeleteTreatingVanishedAsFalse', 'Resolve-ItemPathOrNull')
}
