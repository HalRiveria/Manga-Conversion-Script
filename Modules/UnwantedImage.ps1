# See Docs/module-descriptions.md for this module's full description.

Add-Type -AssemblyName System.Drawing

function Get-UnwantedImageProfiles {
    return @(
    )
}

function Get-UnwantedImageProfilesPath {
    param([string]$BaseDir)

    if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = $env:LOCALAPPDATA }
    return (Join-Path $BaseDir "ConversionScript\unwanted-image-profiles.json")
}

function Get-TrailingZeroReportPath {
    param([string]$BaseDir)

    if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = $env:LOCALAPPDATA }
    return (Join-Path $BaseDir "ConversionScript\trailing-zero-report.txt")
}

function Import-UnwantedImageProfiles {
    param([string]$ProfilesPath = (Get-UnwantedImageProfilesPath))

    if (-not (Test-Path -LiteralPath $ProfilesPath)) { return @() }

    try {
        $raw = [System.IO.File]::ReadAllText($ProfilesPath) | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log ("Could not read unwanted-image profiles file '" + $ProfilesPath + "' - starting with none. (" + $_ + ")") -Level Warn
        $backupPath = $ProfilesPath + ".corrupt-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".bak"
        $backupOk = $false
        try { Copy-Item -LiteralPath $ProfilesPath -Destination $backupPath -Force -ErrorAction Stop; $backupOk = $true } catch { }
        if ($backupOk) {
            try { Export-UnwantedImageProfiles -Profiles @() -ProfilesPath $ProfilesPath } catch { }
        } else {
            Write-Log ("Could not back up the corrupt profiles file '" + $ProfilesPath + "' - leaving it untouched rather than risk overwriting it with no backup. It will be re-detected as corrupt on the next scan.") -Level Warn
        }
        return @()
    }

    # Per-entry casts run in their OWN try/catch (2026-09-14 fix) - they
    # used to share the parse try/catch above, so one hand-edited bad
    # field (e.g. a fat-fingered dimension) in ANY entry was indistinguishable
    # from the whole file being corrupt JSON: backed up and rewritten as
    # `[]`, silently discarding every OTHER, perfectly good profile too.
    # Now a bad entry is skipped and warned about individually, matching
    # Config.ps1's Import-ScriptSettings per-key fallback - the file itself
    # is untouched, since it's not actually corrupt.
    $profiles = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($p in $raw) {
        try {
            $profiles.Add(@{
                Label         = $p.Label
                Width         = [int]$p.Width
                Height        = [int]$p.Height
                SizeBytes     = [int64]$p.SizeBytes
                SizeTolerance = [int]$p.SizeTolerance
                Hash          = $p.Hash
            })
        } catch {
            Write-Log ("Ignoring an invalid unwanted-image profile entry (Label='" + $p.Label + "') in '" + $ProfilesPath + "': " + $_) -Level Warn
        }
    }
    return ,@($profiles)
}

function Export-UnwantedImageProfiles {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Profiles,
        [string]$ProfilesPath = (Get-UnwantedImageProfilesPath)
    )

    $dir = Split-Path -Path $ProfilesPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $json = ConvertTo-Json -InputObject $Profiles -Depth 5
    Set-Content -LiteralPath $ProfilesPath -Value $json -Encoding UTF8
}

function Get-AllUnwantedImageProfiles {
    param([string]$ProfilesPath = (Get-UnwantedImageProfilesPath))

    $builtIn   = @(Get-UnwantedImageProfiles)
    $persisted = Import-UnwantedImageProfiles -ProfilesPath $ProfilesPath
    return ,($builtIn + $persisted)
}

function New-UnwantedImageProfileFromFile {
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
        Hash          = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
    }
}

function Add-UnwantedImageProfile {
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

    $existingLabel = $addResult.ExistingProfile.Label
    Write-Host ("Not added - already tracked as '" + $existingLabel + "'.") -ForegroundColor Yellow
    return @{ Added = $false; Reason = $addResult.Reason; Profile = $profile; ExistingLabel = $existingLabel }
}

