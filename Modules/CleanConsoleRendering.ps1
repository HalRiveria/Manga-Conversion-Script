<#
.SYNOPSIS
    CleanConsoleRendering (CCR) - the "Clean Console Output" toggle's
    renderer: a live, per-series/chapter progress display, replacing the
    default per-file console spam. Never touches log file content - this
    module owns console rendering only.

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules. No forward references -
    this module is fully standalone, like DependencyDetection.ps1.

    THE MODEL (fixed Library > Series > Chapter > Images layout, decided
    during scoping - see CLAUDE.md's "Clean Console Output" section):
      - Start-SeriesProgress registers a series and its total chapter
        count (known upfront via a per-series eager scan - see CLAUDE.md
        for why this doesn't reintroduce the incremental-scan hang fix).
      - Start-ChapterProgress marks one chapter of that series as now
        running.
      - Complete-ChapterProgress resolves it: -Status Success just
        removes it from the display entirely (it "clears out", per
        explicit instruction). -Status Warning/Error instead moves it
        into a PERSISTENT list that stays visible - even after the whole
        series finishes and freezes into a permanent line - with an
        optional caller-supplied -Detail string. This module never
        interprets -Detail's contents, just displays it - keeps CCR
        domain-agnostic about *why* something went wrong.
      - The progress bar's numerator is SuccessCount only - a chapter
        with issues does NOT count toward it, per explicit instruction.
        A series can therefore finish (nothing left running) while its
        bar still shows short of full (e.g. 6/8) - a deliberate signal,
        not a bug: the persisted issue lines right below explain why.
      - A series is "resolved" (nothing left running, freezes into a
        permanent console line) once SuccessCount + issue-chapter count
        reaches TotalChapters. Multiple series can be active/live at
        once; each gets its own block. Only cleanly-successful chapters
        ever actually disappear from the display.
      - Write-CleanConsoleMessage (2026-08-18): a 5th public function,
        for one-off status lines from OTHER modules (currently
        AbortPipeline.ps1's abort/drain messages) that aren't part of
        the series/chapter model at all - printed as permanent content
        above the live region without corrupting it, the same
        erase-and-reprint mechanism Complete-ChapterProgress's
        NewlyFrozen path already uses, just with raw text instead of a
        formatted series.

    RENDERING: tries real in-place redraw via [Console]::SetCursorPosition
    (erase the previous live region, reprint - the actual "clean" part of
    Clean Console Output), but this requires a real attached interactive
    console. Verified live (2026-08-17) that [Console]::CursorTop/
    SetCursorPosition throws System.IO.IOException ("The handle is
    invalid") when output is redirected/non-interactive - a real,
    confirmed failure mode, not a hypothetical - so cursor support is
    probed ONCE (Test-CleanConsoleCursorAvailable, cached) and everything
    falls back to simple sequential Write-Host (no erase, accepting
    scrollback duplication) if unavailable, rather than throwing an
    exception into the middle of a conversion run. This fallback is
    exactly the "simple periodic snapshot" alternative already discussed
    and accepted as reasonable during scoping - it's not an afterthought,
    it's the deliberately-designed degradation path.

    Content generation (Get-ProgressBarString, Split-TextToWidth,
    Format-SeriesLines) is fully separated from the actual console I/O
    (Update-CleanConsoleDisplay) specifically so it can be tested without
    a real console - see Modules\_Harness\CleanConsoleRendering.Harness.ps1's
    own header for what is and isn't actually verifiable that way.

    COLOR: persisted issue lines and the bar+count line are colored to
    match this project's existing Warn/Error console conventions -
    Yellow for Warning/Aborted, Red for Error (the bar+count line itself
    takes the worst severity present: Red if any Error, else Yellow if
    any Warning/Aborted, else uncolored). Series name and active-chapter
    lines are always uncolored.

    THREAD SAFETY / CALLING CONTEXT - IMPORTANT: every public function in
    this module MUST be called from the main/orchestrating thread only -
    NEVER from within a runspace worker script. $script:ccrActiveSeries is
    per-runspace state, exactly like every other $script:-prefixed module
    state in this project (verified live for Logging.ps1 in its own
    harness, Scenario J) - a worker calling these functions would be
    mutating its OWN isolated copy, invisible to the main thread's actual
    live display. This is a silent failure mode (nothing crashes, nothing
    errors, the display just never updates for that chapter) rather than
    an obvious one, so it's called out here prominently rather than left
    for whoever wires ImageConversionPipeline.ps1/ZipPipeline.ps1 up to
    discover the hard way. The correct call sites are the dispatch loop's
    own pre-dispatch code (Start-ChapterProgress) and its -ResultHandler
    callback (Complete-ChapterProgress) - both already run on the main
    thread in this project's established runspace-pool pattern, same as
    Write-Log's own $script:workerConsoleQueue/Flush-ConsoleQueue split
    exists to solve the identical problem for console output.

.NOTES
    Brand new module - no reference extraction exists for this (the
    feature didn't exist when the original reference-extraction pass was
    done). Built entirely from the scoping discussion recorded in
    CLAUDE.md.
#>

# ==============================================================================
#  Module-owned state
# ==============================================================================
$script:ccrActiveSeries       = [System.Collections.Specialized.OrderedDictionary]::new()
# key = series name; value = @{
#     TotalChapters  = <int>
#     SuccessCount   = <int>                                    # bar numerator - Success only
#     ActiveChapters = [System.Collections.Generic.List[string]]  # currently running
#     IssueChapters  = [System.Collections.Generic.List[hashtable]]  # @{ChapterName;Status;Detail} - persists
# }
$script:ccrLiveRegionLineCount = 0      # physical console rows the live region currently occupies
$script:ccrCursorAvailable     = $null  # $null = not yet probed; cached True/False after first probe

function Test-CleanConsoleCursorAvailable {
    <#
    .SYNOPSIS
        Probes once (cached) whether real console cursor control is
        available. Read-only probe - does not move the cursor. Returns
        $false in any redirected/non-interactive context instead of
        letting a later real redraw attempt throw mid-run.
    #>
    if ($null -ne $script:ccrCursorAvailable) { return $script:ccrCursorAvailable }
    try {
        $null = [Console]::CursorTop
        $null = [Console]::BufferWidth
        $script:ccrCursorAvailable = $true
    } catch {
        $script:ccrCursorAvailable = $false
    }
    return $script:ccrCursorAvailable
}

function Get-ProgressBarString {
    <#
    .SYNOPSIS
        Builds a plain-ASCII "[####------]" bar string (not Unicode
        block characters - safer across older/legacy console fonts that
        may not render them, matching this project's console output
        conventions elsewhere). -Total 0 renders as fully filled (a
        0-chapter series has nothing to be "in progress" about).
    #>
    param(
        [Parameter(Mandatory)]
        [int]$Completed,
        [Parameter(Mandatory)]
        [int]$Total,
        [int]$Width = 20
    )
    if ($Width -le 0) { $Width = 1 }
    if ($Total -le 0) { return ("[" + ("#" * $Width) + "]") }

    $ratio  = [Math]::Min(1.0, [Math]::Max(0.0, $Completed / [double]$Total))
    $filled = [int][Math]::Round($ratio * $Width)
    $empty  = $Width - $filled
    return ("[" + ("#" * $filled) + ("-" * $empty) + "]")
}

function Split-TextToWidth {
    <#
    .SYNOPSIS
        Splits $Text into fixed-$Width chunks (the last one shorter if
        it doesn't divide evenly). Used so long series/chapter names wrap
        under this module's own control instead of relying on the
        terminal's automatic wrap - needed because the redraw algorithm
        must know exactly how many physical rows each logical line will
        occupy to move the cursor correctly.
    .OUTPUTS
        string[] - always at least one element, even for empty input.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,
        [Parameter(Mandatory)]
        [int]$Width
    )
    if ($Width -le 0) { $Width = 1 }
    if ($Text.Length -eq 0) { return @("") }

    $chunks = [System.Collections.Generic.List[string]]::new()
    $pos = 0
    while ($pos -lt $Text.Length) {
        $len = [Math]::Min($Width, $Text.Length - $pos)
        $chunks.Add($Text.Substring($pos, $len))
        $pos += $len
    }
    # Deliberately NO leading comma here, unlike the List-returning
    # functions elsewhere in this project (e.g. Get-ZippableLeafDirs) -
    # this function's only real caller uses `foreach (... in (Split-TextToWidth ...))`,
    # which correctly handles a 0- or 1-element collapse on its own
    # (foreach over $null is zero iterations; foreach over a bare scalar
    # is one iteration) - the comma isn't needed there, and a caller
    # doing `@(Split-TextToWidth ...)` (as this module's own harness
    # does, for easy assertions) would double-wrap if this function ALSO
    # added a comma: `@()` around an already-comma-protected single
    # object produces a 1-element array whose only element is the whole
    # inner list, not its contents. Verified live - this exact double-
    # wrap bug was caught by the harness before being fixed here.
    return $chunks
}

function Get-IssueStatusColor {
    <#
    .SYNOPSIS
        Internal helper - the console color for a given issue -Status.
        Yellow for Warning/Aborted (not necessarily a hard failure), Red
        for Error. $null (no color / console default) for anything else.
    #>
    param([string]$Status)
    switch ($Status) {
        "Error"    { return "Red" }
        "Warning"  { return "Yellow" }
        "Aborted"  { return "Yellow" }
        default    { return $null }
    }
}

function Format-SeriesLines {
    <#
    .SYNOPSIS
        Builds the logical display lines for one series - works
        identically whether that series is still live (may have
        ActiveChapters) or has just frozen (ActiveChapters is always
        empty by the time a series resolves, so this naturally produces
        the correct "frozen" look with no separate function needed):
        series name, progress bar + "X/Y chapters", then persisted issue
        chapters (Warning/Error/Aborted, always shown), then currently-
        active chapters (only present while still live).
    .OUTPUTS
        Array of @{ Text = <string>; Color = <string or $null> } - logical
        lines, NOT yet wrapped/padded to console width. Color is $null
        for uncolored (console-default) lines.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SeriesName,
        [Parameter(Mandatory)]
        [hashtable]$Entry
    )
    $lines = [System.Collections.Generic.List[hashtable]]::new()
    $lines.Add(@{ Text = $SeriesName; Color = $null })

    # Bar+count line takes the worst severity present among this
    # series' issue chapters (Red beats Yellow beats uncolored) - a
    # second, cheaper-to-spot signal on top of the bar itself already
    # stalling short of full.
    $barColor = $null
    foreach ($issue in $Entry.IssueChapters) {
        if ($issue.Status -eq "Error") { $barColor = "Red"; break }
        if ($null -eq $barColor) { $barColor = "Yellow" }
    }
    $bar = Get-ProgressBarString -Completed $Entry.SuccessCount -Total $Entry.TotalChapters
    $lines.Add(@{ Text = ($bar + " " + $Entry.SuccessCount + "/" + $Entry.TotalChapters + " chapters"); Color = $barColor })

    foreach ($issue in $Entry.IssueChapters) {
        $detailSuffix = if ($issue.Detail) { ": " + $issue.Detail } else { "" }
        $lines.Add(@{ Text = ("    " + $issue.ChapterName + " - " + $issue.Status + $detailSuffix); Color = (Get-IssueStatusColor -Status $issue.Status) })
    }
    foreach ($active in $Entry.ActiveChapters) {
        $lines.Add(@{ Text = ("    " + $active + " (in progress)"); Color = $null })
    }

    # No leading comma - see Split-TextToWidth's comment for why: the
    # real caller uses foreach (handles 0/1-element collapse safely on
    # its own), and this module's harness uses @() at call sites, which
    # would double-wrap if this also added its own comma.
    return $lines
}

function Update-CleanConsoleDisplay {
    <#
    .SYNOPSIS
        Internal helper (not meant to be called from outside this
        module, except by this module's own public functions below) -
        redraws the console: erases the previous live region (if cursor
        control is available) and reprints it, promoting any
        just-completed series to permanent scrolled content first.
    .PARAMETER NewlyFrozen
        List of @{ Name; Entry } for series that just resolved as part of
        THIS update - printed as new permanent content before the
        (possibly now-shorter) still-live region is reprinted below it.
    #>
    param(
        [System.Collections.Generic.List[hashtable]]$NewlyFrozen = $null,
        [System.Collections.Generic.List[hashtable]]$ExtraFrozenRows = $null
    )

    $cursorOk = Test-CleanConsoleCursorAvailable
    $effectiveWidth = 79
    if ($cursorOk) {
        try {
            $bw = [Console]::BufferWidth
            if ($bw -gt 1) { $effectiveWidth = $bw - 1 }
        } catch { $script:ccrCursorAvailable = $false; $cursorOk = $false }
    }

    # Rows carry their inherited color forward from the logical line they
    # were split from - @{ Text; Color }, same shape Format-SeriesLines
    # itself uses.
    $frozenRows = [System.Collections.Generic.List[hashtable]]::new()

    # Raw one-off rows (e.g. Write-CleanConsoleMessage's abort/drain text)
    # that never went through Format-SeriesLines - printed first, still
    # wrapped to the same $effectiveWidth as everything else so a long
    # message can't desync the cursor math below.
    if ($ExtraFrozenRows) {
        foreach ($rawRow in $ExtraFrozenRows) {
            foreach ($chunk in (Split-TextToWidth -Text $rawRow.Text -Width $effectiveWidth)) {
                $frozenRows.Add(@{ Text = $chunk; Color = $rawRow.Color })
            }
        }
    }
    if ($NewlyFrozen) {
        foreach ($f in $NewlyFrozen) {
            foreach ($logicalLine in (Format-SeriesLines -SeriesName $f.Name -Entry $f.Entry)) {
                foreach ($chunk in (Split-TextToWidth -Text $logicalLine.Text -Width $effectiveWidth)) {
                    $frozenRows.Add(@{ Text = $chunk; Color = $logicalLine.Color })
                }
            }
        }
    }

    $liveRows = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($seriesName in @($script:ccrActiveSeries.Keys)) {
        foreach ($logicalLine in (Format-SeriesLines -SeriesName $seriesName -Entry $script:ccrActiveSeries[$seriesName])) {
            foreach ($chunk in (Split-TextToWidth -Text $logicalLine.Text -Width $effectiveWidth)) {
                $liveRows.Add(@{ Text = $chunk; Color = $logicalLine.Color })
            }
        }
    }

    $newContentRows = [System.Collections.Generic.List[hashtable]]::new()
    $newContentRows.AddRange($frozenRows)
    $newContentRows.AddRange($liveRows)

    $oldCount = $script:ccrLiveRegionLineCount

    if ($cursorOk) {
        try {
            if ($oldCount -gt 0) {
                [Console]::SetCursorPosition(0, [Console]::CursorTop - $oldCount)
            }
            foreach ($row in $newContentRows) { Write-ColoredConsoleRow -Text $row.Text.PadRight($effectiveWidth) -Color $row.Color }
            if ($newContentRows.Count -lt $oldCount) {
                $blankRowsNeeded = $oldCount - $newContentRows.Count
                for ($i = 0; $i -lt $blankRowsNeeded; $i++) { Write-Host ("".PadRight($effectiveWidth)) }
                [Console]::SetCursorPosition(0, [Console]::CursorTop - $blankRowsNeeded)
            }
        } catch {
            # Cursor support broke mid-redraw (rare - the upfront probe
            # above already covers the common "no console at all" case).
            # Fall back for THIS and all future calls; note the content
            # already Write-Host'd above (if any) may be duplicated by
            # the fallback print below for this one transition only -
            # accepted as a narrow, one-time cosmetic edge case rather
            # than engineered away.
            $script:ccrCursorAvailable = $false
            foreach ($row in $newContentRows) { Write-ColoredConsoleRow -Text $row.Text -Color $row.Color }
        }
    } else {
        foreach ($row in $newContentRows) { Write-ColoredConsoleRow -Text $row.Text -Color $row.Color }
    }

    $script:ccrLiveRegionLineCount = $liveRows.Count
}

function Write-ColoredConsoleRow {
    <#
    .SYNOPSIS
        Internal helper - Write-Host with -ForegroundColor only when a
        color is actually specified, since passing -ForegroundColor $null
        is not the same as omitting the parameter entirely.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,
        [string]$Color
    )
    if ($Color) {
        Write-Host $Text -ForegroundColor $Color
    } else {
        Write-Host $Text
    }
}

function Start-SeriesProgress {
    <#
    .SYNOPSIS
        Registers a new active series. -TotalChapters must already be
        known (from a per-series eager scan - see this module's header)
        - a 0-chapter series is rendered as an immediately-frozen "0/0"
        line and never enters the active registry at all. A NEGATIVE
        -TotalChapters throws rather than being silently treated the
        same as the legitimate 0-chapter case - that would mask a real
        caller bug instead of surfacing it.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SeriesName,
        [Parameter(Mandatory)]
        [int]$TotalChapters
    )
    if ($script:ccrActiveSeries.Contains($SeriesName)) {
        throw ("Start-SeriesProgress: '" + $SeriesName + "' is already active - every chapter must be completed (Complete-ChapterProgress) before starting the same series name again.")
    }
    if ($TotalChapters -lt 0) {
        throw ("Start-SeriesProgress: -TotalChapters cannot be negative (got " + $TotalChapters + ") - a genuinely empty series should pass 0, not a negative count.")
    }

    $entry = @{
        TotalChapters  = $TotalChapters
        SuccessCount   = 0
        ActiveChapters = [System.Collections.Generic.List[string]]::new()
        IssueChapters  = [System.Collections.Generic.List[hashtable]]::new()
    }

    if ($TotalChapters -le 0) {
        $frozen = [System.Collections.Generic.List[hashtable]]::new()
        $frozen.Add(@{ Name = $SeriesName; Entry = $entry })
        Update-CleanConsoleDisplay -NewlyFrozen $frozen
        return
    }

    $script:ccrActiveSeries[$SeriesName] = $entry
    Update-CleanConsoleDisplay
}

function Start-ChapterProgress {
    <#
    .SYNOPSIS
        Marks one chapter of an already-started series as now running.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SeriesName,
        [Parameter(Mandatory)]
        [string]$ChapterName
    )
    if (-not $script:ccrActiveSeries.Contains($SeriesName)) {
        throw ("Start-ChapterProgress: '" + $SeriesName + "' is not an active series - call Start-SeriesProgress first.")
    }
    $script:ccrActiveSeries[$SeriesName].ActiveChapters.Add($ChapterName)
    Update-CleanConsoleDisplay
}

function Complete-ChapterProgress {
    <#
    .SYNOPSIS
        Resolves one running chapter. -Status Success removes it from
        the display entirely. -Status Warning/Error instead moves it
        into a persistent list (with optional -Detail) that stays
        visible even after the series freezes - and does NOT count
        toward the series' progress-bar numerator. ("Aborted" is a third
        persistent status, used only internally by
        Complete-AllActiveSeriesProgress for chapters still running when
        a series gets force-resolved - not a value this function accepts
        directly, since a caller reporting a chapter's outcome always
        knows whether it succeeded, warned, or errored.)
    .OUTPUTS
        @{ SeriesCompleted = <bool> } - whether this call was the one
        that resolved the whole series (nothing left running).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SeriesName,
        [Parameter(Mandatory)]
        [string]$ChapterName,
        [Parameter(Mandatory)]
        [ValidateSet("Success", "Warning", "Error")]
        [string]$Status,
        [string]$Detail = ""
    )
    if (-not $script:ccrActiveSeries.Contains($SeriesName)) {
        throw ("Complete-ChapterProgress: '" + $SeriesName + "' is not an active series - call Start-SeriesProgress first.")
    }
    $entry = $script:ccrActiveSeries[$SeriesName]
    if (-not $entry.ActiveChapters.Remove($ChapterName)) {
        throw ("Complete-ChapterProgress: '" + $ChapterName + "' is not an active chapter of '" + $SeriesName + "' - call Start-ChapterProgress first.")
    }

    if ($Status -eq "Success") {
        $entry.SuccessCount++
    } else {
        $entry.IssueChapters.Add(@{ ChapterName = $ChapterName; Status = $Status; Detail = $Detail })
    }

    $resolvedCount   = $entry.SuccessCount + $entry.IssueChapters.Count
    $seriesCompleted = ($resolvedCount -ge $entry.TotalChapters)

    if ($seriesCompleted) {
        $null = $script:ccrActiveSeries.Remove($SeriesName)
        $frozen = [System.Collections.Generic.List[hashtable]]::new()
        $frozen.Add(@{ Name = $SeriesName; Entry = $entry })
        Update-CleanConsoleDisplay -NewlyFrozen $frozen
    } else {
        Update-CleanConsoleDisplay
    }

    return @{ SeriesCompleted = $seriesCompleted }
}

