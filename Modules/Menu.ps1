# See Docs/module-descriptions.md for this module's full description.

function Get-ModeMenuLines {
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

function Clear-MenuScreen {
    if ([Console]::IsOutputRedirected) { return }
    # Swallowed deliberately - a host with no real console buffer (ISE,
    # remoting) throws here; the menu still renders, just below the old one.
    try { [Console]::Clear() } catch { }
}

function Show-ModeMenu {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,
        [Parameter(Mandatory)]
        [string]$SettingsPath,
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message },
        [scriptblock]$ReinitLogPathsHandler = $null,
        [scriptblock]$ClearScreenFunc = { Clear-MenuScreen },
        [string]$TargetPath = ""
    )

    $lastFullLogging        = [bool]$Settings.FullLogging
    $lastDisableSummaryFile = [bool]$Settings.DisableSummaryFile

    # DOCUMENTED DUPLICATE: the same clear/notice render loop is in
    # Show-OptionsMenuLevel and Show-CoverDeletionMenu - keep all three in sync.
    $clearNext = $false
    $notice    = $null
    while ($true) {
        if ($clearNext) { & $ClearScreenFunc }
        $clearNext = $true
        foreach ($line in (Get-ModeMenuLines)) { Write-Host $line }
        if ($null -ne $notice) { Write-Host $notice -ForegroundColor Yellow; $notice = $null }
        $choice = (& $PromptFunc "Enter a number").Trim()

        if ($choice -eq '0') {
            $null = Show-OptionsMenuLevel -Items (Get-OptionsMenuSchema) -Settings $Settings -SettingsPath $SettingsPath -PromptFunc $PromptFunc -Title "Options" -ClearScreenFunc $ClearScreenFunc -ClearOnFirstRender $true
            continue
        }

        if ($choice -eq '5') {
            # Re-init log paths BEFORE running Cover Deletion if Full
            # Logging/Disable Summary File was just toggled via option 0
            # in this same menu visit (2026-09-14 fix, Todo.md finding) -
            # option 5 never returns to Invoke-MainLoop's own equivalent
            # check, it loops right back here, so without this Cover
            # Deletion's Write-Log calls landed in the pre-toggle
            # Errors/Warnings files instead of the log the user just asked
            # for. $ReinitLogPathsHandler is $null for any caller that
            # doesn't wire one up (e.g. a harness) - skip silently then,
            # same as never detecting a change.
            $currentFullLogging        = [bool]$Settings.FullLogging
            $currentDisableSummaryFile = [bool]$Settings.DisableSummaryFile
            if ($null -ne $ReinitLogPathsHandler -and
                ($currentFullLogging -ne $lastFullLogging -or $currentDisableSummaryFile -ne $lastDisableSummaryFile)) {
                & $ReinitLogPathsHandler
                $lastFullLogging        = $currentFullLogging
                $lastDisableSummaryFile = $currentDisableSummaryFile
            }
            Initialize-CleanConsoleOutput -Enabled ([bool]$Settings.CleanConsoleOutputEnabled)
            Initialize-FileDeletion -PermanentDelete ([bool]$Settings.PermanentDelete)
            Start-LogRun
            # RunActive bracket + Complete-LogRun-in-finally (2026-09-15
            # fix, real bugs, land together): Cover Deletion's real,
            # permanent-deletion-capable scan never returns out to
            # Invoke-MainLoop's own dispatch (this branch loops right back
            # to the top of THIS while loop instead) - it never reached
            # Invoke-MainLoop's RunActive/QuickEdit bracket, so a Ctrl+C
            # during a real scan hit the OS default action and hard-killed
            # the process mid-scan (possibly between Get-FileHash and
            # Remove-Source), instead of draining gracefully like every
            # other real deletion-capable path in this project. Only safe
            # to add now that Invoke-UnwantedImageScan's own scan loop
            # actually polls the abort signal (2026-09-15 fix,
            # UnwantedImage.ps1) - RunActive=true with nothing polling it
            # would instead freeze here for 65s with Ctrl+C swallowed.
            # Complete-LogRun moved into the same finally so an exception
            # inside the submenu (a locked report file, a path that
            # vanishes mid-scan) can't skip closing the log run - Scenario
            # Q3's own 2026-09-04 fix exists to prevent exactly the log-
            # ordering corruption that would otherwise cause.
            Set-AbortHandlerRunActive -Active $true
            $null = Set-ConsoleQuickEditEnabled -Enabled $false
            $coverScreen = @{ HasOutput = $false }
            try {
                $null = Show-CoverDeletionMenu -PromptFunc $PromptFunc -Settings $Settings -SettingsPath $SettingsPath -ClearScreenFunc $ClearScreenFunc -ClearOnFirstRender $true -ScreenState $coverScreen -TargetPath $TargetPath
            } finally {
                $null = Set-ConsoleQuickEditEnabled -Enabled $true
                Set-AbortHandlerRunActive -Active $false
                Complete-AbortDrain
                Complete-LogRun
            }
            if ($coverScreen.HasOutput) {
                $clearNext = $false
                Write-Host ""
            }
            continue
        }

        $resolved = Resolve-ModeSelection -Choice $choice
        if ($null -eq $resolved) {
            $notice = "Invalid selection."
            continue
        }
        return $resolved
    }
}

