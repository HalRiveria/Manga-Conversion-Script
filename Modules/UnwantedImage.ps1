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
      - System.Drawing (Get-ImageDimensions) kept as-is - legacy/
        Windows-only, but this whole project is Windows-only already, and
        nothing about porting this module changes that calculus.

    PROFILE PERSISTENCE (added 2026-08-27, per explicit follow-up
    request - "point the script at an image and have it pull the info
    and add it... automatically"): $TargetProfiles is still exposed via
    Get-UnwantedImageProfiles as a hardcoded table, unchanged - but
    that's now only the BUILT-IN half. A separate persisted store lives
    at Get-UnwantedImageProfilesPath's location
    (%LOCALAPPDATA%\ConversionScript\unwanted-image-profiles.json - same
    base directory as Config.ps1's settings.json, but its own file, not
    folded into it) via Import-/Export-UnwantedImageProfiles, matching
    Config.ps1's own resilience convention (missing file -> empty,
    corrupt file -> backed up + Warn, never thrown). Get-AllUnwantedImageProfiles
    combines built-in + persisted, and is what Invoke-UnwantedImageScan
    actually matches against by default now (still overridable via
    -Profiles). Add-UnwantedImageProfileFromFile is the actual feature
    requested: builds a real profile from a real image file
    (New-UnwantedImageProfileFromFile - dimensions/size/hash all read
    from the file, not typed in by hand) and persists it
    (Add-UnwantedImageProfile, which refuses a duplicate hash rather than
    adding one) in one call - so it's picked up automatically by every
    future scan, no further wiring needed. Show-AddUnwantedImageProfileFlow
    is the interactive console flow around that (prompt for path -> prompt
    for label -> show what was actually read from the file -> require an
    explicit Y confirmation before persisting -> report the outcome) - the
    design (preview+confirm, a duplicate just informs rather than offering
    a rename, one add per visit, fixed default tolerance) was settled with
    the project owner before it was built. Wired into Menu.ps1's "5 -
    Cover Deletion" submenu (Show-CoverDeletionMenu) as its "2 - Add
    Image" item.

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

function Get-UnwantedImageProfilesPath {
    <#
    .SYNOPSIS
        "<BaseDir>\ConversionScript\unwanted-image-profiles.json" - the
        one place this filename is decided. Same base directory
        Config.ps1's settings.json lives in (Get-ScriptSettingsPath),
        but its own separate file - profiles are a growing list of
        target signatures, not a settings toggle, matching this
        project's own precedent of resume-state living in its own file
        rather than being folded into settings.json.
    #>
    param([string]$BaseDir)

    if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = $env:LOCALAPPDATA }
    return (Join-Path $BaseDir "ConversionScript\unwanted-image-profiles.json")
}

function Get-TrailingZeroReportPath {
    <#
    .SYNOPSIS
        "<BaseDir>\ConversionScript\trailing-zero-report.txt" (2026-08-31
        addition, for Menu.ps1's Cover Deletion submenu item 5) - same
        base directory as Get-UnwantedImageProfilesPath/settings.json,
        same "one place this filename is decided" precedent. Overwritten
        on every run - Invoke-TrailingZeroAudit's own report is a
        point-in-time scan result, not something to accumulate.
    #>
    param([string]$BaseDir)

    if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = $env:LOCALAPPDATA }
    return (Join-Path $BaseDir "ConversionScript\trailing-zero-report.txt")
}

