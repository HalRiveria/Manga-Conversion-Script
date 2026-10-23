<#
.SYNOPSIS
    Config - the settings file the other modules read their tunables from:
    the default schema, loading (with recovery from a corrupt or stale
    file), and saving.

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules.

    Settings file: %LOCALAPPDATA%\ConversionScript\settings.json
    (Get-ScriptSettingsPath). -BaseDir points it elsewhere, which the
    harness uses.

    Schema and defaults: Get-DefaultScriptSettings is the single source of
    truth. Key names match the parameter names of the functions that use
    them (Initialize-FileDeletion -PermanentDelete, Initialize-LogPaths
    -FullLogging/-DisableSummaryFile, Initialize-CleanConsoleOutput
    -Enabled, Invoke-LooseImageConversionPipeline -MaxCjxlProcs/
    -JpegLossless/-JpegQuality, the Animated* parameters of
    Invoke-LooseAnimatedConversionPipeline).

    Loading validates every value's type and range: settings.json is user
    input (it can be hand-edited or damaged). A bad value falls back to
    that key's default with a warning, without discarding the rest of the
    file. Keys that no longer exist are dropped quietly.

    CjxlPath/MagickPath cache the tools' locations once found
    (Find-ExeCached in DependencyDetection.ps1 does the finding; this
    module only stores the strings). ModulesPath remembers a Modules
    folder found somewhere other than next to the script (the main
    script does the finding and prompting).

    Write-Log (Logging.ps1) is used for the non-fatal warnings above.
#>

function Get-DefaultScriptSettings {
    <#
    .SYNOPSIS
        The full settings schema with its current defaults, as a fresh
        hashtable (never a shared reference - callers can mutate it
        freely). This is the source of truth for what settings.json is
        allowed to contain; Import-ScriptSettings merges onto a copy of
        this.
    #>
    return @{
        ModulesPath                      = ""
        CjxlPath                         = ""
        MagickPath                       = ""
        ZipParallelThreads               = 1
        MaxCjxlProcs                     = 8
        # Full Pipeline's total process budget (image + animated engines
        # together). A separate setting, not MaxCjxlProcs + AnimatedThreads:
        # this is the real total Full Pipeline runs at once. MaxCjxlProcs
        # and AnimatedThreads only apply to Image Conversion and Animated
        # Conversion on their own.
        FullPipelineMaxConcurrentProcs   = 8
        FullLogging                      = $false
        DisableSummaryFile               = $false
        CleanConsoleOutputEnabled        = $false
        JpegLossless                     = $false
        JpegQuality                      = 90
        PermanentDelete                  = $false
        AnimatedThreads                  = 8
        AnimatedQuality                  = 90
        AnimatedLossless                 = $false
        AnimatedOverwrite                = $false
        AnimatedDeleteSource             = $true
        LastCoverDeletionPath            = ""
        CoverDeletionAskForFolder        = $false
        CoverDeletionDryRun              = $false
        # Full Pipeline -> "Run Cover Deletion Before Conversion": runs a
        # Cover Deletion scan before converting (Invoke-FullPipeline).
        RunCoverDeletionBeforeConversion = $false
        FullPipelineAnimatedConversion   = $true
    }
}

function Get-ScriptSettingsPath {
    <#
    .SYNOPSIS
        The settings file path: "<BaseDir>\ConversionScript\settings.json".
    .PARAMETER BaseDir
        Defaults to $env:LOCALAPPDATA. Override for testing (this
        module's harness always does) rather than touching the real
        per-user AppData folder.
    #>
    param([string]$BaseDir)

    if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = $env:LOCALAPPDATA }
    return (Join-Path $BaseDir "ConversionScript\settings.json")
}

