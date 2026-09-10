<#
.SYNOPSIS
    Menu - the mode-selection prompt (what to run) and the options menu
    (view/change settings, saved immediately via Config.ps1).

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules.

    Forward-references:
      - Write-Log (Modules\Logging.ps1) - logs which mode was selected.
      - Export-ScriptSettings (Modules\Config.ps1) - every options-menu
        edit saves immediately, not batched, so nothing is lost on a
        mid-menu Ctrl+C (decided explicitly, not a guess).
      - Get-AllUnwantedImageProfiles, Get-UnwantedImageProfilesPath,
        Invoke-UnwantedImageScan, Show-AddUnwantedImageProfileFlow,
        Invoke-TrailingZeroAudit, Get-TrailingZeroReportPath
        (Modules\UnwantedImage.ps1) - the Cover Deletion submenu (option
        5) is pure wiring around these, no new pipeline logic of its own.
      - Initialize-CleanConsoleOutput (Modules\Logging.ps1),
        Initialize-FileDeletion (Modules\FileDeletion.ps1) - Show-ModeMenu's
        own "5" branch re-syncs both from the current $Settings right
        before Show-CoverDeletionMenu runs (2026-08-31 fix - Cover
        Deletion's real, permanent-deletion-capable scan happens INSIDE
        that same call, before Controller.ps1's own Invoke-MainLoop
        re-sync would ever get a chance to run).

    TESTABILITY: every interactive loop takes a -PromptFunc scriptblock
    (defaults to a thin `Read-Host` wrapper) instead of calling Read-Host
    directly, and Show-OptionsMenuLevel takes an -ActionHandler
    scriptblock for its one real side-effecting item (opening Explorer).
    This is the same "inject the real dependency, let a harness override
    it" shape already used elsewhere in this project (e.g.
    Invoke-ZipParallelProcessing's -ResultHandler) - it's what makes an
    interactive console menu testable at all without simulating real
    stdin. Modules\_Harness\Menu.Harness.ps1 drives entire multi-step
    menu sessions (submenu navigation, value entry, back navigation) by
    queuing canned responses through -PromptFunc.

    DESIGN, settled with the project owner across several rounds before
    this was built (full history in CHANGELOG.md) - see Todo.md's "Menu
    (main prompt + options submenu)" section for the authoritative,
    up-to-date rendered draft this module implements:
      - Mode codes are 1, 2, 3, 4, 5, 8 (NOT contiguous - 6/7/9 are
        deliberately unused/reserved for a future mode without
        renumbering everything already shipped; 9 was "Convert Zipped"/
        rezip, removed entirely 2026-09-09 - see CHANGELOG.md). "0"
        enters the options menu rather than selecting a mode. "5" (Cover
        Deletion) is a submenu, same shape as "0" - it does NOT resolve
        via Resolve-ModeSelection, it opens Show-CoverDeletionMenu and
        then re-shows the main prompt afterward.
      - Old mode 2 ("loose conversion + zip") was deliberately dropped as
        its own mode - Full Pipeline (1) covers "convert everything and
        zip"; if only image conversion + zip is wanted, that's mode 8,
        which is NOT a plain revival of old mode 2 - it gates zipping a
        folder on the new ZipWithUnconvertedAnimated setting, since mode
        8 runs no animated-conversion pass of its own and shouldn't
        silently ship unconverted .avif content inside a ZIP.
      - Full Pipeline (1) is a flag-resolution concern only here - THIS
        MODULE does not implement the per-chapter "convert both types,
        then zip, non-blocking across chapters" execution behavior
        itself (that's ImageConversionPipeline.ps1/
        AnimatedConversionPipeline.ps1/ZipPipeline.ps1's job once wired
        together) - Resolve-ModeSelection just returns the flags a real
        caller would act on.
      - The options-menu schema (Get-OptionsMenuSchema) is DATA, not
        control flow - Show-OptionsMenuLevel is one generic recursive
        renderer/handler for it. Adding a future settings item is a
        schema edit, not a new interactive-loop function.

.NOTES
    Extracted from Conversion Script Main.ps1's mode-selection prompt
    (see Modules\_Reference\Menu.reference.ps1 for the verbatim original)
    plus wholly new functionality (the options menu, which didn't exist
    in the main script at all) built against Todo.md's settled design.
#>

function Get-ModeMenuLines {
    <#
    .SYNOPSIS
        The mode-selection prompt's display lines (pure - no I/O), one
        array entry per printed line.
    #>
    return @(
        "Select process to run:"
        "  1 - Full Pipeline            (image + animated conversion, then zip)"
        "  2 - Image Conversion         (convert loose images only; no zipping)"
        "  3 - Animated Conversion      (convert loose animated/avif files only; no zipping)"
        "  4 - Zip Folders              (no conversion; zips folders that are already ready)"
        "  5 - Cover Deletion           (submenu - unwanted-image profile scan/add)"
        "  8 - Image Conversion + Zip   (convert loose images, then zip)"
        "  0 - Options                  (view/change settings - saved for future runs)"
        ""
        "  Ctrl+C aborts the current run at any point (finishes in-flight work, then stops cleanly)."
    )
}

