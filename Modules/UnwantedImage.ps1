<#
.SYNOPSIS
    UnwantedImage - detects and removes known unwanted images (e.g. ad/
    promo cover pages injected by a specific scan source) via a cheapest-
    first size -> dimensions -> SHA-256 hash match against a known-profile
    table.

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules.

    SOURCE: ported from `Backups\Old Scripts\Delete  Cover -
    Upgrade (2).ps1`, the reference extraction's own choice among six
    variously-named sibling scripts there, based on file date (newest)
    and size (largest) - see Modules\_Reference\UnwantedImage.reference.ps1's
    own header for that reasoning. Covers BOTH phases of the original
    script: PHASE 1 (the profile-match deletion scan,
    Invoke-UnwantedImageScan) and PHASE 2 (the trailing-zero-filename
    audit, Invoke-TrailingZeroAudit - report/log only, never deletes).
    The reference extraction itself only detailed PHASE 1 ("a distinct,
    lower-priority concern from the actual deletion logic" was its own
    framing for PHASE 2) - PHASE 2 was built here from the real source
    script directly rather than from that extraction. PHASE 2 splits
    into a scan/group step (Get-TrailingZeroGroups) and a pure line-
    builder (Get-TrailingZeroReportLines) the same way Summary.ps1 splits
    Get-SummaryLines from Write-SummaryReport - the I/O (writing the
    report file) is Invoke-TrailingZeroAudit's job alone.

    REWORKED per the reference extraction's own explicit list (not a
    straight port):
      - Deletion now goes through FileDeletion.ps1's Remove-Source
        (respects $script:PermanentDelete, Recycle Bin by default) rather
        than the old script's own hardcoded
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile call, which
        always forced Recycle Bin regardless of any project-wide toggle.
        This IS a real behavior change from the original script, made
        deliberately: these are original/source files sitting in the
        user's library, exactly the category this project's own
        deletion-semantics convention (see CLAUDE.md) says should respect
        $PermanentDelete, not original/source files this specific script
        happened to hardcode differently before there was a project-wide
        convention to follow.
      - Logging now goes through Logging.ps1's Write-Log (hash mismatches
        at -Level Warn, the completion line at -Level Summary) instead of
        the old script's own two hand-rolled log files
        (deleted_files_log.txt / hash_mismatch_log.txt) - Write-Log
        already handles full-logging vs. summary-only routing itself, so
        there's no need for a second, separate logging mechanism here.
      - $TargetProfiles is exposed via Get-UnwantedImageProfiles rather
        than a bare script variable, but is STILL a hardcoded table in
        this module's own source, unchanged from the original -
        Todo.md's "easier way to add images/files" idea (pulling the info
        a new profile needs straight from a file, rather than typing it
        in by hand) is a real, separately-discussed future addition, not
        built as part of this port.
      - System.Drawing (Get-ImageDimensions) kept as-is - legacy/
        Windows-only, but this whole project is Windows-only already, and
        nothing about porting this module changes that calculus.

    FORWARD REFERENCES (not defined in this module - callers must
    dot-source the owning module(s) first):
      - Write-Log (Modules\Logging.ps1)
      - Remove-Source, $script:PermanentDelete (Modules\FileDeletion.ps1)

.NOTES
    Extracted from the old standalone script named above - see
    Modules\_Reference\UnwantedImage.reference.ps1 for the verbatim
    source this was built from, with original line numbers and the full
    rework list.
#>

# ---- Required assembly (Get-ImageDimensions) ----
Add-Type -AssemblyName System.Drawing

function Get-UnwantedImageProfiles {
    <#
    .SYNOPSIS
        The known-profile table (Label/Width/Height/SizeBytes/
        SizeTolerance/Hash), as a fresh array each call - never a shared
        reference, so a caller mutating one call's result can't affect
        another's. Still hardcoded here, unchanged from the original
        script - see module header.
    #>
    return @(
    )
}

function Get-ImageDimensions {
    <#
    .SYNOPSIS
        Reads $Path's pixel dimensions via System.Drawing.Image.FromFile,
        always disposing the handle even if something throws after
        FromFile() succeeds. Returns $true on success (writing
        -OutWidth/-OutHeight); $false if the file can't be read as an
        image (does not throw).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [ref]$OutWidth,
        [ref]$OutHeight
    )
    $img = $null
    try {
        $img             = [System.Drawing.Image]::FromFile($Path)
        $OutWidth.Value  = $img.Width
        $OutHeight.Value = $img.Height
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $img) { $img.Dispose() }
    }
}