function Import-UnwantedImageProfiles {
    <#
    .SYNOPSIS
        Loads user-added profiles from $ProfilesPath - just those, NOT
        the hardcoded built-in table (see Get-AllUnwantedImageProfiles
        for the combined view). A missing file returns an empty array
        silently; a corrupt/unparsable file returns an empty array with
        a Write-Log Warn and backs up the bad file
        (.corrupt-<timestamp>.bak) rather than throwing or silently
        discarding it - same resilience convention as Config.ps1's
        Import-ScriptSettings.
    #>
    param([string]$ProfilesPath = (Get-UnwantedImageProfilesPath))

    if (-not (Test-Path -LiteralPath $ProfilesPath)) { return @() }

    try {
        $raw = [System.IO.File]::ReadAllText($ProfilesPath) | ConvertFrom-Json
    } catch {
        Write-Log ("Could not read unwanted-image profiles file '" + $ProfilesPath + "' - starting with none. (" + $_ + ")") -Level Warn
        $backupPath = $ProfilesPath + ".corrupt-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".bak"
        try { Copy-Item -LiteralPath $ProfilesPath -Destination $backupPath -Force -ErrorAction Stop } catch { }
        return @()
    }

    $profiles = @(foreach ($p in $raw) {
        @{
            Label         = $p.Label
            Width         = [int]$p.Width
            Height        = [int]$p.Height
            SizeBytes     = [int64]$p.SizeBytes
            SizeTolerance = [int]$p.SizeTolerance
            Hash          = $p.Hash
        }
    })
    return ,$profiles
}

function Export-UnwantedImageProfiles {
    <#
    .SYNOPSIS
        Writes $Profiles to $ProfilesPath as a proper JSON array
        regardless of count (0, 1, or many) - via -InputObject rather
        than the pipeline, same array-safety technique
        ResumeState.ps1's Merge-ResumeStateEntries uses (PS 5.1's
        ConvertTo-Json has no -AsArray; piping a single object through
        it serializes a bare object instead of a one-element array).
        Creates the parent directory if it doesn't exist yet.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Profiles,
        [string]$ProfilesPath = (Get-UnwantedImageProfilesPath)
    )

    $dir = Split-Path -Path $ProfilesPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $json = ConvertTo-Json -InputObject $Profiles -Depth 5
    Set-Content -LiteralPath $ProfilesPath -Value $json -Encoding UTF8
}

function Get-AllUnwantedImageProfiles {
    <#
    .SYNOPSIS
        The hardcoded built-in profiles (Get-UnwantedImageProfiles) plus
        whatever's been persisted at $ProfilesPath (Import-UnwantedImageProfiles)
        - this is what Invoke-UnwantedImageScan actually matches against
        by default, so a profile added via Add-UnwantedImageProfileFromFile
        is picked up automatically on the next scan without any extra
        wiring.
    #>
    param([string]$ProfilesPath = (Get-UnwantedImageProfilesPath))

    # Get-UnwantedImageProfiles does NOT comma-guard its own return (a
    # plain `return @(...)` of 5 items), so @() here is the correct,
    # single layer of protection for it. Import-UnwantedImageProfiles
    # DOES already comma-guard internally - wrapping ITS call in @() as
    # well would double-protect it (the comma-guard's single-object
    # pipeline emission, itself an array, gets re-collected as one
    # element of a NEW outer array) - captured directly instead, exactly
    # once protected, not twice.
    $builtIn   = @(Get-UnwantedImageProfiles)
    $persisted = Import-UnwantedImageProfiles -ProfilesPath $ProfilesPath
    return ,($builtIn + $persisted)
}

function New-UnwantedImageProfileFromFile {
    <#
    .SYNOPSIS
        Builds a profile hashtable FROM a real image file - pixel
        dimensions (Get-ImageDimensions), file size, and SHA-256 hash
        are all read from $Path directly, not typed in by hand. Throws
        if $Path can't be read as an image (Get-ImageDimensions fails) -
        a profile with no real dimensions would never match anything and
        isn't worth silently creating.
    .PARAMETER Label
        Defaults to the file's own name if not supplied.
    .PARAMETER SizeTolerance
        Defaults to 5000 bytes, matching every built-in profile's own
        tolerance.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$Label,
        [int]$SizeTolerance = 5000
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ("New-UnwantedImageProfileFromFile: '" + $Path + "' does not exist.")
    }
    $file = Get-Item -LiteralPath $Path

    $width  = $null
    $height = $null
    $dimOk  = Get-ImageDimensions -Path $file.FullName -OutWidth ([ref]$width) -OutHeight ([ref]$height)
    if (-not $dimOk) {
        throw ("New-UnwantedImageProfileFromFile: '" + $Path + "' could not be read as an image.")
    }

    if ([string]::IsNullOrWhiteSpace($Label)) { $Label = $file.Name }

    return @{
        Label         = $Label
        Width         = $width
        Height        = $height
        SizeBytes     = $file.Length
        SizeTolerance = $SizeTolerance
        Hash          = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
}