function ConvertTo-SettingsHashtable {
    <#
    .SYNOPSIS
        Flattens a ConvertFrom-Json PSCustomObject into a hashtable.
        Private helper - PS 5.1's ConvertFrom-Json has no -AsHashtable
        (that's PS6+), so this does it by hand.
    #>
    param([Parameter(Mandatory)]$InputObject)

    $ht = @{}
    foreach ($prop in $InputObject.PSObject.Properties) {
        $ht[$prop.Name] = $prop.Value
    }
    return ,$ht
}

function Test-ScriptSettingValue {
    <#
    .SYNOPSIS
        True if $Value is an acceptable value for settings key $Key,
        given $Default (used for both its .NET type and, for numeric
        keys, its sanity range). Private helper for Import-ScriptSettings.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Key,
        $Value,
        [Parameter(Mandatory)]
        $Default
    )

    if ($null -eq $Value) { return $false }

    if ($Default -is [bool]) {
        return ($Value -is [bool])
    }
    if ($Default -is [int]) {
        # ConvertFrom-Json yields [decimal] for a whole-number JSON value
        # on this PS 5.1/.NET Framework combination
        # ('{"a":75.0}' | ConvertFrom-Json).a.GetType() -> System.Decimal,
        # NOT [double]. Without the [decimal] branch, a hand-edited
        # "JpegQuality": 75.0 in settings.json would be silently rejected
        # and reverted to the default. [double] is kept
        # alongside [decimal] rather than replaced - some other JSON
        # parser or a value built directly in PowerShell (not from this
        # project's own ConvertFrom-Json path) could still hand this
        # function a real [double], and accepting it costs nothing.
        $isIntegral = ($Value -is [int]) -or ($Value -is [long]) -or
                      (($Value -is [double] -or $Value -is [decimal]) -and ($Value -eq [math]::Truncate($Value)))
        if (-not $isIntegral) { return $false }

        # try/catch around the [int] cast: a value outside
        # Int32's range (e.g. a hand-edited "MaxCjxlProcs": 99999999999)
        # is integral by the check above but throws OverflowException on
        # cast, contradicting this function's own "never throws" contract
        # (Import-ScriptSettings' docstring) - unguarded, that exception
        # would escape Import-ScriptSettings entirely (no try/catch there
        # either) and kill the WHOLE settings load, not just this one
        # key falling back to its default. An out-of-Int32-range value is
        # exactly as invalid as any other out-of-range value this
        # function already rejects below.
        try {
            $intValue = [int]$Value
        } catch {
            return $false
        }
        switch ($Key) {
            'JpegQuality'        { return ($intValue -ge 1 -and $intValue -le 100) }
            'AnimatedQuality'    { return ($intValue -ge 1 -and $intValue -le 100) }
            'ZipParallelThreads' { return ($intValue -ge 1) }
            'MaxCjxlProcs'       { return ($intValue -ge 1) }
            'AnimatedThreads'    { return ($intValue -ge 1) }
            'FullPipelineMaxConcurrentProcs' { return ($intValue -ge 1) }
            default              { return $true }
        }
    }
    if ($Default -is [string]) {
        return ($Value -is [string])
    }

    return $true
}