function Test-UnwantedImageMatch {
    <#
    .SYNOPSIS
        Checks $File against $Profiles, cheapest-first: file size
        (tolerance-bounded) -> pixel dimensions -> SHA-256 hash. The
        first profile whose size+dimensions match decides the outcome -
        remaining profiles are not tried after that, matching the
        original script's own "break on first size+dimension match"
        behavior (two profiles sharing identical size+dimensions but
        different hashes would only ever be checked against the first
        one in the list - true of the original script too, not a
        regression introduced here).
    .OUTPUTS
        @{ Status = 'Match'|'HashMismatch'|'NoMatch'; Profile; Width;
           Height; Hash } - Profile/Width/Height/Hash are all $null for
        'NoMatch'.
    #>
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,
        [Parameter(Mandatory)]
        [array]$Profiles
    )

    foreach ($profile in $Profiles) {
        $sizeDiff = [Math]::Abs($File.Length - $profile.SizeBytes)
        if ($sizeDiff -gt $profile.SizeTolerance) { continue }

        $width  = $null
        $height = $null
        $dimOk  = Get-ImageDimensions -Path $File.FullName -OutWidth ([ref]$width) -OutHeight ([ref]$height)
        if (-not $dimOk) { continue }
        if ($width -ne $profile.Width -or $height -ne $profile.Height) { continue }

        $fileHash = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
        if ($fileHash -ne $profile.Hash) {
            return @{ Status = 'HashMismatch'; Profile = $profile; Width = $width; Height = $height; Hash = $fileHash }
        }
        return @{ Status = 'Match'; Profile = $profile; Width = $width; Height = $height; Hash = $fileHash }
    }

    return @{ Status = 'NoMatch'; Profile = $null; Width = $null; Height = $null; Hash = $null }
}

function Invoke-UnwantedImageScan {
    <#
    .SYNOPSIS
        Scans $Path recursively for image files matching
        Get-UnwantedImageProfiles (or -Profiles, if supplied), deleting
        each match via Remove-Source (respects $script:PermanentDelete);
        a hash mismatch (size+dimensions matched, hash didn't) is logged
        at -Level Warn but never deleted.
    .PARAMETER DryRun
        Logs "WOULD DELETE" and counts as if deleted, without actually
        calling Remove-Source - matches the original script's own -DryRun
        safety feature.
    .PARAMETER ExcludePaths
        Full paths to skip entirely (e.g. a caller's own log files, if
        they happen to sit inside $Path) - optional, defaults to none.
    .OUTPUTS
        @{ ScannedCount; DeletedCount; DeleteFailedCount; HashMismatchCount }
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [array]$Profiles = (Get-UnwantedImageProfiles),
        [string[]]$ImageExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".tiff"),
        [string[]]$ExcludePaths = @(),
        [bool]$DryRun = $false
    )

    $totals = @{
        ScannedCount      = 0
        DeletedCount      = 0
        DeleteFailedCount = 0
        HashMismatchCount = 0
    }

    $excludeSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$ExcludePaths, [System.StringComparer]::OrdinalIgnoreCase)

    $files = Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $ImageExtensions -icontains $_.Extension -and -not $excludeSet.Contains($_.FullName) }

    foreach ($file in $files) {
        $totals.ScannedCount++
        $matchResult = Test-UnwantedImageMatch -File $file -Profiles $Profiles

        if ($matchResult.Status -eq 'HashMismatch') {
            Write-Log ("Hash mismatch (not deleted): [" + $matchResult.Profile.Label + "] '" + $file.FullName + "' | " + $file.Length + " bytes | " + $matchResult.Width + "x" + $matchResult.Height + " | " + $matchResult.Hash) -Level Warn
            $totals.HashMismatchCount++
            continue
        }

        if ($matchResult.Status -ne 'Match') { continue }

        if ($DryRun) {
            Write-Log ("WOULD DELETE: [" + $matchResult.Profile.Label + "] '" + $file.FullName + "' | " + $file.Length + " bytes | " + $matchResult.Width + "x" + $matchResult.Height)
            $totals.DeletedCount++
            continue
        }

        try {
            $null = Remove-Source -ItemPath $file.FullName
            $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
            Write-Log ("Deleted (" + $deleteDesc + "): [" + $matchResult.Profile.Label + "] '" + $file.FullName + "'")
            $totals.DeletedCount++
        } catch {
            Write-Log ("FAILED to delete '" + $file.FullName + "': " + $_) -Level Error
            $totals.DeleteFailedCount++
        }
    }

    Write-Log ("Unwanted-image scan complete: " + $totals.DeletedCount + " deleted, " + $totals.HashMismatchCount + " hash mismatch(es), " + $totals.ScannedCount + " image(s) scanned.") -Level Summary
    return $totals
}

