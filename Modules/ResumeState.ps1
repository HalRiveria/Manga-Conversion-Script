<#
.SYNOPSIS
    ResumeState - tracks which ZIPs the rezip pipeline (mode 9, "Convert
    Zipped") has already fully processed, so a re-run can skip them.

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules.

    Forward-reference: Write-Log (Modules\Logging.ps1).

    Used by: the rezip pipeline only (old mode 4, now "Convert Zipped" /
    mode 9 per Menu.ps1's redesign - itself deprioritized/legacy, see
    CLAUDE.md). Mode "Zip Folders" (zip-only) has NO resume-state at all,
    same as today - flagged previously as an open question whether that's
    intentional or a gap, not addressed by this module (see
    ZipPipeline.ps1's own note).

    State file: JSON array of { Path, LastWriteTimeUtc } objects, at
    "<TargetPath>\process_state.json". A ZIP counts as already done only
    if BOTH its path AND current LastWriteTimeUtc match a recorded entry
    (Test-ResumeStateComplete) - so a replaced ZIP (same name, newer
    date) is always re-processed.

    CONSOLIDATION - the actual point of building this as a real module:
    the reference extraction has this same read-merge-write logic
    hand-duplicated in FOUR separate spots in the main script (see
    Modules\_Reference\ResumeState.reference.ps1's own header for exactly
    where). Collapsed here into one private core, Merge-ResumeStateEntries,
    shared by:
      - Save-ResumeStateEntry (the two real per-completion writes - a
        worker's own success write, and the main thread's "no
        convertible images" write - were byte-for-byte identical logic
        in the reference, just triggered from two different call sites;
        one shared function now, not two copies)
      - Save-ResumeStateBag (the abort-path bulk re-merge, re-syncing the
        on-disk file against an in-memory "what actually finished" bag,
        since jobs can complete after the file's last periodic write but
        before an abort is detected)
    Import-ResumeStateMap covers the fourth spot (startup load).
    Test-ResumeStateComplete is new - the reference's own comment
    describes the "both path AND LastWriteTimeUtc must match" rule but
    never factored it into its own function; every caller would otherwise
    have had to reimplement that comparison by hand.

    REAL BUG FIXED while consolidating (not present as a decision in the
    reference - a side effect of collapsing four copies into one place
    made it visible): the reference's write step pipes a merged
    hashtable's entries through `ConvertTo-Json` via the pipeline
    (`... | ForEach-Object {...} | ConvertTo-Json -Compress`). In Windows
    PowerShell 5.1, piping a SINGLE object into ConvertTo-Json serializes
    it as a bare JSON object, not a one-element array - so a state file
    with exactly one completed ZIP would come back as `{...}` instead of
    `[{...}]`. Reading it back still worked by accident (PowerShell's
    `foreach` treats a scalar as a one-item sequence, and
    Import-ResumeStateMap's `foreach ($entry in $raw)` is exactly that
    kind of loop) - so this was latent, not something that visibly broke
    anything, but still an inconsistent on-disk shape depending on entry
    count. Fixed in Merge-ResumeStateEntries by building an explicit
    PowerShell array (`@(...)`) and passing it to ConvertTo-Json via
    `-InputObject` (bypassing the pipeline, which is what unrolls a
    single-element array in the first place) - PS 5.1 has no -AsArray
    switch (that's PS6+), so this is the compatible way to get consistent
    `[]`/`[{...}]`/`[{...},{...}]` output regardless of count.

    Save-ResumeStateBag's -StateMutex is OPTIONAL, matching the
    reference's own abort-path save (which does not lock at all, unlike
    the two per-completion writes) - not a decision to add locking there,
    just leaving the option available to a future caller without changing
    current behavior when omitted.

.NOTES
    Extracted from Conversion Script Main.ps1 - see
    Modules\_Reference\ResumeState.reference.ps1 for the verbatim source
    this was built from (all four original spots, with line numbers).
#>

function Get-ResumeStatePath {
    <#
    .SYNOPSIS
        "<TargetPath>\process_state.json" - the one place this filename
        is decided.
    #>
    param([Parameter(Mandatory)][string]$TargetPath)

    return (Join-Path $TargetPath "process_state.json")
}

function Get-ValidResumeStateEntries {
    <#
    .SYNOPSIS
        Private helper - reads and parses $StateFile, returning only the
        entries that have both a Path and a LastWriteTimeUtc property.
        Empty array if the file doesn't exist. Any parse exception
        PROPAGATES (not swallowed here) - callers decide how to handle a
        corrupt file, since that differs by caller: Import-ResumeStateMap
        logs a Warn and starts fresh; Merge-ResumeStateEntries silently
        starts fresh (matching each function's own pre-existing
        behavior, preserved when this was factored out of both).
    .OUTPUTS
        An array of the raw parsed entry objects (PSCustomObject, each
        with .Path/.LastWriteTimeUtc) that passed validation.
    #>
    param([Parameter(Mandatory)][string]$StateFile)

    if (-not (Test-Path -LiteralPath $StateFile)) { return @() }

    $raw = [System.IO.File]::ReadAllText($StateFile) | ConvertFrom-Json
    return @($raw | Where-Object { $_.PSObject.Properties['Path'] -and $_.PSObject.Properties['LastWriteTimeUtc'] })
}

function Import-ResumeStateMap {
    <#
    .SYNOPSIS
        Loads $StateFile (if present) into a case-insensitive
        Path -> LastWriteTimeUtc map. A missing file returns an empty
        map silently; a corrupt/unparsable file returns an empty map
        with a Write-Log Warn rather than throwing.
    .OUTPUTS
        System.Collections.Generic.Dictionary[string,string]
        (OrdinalIgnoreCase key comparer).
    #>
    param([Parameter(Mandatory)][string]$StateFile)

    $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $StateFile)) { return $map }

    try {
        foreach ($entry in (Get-ValidResumeStateEntries -StateFile $StateFile)) {
            $map[$entry.Path] = $entry.LastWriteTimeUtc
        }
        Write-Log ("Resume state loaded: " + $map.Count + " previously completed ZIP(s) tracked. Delete '" + $StateFile + "' to start completely fresh.")
    } catch {
        Write-Log ("Could not read resume state file - starting fresh. (" + $_ + ")") -Level Warn
    }
    return $map
}