function Write-CleanConsoleMessage {
    <#
    .SYNOPSIS
        Prints a one-off status line (e.g. AbortPipeline.ps1's abort/
        drain messages) as permanent console content without corrupting
        the live progress region - the region is erased, the message
        printed above it, then the live region is reprinted below,
        exactly like a series freezing into permanent content. Added
        (2026-08-18) specifically so out-of-band messages from other
        modules have somewhere safe to land instead of a raw Write-Host
        landing wherever the cursor happens to be mid-redraw (see
        CLAUDE.md's "Clean Console Output" section, AbortPipeline touch
        point).
    .PARAMETER Text
        The message to print. May contain "`n" - AbortPipeline.ps1's
        existing abort messages lead with a blank line (e.g.
        "`n[ABORT] Ctrl+C detected..."); each "`n"-separated segment
        becomes its own row, independently width-wrapped like any other
        displayed line.
    .PARAMETER Color
        Optional -ForegroundColor, same meaning as Write-Host's own
        parameter. Applies to every row this message produces. Omit for
        an uncolored (console-default) message.
    .OUTPUTS
        None. Safe to call whether or not any series is currently
        active - with nothing active, this just prints the message and
        leaves the (empty) live region as-is.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,
        [string]$Color
    )
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($segment in ($Text -split "`n")) {
        $rows.Add(@{ Text = $segment; Color = $Color })
    }
    Update-CleanConsoleDisplay -ExtraFrozenRows $rows
}

