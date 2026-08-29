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
        Invoke-UnwantedImageScan, Show-AddUnwantedImageProfileFlow
        (Modules\UnwantedImage.ps1) - the Cover Deletion submenu (option
        5) is pure wiring around these, no new pipeline logic of its own.

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
      - Mode codes are 1, 2, 3, 4, 5, 8, 9 (NOT contiguous - 6/7 are
        deliberately unused/reserved for a future mode without
        renumbering everything already shipped). "0" enters the options
        menu rather than selecting a mode. "5" (Cover Deletion) is a
        submenu, same shape as "0" - it does NOT resolve via
        Resolve-ModeSelection, it opens Show-CoverDeletionMenu and then
        re-shows the main prompt afterward.
      - Old mode 2 ("loose conversion + zip") was deliberately dropped as
        its own mode - Full Pipeline (1) covers "convert everything and
        zip"; if only image conversion + zip is wanted, that's mode 8,
        which is NOT a plain revival of old mode 2 - it gates zipping a
        folder on the new ZipWithUnconvertedAnimated setting, since mode
        8 runs no animated-conversion pass of its own and shouldn't
        silently ship unconverted .avif content inside a ZIP.
      - Mode 9 ("Convert Zipped") is explicitly marked deprecated/
        image-only on the menu text itself, not just in a comment -
        confirmed decision, not an oversight.
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
        "  9 - Convert Zipped           [DEPRECATED - image files only, does not convert animated content]"
        "  0 - Options                  (view/change settings - saved for future runs)"
        ""
        "  Ctrl+C aborts the current run at any point (finishes in-flight work, then stops cleanly)."
    )
}

function Resolve-ModeSelection {
    <#
    .SYNOPSIS
        Maps a validated mode-menu choice ("1"/"2"/"3"/"4"/"8"/"9") to the
        flags a caller acts on. Returns $null for anything else (including
        "0", which Show-ModeMenu handles itself as "enter Options", not a
        mode).
    .OUTPUTS
        @{ Mode = <string>; RunImageConversion = <bool>;
           RunAnimatedConversion = <bool>; RunZip = <bool>;
           RunZipOnly = <bool>; RunConvertZipped = <bool> } or $null.
    #>
    param([string]$Choice)

    switch ($Choice) {
        '1' { return @{ Mode = 'FullPipeline';        RunImageConversion = $true;  RunAnimatedConversion = $true;  RunZip = $true;  RunZipOnly = $false; RunConvertZipped = $false } }
        '2' { return @{ Mode = 'ImageConversion';      RunImageConversion = $true;  RunAnimatedConversion = $false; RunZip = $false; RunZipOnly = $false; RunConvertZipped = $false } }
        '3' { return @{ Mode = 'AnimatedConversion';   RunImageConversion = $false; RunAnimatedConversion = $true;  RunZip = $false; RunZipOnly = $false; RunConvertZipped = $false } }
        '4' { return @{ Mode = 'ZipFolders';           RunImageConversion = $false; RunAnimatedConversion = $false; RunZip = $false; RunZipOnly = $true;  RunConvertZipped = $false } }
        '8' { return @{ Mode = 'ImageConversionZip';   RunImageConversion = $true;  RunAnimatedConversion = $false; RunZip = $true;  RunZipOnly = $false; RunConvertZipped = $false } }
        '9' { return @{ Mode = 'ConvertZipped';        RunImageConversion = $false; RunAnimatedConversion = $false; RunZip = $false; RunZipOnly = $false; RunConvertZipped = $true  } }
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
            Show-OptionsMenuLevel -Items (Get-OptionsMenuSchema) -Settings $Settings -SettingsPath $SettingsPath -PromptFunc $PromptFunc -Title "Options"
            Write-Host ""
            continue
        }

        if ($choice -eq '5') {
            Show-CoverDeletionMenu -PromptFunc $PromptFunc
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
        @{ Key = '1'; Label = 'Image Conversion Settings'; Type = 'Submenu'; Items = @(
            @{ Key = '1'; Label = 'CJXL Processes'; Type = 'Int';  SettingsKey = 'MaxCjxlProcs'; Min = 1; Max = [int]::MaxValue; Description = 'how many cjxl.exe run at once per batch' }
            @{ Key = '2'; Label = 'Quality';         Type = 'Int';  SettingsKey = 'JpegQuality';   Min = 1; Max = 100;            Description = '1-100, only used when Lossless is off' }
            @{ Key = '3'; Label = 'Lossless Toggle';  Type = 'Bool'; SettingsKey = 'JpegLossless';  Description = 'on = lossless JPEG transcode, ignores Quality' }
        ) }
        @{ Key = '2'; Label = 'Animated Conversion Settings'; Type = 'Submenu'; Items = @(
            @{ Key = '1'; Label = 'Threads';         Type = 'Int';  SettingsKey = 'AnimatedThreads';     Min = 1; Max = [int]::MaxValue; Description = 'parallel AVIF->WebP conversions' }
            @{ Key = '2'; Label = 'Quality';         Type = 'Int';  SettingsKey = 'AnimatedQuality';     Min = 1; Max = 100;            Description = '1-100, only used when Lossless is off' }
            @{ Key = '3'; Label = 'Lossless Toggle';  Type = 'Bool'; SettingsKey = 'AnimatedLossless';    Description = 'on = lossless WebP, ignores Quality' }
            @{ Key = '4'; Label = 'Overwrite Switch'; Type = 'Bool'; SettingsKey = 'AnimatedOverwrite';   Description = 'overwrite an existing .webp of the same name' }
            @{ Key = '5'; Label = 'Delete Original';  Type = 'Bool'; SettingsKey = 'AnimatedDeleteSource'; Description = 'delete the source .avif after a successful conversion' }
        ) }
        @{ Key = '3'; Label = 'Zip Settings'; Type = 'Submenu'; Items = @(
            @{ Key = '1'; Label = 'Zip Pipeline Threads';               Type = 'Int';  SettingsKey = 'ZipParallelThreads';         Min = 1; Max = [int]::MaxValue; Description = 'parallel ZIP workers (shared by Zip Folders and Convert Zipped)' }
            @{ Key = '2'; Label = 'Zip with Unconverted Animated Files'; Type = 'Bool'; SettingsKey = 'ZipWithUnconvertedAnimated'; Description = 'off (default) = Image Conversion + Zip skips a folder with unconverted .avif files; on = zips anyway' }
        ) }
        @{ Key = '4'; Label = 'Logging'; Type = 'Submenu'; Items = @(
            @{ Key = '1'; Label = 'Full Logging';         Type = 'Bool'; SettingsKey = 'FullLogging';               Description = 'log every action, not just errors/summary' }
            @{ Key = '2'; Label = 'Toggle Summary File';  Type = 'Bool'; SettingsKey = 'DisableSummaryFile';        Description = 'only matters when Full Logging is off' }
            @{ Key = '3'; Label = 'Clean Console Output'; Type = 'Bool'; SettingsKey = 'CleanConsoleOutputEnabled'; Description = 'live per-series progress instead of per-file lines' }
        ) }
        @{ Key = '5'; Label = 'Permanent Delete';           Type = 'Bool';   SettingsKey = 'PermanentDelete'; Description = 'off = Recycle Bin (default), on = bypasses it entirely' }
        @{ Key = '6'; Label = 'Open Settings File Location'; Type = 'Action'; Action = 'OpenSettingsLocation'; Description = 'opens the settings folder in Explorer' }
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
        'OpenSettingsLocation' {
            $dir = Split-Path -Path $SettingsPath -Parent
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            Start-Process -FilePath "explorer.exe" -ArgumentList $dir
        }
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
                Show-OptionsMenuLevel -Items $match.Items -Settings $Settings -SettingsPath $SettingsPath -Title $match.Label -PromptFunc $PromptFunc -ActionHandler $ActionHandler
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
                & $ActionHandler $match.Action $Settings $SettingsPath
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
        'OpenProfileLocation' {
            $dir = Split-Path -Path $ProfilesPath -Parent
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            Start-Process -FilePath "explorer.exe" -ArgumentList $dir
        }
    }
}

