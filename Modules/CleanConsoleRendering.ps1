# See Docs/module-descriptions.md for this module's full description.

$script:ccrActiveSeries       = [System.Collections.Specialized.OrderedDictionary]::new()
$script:ccrLiveRegionLineCount = 0
$script:ccrCursorAvailable     = $null
# Tracks the console width the PREVIOUS draw actually wrapped its rows
# against - see Update-CleanConsoleDisplay's own use of this for why.
$script:ccrLastDrawWidth       = $null

function Test-CleanConsoleCursorAvailable {
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
    # Floor, not Round (2026-09-15 fix, real bug) - Round(19.8) is 20, so
    # a 40-chapter series showed a COMPLETELY FULL bar at chapter 39/40,
    # even when that 40th chapter then failed. That directly defeats the
    # documented "a bar that stalls short of full means something went
    # wrong" signal - a full bar has to mean everything actually finished.
    $filled = [int][Math]::Floor($ratio * $Width)
    $empty  = $Width - $filled
    return ("[" + ("#" * $filled) + ("-" * $empty) + "]")
}

function Test-WideCharacter {
    param([Parameter(Mandatory)][char]$Char)
    $code = [int][char]$Char
    return (
        ($code -ge 0x1100 -and $code -le 0x115F) -or
        ($code -ge 0x2E80 -and $code -le 0x303E) -or
        ($code -ge 0x3041 -and $code -le 0x33FF) -or
        ($code -ge 0x3400 -and $code -le 0x4DBF) -or
        ($code -ge 0x4E00 -and $code -le 0x9FFF) -or
        ($code -ge 0xA000 -and $code -le 0xA4CF) -or
        ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
        ($code -ge 0xF900 -and $code -le 0xFAFF) -or
        ($code -ge 0xFF00 -and $code -le 0xFF60) -or
        ($code -ge 0xFFE0 -and $code -le 0xFFE6)
    )
}

function Get-DisplayWidth {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        $width += if (Test-WideCharacter -Char $ch) { 2 } else { 1 }
    }
    return $width
}

function Set-PadToDisplayWidth {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,
        [Parameter(Mandatory)]
        [int]$Width
    )
    $currentWidth = Get-DisplayWidth -Text $Text
    if ($currentWidth -ge $Width) { return $Text }
    return $Text + (" " * ($Width - $currentWidth))
}

function Split-TextToWidth {
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
    $current = [System.Text.StringBuilder]::new()
    $currentWidth = 0
    foreach ($ch in $Text.ToCharArray()) {
        $chWidth = if (Test-WideCharacter -Char $ch) { 2 } else { 1 }
        if (($currentWidth + $chWidth) -gt $Width -and $current.Length -gt 0) {
            $chunks.Add($current.ToString())
            $current = [System.Text.StringBuilder]::new()
            $currentWidth = 0
        }
        $null = $current.Append($ch)
        $currentWidth += $chWidth
    }
    if ($current.Length -gt 0 -or $chunks.Count -eq 0) { $chunks.Add($current.ToString()) }
    return $chunks
}

function Get-IssueStatusColor {
    param([string]$Status)
    switch ($Status) {
        "Error"    { return "Red" }
        "Warning"  { return "Yellow" }
        "Aborted"  { return "Yellow" }
        default    { return $null }
    }
}

function Format-SeriesLines {
    param(
        [Parameter(Mandatory)]
        [string]$SeriesName,
        [Parameter(Mandatory)]
        [hashtable]$Entry
    )
    $lines = [System.Collections.Generic.List[hashtable]]::new()
    $lines.Add(@{ Text = $SeriesName; Color = $null })

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

    return $lines
}

function Get-WrappedSeriesRows {
    param(
        [Parameter(Mandatory)]
        [string]$SeriesName,
        [Parameter(Mandatory)]
        [hashtable]$Entry,
        [Parameter(Mandatory)]
        [int]$Width
    )

    $rows = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($logicalLine in (Format-SeriesLines -SeriesName $SeriesName -Entry $Entry)) {
        foreach ($chunk in (Split-TextToWidth -Text $logicalLine.Text -Width $Width)) {
            $rows.Add(@{ Text = $chunk; Color = $logicalLine.Color })
        }
    }
    return ,$rows
}