function Add-UnwantedImageProfile {
    <#
    .SYNOPSIS
        Persists $Profile at $ProfilesPath, appended to whatever's
        already there. Refuses (does not add, does not throw) a profile
        whose Hash already matches an existing one - built-in OR already-
        persisted - checked via Get-AllUnwantedImageProfiles, so the
        same image can't get added twice under different labels.
    .OUTPUTS
        @{ Added = <bool>; Reason = <string, only set when Added is
        $false>; ExistingProfile = <the conflicting profile hashtable,
        only set when Added is $false due to a duplicate hash - lets a
        caller report which existing profile it collided with without
        re-scanning for it itself> }
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Profile,
        [string]$ProfilesPath = (Get-UnwantedImageProfilesPath)
    )

    $existing = Get-AllUnwantedImageProfiles -ProfilesPath $ProfilesPath
    $conflict = $existing | Where-Object { $_.Hash -eq $Profile.Hash } | Select-Object -First 1
    if ($conflict) {
        Write-Log ("Not adding unwanted-image profile '" + $Profile.Label + "' - a profile with the same hash already exists.") -Level Warn
        return @{ Added = $false; Reason = "A profile with the same hash already exists."; ExistingProfile = $conflict }
    }

    $userProfiles = Import-UnwantedImageProfiles -ProfilesPath $ProfilesPath
    $userProfiles = @($userProfiles) + @($Profile)
    Export-UnwantedImageProfiles -Profiles $userProfiles -ProfilesPath $ProfilesPath

    Write-Log ("Added unwanted-image profile '" + $Profile.Label + "' (" + $Profile.Width + "x" + $Profile.Height + ", " + $Profile.SizeBytes + " bytes) to '" + $ProfilesPath + "'.") -Level Summary
    return @{ Added = $true; Reason = $null; ExistingProfile = $null }
}

function Add-UnwantedImageProfileFromFile {
    <#
    .SYNOPSIS
        The actual "point it at an image and have it pull the info and
        add it automatically" feature: builds a profile from a real
        image file (New-UnwantedImageProfileFromFile) and persists it
        (Add-UnwantedImageProfile) in one call, so it's picked up by
        every future Invoke-UnwantedImageScan call (via
        Get-AllUnwantedImageProfiles, its default -Profiles source) with
        no further wiring needed.
    .OUTPUTS
        @{ Added = <bool>; Reason = <string or $null>; Profile = <the
        built profile hashtable> }
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$Label,
        [int]$SizeTolerance = 5000,
        [string]$ProfilesPath = (Get-UnwantedImageProfilesPath)
    )

    $profile = New-UnwantedImageProfileFromFile -Path $Path -Label $Label -SizeTolerance $SizeTolerance
    $addResult = Add-UnwantedImageProfile -Profile $profile -ProfilesPath $ProfilesPath

    return @{ Added = $addResult.Added; Reason = $addResult.Reason; Profile = $profile }
}