function Resolve-ModeSelection {
    <#
    .SYNOPSIS
        Maps a validated mode-menu choice ("1"/"2"/"3"/"4"/"8") to the
        flags a caller acts on. Returns $null for anything else (including
        "0", which Show-ModeMenu handles itself as "enter Options", not a
        mode).
    .OUTPUTS
        @{ Mode = <string>; RunImageConversion = <bool>;
           RunAnimatedConversion = <bool>; RunZip = <bool>;
           RunZipOnly = <bool> } or $null.
    #>
    param([string]$Choice)

    switch ($Choice) {
        '1' { return @{ Mode = 'FullPipeline';        RunImageConversion = $true;  RunAnimatedConversion = $true;  RunZip = $true;  RunZipOnly = $false } }
        '2' { return @{ Mode = 'ImageConversion';      RunImageConversion = $true;  RunAnimatedConversion = $false; RunZip = $false; RunZipOnly = $false } }
        '3' { return @{ Mode = 'AnimatedConversion';   RunImageConversion = $false; RunAnimatedConversion = $true;  RunZip = $false; RunZipOnly = $false } }
        '4' { return @{ Mode = 'ZipFolders';           RunImageConversion = $false; RunAnimatedConversion = $false; RunZip = $false; RunZipOnly = $true  } }
        '8' { return @{ Mode = 'ImageConversionZip';   RunImageConversion = $true;  RunAnimatedConversion = $false; RunZip = $true;  RunZipOnly = $false } }
        default { return $null }
    }
}

function Show-ModeMenu {
    <#
    .SYNOPSIS
        The interactive mode-selection loop: prints Get-ModeMenuLines,
        reads a choice, re-prompts on anything invalid, drops into
        Show-OptionsMenuLevel on "0" (then re-shows the mode menu
        afterward), and returns Resolve-ModeSelection's result once a
        real mode is chosen. Does not log - Get-SelectedMode does that,
        so the disabled-prompt default path logs exactly once too.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,
        [Parameter(Mandatory)]
        [string]$SettingsPath,
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message }
    )

    while ($true) {
        foreach ($line in (Get-ModeMenuLines)) { Write-Host $line }
        $choice = (& $PromptFunc "Enter a number").Trim()

        if ($choice -eq '0') {
            # $null = (2026-09-03 fix - see this file's own header/CHANGELOG.md
            # for the FATAL-crash root cause this same species caused via
            # Show-CoverDeletionMenu below): a bare call's return value
            # becomes part of THIS function's own output stream unless
            # suppressed, silently corrupting the eventual `return $resolved`
            # into a multi-element array the first time anything in this
            # branch's call tree returns non-$null.
            $null = Show-OptionsMenuLevel -Items (Get-OptionsMenuSchema) -Settings $Settings -SettingsPath $SettingsPath -PromptFunc $PromptFunc -Title "Options"
            Write-Host ""
            continue
        }

        if ($choice -eq '5') {
            # Re-sync PermanentDelete/CleanConsoleOutputEnabled here too
            # (2026-08-31 fix, caught by a same-day /code-review full-
            # codebase pass) - Controller.ps1's Invoke-MainLoop already
            # re-syncs both AFTER Get-SelectedMode returns, but Cover
            # Deletion does its real, permanent-deletion-capable work
            # (Invoke-CoverDeletionRun -> Invoke-UnwantedImageScan ->
            # Remove-Source, reading $script:PermanentDelete) INSIDE this
            # same call, before that re-sync ever runs. A user who opens
            # Options, turns Permanent Delete off, backs out, and picks
            # Cover Deletion in the SAME menu visit was still deleting
            # permanently on the stale bootstrap value - live-reproduced,
            # a real data-loss bug (files that should have gone to the
            # Recycle Bin didn't). Same file bypasses Recycle Bin only
            # when explicitly asked to; this closes the one path that
            # wasn't honoring a just-made "off" choice. CleanConsoleOutput
            # is re-synced alongside it for the same reason - stale-on
            # would silently suppress every "Deleted..." console line for
            # the scan the user is about to run.
            Initialize-CleanConsoleOutput -Enabled ([bool]$Settings.CleanConsoleOutputEnabled)
            Initialize-FileDeletion -PermanentDelete ([bool]$Settings.PermanentDelete)
            # Start-LogRun/Complete-LogRun bracket (2026-09-04 fix, real bug) -
            # Cover Deletion is the one mode whose real work (scan, hash,
            # delete, all inside Show-CoverDeletionMenu below) never goes
            # through Invoke-MainLoop's own Invoke-Mode dispatch, so it was
            # never bracketed by that loop's Start-LogRun/Complete-LogRun
            # pair either. In split-log mode its Warn/Error lines landed
            # appended with no run-separator header, and the NEXT real run's
            # Start-LogRun then snapshotted those un-headered lines as
            # "prior content" belonging to whatever ran before them -
            # Complete-LogRun's reorder permanently stranded Cover
            # Deletion's own output under an unrelated earlier run instead
            # of giving it its own newest-on-top section. Called directly
            # (not via an injected handler, unlike Invoke-MainLoop's own
            # pair) - Start-LogRun/Complete-LogRun are ordinary Logging.ps1
            # functions in the same script scope as every other module here,
            # and this is the one call site outside Invoke-MainLoop itself
            # that needs them.
            Start-LogRun
            # $null = (2026-09-03 fix): Show-CoverDeletionMenu's own '1'/'2'/'5'
            # branches return a hashtable (Invoke-CoverDeletionRun/
            # Show-AddUnwantedImageProfileFlow/Invoke-TrailingZeroAuditRun all
            # do) from a bare, unsuppressed call of their own - that hashtable
            # was escaping THIS call too, silently added to Show-ModeMenu's own
            # output stream. Live-reproduced as the real FATAL crash: run
            # Cover Deletion's trailing-zero audit, back out, pick a real mode
            # next - Get-SelectedMode's `$resolved` came back as a 2-element
            # array (the leaked hashtable, then the real resolved mode),
            # crashing the first `$resolved.Mode`/property access downstream.
            $null = Show-CoverDeletionMenu -PromptFunc $PromptFunc -Settings $Settings -SettingsPath $SettingsPath
            Complete-LogRun
            Write-Host ""
            continue
        }

        $resolved = Resolve-ModeSelection -Choice $choice
        if ($null -eq $resolved) {
            Write-Host "Invalid selection." -ForegroundColor Yellow
            continue
        }
        return $resolved
    }
}

