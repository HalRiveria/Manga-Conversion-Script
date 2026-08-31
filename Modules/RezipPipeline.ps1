<#
.SYNOPSIS
    RezipPipeline - mode 9 ("Convert Zipped", deprecated/legacy, see
    Menu.ps1): extracts each ZIP under -Path, converts its images,
    re-zips, tracks completion via ResumeState.ps1 so a re-run skips
    already-done ZIPs.

.DESCRIPTION
    Pure definitions only - no top-level side effects, safe to dot-source
    more than once or alongside other modules.

    SCOPE NOTE: this module is deprioritized/legacy (see CLAUDE.md) - the
    project owner asked for minimal effort here, only what's necessary to
    function. Two things the reference extraction's own header flagged as
    real open decisions were resolved explicitly before writing any code,
    not guessed at:
      - Zip creation calls Compress-FolderToZip/Test-ZipArchive directly
        (matching ZipPipeline.ps1's own worker pattern) rather than adding
        a new shared helper function elsewhere - simplest option, explicit
        project-owner choice given the "minimal effort" direction.
      - This does NOT resolve the existing partial-zip-cleanup inconsistency
        between ZipPipeline.ps1's two call sites (mode 3 deletes a broken
        partial ZIP on failure, Invoke-LooseFolderZip doesn't) - this
        module doesn't clean up a broken partial ZIP either, matching the
        reference's own original behavior. Still an open inconsistency
        across all three call sites now, not made worse, not resolved -
        see CLAUDE.md's Known gaps.

    REAL SIMPLIFICATIONS versus the reference extraction (not just a
    verbatim port - the reference's own header flagged both of these as
    "split out, don't copy wholesale"):

    1. MIGRATED onto Invoke-ZipParallelProcessing (ZipParallelProcessing.ps1)
       instead of the reference's own hand-rolled scan+dispatch+collect
       loop and its separate 60s graceful-abort-drain loop. This is not
       just less code to maintain - it picks up, for free, fixes that
       loop never had: the graceful-drain race condition (a job finishing
       in the ~250ms gap between the last poll and the timeout firing no
       longer gets silently discarded and miscounted as force-stopped),
       and real [ConsoleCtrl]::DrainComplete signalling (the reference's
       own loop only signalled it on the X-button/ctrlCloseAbort path,
       never on a plain Ctrl+C). Same pattern ZipPipeline.ps1's
       Invoke-ZipOnlyPipeline already established for mode 3.

    2. RESUME-STATE now goes through ResumeState.ps1 (Import-ResumeStateMap/
       Save-ResumeStateEntry/Test-ResumeStateComplete) instead of the
       reference's four hand-duplicated read-merge-write-under-mutex
       spots. A bigger structural change than a straight call-site swap,
       enabled by how Invoke-ZipParallelProcessing is shaped: every
       completed job - whether finishing during normal dispatch OR during
       the graceful abort drain - passes through the SAME -ResultHandler,
       called on the main thread, never concurrently with itself. That
       means the state-completion write for a successful ZIP can happen
       from -ResultHandler alone; the reference's separate "abort-path
       bulk re-merge against an in-memory completed bag" (RESUME-STATE 4
       of 4 in the reference) is not needed at all - there's no window
       where a completion could be missed, since the drain's completions
       flow through the exact same handler as normal ones. The worker
       itself no longer takes -StateFile/-StateMutex/-CompletedBag params
       at all - it just returns a result; the caller decides what to do
       with it. -NextJobProvider's own "no convertible images" case
       writes its resume-state entry the same way, also main-thread-only
       (a job source is polled by Invoke-ZipParallelProcessing's own
       single dispatch loop, never in parallel with itself either).

    REAL BEHAVIOR FOUND WHILE BUILDING THIS (not a bug introduced here -
    present in the reference extraction too): a ZIP that WAS successfully
    converted has its resume-state entry recorded against the timestamp
    captured BEFORE processing, but STEP 4 rewrites that exact file in
    place (extract -> convert -> re-compress OVER the same path via
    Compress-FolderToZip, which deletes then recreates it) - so the
    file's real on-disk LastWriteTime changes the moment it's rewritten,
    and no longer matches what was recorded. So Test-ResumeStateComplete
    alone never actually skips a genuinely-finished ZIP on a later run -
    strictly narrower than what the state file's own name implies.

    In practice this turns out mostly harmless, not the "full reprocessing
    every time" problem it sounds like: since a successfully-converted
    ZIP's remaining entries are now all `.jxl` (not matching the
    "convertible image" extension pattern the job provider peeks for), a
    later run's cheap pre-dispatch inspection - not the timestamp check -
    is what actually keeps it from being re-extracted/re-converted. It
    gets peeked at (one ZipFile.OpenRead + entry-name scan), found to
    have "no convertible images", and re-recorded - never re-dispatched
    to a real extract/convert/re-zip worker. The one genuinely wasted
    thing on a later run is that cheap peek itself, not the expensive
    work. A ZIP with a MIXED outcome (some images converted, some left
    failed/unconverted) behaves correctly for a different reason: it's
    never recorded as complete in the first place (ResultHandler only
    records a fully-succeeded job), and its leftover unconverted entries
    still match the image pattern on a later scan, so it's correctly
    re-dispatched. Confirmed with harness scenarios that run the same ZIP
    through the pipeline twice. Not touched further here - the underlying
    timestamp mismatch is still real (see CLAUDE.md's Known gaps for
    whoever revisits this), just less consequential in practice than it
    first appeared.

    NOT BUILT, matching the "minimal, deprecated" direction - not an
    oversight: the reference's elaborate abort-path SUMMARY (trigger
    label, "last completed jobs" list, force-stopped count, dual-mode log
    writing) is mostly Write-Host/string-building, not core pipeline
    behavior - the reference's own header says as much (point 3: "not
    extracted in full detail here"). The actual abort MECHANICS (graceful
    drain, force-stop after 60s, DrainComplete signalling) are fully
    present via Invoke-ZipParallelProcessing/AbortPipeline.ps1 - only the
    fancy end-of-run report text is skipped. A future caller gets
    -ForceStoppedCount back in the totals and can build whatever report
    it wants around that.

    FORWARD REFERENCES (not defined in this module - callers must
    dot-source the owning module(s) first):
      - Write-Log, Invoke-MutexGuardedWrite, Get-LoggingSharedFunctionNames
        (Logging.ps1)
      - Move-ToRecycleBin, Remove-ItemPermanently, Remove-Source,
        Get-FileDeletionSharedFunctionNames (FileDeletion.ps1)
      - Compress-FolderToZip, Get-ZipCreationSharedFunctionNames (ZipCreation.ps1)
      - Test-ZipArchive, Get-ZipValidationSharedFunctionNames (ZipValidation.ps1)
      - Convert-ImageBatch, Get-ImageConversionSharedFunctionNames
        (ImageConversionPipeline.ps1)
      - Get-*SharedFunctionNames (2026-08-29) are each module's own single
        source of truth for what a caller needs in -SharedFunctionNames to
        call into it from a runspace worker - see Controller.ps1's own
        header for the full reasoning (same pattern, same reason).
      - Invoke-ZipParallelProcessing (ZipParallelProcessing.ps1)
      - Register-AbortCancellationSource, Unregister-AbortCancellationSource
        (AbortPipeline.ps1)
      - Get-ResumeStatePath, Import-ResumeStateMap, Save-ResumeStateEntry,
        Test-ResumeStateComplete, Write-ResumeStateRetainedNotice
        (ResumeState.ps1)
    Same dot-source ordering rule as ZipPipeline.ps1: Logging.ps1/
    FileDeletion.ps1 BEFORE ZipParallelProcessing.ps1, since
    -SharedFunctionNames captures whichever definition is CURRENTLY active
    in the caller's scope at call time.