function Get-SelectedMode {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,
        [Parameter(Mandatory)]
        [string]$SettingsPath,
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message },
        [scriptblock]$ReinitLogPathsHandler = $null,
        [scriptblock]$ClearScreenFunc = { Clear-MenuScreen },
        [string]$TargetPath = ""
    )

    $resolved = Show-ModeMenu -Settings $Settings -SettingsPath $SettingsPath -PromptFunc $PromptFunc -ReinitLogPathsHandler $ReinitLogPathsHandler -ClearScreenFunc $ClearScreenFunc -TargetPath $TargetPath
    Write-Log ("Mode selected: " + $resolved.Mode)
    return $resolved
}

function Get-OptionsMenuSchema {
    return @(
        @{ Key = '1'; Label = 'Full Pipeline Settings'; Type = 'Submenu'; Items = @(
            @{ Key = '1'; Label = 'Max Concurrent Processes'; Type = 'Int'; SettingsKey = 'FullPipelineMaxConcurrentProcs'; Min = 1; Max = [int]::MaxValue; Description = 'shared cjxl+magick process budget (independent of CJXL Processes/Animated Threads)' }
            @{ Key = '2'; Label = 'Run Cover Deletion Before Conversion'; Type = 'Bool'; SettingsKey = 'RunCoverDeletionBeforeConversion'; Description = 'runs a Cover Deletion pre-scan before Full Pipeline conversion starts' }
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
            @{ Key = '2'; Label = 'Disable Summary File';  Type = 'Bool'; SettingsKey = 'DisableSummaryFile';        Description = 'only matters when Full Logging is off' }
            @{ Key = '3'; Label = 'Clean Console Output';  Type = 'Bool'; SettingsKey = 'CleanConsoleOutputEnabled'; Description = 'live per-series progress instead of per-file lines' }
        ) }
        @{ Key = '6'; Label = 'Permanent Delete';           Type = 'Bool';   SettingsKey = 'PermanentDelete'; Description = 'off = Recycle Bin (default), on = bypasses it entirely' }
        @{ Key = '7'; Label = 'Open Settings File Location'; Type = 'Action'; Action = 'OpenSettingsLocation'; Description = 'opens the settings folder in Explorer' }
    )
}

function Format-OptionsMenuLines {
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
    param([Parameter(Mandatory)]$Item)

    if ($Item.Max -ge [int]::MaxValue) {
        return "(min " + $Item.Min + ")"
    }
    return "(" + $Item.Min + "-" + $Item.Max + ")"
}