function Get-SelectedMode {
    <#
    .SYNOPSIS
        Top-level entry point. When $Settings.EnableModePrompt is
        $false, skips the interactive prompt entirely and returns the
        same default the old main script used (old mode 1 - loose image
        conversion only, no zip, no animated - which is today's
        "ImageConversion"/"2"). Otherwise runs Show-ModeMenu. Logs the
        resolved mode exactly once either way.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,
        [Parameter(Mandatory)]
        [string]$SettingsPath,
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message }
    )

    if (-not $Settings.EnableModePrompt) {
        $resolved = Resolve-ModeSelection -Choice '2'
        Write-Log ("Mode (prompt disabled): " + $resolved.Mode)
        return $resolved
    }

    $resolved = Show-ModeMenu -Settings $Settings -SettingsPath $SettingsPath -PromptFunc $PromptFunc
    Write-Log ("Mode selected: " + $resolved.Mode)
    return $resolved
}

function Get-OptionsMenuSchema {
    <#
    .SYNOPSIS
        The options-menu tree as data, not control flow - one generic
        renderer (Show-OptionsMenuLevel) walks this regardless of depth.
        Each node's Type is 'Submenu', 'Bool', 'Int', or 'Action'.
        SettingsKey names match Modules\Config.ps1's real schema keys
        exactly - see that module for defaults/validation.
    #>
    return @(
        # 2026-09-09 reorganization (see CHANGELOG.md): a new top-level
        # submenu for Full-Pipeline-specific settings, freeing the old
        # bare top-level "Full Pipeline Max Concurrent Processes" item
        # (originally added 2026-09-03, see that item's own history
        # below) into a real home instead of sitting alone. Everything
        # else shifted down by one to make room.
        @{ Key = '1'; Label = 'Full Pipeline Settings'; Type = 'Submenu'; Items = @(
            @{ Key = '1'; Label = 'Max Concurrent Processes'; Type = 'Int'; SettingsKey = 'FullPipelineMaxConcurrentProcs'; Min = 1; Max = [int]::MaxValue; Description = 'shared cjxl+magick process budget (independent of CJXL Processes/Animated Threads)' }
            # Placeholder (2026-09-09) - RunCoverDeletionBeforeConversion
            # (Config.ps1) is a real, persisted setting, but nothing reads
            # it yet; toggling this currently has no effect on a real run.
            # See Todo.md's "Run Cover Deletion automatically before Full
            # Pipeline conversion" entry for the real feature this is
            # scaffolding toward.
            @{ Key = '2'; Label = 'Run Cover Deletion Before Conversion'; Type = 'Bool'; SettingsKey = 'RunCoverDeletionBeforeConversion'; Description = 'placeholder - not wired into a real run yet' }
        ) }
        @{ Key = '2'; Label = 'Image Conversion Settings'; Type = 'Submenu'; Items = @(
            @{ Key = '1'; Label = 'CJXL Processes'; Type = 'Int';  SettingsKey = 'MaxCjxlProcs'; Min = 1; Max = [int]::MaxValue; Description = 'how many cjxl.exe run at once per batch' }
            @{ Key = '2'; Label = 'Quality';         Type = 'Int';  SettingsKey = 'JpegQuality';   Min = 1; Max = 100;            Description = '1-100, only used when Lossless is off' }
            @{ Key = '3'; Label = 'Lossless Toggle';  Type = 'Bool'; SettingsKey = 'JpegLossless';  Description = 'on = lossless JPEG transcode, ignores Quality' }
        ) }
        @{ Key = '3'; Label = 'Animated Conversion Settings'; Type = 'Submenu'; Items = @(
            @{ Key = '1'; Label = 'Threads';         Type = 'Int';  SettingsKey = 'AnimatedThreads';     Min = 1; Max = [int]::MaxValue; Description = 'parallel AVIF->WebP conversions' }
            @{ Key = '2'; Label = 'Quality';         Type = 'Int';  SettingsKey = 'AnimatedQuality';     Min = 1; Max = 100;            Description = '1-100, only used when Lossless is off' }
            @{ Key = '3'; Label = 'Lossless Toggle';  Type = 'Bool'; SettingsKey = 'AnimatedLossless';    Description = 'on = lossless WebP, ignores Quality' }
            @{ Key = '4'; Label = 'Overwrite Switch'; Type = 'Bool'; SettingsKey = 'AnimatedOverwrite';   Description = 'overwrite an existing .webp of the same name' }
            @{ Key = '5'; Label = 'Delete Original';  Type = 'Bool'; SettingsKey = 'AnimatedDeleteSource'; Description = 'delete the source .avif after a successful conversion' }
        ) }
        @{ Key = '4'; Label = 'Zip Settings'; Type = 'Submenu'; Items = @(
            @{ Key = '1'; Label = 'Zip Pipeline Threads';               Type = 'Int';  SettingsKey = 'ZipParallelThreads';         Min = 1; Max = [int]::MaxValue; Description = 'parallel ZIP workers for Zip Folders' }
            @{ Key = '2'; Label = 'Zip with Unconverted Animated Files'; Type = 'Bool'; SettingsKey = 'ZipWithUnconvertedAnimated'; Description = 'off (default) = Image Conversion + Zip skips a folder with unconverted .avif files; on = zips anyway' }
        ) }
        @{ Key = '5'; Label = 'Logging'; Type = 'Submenu'; Items = @(
            @{ Key = '1'; Label = 'Full Logging';          Type = 'Bool'; SettingsKey = 'FullLogging';               Description = 'log every action, not just errors/summary' }
            # Label renamed from "Toggle Summary File" (2026-09-09,
            # project owner's own catch) - the settings key is
            # DisableSummaryFile, so [On] meant the summary file was
            # OFF; the old label gave no indication which direction "On"
            # pointed. Renamed to match the key's own sense instead of
            # flipping the underlying setting (safer - an existing
            # settings.json's stored value keeps meaning exactly what it
            # already meant, only the menu's own label text changed).
            @{ Key = '2'; Label = 'Disable Summary File';  Type = 'Bool'; SettingsKey = 'DisableSummaryFile';        Description = 'only matters when Full Logging is off' }
            @{ Key = '3'; Label = 'Clean Console Output';  Type = 'Bool'; SettingsKey = 'CleanConsoleOutputEnabled'; Description = 'live per-series progress instead of per-file lines' }
        ) }
        @{ Key = '6'; Label = 'Permanent Delete';           Type = 'Bool';   SettingsKey = 'PermanentDelete'; Description = 'off = Recycle Bin (default), on = bypasses it entirely' }
        @{ Key = '7'; Label = 'Open Settings File Location'; Type = 'Action'; Action = 'OpenSettingsLocation'; Description = 'opens the settings folder in Explorer' }
    )
}

