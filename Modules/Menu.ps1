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
      - Mode codes are 1, 2, 3, 4, 8, 9 (NOT contiguous - 5/6/7 are
        deliberately unused/reserved for a future mode without
        renumbering everything already shipped). "0" enters the options
        menu rather than selecting a mode.
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