function Get-ImageDimensions {
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
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Profiles
    )

    $fallbackResult = $null

    $dimsAttempted = $false
    $cachedWidth    = $null
    $cachedHeight   = $null
    $hashAttempted  = $false
    $cachedHash     = $null

    foreach ($profile in $Profiles) {
        $sizeDiff = [Math]::Abs($File.Length - $profile.SizeBytes)
        if ($sizeDiff -gt $profile.SizeTolerance) { continue }

        if (-not $dimsAttempted) {
            $dimsAttempted = $true
            $w = $null
            $h = $null
            if (Get-ImageDimensions -Path $File.FullName -OutWidth ([ref]$w) -OutHeight ([ref]$h)) {
                $cachedWidth  = $w
                $cachedHeight = $h
            }
        }
        if ($null -eq $cachedWidth) { continue }
        if ($cachedWidth -ne $profile.Width -or $cachedHeight -ne $profile.Height) { continue }

        if (-not $hashAttempted) {
            $hashAttempted = $true
            try {
                $cachedHash = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            } catch {
                Write-Log ("Could not hash '" + $File.FullName + "' during unwanted-image scan: " + $_) -Level Warn -ForceConsole
                return @{ Status = 'HashFailure'; Profile = $profile; Width = $cachedWidth; Height = $cachedHeight; Hash = $null }
            }
        }
        if ($null -eq $cachedHash) { continue }
        if ($cachedHash -ne $profile.Hash) {
            if ($null -eq $fallbackResult) { $fallbackResult = @{ Status = 'HashMismatch'; Profile = $profile; Width = $cachedWidth; Height = $cachedHeight; Hash = $cachedHash } }
            continue
        }
        return @{ Status = 'Match'; Profile = $profile; Width = $cachedWidth; Height = $cachedHeight; Hash = $cachedHash }
    }

    if ($null -ne $fallbackResult) { return $fallbackResult }
    return @{ Status = 'NoMatch'; Profile = $null; Width = $null; Height = $null; Hash = $null }
}

function Get-ScannableFiles {
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
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [array]$Profiles = (Get-AllUnwantedImageProfiles),
        [string[]]$ImageExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".tiff", ".tif"),
        [string[]]$ExcludePaths = @(),
        [bool]$DryRun = $false
    )

    $totals = @{
        ScannedCount      = 0
        DeletedCount      = 0
        DeleteFailedCount = 0
        HashMismatchCount = 0
        HashFailureCount  = 0
        AlreadyGoneCount  = 0
    }

    $allScannedFiles = @(Get-ScannableFiles -Path $Path -ExcludePaths $ExcludePaths)
    $files = $allScannedFiles | Where-Object { $ImageExtensions -icontains $_.Extension }

    foreach ($file in $files) {
        $totals.ScannedCount++
        $matchResult = Test-UnwantedImageMatch -File $file -Profiles $Profiles

        if ($matchResult.Status -eq 'HashFailure') {
            $totals.HashFailureCount++
            continue
        }

        if ($matchResult.Status -eq 'HashMismatch') {
            Write-Log ("Hash mismatch (not deleted): [" + $matchResult.Profile.Label + "] '" + $file.FullName + "' | " + $file.Length + " bytes | " + $matchResult.Width + "x" + $matchResult.Height + " | " + $matchResult.Hash) -Level Warn -ForceConsole
            $totals.HashMismatchCount++
            continue
        }

        if ($matchResult.Status -ne 'Match') { continue }

        if ($DryRun) {
            Write-Log ("WOULD DELETE: [" + $matchResult.Profile.Label + "] '" + $file.FullName + "' | " + $file.Length + " bytes | " + $matchResult.Width + "x" + $matchResult.Height) -ForceConsole
            $totals.DeletedCount++
            continue
        }

        try {
            $removed = Remove-Source -ItemPath $file.FullName
            if ($removed) {
                $deleteDesc = if ($script:PermanentDelete) { "permanently" } else { "Recycle Bin" }
                Write-Log ("Deleted (" + $deleteDesc + "): [" + $matchResult.Profile.Label + "] '" + $file.FullName + "'") -ForceConsole
                $totals.DeletedCount++
            } else {
                Write-Log ("Already gone before deletion (not counted as deleted): [" + $matchResult.Profile.Label + "] '" + $file.FullName + "'") -Level Warn -ForceConsole
                $totals.AlreadyGoneCount++
            }
        } catch {
            Write-Log ("FAILED to delete '" + $file.FullName + "': " + $_) -Level Error -ForceConsole
            $totals.DeleteFailedCount++
        }
    }

    Write-Log ("Unwanted-image scan complete: " + $totals.DeletedCount + " deleted, " + $totals.HashMismatchCount + " hash mismatch(es), " + $totals.ScannedCount + " image(s) scanned.") -Level Summary -ForceConsole
    $totals.AllScannedFiles = $allScannedFiles
    return $totals
}