function Format-OptionsMenuLines {
    <#
    .SYNOPSIS
        Renders one menu level (pure - no I/O): $Title, one line per item
        in $Items (current value inline for Bool/Int items), then
        "0 - Back".
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Items,
        [Parameter(Mandatory)]
        [hashtable]$Settings,
        [string]$Title = "Options"
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($Title)
    foreach ($item in $Items) {
        $valueText = ""
        if ($item.Type -eq 'Bool') {
            $onOff = if ($Settings[$item.SettingsKey]) { "On" } else { "Off" }
            $valueText = " [" + $onOff + "]"
        } elseif ($item.Type -eq 'Int') {
            $valueText = " [" + $Settings[$item.SettingsKey] + "]"
        }
        $descText = if ($item.Description) { "  (" + $item.Description + ")" } else { "" }
        $lines.Add("  " + $item.Key + " - " + $item.Label + $valueText + $descText)
    }
    $lines.Add("  0 - Back")
    return ,$lines.ToArray()
}

function Get-OptionsIntRangeText {
    <#
    .SYNOPSIS
        Private-ish helper: "(1-100)" for a bounded Int item, "(min N)"
        for one with no real upper bound ([int]::MaxValue sentinel).
    #>
    param([Parameter(Mandatory)]$Item)

    if ($Item.Max -ge [int]::MaxValue) {
        return "(min " + $Item.Min + ")"
    }
    return "(" + $Item.Min + "-" + $Item.Max + ")"
}

function Open-FolderInExplorer {
    <#
    .SYNOPSIS
        Private helper - opens $Path's parent folder in Explorer,
        creating it first if it doesn't exist yet (so there's something
        to open). Shared by Invoke-OptionsMenuAction's
        OpenSettingsLocation and Invoke-CoverDeletionAction's
        OpenProfileLocation - both were running this identical block by
        hand.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Start-Process -FilePath "explorer.exe" -ArgumentList $dir
}

function Invoke-OptionsMenuAction {
    <#
    .SYNOPSIS
        Default -ActionHandler for Show-OptionsMenuLevel's 'Action'
        items. Currently just 'OpenSettingsLocation' - opens the
        settings file's parent folder in Explorer (creating it first if
        it doesn't exist yet, so there's something to open).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ActionName,
        [hashtable]$Settings,
        [string]$SettingsPath
    )

    switch ($ActionName) {
        'OpenSettingsLocation' { Open-FolderInExplorer -Path $SettingsPath }
    }
}

