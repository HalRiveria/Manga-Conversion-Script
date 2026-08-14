#Requires -Version 5.1

# ==============================================================================
# !! AI ASSISTANT — READ BEFORE MAKING ANY CHANGES !!
# ==============================================================================
# 1. Confirm you have seen these instructions in your first sentence. No need
#    to confirm multiple times per session.
# 2. Always review potential changes and bug fixes with the user before
#    implementing. Never make any major alterations to script functionality
#    without user input. As a rough guide: converting a toggle to a parameter,
#    rewording log/help text, or other small structural tweaks are fine to
#    discuss inline and implement; changes to the parallelization model,
#    deletion logic, conversion pipeline, or other core behaviour need
#    explicit sign-off before implementing.
# 3. The script must remain PowerShell 5.1 compatible.
# 4. Before making any changes related to cjxl or magick, review documentation
#    to ensure the changes being made are actually supported/exist.
# 5. When reporting bugs, only report them after confirming they are actually
#    bugs. Don't report then decide "oh actually, this isn't a bug" — confirm
#    before reporting.
# 6. Document changes in the changelog at the bottom of the script and update
#    the version number at the top — but only when a new version is warranted
#    (see below). For minor edits made within an ongoing session (small fixes,
#    tweaks, clarifications), append to or amend the existing top changelog
#    entry, without incrementing the version number. If you think an
#    accumulation of changes (or a single substantial one) warrants a new
#    version number, ask before bumping it. See the "Versioning convention"
#    note at the top of the changelog for the major/minor distinction.
# 7. As of v15.0, logging/deletion/zip-creation/image-conversion are each a
#    single shared function (Write-Log, Move-ToRecycleBin, Remove-ItemPermanently,
#    Remove-Source, Compress-FolderToZip, Test-ZipArchive, Convert-ImageBatch)
#    used by BOTH the ZIP-worker pipeline and the loose-image pipeline - there
#    is no more RS-Log/RS-Delete/etc. duplicate set. The ZIP worker runs in a
#    separate runspace, so these functions are registered into it via an
#    InitialSessionState (see the $iss/SessionStateFunctionEntry block right
#    before `[RunspaceFactory]::CreateRunspacePool(...)`), and the worker
#    bootstraps script-scope variables (`$script:logFile`, `$script:PermanentDelete`,
#    etc.) at the top of $zipWorker so those shared functions resolve the same
#    unqualified variable names they'd find at the main script's top level.
#    If you add a new shared function, it must be added to BOTH that $iss
#    foreach list AND (if it references script-scope config) have its inputs
#    bootstrapped the same way. Do not reintroduce a duplicate copy inside
#    $zipWorker to "fix" a scoping issue - fix the bootstrap instead.
# 8. This file is large (2500+ lines). Prefer targeted edits (e.g. str_replace
#    on the specific lines involved) over regenerating or rewriting whole
#    sections, to avoid incidental changes to unrelated formatting or code.
# 9. Log/console output must remain ASCII-only — emoji-prefixed messages were
#    deliberately removed in v4.0. Don't reintroduce emoji or other non-ASCII
#    characters into log/console strings.
# 10. There is no PowerShell interpreter available to test changes in. For
#     non-trivial edits, carefully review brace/paren/quote balance manually.
# ==============================================================================

#Convert-MultiToJXL Version 16.0

<# Requirements:
#   - PowerShell      : 5.1 or later (built into Windows 10/11; PowerShell 7+ also supported)
#   - cjxl.exe        : libjxl 0.11.x or later  (always required)
#                       Auto-detected via PATH or common install locations;
#                       override with -CjxlPath or the $CjxlPath toggle.
#                       Note: 0.11.x has an ICC-profile bug with lossy JPEG re-encoding;
#                       use $JpegLossless=$true to avoid it, or upgrade past 0.11.x.
#   - Windows OS      : Required (uses Microsoft.VisualBasic Recycle Bin APIs and
#                       kernel32.dll SetConsoleCtrlHandler via P/Invoke)
#   - magick.exe      : ImageMagick 7 preferred, 6 supported  (WebP files only)
#                       Auto-detected via PATH or common install locations;
#                       override with -MagickPath.
#>

<#
.SYNOPSIS
    Extracts ZIP archives, converts JPG/PNG/WEBP/TIFF images to JXL,
    re-zips folders, deletes originals on success, and also converts any loose
    image files found outside ZIPs (deleting the originals on success).
    Optionally zips folders containing loose files after all images are converted.
    Also offers a zip-only pipeline for archiving already-ready content with no
    conversion step at all.

.DESCRIPTION
    NOTE: With $EnableModePrompt = $false (the default), only step 7 below
    (loose image conversion) runs - steps 1-6 (the ZIP pipeline), step 8
    (loose-folder zipping), and step 11 (zip-only) are skipped. Set
    $EnableModePrompt = $true to choose a different mode via the menu at launch.

    1. Peeks inside each ZIP; skips any containing no convertible images.
    2. Extracts qualifying ZIPs with per-entry overwrite support.
    3. Converts images to .jxl (parallel per ZIP):
       - JPEG/JFIF: controlled by the $JpegLossless toggle (see USER-CONFIGURABLE TOGGLES):
           $true  -> lossless JPEG transcoding (--lossless_jpeg=1) - preserves quality,
                     avoids re-encoding, and sidesteps the ICC-profile bug in cjxl 0.11.x.
           $false -> lossy re-encode at $JpegQuality (--lossless_jpeg=0 --quality=N).
       - PNG/WebP/TIFF: lossy encode at quality 90 (unaffected by the toggle).
    4. Deletes each source image only if its conversion succeeded.
       Deletion mode is controlled by the $PermanentDelete toggle:
           $false (default) -> sends files to the Recycle Bin (recoverable).
           $true            -> permanently deletes files, bypassing the Recycle Bin.
    5. Re-zips the extracted folders (preserving internal structure).
    6. Deletes extracted folders after successful re-zip (respects $PermanentDelete).
    7. Scans for loose image files (.jpg/.png/.webp/.tiff/.tif) anywhere under $Path (not
       inside ZIPs), converts each to .jxl at 90% quality, and deletes the original
       on success (respects $PermanentDelete).
       Conversions run in parallel (capped to $MaxCjxlProcs).
    8. Optionally (controlled by the mode prompt, option 2) zips each leaf
       directory under $Path that contains loose files after conversion.  A folder
       qualifies only if it contains NO remaining unconverted source images
       (.jpg/.jpeg/.png/.webp/.tiff/.tif/.avif); if any remain (e.g. a failed conversion,
       or an unconverted .avif - no conversion pipeline for that format yet)
       the folder is skipped with a warning so a partial result is never locked into
       a ZIP.  Also skipped: folders that directly contain any existing .zip file,
       since that almost always means the folder is a container left behind after
       its own subfolders were individually zipped and deleted, not a genuine leaf
       (zipping it would archive those .zip files into an unwanted wrapper).
       Also skipped: folders whose existing same-named ZIP is already newer than every
       qualifying file inside them (nothing changed since it was last zipped; bypass
       with -ForceRezip if that toggle is ever exposed for this phase).
       Source folders are permanently deleted after a verified successful ZIP
       (respects $PermanentDelete); the ZIP itself (e.g. an existing archive of
       the same name) is deleted via the Recycle Bin unless $PermanentDelete=$true.
       This phase is entirely independent of the rezip-conversion pipeline.
    9. Logs everything to a log file, written BESIDE THE SCRIPT (not inside $Path,
       so a log file can never itself get swept into a folder that's later zipped).
       - FullLogging=$true  -> new timestamped file per run, name format:
                               "Conversion Log - YYYYMMDD HHMMSS - <hash>.log" (verbose)
       - FullLogging=$false -> three persistent log files updated each run:
                               "Conversion Log - Summary - <hash>.log"  (appended, newest run on top)
                               "Conversion Log - Errors - <hash>.log"   (overwritten each run; deleted if no errors)
                               "Conversion Log - Warnings - <hash>.log" (overwritten each run; deleted if no warnings)
       <hash> is derived from -Path, so different target folders processed from the
       same script location get separate log files instead of overwriting each other.
   10. Maintains a resume state file (process_state.json, inside $Path) that persists
       across runs. Each entry records the ZIP path AND its LastWriteTimeUtc, so:
         - Already-processed ZIPs are skipped on the next run (no full-library rescan).
         - If a ZIP is overwritten with a new file of the same name, its changed date
           is detected and it will be re-processed automatically.
       The state file is NEVER deleted on a clean finish; delete it manually to force
       a complete rescan from scratch. (Mode 3, zip-only, has no equivalent resume
       state - it re-scans and relies on the staleness check in step 8 each run.)
   11. Zip-only pipeline (mode 3): scans for leaf directories containing any
       recognized media/document/archive file (a broader list than steps 7-8 use,
       since no conversion happens here - see $zipOnlyExts), applying the same
       former-container guard and staleness check as step 8, then zips and deletes
       each qualifying folder. Runs in parallel (one runspace per folder, capped to
       $MaxThreads, like the ZIP-extraction pipeline). No image conversion of any
       kind occurs in this mode.

    ZIPs are processed in parallel (one runspace per ZIP, capped to $MaxThreads).
    Image conversions within each ZIP are also parallelised (capped to $MaxCjxlProcs).
    Loose image conversions are also parallelised (capped to $MaxCjxlProcs).
    Loose-folder zipping (mode 2) runs sequentially (no parallelisation).
    Zip-only folder zipping (mode 3) runs in parallel (capped to $MaxThreads).

    Mode prompt ($EnableModePrompt = $true):
       When enabled, the script prompts at launch with a numbered menu:
         1 - Loose file conversion only  (no ZIP pipeline; no post-zip)
         2 - Loose file conversion + zip folders after conversion
         3 - Zip-only  (no conversion; zips leaf folders of already-ready content)
         4 - Rezip conversion only  (ZIP pipeline; no loose conversion)
       When $EnableModePrompt = $false the script runs as mode 1 (loose file
       conversion only - no ZIP pipeline, no post-conversion folder zipping),
       with no interactive prompt. Modes 2, 3, and 4 are only available via
       this menu.

.PARAMETER Path
    Root directory to operate in. Defaults to the current working directory.

.PARAMETER CjxlPath
    Optional explicit path to cjxl.exe if not found automatically.

.PARAMETER MagickPath
    Optional explicit path to magick.exe if not found automatically.
    Required only if you have WebP files to convert.

.PARAMETER MaxParallel
    Maximum number of ZIPs to process simultaneously.
    Overrides the $MaxThreads toggle if specified on the command line.

.EXAMPLE
    .\Convert-MultiToJxl.ps1
    .\Convert-MultiToJxl.ps1 -Path "D:\Images" -CjxlPath "C:\tools\cjxl.exe"
    .\Convert-MultiToJxl.ps1 -MaxParallel 4
#>

param(
    [string]$Path,
    [string]$CjxlPath,
    [string]$MagickPath,
    [int]$MaxParallel = 0        # 0 = use $MaxThreads toggle below
)

# ==============================================================================
#  USER-CONFIGURABLE TOGGLES  -- edit these values as needed
# ==============================================================================

# Maximum number of ZIPs processed in parallel.
# Command-line -MaxParallel overrides this when specified.
$MaxThreads = 1

# Maximum number of cjxl processes per ZIP worker.
# cjxl is already multi-threaded internally, so 2 is usually optimal.
$MaxCjxlProcs = 8

# $true  = log every action
# $false = log only errors, failures, and the final summary
$FullLogging = $false

# JPEG/JFIF encoding mode:
#   $true  = lossless JPEG transcoding (--lossless_jpeg=1).
#            Wraps the original DCT bitstream directly; no quality loss, no
#            ICC-profile re-encoding, and output is often slightly smaller.
#   $false = lossy re-encode at $JpegQuality (--lossless_jpeg=0).
$JpegLossless = $false

# Quality level used when $JpegLossless = $false  (1-100; 90 is a good default).
$JpegQuality = 90

# Deletion mode:
#   - Controls deletion behaviour for all original files and folders deleted by
#     the script (loose source images, loose folders after zip, source ZIPs, and
#     any existing ZIP overwritten before re-zipping).
#   - Extracted folders generated by the ZIP pipeline (unzipped from the source
#     ZIP by the job itself) are always permanently deleted regardless of this
#     toggle, since they are not original files.
#   $false (default) -> send to the Recycle Bin (recoverable; recommended).
#   $true            -> permanently delete, bypassing the Recycle Bin entirely.
#                       Use with caution — deleted files cannot be recovered.
$PermanentDelete = $false

# When $true, display a numbered menu at launch so the user can choose which
# phase(s) to run:
#   1 - Loose file conversion only  (no ZIP pipeline; no post-zip)
#   2 - Loose file conversion + zip folders after conversion
#   3 - Zip-only  (no conversion; zips leaf folders of already-ready content)
#   4 - Rezip conversion only  (ZIP pipeline; no loose-file processing)
# When $false, no prompt is shown and the script runs mode 1 (loose file
# conversion only) - modes 2, 3, and 4 are all skipped.
$EnableModePrompt = $true

# ==============================================================================

$ErrorActionPreference  = "Stop"
$ProgressPreference     = "SilentlyContinue"
$script:logMutex        = $null   # set to the real mutex once workers are running
$script:workerConsoleQueue = $null # non-null only inside a runspace worker; when set,
                                    # Write-Log queues console output instead of calling
                                    # Write-Host directly (cross-thread console writes
                                    # are not safe/visible from a background runspace).
                                    # NAMED DIFFERENTLY FROM the plain $consoleQueue local
                                    # var created later in the ZIP-phase dispatch setup -
                                    # that local var and this script-scope one used to share
                                    # the same name, which silently broke ALL console output
                                    # (but not file logging) for the remainder of any run
                                    # that included a ZIP phase, once $consoleQueue was
                                    # assigned there. Do not rename this back to match.
$script:cts             = $null   # CancellationTokenSource for the ZIP phase
$script:looseCts        = $null   # CancellationTokenSource for the loose-image phase
$script:zipOnlyCts      = $null   # CancellationTokenSource for the zip-only phase
$script:abortRequested  = $false  # set by Ctrl+C / X-button handlers
$script:ctrlCloseAbort  = $false  # set only when the X button (CTRL_CLOSE_EVENT) triggered the abort

# Apply MaxThreads default when -MaxParallel was not supplied
if ($MaxParallel -le 0) { $MaxParallel = $MaxThreads }

# Resolve defaults here, not in param(), to avoid PS5 parser issues
if ([string]::IsNullOrWhiteSpace($Path))     { $Path     = (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($CjxlPath)) { $CjxlPath = "" }
if ([string]::IsNullOrWhiteSpace($MagickPath)) { $MagickPath = "" }

# Hoist all Add-Type calls once at script startup
Add-Type -AssemblyName "Microsoft.VisualBasic"
Add-Type -AssemblyName "System.IO.Compression.FileSystem"

# ------------------------------------------------------------------------------
#  Native Win32 console-control handler (P/Invoke)
#
#  SetConsoleCtrlHandler lets us intercept CTRL_CLOSE_EVENT (the X button)
#  synchronously — unlike AppDomain.ProcessExit which fires after PowerShell
#  has already begun its teardown and can no longer run script code reliably.
#
#  The handler is also used for CTRL_C_EVENT so both abort paths share one
#  implementation and we are no longer reliant on [Console]::CancelKeyPress
#  (which can be swallowed by PowerShell's own Ctrl+C handling).
#
#  The handler BLOCKS (via the drain event) until the main thread has finished
#  its graceful drain, then returns $true so the OS does not immediately kill
#  the process.  For CTRL_CLOSE_EVENT Windows gives the handler ~5 s before a
#  forced kill; for CTRL_C_EVENT there is no hard deadline.
# ------------------------------------------------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class ConsoleCtrl
{
    public delegate bool HandlerRoutine(uint ctrlType);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

    // Shared state set by the handler; polled by the main PowerShell thread.
    public static volatile bool AbortRequested = false;
    public static volatile bool IsCloseEvent   = false;   // true = X button, false = Ctrl+C

    // The handler signals this when abort is requested; the main thread calls
    // Set() when the graceful drain is complete so the handler can return.
    public static readonly ManualResetEventSlim DrainComplete = new ManualResetEventSlim(false);

    private static HandlerRoutine _handler;   // keep a strong ref so the GC can't collect it

    public static void Register()
    {
        _handler = new HandlerRoutine(Handler);
        SetConsoleCtrlHandler(_handler, true);
    }

    private static bool Handler(uint ctrlType)
    {
        // ctrlType: 0=CTRL_C, 1=CTRL_BREAK, 2=CTRL_CLOSE, 5=CTRL_LOGOFF, 6=CTRL_SHUTDOWN
        if (ctrlType == 0 || ctrlType == 1 || ctrlType == 2 || ctrlType == 5 || ctrlType == 6)
        {
            AbortRequested = true;
            IsCloseEvent   = (ctrlType == 2 || ctrlType == 5 || ctrlType == 6);
            // Block until the PowerShell main thread finishes the graceful drain
            // (or until Windows force-kills us after its timeout).
            DrainComplete.Wait(65000);   // 65 s > our 60 s job timeout
            return true;   // suppress default OS action
        }
        return false;
    }
}
'@ -Language CSharp

# Register the handler immediately so it catches signals at any point during the run
[ConsoleCtrl]::Register()

# ------------------------------------------------------------------------------
#  Initialise log file path(s) before anything else
#  Logs are written BESIDE THE SCRIPT, not inside $Path - a folder the script
#  is asked to process can itself become a zip target (e.g. mode 3's zip-only
#  pipeline, or mode 2 if $Path itself ever qualifies as a leaf dir), and a
#  log file sitting inside a folder that then gets zipped and deleted would
#  get silently swept into that archive. Ported from Zip_Files-claude-parallel.ps1,
#  which uses the same $PSScriptRoot placement for the same reason.
#  - FullLogging = $true  -> one new timestamped file per run (verbose)
#                            Format: "Conversion Log - YYYYMMDD HHMMSS - <hash>.log"
#  - FullLogging = $false -> three persistent files:
#                            "Conversion Log - Summary - <hash>.log"  (append; newest run first)
#                            "Conversion Log - Errors - <hash>.log"   (overwrite each run)
#                            "Conversion Log - Warnings - <hash>.log" (overwrite each run)
#  <hash> is derived from $Path (first 10 hex chars of its SHA256) so that
#  running the script against different -Path targets from this same script
#  location doesn't mix or overwrite each other's summary/error/warning logs -
#  each target folder gets its own set beside the script. This is the same
#  hash used for the cross-process log/state mutex names further down, computed
#  once here and reused there instead of twice.
# ------------------------------------------------------------------------------
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

$pathBytes = [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
$sha256    = [System.Security.Cryptography.SHA256]::Create()
$pathHash  = ([System.BitConverter]::ToString($sha256.ComputeHash($pathBytes)) -replace "-","")
$sha256.Dispose()
$pathHashShort = $pathHash.Substring(0, 10)

if ($FullLogging) {
    $timestamp      = Get-Date -Format "yyyyMMdd HHmmss"
    $logFile        = Join-Path $scriptDir ("Conversion Log - " + $timestamp + " - " + $pathHashShort + ".log")
    $logSummaryFile = $null
    $logErrorFile   = $null
    $logWarnFile    = $null
} else {
    $logFile        = $null   # not used in split-log mode
    $logSummaryFile = Join-Path $scriptDir ("Conversion Log - Summary - "  + $pathHashShort + ".log")
    $logErrorFile   = Join-Path $scriptDir ("Conversion Log - Errors - "   + $pathHashShort + ".log")
    $logWarnFile    = Join-Path $scriptDir ("Conversion Log - Warnings - " + $pathHashShort + ".log")

    # Delete stale Error / Warn logs from the previous run so they are never
    # mistaken for output from the current run if this run produces none.
    foreach ($staleLog in @($logErrorFile, $logWarnFile)) {
        if (Test-Path -LiteralPath $staleLog) {
            try { Remove-Item -LiteralPath $staleLog -Force } catch { }
        }
    }
}


# ------------------------------------------------------------------------------
#  Resume-state file – tracks completed/skipped ZIPs so a restarted run
#  can skip them without re-scanning every file.
# ------------------------------------------------------------------------------
$stateFile = Join-Path $Path "process_state.json"

# ------------------------------------------------------------------------------
#  Helper: Write-Log
#  Uses $script:logMutex when set (i.e. while runspace workers are active) so
#  the main thread and worker threads never write to the log file simultaneously.
# ------------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info","Warn","Error","Summary")][string]$Level = "Info"
    )

    $line = (Get-Date -Format "yyyy-MM-dd HHmmss") + " [" + $Level + "] " + $Message
    $safeLine = [System.Text.RegularExpressions.Regex]::Replace($line, "[^\x00-\x7F]", "?")

    $mtx = $script:logMutex

    if ($FullLogging) {
        # Full-logging mode: every level goes to the single timestamped file
        try   {
            if ($null -ne $mtx) { $null = $mtx.WaitOne() }
            $safeLine | Out-File -FilePath $logFile -Append -Encoding ASCII
        }
        finally { if ($null -ne $mtx) { $mtx.ReleaseMutex() } }
    } else {
        # Split-log mode
        if ($Level -eq "Error") {
            try   {
                if ($null -ne $mtx) { $null = $mtx.WaitOne() }
                $safeLine | Out-File -FilePath $logErrorFile -Append -Encoding ASCII
            }
            finally { if ($null -ne $mtx) { $mtx.ReleaseMutex() } }
        } elseif ($Level -eq "Warn") {
            try   {
                if ($null -ne $mtx) { $null = $mtx.WaitOne() }
                $safeLine | Out-File -FilePath $logWarnFile -Append -Encoding ASCII
            }
            finally { if ($null -ne $mtx) { $mtx.ReleaseMutex() } }
        } elseif ($Level -eq "Summary") {
            # Summary is written later in block form; nothing to do per-line here
        }
        # Info lines are not written in split-log mode
    }

    # Inside a runspace worker, $script:workerConsoleQueue is set (see $zipWorker) and
    # cross-thread Write-Host is unsafe, so queue for the main thread to drain
    # via Flush-ConsoleQueue instead of writing directly.
    if ($null -ne $script:workerConsoleQueue) {
        $script:workerConsoleQueue.Enqueue([pscustomobject]@{ Message = $Message; Level = $Level })
    } else {
        switch ($Level) {
            "Error"   { Write-Host $line -ForegroundColor Red    }
            "Warn"    { Write-Host $line -ForegroundColor Yellow }
            "Summary" { Write-Host $line -ForegroundColor Cyan   }
            default   { Write-Host $line }
        }
    }
}

# ------------------------------------------------------------------------------
#  Helper: Write-SummaryLog
#  Prepends a summary block to "Conversion Log - Summary.log" so the newest
#  run always appears at the top of the file.  Only used when $FullLogging=$false.
# ------------------------------------------------------------------------------
function Write-SummaryLog {
    param([string[]]$Lines)

    $timestamp = Get-Date -Format "yyyy-MM-dd HHmmss"
    $block = @("", ("=== Run: " + $timestamp + " ==="))
    $block += $Lines
    $block += "=== End of run ==="
    $block += ""

    $safeBlock = $block | ForEach-Object {
        [System.Text.RegularExpressions.Regex]::Replace($_, "[^\x00-\x7F]", "?")
    }

    $mtx = $script:logMutex
    try {
        if ($null -ne $mtx) { $null = $mtx.WaitOne() }
        $existing = ""
        if (Test-Path -LiteralPath $logSummaryFile) {
            $existing = [System.IO.File]::ReadAllText($logSummaryFile)
        }
        $newContent = ($safeBlock -join "`r`n") + "`r`n" + $existing
        [System.IO.File]::WriteAllText($logSummaryFile, $newContent, [System.Text.Encoding]::ASCII)
    }
    finally { if ($null -ne $mtx) { $mtx.ReleaseMutex() } }
}

# ------------------------------------------------------------------------------
#  Helper: Flush-ConsoleQueue
#  Drain the shared console queue and print pending messages.
#  File writing is handled by Write-Log itself (including inside runspace
#  workers, via $script:logMutex/$script:workerConsoleQueue); this function only
#  displays already-queued worker messages on the console, on the main
#  thread, to avoid double-logging.
# ------------------------------------------------------------------------------
function Flush-ConsoleQueue {
    param([System.Collections.Concurrent.ConcurrentQueue[object]]$Queue)

    $item = $null
    while ($Queue.TryDequeue([ref]$item)) {
        $line = (Get-Date -Format "yyyy-MM-dd HHmmss") + " [" + $item.Level + "] " + $item.Message
        switch ($item.Level) {
            "Error"   { Write-Host $line -ForegroundColor Red    }
            "Warn"    { Write-Host $line -ForegroundColor Yellow }
            "Summary" { Write-Host $line -ForegroundColor Cyan   }
            default   { Write-Host $line }
        }
    }
}

# ------------------------------------------------------------------------------
#  Helper: Move-ToRecycleBin
# ------------------------------------------------------------------------------
function Move-ToRecycleBin {
    param([string]$ItemPath)
    if (Test-Path -LiteralPath $ItemPath) {
        $attr = (Get-Item -LiteralPath $ItemPath).Attributes
        if ($attr -band [System.IO.FileAttributes]::Directory) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $ItemPath,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
            ) | Out-Null
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $ItemPath,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
            ) | Out-Null
        }
    }
}