function Show-AddUnwantedImageProfileFlow {
    <#
    .SYNOPSIS
        The interactive "add an unwanted-image profile" flow: prompts for
        an image path (drag-and-drop or a pasted/typed path both work -
        any Read-Host prompt accepts a dropped file in a Windows
        console), a label (blank defaults to the file's own name), shows
        what was actually read from the file (dimensions/size/hash), and
        requires an explicit Y confirmation before persisting - a wrong
        image here would get auto-deleted on every future scan, so this
        is a real safety check, not a formality. A duplicate hash is
        reported (naming the existing profile's Label) rather than
        added again. Design settled with the project owner before this
        was built: preview+confirm (not immediate-add), duplicate just
        informs rather than offering to rename the existing entry, adds
        exactly one profile then returns (no "add another?" loop), and
        always uses the default 5000-byte SizeTolerance (not prompted
        per-profile).
    .PARAMETER PromptFunc
        Defaults to a thin Read-Host wrapper. Injectable for testing -
        same "inject the real dependency, let a harness override it"
        pattern Menu.ps1's Show-ModeMenu/Show-OptionsMenuLevel already
        established, for the same reason: a harness can drive the whole
        interactive flow without simulating real stdin.
    .OUTPUTS
        @{ Added = <bool>; Reason = <string, set for every non-Added
        outcome - "no path entered"/"cancelled by file-read error"/
        "cancelled by user"/"a profile with the same hash already
        exists"> ; Profile = <the built profile, or $null if the file
        couldn't be read>; ExistingLabel = <set only on a duplicate> }
    #>
    param(
        [string]$ProfilesPath = (Get-UnwantedImageProfilesPath),
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message }
    )

    $path = (& $PromptFunc "Enter the path to the image (drag & drop the file in, or paste the path)")
    if ($null -ne $path) { $path = $path.Trim().Trim('"') }
    if ([string]::IsNullOrWhiteSpace($path)) {
        Write-Host "No path entered - cancelled." -ForegroundColor Yellow
        return @{ Added = $false; Reason = "No path entered."; Profile = $null }
    }

    $label = (& $PromptFunc "Label for this profile (Enter to use the filename)")
    if ($null -ne $label) { $label = $label.Trim() }

    $profile = $null
    try {
        if ([string]::IsNullOrWhiteSpace($label)) {
            $profile = New-UnwantedImageProfileFromFile -Path $path
        } else {
            $profile = New-UnwantedImageProfileFromFile -Path $path -Label $label
        }
    } catch {
        Write-Host ("Could not read '" + $path + "' as an image: " + $_) -ForegroundColor Red
        return @{ Added = $false; Reason = "Cancelled by file-read error: " + $_; Profile = $null }
    }

    Write-Host ""
    Write-Host "Pulled from the file:" -ForegroundColor Cyan
    Write-Host ("  Width      : " + $profile.Width)
    Write-Host ("  Height     : " + $profile.Height)
    Write-Host ("  Size       : " + $profile.SizeBytes + " bytes")
    Write-Host ("  SHA-256    : " + $profile.Hash)
    Write-Host ""

    $confirm = (& $PromptFunc "Add this as a new unwanted-image profile? (Y/N)")
    if ($null -eq $confirm -or $confirm.Trim() -notmatch '^(?i:y|yes)$') {
        Write-Host "Cancelled - not added." -ForegroundColor Yellow
        return @{ Added = $false; Reason = "Cancelled by user."; Profile = $profile }
    }

    $addResult = Add-UnwantedImageProfile -Profile $profile -ProfilesPath $ProfilesPath
    if ($addResult.Added) {
        Write-Host ("Added '" + $profile.Label + "' - will be caught on every future scan.") -ForegroundColor Green
        return @{ Added = $true; Reason = $null; Profile = $profile }
    }

    # Add-UnwantedImageProfile already found the conflicting profile
    # internally (it has to, to detect the duplicate in the first place)
    # and returns it directly as -ExistingProfile - no need to re-scan
    # Get-AllUnwantedImageProfiles a second time just to find it again.
    $existingLabel = $addResult.ExistingProfile.Label
    Write-Host ("Not added - already tracked as '" + $existingLabel + "'.") -ForegroundColor Yellow
    return @{ Added = $false; Reason = $addResult.Reason; Profile = $profile; ExistingLabel = $existingLabel }
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
        @{ Status = 'Match'|'HashMismatch'|'HashFailure'|'NoMatch'; Profile;
           Width; Height; Hash } - Profile/Width/Height/Hash are all $null
        for 'NoMatch'.
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

        # try/catch (2026-09-02 review fix): Get-FileHash used to run bare,
        # unlike Get-TrailingZeroGroups's own identical call further down
        # this file - with the bootstrap's $ErrorActionPreference = 'Stop'
        # inherited into this function, a file that disappears or gets
        # locked (a sync client, an indexer, another app) in the window
        # between the Get-ImageDimensions call above and this line throws
        # a terminating error here. A size+dimension match is exactly the
        # moment this function is most likely to be looking at a real,
        # externally-touched file, not a made-up edge case. Same
        # treatment as Get-TrailingZeroGroups: log a Warn and give up on
        # this file (retrying against another profile would just hit the
        # same failure again), rather than letting it escape uncaught -
        # see Invoke-MainLoop's own matching fix for why an uncaught throw
        # here used to take down the whole script instead of just this
        # one scan.
        try {
            $fileHash = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
        } catch {
            Write-Log ("Could not hash '" + $File.FullName + "' during unwanted-image scan: " + $_) -Level Warn
            return @{ Status = 'HashFailure'; Profile = $profile; Width = $width; Height = $height; Hash = $null }
        }
        if ($fileHash -ne $profile.Hash) {
            return @{ Status = 'HashMismatch'; Profile = $profile; Width = $width; Height = $height; Hash = $fileHash }
        }
        return @{ Status = 'Match'; Profile = $profile; Width = $width; Height = $height; Hash = $fileHash }
    }

    return @{ Status = 'NoMatch'; Profile = $null; Width = $null; Height = $null; Hash = $null }
}

function Get-ScannableFiles {
    <#
    .SYNOPSIS
        Private helper - recursively lists files under $Path, excluding
        anything in $ExcludePaths, optionally filtered to
        $ImageExtensions. Shared by Invoke-UnwantedImageScan (image-only)
        and Get-TrailingZeroGroups (every file type), which previously
        each built the same exclude-set + Get-ChildItem -Recurse -File
        scan by hand.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string[]]$ExcludePaths = @(),
        [string[]]$ImageExtensions = $null
    )

    $excludeSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$ExcludePaths, [System.StringComparer]::OrdinalIgnoreCase)

    return Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        (-not $excludeSet.Contains($_.FullName)) -and
        ($null -eq $ImageExtensions -or $ImageExtensions -icontains $_.Extension)
    }
}