function Show-OptionsMenuLevel {
    <#
    .SYNOPSIS
        One generic recursive renderer/handler for any level of
        Get-OptionsMenuSchema's tree - a Submenu item recurses into
        itself with the child $Items; a Bool item toggles and saves
        immediately; an Int item prompts for a new value (range-
        validated, blank cancels) and saves immediately; an Action item
        calls -ActionHandler. "0" (or anything unrecognized falling
        through Back) returns to the caller.
    .PARAMETER Settings
        Mutated in place as items are changed - same hashtable the
        caller already has, no copy.
    .PARAMETER ActionHandler
        Defaults to Invoke-OptionsMenuAction. Override in tests to avoid
        a real Explorer launch while still verifying the right action
        name was dispatched.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Items,
        [Parameter(Mandatory)]
        [hashtable]$Settings,
        [Parameter(Mandatory)]
        [string]$SettingsPath,
        [string]$Title = "Options",
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message },
        [scriptblock]$ActionHandler = { param($ActionName, $Settings, $SettingsPath) Invoke-OptionsMenuAction -ActionName $ActionName -Settings $Settings -SettingsPath $SettingsPath }
    )

    while ($true) {
        foreach ($line in (Format-OptionsMenuLines -Items $Items -Settings $Settings -Title $Title)) { Write-Host $line }
        $choice = (& $PromptFunc "Enter a number").Trim()

        if ($choice -eq '0') { return }

        $match = $Items | Where-Object { $_.Key -eq $choice } | Select-Object -First 1
        if (-not $match) {
            Write-Host "Invalid selection." -ForegroundColor Yellow
            continue
        }

        switch ($match.Type) {
            'Submenu' {
                # $null = (2026-09-03 fix, same species as Show-ModeMenu's
                # Show-CoverDeletionMenu leak) - defensive: this recursion
                # never returns non-$null today (every path ends in a bare
                # `return` with no value), but suppressing here means a
                # future -ActionHandler/nested change can't silently corrupt
                # every caller up the chain the way the Cover Deletion one did.
                $null = Show-OptionsMenuLevel -Items $match.Items -Settings $Settings -SettingsPath $SettingsPath -Title $match.Label -PromptFunc $PromptFunc -ActionHandler $ActionHandler
            }
            'Bool' {
                $Settings[$match.SettingsKey] = -not [bool]$Settings[$match.SettingsKey]
                Export-ScriptSettings -Settings $Settings -Path $SettingsPath
            }
            'Int' {
                $rangeText = Get-OptionsIntRangeText -Item $match
                $promptMessage = $match.Label + " " + $rangeText + ", currently " + $Settings[$match.SettingsKey] + ". Enter new value (blank to cancel)"
                $input = (& $PromptFunc $promptMessage).Trim()
                if ([string]::IsNullOrEmpty($input)) { continue }

                $parsed = 0
                if ([int]::TryParse($input, [ref]$parsed) -and $parsed -ge $match.Min -and $parsed -le $match.Max) {
                    $Settings[$match.SettingsKey] = $parsed
                    Export-ScriptSettings -Settings $Settings -Path $SettingsPath
                } else {
                    Write-Host "Invalid value." -ForegroundColor Yellow
                }
            }
            'Action' {
                # $null = (2026-09-03 fix, same reason as the Submenu branch above)
                $null = & $ActionHandler $match.Action $Settings $SettingsPath
            }
        }
    }
}

function Get-CoverDeletionMenuLines {
    <#
    .SYNOPSIS
        The Cover Deletion submenu's display lines (pure - no I/O). Same
        shape as Get-ModeMenuLines - "0 - Back" always last, matching
        every other submenu in this design.
    #>
    return @(
        "Cover Deletion"
        "  1 - Run                      (scan a folder for known unwanted covers)"
        "  2 - Add Image                (point at a real image to add as a new profile)"
        "  4 - Open Profile Location    (opens the unwanted-image-profiles.json folder)"
        "  5 - Trailing-Zero Report     (scan a folder, write and open a report of trailing-zero filenames)"
        "  0 - Back"
    )
}

function Invoke-CoverDeletionAction {
    <#
    .SYNOPSIS
        Default -ActionHandler for Show-CoverDeletionMenu's one real
        side-effecting item, 'OpenProfileLocation' - opens the unwanted-
        image profiles file's parent folder in Explorer (creating it
        first if it doesn't exist yet, same as Invoke-OptionsMenuAction's
        OpenSettingsLocation).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ActionName,
        [string]$ProfilesPath
    )

    switch ($ActionName) {
        'OpenProfileLocation' { Open-FolderInExplorer -Path $ProfilesPath }
    }
}

function Get-PathWithDefault {
    <#
    .SYNOPSIS
        Shared prompt-with-remembered-default logic for
        Invoke-CoverDeletionRun and Invoke-TrailingZeroAuditRun
        (2026-09-09 extraction - a /code-review finding caught this
        copy-pasted identically in both). Prompts via -PromptFunc,
        offering -DefaultPath as a reusable default (shown in the
        message, used when input is blank).
    .OUTPUTS
        The resolved path (trimmed, unquoted), or $null when the user
        entered nothing and no -DefaultPath was available - caller
        decides how to report that as a cancellation.
    #>
    param(
        [Parameter(Mandatory)]
        [scriptblock]$PromptFunc,
        [string]$DefaultPath = ""
    )
    $promptMessage = "Enter the folder to scan (drag & drop the folder in, or paste the path)"
    if (-not [string]::IsNullOrWhiteSpace($DefaultPath)) {
        $promptMessage += " [Enter to reuse: '" + $DefaultPath + "']"
    }
    $path = (& $PromptFunc $promptMessage)
    if ($null -ne $path) { $path = $path.Trim().Trim('"') }
    if ([string]::IsNullOrWhiteSpace($path)) {
        if (-not [string]::IsNullOrWhiteSpace($DefaultPath)) { return $DefaultPath }
        return $null
    }
    return $path
}