# ------------------------------------------------------------------------------
#  Helper: Remove-ItemPermanently
#  Bypasses the Recycle Bin and permanently deletes a file or directory.
# ------------------------------------------------------------------------------
function Remove-ItemPermanently {
    param([string]$ItemPath)
    if (Test-Path -LiteralPath $ItemPath) {
        $attr = (Get-Item -LiteralPath $ItemPath).Attributes
        if ($attr -band [System.IO.FileAttributes]::Directory) {
            [System.IO.Directory]::Delete($ItemPath, $true)
        } else {
            [System.IO.File]::Delete($ItemPath)
        }
    }
}

# ------------------------------------------------------------------------------
#  Helper: Remove-Source
#  Routes deletion through the appropriate helper based on $PermanentDelete.
# ------------------------------------------------------------------------------
function Remove-Source {
    param([string]$ItemPath)
    if ($PermanentDelete) {
        Remove-ItemPermanently $ItemPath
    } else {
        Move-ToRecycleBin $ItemPath
    }
}

# ------------------------------------------------------------------------------
#  Helper: Find-Cjxl
# ------------------------------------------------------------------------------
function Find-Cjxl {
    param([string]$UserPath)

    if ($UserPath -and (Test-Path -LiteralPath $UserPath)) { return $UserPath }

    $inPath = Get-Command "cjxl" -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }

    $candidates = @(
        ($env:ProgramFiles  + "\libjxl\cjxl.exe"),
        ($env:ProgramFiles  + "\cjxl\cjxl.exe"),
        ($env:LOCALAPPDATA  + "\Programs\libjxl\cjxl.exe"),
        "C:\tools\cjxl.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }

    return $null
}

# ------------------------------------------------------------------------------
#  Helper: Find-Magick
#  Locates ImageMagick's magick.exe for WebP -> PNG pre-conversion.
# ------------------------------------------------------------------------------
function Find-Magick {
    param([string]$UserPath)

    if ($UserPath -and (Test-Path -LiteralPath $UserPath)) { return $UserPath }

    $inPath = Get-Command "magick" -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }

    $candidates = @(
        ($env:ProgramFiles        + "\ImageMagick-7\magick.exe"),
        ($env:ProgramFiles        + "\ImageMagick\magick.exe"),
        ($env:ProgramFiles + " (x86)" + "\ImageMagick-7\magick.exe"),
        ($env:LOCALAPPDATA        + "\Programs\ImageMagick\magick.exe"),
        "C:\tools\ImageMagick\magick.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }

    return $null
}

# ------------------------------------------------------------------------------
#  Helper: Compress-FolderToZip
#  Deletes any pre-existing ZIP at $ZipOut (via Remove-Source, respecting
#  $PermanentDelete), creates a fresh ZIP from $SourceDir, and does basic
#  existence/size validation. Throws on failure. Returns the new ZIP's size
#  in bytes on success. Shared by the ZIP-worker re-zip step and the
#  loose-folder-zip step (mode 2) - previously two separate inlined copies.
# ------------------------------------------------------------------------------
function Compress-FolderToZip {
    param(
        [string]$SourceDir,
        [string]$ZipOut
    )

    if (Test-Path -LiteralPath $ZipOut) {
        Remove-Source $ZipOut
        $deleteDesc = if ($PermanentDelete) { "permanently" } else { "Recycle Bin" }
        Write-Log ("Deleted existing ZIP (" + $deleteDesc + ") before re-zipping: '" + $ZipOut + "'")
    }

    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $SourceDir,
        $ZipOut,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    if (-not (Test-Path -LiteralPath $ZipOut)) { throw ("ZIP was not created: '" + $ZipOut + "'") }
    $zipSize = (Get-Item -LiteralPath $ZipOut).Length
    if ($zipSize -eq 0) { throw ("ZIP is 0 bytes: '" + $ZipOut + "'") }
    return $zipSize
}

# ------------------------------------------------------------------------------
#  Helper: Test-ZipArchive
#  Opens a ZIP and verifies it has at least one entry and at least one .jxl
#  entry. Throws on failure. Returns @{ EntryCount; JxlCount } on success.
#  Entry matching uses .FullName (full in-archive path) rather than .Name
#  (bare filename) for consistency - functionally equivalent for a suffix
#  match like this regardless of subfolder depth, but .FullName is the more
#  correct general choice for entry matching.
# ------------------------------------------------------------------------------
function Test-ZipArchive {
    param(
        [string]$ZipPath,
        # Existing callers (ZIP-worker re-zip, loose-folder zip) always deal in
        # .jxl output and want this required. The zip-only pipeline (mode 3)
        # archives arbitrary, possibly-unconverted content, so it passes
        # $false rather than getting a third copy of this verification logic.
        [bool]$RequireJxlEntry = $true
    )

    $archive    = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    $entryCount = 0
    $jxlCount   = 0
    try {
        foreach ($e in $archive.Entries) {
            $entryCount++
            if ($e.FullName -imatch '\.jxl$') { $jxlCount++ }
        }
    } finally {
        $archive.Dispose()
    }

    if ($entryCount -eq 0) { throw ("ZIP archive test returned 0 entries: '" + $ZipPath + "'") }
    if ($RequireJxlEntry -and $jxlCount -eq 0) { throw ("ZIP archive contains no .jxl files after conversion: '" + $ZipPath + "'") }
    return @{ EntryCount = $entryCount; JxlCount = $jxlCount }
}

