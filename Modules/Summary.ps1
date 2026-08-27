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

    ALSO NOT included here, moved out on purpose while building (not in
    the reference extraction): the "resume state file retained" log line.
    The reference file included it directly in the SUMMARY block, but
    it's actually ResumeState.ps1's domain (it's reporting on resume-state
    file retention, not on run statistics) - per this project's standing
    "domain logic lives in its domain's module" rule. Left for
    ResumeState.ps1 to own once that module is built, not duplicated here.

    REGATED onto Menu.ps1's mode-flags shape, not the reference's four
    independent $runZipPhase/$runLooseConv/$runLooseZip/$runZipOnly
    booleans - Get-SummaryLines takes one -ModeFlags hashtable matching
    Resolve-ModeSelection's real output (RunImageConversion/
    RunAnimatedConversion/RunZip/RunZipOnly/RunConvertZipped), so a
    caller can pass Get-SelectedMode's actual return value straight in.
    A new Loose Animated Converted/Deleted row-group was added (gated on
    RunAnimatedConversion) since AnimatedConversionPipeline.ps1 has no
    reference-extraction equivalent to draw from - same "designed ahead
    of the module" situation as Config.ps1's Animated* keys; re-check
    field names/shape once that module is actually built (see CLAUDE.md's
    Known gaps, same note extended to cover this module too).

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
        ZipExtracted           = @{ Success = 0; Fail = 0 }
        ImgConverted           = @{ Success = 0; Fail = 0; Skipped = 0 }
        ImgDeleted             = @{ Success = 0; Fail = 0 }
        ZipCreated             = @{ Success = 0; Fail = 0 }
        FolderDeleted          = @{ Success = 0; Fail = 0 }
        LooseImgConverted      = @{ Success = 0; Fail = 0; Skipped = 0 }
        LooseImgDeleted        = @{ Success = 0; Fail = 0 }
        LooseStaleCleaned      = @{ Success = 0; Fail = 0 }
        LooseAnimatedConverted = @{ Success = 0; Fail = 0; Skipped = 0 }
        LooseAnimatedDeleted   = @{ Success = 0; Fail = 0 }
        LooseFolderZipped      = @{ Success = 0; Fail = 0; Skipped = 0 }
        LooseFolderDeleted     = @{ Success = 0; Fail = 0 }
        ZipOnlyZipped          = @{ Success = 0; Fail = 0 }
        ZipOnlyFolderDeleted   = @{ Success = 0; Fail = 0 }
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
        - RunImageConversion/RunAnimatedConversion/RunZip/RunZipOnly/
        RunConvertZipped. Pass Get-SelectedMode's real return value.
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

    if ($ModeFlags.RunConvertZipped) {
        $lines.Add("ZIPs Extracted      : Success = " + $Stats.ZipExtracted.Success  + "  |  Failed = " + $Stats.ZipExtracted.Fail)
        $lines.Add("Img -> JXL Conv.    : Success = " + $Stats.ImgConverted.Success  + "  |  Failed = " + $Stats.ImgConverted.Fail + "  |  Skipped (animated) = " + $Stats.ImgConverted.Skipped)
        $lines.Add("Img Deleted         : Success = " + $Stats.ImgDeleted.Success    + "  |  Failed = " + $Stats.ImgDeleted.Fail)
        $lines.Add("ZIPs Created        : Success = " + $Stats.ZipCreated.Success    + "  |  Failed = " + $Stats.ZipCreated.Fail)
        $lines.Add("Folders Deleted     : Success = " + $Stats.FolderDeleted.Success + "  |  Failed = " + $Stats.FolderDeleted.Fail)
    }

    if ($ModeFlags.RunImageConversion) {
        $lines.Add("Loose Img Conv.     : Success = " + $Stats.LooseImgConverted.Success + "  |  Failed = " + $Stats.LooseImgConverted.Fail + "  |  Skipped (animated) = " + $Stats.LooseImgConverted.Skipped)
        $lines.Add("Loose Img Deleted   : Success = " + $Stats.LooseImgDeleted.Success   + "  |  Failed = " + $Stats.LooseImgDeleted.Fail)
        $lines.Add("Loose Stale Cleaned : Success = " + $Stats.LooseStaleCleaned.Success + "  |  Failed = " + $Stats.LooseStaleCleaned.Fail)
    }

    if ($ModeFlags.RunAnimatedConversion) {
        $lines.Add("Loose Anim. Conv.   : Success = " + $Stats.LooseAnimatedConverted.Success + "  |  Failed = " + $Stats.LooseAnimatedConverted.Fail + "  |  Skipped (already converted) = " + $Stats.LooseAnimatedConverted.Skipped)
        $lines.Add("Loose Anim. Deleted : Success = " + $Stats.LooseAnimatedDeleted.Success   + "  |  Failed = " + $Stats.LooseAnimatedDeleted.Fail)
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
    $lines.Add("=== Processing complete ===")

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
