<#
.SYNOPSIS
    Config - the settings file this project's other modules read their
    tunables from: default schema, load (with corrupt/stale-file
    recovery), and save.

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules.

    Forward-references (same pattern as ZipCreation.ps1/FileDeletion.ps1):
      - Write-Log (Modules\Logging.ps1) - used only for non-fatal warnings
        when a settings file is missing/corrupt/stale. Never required:
        every code path here still works correctly if Write-Log isn't
        defined-safe order just means those warnings currently error out
        instead of logging, exactly like every other module's forward
        reference in this project.

    Settings file location: %LOCALAPPDATA%\ConversionScript\settings.json
    by default (Get-ScriptSettingsPath), matching the design already
    decided in Docs\module-loading-design.md. -BaseDir lets a caller (or
    this module's harness) point elsewhere instead of the real per-user
    AppData folder.

    Schema: see Get-DefaultScriptSettings. Field names were chosen to
    match the -Param names of the real Initialize-* functions that
    consume them (Initialize-FileDeletion -PermanentDelete,
    Initialize-LogPaths -FullLogging/-DisableSummaryFile,
    Initialize-CleanConsoleOutput -Enabled, Convert-ImageBatch
    -MaxCjxlProcs/-JpegLossless/-JpegQuality) so a future caller can
    splat the loaded hashtable straight in without a translation layer.
    The five Animated* keys (AnimatedThreads/AnimatedQuality/
    AnimatedLossless/AnimatedOverwrite/AnimatedDeleteSource) are added
    ahead of AnimatedConversionPipeline.ps1 itself being built (added
    2026-08-27 for the Menu module's options-menu draft) - defaults taken
    from Backups\Old Scripts\Convert-AnimatedAvifToWebp.ps1's own CLI
    defaults (Quality 90, Lossless/Overwrite off) and
    Convert-AnimatedToJxl.ps1's KeepOriginals default (delete-on-success
    by default, matching this project's other deletion toggles) -
    AnimatedThreads has no real prior default to inherit (the old script
    used [Environment]::ProcessorCount, not something a persisted static
    setting can express) so it's set to a fixed value: 8, matching
    MaxCjxlProcs and this machine's physical core count (Ryzen 7 7800X3D).

    ZipWithUnconvertedAnimated (added 2026-08-27 alongside the Menu
    redesign in Todo.md) gates the "Image Conversion + Zip" mode, which
    runs no animated-conversion pass of its own: default $false means a
    folder still holding unconverted .avif files does NOT get zipped by
    that mode, so animated content doesn't silently end up shipped
    unconverted inside a ZIP. $true zips anyway.

    TODO once AnimatedConversionPipeline.ps1 is actually built: re-check
    these six keys (five Animated* plus ZipWithUnconvertedAnimated)
    against its real functions' actual -Param names (the same "match the
    consuming function's param names" rule every other key in this
    schema follows) and check whether it needs any settings beyond these
    - they were guessed/designed ahead of a built module, not from one.

    Real decisions made building this (not just extraction) - see
    CLAUDE.md/CHANGELOG.md for the full writeup:
      - $MaxThreads/$MaxParallel (reference: one value, CLI-overridable,
        shared by mode 3 and mode 4) became ZipParallelThreads here - one
        settings-file value, still shared by both modes, matching real
        current behavior. The options-menu sketch in Todo.md lists "Zip-
        Only Pipeline Threads" and "Rezip Pipeline Threads" as two
        separate options; splitting them is a real behavior change, not
        just data-modeling, so it was left as one setting rather than
        guessed at.
      - $deleteFolders (reference: hardcoded $true, mode 4's "delete
        extracted staging folders after a successful re-zip" flag) became
        a real setting, DeleteExtractedFoldersAfterRezip - removed
        2026-09-09 along with RezipPipeline.ps1 itself (mode 9, the only
        thing that ever read it).
      - CjxlPath/MagickPath are persisted here even though they're
        currently CLI params resolved fresh (via Find-Exe) every run -
        letting a caller cache a successful auto-detection avoids
        re-running that search every single run. Stored as plain strings,
        empty by default (meaning "not yet resolved / detect fresh"). The
        actual cache-check-then-detect-then-remember logic lives in
        DependencyDetection.ps1's Find-ExeCached, not here - this module
        only owns the field existing and its load/save; Find-ExeCached
        takes/mutates a settings hashtable rather than depending on this
        module directly, so DependencyDetection.ps1 stays standalone.
      - ModulesPath is included per Docs\module-loading-design.md, but
        this module does not implement the prompt-and-remember flow
        itself - that's the main-script rewrite's job. This module just
        gives it somewhere durable to persist that string.
      - Values are type/range-validated on load, not just merged - a
        hand-edited or corrupted settings.json is real user input, not a
        can't-happen case (CLAUDE.md's "only validate at system
        boundaries" applies here). A bad value for one key falls back to
        that key's default individually, with a warning, rather than
        discarding the whole file.

.NOTES
    Extracted from Conversion Script Main.ps1 - see
    Modules\_Reference\Config.reference.ps1 for the verbatim source this
    was built from, with original line numbers. Unlike a straight
    extraction, this module's actual job (a real settings FILE, not just
    the in-memory toggle surface) required real design decisions - see
    above.
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
        # Default matches MaxCjxlProcs (2026-09-03 addition, real bug fix -
        # see CHANGELOG.md) so upgrading doesn't silently change Full
        # Pipeline's real concurrency - this replaces the shared-budget
        # call site that used to reuse $Settings.MaxCjxlProcs directly,
        # which meant Full Pipeline's combined image+animated process
        # ceiling was ALWAYS MaxCjxlProcs alone, silently ignoring
        # AnimatedThreads entirely. Dedicated setting, not a sum of the
        # other two (MaxCjxlProcs + AnimatedThreads would silently double-
        # count for anyone who doesn't realize the two get added) - a
        # single number is the real total Full Pipeline will ever run at
        # once; MaxCjxlProcs/AnimatedThreads keep meaning exactly what
        # they say for solo modes 2/3, unaffected by this setting.
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
        ZipWithUnconvertedAnimated       = $false
        LastCoverDeletionPath            = ""
        # Placeholder (2026-09-09, options-menu redesign) - exposed as a
        # real, persisted toggle under the new "Full Pipeline Settings"
        # submenu (Menu.ps1's Get-OptionsMenuSchema), but not yet read by
        # Invoke-FullPipeline or anything else - flipping it currently has
        # no effect. See Todo.md's "Run Cover Deletion automatically
        # before Full Pipeline conversion" entry for the real feature this
        # is scaffolding toward.
        RunCoverDeletionBeforeConversion = $false
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
        # on this PS 5.1/.NET Framework combination - confirmed live
        # ('{"a":75.0}' | ConvertFrom-Json).a.GetType() -> System.Decimal,
        # NOT [double] (2026-08-31 fix, caught by a same-day /code-review:
        # the [double] branch below was dead code against real
        # ConvertFrom-Json output, so a hand-edited "JpegQuality": 75.0 in
        # settings.json was silently rejected and reverted to the
        # default, contrary to what this comment claimed). [double] kept
        # alongside [decimal] rather than replaced - some other JSON
        # parser or a value built directly in PowerShell (not from this
        # project's own ConvertFrom-Json path) could still hand this
        # function a real [double], and accepting it costs nothing.
        $isIntegral = ($Value -is [int]) -or ($Value -is [long]) -or
                      (($Value -is [double] -or $Value -is [decimal]) -and ($Value -eq [math]::Truncate($Value)))
        if (-not $isIntegral) { return $false }

        # try/catch around the [int] cast (2026-08-31 fix, caught by
        # verifying a same-day /code-review pass): a value outside
        # Int32's range (e.g. a hand-edited "MaxCjxlProcs": 99999999999)
        # is integral by the check above but throws OverflowException on
        # cast, contradicting this function's own "never throws" contract
        # (Import-ScriptSettings' docstring) - unguarded, that exception
        # escaped Import-ScriptSettings entirely (no try/catch there
        # either) and killed the WHOLE settings load, not just this one
        # key falling back to its default. An out-of-Int32-range value is
        # exactly as invalid as any other out-of-range value this
        # function already rejects below - now treated the same way.
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
        with the defaults (2026-09-03 fix, Todo.md finding) - without the
        repair, the same corrupt file sat there forever, re-warning and
        dropping a new .bak on every single future launch. A file that
        merely can't be READ (locked, momentarily inaccessible - a second
        instance of the script, an AV/sync-client hold) is handled
        SEPARATELY and does NOT get the backup+repair treatment (2026-09-03
        fix, real bug caught by a same-session /code-review pass) - it
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

    # Read and parse are two SEPARATE try/catch blocks (2026-09-03 fix,
    # real bug caught by a same-session /code-review pass) - they used to
    # share one catch, so a file that's merely locked/momentarily
    # inaccessible (a second instance of the script mid-Export-ScriptSettings,
    # an AV/sync-client hold) was treated exactly like genuinely corrupt
    # JSON: backed up and REPAIRED WITH DEFAULTS, permanently overwriting
    # every real customization in a perfectly good file just because it
    # couldn't be read at that instant. Only a real ConvertFrom-Json
    # failure (content that was actually read, and IS genuinely bad) gets
    # the backup+repair treatment now; a read failure degrades to "use
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
    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log ("Settings file at '" + $Path + "' could not be parsed (" + $_.Exception.Message + ") - using defaults.") -Level Warn
        $backupPath = $Path + ".corrupt-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".bak"
        # Backup swallowed here deliberately - a transient failure (file
        # lock, full disk, ACL) shouldn't stop the fallback-to-defaults
        # below. But the repair (overwriting $Path with defaults) is now
        # GATED on this actually succeeding (2026-09-04 fix, real bug) -
        # it used to run unconditionally, so a failed backup plus the
        # unconditional repair meant the user's real settings content
        # could be lost with no backup and nothing logged about the
        # missing backup. A failed backup now skips the repair entirely
        # and says so - the corrupt file is left alone for manual
        # recovery instead of being silently overwritten.
        $backupOk = $false
        try { Copy-Item -LiteralPath $Path -Destination $backupPath -Force -ErrorAction Stop; $backupOk = $true } catch { }
        if ($backupOk) {
            # Repair the file with the defaults just fell back to (2026-09-03
            # fix, Todo.md finding) - without this, the SAME corrupt file sat
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
        # (2026-09-04 fix, real bug) - see that branch's comment for why.
        $backupOk = $false
        try { Copy-Item -LiteralPath $Path -Destination $backupPath -Force -ErrorAction Stop; $backupOk = $true } catch { }
        if ($backupOk) {
            # Repair the file (2026-09-03 fix, Todo.md finding) - see the
            # matching parse-failure branch above for why.
            try { Export-ScriptSettings -Settings $settings -Path $Path } catch { }
        } else {
            Write-Log ("Could not back up the corrupt settings file at '" + $Path + "' - leaving it untouched rather than risk overwriting it with no backup. It will be re-detected as corrupt on the next launch.") -Level Warn
        }
        return $settings
    }

    $loaded = ConvertTo-SettingsHashtable -InputObject $parsed
    foreach ($key in $loaded.Keys) {
        if (-not $settings.ContainsKey($key)) {
            Write-Log ("Ignoring unknown setting '" + $key + "' found in '" + $Path + "'.") -Level Warn
            continue
        }
        $value = $loaded[$key]
        if (Test-ScriptSettingValue -Key $key -Value $value -Default $settings[$key]) {
            # [int] normalization (2026-08-31 fix, caught by verifying a
            # same-day /code-review pass): Test-ScriptSettingValue accepts
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