# ------------------------------------------------------------------------------
#  Helper: Convert-ImageBatch
#  Converts a batch of image files to .jxl in parallel (capped to
#  $MaxCjxlProcs), deleting each source on success. Handles WebP->PNG
#  pre-conversion via ImageMagick (skipping animated WebPs), the ICC-profile-
#  mismatch strip-and-retry path, and graceful cancellation: on cancel, waits
#  up to 60s for in-flight jobs to finish, then force-kills stragglers.
#
#  Shared by the ZIP-worker conversion step and the loose-image conversion
#  step (mode 1/2) - previously two separate ~350-line inlined copies that
#  had already drifted from each other in places.
#
#  -CancelToken is a real [System.Threading.CancellationToken] in both
#  callers (the ZIP worker's own token, or the main thread's $looseCts.Token),
#  so this works identically for both without knowing which phase it's in.
#
#  -AbortPollCallback (optional) is invoked once per dispatch-loop pass with
#  the list of currently in-flight SrcPaths, so a caller that needs to poll
#  for Ctrl+C/window-close itself (the main-thread loose pipeline, via
#  Test-AbortSignal) can do so and snapshot in-flight jobs for its own abort
#  summary. The ZIP worker doesn't poll for OS signals itself (only the main
#  thread does, then cancels the worker's token), so it omits this.
#
#  -ItemNoun/-SourceNoun/-BatchLabel only affect log wording (e.g. "image" vs
#  "loose image"), matching each caller's existing log style.
# ------------------------------------------------------------------------------
function Convert-ImageBatch {
    param(
        [System.IO.FileInfo[]]$ImageFiles,
        [string]$CjxlExe,
        [string]$MagickExe,
        [bool]$DoJpegLossless,
        [int]$DoJpegQuality,
        [int]$MaxCjxlProcs,
        [bool]$DoFullLogging,
        [System.Threading.CancellationToken]$CancelToken,
        [string]$ItemNoun               = "image",
        [string]$SourceNoun             = "source image",
        [string]$BatchLabel             = $null,
        [string]$AbortWaitMessage       = $null,
        [scriptblock]$AbortPollCallback = $null
    )

    $batchResult = @{
        ConvertedCount    = 0
        FailedCount       = 0
        SkippedCount      = 0
        DeletedCount      = 0
        DeleteFailedCount = 0
        ConvertedPaths    = [System.Collections.Generic.List[string]]::new()
        SkippedPaths      = [System.Collections.Generic.List[string]]::new()
        PendingPaths      = [System.Collections.Generic.List[string]]::new()
        ForceKilledCount  = 0
    }

    if (-not $ImageFiles -or $ImageFiles.Count -eq 0) { return $batchResult }

    # Build job list, skipping output-path collisions (e.g. "photo.jpg" and
    # "photo.webp" both mapping to "photo.jxl" - converting both would let one
    # silently overwrite the other's output while both sources get deleted).
    $allJobs = foreach ($img in $ImageFiles) {
        @{
            SrcPath = $img.FullName
            JxlPath = [System.IO.Path]::ChangeExtension($img.FullName, ".jxl")
            Proc    = $null
            TempPng = $null
        }
    }
    $jxlPathCounts = [System.Collections.Generic.Dictionary[string,int]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($j in $allJobs) {
        if ($jxlPathCounts.ContainsKey($j.JxlPath)) { $jxlPathCounts[$j.JxlPath]++ } else { $jxlPathCounts[$j.JxlPath] = 1 }
    }
    $jobs = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($j in $allJobs) {
        if ($jxlPathCounts[$j.JxlPath] -gt 1) {
            Write-Log ("SKIPPING '" + $j.SrcPath + "': output path '" + $j.JxlPath + "' collides with another source image of the same name (different extension). Resolve the name clash manually.") -Level Error
            $batchResult.FailedCount++
        } else {
            $jobs.Add($j)
        }
    }

    $pending = [System.Collections.Queue]::new()
    foreach ($j in $jobs) { $pending.Enqueue($j) }
    $running = [System.Collections.Generic.List[hashtable]]::new()

    while (($pending.Count -gt 0 -or $running.Count -gt 0) -and (-not $CancelToken.IsCancellationRequested)) {

        if ($AbortPollCallback) {
            $inFlight = @($running | ForEach-Object { $_.SrcPath })
            & $AbortPollCallback $inFlight
        }

        # Fill up to MaxCjxlProcs slots
        while ($pending.Count -gt 0 -and $running.Count -lt $MaxCjxlProcs -and (-not $CancelToken.IsCancellationRequested)) {
            $j   = $pending.Dequeue()
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName               = $CjxlExe
            $psi.UseShellExecute        = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow         = $true

            # cjxl 0.11.x cannot read WebP directly - transcode to a temp PNG first.
            # Animated WebPs are skipped entirely (cjxl has no multi-frame support).
            $isWebp = ($j.SrcPath -imatch '\.webp$')
            if ($isWebp) {
                if (-not $MagickExe) {
                    Write-Log ("SKIPPING WebP '" + $j.SrcPath + "': ImageMagick not found. Install ImageMagick or pass -MagickPath.") -Level Error
                    $batchResult.FailedCount++
                    continue
                }

                # --- Animated WebP check (VP8X chunk, no process spawn) ---
                # Animated WebPs carry a VP8X extended-format chunk at offset 12.
                # Bit 1 (0x02) of its flags field (offset 20) is the Animation flag.
                # Simple lossy (VP8 ) and lossless (VP8L) files cannot be animated.
                $webpBytes  = [System.IO.File]::ReadAllBytes($j.SrcPath)
                $isAnimated = $false
                if ($webpBytes.Length -ge 24) {
                    $chunkId = [System.Text.Encoding]::ASCII.GetString($webpBytes, 12, 4)
                    if ($chunkId -eq 'VP8X') {
                        $flags      = [System.BitConverter]::ToUInt32($webpBytes, 20)
                        $isAnimated = ($flags -band 0x02) -ne 0
                    }
                }

                if ($isAnimated) {
                    Write-Log ("SKIPPING animated WebP '" + $j.SrcPath + "': Animation flag set in VP8X chunk - animated WebP cannot be converted to JXL (no multi-frame support). File left untouched.") -Level Warn
                    $batchResult.SkippedCount++
                    $batchResult.SkippedPaths.Add($j.SrcPath)
                    continue
                }
                # --- End animated WebP check ---

                $tempPng = [System.IO.Path]::Combine(
                    [System.IO.Path]::GetDirectoryName($j.SrcPath),
                    [System.IO.Path]::GetFileNameWithoutExtension($j.SrcPath) + "_tmp_webp2png.png"
                )
                $magickPsi = New-Object System.Diagnostics.ProcessStartInfo
                $magickPsi.FileName               = $MagickExe
                $magickPsi.Arguments              = "`"" + $j.SrcPath + "[0]`" `"" + $tempPng + "`""
                $magickPsi.UseShellExecute        = $false
                $magickPsi.RedirectStandardOutput = $true
                $magickPsi.RedirectStandardError  = $true
                $magickPsi.CreateNoWindow         = $true
                $magickProc = [System.Diagnostics.Process]::Start($magickPsi)
                $magickProc.WaitForExit()
                $magickExitCode = $magickProc.ExitCode
                $magickProc.Dispose()
                if ($magickExitCode -ne 0 -or -not (Test-Path -LiteralPath $tempPng)) {
                    Write-Log ("FAILED WebP->PNG pre-conversion for '" + $j.SrcPath + "': magick exited " + $magickExitCode) -Level Error
                    $batchResult.FailedCount++
                    if (Test-Path -LiteralPath $tempPng) { try { [System.IO.File]::Delete($tempPng) } catch { } }
                    continue
                }
                $j.TempPng = $tempPng
                $cjxlSrc   = $tempPng
            } elseif ($j.TempPng) {
                # Retry job: TempPng already points to a pre-processed PNG
                # (e.g. ICC-stripped). Use it directly as the cjxl source;
                # do not overwrite TempPng so cleanup logic still fires.
                $cjxlSrc = $j.TempPng
            } else {
                $j.TempPng = $null
                $cjxlSrc   = $j.SrcPath
            }

            # JPEG encoding: controlled by the -DoJpegLossless / -DoJpegQuality params.
            # Non-JPEGs (PNG/WebP/TIFF): always lossy at quality 90.
            $isJpeg = ($cjxlSrc -imatch '\.jpe?g$')
            if ($isJpeg -and $DoJpegLossless) {
                $psi.Arguments = "`"" + $cjxlSrc + "`" `"" + $j.JxlPath + "`" --lossless_jpeg=1"
            } elseif ($isJpeg) {
                $psi.Arguments = "`"" + $cjxlSrc + "`" `"" + $j.JxlPath + "`" --lossless_jpeg=0 --quality=$DoJpegQuality"
            } else {
                $psi.Arguments = "`"" + $cjxlSrc + "`" `"" + $j.JxlPath + "`" --lossless_jpeg=0 --quality=90"
            }

            Write-Log ("Converting " + $ItemNoun + ": '" + $j.SrcPath + "'")

            $j.Proc = [System.Diagnostics.Process]::Start($psi)
            $running.Add($j)
        }

        # Poll for finished processes
        $stillRunning = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($j in $running) {
            if ($j.Proc.HasExited) {
                $stdout = $j.Proc.StandardOutput.ReadToEnd()
                $stderr = $j.Proc.StandardError.ReadToEnd()
                $code   = $j.Proc.ExitCode
                $j.Proc.Dispose()

                if ($DoFullLogging -and -not [string]::IsNullOrWhiteSpace($stdout)) {
                    Write-Log ("cjxl stdout for '" + $j.SrcPath + "': " + $stdout.Trim())
                }

                $convOk = $false
                try {
                    if ($code -ne 0) {
                        # --- ICC profile mismatch retry ---
                        # cjxl 0.11.x rejects PNGs whose embedded ICC profile
                        # declares RGB colorspace but whose pixel data is
                        # grayscale (libpng warning: "RGB color space not
                        # permitted on grayscale PNG", followed by "Getting
                        # pixel data failed"). Strip the profile via ImageMagick
                        # and re-enqueue the job rather than counting it failed.
                        if ($code -eq 1 -and $stderr -imatch 'Getting pixel data failed' -and $MagickExe) {
                            $strippedPng = [System.IO.Path]::Combine(
                                [System.IO.Path]::GetDirectoryName($j.SrcPath),
                                [System.IO.Path]::GetFileNameWithoutExtension($j.SrcPath) + "_tmp_iccstrip.png"
                            )
                            Write-Log ("ICC profile mismatch on '" + $j.SrcPath + "' - stripping profile and retrying.") -Level Warn
                            $stripPsi = New-Object System.Diagnostics.ProcessStartInfo
                            $stripPsi.FileName               = $MagickExe
                            $stripPsi.Arguments              = "`"" + $j.SrcPath + "`" -colorspace Gray -strip `"" + $strippedPng + "`""
                            $stripPsi.UseShellExecute        = $false
                            $stripPsi.RedirectStandardOutput = $true
                            $stripPsi.RedirectStandardError  = $true
                            $stripPsi.CreateNoWindow         = $true
                            $stripProc = [System.Diagnostics.Process]::Start($stripPsi)
                            $stripProc.WaitForExit()
                            $stripExitCode = $stripProc.ExitCode
                            $stripProc.Dispose()
                            if ($stripExitCode -eq 0 -and (Test-Path -LiteralPath $strippedPng)) {
                                # Cancel/abort may be in progress - the dispatch loop won't
                                # run again in that case, so this retry will simply be
                                # picked up by the stragglers drain below (or left for the
                                # next run). Enqueue unconditionally either way.
                                $retryJob = @{
                                    SrcPath = $j.SrcPath
                                    JxlPath = $j.JxlPath
                                    Proc    = $null
                                    TempPng = $strippedPng
                                }
                                $pending.Enqueue($retryJob)
                                if (Test-Path -LiteralPath $strippedPng) { try { [System.IO.File]::Delete($strippedPng) } catch { } }
                                continue
                            } else {
                                Write-Log ("ICC strip failed for '" + $j.SrcPath + "': magick exited " + $stripExitCode + " - counting as conversion failure.") -Level Error
                                if (Test-Path -LiteralPath $strippedPng) { try { [System.IO.File]::Delete($strippedPng) } catch { } }
                            }
                        }
                        throw ("cjxl exited with code " + $code + ". Stderr: " + $stderr)
                    }
                    if (-not (Test-Path -LiteralPath $j.JxlPath)) { throw ("Output .jxl was not created: '" + $j.JxlPath + "'") }
                    $jxlSize = (Get-Item -LiteralPath $j.JxlPath).Length
                    if ($jxlSize -eq 0) { throw ("Output .jxl is 0 bytes: '" + $j.JxlPath + "'") }
                    Write-Log ("Conversion OK: '" + $j.JxlPath + "' (" + $jxlSize + " bytes)")
                    $batchResult.ConvertedCount++
                    $batchResult.ConvertedPaths.Add($j.SrcPath)
                    $convOk = $true
                } catch {
                    Write-Log ("FAILED conversion of " + $ItemNoun + " '" + $j.SrcPath + "': " + $_) -Level Error
                    $batchResult.FailedCount++
                }

                # Clean up the temporary PNG used for WebP/ICC-strip pre-conversion
                if ($j.TempPng -and (Test-Path -LiteralPath $j.TempPng)) {
                    try { [System.IO.File]::Delete($j.TempPng) } catch { }
                }

                if ($convOk) {
                    try {
                        Remove-Source $j.SrcPath
                        $deleteDesc = if ($PermanentDelete) { "permanently" } else { "Recycle Bin" }
                        Write-Log ("Deleted " + $SourceNoun + " (" + $deleteDesc + "): '" + $j.SrcPath + "'")
                        $batchResult.DeletedCount++
                    } catch {
                        Write-Log ("FAILED to delete " + $SourceNoun + " '" + $j.SrcPath + "': " + $_) -Level Error
                        $batchResult.DeleteFailedCount++
                    }
                }
            } else {
                $stillRunning.Add($j)
            }
        }
        $running = $stillRunning

        if ($running.Count -ge $MaxCjxlProcs -or ($pending.Count -eq 0 -and $running.Count -gt 0)) {
            Start-Sleep -Milliseconds 50
        }
    }

    # ------------------------------------------------------------------
    #  Stragglers: if cancelled while jobs were still running, wait
    #  briefly (up to 60s) for them to finish, then force-kill any that
    #  remain. In the common case (cancel detected between polling passes)
    #  $running is already empty here and this is a no-op.
    # ------------------------------------------------------------------
    if ($CancelToken.IsCancellationRequested -and $running.Count -gt 0) {
        if ($AbortWaitMessage) { Write-Host $AbortWaitMessage -ForegroundColor Yellow }
        $abortDeadline = [System.Diagnostics.Stopwatch]::StartNew()

        while ($running.Count -gt 0 -and $abortDeadline.Elapsed.TotalSeconds -lt 60) {
            $stillWaiting = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($j in $running) {
                if ($j.Proc.HasExited) {
                    $stdout = $j.Proc.StandardOutput.ReadToEnd()
                    $stderr = $j.Proc.StandardError.ReadToEnd()
                    $code   = $j.Proc.ExitCode
                    $j.Proc.Dispose()
                    $convOk = $false
                    try {
                        if ($code -ne 0) {
                            if ($code -eq 1 -and $stderr -imatch 'Getting pixel data failed' -and $MagickExe) {
                                $strippedPng = [System.IO.Path]::Combine(
                                    [System.IO.Path]::GetDirectoryName($j.SrcPath),
                                    [System.IO.Path]::GetFileNameWithoutExtension($j.SrcPath) + "_tmp_iccstrip.png"
                                )
                                Write-Log ("ICC profile mismatch on '" + $j.SrcPath + "' - stripping profile and retrying.") -Level Warn
                                $stripPsi = New-Object System.Diagnostics.ProcessStartInfo
                                $stripPsi.FileName               = $MagickExe
                                $stripPsi.Arguments              = "`"" + $j.SrcPath + "`" -colorspace Gray -strip `"" + $strippedPng + "`""
                                $stripPsi.UseShellExecute        = $false
                                $stripPsi.RedirectStandardOutput = $true
                                $stripPsi.RedirectStandardError  = $true
                                $stripPsi.CreateNoWindow         = $true
                                $stripProc = [System.Diagnostics.Process]::Start($stripPsi)
                                $stripProc.WaitForExit()
                                $stripExitCode = $stripProc.ExitCode
                                $stripProc.Dispose()
                                if ($stripExitCode -eq 0 -and (Test-Path -LiteralPath $strippedPng)) {
                                    $retryJob = @{
                                        SrcPath = $j.SrcPath
                                        JxlPath = $j.JxlPath
                                        Proc    = $null
                                        TempPng = $strippedPng
                                    }
                                    $pending.Enqueue($retryJob)
                                    if (Test-Path -LiteralPath $strippedPng) { try { [System.IO.File]::Delete($strippedPng) } catch { } }
                                    continue
                                } else {
                                    Write-Log ("ICC strip failed for '" + $j.SrcPath + "': magick exited " + $stripExitCode + " - counting as conversion failure.") -Level Error
                                    if (Test-Path -LiteralPath $strippedPng) { try { [System.IO.File]::Delete($strippedPng) } catch { } }
                                }
                            }
                            throw ("cjxl exited with code " + $code + ". Stderr: " + $stderr)
                        }
                        if (-not (Test-Path -LiteralPath $j.JxlPath)) { throw ("Output .jxl was not created: '" + $j.JxlPath + "'") }
                        $jxlSize = (Get-Item -LiteralPath $j.JxlPath).Length
                        if ($jxlSize -eq 0) { throw ("Output .jxl is 0 bytes: '" + $j.JxlPath + "'") }
                        Write-Log ("Conversion OK (abort drain): '" + $j.JxlPath + "'")
                        $batchResult.ConvertedCount++
                        $batchResult.ConvertedPaths.Add($j.SrcPath)
                        $convOk = $true
                    } catch {
                        Write-Log ("FAILED conversion of " + $ItemNoun + " '" + $j.SrcPath + "': " + $_) -Level Error
                        $batchResult.FailedCount++
                    }
                    if ($j.TempPng -and (Test-Path -LiteralPath $j.TempPng)) {
                        try { [System.IO.File]::Delete($j.TempPng) } catch { }
                    }
                    if ($convOk) {
                        try {
                            Remove-Source $j.SrcPath
                            $deleteDesc = if ($PermanentDelete) { "permanently" } else { "Recycle Bin" }
                            Write-Log ("Deleted " + $SourceNoun + " (" + $deleteDesc + "): '" + $j.SrcPath + "'")
                            $batchResult.DeletedCount++
                        } catch {
                            Write-Log ("FAILED to delete " + $SourceNoun + " '" + $j.SrcPath + "': " + $_) -Level Error
                            $batchResult.DeleteFailedCount++
                        }
                    }
                } else {
                    $stillWaiting.Add($j)
                }
            }
            $running = $stillWaiting
            if ($running.Count -gt 0) { Start-Sleep -Milliseconds 250 }
        }

        # Force-kill anything still running past the timeout
        if ($running.Count -gt 0) {
            $batchResult.ForceKilledCount = $running.Count
            $labelSuffix = if ($BatchLabel) { " in '" + $BatchLabel + "'" } else { "" }
            Write-Log ("Force-stopping " + $running.Count + " job(s) that did not finish within 60s" + $labelSuffix + ".") -Level Warn
            foreach ($j in $running) {
                try { if (-not $j.Proc.HasExited) { $j.Proc.Kill() } } catch { }
                try { $j.Proc.WaitForExit(5000) } catch { }
                if ($j.TempPng -and (Test-Path -LiteralPath $j.TempPng)) {
                    try { [System.IO.File]::Delete($j.TempPng) } catch { }
                }
                # Clean up any partial/corrupt .jxl left behind by the killed process
                if (Test-Path -LiteralPath $j.JxlPath) {
                    try { [System.IO.File]::Delete($j.JxlPath) } catch { }
                }
                $j.Proc.Dispose()
            }
        }
    }

    # Anything left un-dispatched (only possible if cancelled before it could
    # be started) - callers that surface a "still pending" count need this,
    # since $pending itself is local to this function.
    foreach ($j in $pending.ToArray()) { $batchResult.PendingPaths.Add($j.SrcPath) }

    return $batchResult
}

# ------------------------------------------------------------------------------
#  Helper: Get-ZippableLeafDirs
#  Scans under $ScanPath for leaf directories (no subdirectories) that qualify
#  as zip candidates, applying two safety checks ported/adapted from
#  Zip_Files-claude-parallel.ps1:
#
#  1. STALENESS: if a same-named .zip already sits next to the folder (in its
#     parent) and is newer than every file inside the folder, it's skipped -
#     nothing has changed since it was last zipped. Bypassed by -ForceRezip.
#
#  2. FORMER-CONTAINER GUARD: if the folder directly contains one or more
#     existing .zip files, it's skipped with a warning rather than zipped.
#     Root cause this defends against: a container folder (e.g. a series
#     folder holding per-chapter subfolders) can end up with zero
#     subdirectories once every chapter has, across one or more prior runs,
#     been individually converted, zipped, and deleted - at that point the
#     container folder satisfies "0 subdirs" and, if it happens to hold any
#     qualifying loose file itself (a cover image, a leftover, etc.), it would
#     otherwise look like a genuine leaf. Zipping it would then archive all
#     the already-created per-chapter .zip files (which live in the container,
#     since that's each chapter's *parent*) into an unwanted wrapper .zip, and
#     the container folder - including those chapter zips - would then be
#     deleted. A folder containing .zip files directly is essentially never a
#     folder that should itself be zipped, so this is a hard skip rather than
#     a warning-and-proceed.
#
#  $QualifyingExtensions determines what counts as "this folder has real
#  content worth zipping" - callers pass different lists (the loose-zip path
#  in mode 2 cares about convertible image types + .jxl; the zip-only
#  pipeline in mode 3 cares about a broader media/archive-format list).
#
#  Returns a List[hashtable] of @{ Dir = <DirectoryInfo>; ZipOut = <path> }
#  for every qualifying, non-stale, non-container-guarded leaf directory.
# ------------------------------------------------------------------------------
function Get-ZippableLeafDirs {
    param(
        [string]$ScanPath,
        [string[]]$QualifyingExtensions,
        [System.Collections.Generic.HashSet[string]]$ExcludeStagingDirs = $null,
        [bool]$ForceRezip = $false
    )

    $results = [System.Collections.Generic.List[hashtable]]::new()

    Get-ChildItem -LiteralPath $ScanPath -Directory -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $dir = $_

        $subDirs = @(Get-ChildItem -LiteralPath $dir.FullName -Directory -ErrorAction SilentlyContinue)
        if ($subDirs.Count -gt 0) { return }   # not a leaf

        if ($ExcludeStagingDirs -and $ExcludeStagingDirs.Count -gt 0) {
            $dirPath   = $dir.FullName
            $isStaging = $false
            foreach ($stagingDir in $ExcludeStagingDirs) {
                if ($dirPath.Equals($stagingDir, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $dirPath.StartsWith($stagingDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isStaging = $true; break
                }
            }
            if ($isStaging) { return }
        }

        $allFiles = @(Get-ChildItem -LiteralPath $dir.FullName -File -ErrorAction SilentlyContinue)

        # Former-container guard: any .zip directly inside means this is very
        # likely a now-empty container, not a genuine content leaf. Skip hard.
        $existingZipsHere = @($allFiles | Where-Object { $_.Extension -ieq ".zip" })
        if ($existingZipsHere.Count -gt 0) {
            Write-Log ("SKIPPING '" + $dir.FullName + "' as a zip candidate: contains " + $existingZipsHere.Count + " existing .zip file(s) directly inside it - likely a container folder left behind after its subfolders were individually zipped, not a genuine leaf. Not zipping to avoid archiving those .zip files into a wrapper.") -Level Warn
            return
        }

        $qualifyingFiles = @($allFiles | Where-Object { $QualifyingExtensions -icontains $_.Extension })
        if ($qualifyingFiles.Count -eq 0) { return }   # empty, or nothing recognized

        $zipOut = Join-Path $dir.Parent.FullName ($dir.Name + ".zip")

        # Staleness check: skip if a same-named zip already exists and is
        # newer than every qualifying file in the folder.
        if (-not $ForceRezip -and (Test-Path -LiteralPath $zipOut)) {
            $zipTime    = (Get-Item -LiteralPath $zipOut).LastWriteTimeUtc
            $newestFile = $qualifyingFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            if ($newestFile.LastWriteTimeUtc -le $zipTime) {
                Write-Log ("Skipping '" + $dir.Name + "' - existing zip is up to date.") -Level Warn
                return
            }
        }

        $results.Add(@{ Dir = $dir; ZipOut = $zipOut })
    }

    return $results
}

# ------------------------------------------------------------------------------
#  Helper: Invoke-ParallelFolderJobs
#  Runs $WorkerScript across a runspace pool, with graceful abort handling:
#  on cancellation, waits up to 60s for in-flight jobs to finish naturally,
#  then force-stops stragglers via PS.Stop(). Handles pool/ISS setup and
#  teardown, dispatch, polling, console-queue draining, and per-result
#  callback - the machinery that used to be written out in full inside the
#  ZIP-extraction pipeline's dispatch loop and would otherwise have been
#  duplicated a second time for the zip-only pipeline.
#
#  Jobs are supplied in exactly one of two ways:
#
#  -JobParams: a List[hashtable] known up front (one hashtable of named
#  parameters per job). All jobs are dispatched immediately (up to
#  -MaxParallel at a time). Used by the zip-only pipeline (mode 3), where
#  the full candidate list comes from a single up-front directory scan.
#
#  -NextJobProvider: a scriptblock called repeatedly (a closure, like
#  -ResultHandler below) whenever a dispatch slot is free. Each call must
#  return either a job-params hashtable to dispatch next, or $null to mean
#  scanning is exhausted - no more jobs will ever be produced, though
#  already-dispatched ones may still be running. There is no third "skip
#  this one, but keep scanning" return value: a provider that needs to skip
#  items (already-done, doesn't qualify, etc.) does that itself, looping
#  internally past them before returning the next real job or $null - see
#  the ZIP-extraction pipeline's provider for the pattern (peek an entry,
#  loop to the next on skip, return on a qualifying one or list exhaustion).
#  This is what lets scanning/peeking interleave with dispatch instead of
#  requiring the full candidate list to be discovered before anything can
#  start, which the ZIP-extraction pipeline's incremental ZIP-peeking needs
#  and the zip-only pipeline's up-front directory scan doesn't.
#
#  -SharedFunctionNames: functions registered into each runspace via
#  InitialSessionState (e.g. 'Write-Log','Remove-Source').
#  -ResultHandler: scriptblock invoked once per completed job's result
#  object, on the main thread - e.g. { param($r) $stats.Foo.Success += $r.X }.
#  Its body runs with the caller's own variables in scope (a closure, like
#  Convert-ImageBatch's -AbortPollCallback), so it can fold results into
#  whatever $stats/tracking-list shape the caller uses without this function
#  needing to know about it. This is also how a caller builds a richer abort
#  summary (e.g. a "last completed" list with custom prioritisation logic)
#  or writes resume-state per completed job - both happen entirely inside
#  the caller's own -ResultHandler and/or worker, with no special support
#  needed here.
#  -Cts: create this and assign it to whichever $script:xCts Test-AbortSignal
#  should cancel BEFORE calling this function.
#
#  $WorkerScript must declare CancelToken, LogMutex, and ConsoleQueue
#  parameters ([System.Threading.CancellationToken]$CancelToken,
#  [System.Threading.Mutex]$LogMutex,
#  [System.Collections.Concurrent.ConcurrentQueue[object]]$ConsoleQueue) -
#  this function binds all three automatically for every job, so don't
#  include any of them as keys in a -JobParams entry or a -NextJobProvider
#  return value.
#
#  Returns @{ ForceStoppedCount = <int> } - jobs force-stopped after the 60s
#  abort-drain timeout (0 on a normal, non-aborted completion).
# ------------------------------------------------------------------------------
function Invoke-ParallelFolderJobs {
    param(
        [scriptblock]$WorkerScript,
        [System.Collections.Generic.List[hashtable]]$JobParams = $null,
        [scriptblock]$NextJobProvider = $null,
        [string[]]$SharedFunctionNames,
        [int]$MaxParallel,
        [System.Threading.CancellationTokenSource]$Cts,
        [scriptblock]$ResultHandler,
        [string]$AbortWaitMessage = "[ABORT] Waiting for current jobs to finish (up to 60s)..."
    )

    if ($null -eq $JobParams -and $null -eq $NextJobProvider) {
        throw "Invoke-ParallelFolderJobs: must supply either -JobParams or -NextJobProvider."
    }
    if ($null -ne $JobParams -and $null -ne $NextJobProvider) {
        throw "Invoke-ParallelFolderJobs: supply only one of -JobParams or -NextJobProvider, not both."
    }

    # Normalize -JobParams into a provider closure internally, so the rest of
    # this function has only one dispatch code path to maintain.
    if ($null -ne $JobParams) {
        if ($JobParams.Count -eq 0) { return @{ ForceStoppedCount = 0 } }
        $fixedListIndex = 0
        $provider = {
            if ($fixedListIndex -lt $JobParams.Count) {
                $j = $JobParams[$fixedListIndex]
                $fixedListIndex++
                return $j
            }
            return $null
        }
    } else {
        $provider = $NextJobProvider
    }

    $localLogMutex   = [System.Threading.Mutex]::new($false, ("JxlLogMutex_" + $pathHash))
    $script:logMutex = $localLogMutex
    $localConsoleQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

    $localIss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($sharedFn in $SharedFunctionNames) {
        $fnDef = (Get-Item ("Function:\" + $sharedFn)).Definition
        $localIss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $sharedFn, $fnDef))
    }

    $localPool = [RunspaceFactory]::CreateRunspacePool(1, $MaxParallel, $localIss, $Host)
    $localPool.Open()

    $localHandles      = [System.Collections.Generic.List[hashtable]]::new()
    $scanExhausted     = $false
    $forceStoppedCount = 0

    try {
        # ==================================================================
        #  Combined provider + dispatch + collect loop. Exits once the
        #  provider is exhausted and every dispatched job has returned, or
        #  once the abort flag is set (the graceful drain below takes over).
        # ==================================================================
        while ((-not $scanExhausted -or $localHandles.Count -gt 0) -and -not $Cts.Token.IsCancellationRequested) {

            while (-not $scanExhausted -and $localHandles.Count -lt $MaxParallel -and -not $Cts.Token.IsCancellationRequested) {
                $nextJob = & $provider
                if ($null -eq $nextJob) { $scanExhausted = $true; break }

                $ps = [PowerShell]::Create()
                $ps.RunspacePool = $localPool
                $null = $ps.AddScript($WorkerScript)
                foreach ($key in $nextJob.Keys) { $null = $ps.AddParameter($key, $nextJob[$key]) }
                # See docstring: every worker must declare these three; bound
                # here automatically rather than requiring each job (whether
                # from -JobParams or a -NextJobProvider) to include them.
                $null = $ps.AddParameter("CancelToken", $Cts.Token)
                $null = $ps.AddParameter("LogMutex", $localLogMutex)
                $null = $ps.AddParameter("ConsoleQueue", $localConsoleQueue)
                $localHandles.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
            }

            $null = Test-AbortSignal
            Flush-ConsoleQueue -Queue $localConsoleQueue

            $localStillPending = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($h in $localHandles) {
                if ($h.Handle.IsCompleted) {
                    try {
                        $localResults = $h.PS.EndInvoke($h.Handle)
                        foreach ($r in $localResults) { & $ResultHandler $r }
                        if ($h.PS.HadErrors) {
                            foreach ($e in $h.PS.Streams.Error) { Write-Log ("Runspace error: " + $e.ToString()) -Level Error }
                        }
                    } catch {
                        Write-Log ("Error collecting runspace result: " + $_) -Level Error
                    } finally {
                        $h.PS.Dispose()
                    }
                } else {
                    $localStillPending.Add($h)
                }
            }
            $localHandles = $localStillPending
            if ($localHandles.Count -gt 0 -and ($scanExhausted -or $localHandles.Count -ge $MaxParallel)) { Start-Sleep -Milliseconds 100 }
        }

        # Graceful drain after abort: wait up to 60s for in-flight jobs to
        # finish naturally, then force-stop anything still running. Jobs the
        # provider hadn't yet produced (or hadn't been dispatched due to a
        # full pool) are simply never dispatched - nothing to drain for those.
        if ($Cts.Token.IsCancellationRequested -and $localHandles.Count -gt 0) {
            if ($AbortWaitMessage) { Write-Host $AbortWaitMessage -ForegroundColor Yellow }
            $abortDeadline = [System.Diagnostics.Stopwatch]::StartNew()

            while ($localHandles.Count -gt 0 -and $abortDeadline.Elapsed.TotalSeconds -lt 60) {
                $localStillActive = [System.Collections.Generic.List[hashtable]]::new()
                foreach ($h in $localHandles) {
                    if ($h.Handle.IsCompleted) {
                        try {
                            $localResults = $h.PS.EndInvoke($h.Handle)
                            foreach ($r in $localResults) { & $ResultHandler $r }
                        } catch { }
                        finally { $h.PS.Dispose() }
                    } else {
                        $localStillActive.Add($h)
                    }
                }
                $localHandles = $localStillActive
                Flush-ConsoleQueue -Queue $localConsoleQueue
                if ($localHandles.Count -gt 0) { Start-Sleep -Milliseconds 250 }
            }

            if ($localHandles.Count -gt 0) {
                $forceStoppedCount = $localHandles.Count
                Write-Host ("[ABORT] Force-stopping " + $forceStoppedCount + " job(s) that did not finish within 60s.") -ForegroundColor Red
                foreach ($h in $localHandles) {
                    try { $h.PS.Stop() } catch { }
                    try { $h.PS.Dispose() } catch { }
                }
                $localHandles = [System.Collections.Generic.List[hashtable]]::new()
            }
        }

        Flush-ConsoleQueue -Queue $localConsoleQueue
    } finally {
        # Always torn down, even if the provider, worker collection, or
        # -ResultHandler throws - the previous version of this function had
        # no such guarantee and could leak the pool/mutex on an exception.
        if ($null -ne $localPool) { try { $localPool.Close() } catch { }; try { $localPool.Dispose() } catch { } }
        $script:logMutex = $null   # stop Write-Log from acquiring a disposed mutex
        if ($null -ne $localLogMutex) { try { $localLogMutex.Dispose() } catch { } }
    }

    return @{ ForceStoppedCount = $forceStoppedCount }
}

# ------------------------------------------------------------------------------
#  Scriptblock executed in each runspace - handles one ZIP end-to-end
# ------------------------------------------------------------------------------
$zipWorker = {
    param(
        [string]$ZipPath,
        [string]$ZipLastWriteTimeUtc,
        [string]$CjxlExe,
        [string]$LogFile,
        [string]$LogErrorFile,
        [string]$LogWarnFile,
        [bool]$DoFullLogging,
        [bool]$DeleteFolders,
        [int]$MaxCjxlProcs,
        [bool]$DoJpegLossless,
        [int]$DoJpegQuality,
        [string]$MagickExe,
        [bool]$DoPermanentDelete,
        [System.Threading.Mutex]$LogMutex,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ConsoleQueue,
        [System.Threading.CancellationToken]$CancelToken,
        [string]$StateFile,
        [System.Threading.Mutex]$StateMutex,
        [System.Collections.Concurrent.ConcurrentDictionary[string,string]]$CompletedBag
    )

    # Hoist assemblies inside the runspace
    Add-Type -AssemblyName "Microsoft.VisualBasic"
    Add-Type -AssemblyName "System.IO.Compression.FileSystem"

    # ------------------------------------------------------------------
    #  Bootstrap: this runspace has its own independent script scope, so
    #  the shared Write-Log/Remove-Source/Convert-ImageBatch functions
    #  (registered via InitialSessionState - see the pool creation code)
    #  need the same-named script-scope variables set here that they'd
    #  find at the main script's top level. This is what lets those
    #  functions run unmodified in either context.
    # ------------------------------------------------------------------
    $script:logMutex       = $LogMutex
    $script:workerConsoleQueue   = $ConsoleQueue
    $script:FullLogging    = $DoFullLogging
    $script:logFile        = $LogFile
    $script:logErrorFile   = $LogErrorFile
    $script:logWarnFile    = $LogWarnFile
    $script:PermanentDelete = $DoPermanentDelete

    # Result object accumulated throughout and returned to the main thread
    $result = @{
        ZipName           = [System.IO.Path]::GetFileName($ZipPath)
        ZipPath           = $ZipPath
        ZipExtracted      = 0; ZipExtractFailed  = 0
        ImgConverted      = 0; ImgConvertFailed  = 0; ImgSkipped = 0
        ImgDeleted        = 0; ImgDeleteFailed   = 0
        ZipCreated        = 0; ZipCreateFailed   = 0
        FolderDeleted     = 0; FolderDeleteFailed = 0
        # Tracks the last meaningful action completed in this worker, used for
        # the abort summary. Set to the full source path of the last successfully
        # converted image, or the output ZIP path if re-zipping was underway.
        LastConvertedPath = $null
        LastReZipPath     = $null
    }

    $parentDir  = [System.IO.Path]::GetDirectoryName($ZipPath)
    $baseName   = [System.IO.Path]::GetFileNameWithoutExtension($ZipPath)
    $extractDir = [System.IO.Path]::Combine($parentDir, $baseName)

    Write-Log ("--- Begin: '" + $result.ZipName + "' ---")

    # Check for cancellation before doing any real work
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
    #  STEPS 2 & 3 - Convert images in parallel, delete source on success
    # ------------------------------------------------------------------
    $imgExtensions = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif")
    $imgFiles = @(Get-ChildItem -LiteralPath $extractDir -Recurse -File -ErrorAction SilentlyContinue |
                  Where-Object { $imgExtensions -icontains $_.Extension })

    if ($imgFiles.Count -eq 0) {
        Write-Log ("No convertible image files found in '" + $extractDir + "'.")
    } else {
        Write-Log ("Found " + $imgFiles.Count + " image(s) in '" + $extractDir + "' - converting in parallel.")

        $batchResult = Convert-ImageBatch -ImageFiles $imgFiles -CjxlExe $CjxlExe -MagickExe $MagickExe `
            -DoJpegLossless $DoJpegLossless -DoJpegQuality $DoJpegQuality -MaxCjxlProcs $MaxCjxlProcs `
            -DoFullLogging $DoFullLogging -CancelToken $CancelToken -BatchLabel $result.ZipName `
            -AbortWaitMessage "[ABORT] Waiting for current jobs to finish (up to 60s)..."

        $result.ImgConverted     = $batchResult.ConvertedCount
        $result.ImgConvertFailed = $batchResult.FailedCount
        $result.ImgSkipped       = $batchResult.SkippedCount
        $result.ImgDeleted       = $batchResult.DeletedCount
        $result.ImgDeleteFailed  = $batchResult.DeleteFailedCount
        if ($batchResult.ConvertedPaths.Count -gt 0) {
            $result.LastConvertedPath = $batchResult.ConvertedPaths[$batchResult.ConvertedPaths.Count - 1]
        }
    }

    if ($CancelToken.IsCancellationRequested) {
        Write-Log ("Cancelled before re-zip step for '" + $result.ZipName + "'") -Level Warn
        return $result
    }

    # ------------------------------------------------------------------
    #  STEP 4 - Re-zip extracted folder
    #  Intentionally unconditional: unlike the loose-folder-zip path (mode 2,
    #  which checks $looseFolderImgExts and skips zipping if any unconverted/
    #  unrecognized-format source images remain), this always re-zips after
    #  conversion regardless of leftover files (failed conversions, .avif,
    #  etc.). That's the intended behavior of the rezip pipeline - confirmed,
    #  not an oversight - so don't add an equivalent gate here without
    #  checking first.
    # ------------------------------------------------------------------
    $zipOut = $extractDir + ".zip"

    try {
        Write-Log ("Re-zipping '" + $extractDir + "' -> '" + $zipOut + "'")
        $result.LastReZipPath = $zipOut

        $zipSize = Compress-FolderToZip -SourceDir $extractDir -ZipOut $zipOut
        $verify  = Test-ZipArchive -ZipPath $zipOut

        Write-Log ("ZIP OK: '" + $zipOut + "' (" + $zipSize + " bytes, " + $verify.EntryCount + " entries)")
        $result.ZipCreated = 1

        if ($DeleteFolders) {
            try {
                Remove-ItemPermanently $extractDir
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

    # Only record this ZIP as completed if all critical steps succeeded.
    # A partial failure (failed re-zip, etc.) must NOT be skipped on the next run.
    $zipFullySucceeded = ($result.ZipExtractFailed -eq 0) -and
                         ($result.ZipCreateFailed  -eq 0) -and
                         ($result.ImgConvertFailed  -eq 0)

    if ($zipFullySucceeded) {
        $entryJson = ('{"Path":' + ($ZipPath | ConvertTo-Json) + ',"LastWriteTimeUtc":' + ($ZipLastWriteTimeUtc | ConvertTo-Json) + '}')
        $CompletedBag[$ZipPath] = $entryJson
        try {
            $null = $StateMutex.WaitOne()
            # Read existing state entries, merge new entry, write back
            $existing = [System.Collections.Generic.List[object]]::new()
            if (Test-Path -LiteralPath $StateFile) {
                try {
                    $parsed = [System.IO.File]::ReadAllText($StateFile) | ConvertFrom-Json
                    foreach ($e in $parsed) { $existing.Add($e) }
                } catch { }
            }
            # Build merged dictionary (path -> lwt), newest entry wins
            $merged = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($e in $existing) {
                if ($e.PSObject.Properties['Path'] -and $e.PSObject.Properties['LastWriteTimeUtc']) {
                    $merged[$e.Path] = $e.LastWriteTimeUtc
                }
            }
            $merged[$ZipPath] = $ZipLastWriteTimeUtc
            $merged.GetEnumerator() | ForEach-Object {
                [pscustomobject]@{ Path = $_.Key; LastWriteTimeUtc = $_.Value }
            } | ConvertTo-Json -Compress | Set-Content -LiteralPath $StateFile -Encoding UTF8
        } catch { }
        finally { $StateMutex.ReleaseMutex() }
    } else {
        Write-Log ("ZIP '" + $result.ZipName + "' had failures - NOT recorded in state file; will be retried next run.") -Level Warn
    }

    return $result
}

# ------------------------------------------------------------------------------
#  Scriptblock executed in each runspace - zips (and deletes) one leaf folder,
#  no conversion involved. Used by the zip-only pipeline (mode 3). Adapted
#  from Zip_Files-claude-parallel.ps1's $zipWorker, but calling the shared
#  Write-Log/Remove-Source/Compress-FolderToZip/Test-ZipArchive functions
#  (registered into this runspace via InitialSessionState - see the pool
#  creation code) instead of maintaining another copy of each.
# ------------------------------------------------------------------------------
$zipOnlyWorker = {
    param(
        [string]$FolderPath,
        [string]$ZipOutPath,
        [string]$LogFile,
        [string]$LogErrorFile,
        [string]$LogWarnFile,
        [bool]$DoFullLogging,
        [bool]$DeleteFolders,
        [bool]$DoPermanentDelete,
        [System.Threading.Mutex]$LogMutex,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ConsoleQueue,
        [System.Threading.CancellationToken]$CancelToken
    )

    Add-Type -AssemblyName "Microsoft.VisualBasic"
    Add-Type -AssemblyName "System.IO.Compression.FileSystem"

    # Bootstrap: same pattern as $zipWorker - this runspace has its own
    # independent script scope, so the shared functions need these
    # same-named script-scope variables set here.
    $script:logMutex           = $LogMutex
    $script:workerConsoleQueue = $ConsoleQueue
    $script:FullLogging        = $DoFullLogging
    $script:logFile            = $LogFile
    $script:logErrorFile       = $LogErrorFile
    $script:logWarnFile        = $LogWarnFile
    $script:PermanentDelete    = $DoPermanentDelete

    $folderName = [System.IO.Path]::GetFileName($FolderPath)
    $result = @{
        FolderName         = $folderName
        Success            = 0
        Failed             = 0
        FolderDeleted      = 0
        FolderDeleteFailed = 0
    }

    if ($CancelToken.IsCancellationRequested) {
        Write-Log ("Cancelled before starting '" + $folderName + "'") -Level Warn
        return $result
    }

    try {
        Write-Log ("Zipping '" + $FolderPath + "' -> '" + $ZipOutPath + "'")

        $zipSize = Compress-FolderToZip -SourceDir $FolderPath -ZipOut $ZipOutPath
        $verify  = Test-ZipArchive -ZipPath $ZipOutPath -RequireJxlEntry $false

        Write-Log ("ZIP OK: '" + $ZipOutPath + "' (" + $zipSize + " bytes, " + $verify.EntryCount + " entries)")
        $result.Success = 1

        if ($DeleteFolders) {
            try {
                Remove-Source $FolderPath
                $deleteDesc = if ($DoPermanentDelete) { "permanently" } else { "Recycle Bin" }
                Write-Log ("Deleted source folder (" + $deleteDesc + "): '" + $FolderPath + "'")
                $result.FolderDeleted = 1
            } catch {
                Write-Log ("FAILED to delete folder '" + $FolderPath + "': " + $_) -Level Error
                $result.FolderDeleteFailed = 1
            }
        }
    } catch {
        Write-Log ("FAILED to zip '" + $folderName + "': " + $_) -Level Error
        $result.Failed = 1
        # Remove the broken partial zip if it was created
        try {
            if (Test-Path -LiteralPath $ZipOutPath) { [System.IO.File]::Delete($ZipOutPath) }
        } catch { }
    }

    return $result
}

# ==============================================================================
#  MAIN
# ==============================================================================
try {

    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("Path '" + $Path + "' does not exist.")
    }

    $cjxl = Find-Cjxl -UserPath $CjxlPath
    if (-not $cjxl) {
        throw "cjxl.exe was not found. Install libjxl or pass -CjxlPath."
    }

    $magick = Find-Magick -UserPath $MagickPath
    # $magick may be $null - only required when WebP files are present

    $deleteFolders = $true

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $stats = @{
        ZipExtracted        = @{ Success = 0; Fail = 0 }
        ImgConverted        = @{ Success = 0; Fail = 0; Skipped = 0 }
        ImgDeleted          = @{ Success = 0; Fail = 0 }
        ZipCreated          = @{ Success = 0; Fail = 0 }
        FolderDeleted       = @{ Success = 0; Fail = 0 }
        LooseImgConverted   = @{ Success = 0; Fail = 0; Skipped = 0 }
        LooseImgDeleted     = @{ Success = 0; Fail = 0 }
        LooseStaleCleaned   = @{ Success = 0; Fail = 0 }
        LooseFolderZipped   = @{ Success = 0; Fail = 0; Skipped = 0 }
        LooseFolderDeleted  = @{ Success = 0; Fail = 0 }
        ZipOnlyZipped       = @{ Success = 0; Fail = 0 }
        ZipOnlyFolderDeleted = @{ Success = 0; Fail = 0 }
    }

    # ------------------------------------------------------------------
    #  Mode prompt — shown at launch when $EnableModePrompt = $true.
    #  Resolves which phases to run into four boolean flags:
    #    $runZipPhase    - run the rezip-conversion (ZIP) pipeline
    #    $runLooseConv   - run loose-image conversion
    #    $runLooseZip    - zip loose-file folders after conversion
    #    $runZipOnly     - run the zip-only pipeline (no conversion at all)
    #  Default (prompt disabled) is mode 1 - loose file conversion only.
    # ------------------------------------------------------------------
    $runZipPhase  = $false
    $runLooseConv = $true
    $runLooseZip  = $false
    $runZipOnly   = $false

    if ($EnableModePrompt) {
        Write-Host ""
        Write-Host "Select process to run:" -ForegroundColor Cyan
        Write-Host "  1 - Loose file conversion only  (no ZIP pipeline; no post-zip)"
        Write-Host "  2 - Loose file conversion + zip folders after conversion"
        Write-Host "  3 - Zip-only  (no conversion; zips leaf folders of already-ready content)"
        Write-Host "  4 - Rezip conversion only  (ZIP pipeline; no loose-file processing)"
        Write-Host ""

        $modeChoice = $null
        while ($modeChoice -notin @("1","2","3","4")) {
            $modeChoice = (Read-Host "Enter 1, 2, 3, or 4").Trim()
            if ($modeChoice -notin @("1","2","3","4")) {
                Write-Host "Invalid selection. Please enter 1, 2, 3, or 4." -ForegroundColor Yellow
            }
        }

        switch ($modeChoice) {
            "1" {
                $runZipPhase  = $false
                $runLooseConv = $true
                $runLooseZip  = $false
                $runZipOnly   = $false
                Write-Log "Mode selected: 1 - Loose file conversion only."
            }
            "2" {
                $runZipPhase  = $false
                $runLooseConv = $true
                $runLooseZip  = $true
                $runZipOnly   = $false
                Write-Log "Mode selected: 2 - Loose file conversion + zip folders."
            }
            "3" {
                $runZipPhase  = $false
                $runLooseConv = $false
                $runLooseZip  = $false
                $runZipOnly   = $true
                Write-Log "Mode selected: 3 - Zip-only."
            }
            "4" {
                $runZipPhase  = $true
                $runLooseConv = $false
                $runLooseZip  = $false
                $runZipOnly   = $false
                Write-Log "Mode selected: 4 - Rezip conversion only."
            }
        }
    }

    Write-Log ("=== Starting processing in '" + $Path + "' ===")
    Write-Log ("cjxl             : " + $cjxl)
    Write-Log ("FullLogging      : " + $FullLogging)
    Write-Log ("DeleteFolders    : " + $deleteFolders)
    Write-Log ("PermanentDelete  : " + $PermanentDelete + $(if ($PermanentDelete) { " (WARNING: files will be permanently deleted, bypassing the Recycle Bin)" } else { " (files sent to Recycle Bin)" }))
    Write-Log ("MaxParallel      : " + $MaxParallel)
    Write-Log ("JpegLossless     : " + $JpegLossless + $(if (-not $JpegLossless) { " (quality=$JpegQuality)" } else { "" }))
    Write-Log ("magick           : " + $(if ($magick) { $magick } else { "not found (WebP conversion unavailable)" }))
    Write-Log ("EnableModePrompt : " + $EnableModePrompt)
    if (-not $EnableModePrompt) {
        Write-Log "Mode (prompt disabled): 1 - Loose file conversion only."
    }

    # ------------------------------------------------------------------
    #  Load resume state (if present) so already-completed ZIPs are skipped.
    #  State entries are objects: { Path, LastWriteTimeUtc }
    #  A ZIP is skipped only if BOTH the path and the file's current
    #  LastWriteTimeUtc match the recorded value, so a replaced ZIP
    #  (same name, newer date) will always be re-processed.
    # ------------------------------------------------------------------
    # Keyed by full path (case-insensitive) -> LastWriteTimeUtc string
    $resumedMap = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $raw = [System.IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
            foreach ($entry in $raw) {
                if ($entry.PSObject.Properties['Path'] -and $entry.PSObject.Properties['LastWriteTimeUtc']) {
                    $resumedMap[$entry.Path] = $entry.LastWriteTimeUtc
                }
            }
            Write-Log ("Resume state loaded: " + $resumedMap.Count + " previously completed ZIP(s) tracked. Delete '" + $stateFile + "' to start completely fresh.")
        } catch {
            Write-Log ("Could not read resume state file - starting fresh. (" + $_ + ")") -Level Warn
        }
    }

    # ------------------------------------------------------------------
    #  Abort signal polling — defined here so it is always in scope,
    #  including during the loose-image phase when no ZIPs were found.
    #
    #  Only cancels a CTS if it is non-null and not already disposed;
    #  wrapping in try/catch handles the disposed-CTS edge case that
    #  occurs in the window between ZIP-phase teardown and loose-phase init.
    # ------------------------------------------------------------------
    function Test-AbortSignal {
        if ([ConsoleCtrl]::AbortRequested -and -not $script:abortRequested) {
            $script:abortRequested = $true
            $script:ctrlCloseAbort = [ConsoleCtrl]::IsCloseEvent
            if ($null -ne $script:cts)        { try { $script:cts.Cancel()        } catch { } }
            if ($null -ne $script:looseCts)   { try { $script:looseCts.Cancel()   } catch { } }
            if ($null -ne $script:zipOnlyCts) { try { $script:zipOnlyCts.Cancel() } catch { } }
            if (-not $script:ctrlCloseAbort) {
                Write-Host "`n[ABORT] Ctrl+C detected - finishing current jobs, please wait..." -ForegroundColor Yellow
            } else {
                Write-Host "`n[ABORT] Window close detected - finishing current jobs, please wait..." -ForegroundColor Yellow
            }
        }
        return $script:abortRequested
    }

    # $allZips is populated by the ZIP phase; initialised here so the loose-image
    # phase (which uses it to build $zipBaseDirs) always has a valid collection
    # regardless of whether the ZIP phase ran.
    $allZips = @()

    if ($runZipPhase) {

    # ==========================================================================
    #  Discover and pre-filter ZIPs (skip those with no JPGs)
    # ==========================================================================
    $allZips = @(Get-ChildItem -LiteralPath $Path -Recurse -Filter "*.zip" -File -ErrorAction SilentlyContinue |
        Where-Object {
            # Exclude ZIPs that live inside a folder that is itself an extraction staging
            # directory (i.e. a folder sharing its name with a sibling .zip).  These are
            # artefacts of a previous partial run and should not be re-processed.
            # A ZIP is inside a staging dir if its parent folder has a sibling .zip of the same name.
            $parentOfDir = [System.IO.Path]::GetDirectoryName($_.DirectoryName)
            if ($parentOfDir -and (Test-Path -LiteralPath ([System.IO.Path]::Combine($parentOfDir, ($_.Directory.Name + ".zip"))))) {
                return $false
            }
            return $true
        })
    if ($null -eq $allZips) { $allZips = @() }

    if ($allZips.Count -eq 0) {
        Write-Log "No ZIP files found." -Level Warn
    } else {
        Write-Log ("Found " + $allZips.Count + " ZIP file(s). Scanning and dispatching as qualifying ZIPs are found...")

        $imgPattern = '\.(jpg|jpeg|png|webp|tiff|tif)$'

        # ==================================================================
        #  Shared objects: set up once, used across the combined scan+work loop
        # ==================================================================
        # $pathHash was already computed at script startup (see log-file init)

        $logMutex     = [System.Threading.Mutex]::new($false, ("JxlLogMutex_"   + $pathHash))
        $stateMutex   = [System.Threading.Mutex]::new($false, ("JxlStateMutex_" + $pathHash))
        $script:logMutex = $logMutex   # expose to Write-Log / Flush-ConsoleQueue
        $consoleQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        # Keyed by ZipPath -> JSON entry string.  Each worker writes exactly once
        # (on success), so at abort time the dictionary holds at most one entry per
        # ZIP that finished during this run — but we only want the ones that were
        # in-flight at the moment of abort.  The abort drain loop populates
        # $lastCompletedAtAbort separately for the summary display.
        $completedBag = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:cts     = [System.Threading.CancellationTokenSource]::new()

        # ==================================================================
        #  Propagate the shared functions into every runspace via
        #  InitialSessionState, so $zipWorker calls the exact same
        #  Write-Log/Remove-Source/Compress-FolderToZip/Test-ZipArchive/
        #  Convert-ImageBatch as the main thread, instead of maintaining
        #  separate RS-* copies inside the worker scriptblock.
        # ==================================================================
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($sharedFn in @(
            'Write-Log', 'Move-ToRecycleBin', 'Remove-ItemPermanently', 'Remove-Source',
            'Compress-FolderToZip', 'Test-ZipArchive', 'Convert-ImageBatch'
        )) {
            $fnDef = (Get-Item ("Function:\" + $sharedFn)).Definition
            $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $sharedFn, $fnDef))
        }

        $pool = [RunspaceFactory]::CreateRunspacePool(1, $MaxParallel, $iss, $Host)
        $pool.Open()

        $handles      = [System.Collections.Generic.List[hashtable]]::new()
        $zipIndex     = 0          # cursor into $allZips - advances as we scan
        $dispatched   = 0
        $skipped      = 0

        # ==================================================================
        #  Combined scan + dispatch + collect loop.
        #
        #  Each iteration:
        #    1. Peek the next un-examined ZIP and dispatch it immediately if
        #       it qualifies (no waiting for the full scan to finish).
        #    2. Collect any completed runspace results.
        #    3. Drain the console queue.
        #  The loop exits once every ZIP has been examined AND every
        #  dispatched runspace has returned its result, OR when the abort
        #  flag is set (in which case the graceful drain below takes over).
        # ==================================================================
        while ((-not (Test-AbortSignal)) -and
               ($zipIndex -lt $allZips.Count -or $handles.Count -gt 0)) {

            # -- Step 1: examine the next ZIP and dispatch if it qualifies --
            # Capacity guard: don't examine (and potentially dispatch) more ZIPs
            # while the pool is already fully occupied.  Without this the loop
            # advances $zipIndex on every iteration even when no slot is free,
            # causing BeginInvoke() to be called on a full pool and returning $null.
            if ($zipIndex -lt $allZips.Count -and $handles.Count -lt $MaxParallel) {
                $zip    = $allZips[$zipIndex]
                $zipIndex++

                $zipLwt = $zip.LastWriteTimeUtc.ToString("o")

                if ($resumedMap.ContainsKey($zip.FullName) -and $resumedMap[$zip.FullName] -eq $zipLwt) {
                    Write-Log ("Skipping '" + $zip.Name + "' - already completed (date unchanged).")
                    $skipped++
                } else {
                    $hasImgs    = $false
                    $inspectOk  = $true
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
                        $skipped++
                    }

                    if (-not $inspectOk) {
                        # Already counted and logged above; nothing more to do
                    } elseif ($hasImgs) {
                        Write-Log ("Dispatching '" + $zip.Name + "' for conversion.")
                        $dispatched++
                        $ps = [PowerShell]::Create()
                        $ps.RunspacePool = $pool
                        $null = $ps.AddScript($zipWorker)
                        $null = $ps.AddParameter("ZipPath",             $zip.FullName)
                        $null = $ps.AddParameter("ZipLastWriteTimeUtc", $zipLwt)
                        $null = $ps.AddParameter("CjxlExe",             $cjxl)
                        $null = $ps.AddParameter("LogFile",             $logFile)
                        $null = $ps.AddParameter("LogErrorFile",        $logErrorFile)
                        $null = $ps.AddParameter("LogWarnFile",         $logWarnFile)
                        $null = $ps.AddParameter("DoFullLogging",       $FullLogging)
                        $null = $ps.AddParameter("DeleteFolders",       $deleteFolders)
                        $null = $ps.AddParameter("MaxCjxlProcs",        $MaxCjxlProcs)
                        $null = $ps.AddParameter("DoJpegLossless",      $JpegLossless)
                        $null = $ps.AddParameter("DoJpegQuality",       $JpegQuality)
                        $null = $ps.AddParameter("MagickExe",           $magick)
                        $null = $ps.AddParameter("DoPermanentDelete",   $PermanentDelete)
                        $null = $ps.AddParameter("LogMutex",            $logMutex)
                        $null = $ps.AddParameter("ConsoleQueue",        $consoleQueue)
                        $null = $ps.AddParameter("CancelToken",         $script:cts.Token)
                        $null = $ps.AddParameter("StateFile",           $stateFile)
                        $null = $ps.AddParameter("StateMutex",          $stateMutex)
                        $null = $ps.AddParameter("CompletedBag",        $completedBag)
                        $handles.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
                    } else {
                        # No images - record in state so it is not re-scanned next run.
                        # Mutex-protected merge with the on-disk file, since ZIP workers
                        # are concurrently writing to the same state file.
                        Write-Log ("Skipping '" + $zip.FullName + "' - no convertible images inside.") -Level Warn
                        $resumedMap[$zip.FullName] = $zipLwt
                        try {
                            $null = $stateMutex.WaitOne()
                            try {
                                $existingNoImg = [System.Collections.Generic.List[object]]::new()
                                if (Test-Path -LiteralPath $stateFile) {
                                    try {
                                        $parsedNoImg = [System.IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
                                        foreach ($e in $parsedNoImg) { $existingNoImg.Add($e) }
                                    } catch { }
                                }
                                $mergedNoImg = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                                foreach ($e in $existingNoImg) {
                                    if ($e.PSObject.Properties['Path'] -and $e.PSObject.Properties['LastWriteTimeUtc']) {
                                        $mergedNoImg[$e.Path] = $e.LastWriteTimeUtc
                                    }
                                }
                                $mergedNoImg[$zip.FullName] = $zipLwt
                                $mergedNoImg.GetEnumerator() | ForEach-Object {
                                    [pscustomobject]@{ Path = $_.Key; LastWriteTimeUtc = $_.Value }
                                } | ConvertTo-Json -Compress | Set-Content -LiteralPath $stateFile -Encoding UTF8
                            } finally { $stateMutex.ReleaseMutex() }
                        } catch { }
                        $skipped++
                    }
                }
            }

            # -- Step 2: collect any completed runspace results --
            $stillActive = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($h in $handles) {
                if ($h.Handle.IsCompleted) {
                    try {
                        $results = $h.PS.EndInvoke($h.Handle)
                        foreach ($r in $results) {
                            $stats.ZipExtracted.Success  += $r.ZipExtracted
                            $stats.ZipExtracted.Fail     += $r.ZipExtractFailed
                            $stats.ImgConverted.Success  += $r.ImgConverted
                            $stats.ImgConverted.Fail     += $r.ImgConvertFailed
                            $stats.ImgConverted.Skipped  += $r.ImgSkipped
                            $stats.ImgDeleted.Success    += $r.ImgDeleted
                            $stats.ImgDeleted.Fail       += $r.ImgDeleteFailed
                            $stats.ZipCreated.Success    += $r.ZipCreated
                            $stats.ZipCreated.Fail       += $r.ZipCreateFailed
                            $stats.FolderDeleted.Success += $r.FolderDeleted
                            $stats.FolderDeleted.Fail    += $r.FolderDeleteFailed
                        }
                        if ($h.PS.HadErrors) {
                            foreach ($e in $h.PS.Streams.Error) {
                                Write-Log ("Runspace error: " + $e.ToString()) -Level Error
                            }
                        }
                    } catch {
                        Write-Log ("Error collecting runspace result: " + $_) -Level Error
                    } finally {
                        $h.PS.Dispose()
                    }
                } else {
                    $stillActive.Add($h)
                }
            }
            $handles = $stillActive

            # -- Step 3: drain console queue --
            Flush-ConsoleQueue -Queue $consoleQueue

            # Yield briefly only when the pool is fully occupied and there are
            # still ZIPs left to scan, or when we're just waiting for workers to finish.
            if ($handles.Count -ge $MaxParallel -or ($zipIndex -ge $allZips.Count -and $handles.Count -gt 0)) {
                Start-Sleep -Milliseconds 100
            }
        }

        # ==================================================================
        #  Graceful drain after abort signal
        #  The main loop exited because CancellationRequested was set.
        #  Workers that are already in-flight are allowed to finish naturally
        #  (they check the token only between jobs, so the current job
        #  completes).  We wait up to 60 s, then force-stop stragglers.
        # ==================================================================
        $abortedJobCount = 0
        $lastCompletedAtAbort = [System.Collections.Generic.List[string]]::new()
        if ($script:abortRequested -and $handles.Count -gt 0) {
            Write-Host "[ABORT] Waiting for current jobs to finish (up to 60s)..." -ForegroundColor Yellow
            $abortDeadline = [System.Diagnostics.Stopwatch]::StartNew()

            while ($handles.Count -gt 0 -and $abortDeadline.Elapsed.TotalSeconds -lt 60) {
                $stillActive = [System.Collections.Generic.List[hashtable]]::new()
                foreach ($h in $handles) {
                    if ($h.Handle.IsCompleted) {
                        try {
                            $results = $h.PS.EndInvoke($h.Handle)
                            foreach ($r in $results) {
                                $stats.ZipExtracted.Success  += $r.ZipExtracted
                                $stats.ZipExtracted.Fail     += $r.ZipExtractFailed
                                $stats.ImgConverted.Success  += $r.ImgConverted
                                $stats.ImgConverted.Fail     += $r.ImgConvertFailed
                                $stats.ImgConverted.Skipped  += $r.ImgSkipped
                                $stats.ImgDeleted.Success    += $r.ImgDeleted
                                $stats.ImgDeleted.Fail       += $r.ImgDeleteFailed
                                $stats.ZipCreated.Success    += $r.ZipCreated
                                $stats.ZipCreated.Fail       += $r.ZipCreateFailed
                                $stats.FolderDeleted.Success += $r.FolderDeleted
                                $stats.FolderDeleted.Fail    += $r.FolderDeleteFailed
                                # Record the last meaningful action from this worker for the abort
                                # summary. Priority: re-zip path (if re-zipping was underway) >
                                # last converted image path. A worker that only extracted a ZIP
                                # but did no conversions is excluded — extraction is not a
                                # "last job" worth reporting.
                                if ($r.LastReZipPath) {
                                    $lastCompletedAtAbort.Add("[re-zip] " + $r.LastReZipPath)
                                } elseif ($r.LastConvertedPath) {
                                    $lastCompletedAtAbort.Add($r.LastConvertedPath)
                                }
                            }
                        } catch { }
                        finally { $h.PS.Dispose() }
                    } else {
                        $stillActive.Add($h)
                    }
                }
                $handles = $stillActive
                Flush-ConsoleQueue -Queue $consoleQueue
                if ($handles.Count -gt 0) { Start-Sleep -Milliseconds 250 }
            }

            # Force-stop anything still running after the timeout
            if ($handles.Count -gt 0) {
                $abortedJobCount = $handles.Count
                Write-Host ("[ABORT] Force-stopping " + $abortedJobCount + " job(s) that did not finish within 60s.") -ForegroundColor Red
                foreach ($h in $handles) {
                    try { $h.PS.Stop() } catch { }
                    try { $h.PS.Dispose() } catch { }
                }
                $handles = [System.Collections.Generic.List[hashtable]]::new()
            }
        }

        # Final drain after all runspaces finish
        Flush-ConsoleQueue -Queue $consoleQueue

        # ==================================================================
        #  Save state for completed ZIPs (abort path)
        # ==================================================================
        if ($script:abortRequested) {
            try {
                $existing = [System.Collections.Generic.List[object]]::new()
                if (Test-Path -LiteralPath $stateFile) {
                    try {
                        $parsed = [System.IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
                        foreach ($e in $parsed) { $existing.Add($e) }
                    } catch { }
                }
                $mergedAbort = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($e in $existing) {
                    if ($e.PSObject.Properties['Path'] -and $e.PSObject.Properties['LastWriteTimeUtc']) {
                        $mergedAbort[$e.Path] = $e.LastWriteTimeUtc
                    }
                }
                foreach ($kvp in $completedBag) {
                    try {
                        $obj = $kvp.Value | ConvertFrom-Json
                        if ($obj.Path -and $obj.LastWriteTimeUtc) { $mergedAbort[$obj.Path] = $obj.LastWriteTimeUtc }
                    } catch { }
                }
                $mergedAbort.GetEnumerator() | ForEach-Object {
                    [pscustomobject]@{ Path = $_.Key; LastWriteTimeUtc = $_.Value }
                } | ConvertTo-Json -Compress | Set-Content -LiteralPath $stateFile -Encoding UTF8
                Write-Host ("[ABORT] State saved: " + $mergedAbort.Count + " completed ZIP(s) recorded.") -ForegroundColor Yellow
            } catch {
                Write-Host ("[ABORT] Failed to save state file: " + $_) -ForegroundColor Red
            }

            # Build and write the abort summary
            $stopwatch.Stop()
            $abortElapsed    = $stopwatch.Elapsed
            $abortElapsedStr = "{0:D2}h {1:D2}m {2:D2}s" -f $abortElapsed.Hours, $abortElapsed.Minutes, $abortElapsed.Seconds

            # $lastCompletedAtAbort was populated during the graceful drain above —
            # one entry per handler that was in-flight at abort time.
            # If abort fired before any ZIP workers started (e.g. during scan),
            # the list will be empty.

            $abortTrigger = if ($script:ctrlCloseAbort) { "window close (X button)" } else { "Ctrl+C" }

            $abortSummary = @(
                "=== ABORTED ===",
                ("Process was aborted by user (" + $abortTrigger + ")."),
                ("Time elapsed before abort  : " + $abortElapsedStr),
                ("ZIPs Extracted      : Success = " + $stats.ZipExtracted.Success + "  |  Failed = " + $stats.ZipExtracted.Fail),
                ("Img -> JXL Conv.    : Success = " + $stats.ImgConverted.Success + "  |  Failed = " + $stats.ImgConverted.Fail + "  |  Skipped = " + $stats.ImgConverted.Skipped),
                ("Img Deleted         : Success = " + $stats.ImgDeleted.Success   + "  |  Failed = " + $stats.ImgDeleted.Fail),
                ("ZIPs Created        : Success = " + $stats.ZipCreated.Success   + "  |  Failed = " + $stats.ZipCreated.Fail),
                ("Folders Deleted     : Success = " + $stats.FolderDeleted.Success + "  |  Failed = " + $stats.FolderDeleted.Fail)
            )

            if ($lastCompletedAtAbort.Count -gt 0) {
                $abortSummary += ("Last completed jobs (" + $lastCompletedAtAbort.Count + "):")
                foreach ($p in $lastCompletedAtAbort) { $abortSummary += ("  " + $p) }
            } else {
                $abortSummary += "Last completed jobs : (none)"
            }

            if ($abortedJobCount -gt 0) {
                $abortSummary += ("Forcefully aborted jobs : " + $abortedJobCount + " job(s) did not finish within 60s - these ZIPs will be retried next run.")
            } else {
                $abortSummary += "Forcefully aborted jobs : none - all in-flight jobs completed cleanly."
            }

            $abortSummary += "=== End of aborted run ==="

            Write-Host ""
            foreach ($line in $abortSummary) { Write-Host $line -ForegroundColor Cyan }

            # Write to the appropriate log
            if ($FullLogging) {
                $ts = Get-Date -Format "yyyy-MM-dd HHmmss"
                foreach ($line in $abortSummary) {
                    $entry = $ts + " [Summary] " + $line
                    $safe  = [System.Text.RegularExpressions.Regex]::Replace($entry, "[^\x00-\x7F]", "?")
                    try { $safe | Out-File -FilePath $logFile -Append -Encoding ASCII } catch { }
                }
            } else {
                $runTs     = Get-Date -Format "yyyy-MM-dd HHmmss"
                $block     = @("", ("=== Run: " + $runTs + " ==="))
                $block    += $abortSummary
                $block    += ""
                $safeBlock = $block | ForEach-Object {
                    [System.Text.RegularExpressions.Regex]::Replace($_, "[^\x00-\x7F]", "?")
                }
                try {
                    $existingText = ""
                    if (Test-Path -LiteralPath $logSummaryFile) {
                        $existingText = [System.IO.File]::ReadAllText($logSummaryFile)
                    }
                    [System.IO.File]::WriteAllText($logSummaryFile, ($safeBlock -join "`r`n") + "`r`n" + $existingText, [System.Text.Encoding]::ASCII)
                } catch { }
            }

            # Signal the ConsoleCtrl handler that the drain is complete.
            # For X-button (CTRL_CLOSE_EVENT) this unblocks the native handler
            # so Windows can proceed with closing the window cleanly.
            [ConsoleCtrl]::DrainComplete.Set()

            # For X-button close, Windows will kill the process shortly after
            # DrainComplete unblocks the handler.  Skip the loose-image phase
            # to avoid starting new work that will be forcibly interrupted.
            # NOTE: pool/mutex cleanup is performed inline here before returning
            # so that disposal always runs on the X-button abort path.
            if ($script:ctrlCloseAbort) {
                if ($null -ne $pool)       { try { $pool.Close()        } catch { }; try { $pool.Dispose()        } catch { } }
                $script:logMutex = $null
                if ($null -ne $logMutex)   { try { $logMutex.Dispose()   } catch { } }
                if ($null -ne $stateMutex) { try { $stateMutex.Dispose() } catch { } }
                if ($null -ne $script:cts) { try { $script:cts.Dispose() } catch { } }
                return
            }
        }

        if ($dispatched -eq 0 -and -not $script:abortRequested) {
            Write-Log "No qualifying ZIPs (with convertible images) found." -Level Warn
        } elseif (-not $script:abortRequested) {
            Write-Log ("ZIP processing complete: " + $dispatched + " dispatched, " + $skipped + " skipped.") -Level Summary
        }

        if ($null -ne $pool)       { try { $pool.Close()        } catch { }; try { $pool.Dispose()        } catch { } }
        $script:logMutex = $null   # stop Write-Log from acquiring a disposed mutex
        if ($null -ne $logMutex)   { try { $logMutex.Dispose()   } catch { } }
        if ($null -ne $stateMutex) { try { $stateMutex.Dispose() } catch { } }
        if ($null -ne $script:cts)        { try { $script:cts.Dispose()        } catch { } }
    }

    } # end if ($runZipPhase)

    # ==========================================================================
    #  ZIP-ONLY PIPELINE (mode 3)
    #  Scans for leaf directories containing any recognized content and zips
    #  each in parallel, with no conversion step at all. Ported from
    #  Zip_Files-claude-parallel.ps1, reusing this script's shared
    #  Write-Log/Remove-Source/Compress-FolderToZip/Test-ZipArchive functions,
    #  and its parallel-dispatch/graceful-abort-drain machinery via
    #  Invoke-ParallelFolderJobs, instead of maintaining another copy of any
    #  of that.
    # ==========================================================================
    if ($runZipOnly) {

    try {
        # Broader than $looseFolderImgExts - this pipeline handles arbitrary
        # already-ready content (including video and document/archive
        # formats), not just image types awaiting .jxl conversion, since no
        # conversion happens in this mode.
        $zipOnlyExts = @(
            ".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".jxl", ".bmp", ".tiff", ".tif",
            ".heic", ".heif", ".mp4", ".mkv", ".webm", ".avi", ".mov", ".wmv",
            ".cbz", ".cbr", ".epub", ".pdf"
        )

        Write-Log "Zip-only: scanning for leaf directories..."
        $zoCandidates = Get-ZippableLeafDirs -ScanPath $Path -QualifyingExtensions $zipOnlyExts -ForceRezip $false

        if ($zoCandidates.Count -eq 0) {
            Write-Log "Zip-only: no qualifying leaf directories found." -Level Warn
        } else {
            Write-Log ("Zip-only: found " + $zoCandidates.Count + " folder(s) to zip. Running up to " + $MaxParallel + " in parallel.")

            $zoJobParams = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($cand in $zoCandidates) {
                $zoJobParams.Add(@{
                    FolderPath        = $cand.Dir.FullName
                    ZipOutPath        = $cand.ZipOut
                    LogFile           = $logFile
                    LogErrorFile      = $logErrorFile
                    LogWarnFile       = $logWarnFile
                    DoFullLogging     = $FullLogging
                    DeleteFolders     = $deleteFolders
                    DoPermanentDelete = $PermanentDelete
                })
            }

            $script:zipOnlyCts = [System.Threading.CancellationTokenSource]::new()
            $zoResultHandler = {
                param($r)
                $stats.ZipOnlyZipped.Success        += $r.Success
                $stats.ZipOnlyZipped.Fail           += $r.Failed
                $stats.ZipOnlyFolderDeleted.Success += $r.FolderDeleted
                $stats.ZipOnlyFolderDeleted.Fail    += $r.FolderDeleteFailed
            }

            $zoOutcome = Invoke-ParallelFolderJobs -WorkerScript $zipOnlyWorker -JobParams $zoJobParams `
                -SharedFunctionNames @('Write-Log', 'Move-ToRecycleBin', 'Remove-ItemPermanently', 'Remove-Source', 'Compress-FolderToZip', 'Test-ZipArchive') `
                -MaxParallel $MaxParallel -Cts $script:zipOnlyCts -ResultHandler $zoResultHandler

            $script:zipOnlyCts.Dispose()

            # Printed regardless of abort state, matching the ZIP-extraction
            # pipeline's "ZIP processing complete: N dispatched, M skipped."
            # line - not gated behind the SUMMARY block below, which is
            # skipped entirely on aborted runs.
            $zoCompleteMsg = "Zip-only processing complete: " + $stats.ZipOnlyZipped.Success + " zipped, " + $stats.ZipOnlyZipped.Fail + " failed."
            if ($zoOutcome.ForceStoppedCount -gt 0) {
                $zoCompleteMsg += (" " + $zoOutcome.ForceStoppedCount + " job(s) force-stopped on abort.")
            }
            Write-Log $zoCompleteMsg -Level Summary
        }
    } catch {
        Write-Log ("Zip-only pipeline error: " + $_) -Level Error
    }

    } # end if ($runZipOnly)

    # ==========================================================================
    #  LOOSE IMAGE CONVERSION
    #  Find image files that sit directly on the filesystem (not inside ZIPs),
    #  convert each to JXL, then send the original to the Recycle Bin.
    #  Skips files whose names already have a sibling .jxl (already converted).
    # ==========================================================================
    if ($runLooseConv) {

    $looseImgExts = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif")

    # Exclude files inside folders that are themselves extracted ZIP staging dirs
    # (those are handled by the ZIP worker).  We identify them by checking whether
    # the file lives under a folder whose name matches a qualifying ZIP's base name;
    # simpler: just exclude anything inside a directory that has the same name as a
    # .zip we know about.  For safety we collect all known staging-dir names.
    $zipBaseDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($zp in $allZips) {
        $zipBaseDirs.Add([System.IO.Path]::Combine(
            [System.IO.Path]::GetDirectoryName($zp.FullName),
            [System.IO.Path]::GetFileNameWithoutExtension($zp.FullName)
        )) | Out-Null
    }

    $looseAllCandidates = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            if ($looseImgExts -inotcontains $_.Extension)  { return $false }
            # Skip if file lives inside a known ZIP staging/extraction directory
            # (compare with a trailing separator so e.g. "bar" doesn't match "barbaz")
            $fileDir = $_.DirectoryName
            foreach ($stagingDir in $zipBaseDirs) {
                if ($fileDir.Equals($stagingDir, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $fileDir.StartsWith($stagingDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $false
                }
            }
            return $true
        })

    # Files whose .jxl counterpart already exists are not converted again, but
    # they are stale leftovers from a prior run that should be cleaned up
    # (deleted) rather than left in place indefinitely. Only treated as stale
    # if the existing .jxl looks valid (non-zero bytes) - if it looks
    # incomplete/corrupt, the source is left alone and queued for
    # (re-)conversion instead, since deleting it would lose data.
    $looseImages       = [System.Collections.Generic.List[object]]::new()
    $looseStaleSources = [System.Collections.Generic.List[object]]::new()
    foreach ($img in $looseAllCandidates) {
        $jxlCounterpart = [System.IO.Path]::ChangeExtension($img.FullName, ".jxl")
        if (Test-Path -LiteralPath $jxlCounterpart) {
            $existingJxlSize = (Get-Item -LiteralPath $jxlCounterpart).Length
            if ($existingJxlSize -gt 0) {
                $looseStaleSources.Add($img)
            } else {
                Write-Log ("Existing .jxl counterpart for '" + $img.FullName + "' is 0 bytes - treating as incomplete and re-converting source.") -Level Warn
                $looseImages.Add($img)
            }
        } else {
            $looseImages.Add($img)
        }
    }
    $looseImages = @($looseImages)

    # ------------------------------------------------------------------
    #  Clean up stale source files that already have a valid .jxl
    #  counterpart. Runs regardless of abort state/$looseImages.Count,
    #  since it does not invoke cjxl and completes essentially instantly.
    # ------------------------------------------------------------------
    if ($looseStaleSources.Count -gt 0) {
        Write-Log ("Found " + $looseStaleSources.Count + " loose source file(s) with an existing .jxl counterpart - cleaning up.")
        foreach ($stale in $looseStaleSources) {
            if (Test-AbortSignal) { break }
            try {
                Remove-Source $stale.FullName
                $deleteDesc = if ($PermanentDelete) { "permanently" } else { "Recycle Bin" }
                Write-Log ("Deleted stale source image (" + $deleteDesc + ", .jxl already exists): '" + $stale.FullName + "'")
                $stats.LooseStaleCleaned.Success++
            } catch {
                Write-Log ("FAILED to delete stale source image '" + $stale.FullName + "': " + $_) -Level Error
                $stats.LooseStaleCleaned.Fail++
            }
        }
    }

    # ------------------------------------------------------------------
    #  When $runLooseZip is true (mode 2), build the leaf-dir list now so
    #  we can drive a per-folder convert-then-zip loop.  This list is also
    #  used later to skip the separate $runLooseZip phase (which no longer
    #  exists as a separate block in mode 2 - it is folded in here).
    # ------------------------------------------------------------------
    # $looseFolderImgExts intentionally also includes formats we recognize as
    # images but don't yet convert (currently .avif - no cjxl/magick pipeline
    # for it yet). Listing them here means a leftover .avif blocks zipping the
    # folder (same as a leftover .jpg would) and gets named in the "SKIPPING
    # zip" warning below, instead of being silently invisible and bundled into
    # the ZIP untouched. Do NOT add .avif to $looseImgExts (line ~1828) or
    # $imgExtensions (line ~1148) - those drive what actually gets converted,
    # and cjxl/magick can't handle .avif input.
    $looseFolderImgExts = @(".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".avif")
    $lfLeafDirs = $null   # populated only when $runLooseZip is true

    if ($runLooseZip) {
        $lfZipBaseDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($zp in $allZips) {
            $lfZipBaseDirs.Add([System.IO.Path]::Combine(
                [System.IO.Path]::GetDirectoryName($zp.FullName),
                [System.IO.Path]::GetFileNameWithoutExtension($zp.FullName)
            )) | Out-Null
        }

        # .jxl counts as qualifying content here (a folder already fully
        # converted, just needing zipping, is still a valid candidate) - it's
        # added on top of $looseFolderImgExts rather than folded into it, since
        # $looseFolderImgExts is also used elsewhere purely as "unconverted
        # source image" types, which .jxl is not.
        $lfQualifyingExts = @($looseFolderImgExts) + @(".jxl")
        $lfCandidates = Get-ZippableLeafDirs -ScanPath $Path -QualifyingExtensions $lfQualifyingExts `
            -ExcludeStagingDirs $lfZipBaseDirs -ForceRezip $false
        $lfLeafDirs = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
        foreach ($c in $lfCandidates) { $lfLeafDirs.Add($c.Dir) }

        if ($lfLeafDirs.Count -eq 0) {
            Write-Log "Loose folder zip: no qualifying leaf directories found." -Level Warn
        } else {
            Write-Log ("Loose folder zip: found " + $lfLeafDirs.Count + " leaf director(ies) to process (convert then zip each).")
        }
    }

    # In mode 2 ($runLooseZip), the $looseImages list collected above covers
    # ALL folders and is used only for the stale-cleanup pass (already done).
    # Conversion is driven per-folder below, so we do not use $looseImages
    # as a flat batch in that mode.
    #
    # In mode 1 (no zip), $looseImages is the full flat batch as before.

    # Announce total image count for mode 1 (mode 2 announces per-folder).
    if (-not $runLooseZip) {
        if ($looseImages.Count -eq 0) {
            Write-Log "No loose image files found outside ZIPs." -Level Info
        } elseif ($script:abortRequested) {
            Write-Log "Loose image conversion skipped - process was aborted." -Level Warn
        } else {
            Write-Log ("Found " + $looseImages.Count + " loose image file(s) to convert.")
        }
    }

    # shared abort-tracking state - initialised once, used by both the
    # per-folder loop (mode 2) and the flat loop (mode 1).
    $lastLooseCompleted = [System.Collections.Generic.List[string]]::new()
    $lastLooseSkipped   = [System.Collections.Generic.List[string]]::new()
    $looseAbortedCount  = 0
    $looseStillPendingPaths = $null   # set from Convert-ImageBatch's return after each batch; stays
                                       # $null if abort happens before any batch's dispatch loop runs

    # ------------------------------------------------------------------
    #  Determine the list of "work batches" to process.
    #  Mode 1: one batch = all images (no per-folder scoping).
    #  Mode 2: one batch per leaf dir, images scoped to that dir only.
    # ------------------------------------------------------------------
    # $workBatches is a list of hashtables: @{ Images = [...]; Dir = <DirInfo or $null> }
    $workBatches = [System.Collections.Generic.List[hashtable]]::new()
    if ($runLooseZip -and $lfLeafDirs -and $lfLeafDirs.Count -gt 0 -and -not $script:abortRequested) {
        foreach ($dir in $lfLeafDirs) {
            # Scope $looseImages to only this folder's files
            $folderImages = @($looseImages | Where-Object { $_.DirectoryName.Equals($dir.FullName, [System.StringComparison]::OrdinalIgnoreCase) })
            $workBatches.Add(@{ Images = $folderImages; Dir = $dir })
        }
    } elseif (-not $runLooseZip -and $looseImages.Count -gt 0 -and -not $script:abortRequested) {
        $workBatches.Add(@{ Images = $looseImages; Dir = $null })
    }

    # Dedicated cancellation source for the loose-image phase.
    # A fresh CTS is needed here because the ZIP-phase CTS is already disposed.
    $script:looseCts = [System.Threading.CancellationTokenSource]::new()

    foreach ($batch in $workBatches) {
        if ($script:abortRequested) { break }

        # Reset per-batch abort-tracking lists so the abort summary reflects
        # only the most recently active batch, not the entire run history.
        $lastLooseCompleted = [System.Collections.Generic.List[string]]::new()
        $lastLooseSkipped   = [System.Collections.Generic.List[string]]::new()
        $looseAbortedCount  = 0

        $batchImages = $batch.Images
        $batchDir    = $batch.Dir   # $null in mode 1

        if ($batchDir) {
            Write-Log ("=== Processing folder: '" + $batchDir.FullName + "' ===")
            if ($batchImages.Count -eq 0) {
                Write-Log ("  No unconverted images in this folder - skipping conversion, proceeding to zip check.")
            } else {
                Write-Log ("  Found " + $batchImages.Count + " image(s) to convert.")
            }
        }

        if ($batchImages.Count -gt 0) {

        # Poll for Ctrl+C / window-close once per dispatch pass, and snapshot
        # whichever jobs are in-flight at the exact moment abort is first
        # detected (used for the abort summary's "Last completed jobs" list).
        $looseAbortPoll = {
            param($InFlightPaths)
            $wasAbortedBeforeThisIteration = $script:abortRequested
            $null = Test-AbortSignal
            if ($script:abortRequested -and -not $wasAbortedBeforeThisIteration) {
                foreach ($p in $InFlightPaths) { $lastLooseCompleted.Add($p) }
            }
        }

        $batchResult = Convert-ImageBatch -ImageFiles $batchImages -CjxlExe $cjxl -MagickExe $magick `
            -DoJpegLossless $JpegLossless -DoJpegQuality $JpegQuality -MaxCjxlProcs $MaxCjxlProcs `
            -DoFullLogging $FullLogging -CancelToken $script:looseCts.Token -ItemNoun "loose image" `
            -SourceNoun "loose source image" -AbortPollCallback $looseAbortPoll `
            -AbortWaitMessage "[ABORT] Waiting for current loose-image jobs to finish (up to 60s)..."

        $stats.LooseImgConverted.Success += $batchResult.ConvertedCount
        $stats.LooseImgConverted.Fail    += $batchResult.FailedCount
        $stats.LooseImgConverted.Skipped += $batchResult.SkippedCount
        $stats.LooseImgDeleted.Success   += $batchResult.DeletedCount
        $stats.LooseImgDeleted.Fail      += $batchResult.DeleteFailedCount
        foreach ($p in $batchResult.SkippedPaths) { $lastLooseSkipped.Add($p) }
        $looseAbortedCount = $batchResult.ForceKilledCount
        $looseStillPendingPaths = $batchResult.PendingPaths

        } # end if ($batchImages.Count -gt 0)

        # ------------------------------------------------------------------
        #  Per-folder zip step (mode 2 only).
        #  Runs immediately after this folder's conversion completes, before
        #  moving to the next folder.  Skipped on abort.
        # ------------------------------------------------------------------
        if ($runLooseZip -and $batchDir -and -not $script:abortRequested) {
            $dirPath = $batchDir.FullName
            $dirName = $batchDir.Name
            $zipOut  = Join-Path $batchDir.Parent.FullName ($dirName + ".zip")

            # Check for remaining unconverted source images
            $remainingSrcImages = @(Get-ChildItem -LiteralPath $dirPath -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $looseFolderImgExts -icontains $_.Extension })

            if ($remainingSrcImages.Count -gt 0) {
                $nameList = ($remainingSrcImages | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ", "
                if ($remainingSrcImages.Count -gt 5) { $nameList += ", ..." }
                Write-Log ("SKIPPING zip of '" + $dirName + "': " + $remainingSrcImages.Count + " unconverted source image(s) still present (" + $nameList + "). Resolve conversion failures before zipping.") -Level Warn
                $stats.LooseFolderZipped.Skipped++
            } else {
                try {
                    Write-Log ("Re-zipping '" + $dirPath + "' -> '" + $zipOut + "'")

                    $zipSize = Compress-FolderToZip -SourceDir $dirPath -ZipOut $zipOut
                    $verify  = Test-ZipArchive -ZipPath $zipOut

                    Write-Log ("ZIP OK: '" + $zipOut + "' (" + $zipSize + " bytes, " + $verify.EntryCount + " entries)")
                    $stats.LooseFolderZipped.Success++

                    try {
                        Remove-Source $dirPath
                        $deleteDesc = if ($PermanentDelete) { "permanently" } else { "Recycle Bin" }
                        Write-Log ("Deleted folder (" + $deleteDesc + "): '" + $dirPath + "'")
                        $stats.LooseFolderDeleted.Success++
                    } catch {
                        Write-Log ("FAILED to delete folder '" + $dirPath + "': " + $_) -Level Error
                        $stats.LooseFolderDeleted.Fail++
                    }
                } catch {
                    Write-Log ("FAILED to zip folder '" + $dirPath + "': " + $_) -Level Error
                    $stats.LooseFolderZipped.Fail++
                }
            }
        }

    } # end foreach ($batch in $workBatches)

    # ------------------------------------------------------------------
    #  Post-loop summary / abort handling
    # ------------------------------------------------------------------
    if ($script:abortRequested) {
        # The abort summary label reflects which phase was active when abort
        # was detected.  Mode 2 (convert+zip) uses the combined label since
        # both conversion and zip stats may be partially populated.
        $abortPhaseLabel = if ($runLooseZip) { "loose-convert-and-zip phase" } else { "loose-image phase" }

        if ($stopwatch.IsRunning) { $stopwatch.Stop() }
        $looseAbortElapsed    = $stopwatch.Elapsed
        $looseAbortElapsedStr = "{0:D2}h {1:D2}m {2:D2}s" -f $looseAbortElapsed.Hours, $looseAbortElapsed.Minutes, $looseAbortElapsed.Seconds
        $abortTrigger2 = if ($script:ctrlCloseAbort) { "window close (X button)" } else { "Ctrl+C" }

        # Remaining queued (not yet started) jobs at the time of abort.
        # $looseStillPendingPaths may be $null if abort happened before any
        # batch's dispatch loop ran (e.g. during stale cleanup).
        $looseStillPending = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $looseStillPendingPaths) {
            foreach ($p in $looseStillPendingPaths) { $looseStillPending.Add($p) }
        }

        $looseAbortSummary = @(
            ("=== ABORTED (" + $abortPhaseLabel + ") ==="),
            ("Process was aborted by user (" + $abortTrigger2 + ")."),
            ("Time elapsed before abort  : " + $looseAbortElapsedStr),
            ("ZIPs Extracted      : Success = " + $stats.ZipExtracted.Success  + "  |  Failed = " + $stats.ZipExtracted.Fail),
            ("Img -> JXL Conv.    : Success = " + $stats.ImgConverted.Success  + "  |  Failed = " + $stats.ImgConverted.Fail + "  |  Skipped (animated) = " + $stats.ImgConverted.Skipped),
            ("Img Deleted         : Success = " + $stats.ImgDeleted.Success    + "  |  Failed = " + $stats.ImgDeleted.Fail),
            ("ZIPs Created        : Success = " + $stats.ZipCreated.Success    + "  |  Failed = " + $stats.ZipCreated.Fail),
            ("Folders Deleted     : Success = " + $stats.FolderDeleted.Success + "  |  Failed = " + $stats.FolderDeleted.Fail),
            ("Loose Img Conv.     : Success = " + $stats.LooseImgConverted.Success + "  |  Failed = " + $stats.LooseImgConverted.Fail + "  |  Skipped (animated) = " + $stats.LooseImgConverted.Skipped),
            ("Loose Img Deleted   : Success = " + $stats.LooseImgDeleted.Success   + "  |  Failed = " + $stats.LooseImgDeleted.Fail),
            ("Loose Stale Cleaned : Success = " + $stats.LooseStaleCleaned.Success + "  |  Failed = " + $stats.LooseStaleCleaned.Fail)
        )
        if ($runLooseZip) {
            $looseAbortSummary += ("Loose Folders Zipped: Success = " + $stats.LooseFolderZipped.Success  + "  |  Failed = " + $stats.LooseFolderZipped.Fail + "  |  Skipped (unconverted images) = " + $stats.LooseFolderZipped.Skipped)
            $looseAbortSummary += ("Loose Fldr Deleted  : Success = " + $stats.LooseFolderDeleted.Success + "  |  Failed = " + $stats.LooseFolderDeleted.Fail)
        }
        if ($lastLooseCompleted.Count -gt 0) {
            $looseAbortSummary += ("Last completed jobs (" + $lastLooseCompleted.Count + "):")
            foreach ($p in $lastLooseCompleted) { $looseAbortSummary += ("  " + $p) }
        } else {
            $looseAbortSummary += "Last completed jobs : (none)"
        }
        if ($lastLooseSkipped.Count -gt 0) {
            $looseAbortSummary += ("Skipped jobs (" + $lastLooseSkipped.Count + "):")
            foreach ($p in $lastLooseSkipped) { $looseAbortSummary += ("  " + $p) }
        } else {
            $looseAbortSummary += "Skipped jobs : (none)"
        }
        if ($looseAbortedCount -gt 0) {
            $looseAbortSummary += ("Forcefully aborted jobs : " + $looseAbortedCount + " job(s) did not finish within 60s.")
        } else {
            $looseAbortSummary += "Forcefully aborted jobs : none - all in-flight jobs completed cleanly."
        }
        if ($looseStillPending.Count -gt 0) {
            $looseAbortSummary += ("Not started (still pending) : " + $looseStillPending.Count + " job(s).")
        }
        $looseAbortSummary += "=== End of aborted run ==="

        Write-Host ""
        foreach ($line in $looseAbortSummary) { Write-Host $line -ForegroundColor Cyan }

        if ($FullLogging) {
            $ts2 = Get-Date -Format "yyyy-MM-dd HHmmss"
            foreach ($line in $looseAbortSummary) {
                $entry = $ts2 + " [Summary] " + $line
                $safe  = [System.Text.RegularExpressions.Regex]::Replace($entry, "[^\x00-\x7F]", "?")
                try { $safe | Out-File -FilePath $logFile -Append -Encoding ASCII } catch { }
            }
        } else {
            $runTs2     = Get-Date -Format "yyyy-MM-dd HHmmss"
            $block2     = @("", ("=== Run: " + $runTs2 + " ==="))
            $block2    += $looseAbortSummary
            $block2    += ""
            $safeBlock2 = $block2 | ForEach-Object {
                [System.Text.RegularExpressions.Regex]::Replace($_, "[^\x00-\x7F]", "?")
            }
            try {
                $existingText2 = ""
                if (Test-Path -LiteralPath $logSummaryFile) {
                    $existingText2 = [System.IO.File]::ReadAllText($logSummaryFile)
                }
                [System.IO.File]::WriteAllText($logSummaryFile, ($safeBlock2 -join "`r`n") + "`r`n" + $existingText2, [System.Text.Encoding]::ASCII)
            } catch { }
        }

        # Signal the ConsoleCtrl handler that the drain is complete
        [ConsoleCtrl]::DrainComplete.Set()
    }

    $script:looseCts.Dispose()

    } # end if ($runLooseConv)

    # ==========================================================================
    #  LOOSE FOLDER ZIP PHASE
    #  This phase is now handled inside the $runLooseConv block above (mode 2).
    #  The $runLooseZip flag is only set when $runLooseConv is also true, so
    #  this block is intentionally left empty - kept as a placeholder to avoid
    #  breaking any external references to the flag.
    # ==========================================================================
    if ($runLooseZip -and -not $runLooseConv) {
        # Should never be reached under current mode assignments, but handled
        # defensively: $runLooseZip without $runLooseConv has no defined
        # behaviour, so log a warning and skip.
        Write-Log "Loose folder zip requested without loose conversion - skipping (unsupported combination)." -Level Warn
    }
    # ==========================================================================
    #  SUMMARY  (only on clean/non-aborted runs; abort path already logged above)
    #  Only shows the row-groups relevant to what this run's mode actually did:
    #  $runZipPhase (mode 3) and $runLooseConv (modes 1/2) are mutually
    #  exclusive per the mode menu, so a given run never populates both the
    #  ZIP-pipeline rows and the Loose-pipeline rows - showing both sets
    #  every time just meant one set was always a wall of zeros.
    # ==========================================================================
    if (-not $script:abortRequested) {
        $stopwatch.Stop()
        $elapsed    = $stopwatch.Elapsed
        $elapsedStr = "{0:D2}h {1:D2}m {2:D2}s" -f $elapsed.Hours, $elapsed.Minutes, $elapsed.Seconds

        $summaryLines = [System.Collections.Generic.List[string]]::new()
        $summaryLines.Add("=== SUMMARY ===")

        if ($runZipPhase) {
            $summaryLines.Add("ZIPs Extracted      : Success = " + $stats.ZipExtracted.Success  + "  |  Failed = " + $stats.ZipExtracted.Fail)
            $summaryLines.Add("Img -> JXL Conv.    : Success = " + $stats.ImgConverted.Success  + "  |  Failed = " + $stats.ImgConverted.Fail + "  |  Skipped (animated) = " + $stats.ImgConverted.Skipped)
            $summaryLines.Add("Img Deleted         : Success = " + $stats.ImgDeleted.Success    + "  |  Failed = " + $stats.ImgDeleted.Fail)
            $summaryLines.Add("ZIPs Created        : Success = " + $stats.ZipCreated.Success    + "  |  Failed = " + $stats.ZipCreated.Fail)
            $summaryLines.Add("Folders Deleted     : Success = " + $stats.FolderDeleted.Success + "  |  Failed = " + $stats.FolderDeleted.Fail)
        }

        if ($runLooseConv) {
            $summaryLines.Add("Loose Img Conv.     : Success = " + $stats.LooseImgConverted.Success + "  |  Failed = " + $stats.LooseImgConverted.Fail + "  |  Skipped (animated) = " + $stats.LooseImgConverted.Skipped)
            $summaryLines.Add("Loose Img Deleted   : Success = " + $stats.LooseImgDeleted.Success   + "  |  Failed = " + $stats.LooseImgDeleted.Fail)
            $summaryLines.Add("Loose Stale Cleaned : Success = " + $stats.LooseStaleCleaned.Success + "  |  Failed = " + $stats.LooseStaleCleaned.Fail)
        }

        if ($runLooseZip) {
            $summaryLines.Add("Loose Folders Zipped: Success = " + $stats.LooseFolderZipped.Success  + "  |  Failed = " + $stats.LooseFolderZipped.Fail + "  |  Skipped (unconverted images) = " + $stats.LooseFolderZipped.Skipped)
            $summaryLines.Add("Loose Fldr Deleted  : Success = " + $stats.LooseFolderDeleted.Success + "  |  Failed = " + $stats.LooseFolderDeleted.Fail)
        }

        if ($runZipOnly) {
            $summaryLines.Add("Zip-only Zipped     : Success = " + $stats.ZipOnlyZipped.Success       + "  |  Failed = " + $stats.ZipOnlyZipped.Fail)
            $summaryLines.Add("Zip-only Fldr Del.  : Success = " + $stats.ZipOnlyFolderDeleted.Success + "  |  Failed = " + $stats.ZipOnlyFolderDeleted.Fail)
        }

        $summaryLines.Add("Time taken          : " + $elapsedStr)
        $summaryLines.Add("=== Processing complete ===")

        Write-Host ""
        foreach ($line in $summaryLines) { Write-Log $line -Level Summary }

        if ($FullLogging) {
            # In full-logging mode Write-Log already wrote every Summary line to the file
        } else {
            # In split-log mode, prepend the summary block to the Summary log
            Write-SummaryLog -Lines $summaryLines
        }

        # On a clean finish the state file is kept so the next run can skip
        # already-processed ZIPs.  Only ZIPs whose file date has changed
        # (i.e. overwritten with a new archive of the same name) will be
        # re-processed.  Delete the state file manually to force a full rescan.
        if (Test-Path -LiteralPath $stateFile) {
            Write-Log ("Resume state file retained for future runs: '" + $stateFile + "'") -Level Summary
        }
    }

} catch {
    # If the exception is a pipeline-stopped exception caused by our own abort
    # (e.g. PowerShell's internal Ctrl+C handling firing before our handler
    # suppresses it), treat it as a graceful abort rather than a fatal error.
    $exType = $_.Exception.GetType().FullName
    if ($script:abortRequested -and ($exType -like '*PipelineStoppedException*' -or $exType -like '*OperationCanceled*')) {
        # Abort already handled / being handled above — nothing more to do here.
        # Ensure DrainComplete is set so the ConsoleCtrl handler can unblock.
        try { [ConsoleCtrl]::DrainComplete.Set() } catch { }
    } else {
        $fatalMsg = "FATAL ERROR: " + $_.ToString() + "`r`nStack Trace:`r`n" + $_.ScriptStackTrace
        try {
            $safeMsg = [System.Text.RegularExpressions.Regex]::Replace($fatalMsg, "[^\x00-\x7F]", "?")
            if ($FullLogging) {
                $safeMsg | Out-File -FilePath $logFile -Append -Encoding ASCII
            } else {
                $safeMsg | Out-File -FilePath $logErrorFile -Append -Encoding ASCII
            }
        } catch { }
        Write-Host ("`r`n" + $fatalMsg) -ForegroundColor Red
    }
} finally {
    # Always make sure the ConsoleCtrl handler is unblocked before we exit,
    # in case an unhandled path skipped the DrainComplete.Set() calls above.
    try { [ConsoleCtrl]::DrainComplete.Set() } catch { }

    if ($FullLogging) {
        Write-Host ("`r`nLog file: " + $logFile) -ForegroundColor Green
    } else {
        Write-Host "`r`nLog files:" -ForegroundColor Green
        Write-Host ("  Summary  : " + $logSummaryFile) -ForegroundColor Green
        if (Test-Path -LiteralPath $logErrorFile)  { Write-Host ("  Errors   : " + $logErrorFile)  -ForegroundColor Green }
        if (Test-Path -LiteralPath $logWarnFile)   { Write-Host ("  Warnings : " + $logWarnFile)   -ForegroundColor Green }
    }

    # For X-button close: the window is going away; no point waiting for a keypress.
    # For Ctrl+C or normal exit: pause so the user can read the output.
    if (-not $script:ctrlCloseAbort) {
        if ($script:abortRequested) {
            Write-Host "`n[ABORT] Process stopped. Press any key to close..." -ForegroundColor Yellow
        } else {
            Write-Host "Press any key to exit..." -ForegroundColor Yellow
        }

        try {
            # After Ctrl+C the console input pipeline may be in a disrupted state.
            # Re-arm it before calling ReadKey:
            #   1. Stop PowerShell's own Ctrl+C handling so a second Ctrl+C press
            #      while waiting doesn't kill the process immediately.
            #   2. Flush any queued keystrokes (the Ctrl+C itself often sits in the
            #      buffer and would satisfy ReadKey instantly without this).
            [Console]::TreatControlCAsInput = $true
            try {
                while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }
            } catch { }

            # ReadKey with a tight polling loop so a broken RawUI falls back cleanly.
            $gotKey = $false
            $keyDeadline = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $gotKey) {
                try {
                    if ([Console]::KeyAvailable) {
                        $null = [Console]::ReadKey($true)
                        $gotKey = $true
                    } else {
                        Start-Sleep -Milliseconds 50
                    }
                } catch {
                    # Console may not be interactive (e.g. redirected); break out.
                    $gotKey = $true
                }
                # Safety valve: never loop forever if the console is non-interactive.
                if ($keyDeadline.Elapsed.TotalSeconds -ge 300) { $gotKey = $true }
            }
        } catch {
            # Absolute last resort.
            try { Read-Host "Press Enter to exit" } catch { }
        } finally {
            # Restore normal Ctrl+C behaviour now that we're about to exit anyway.
            try { [Console]::TreatControlCAsInput = $false } catch { }
        }
    }
}