.NOTES
    Extracted from Conversion Script Main.ps1 - see
    Modules\_Reference\RezipPipeline.reference.ps1 for the verbatim source
    this was built from, with original line numbers, and the three
    "split out, don't copy wholesale" items its own header called out.
#>

function Get-RezipCandidateZips {
    <#
    .SYNOPSIS
        Every *.zip under $Path, excluding one sitting inside what looks
        like another ZIP's own extraction staging folder (a directory
        sharing its name with a sibling .zip) - a leftover from a
        previous partial run, not real content to re-process.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $all = @(Get-ChildItem -LiteralPath $Path -Recurse -Filter "*.zip" -File -ErrorAction SilentlyContinue |
        Where-Object {
            $parentOfDir = [System.IO.Path]::GetDirectoryName($_.DirectoryName)
            -not ($parentOfDir -and (Test-Path -LiteralPath ([System.IO.Path]::Combine($parentOfDir, ($_.Directory.Name + ".zip")))))
        })
    return ,$all
}

# ---- Worker scriptblock, dispatched once per qualifying ZIP via
#      Invoke-ZipParallelProcessing. Must declare CancelToken/LogMutex/
#      ConsoleQueue per ZPP's contract. No resume-state params here - see
#      module header for why that moved to the caller's -ResultHandler. ----
$script:rezipWorker = {
    param(
        [string]$ZipPath,
        [string]$ZipLastWriteTimeUtc,
        [string]$CjxlExe,
        [string]$MagickExe,
        [string]$LogFile,
        [string]$LogErrorFile,
        [string]$LogWarnFile,
        [bool]$DoFullLogging,
        [bool]$DeleteFolders,
        [int]$MaxCjxlProcs,
        [bool]$DoJpegLossless,
        [int]$DoJpegQuality,
        [bool]$DoPermanentDelete,
        [System.Threading.Mutex]$LogMutex,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ConsoleQueue,
        [System.Threading.CancellationToken]$CancelToken
    )

    Add-Type -AssemblyName "Microsoft.VisualBasic"
    Add-Type -AssemblyName "System.IO.Compression.FileSystem"

    $script:logMutex           = $LogMutex
    $script:workerConsoleQueue = $ConsoleQueue
    $script:FullLogging        = $DoFullLogging
    $script:logFile            = $LogFile
    $script:logErrorFile       = $LogErrorFile
    $script:logWarnFile        = $LogWarnFile
    $script:PermanentDelete    = $DoPermanentDelete

    $result = @{
        ZipPath             = $ZipPath
        ZipName             = [System.IO.Path]::GetFileName($ZipPath)
        ZipLastWriteTimeUtc = $ZipLastWriteTimeUtc
        ZipExtracted        = 0; ZipExtractFailed   = 0
        ImgConverted        = 0; ImgConvertFailed   = 0; ImgSkipped = 0
        ImgDeleted          = 0; ImgDeleteFailed    = 0
        ZipCreated          = 0; ZipCreateFailed    = 0
        FolderDeleted       = 0; FolderDeleteFailed = 0
    }

    $parentDir  = [System.IO.Path]::GetDirectoryName($ZipPath)
    $baseName   = [System.IO.Path]::GetFileNameWithoutExtension($ZipPath)
    $extractDir = [System.IO.Path]::Combine($parentDir, $baseName)

    Write-Log ("--- Begin: '" + $result.ZipName + "' ---")

    if ($CancelToken.IsCancellationRequested) {
        Write-Log ("Cancelled before starting '" + $result.ZipName + "'") -Level Warn
        return $result
    }

    # ------------------------------------------------------------------
    #  STEP 1 - Extract ZIP
    # ------------------------------------------------------------------
    $extractOk = $false
    try {
        Write-Log ("Extracting '" + $ZipPath + "' -> '" + $extractDir + "'")

        if (-not (Test-Path -LiteralPath $extractDir)) {
            [System.IO.Directory]::CreateDirectory($extractDir) | Out-Null
        }

        # ZipFile::ExtractToDirectory has no overwrite option in .NET 4.x,
        # so extract entry-by-entry and overwrite any existing files.
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            foreach ($entry in $zip.Entries) {
                $destPath = [System.IO.Path]::Combine($extractDir, $entry.FullName)
                if ($entry.FullName.EndsWith("/") -or $entry.FullName.EndsWith("\")) {
                    [System.IO.Directory]::CreateDirectory($destPath) | Out-Null
                } else {
                    $destDir = [System.IO.Path]::GetDirectoryName($destPath)
                    if (-not (Test-Path -LiteralPath $destDir)) {
                        [System.IO.Directory]::CreateDirectory($destDir) | Out-Null
                    }
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destPath, $true)
                }
            }
        } finally {
            $zip.Dispose()
        }

        Write-Log ("Extracted OK: '" + $extractDir + "'")
        $result.ZipExtracted = 1
        $extractOk = $true
    } catch {
        Write-Log ("FAILED to extract '" + $ZipPath + "': " + $_) -Level Error
        $result.ZipExtractFailed = 1
    }

    if (-not $extractOk) {
        Write-Log ("Skipping remaining steps for '" + $result.ZipName + "' due to extraction failure.") -Level Warn
        return $result
    }

    # ------------------------------------------------------------------
    #  STEPS 2 & 3 - Convert images, delete source on success
    # ------------------------------------------------------------------
    $imgExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif")
    $imgFiles = @(Get-ChildItem -LiteralPath $extractDir -Recurse -File -ErrorAction SilentlyContinue |
                  Where-Object { $imgExtensions -icontains $_.Extension })

    if ($imgFiles.Count -eq 0) {
        Write-Log ("No convertible image files found in '" + $extractDir + "'.")
    } else {
        Write-Log ("Found " + $imgFiles.Count + " image(s) in '" + $extractDir + "' - converting.")

        # No -AbortWaitMessage passed (2026-08-29) - this call runs inside
        # $script:rezipWorker's own runspace, where CleanConsoleRendering.ps1's
        # module-scope state (e.g. $script:ccrActiveSeries) is never
        # initialized (only function definitions propagate into a fresh
        # runspace via -SharedFunctionNames, not a module's top-level state).
        # Passing a real message here would let Convert-ImageBatch's own
        # internal straggler-drain try to call into CCR's live-region
        # display machinery from an unsafe context if Clean Console Output
        # is on - see CLAUDE.md's Known gaps. Matches Controller.ps1's own
        # Full Pipeline worker, which never passed this either. The outer
        # Invoke-ZipParallelProcessing call below already prints its own
        # (CCR-safe, main-thread) default wait message via
        # AbortPipeline.ps1's Invoke-GracefulDrain, so the user still sees
        # an abort-in-progress message either way.
        $batchResult = Convert-ImageBatch -ImageFiles $imgFiles -CjxlExe $CjxlExe -MagickExe $MagickExe `
            -DoJpegLossless $DoJpegLossless -DoJpegQuality $DoJpegQuality -MaxCjxlProcs $MaxCjxlProcs `
            -DoFullLogging $DoFullLogging -CancelToken $CancelToken -BatchLabel $result.ZipName

        $result.ImgConverted     = $batchResult.ConvertedCount
        $result.ImgConvertFailed = $batchResult.FailedCount
        $result.ImgSkipped       = $batchResult.SkippedCount
        $result.ImgDeleted       = $batchResult.DeletedCount
        $result.ImgDeleteFailed  = $batchResult.DeleteFailedCount
    }

    if ($CancelToken.IsCancellationRequested) {
        Write-Log ("Cancelled before re-zip step for '" + $result.ZipName + "'") -Level Warn
        return $result
    }

    # ------------------------------------------------------------------
    #  STEP 4 - Re-zip extracted folder. Intentionally unconditional -
    #  confirmed intentional behavior (not an oversight), see CLAUDE.md.
    # ------------------------------------------------------------------
    $zipOut = $extractDir + ".zip"

    try {
        Write-Log ("Re-zipping '" + $extractDir + "' -> '" + $zipOut + "'")

        $zipSize = Compress-FolderToZip -SourceDir $extractDir -ZipOut $zipOut
        $verify  = Test-ZipArchive -ZipPath $zipOut

        Write-Log ("ZIP OK: '" + $zipOut + "' (" + $zipSize + " bytes, " + $verify.EntryCount + " entries)")
        $result.ZipCreated = 1

        if ($DeleteFolders) {
            try {
                Remove-ItemPermanently -ItemPath $extractDir | Out-Null
                Write-Log ("Deleted folder (permanently - extracted by job): '" + $extractDir + "'")
                $result.FolderDeleted = 1
            } catch {
                Write-Log ("FAILED to delete folder '" + $extractDir + "': " + $_) -Level Error
                $result.FolderDeleteFailed = 1
            }
        } else {
            Write-Log ("Folder kept (deletion skipped): '" + $extractDir + "'")
        }
    } catch {
        Write-Log ("FAILED to re-zip '" + $extractDir + "': " + $_) -Level Error
        $result.ZipCreateFailed = 1
    }

    Write-Log ("--- Done: '" + $result.ZipName + "' ---")
    return $result
}

