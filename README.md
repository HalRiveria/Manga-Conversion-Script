# Manga Conversion Toolkit

Personal automation for maintaining a large manga/comic library: converting
images to JPEG XL (`.jxl`), archiving folders into `.zip`, and (soon)
converting animated AVIF to WebP. Built and iterated on with Claude as a
development/debugging partner.

**Status: standalone-build phase done, main-script rewrite not started.**
The project is moving from a single large script toward independently-
built-and-tested modules that get merged into a shipped script only once
each is verified working on its own. **All 18 planned modules are now
built and tested** (20/20 harnesses, 791+ assertions) - none are merged
into the main script yet, which stays frozen until that rewrite starts.
See `CLAUDE.md` for full working context if you're picking this up in a
new session (human or Claude Code), `Todo.md` for the live tracker, and
`CHANGELOG.md` for full version history.

## What's in this repo

| File | What it does |
|---|---|
| `Conversion Script Main.ps1` | Main conversion script (currently v16.1), FROZEN - no edits until the module rewrite starts. Extracts ZIPs, converts images to `.jxl`, re-zips, handles loose files, zip-only archiving. Four modes: loose-only, loose+zip, zip-only, rezip-only. |

`Modules\` holds all 18 standalone modules built per the development
approach below - not yet merged into the main script. Each is a
self-contained `.ps1` (pure function definitions, no top-level side
effects) with its own test harness in `Modules\_Harness\`. Full detail on
every module - real design decisions made, bugs found and fixed, forward
references - lives in `CLAUDE.md`; this table is a quick map, not the
full story:

| File | What it does |
|---|---|
| `Modules\Logging.ps1` | `Write-Log`, `Write-SummaryLog`, `Flush-ConsoleQueue`, `Initialize-LogPaths`/`Initialize-LogMutex`/`Initialize-CleanConsoleOutput`. Nearly every other module forward-references this one. |
| `Modules\FileDeletion.ps1` | `Move-ToRecycleBin`, `Remove-ItemPermanently`, `Remove-Source` (the wrapper every mode calls, routing on `Initialize-FileDeletion -PermanentDelete`). |
| `Modules\AbortPipeline.ps1` | The Ctrl+C/window-close abort pipeline - `ConsoleCtrl`, a CTS registry, `Invoke-GracefulDrain` (generalized graceful-drain/force-stop, fixes a race the main script's own inline copies still have). |
| `Modules\DependencyDetection.ps1` | `Find-Exe` (generalized cjxl/magick locator) and `Find-ExeCached` (checks a cached path in a settings hashtable before searching again). |
| `Modules\ZipCreation.ps1` | `Compress-FolderToZip` - creates a ZIP from a folder, clearing any pre-existing same-name ZIP first. |
| `Modules\ZipValidation.ps1` | `Test-ZipArchive` - post-creation sanity check (entry count, optional required `.jxl` presence). |
| `Modules\LeafDirectoryDiscovery.ps1` | `Get-ZippableLeafDirs`/`New-ZippableLeafDirProvider` (incremental leaf-folder scan) plus `New-SeriesProvider`/`Get-SeriesChapters` (two-tier series/chapter discovery for Clean Console Output). |
| `Modules\ZipParallelProcessing.ps1` | `Invoke-ZipParallelProcessing` - the parallel-dispatch engine used by the zip pipelines; the main script's own inline copy (`Invoke-ParallelFolderJobs`) hasn't migrated onto it yet. |
| `Modules\CleanConsoleRendering.ps1` | The Clean Console Output renderer - live per-series/chapter progress display replacing per-file console spam (log files unaffected). |
| `Modules\ZipPipeline.ps1` | `Invoke-ZipOnlyPipeline` (mode 3) and `Invoke-LooseFolderZip` (mode 2's zip step) - zip-domain orchestration. |
| `Modules\ImageConversionPipeline.ps1` | `Convert-ImageBatch` (shared batch conversion engine) and `Invoke-LooseImageConversionPipeline` (mode 1 end to end, Clean Console Output-integrated). |
| `Modules\Config.ps1` | Settings schema + `Import-/Export-ScriptSettings` at `%LOCALAPPDATA%\ConversionScript\settings.json`, with per-key validation and corrupt-file recovery. |
| `Modules\Menu.ps1` | `Get-SelectedMode`/`Show-ModeMenu` (mode-selection prompt) and `Show-OptionsMenuLevel` (data-driven options-menu renderer). |
| `Modules\Summary.ps1` | The clean-run summary report - `New-StatsTracker`, `Format-ElapsedTime`, `Get-SummaryLines`/`Write-SummaryReport`. |
| `Modules\ResumeState.ps1` | Tracks which ZIPs the rezip pipeline has already completed, so a re-run can skip them. |
| `Modules\RezipPipeline.ps1` | `Invoke-RezipPipeline` - mode 9 ("Convert Zipped"), deprecated/legacy, minimal-effort build. |
| `Modules\AnimatedConversionPipeline.ps1` | `Convert-AnimatedBatch` - AVIF→WebP batch conversion (the primitive only; no library-walking orchestrator yet). |
| `Modules\UnwantedImage.ps1` | Detects/deletes known unwanted images by size+dimensions+hash match, plus a trailing-zero-filename audit and a real profile-persistence feature (`Add-UnwantedImageProfileFromFile`). |
| `Modules\_Harness\*.Harness.ps1` | Standalone test harness per module - dot-sources the real module from `..\`. |
| `Modules\_Reference\*.reference.ps1` | The extraction each module was built FROM - historical build input, not pending work (16 of 18 modules have one; `ZipParallelProcessing`/`CleanConsoleRendering` legitimately don't). |

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
├── Modules/               <- every standalone module lives here (all 18 built)
│   ├── Logging.ps1
│   ├── FileDeletion.ps1
│   ├── AbortPipeline.ps1
│   ├── DependencyDetection.ps1
│   ├── ZipCreation.ps1
│   ├── ZipValidation.ps1
│   ├── LeafDirectoryDiscovery.ps1
│   ├── ZipParallelProcessing.ps1
│   ├── CleanConsoleRendering.ps1
│   ├── ZipPipeline.ps1
│   ├── ImageConversionPipeline.ps1
│   ├── Config.ps1
│   ├── Menu.ps1
│   ├── Summary.ps1
│   ├── ResumeState.ps1
│   ├── RezipPipeline.ps1
│   ├── AnimatedConversionPipeline.ps1
│   ├── UnwantedImage.ps1
│   ├── _Harness/          <- test harness per module
│   └── _Reference/        <- extraction each module was built from
├── Tools/
│   └── Run-Harness.ps1    <- runs one or all harnesses, compresses output to
│                              PASS/FAIL summaries instead of every assertion line
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

The frozen main script still runs on its own original inline logic
throughout (parallel dispatch, abort/drain, everything) - none of the 18
built modules are wired into it yet; that's the main-script rewrite,
still not started. Beyond that, a handful of real open items remain even
within the standalone modules themselves - see `CLAUDE.md`'s "Known
gaps / open work" section for the current, maintained list (things like:
`AnimatedConversionPipeline.ps1` is a batch-conversion primitive only,
no library-walking orchestrator yet; `UnwantedImage.ps1` has no `Menu.ps1`
entry wired in yet; a couple of small cross-module consistency questions
flagged but deliberately deferred). Not duplicated here since it changes
often enough that a second copy would just go stale.

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