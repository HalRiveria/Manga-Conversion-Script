# Manga Conversion Toolkit

Personal automation for maintaining a large manga/comic library: converting
images to JPEG XL (`.jxl`), archiving folders into `.zip`, and (soon)
converting animated AVIF to WebP. Built and iterated on with Claude as a
development/debugging partner.

**Status: active rewrite in progress.** The project is moving from a single
large script toward independently-built-and-tested modules that get merged
into a shipped script only once each is verified working on its own. See
`CLAUDE.md` for full working context if you're picking this up in a new
session (human or Claude Code), and `CHANGELOG.md` for full version history.

## What's in this repo

| File | What it does |
|---|---|
| `Conversion Script Main.ps1` | Main conversion script (currently v16.1). Extracts ZIPs, converts images to `.jxl`, re-zips, handles loose files, zip-only archiving. Four modes: loose-only, loose+zip, zip-only, rezip-only. |

`Modules\` holds every standalone module built per the development process
below - not yet merged into the main script, or (once merged) kept around
as the canonical, independently-testable definition. Ten are actually
built and tested (`ZipParallelProcessing`, `AbortPipeline`, `Logging`,
`FileDeletion`, `DependencyDetection`, `ZipCreation`, `ZipValidation`,
`LeafDirectoryDiscovery`, `ZipPipeline`, `CleanConsoleRendering`); the
other six are empty placeholders with a corresponding extraction in
`Modules\_Reference\` (`ImageConversionPipeline.ps1` is a third
state - a real but untested/uncommitted draft, paused mid-build - see
`CLAUDE.md`'s "Clean Console Output" section) - see `Todo.md` for the
current state of each:

| File | What it does |
|---|---|
| `Modules\ZipParallelProcessing.ps1` | `Invoke-ZipParallelProcessing`, the parallel-dispatch engine for the zip-only pipeline (mode 3) - pure definitions, no top-level side effects, safe to dot-source. Renamed from `Invoke-ParallelFolderJobs`/`InvokeParallelFolderJobs.ps1` since it's currently zip-specific; the main script's own inline copy of the same algorithm still uses the older name until mode 3 (and eventually mode 4) migrates onto this module - see its file header. Has its own inline (and partly stale) copies of logic `Logging`/`AbortPipeline` now own - see `CLAUDE.md`'s "Known gaps". |
| `Modules\AbortPipeline.ps1` | Standalone module (not yet merged into the main script): the Ctrl+C/window-close abort pipeline - `ConsoleCtrl`, abort-state tracking, a CTS registry, and a generalized graceful-drain/force-stop function - centralizing logic currently duplicated across modes 3/4 in the main script. |
| `Modules\Logging.ps1` | `Write-Log`, `Write-SummaryLog`, `Flush-ConsoleQueue`, plus `Initialize-LogPaths` (call once before anything logs). Includes a `-DisableSummaryFile` toggle (split-log mode only), abandoned-mutex recovery, UTF-8 log encoding, Recycle-Bin cleanup of old full-logging-mode log files, and `Initialize-LogMutex` for the shared log-mutex naming convention. |
| `Modules\FileDeletion.ps1` | `Move-ToRecycleBin`, `Remove-ItemPermanently`, and `Remove-Source` (the wrapper every mode calls, routing based on `Initialize-FileDeletion -PermanentDelete`). |
| `Modules\DependencyDetection.ps1` | `Find-Exe` - generalized cjxl/magick/ffmpeg executable locator (`-UserPath` > PATH > `-Candidates`), not separate per-tool wrapper functions. |
| `Modules\ZipCreation.ps1` | `Compress-FolderToZip` - creates a ZIP from a folder, clearing any pre-existing same-name ZIP first and cleaning up stray output if creation fails partway through. |
| `Modules\ZipValidation.ps1` | `Test-ZipArchive` - post-creation sanity check (entry count, optional required `.jxl` presence). No cross-module dependencies. |
| `Modules\LeafDirectoryDiscovery.ps1` | `Get-ZippableLeafDirs` - shared leaf-folder scan (mode 2/3) with staleness and former-container guards; its harness live-reproduces the historical "parent folder gets zipped" bug from `CHANGELOG.md` for the first time and confirms the fix works. Also `New-ZippableLeafDirProvider`, an incremental alternative that lets dispatch start on the first qualifying folder while a large tree is still being scanned, instead of the whole tree needing to finish first. |
| `Modules\ZipPipeline.ps1` | `Invoke-ZipOnlyPipeline` (mode 3 end to end) and `Invoke-LooseFolderZip` (mode 2's per-folder zip step) - the first orchestration-tier module, tested as a real integration harness against the other six built modules together rather than stubs. |
| `Modules\CleanConsoleRendering.ps1` | The "Clean Console Output" toggle's renderer - live per-series/chapter progress display, replacing default per-file console spam (log files unaffected). Zero forward references, like `DependencyDetection.ps1`. Falls back to plain sequential printing when real console cursor control isn't available (confirmed via a live probe that this throws in non-interactive/redirected contexts) rather than crashing a run. |
| `Modules\_Harness\*.Harness.ps1` | Standalone test harness per built module - dot-sources the real module from `..\`. |
| `Modules\_Reference\*.reference.ps1` | Extracted-but-not-yet-built reference material for every module, including the two above - not working code, see `CLAUDE.md`'s "Modularization in progress" section. |

Earlier working scripts, including the standalone `Zip_Files-claude-parallel.ps1`
that the staleness-check and former-container-guard logic were ported from,
live in `Backups\Old Scripts\` - kept for reference, not tracked in git (see
folder layout below).

## Requirements

- Windows PowerShell 5.1 (all scripts are written for 5.1 compatibility, not PowerShell 7+ only features)
- [cjxl](https://github.com/libjxl/libjxl) (JPEG XL encoder)
- [ImageMagick](https://imagemagick.org/) (for WebP/ICC-profile pre-processing)

## Folder layout (local, not all tracked)

```
Conversion Script/
├── .git/
├── .gitignore
├── README.md
├── CLAUDE.md              <- persistent context for Claude Code sessions
├── CHANGELOG.md           <- full version history (v1.0 → v16.1)
├── Todo.md                <- live modularization checklist
├── Conversion Script Main.ps1
├── Modules/               <- every standalone module lives here
│   ├── ZipParallelProcessing.ps1
│   ├── AbortPipeline.ps1
│   ├── Logging.ps1
│   ├── FileDeletion.ps1
│   ├── DependencyDetection.ps1
│   ├── ZipCreation.ps1
│   ├── ZipValidation.ps1
│   ├── LeafDirectoryDiscovery.ps1
│   ├── ZipPipeline.ps1
│   ├── CleanConsoleRendering.ps1
│   ├── ImageConversionPipeline.ps1 (untested draft, paused mid-build)
│   ├── (6 more placeholder modules - see Todo.md)
│   ├── _Harness/          <- test harness per built module
│   └── _Reference/        <- extracted reference material per module
├── Testing/               <- scratch copy scripts run against (gitignored)
└── Backups/               <- original test media, never touched by scripts (gitignored)
    └── Old Scripts/       <- earlier working versions, kept for reference