function Test-ResumeStateComplete {
    <#
    .SYNOPSIS
        True only if $ResumedMap has $ZipPath recorded AND its recorded
        LastWriteTimeUtc matches $LastWriteTimeUtc exactly - a replaced
        ZIP (same path, different/newer write time) is never considered
        complete.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.IDictionary[string,string]]$ResumedMap,
        [Parameter(Mandatory)]
        [string]$ZipPath,
        [Parameter(Mandatory)]
        [string]$LastWriteTimeUtc
    )

    $recorded = $null
    if ($ResumedMap.TryGetValue($ZipPath, [ref]$recorded)) {
        return ($recorded -eq $LastWriteTimeUtc)
    }
    return $false
}

function Merge-ResumeStateEntries {
    <#
    .SYNOPSIS
        Private core: reads $StateFile's existing entries (tolerating a
        missing/corrupt file - starts from empty rather than throwing),
        merges $NewEntries on top (new entries win on a Path collision),
        and writes the merged result back as a proper JSON array
        regardless of how many entries it has (see module header's "REAL
        BUG FIXED" note for why -InputObject, not the pipeline, is used
        here). Returns the merged entry count.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$StateFile,
        [Parameter(Mandatory)]
        [System.Collections.Generic.IDictionary[string,string]]$NewEntries
    )

    $merged = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($e in (Get-ValidResumeStateEntries -StateFile $StateFile)) {
            $merged[$e.Path] = $e.LastWriteTimeUtc
        }
    } catch { }
    foreach ($kvp in $NewEntries.GetEnumerator()) { $merged[$kvp.Key] = $kvp.Value }

    $mergedArray = @($merged.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Path = $_.Key; LastWriteTimeUtc = $_.Value } })
    $json = ConvertTo-Json -InputObject $mergedArray -Compress
    Set-Content -LiteralPath $StateFile -Value $json -Encoding UTF8

    return $merged.Count
}