function Update-CleanConsoleDisplay {
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

    $frozenRows = [System.Collections.Generic.List[hashtable]]::new()

    if ($ExtraFrozenRows) {
        foreach ($rawRow in $ExtraFrozenRows) {
            foreach ($chunk in (Split-TextToWidth -Text $rawRow.Text -Width $effectiveWidth)) {
                $frozenRows.Add(@{ Text = $chunk; Color = $rawRow.Color })
            }
        }
    }
    if ($NewlyFrozen) {
        foreach ($f in $NewlyFrozen) {
            $frozenRows.AddRange((Get-WrappedSeriesRows -SeriesName $f.Name -Entry $f.Entry -Width $effectiveWidth))
        }
    }

    $liveRows = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($seriesName in @($script:ccrActiveSeries.Keys)) {
        $liveRows.AddRange((Get-WrappedSeriesRows -SeriesName $seriesName -Entry $script:ccrActiveSeries[$seriesName] -Width $effectiveWidth))
    }

    $newContentRows = [System.Collections.Generic.List[hashtable]]::new()
    $newContentRows.AddRange($frozenRows)
    $newContentRows.AddRange($liveRows)

    $oldCount = $script:ccrLiveRegionLineCount
    # 2026-09-15 fix, real bug: $oldCount is a ROW COUNT from the PREVIOUS
    # draw, measured against that draw's own $effectiveWidth. If the
    # console window was resized since (narrower especially - conhost
    # reflows already-padded rows into MORE physical rows at a narrower
    # width), moving the cursor up by $oldCount lands mid-region instead
    # of at the true top, and the redraw below then paints over the wrong
    # rows. Skip the erase-and-overwrite entirely for this one round when
    # the width has changed - draw fresh from the current cursor position
    # instead of trusting a stale row count. Self-correcting: the NEXT
    # draw (now working from the freshly-cached width) erases normally.
    if ($script:ccrLastDrawWidth -ne $null -and $script:ccrLastDrawWidth -ne $effectiveWidth) {
        $oldCount = 0
    }
    $script:ccrLastDrawWidth = $effectiveWidth

    if ($cursorOk) {
        try {
            if ($oldCount -gt 0) {
                [Console]::SetCursorPosition(0, [Console]::CursorTop - $oldCount)
            }
            foreach ($row in $newContentRows) { Write-ColoredConsoleRow -Text (Set-PadToDisplayWidth -Text $row.Text -Width $effectiveWidth) -Color $row.Color }
            if ($newContentRows.Count -lt $oldCount) {
                $blankRowsNeeded = $oldCount - $newContentRows.Count
                for ($i = 0; $i -lt $blankRowsNeeded; $i++) { Write-Host ("".PadRight($effectiveWidth)) }
                [Console]::SetCursorPosition(0, [Console]::CursorTop - $blankRowsNeeded)
            }
        } catch {
            $script:ccrCursorAvailable = $false
            foreach ($row in $newContentRows) { Write-ColoredConsoleRow -Text $row.Text -Color $row.Color }
        }
    } else {
        foreach ($row in $newContentRows) { Write-ColoredConsoleRow -Text $row.Text -Color $row.Color }
    }

    $script:ccrLiveRegionLineCount = $liveRows.Count
}

function Write-ColoredConsoleRow {
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
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,
        [string]$Color
    )
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    # -split "\r?\n" (2026-09-15 fix, real latent bug), not a bare "`n" -
    # splitting on LF only leaves a trailing CR on each segment for CRLF
    # input. A stray CR written mid-row makes the terminal move the
    # cursor back to column 0, so the row's own trailing padding then
    # overwrites the message text with blanks - the row renders empty.
    # Latent today (no current caller passes CRLF), but a real defect in
    # a public function's own contract.
    foreach ($segment in ($Text -split "\r?\n")) {
        $rows.Add(@{ Text = $segment; Color = $Color })
    }
    Update-CleanConsoleDisplay -ExtraFrozenRows $rows
}

function Write-GatedConsoleMessage {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,
        [string]$Color,
        [Parameter(Mandatory)]
        [bool]$CleanConsoleOutputEnabled
    )
    if ($CleanConsoleOutputEnabled) {
        Write-CleanConsoleMessage -Text $Text -Color $Color
    } elseif ($Color) {
        Write-Host $Text -ForegroundColor $Color
    } else {
        Write-Host $Text
    }
}

function Complete-AllActiveSeriesProgress {
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
