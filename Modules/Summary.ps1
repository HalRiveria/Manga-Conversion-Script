# See Docs/module-descriptions.md for this module's full description.

function New-StatsTracker {
    return @{
        LooseImgConverted      = @{ Success = 0; Fail = 0; Skipped = 0 }
        LooseImgDeleted        = @{ Success = 0; Fail = 0 }
        LooseStaleCleaned      = @{ Success = 0; Fail = 0 }
        LooseAnimatedConverted = @{ Success = 0; Fail = 0; Skipped = 0 }
        LooseAnimatedDeleted   = @{ Success = 0; Fail = 0 }
        LooseFolderZipped      = @{ Success = 0; Fail = 0; Skipped = 0 }
        LooseFolderDeleted     = @{ Success = 0; Fail = 0 }
        ZipOnlyZipped          = @{ Success = 0; Fail = 0 }
        ZipOnlyFolderDeleted   = @{ Success = 0; Fail = 0 }
        InspectFailed          = @{ Count = 0 }
        Aborted                = $false
        ForceKilledCount       = 0
    }
}

function Format-ElapsedTime {
    param([Parameter(Mandatory)][timespan]$Elapsed)

    return ("{0:D2}h {1:D2}m {2:D2}s" -f $Elapsed.Hours, $Elapsed.Minutes, $Elapsed.Seconds)
}

function Get-SummaryLines {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Stats,
        [Parameter(Mandatory)]
        [string]$ElapsedString,
        [Parameter(Mandatory)]
        [hashtable]$ModeFlags
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("=== SUMMARY ===")

    if ($ModeFlags.RunImageConversion) {
        $lines.Add("Loose Img Conv.     : Success = " + $Stats.LooseImgConverted.Success + "  |  Failed = " + $Stats.LooseImgConverted.Fail + "  |  Skipped (animated) = " + $Stats.LooseImgConverted.Skipped)
        $lines.Add("Loose Img Deleted   : Success = " + $Stats.LooseImgDeleted.Success   + "  |  Failed = " + $Stats.LooseImgDeleted.Fail)
        $lines.Add("Loose Stale Cleaned : Success = " + $Stats.LooseStaleCleaned.Success + "  |  Failed = " + $Stats.LooseStaleCleaned.Fail)
    }

    if ($ModeFlags.RunAnimatedConversion) {
        $lines.Add("Loose Anim. Conv.   : Success = " + $Stats.LooseAnimatedConverted.Success + "  |  Failed = " + $Stats.LooseAnimatedConverted.Fail + "  |  Skipped (already converted) = " + $Stats.LooseAnimatedConverted.Skipped)
        $lines.Add("Loose Anim. Deleted : Success = " + $Stats.LooseAnimatedDeleted.Success   + "  |  Failed = " + $Stats.LooseAnimatedDeleted.Fail)
    }

    if ($ModeFlags.RunImageConversion -or $ModeFlags.RunAnimatedConversion) {
        $lines.Add("Inspect Failed      : " + $Stats.InspectFailed.Count + " file(s) - could not determine if animated")
    }

    if ($ModeFlags.RunZip) {
        $lines.Add("Loose Folders Zipped: Success = " + $Stats.LooseFolderZipped.Success  + "  |  Failed = " + $Stats.LooseFolderZipped.Fail + "  |  Skipped (unconverted images) = " + $Stats.LooseFolderZipped.Skipped)
        $lines.Add("Loose Fldr Deleted  : Success = " + $Stats.LooseFolderDeleted.Success + "  |  Failed = " + $Stats.LooseFolderDeleted.Fail)
    }

    if ($ModeFlags.RunZipOnly) {
        $lines.Add("Zip-only Zipped     : Success = " + $Stats.ZipOnlyZipped.Success       + "  |  Failed = " + $Stats.ZipOnlyZipped.Fail)
        $lines.Add("Zip-only Fldr Del.  : Success = " + $Stats.ZipOnlyFolderDeleted.Success + "  |  Failed = " + $Stats.ZipOnlyFolderDeleted.Fail)
    }

    $lines.Add("Time taken          : " + $ElapsedString)
    if ($Stats.Aborted) {
        $lines.Add("Run was ABORTED     : " + $Stats.ForceKilledCount + " job(s) force-stopped after the drain timeout")
        $lines.Add("=== Processing ABORTED ===")
    } else {
        $lines.Add("=== Processing complete ===")
    }

    return ,$lines.ToArray()
}

function Write-SummaryReport {
    param(
        [Parameter(Mandatory)]
        [string[]]$Lines,
        [Parameter(Mandatory)]
        [bool]$FullLogging
    )

    Write-Host ""
    # -ForceConsole (2026-09-15 fix, real bug): without it, Write-Log
    # (Logging.ps1) suppresses console output whenever Clean Console
    # Output is enabled, and nothing turns CCR off before this runs
    # (Controller.ps1 sets it once per loop iteration, the summary is
    # written inside that same iteration) - so with CCO on, the user saw
    # a single blank line and no summary at all: no counts, no elapsed
    # time, no "=== Processing ABORTED ===" footer. Every other
    # end-of-operation Summary-level Write-Log call in this codebase
    # (UnwantedImage.ps1's four) already passes -ForceConsole - this one
    # was the omission, not a design choice.
    foreach ($line in $Lines) { Write-Log $line -Level Summary -ForceConsole }

    if (-not $FullLogging) {
        Write-SummaryLog -Lines $Lines
    }
}