function Invoke-ResumeStateWrite {
    <#
    .SYNOPSIS
        Private helper - wait on $StateMutex if one is supplied, call
        Merge-ResumeStateEntries, release in finally, swallow any
        exception (including a failed mutex wait) and return $null on
        failure. Shared by Save-ResumeStateEntry (always passes a mutex)
        and Save-ResumeStateBag's two branches (with and without one),
        which previously each implemented this wait/merge/release/swallow
        shape by hand. Not directly reusable as Logging.ps1's own
        Invoke-MutexGuardedWrite - that one lets exceptions propagate,
        this one needs to swallow and return $null instead.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$StateFile,
        [Parameter(Mandatory)]
        [System.Collections.Generic.IDictionary[string,string]]$NewEntries,
        [System.Threading.Mutex]$StateMutex
    )

    try {
        if ($StateMutex) {
            $null = $StateMutex.WaitOne()
            try {
                return Merge-ResumeStateEntries -StateFile $StateFile -NewEntries $NewEntries
            } finally {
                $StateMutex.ReleaseMutex()
            }
        }
        return Merge-ResumeStateEntries -StateFile $StateFile -NewEntries $NewEntries
    } catch {
        return $null
    }
}

function Save-ResumeStateEntry {
    <#
    .SYNOPSIS
        Marks one ZIP as fully completed: mutex-protected read-merge-
        write against $StateFile. Shared by both real per-completion
        write sites (a worker's own success write, and the main thread's
        "no convertible images" write) - one function, not two
        hand-duplicated copies. Failures (including a failed mutex wait)
        are swallowed, returning $null, rather than throwing - matching
        the reference's own try/catch-and-continue behavior, since a
        failed state write should not crash a real conversion run.
    .OUTPUTS
        The merged entry count on success, or $null on failure.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$StateFile,
        [Parameter(Mandatory)]
        [System.Threading.Mutex]$StateMutex,
        [Parameter(Mandatory)]
        [string]$ZipPath,
        [Parameter(Mandatory)]
        [string]$LastWriteTimeUtc
    )

    $newEntries = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $newEntries[$ZipPath] = $LastWriteTimeUtc

    return Invoke-ResumeStateWrite -StateFile $StateFile -NewEntries $newEntries -StateMutex $StateMutex
}

function Save-ResumeStateBag {
    <#
    .SYNOPSIS
        Abort-path bulk save: re-merges $StateFile against an in-memory
        "completed bag" (a ConcurrentDictionary[string,string] whose
        values are JSON-encoded {Path,LastWriteTimeUtc} strings, matching
        the shape callers already build per-job), since jobs can finish
        after the file's last periodic write but before an abort is
        detected.
    .PARAMETER StateMutex
        Optional - the reference's own abort-path save does not lock at
        all (unlike the two per-completion writes), so this defaults to
        no locking to match. Pass one if a future caller wants the extra
        safety; not a behavior change on its own.
    .OUTPUTS
        The merged entry count on success, or $null on failure.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$StateFile,
        [Parameter(Mandatory)]
        $CompletedBag,
        [System.Threading.Mutex]$StateMutex
    )

    $newEntries = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($kvp in $CompletedBag.GetEnumerator()) {
        try {
            $obj = $kvp.Value | ConvertFrom-Json
            if ($obj.Path -and $obj.LastWriteTimeUtc) { $newEntries[$obj.Path] = $obj.LastWriteTimeUtc }
        } catch {
            # 2026-08-31 fix: this used to swallow a malformed bag entry
            # with no comment and no log line (CLAUDE.md: "no silent
            # catches without a reason"). $CompletedBag entries are built
            # in-process by this run's own workers, not read from an
            # external file, so a malformed one here means something
            # actually went wrong upstream - worth a log line even though
            # dropping just this one entry (rather than aborting the whole
            # bulk save) is still the right recovery.
            Write-Log ("Skipping malformed resume-state bag entry for '" + $kvp.Key + "': " + $_) -Level Warn
        }
    }

    return Invoke-ResumeStateWrite -StateFile $StateFile -NewEntries $newEntries -StateMutex $StateMutex
}

function Write-ResumeStateRetainedNotice {
    <#
    .SYNOPSIS
        Logs "Resume state file retained for future runs: '<path>'" if
        $StateFile exists on disk - a no-op otherwise (e.g. every
        candidate ZIP was skipped/failed this run and nothing was ever
        recorded, or a prior run never created the file either). Ported
        verbatim from the original script's own end-of-run text (see
        Modules\_Reference\Summary.reference.ps1) - Summary.ps1
        deliberately did not pick this up (not its domain, this module's
        instead), and this module never had a real call for it added
        until now. Call once, at the very end of a rezip run, after
        whatever completion writes that run made.
    #>
    param([Parameter(Mandatory)][string]$StateFile)

    if (Test-Path -LiteralPath $StateFile) {
        Write-Log ("Resume state file retained for future runs: '" + $StateFile + "'") -Level Summary
    }
}