function Test-TrailingZeroName {
    <#
    .SYNOPSIS
        True if $File's base name (extension excluded) ends with one of
        $Suffixes (case-insensitive). Default suffixes are ordered
        longest-first deliberately - EndsWith would otherwise match
        "cover_000.jpg" on "_0" alone if "_0" came before "_000".
    #>
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,
        [string[]]$Suffixes = @("_000", "_00", "_0")
    )
    $base = $File.BaseName
    foreach ($suffix in $Suffixes) {
        if ($base.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-TrailingZeroGroups {
    <#
    .SYNOPSIS
        Scans $Path recursively for ALL files (any extension, not just
        images - a suspicious name matters regardless of file type) whose
        base name ends in a trailing-zero suffix, grouping by SHA-256
        hash so the same content appearing in multiple folders is
        reported once with every location listed. Report/audit only -
        never deletes anything.
    .OUTPUTS
        @{ Groups; HashFailureCount } - Groups is an array of
        @{ FileName; Locations (List[string]); SizeBytes; Width; Height;
        Hash }, in first-seen order. Width/Height are $null when the file
        isn't a readable image (expected - this scan isn't image-only).
        A file that fails to hash (unreadable/locked) is logged at
        -Level Warn, counted in HashFailureCount, and excluded from
        Groups rather than failing the whole scan.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string[]]$Suffixes = @("_000", "_00", "_0"),
        [string[]]$ExcludePaths = @()
    )

    $excludeSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$ExcludePaths, [System.StringComparer]::OrdinalIgnoreCase)
    $seen          = [System.Collections.Generic.Dictionary[string, hashtable]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $orderedHashes = [System.Collections.Generic.List[string]]::new()
    $hashFailureCount = 0

    $files = Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { -not $excludeSet.Contains($_.FullName) }

    foreach ($file in $files) {
        if (-not (Test-TrailingZeroName -File $file -Suffixes $Suffixes)) { continue }

        $width  = $null
        $height = $null
        $null = Get-ImageDimensions -Path $file.FullName -OutWidth ([ref]$width) -OutHeight ([ref]$height)

        try {
            $fileHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
        } catch {
            Write-Log ("Could not hash '" + $file.FullName + "' during trailing-zero audit: " + $_) -Level Warn
            $hashFailureCount++
            continue
        }
        if ([string]::IsNullOrEmpty($fileHash)) {
            Write-Log ("Get-FileHash returned no hash for '" + $file.FullName + "' during trailing-zero audit.") -Level Warn
            $hashFailureCount++
            continue
        }

        $thisDir = $file.DirectoryName
        if ($seen.ContainsKey($fileHash)) {
            $entry = $seen[$fileHash]
            if ($entry.Locations -notcontains $thisDir) { $entry.Locations.Add($thisDir) }
        } else {
            $seen[$fileHash] = @{
                FileName  = $file.Name
                Locations = [System.Collections.Generic.List[string]]@($thisDir)
                SizeBytes = $file.Length
                Width     = $width
                Height    = $height
                Hash      = $fileHash
            }
            $orderedHashes.Add($fileHash)
        }
    }

    $groups = @(foreach ($h in $orderedHashes) { $seen[$h] })
    return @{ Groups = $groups; HashFailureCount = $hashFailureCount }
}

function Get-TrailingZeroReportLines {
    <#
    .SYNOPSIS
        Pure function (no I/O) - builds the report text for
        Get-TrailingZeroGroups' own output shape.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Groups,
        [Parameter(Mandatory)]
        [string]$SearchRoot
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Trailing-Zero Filename Report")
    $lines.Add("Generated  : " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
    $lines.Add("Search root: " + $SearchRoot)
    $lines.Add("=" * 72)
    $lines.Add("")

    $entryNum = 0
    foreach ($e in $Groups) {
        $entryNum++
        $dims = if ($null -ne $e.Width -and $null -ne $e.Height) { $e.Width.ToString() + "x" + $e.Height.ToString() } else { "unknown" }
        $lines.Add("[" + $entryNum + "]  " + $e.FileName)
        $lines.Add("    Hash      : " + $e.Hash)
        $lines.Add("    Size      : " + $e.SizeBytes + " bytes")
        $lines.Add("    Dimensions: " + $dims)
        foreach ($loc in $e.Locations) { $lines.Add("    Location  : " + $loc) }
        $lines.Add("")
    }
    $lines.Add("--- " + $entryNum + " unique file(s) found ---")

    return ,$lines.ToArray()
}

function Invoke-TrailingZeroAudit {
    <#
    .SYNOPSIS
        Runs the trailing-zero filename audit end to end: scan, group,
        write a report file (only when something was actually found -
        matches the original script's own "don't create an empty
        report" behavior), log a summary. Report/audit only - never
        deletes anything.
    .OUTPUTS
        @{ UniqueFileCount; HashFailureCount; ReportPath } - ReportPath
        is $null when nothing was found (no file written).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$ReportPath,
        [string[]]$Suffixes = @("_000", "_00", "_0"),
        [string[]]$ExcludePaths = @()
    )

    $scanResult = Get-TrailingZeroGroups -Path $Path -Suffixes $Suffixes -ExcludePaths $ExcludePaths

    if ($scanResult.Groups.Count -eq 0) {
        Write-Log "Trailing-zero audit: no files with trailing-zero names found." -Level Summary
        return @{ UniqueFileCount = 0; HashFailureCount = $scanResult.HashFailureCount; ReportPath = $null }
    }

    $lines = Get-TrailingZeroReportLines -Groups $scanResult.Groups -SearchRoot $Path
    Set-Content -LiteralPath $ReportPath -Value $lines -Encoding UTF8

    Write-Log ("Trailing-zero audit: " + $scanResult.Groups.Count + " unique file(s) found, report written to '" + $ReportPath + "'.") -Level Summary
    return @{ UniqueFileCount = $scanResult.Groups.Count; HashFailureCount = $scanResult.HashFailureCount; ReportPath = $ReportPath }
}