function Open-FolderInExplorer {
    param([Parameter(Mandatory)][string]$Path)

    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # Quoted (2026-09-15 fix, real bug) - PS 5.1's Start-Process
    # -ArgumentList doesn't quote a bare path itself, so an unquoted path
    # containing a space (e.g. a username with a space in it) arrives at
    # explorer.exe as two separate arguments instead of one. Verified
    # live with an argv-dumping helper.
    Start-Process -FilePath "explorer.exe" -ArgumentList ("`"" + $dir + "`"")
}

function Invoke-OptionsMenuAction {
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
    param(
        [Parameter(Mandatory)]
        [array]$Items,
        [Parameter(Mandatory)]
        [hashtable]$Settings,
        [Parameter(Mandatory)]
        [string]$SettingsPath,
        [string]$Title = "Options",
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message },
        [scriptblock]$ActionHandler = { param($ActionName, $Settings, $SettingsPath) Invoke-OptionsMenuAction -ActionName $ActionName -Settings $Settings -SettingsPath $SettingsPath },
        [scriptblock]$ClearScreenFunc = { Clear-MenuScreen },
        [bool]$ClearOnFirstRender = $false
    )

    # DOCUMENTED DUPLICATE: the same clear/notice render loop is in
    # Show-ModeMenu and Show-CoverDeletionMenu - keep all three in sync.
    $clearNext = $ClearOnFirstRender
    $notice    = $null
    while ($true) {
        if ($clearNext) { & $ClearScreenFunc }
        $clearNext = $true
        foreach ($line in (Format-OptionsMenuLines -Items $Items -Settings $Settings -Title $Title)) { Write-Host $line }
        if ($null -ne $notice) { Write-Host $notice -ForegroundColor Yellow; $notice = $null }
        $choice = (& $PromptFunc "Enter a number").Trim()

        if ($choice -eq '0') { return }

        $match = $Items | Where-Object { $_.Key -eq $choice } | Select-Object -First 1
        if (-not $match) {
            $notice = "Invalid selection."
            continue
        }

        switch ($match.Type) {
            'Submenu' {
                $null = Show-OptionsMenuLevel -Items $match.Items -Settings $Settings -SettingsPath $SettingsPath -Title $match.Label -PromptFunc $PromptFunc -ActionHandler $ActionHandler -ClearScreenFunc $ClearScreenFunc -ClearOnFirstRender $true
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
                    $notice = "Invalid value."
                }
            }
            'Action' {
                $null = & $ActionHandler $match.Action $Settings $SettingsPath
            }
        }
    }
}

function Get-CoverDeletionMenuLines {
    param(
        [hashtable]$Settings = $null,
        [string]$TargetPath = ""
    )
    $dryRun       = Get-CoverDeletionSetting -Settings $Settings -Key 'CoverDeletionDryRun'
    $askForFolder = Get-CoverDeletionSetting -Settings $Settings -Key 'CoverDeletionAskForFolder'
    $folderText = if ($askForFolder -or [string]::IsNullOrWhiteSpace($TargetPath)) { "asks for a folder each time" } else { "scans the target folder: '" + $TargetPath + "'" }
    return @(
        "Cover Deletion"
        "  1 - Run                      (scan for known unwanted covers" + $(if ($dryRun) { " - dry run, nothing deleted)" } else { " and DELETE matches)" })
        "  2 - Add Image                (point at a real image to add as a new profile)"
        "  4 - Open Profile Location    (opens the unwanted-image-profiles.json folder)"
        "  5 - Trailing-Zero Report     (scan, write and open a report of trailing-zero filenames)"
        ("  6 - Dry Run                  [" + $(if ($dryRun) { "On" } else { "Off" }) + "]  (on = report matches only; off = delete them)")
        ("  7 - Ask For Folder           [" + $(if ($askForFolder) { "On" } else { "Off" }) + "]  (currently " + $folderText + ")")
        "  0 - Back"
    )
}

function Get-CoverDeletionSetting {
    param(
        [hashtable]$Settings,
        [Parameter(Mandatory)]
        [string]$Key
    )
    if ($null -ne $Settings -and $Settings.ContainsKey($Key)) { return [bool]$Settings[$Key] }
    return [bool](Get-DefaultScriptSettings)[$Key]
}

function Invoke-CoverDeletionAction {
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
    param(
        [string]$ProfilesPath = (Get-UnwantedImageProfilesPath),
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message },
        [string]$DefaultPath = "",
        [string]$FolderPath = "",
        [bool]$DryRun = $true
    )

    if (-not [string]::IsNullOrWhiteSpace($FolderPath)) {
        $path = $FolderPath.Trim().Trim('"')
    } else {
        $path = Get-PathWithDefault -PromptFunc $PromptFunc -DefaultPath $DefaultPath
    }
    if ($null -eq $path) {  # lint:ignore - $path here is a genuinely untyped local var (no [string]$path/$Path param in THIS function), Lint Rule 2's file-wide name match just collides with -Path elsewhere in Menu.ps1
        Write-Host "No path entered - cancelled." -ForegroundColor Yellow
        return @{ Ran = $false; Reason = "No path entered."; ResolvedPath = $null; AllScannedFiles = $null }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Write-Host ("Folder not found: '" + $path + "'") -ForegroundColor Red
        return @{ Ran = $false; Reason = "Folder not found."; ResolvedPath = $null; AllScannedFiles = $null }
    }

    $isDryRun = $DryRun

    if (-not $isDryRun) {
        $refusal = Get-RecycleBinRefusalMessage -TargetPath $path -PermanentDelete ([bool](Get-WorkerRunspaceValue -Name PermanentDelete))
        if ($refusal) {
            Write-Host $refusal -ForegroundColor Red
            return @{ Ran = $false; Reason = "No Recycle Bin on this drive and Permanent Delete is off."; ResolvedPath = $null; AllScannedFiles = $null }
        }
    }

    $result = Invoke-UnwantedImageScan -Path $path -Profiles (Get-AllUnwantedImageProfiles -ProfilesPath $ProfilesPath) -DryRun $isDryRun
    if ($isDryRun) { Write-Host "Dry run complete - nothing was deleted." -ForegroundColor Cyan }
    return @{ Ran = $true; Reason = $null; Result = $result; DryRun = $isDryRun; ResolvedPath = $path; AllScannedFiles = $result.AllScannedFiles }
}

function Invoke-TrailingZeroAuditRun {
    param(
        [string]$ReportPath = (Get-TrailingZeroReportPath),
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message },
        [string]$Path = "",
        [scriptblock]$OpenHandler = { param($Path) Start-Process -FilePath $Path },
        [string]$DefaultPath = "",
        [System.IO.FileInfo[]]$PreScannedFiles = $null
    )

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

    $result = Invoke-TrailingZeroAudit -Path $resolvedPath -ReportPath $ReportPath -PreScannedFiles $PreScannedFiles
    if ($null -eq $result.ReportPath) {
        Write-Host "No trailing-zero filenames found - nothing to report." -ForegroundColor Yellow
        return @{ Ran = $true; Reason = $null; Result = $result; ResolvedPath = $resolvedPath }
    }

    Write-Host ("Report written: '" + $result.ReportPath + "' (" + $result.UniqueFileCount + " unique file(s))") -ForegroundColor Green
    # $null = (2026-09-15 fix, real bug, latent) - the shipped default
    # (Start-Process with no -PassThru) emits nothing, so this was safe
    # in practice, but -OpenHandler is advertised as an injection point -
    # a handler returning anything would make this function return a
    # 2-element array instead of the single hashtable below, and
    # Show-CoverDeletionMenu's own caller would then persist a garbage
    # space-joined string as LastCoverDeletionPath.
    $null = & $OpenHandler $result.ReportPath
    return @{ Ran = $true; Reason = $null; Result = $result; ResolvedPath = $resolvedPath }
}

function Save-LastCoverDeletionPath {
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
    param(
        [string]$ProfilesPath = (Get-UnwantedImageProfilesPath),
        [scriptblock]$PromptFunc = { param($Message) Read-Host $Message },
        [scriptblock]$RunHandler = { param($ProfilesPath, $PromptFunc, $DefaultPath, $Path, $DryRun) Invoke-CoverDeletionRun -ProfilesPath $ProfilesPath -PromptFunc $PromptFunc -DefaultPath $DefaultPath -FolderPath $Path -DryRun ([bool]$DryRun) },
        [scriptblock]$AddHandler = { param($ProfilesPath, $PromptFunc) Show-AddUnwantedImageProfileFlow -ProfilesPath $ProfilesPath -PromptFunc $PromptFunc },
        [scriptblock]$ActionHandler = { param($ActionName, $ProfilesPath) Invoke-CoverDeletionAction -ActionName $ActionName -ProfilesPath $ProfilesPath },
        [scriptblock]$TrailingZeroHandler = { param($PromptFunc, $DefaultPath, $Path) Invoke-TrailingZeroAuditRun -PromptFunc $PromptFunc -DefaultPath $DefaultPath -Path $Path },
        [scriptblock]$AutoTrailingZeroHandler = { param($Path, $PreScannedFiles) Invoke-TrailingZeroAuditRun -Path $Path -PreScannedFiles $PreScannedFiles },
        [hashtable]$Settings = $null,
        [string]$SettingsPath,
        [scriptblock]$ClearScreenFunc = { Clear-MenuScreen },
        [bool]$ClearOnFirstRender = $false,
        [hashtable]$ScreenState = $null,
        [string]$TargetPath = ""
    )

    # DOCUMENTED DUPLICATE: the same clear/notice render loop is in
    # Show-ModeMenu and Show-OptionsMenuLevel - keep all three in sync.
    # Options 1/2/5 print real work output, so the render right after them
    # doesn't clear, and -ScreenState.HasOutput tells the caller not to clear either.
    $clearNext       = $ClearOnFirstRender
    $notice          = $null
    $screenHasOutput = $false
    while ($true) {
        if ($clearNext) { & $ClearScreenFunc; $screenHasOutput = $false }
        $clearNext = $true
        foreach ($line in (Get-CoverDeletionMenuLines -Settings $Settings -TargetPath $TargetPath)) { Write-Host $line }
        if ($null -ne $notice) { Write-Host $notice -ForegroundColor Yellow; $notice = $null }
        $choice = (& $PromptFunc "Enter a number").Trim()

        $defaultPath = ""
        if ($null -ne $Settings -and $Settings.ContainsKey('LastCoverDeletionPath')) {
            $defaultPath = [string]$Settings.LastCoverDeletionPath
        }
        # Empty = prompt (prefilled with $defaultPath); otherwise scan the target folder directly.
        $runFolder = ""
        if (-not (Get-CoverDeletionSetting -Settings $Settings -Key 'CoverDeletionAskForFolder')) { $runFolder = $TargetPath }
        $dryRun = Get-CoverDeletionSetting -Settings $Settings -Key 'CoverDeletionDryRun'

        switch ($choice) {
            '0' { if ($null -ne $ScreenState) { $ScreenState.HasOutput = $screenHasOutput }; return }
            '1' {
                $runResult = & $RunHandler $ProfilesPath $PromptFunc $defaultPath $runFolder $dryRun
                if ($runResult -and $runResult.ResolvedPath) {
                    Save-LastCoverDeletionPath -Settings $Settings -SettingsPath $SettingsPath -ResolvedPath $runResult.ResolvedPath
                    $survivingFiles = $null
                    if ($runResult.AllScannedFiles) {
                        $survivingFiles = @($runResult.AllScannedFiles | Where-Object { [System.IO.File]::Exists($_.FullName) })
                    }
                    $null = & $AutoTrailingZeroHandler $runResult.ResolvedPath $survivingFiles
                }
                Write-Host ""
                $clearNext = $false; $screenHasOutput = $true
            }
            '2' { $null = & $AddHandler $ProfilesPath $PromptFunc; Write-Host ""; $clearNext = $false; $screenHasOutput = $true }
            '4' { $null = & $ActionHandler 'OpenProfileLocation' $ProfilesPath }
            '5' {
                $tzResult = & $TrailingZeroHandler $PromptFunc $defaultPath $runFolder
                if ($tzResult -and $tzResult.ResolvedPath) {
                    Save-LastCoverDeletionPath -Settings $Settings -SettingsPath $SettingsPath -ResolvedPath $tzResult.ResolvedPath
                }
                Write-Host ""
                $clearNext = $false; $screenHasOutput = $true
            }
            '6' { Set-CoverDeletionToggle -Settings $Settings -SettingsPath $SettingsPath -Key 'CoverDeletionDryRun' }
            '7' { Set-CoverDeletionToggle -Settings $Settings -SettingsPath $SettingsPath -Key 'CoverDeletionAskForFolder' }
            default { $notice = "Invalid selection." }
        }
    }
}

function Set-CoverDeletionToggle {
    param(
        [hashtable]$Settings,
        [string]$SettingsPath,
        [Parameter(Mandatory)]
        [string]$Key
    )
    if (-not $Settings) { return }
    $Settings[$Key] = -not (Get-CoverDeletionSetting -Settings $Settings -Key $Key)
    if (-not [string]::IsNullOrWhiteSpace($SettingsPath)) { Export-ScriptSettings -Settings $Settings -Path $SettingsPath }
}

function Show-PostRunPrompt {
    param(
        [scriptblock]$KeyReader = { $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
    )

    Write-Host ""
    Write-Host "Press any key to return to the main menu, or press Esc to exit." -ForegroundColor Cyan
    $key = & $KeyReader
    if ($key.VirtualKeyCode -eq 27) { return 'Exit' }
    return 'ReturnToMenu'
}