function Complete-AllActiveSeriesProgress {
    <#
    .SYNOPSIS
        Force-resolves every still-active series - for shutdown/abort,
        when the run is ending with series/chapters genuinely still in
        progress (a live region would otherwise be left stuck forever,
        since nothing else would ever call Complete-ChapterProgress for
        those remaining chapters). Any chapter still active is treated
        exactly like a Warning/Error chapter - moved into the persistent
        issue list (so it stays visible, does not count toward the bar's
        numerator) - just with -Status "Aborted" instead. No -Detail is
        set; the status itself already says what happened.
    .OUTPUTS
        None. No-ops cleanly if nothing is currently active.
    #>
    param()

    if ($script:ccrActiveSeries.Count -eq 0) { return }

    $seriesNames = @($script:ccrActiveSeries.Keys)
    $frozen = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($seriesName in $seriesNames) {
        $entry = $script:ccrActiveSeries[$seriesName]
        foreach ($chapterName in @($entry.ActiveChapters)) {
            $entry.IssueChapters.Add(@{ ChapterName = $chapterName; Status = "Aborted"; Detail = "" })
        }
        $entry.ActiveChapters.Clear()
        $frozen.Add(@{ Name = $seriesName; Entry = $entry })
        $null = $script:ccrActiveSeries.Remove($seriesName)
    }

    Update-CleanConsoleDisplay -NewlyFrozen $frozen
}