function Invoke-CoverDeletionRun {
    <#
    .SYNOPSIS
        The "1 - Run" item's real behavior: prompts for a folder to scan
        (same drag-and-drop-or-paste convention as
        Show-AddUnwantedImageProfileFlow's path prompt), confirms before
        actually deleting anything (2026-09-03 fix, Todo.md finding - this
        used to go straight from path validation into the real,
        permanent-deletion-capable scan with no confirmation and no
        reachable dry-run), then runs Invoke-UnwantedImageScan against it
        using every known profile (built-in + persisted). A blank path,
        one that doesn't exist, or a declined confirmation all cancel
        without scanning - no silent no-op against an empty $Path, and no
        surprise deletion either.
        Confirmation reuses the same -PromptFunc as the path prompt above
        (matches Show-AddUnwantedImageProfileFlow's own pattern of one
        prompt function handling a queue of sequential questions) -
        answers Y (run for real), D (dry run - reports matches, deletes
        nothing), or anything else (cancel).
    .PARAMETER DefaultPath
        Last-used folder (Show-CoverDeletionMenu threads this from
        $Settings.LastCoverDeletionPath), offered as a reusable default -
        blank input reuses it instead of being treated as "no path
        entered." Empty string (the default) means no remembered path
        yet, matching original behavior exactly.
    .OUTPUTS
        Adds `ResolvedPath` to the existing result shape: the real path
        actually used when Ran is $true (freshly typed or reused from
        -DefaultPath), $null otherwise - Show-CoverDeletionMenu persists
        this back to settings.json.
    #>
    param(
        [string]$ProfilesPath = (Get-UnwantedImageProfilesPath),
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message },
        [string]$DefaultPath = ""
    )

    $path = Get-PathWithDefault -PromptFunc $PromptFunc -DefaultPath $DefaultPath
    if ($null -eq $path) {  # lint:ignore - $path here is a genuinely untyped local var (no [string]$path/$Path param in THIS function), Lint Rule 2's file-wide name match just collides with -Path elsewhere in Menu.ps1
        Write-Host "No path entered - cancelled." -ForegroundColor Yellow
        return @{ Ran = $false; Reason = "No path entered."; ResolvedPath = $null }
    }
    # -PathType Container (2026-08-31 fix, caught by a same-day
    # /code-review full-codebase pass): a bare Test-Path matches a FILE
    # too, so dropping a file on this prompt (instead of the folder it
    # asks for) silently became a one-file scan target instead of being
    # rejected with a clear message.
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Write-Host ("Folder not found: '" + $path + "'") -ForegroundColor Red
        return @{ Ran = $false; Reason = "Folder not found."; ResolvedPath = $null }
    }

    $confirmAnswer = (& $PromptFunc ("About to scan '" + $path + "' and delete any matching files (respecting your Recycle Bin/Permanent Delete setting). Enter Y to run for real, D for a dry run (reports matches, deletes nothing), or anything else to cancel"))
    if ($null -ne $confirmAnswer) { $confirmAnswer = $confirmAnswer.Trim() }
    if ($confirmAnswer -notin @('Y', 'y', 'D', 'd')) {
        Write-Host "Cancelled - no scan was run." -ForegroundColor Yellow
        return @{ Ran = $false; Reason = "Cancelled by user."; ResolvedPath = $null }
    }
    $isDryRun = $confirmAnswer -in @('D', 'd')

    $result = Invoke-UnwantedImageScan -Path $path -Profiles (Get-AllUnwantedImageProfiles -ProfilesPath $ProfilesPath) -DryRun $isDryRun
    if ($isDryRun) { Write-Host "Dry run complete - nothing was deleted." -ForegroundColor Cyan }
    return @{ Ran = $true; Reason = $null; Result = $result; DryRun = $isDryRun; ResolvedPath = $path }
}