function Invoke-RezipPipeline {
    <#
    .SYNOPSIS
        Mode 9 ("Convert Zipped") end to end: discovers ZIPs under $Path,
        skips ones ResumeState.ps1 already recorded as complete, extracts
        + converts + re-zips the rest in parallel (via
        Invoke-ZipParallelProcessing), and records each newly-completed
        ZIP as it finishes.
    .OUTPUTS
        A plain result hashtable (CandidateCount, per-step Success/Fail/
        Skipped counters, ForceStoppedCount) - not a mutation of an
        external $stats hashtable, matching Invoke-ZipOnlyPipeline's own
        convention. The caller folds this into whatever stats shape it
        uses (e.g. Summary.ps1's RunConvertZipped row-group).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [int]$MaxParallel,
        [bool]$DeleteFolders = $false,
        [Parameter(Mandatory)]
        [bool]$FullLogging,
        [string]$LogFile,
        [string]$LogErrorFile,
        [string]$LogWarnFile,
        [Parameter(Mandatory)]
        [bool]$PermanentDelete,
        [Parameter(Mandatory)]
        [string]$CjxlExe,
        [string]$MagickExe,
        [Parameter(Mandatory)]
        [int]$MaxCjxlProcs,
        [bool]$JpegLossless = $false,
        [int]$JpegQuality = 90
    )

    $totals = @{
        CandidateCount       = 0
        ZipExtractedSuccess  = 0; ZipExtractedFail   = 0
        ImgConvertedSuccess  = 0; ImgConvertedFail   = 0; ImgConvertedSkipped = 0
        ImgDeletedSuccess    = 0; ImgDeletedFail     = 0
        ZipCreatedSuccess    = 0; ZipCreatedFail     = 0
        FolderDeletedSuccess = 0; FolderDeletedFail  = 0
        Skipped              = 0
        ForceStoppedCount    = 0
    }

    $stateFile  = Get-ResumeStatePath -TargetPath $Path
    $resumedMap = Import-ResumeStateMap -StateFile $stateFile
    $stateMutex = New-Object System.Threading.Mutex($false, ("RezipStateMutex_" + [guid]::NewGuid().ToString("N")))

    try {
        $allZips = Get-RezipCandidateZips -Path $Path

        if ($allZips.Count -eq 0) {
            Write-Log "No ZIP files found." -Level Warn
            return $totals
        }

        Write-Log ("Found " + $allZips.Count + " ZIP file(s). Scanning and dispatching as qualifying ZIPs are found...")

        $imgPattern = '\.(jpg|jpeg|png|webp|tiff|tif)$'
        # A real .NET enumerator, not a plain scalar counter - MoveNext()
        # mutates the enumerator OBJECT's own internal state, which is
        # what actually persists reliably across separate invocations of
        # a .GetNewClosure()'d scriptblock. A plain [int] index mutated
        # with $zipIndex++ does NOT reliably persist the same way (see
        # Docs/lessons-learned.md) - live-reproduced here the hard way:
        # an early version of this provider used exactly that scalar
        # pattern, and under real Invoke-ZipParallelProcessing dispatch
        # it silently restarted from the beginning on later calls,
        # re-dispatching already-in-flight ZIPs to a second/third
        # concurrent runspace and corrupting each other's extract
        # folders. Matches LeafDirectoryDiscovery.ps1's own proven-safe
        # enumerator-based pattern.
        $zipEnumerator = $allZips.GetEnumerator()

        # Incremental job source: skips already-resumed ZIPs and "no
        # convertible images" ZIPs internally (recording the latter in
        # resume-state on the way past, main-thread-only - see module
        # header), returning $null only once every candidate has been
        # examined. Mirrors ZipPipeline.ps1's own -NextJobProvider shape.
        $rzJobProvider = {
            while ($zipEnumerator.MoveNext()) {
                $zip = $zipEnumerator.Current
                $zipLwt = $zip.LastWriteTimeUtc.ToString("o")

                if (Test-ResumeStateComplete -ResumedMap $resumedMap -ZipPath $zip.FullName -LastWriteTimeUtc $zipLwt) {
                    Write-Log ("Skipping '" + $zip.Name + "' - already completed (date unchanged).")
                    $totals.Skipped++
                    continue
                }

                $hasImgs   = $false
                $inspectOk = $true
                try {
                    $peek = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
                    try {
                        foreach ($entry in $peek.Entries) {
                            if ($entry.Name -imatch $imgPattern) { $hasImgs = $true; break }
                        }
                    } finally { $peek.Dispose() }
                } catch {
                    Write-Log ("Could not inspect '" + $zip.FullName + "' - skipping: " + $_) -Level Warn
                    $inspectOk = $false
                }

                if (-not $inspectOk) {
                    $totals.Skipped++
                    continue
                }

                if (-not $hasImgs) {
                    Write-Log ("Skipping '" + $zip.FullName + "' - no convertible images inside.") -Level Warn
                    $null = Save-ResumeStateEntry -StateFile $stateFile -StateMutex $stateMutex -ZipPath $zip.FullName -LastWriteTimeUtc $zipLwt
                    $totals.Skipped++
                    continue
                }

                $totals.CandidateCount++
                Write-Log ("Dispatching '" + $zip.Name + "' for conversion.")
                return @{
                    ZipPath             = $zip.FullName
                    ZipLastWriteTimeUtc = $zipLwt
                    CjxlExe             = $CjxlExe
                    MagickExe           = $MagickExe
                    LogFile             = $LogFile
                    LogErrorFile        = $LogErrorFile
                    LogWarnFile         = $LogWarnFile
                    DoFullLogging       = $FullLogging
                    DeleteFolders       = $DeleteFolders
                    MaxCjxlProcs        = $MaxCjxlProcs
                    DoJpegLossless      = $JpegLossless
                    DoJpegQuality       = $JpegQuality
                    DoPermanentDelete   = $PermanentDelete
                }
            }
            return $null
        }.GetNewClosure()

        # Every completed job - normal dispatch or the graceful abort
        # drain - passes through here on the main thread. Resume-state is
        # recorded here, not inside the worker - see module header.
        $rzResultHandler = {
            param($r)
            $totals.ZipExtractedSuccess  += $r.ZipExtracted
            $totals.ZipExtractedFail     += $r.ZipExtractFailed
            $totals.ImgConvertedSuccess  += $r.ImgConverted
            $totals.ImgConvertedFail     += $r.ImgConvertFailed
            $totals.ImgConvertedSkipped  += $r.ImgSkipped
            $totals.ImgDeletedSuccess    += $r.ImgDeleted
            $totals.ImgDeletedFail       += $r.ImgDeleteFailed
            $totals.ZipCreatedSuccess    += $r.ZipCreated
            $totals.ZipCreatedFail       += $r.ZipCreateFailed
            $totals.FolderDeletedSuccess += $r.FolderDeleted
            $totals.FolderDeletedFail    += $r.FolderDeleteFailed

            $zipFullySucceeded = ($r.ZipExtractFailed -eq 0) -and ($r.ZipCreateFailed -eq 0) -and ($r.ImgConvertFailed -eq 0)
            if ($zipFullySucceeded) {
                $null = Save-ResumeStateEntry -StateFile $stateFile -StateMutex $stateMutex -ZipPath $r.ZipPath -LastWriteTimeUtc $r.ZipLastWriteTimeUtc
            } else {
                Write-Log ("ZIP '" + $r.ZipName + "' had failures - NOT recorded in state file; will be retried next run.") -Level Warn
            }
        }.GetNewClosure()

        $script:rezipCts = [System.Threading.CancellationTokenSource]::new()
        Register-AbortCancellationSource -Cts $script:rezipCts
        try {
            $rezipWorkerSharedFunctionNames = @(Get-LoggingSharedFunctionNames) + @(Get-FileDeletionSharedFunctionNames) + @(Get-ZipCreationSharedFunctionNames) + @(Get-ZipValidationSharedFunctionNames) + @(Get-ImageConversionSharedFunctionNames)
            $rzOutcome = Invoke-ZipParallelProcessing -WorkerScript $script:rezipWorker -NextJobProvider $rzJobProvider `
                -SharedFunctionNames $rezipWorkerSharedFunctionNames `
                -MaxParallel $MaxParallel -Cts $script:rezipCts -ResultHandler $rzResultHandler

            $totals.ForceStoppedCount = $rzOutcome.ForceStoppedCount
        } finally {
            Unregister-AbortCancellationSource -Cts $script:rezipCts
            $script:rezipCts.Dispose()
            $script:rezipCts = $null
        }

        if ($totals.CandidateCount -eq 0) {
            Write-Log "Rezip: no qualifying ZIPs (with convertible images) found." -Level Warn
        } else {
            $rzCompleteMsg = "Rezip processing complete: " + $totals.ZipCreatedSuccess + " zipped, " + $totals.ZipCreatedFail + " failed, " + $totals.Skipped + " skipped."
            if ($totals.ForceStoppedCount -gt 0) {
                $rzCompleteMsg += (" " + $totals.ForceStoppedCount + " job(s) force-stopped on abort.")
            }
            Write-Log $rzCompleteMsg -Level Summary
        }
    } finally {
        $stateMutex.Dispose()
    }

    # The "gap, not yet done" this project's own docs flagged: nothing
    # emitted this notice anywhere until now (Summary.ps1 deliberately
    # left it to ResumeState.ps1's domain instead of building it itself -
    # see that module's header). Called once, after every completion
    # write this run made, so a real newly-created state file is
    # reflected too, not just a pre-existing one.
    Write-ResumeStateRetainedNotice -StateFile $stateFile

    return $totals
}