```

`Backups/` holds source images/AVIFs kept safe from any script - copied into
`Testing/` before a run - plus `Old Scripts/`, earlier working script
versions kept for reference. Nothing under `Backups/` or `Testing/` is
tracked in git: the former is binary test media and superseded code, not
current source; the latter is regenerated scratch content.

## Development approach

New functionality is built as an independent module first (its own file,
its own test harness, living in `Modules\`), verified working in isolation,
and only merged into the main script once proven. `Invoke-ZipParallelProcessing`
(`Modules\ZipParallelProcessing.ps1`) is the first example of this pattern -
not a one-off, the intended process going forward.

Testing is currently manual: standalone test harnesses run directly
(`.\Modules\_Harness\ZipParallelProcessing.Harness.ps1 -RunSlowTest`), since there's
no CI runner configured against this local-only repo yet.

## Known open items

- Mode 3 (zip-only pipeline) still has its own inline copy of the parallel-
  dispatch algorithm (under the name `Invoke-ParallelFolderJobs`) instead of
  dot-sourcing `Modules\ZipParallelProcessing.ps1`'s `Invoke-ZipParallelProcessing` -
  migration planned, not yet done. Mode 4 (rezip/ZIP-extraction pipeline)
  has its own separate inline copy of the same kind of dispatch logic too -
  also not yet migrated onto the module.
- A narrow race condition exists in the main script's inline
  `Invoke-ParallelFolderJobs` abort-drain logic (a job finishing in the
  final ~250ms before the 60s force-stop timeout can have its result
  silently dropped) - documented, and fixed in
  `Modules\ZipParallelProcessing.ps1`'s rewrite of the same logic, but the
  main script's copy hasn't been migrated to use it yet.
- `Modules\AbortPipeline.ps1` centralizes the abort/graceful-drain logic
  that's currently duplicated (with variations) across the main script's
  inline `Invoke-ParallelFolderJobs`, the ZIP-extraction pipeline's inline
  dispatch loop, and the loose-image pipeline. Built and verified
  standalone; not yet wired into the main script.
- AVIF→WebP conversion pipeline not yet integrated (separate existing script
  to be merged in).

## Language

PowerShell (5.1-compatible), settled - not switching to Python. The repo/
local-git setup gives real version history and lets modules be built and
tested in isolation before merging, which was the main advantage Python
would have offered; staying in PowerShell keeps the zero-install-friction
Windows-native tooling (Recycle Bin integration, `SetConsoleCtrlHandler` for
robust Ctrl+C/window-close handling) that a Python rewrite would have had to
reproduce.

## License / scope

Personal-use tooling, not published or intended for general distribution.