function Invoke-TrailingZeroAuditRun {
    <#
    .SYNOPSIS
        Cover Deletion submenu item 5's real behavior (2026-08-31
        addition - project owner's own decision: since item 4 opens the
        profile location, item 5 opens the trailing-zero report). Prompts
        for a folder to scan (same convention as Invoke-CoverDeletionRun's
        own prompt), runs Invoke-TrailingZeroAudit against it, then opens
        the resulting report in the default text-file handler - but only
        when something was actually found (Invoke-TrailingZeroAudit
        itself returns a $null ReportPath and writes no file at all in
        that case - "don't create an empty report" is that function's own
        documented behavior, not something to work around here).
    .PARAMETER Path
        Optional (default "" - matches original behavior, always
        prompts). When supplied, skips the prompt entirely and scans
        this path directly - used by Show-CoverDeletionMenu's '1' branch
        to auto-run this report against item 1's own just-scanned folder
        (2026-09-02 approved-but-not-built feature: item 5 running
        automatically right after item 1, instead of a separate manual
        step). Still re-validated with the same -PathType Container
        check as the prompted path, even though a caller like item 1's
        own resolved path should already be valid - cheap, and this is a
        real function boundary.
    #>
    param(
        [string]$ReportPath = (Get-TrailingZeroReportPath),
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message },
        [string]$Path = "",
        # Start-Process -FilePath (2026-08-31 fix, caught by verifying a
        # same-day /code-review pass) - NOT Open-FolderInExplorer, which
        # opens $Path's PARENT FOLDER, not $Path itself. Every piece of
        # this feature's own documentation (this function's docstring,
        # Get-CoverDeletionMenuLines' menu text, Docs/menu-design.md)
        # says item 5 opens the REPORT, contrasting it with item 4's own
        # "open the location" behavior - the original wiring accidentally
        # reused item 4's helper instead. Start-Process with just a file
        # path launches it via the OS's own default handler for that
        # extension (Notepad or whatever .txt is associated with), same
        # as double-clicking the file in Explorer.
        [scriptblock]$OpenHandler = { param($Path) Start-Process -FilePath $Path },
        # Same -DefaultPath convention as Invoke-CoverDeletionRun (see its
        # own .PARAMETER doc) - Show-CoverDeletionMenu threads the same
        # $Settings.LastCoverDeletionPath into both, one remembered
        # folder shared across the whole submenu.
        [string]$DefaultPath = ""
    )

    # A local variable named $path (or $Path) would be THE SAME VARIABLE
    # as the -Path parameter above (PowerShell variable names are case-
    # insensitive) - since -Path is declared [string], reassigning it to
    # $null (Get-PathWithDefault's own "cancelled" signal) would silently
    # coerce to "" instead of staying $null, exactly the class of bug
    # this project's own Lint Rule 2 exists to catch (caught live: a
    # /code-review fix first used $path here and Lint failed on it).
    # $resolvedPath avoids the collision entirely.
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $resolvedPath = $Path.Trim().Trim('"')
    } else {
        $resolvedPath = Get-PathWithDefault -PromptFunc $PromptFunc -DefaultPath $DefaultPath
        if ($null -eq $resolvedPath) {  # lint:ignore - $resolvedPath is this function's own untyped local var; Rule 2's file-wide match collides with Save-LastCoverDeletionPath's unrelated [string]$ResolvedPath parameter in a completely different function scope (verified live: no actual collision, PowerShell scoping keeps them independent)
            Write-Host "No path entered - cancelled." -ForegroundColor Yellow
            return @{ Ran = $false; Reason = "No path entered."; ResolvedPath = $null }
        }
    }
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
        Write-Host ("Folder not found: '" + $resolvedPath + "'") -ForegroundColor Red
        return @{ Ran = $false; Reason = "Folder not found."; ResolvedPath = $null }
    }

    $reportDir = Split-Path -Path $ReportPath -Parent
    if (-not (Test-Path -LiteralPath $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }

    $result = Invoke-TrailingZeroAudit -Path $resolvedPath -ReportPath $ReportPath
    if ($null -eq $result.ReportPath) {
        Write-Host "No trailing-zero filenames found - nothing to report." -ForegroundColor Yellow
        return @{ Ran = $true; Reason = $null; Result = $result; ResolvedPath = $resolvedPath }
    }

    Write-Host ("Report written: '" + $result.ReportPath + "' (" + $result.UniqueFileCount + " unique file(s))") -ForegroundColor Green
    & $OpenHandler $result.ReportPath
    return @{ Ran = $true; Reason = $null; Result = $result; ResolvedPath = $resolvedPath }
}