function Import-ScriptSettings {
    <#
    .SYNOPSIS
        Loads settings.json, merged onto Get-DefaultScriptSettings so a
        file from an older schema (missing newer keys) still comes back
        complete. Never throws: a missing file, unreadable/corrupt JSON,
        an unknown key, or a bad value for a known key all fall back to
        that key's default (with a Write-Log Warn for the latter three),
        rather than failing the whole load. A genuinely corrupt/unparseable
        file (not just an unknown key or bad value within an otherwise
        valid one) is backed up (timestamped .bak) AND repaired in place
        with the defaults - without the
        repair, the same corrupt file sat there forever, re-warning and
        dropping a new .bak on every single future launch. A file that
        merely can't be READ (locked, momentarily inaccessible - a second
        instance of the script, an AV/sync-client hold) is handled
        SEPARATELY and does NOT get the backup+repair treatment - it
        just uses defaults for this run, leaving the file untouched, since
        it may read fine on the very next launch. Only a genuine
        ConvertFrom-Json failure on content that WAS successfully read
        counts as corruption.
    .PARAMETER Path
        Defaults to Get-ScriptSettingsPath (real per-user AppData
        location). Pass explicitly to point at a test file instead.
    .OUTPUTS
        Hashtable, always containing every key from
        Get-DefaultScriptSettings.
    #>
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-ScriptSettingsPath }

    $settings = Get-DefaultScriptSettings

    if (-not (Test-Path -LiteralPath $Path)) {
        return $settings
    }

    # Read and parse are two SEPARATE try/catch blocks - with one shared
    # catch, a file that's merely locked/momentarily
    # inaccessible (a second instance of the script mid-Export-ScriptSettings,
    # an AV/sync-client hold) would be treated exactly like genuinely corrupt
    # JSON: backed up and REPAIRED WITH DEFAULTS, permanently overwriting
    # every real customization in a perfectly good file just because it
    # couldn't be read at that instant. Only a real ConvertFrom-Json
    # failure (content that was actually read, and IS genuinely bad) gets
    # the backup+repair treatment; a read failure degrades to "use
    # defaults for this run" without touching the file at all - it might
    # read fine next launch.
    $raw = $null
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
        Write-Log ("Settings file at '" + $Path + "' could not be read (" + $_.Exception.Message + ") - using defaults for this run without touching the file, since it may just be locked right now.") -Level Warn
        return $settings
    }

    $parsed = $null
    # DOCUMENTED DUPLICATE: UnwantedImage.ps1's Import-UnwantedImageProfiles
    # has a near-verbatim copy of this backup-timestamp / $backupOk-gated
    # repair-or-leave-alone recovery block - keep both in sync.
    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log ("Settings file at '" + $Path + "' could not be parsed (" + $_.Exception.Message + ") - using defaults.") -Level Warn
        $backupPath = $Path + ".corrupt-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".bak"
        # Backup swallowed here deliberately - a transient failure (file
        # lock, full disk, ACL) shouldn't stop the fallback-to-defaults
        # below. But the repair (overwriting $Path with defaults) is
        # GATED on this actually succeeding - otherwise a failed backup
        # plus the repair would lose the user's real settings content
        # with no backup and nothing logged about it. A failed backup
        # skips the repair entirely and says so - the corrupt file is
        # left alone for manual recovery instead of being silently
        # overwritten.
        $backupOk = $false
        try { Copy-Item -LiteralPath $Path -Destination $backupPath -Force -ErrorAction Stop; $backupOk = $true } catch { }
        if ($backupOk) {
            # Repair the file with the defaults just fell back to - without
            # this, the SAME corrupt file would sit
            # at $Path forever, so every future launch re-hit this exact
            # branch: another timestamped .bak dropped and another Warn logged
            # on every single run until someone manually deleted/fixed it.
            # Best-effort only - if the write itself fails (e.g. a read-only
            # file), this function still returns usable defaults either way,
            # it just won't have fixed the file for next time.
            try { Export-ScriptSettings -Settings $settings -Path $Path } catch { }
        } else {
            Write-Log ("Could not back up the corrupt settings file at '" + $Path + "' - leaving it untouched rather than risk overwriting it with no backup. It will be re-detected as corrupt on the next launch.") -Level Warn
        }
        return $settings
    }

    if ($null -eq $parsed -or $parsed -isnot [System.Management.Automation.PSCustomObject]) {
        # ConvertFrom-Json succeeds (no exception) on content that parses
        # but isn't a real settings object - the literal JSON `null` (a
        # realistic outcome of a truncated write, since Export-ScriptSettings's
        # Set-Content isn't atomic) parses to $null, and a JSON array parses
        # to an array. ConvertTo-SettingsHashtable's own [Parameter(Mandatory)]
        # rejects $null outright - a ParameterBindingValidationException
        # this function's own contract ("never throws") can't allow to
        # escape - so this must be caught here, before that call, and
        # routed through the same corrupt-file recovery as an actual parse
        # failure above.
        Write-Log ("Settings file at '" + $Path + "' did not contain a valid settings object - using defaults.") -Level Warn
        $backupPath = $Path + ".corrupt-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".bak"
        # Same backup-success gate as the parse-failure branch above
        # - see that branch's comment for why.
        $backupOk = $false
        try { Copy-Item -LiteralPath $Path -Destination $backupPath -Force -ErrorAction Stop; $backupOk = $true } catch { }
        if ($backupOk) {
            # Repair the file - see the
            # matching parse-failure branch above for why.
            try { Export-ScriptSettings -Settings $settings -Path $Path } catch { }
        } else {
            Write-Log ("Could not back up the corrupt settings file at '" + $Path + "' - leaving it untouched rather than risk overwriting it with no backup. It will be re-detected as corrupt on the next launch.") -Level Warn
        }
        return $settings
    }

    $loaded = ConvertTo-SettingsHashtable -InputObject $parsed
    # Keys this project no longer writes - dropped
    # silently rather than warning on every launch until the file is
    # next saved. ZipWithUnconvertedAnimated belonged to a retired mode.
    $retiredKeys = @('ZipWithUnconvertedAnimated')
    foreach ($key in $loaded.Keys) {
        if ($retiredKeys -contains $key) { continue }
        if (-not $settings.ContainsKey($key)) {
            Write-Log ("Ignoring unknown setting '" + $key + "' found in '" + $Path + "'.") -Level Warn
            continue
        }
        $value = $loaded[$key]
        if (Test-ScriptSettingValue -Key $key -Value $value -Default $settings[$key]) {
            # [int] normalization: Test-ScriptSettingValue accepts
            # an integral [double]/[decimal] for an int-typed key (a
            # hand-edited "JpegQuality": 75.0), but storing $value as-is
            # kept it a [decimal] - functionally harmless (every real
            # consumer binds it to an [int] parameter anyway) but visibly
            # wrong: the options menu displayed "Quality [75.0]" and
            # Export-ScriptSettings wrote "75.0" back out, both looking
            # like a bug even though nothing downstream actually broke.
            # The cast itself can't throw here - Test-ScriptSettingValue
            # just proved it's in Int32's range.
            if ($settings[$key] -is [int]) {
                $settings[$key] = [int]$value
            } else {
                $settings[$key] = $value
            }
        } else {
            Write-Log ("Setting '" + $key + "' in '" + $Path + "' has an invalid value - keeping default (" + $settings[$key] + ").") -Level Warn
        }
    }

    return $settings
}

function Export-ScriptSettings {
    <#
    .SYNOPSIS
        Writes $Settings to $Path as JSON, creating the parent directory
        if needed.
    .PARAMETER Path
        Defaults to Get-ScriptSettingsPath.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-ScriptSettingsPath }

    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = $Settings | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}