function Test-TrailingZeroName {
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
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string[]]$Suffixes = @("_000", "_00", "_0"),
        [string[]]$ExcludePaths = @(),
        [System.IO.FileInfo[]]$PreScannedFiles = $null
    )

    $seen          = [System.Collections.Generic.Dictionary[string, hashtable]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $orderedHashes = [System.Collections.Generic.List[string]]::new()
    $hashFailureCount = 0

    if ($null -ne $PreScannedFiles) {
        $files = $PreScannedFiles
    } else {
        $files = Get-ScannableFiles -Path $Path -ExcludePaths $ExcludePaths
    }

    foreach ($file in $files) {
        if (-not (Test-TrailingZeroName -File $file -Suffixes $Suffixes)) { continue }

        $width  = $null
        $height = $null
        $null = Get-ImageDimensions -Path $file.FullName -OutWidth ([ref]$width) -OutHeight ([ref]$height)

        try {
            $fileHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
        } catch {
            Write-Log ("Could not hash '" + $file.FullName + "' during trailing-zero audit: " + $_) -Level Warn -ForceConsole
            $hashFailureCount++
            continue
        }
        if ([string]::IsNullOrEmpty($fileHash)) {
            Write-Log ("Get-FileHash returned no hash for '" + $file.FullName + "' during trailing-zero audit.") -Level Warn -ForceConsole
            $hashFailureCount++
            continue
        }

        $thisDir = $file.DirectoryName
        if ($seen.ContainsKey($fileHash)) {
            $entry = $seen[$fileHash]
            if ($entry.LocationSet.Add($thisDir)) { $entry.Locations.Add($thisDir) }
        } else {
            $locationSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $null = $locationSet.Add($thisDir)
            $seen[$fileHash] = @{
                FileName    = $file.Name
                Locations   = [System.Collections.Generic.List[string]]@($thisDir)
                LocationSet = $locationSet
                SizeBytes   = $file.Length
                Width       = $width
                Height      = $height
                Hash        = $fileHash
            }
            $orderedHashes.Add($fileHash)
        }
    }

    $groups = @(foreach ($h in $orderedHashes) { $seen[$h] })
    return @{ Groups = $groups; HashFailureCount = $hashFailureCount }
}

function Get-TrailingZeroReportLines {
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
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$ReportPath,
        [string[]]$Suffixes = @("_000", "_00", "_0"),
        [string[]]$ExcludePaths = @(),
        [System.IO.FileInfo[]]$PreScannedFiles = $null
    )

    $scanResult = Get-TrailingZeroGroups -Path $Path -Suffixes $Suffixes -ExcludePaths $ExcludePaths -PreScannedFiles $PreScannedFiles

    if ($scanResult.Groups.Count -eq 0) {
        Write-Log "Trailing-zero audit: no files with trailing-zero names found." -Level Summary -ForceConsole
        return @{ UniqueFileCount = 0; HashFailureCount = $scanResult.HashFailureCount; ReportPath = $null }
    }

    $lines = Get-TrailingZeroReportLines -Groups $scanResult.Groups -SearchRoot $Path
    $reportDir = Split-Path -Path $ReportPath -Parent
    if (-not (Test-Path -LiteralPath $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
    Set-Content -LiteralPath $ReportPath -Value $lines -Encoding UTF8

    Write-Log ("Trailing-zero audit: " + $scanResult.Groups.Count + " unique file(s) found, report written to '" + $ReportPath + "'.") -Level Summary -ForceConsole
    return @{ UniqueFileCount = $scanResult.Groups.Count; HashFailureCount = $scanResult.HashFailureCount; ReportPath = $ReportPath }
}