function Save-LastCoverDeletionPath {
    <#
    .SYNOPSIS
        Shared persist step for Show-CoverDeletionMenu's '1'/'5'
        branches (2026-09-09 extraction - a /code-review finding caught
        this duplicated in both, AND caught the duplicate's own bare,
        unassigned Export-ScriptSettings-wrapper call as a real
        reintroduction of the 2026-09-03 output-stream-leak bug this
        module's own switch statement was fixed for). No-ops when
        -Settings is $null - every existing caller/test that doesn't
        pass it. Calls Export-ScriptSettings directly, same convention
        Show-OptionsMenuLevel already uses elsewhere in this file - no
        injectable wrapper layer, since Export-ScriptSettings is already
        simple and already independently tested.
    #>
    param(
        [hashtable]$Settings,
        [string]$SettingsPath,
        [Parameter(Mandatory)]
        [string]$ResolvedPath
    )
    if ($null -eq $Settings) { return }  # lint:ignore - $Settings is [hashtable] here; Rule 2's regex matched an unrelated `[string]$Settings.LastCoverDeletionPath` TYPE CAST elsewhere in this file, not a real [string] parameter declaration
    $Settings.LastCoverDeletionPath = $ResolvedPath
    $null = Export-ScriptSettings -Settings $Settings -Path $SettingsPath
}

function Show-CoverDeletionMenu {
    <#
    .SYNOPSIS
        The Cover Deletion submenu loop - "1 - Run" and "2 - Add Image"
        both return to THIS submenu when they finish (not the main
        prompt), matching Options' own "stay until you back out" shape;
        "4 - Open Profile Location" and "0 - Back" are one-shot. "5 -
        Trailing-Zero Report" (2026-08-31 addition, project owner's own
        decision) also returns to this submenu when it finishes, same
        shape as "1"/"2" - it's a real, potentially lengthy scan, not a
        one-shot action like "4". Design settled with the project owner
        (see Todo.md's Menu section) - this function is pure wiring
        around already-built UnwantedImage.ps1 functions, no new
        pipeline logic.
    .PARAMETER RunHandler
        Defaults to Invoke-CoverDeletionRun. Injectable so a harness can
        verify dispatch without a real folder scan.
    .PARAMETER AddHandler
        Defaults to Show-AddUnwantedImageProfileFlow. Injectable for the
        same reason.
    .PARAMETER ActionHandler
        Defaults to Invoke-CoverDeletionAction. Override in tests to
        avoid a real Explorer launch while still verifying the right
        action name was dispatched - same pattern as
        Show-OptionsMenuLevel's -ActionHandler.
    .PARAMETER TrailingZeroHandler
        Defaults to Invoke-TrailingZeroAuditRun. Injectable for the same
        reason as -RunHandler/-AddHandler.
    .PARAMETER AutoTrailingZeroHandler
        Defaults to a real Invoke-TrailingZeroAuditRun -Path call (the
        -Path bypass, not -PromptFunc - no second prompt). Fired once,
        automatically, right after item 1 resolves a real path -
        approved-but-not-built feature (2026-09-02): item 5's report used
        to be a separate manual step, now runs unprompted against
        whatever item 1 just scanned. Injectable so a harness can verify
        it fired (and with which path) without a real scan.
    .PARAMETER Settings
        Optional (default $null - matches original behavior exactly,
        including every existing caller/test that doesn't pass it). When
        supplied, $Settings.LastCoverDeletionPath is offered as items
        1/5's reusable default folder, and updated + persisted
        immediately after either one resolves a real path - same "saves
        immediately, nothing lost on a mid-menu Ctrl+C" convention
        Show-OptionsMenuLevel already uses (calling Export-ScriptSettings
        directly, not through an injectable wrapper - see
        Save-LastCoverDeletionPath below, matching that existing
        precedent instead of introducing a second one).
    .PARAMETER SettingsPath
        Passed straight to Export-ScriptSettings. Same meaning as
        Get-SelectedMode/Show-OptionsMenuLevel's own -SettingsPath.
    #>
    param(
        [string]$ProfilesPath = (Get-UnwantedImageProfilesPath),
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message },
        [scriptblock]$RunHandler = { param($ProfilesPath, $PromptFunc, $DefaultPath) Invoke-CoverDeletionRun -ProfilesPath $ProfilesPath -PromptFunc $PromptFunc -DefaultPath $DefaultPath },
        [scriptblock]$AddHandler = { param($ProfilesPath, $PromptFunc) Show-AddUnwantedImageProfileFlow -ProfilesPath $ProfilesPath -PromptFunc $PromptFunc },
        [scriptblock]$ActionHandler = { param($ActionName, $ProfilesPath) Invoke-CoverDeletionAction -ActionName $ActionName -ProfilesPath $ProfilesPath },
        [scriptblock]$TrailingZeroHandler = { param($PromptFunc, $DefaultPath) Invoke-TrailingZeroAuditRun -PromptFunc $PromptFunc -DefaultPath $DefaultPath },
        [scriptblock]$AutoTrailingZeroHandler = { param($Path) Invoke-TrailingZeroAuditRun -Path $Path },
        [hashtable]$Settings = $null,
        [string]$SettingsPath
    )

    while ($true) {
        foreach ($line in (Get-CoverDeletionMenuLines)) { Write-Host $line }
        $choice = (& $PromptFunc "Enter a number").Trim()

        $defaultPath = ""
        if ($null -ne $Settings -and $Settings.ContainsKey('LastCoverDeletionPath')) {
            $defaultPath = [string]$Settings.LastCoverDeletionPath
        }

        # Captured into a real variable (not bare/unsuppressed) so
        # -RunHandler/-TrailingZeroHandler's ResolvedPath can be read
        # below - still never left bare, so the 2026-09-03 leak fix (see
        # the comment this replaced) still holds: a NAMED assignment
        # doesn't add anything to this function's own output stream,
        # only an unassigned bare call does.
        switch ($choice) {
            '0' { return }
            '1' {
                $runResult = & $RunHandler $ProfilesPath $PromptFunc $defaultPath
                if ($runResult -and $runResult.ResolvedPath) {
                    Save-LastCoverDeletionPath -Settings $Settings -SettingsPath $SettingsPath -ResolvedPath $runResult.ResolvedPath
                    $null = & $AutoTrailingZeroHandler $runResult.ResolvedPath
                }
                Write-Host ""
            }
            '2' { $null = & $AddHandler $ProfilesPath $PromptFunc; Write-Host "" }
            '4' { $null = & $ActionHandler 'OpenProfileLocation' $ProfilesPath }
            '5' {
                $tzResult = & $TrailingZeroHandler $PromptFunc $defaultPath
                if ($tzResult -and $tzResult.ResolvedPath) {
                    Save-LastCoverDeletionPath -Settings $Settings -SettingsPath $SettingsPath -ResolvedPath $tzResult.ResolvedPath
                }
                Write-Host ""
            }
            default { Write-Host "Invalid selection." -ForegroundColor Yellow }
        }
    }
}

function Show-PostRunPrompt {
    <#
    .SYNOPSIS
        After a run finishes: "Press any key to return to the main menu,
        or press Esc to exit." Applies broadly to any mode's run, not
        just one - called once per loop iteration by Controller.ps1's
        Invoke-MainLoop, which wraps this around Get-SelectedMode/
        Invoke-Mode so the menu doesn't just dump back to a bare prompt
        or close the window outright once a run completes.
    .PARAMETER KeyReader
        Defaults to a real single-keypress read via $Host.UI.RawUI.
        Injectable so a harness can feed a fake key object (needs only a
        .VirtualKeyCode property) without blocking on real console input.
    .OUTPUTS
        'Exit' if the key pressed was Escape (VirtualKeyCode 27),
        'ReturnToMenu' for any other key.
    #>
    param(
        [scriptblock]$KeyReader = { $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
    )

    Write-Host ""
    Write-Host "Press any key to return to the main menu, or press Esc to exit." -ForegroundColor Cyan
    $key = & $KeyReader
    if ($key.VirtualKeyCode -eq 27) { return 'Exit' }
    return 'ReturnToMenu'
}