function Invoke-UnwantedImageScan {
    <#
    .SYNOPSIS
        Scans $Path recursively for image files matching
        Get-AllUnwantedImageProfiles - built-in profiles plus anything
        persisted via Add-UnwantedImageProfileFromFile (or -Profiles, if
        supplied, to override entirely) - deleting each match via
        Remove-Source (respects $script:PermanentDelete); a hash mismatch
        (size+dimensions matched, hash didn't) is logged at -Level Warn
        but never deleted.
    .PARAMETER DryRun
        Logs "WOULD DELETE" and counts as if deleted, without actually
        calling Remove-Source - matches the original script's own -DryRun
        safety feature.
    .PARAMETER ExcludePaths
        Full paths to skip entirely (e.g. a caller's own log files, if
        they happen to sit inside $Path) - optional, defaults to none.
    .OUTPUTS
        @{ ScannedCount; DeletedCount; DeleteFailedCount; HashMismatchCount;
           HashFailureCount } - HashFailureCount (2026-09-02 review fix)
        counts a file Test-UnwantedImageMatch couldn't hash at all (already
        logged as its own Warn there) - distinct from HashMismatchCount
        (hashed fine, just didn't match), same distinction
        Get-TrailingZeroGroups's own HashFailureCount already makes.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [array]$Profiles = (Get-AllUnwantedImageProfiles),
        [string[]]$ImageExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".tiff"),
        [string[]]$ExcludePaths = @(),
        [bool]$DryRun = $false
    )

    $totals = @{
        ScannedCount      = 0
        DeletedCount      = 0
        DeleteFailedCount = 0
        HashMismatchCount = 0
        HashFailureCount  = 0
    }

    $files = Get-ScannableFiles -Path $Path -ExcludePaths $ExcludePaths -ImageExtensions $ImageExtensions

    foreach ($file in $files) {
        $totals.ScannedCount++
        $matchResult = Test-UnwantedImageMatch -File $file -Profiles $Profiles

        if ($matchResult.Status -eq 'HashFailure') {
            $totals.HashFailureCount++
            continue
        }

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

    $seen          = [System.Collections.Generic.Dictionary[string, hashtable]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $orderedHashes = [System.Collections.Generic.List[string]]::new()
    $hashFailureCount = 0

    $files = Get-ScannableFiles -Path $Path -ExcludePaths $ExcludePaths

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
