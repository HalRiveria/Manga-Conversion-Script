<#
.SYNOPSIS
    Summary - the clean-run (non-aborted) summary report: the $stats
    counter shape every pipeline module writes into, elapsed-time
    formatting, and building/writing the final report.

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules.

    Forward-references (Modules\Logging.ps1):
      - Write-Log (used at -Level Summary for each report line)
      - Write-SummaryLog (writes the report to the separate Summary log
        file, when not in full-logging mode)

    NOT extracted here, on purpose (see Modules\_Reference\Summary.reference.ps1
    for the full reasoning): the two ABORT-path summaries (old mode 4's
    and old modes 1/2's) - those carry abort-specific content (trigger
    label, "last completed jobs", forced-stop counts) that's AbortPipeline.ps1's
    territory more than this module's. Format-ElapsedTime below is written
    so those can eventually call it too (all three call sites used the
    exact same one-liner in the reference) - not wired up yet.

    REGATED onto Menu.ps1's mode-flags shape, not the reference's four
    independent $runZipPhase/$runLooseConv/$runLooseZip/$runZipOnly
    booleans - Get-SummaryLines takes one -ModeFlags hashtable matching
    Resolve-ModeSelection's real output (RunImageConversion/
    RunAnimatedConversion/RunZip/RunZipOnly), so a caller can pass
    Get-SelectedMode's actual return value straight in.
    A new Loose Animated Converted/Deleted row-group was added (gated on
    RunAnimatedConversion) since AnimatedConversionPipeline.ps1 has no
    reference-extraction equivalent to draw from - same "designed ahead
    of the module" situation as Config.ps1's Animated* keys. Field names
    confirmed against the real module: Controller.ps1 maps
    Convert-AnimatedBatch's actual ConvertedSuccess/ConvertedFail/
    ConvertedSkipped/DeletedSuccess/DeletedFail output onto these fields
    directly, tested in Controller.Harness.ps1.

    InspectFailed gets its own field, kept out of every engine's Fail
    count. A file we couldn't determine is animated or not (a real
    Test-AvifAnimated failure) is a different kind of outcome than a
    conversion that actually failed - same distinction this module
    already draws for StaticSkippedCount getting no row at all (a static
    AVIF being left alone is expected, while InspectFailed is a genuine
    "couldn't tell" problem worth reporting). Both the image and animated
    engines can hit this failure mode independently, so it's shown as one
    shared line whenever either RunImageConversion or
    RunAnimatedConversion is active, rather than two near-duplicate rows.

.NOTES
    Extracted from Conversion Script Main.ps1 - see
    Modules\_Reference\Summary.reference.ps1 for the verbatim source this
    was built from, with original line numbers, and the reasoning behind
    what's deliberately NOT included.
#>

function New-StatsTracker {
    <#
    .SYNOPSIS
        The $stats counter shape every pipeline module writes into and
        this module reads back out, as a fresh hashtable (never a shared
        reference - nested Success/Fail/Skipped hashtables are fresh
        each call too, since hashtable literals always construct new
        objects).
    #>
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
    <#
    .SYNOPSIS
        "{0:D2}h {1:D2}m {2:D2}s" formatting for a TimeSpan - collapses
        what was three independent copies of the same one-liner in the
        reference extraction into one place.
    #>
    param([Parameter(Mandatory)][timespan]$Elapsed)

    return ("{0:D2}h {1:D2}m {2:D2}s" -f $Elapsed.Hours, $Elapsed.Minutes, $Elapsed.Seconds)
}

function Get-SummaryLines {
    <#
    .SYNOPSIS
        Builds the SUMMARY report as an array of lines (pure - no I/O).
        Only shows the row-groups relevant to what this run's mode
        actually did, per -ModeFlags - showing every group every time
        just meant unused ones were always a wall of zeros.
    .PARAMETER ModeFlags
        A hashtable shaped like Resolve-ModeSelection's output (Menu.ps1)
        - RunImageConversion/RunAnimatedConversion/RunZip/RunZipOnly.
        Pass Get-SelectedMode's real return value.
    .PARAMETER ElapsedString
        Pre-formatted (e.g. via Format-ElapsedTime) - this function
        doesn't touch the Stopwatch itself, matching this module not
        owning the timer's lifecycle (see module header).
    #>
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
    # Shown whenever Aborted is true, since a run that didn't finish
    # normally shouldn't end with the same "Processing complete" framing
    # as a clean run. The force-killed count is folded into this same
    # line rather than a separate row, since it's only ever meaningful in
    # the aborted case.
    if ($Stats.Aborted) {
        $lines.Add("Run was ABORTED     : " + $Stats.ForceKilledCount + " job(s) force-stopped after the drain timeout")
        $lines.Add("=== Processing ABORTED ===")
    } else {
        $lines.Add("=== Processing complete ===")
    }

    return ,$lines.ToArray()
}

function Write-SummaryReport {
    <#
    .SYNOPSIS
        Writes $Lines out: a blank console line, then each line through
        Write-Log -Level Summary (so it always reaches the console and,
        in full-logging mode, the combined log file), then - only when
        NOT in full-logging mode, where Write-Log already wrote every
        Summary line to that one combined file - Write-SummaryLog to
        prepend the same block to the separate Summary log file.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Lines,
        [Parameter(Mandatory)]
        [bool]$FullLogging
    )

    Write-Host ""
    foreach ($line in $Lines) { Write-Log $line -Level Summary }

    if (-not $FullLogging) {
        Write-SummaryLog -Lines $Lines
    }
}