function Invoke-CoverDeletionRun {
    <#
    .SYNOPSIS
        The "1 - Run" item's real behavior: prompts for a folder to scan
        (same drag-and-drop-or-paste convention as
        Show-AddUnwantedImageProfileFlow's path prompt), then runs
        Invoke-UnwantedImageScan against it using every known profile
        (built-in + persisted). A blank path or one that doesn't exist
        cancels without scanning - no silent no-op against an empty
        $Path.
    #>
    param(
        [string]$ProfilesPath = (Get-UnwantedImageProfilesPath),
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message }
    )

    $path = (& $PromptFunc "Enter the folder to scan (drag & drop the folder in, or paste the path)")
    if ($null -ne $path) { $path = $path.Trim().Trim('"') }
    if ([string]::IsNullOrWhiteSpace($path)) {
        Write-Host "No path entered - cancelled." -ForegroundColor Yellow
        return @{ Ran = $false; Reason = "No path entered." }
    }
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host ("Path not found: '" + $path + "'") -ForegroundColor Red
        return @{ Ran = $false; Reason = "Path not found." }
    }

    $result = Invoke-UnwantedImageScan -Path $path -Profiles (Get-AllUnwantedImageProfiles -ProfilesPath $ProfilesPath)
    return @{ Ran = $true; Reason = $null; Result = $result }
}

function Show-CoverDeletionMenu {
    <#
    .SYNOPSIS
        The Cover Deletion submenu loop - "1 - Run" and "2 - Add Image"
        both return to THIS submenu when they finish (not the main
        prompt), matching Options' own "stay until you back out" shape;
        "4 - Open Profile Location" and "0 - Back" are one-shot. Design
        settled with the project owner (see Todo.md's Menu section) -
        this function is pure wiring around already-built
        UnwantedImage.ps1 functions, no new pipeline logic.
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
    #>
    param(
        [string]$ProfilesPath = (Get-UnwantedImageProfilesPath),
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message },
        [scriptblock]$RunHandler = { param($ProfilesPath, $PromptFunc) Invoke-CoverDeletionRun -ProfilesPath $ProfilesPath -PromptFunc $PromptFunc },
        [scriptblock]$AddHandler = { param($ProfilesPath, $PromptFunc) Show-AddUnwantedImageProfileFlow -ProfilesPath $ProfilesPath -PromptFunc $PromptFunc },
        [scriptblock]$ActionHandler = { param($ActionName, $ProfilesPath) Invoke-CoverDeletionAction -ActionName $ActionName -ProfilesPath $ProfilesPath }
    )

    while ($true) {
        foreach ($line in (Get-CoverDeletionMenuLines)) { Write-Host $line }
        $choice = (& $PromptFunc "Enter a number").Trim()

        switch ($choice) {
            '0' { return }
            '1' { & $RunHandler $ProfilesPath $PromptFunc; Write-Host "" }
            '2' { & $AddHandler $ProfilesPath $PromptFunc; Write-Host "" }
            '4' { & $ActionHandler 'OpenProfileLocation' $ProfilesPath }
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
