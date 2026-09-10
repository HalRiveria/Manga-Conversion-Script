# Manga Conversion Toolkit

Personal automation for maintaining a large manga/comic library: extracting
ZIPs, converting images to JPEG XL (`.jxl`), re-zipping, handling loose
files, and converting animated AVIF to WebP. Built and iterated on with
Claude as a development/debugging partner.

**Status: the rewrite is done and live.** `Conversion Script Main.ps1` is
the real, actively-edited script - no longer frozen. It bootstraps (finds
`Modules\`, loads settings, resolves `cjxl`/`magick`) and hands off to
`Controller.ps1`'s `Invoke-MainLoop`. All 18 modules are built, tested, and
wired in (21/21 harnesses - see `.\Tools\Run-Harness.ps1 -All` for the
current assertion count, it drifts as coverage grows). The old monolithic
script moved to `Modules\_Reference\Conversion Script Main - Old.ps1`, kept
frozen as a reference copy. See `CLAUDE.md` for full working context if
you're picking this up in a new session (human or Claude Code), `Todo.md`
for the live tracker, and `CHANGELOG.md` for full version history.

## What's in this repo

| File | What it does |
|---|---|
| `Conversion Script Main.ps1` | The live script - bootstrap (module discovery, settings, dependency resolution) plus one call into `Controller.ps1`'s `Invoke-MainLoop`. Interactive mode menu: Full Pipeline, Image Conversion, Animated Conversion, Zip Folders, Cover Deletion, Image Conversion + Zip. |

`Modules\` holds all 18 standalone modules - each a self-contained `.ps1`
(pure function definitions, no top-level side effects) with its own test
harness in `Modules\_Harness\`. Full detail on every module - real design
decisions made, bugs found and fixed, forward references - lives in
`CLAUDE.md`; this table is a quick map, not the full story:

| File | What it does |
|---|---|
| `Modules\Logging.ps1` | `Write-Log`, `Write-SummaryLog`, `Flush-ConsoleQueue`, `Initialize-LogPaths`/`Initialize-LogMutex`/`Initialize-CleanConsoleOutput`/`Start-LogRun`/`Complete-LogRun`. Nearly every other module forward-references this one. |
| `Modules\FileDeletion.ps1` | `Move-ToRecycleBin`, `Remove-ItemPermanently`, `Remove-Source` (the wrapper every mode calls, routing on `Initialize-FileDeletion -PermanentDelete`). |
| `Modules\AbortPipeline.ps1` | The Ctrl+C/window-close abort pipeline - `ConsoleCtrl`, a CTS registry, `Invoke-GracefulDrain` (graceful-drain/force-stop), `Invoke-AbortOrFatalHandler`. |
| `Modules\DependencyDetection.ps1` | `Find-Exe` (generalized cjxl/magick locator) and `Find-ExeCached` (checks a cached path in a settings hashtable before searching again). |
| `Modules\ZipCreation.ps1` | `Compress-FolderToZip` - creates a ZIP from a folder, clearing any pre-existing same-name ZIP first. |
| `Modules\ZipValidation.ps1` | `Test-ZipArchive` - post-creation sanity check (entry count, optional required `.jxl` presence). |
| `Modules\LeafDirectoryDiscovery.ps1` | `Get-ZippableLeafDirs`/`New-ZippableLeafDirProvider` (incremental leaf-folder scan) plus `New-SeriesProvider`/`Get-SeriesChapters` (two-tier series/chapter discovery for Clean Console Output). |
| `Modules\ZipParallelProcessing.ps1` | `Invoke-ZipParallelProcessing` - the shared runspace-pool dispatcher used by `ZipPipeline.ps1` and `Controller.ps1`. |
| `Modules\CleanConsoleRendering.ps1` | The Clean Console Output renderer - live per-series/chapter progress display replacing per-file console spam (log files unaffected). |
| `Modules\ZipPipeline.ps1` | `Invoke-ZipOnlyPipeline` (mode "Zip Folders") and `Invoke-LooseFolderZip` (mode "Image Conversion + Zip"'s zip step) - zip-domain orchestration. |
| `Modules\ImageConversionPipeline.ps1` | `Convert-ImageBatch` (shared batch conversion engine) and `Invoke-LooseImageConversionPipeline` (mode "Image Conversion" end to end, Clean Console Output-integrated). |
| `Modules\Config.ps1` | Settings schema + `Import-/Export-ScriptSettings` at `%LOCALAPPDATA%\ConversionScript\settings.json`, with per-key validation and corrupt-file recovery. |
| `Modules\Menu.ps1` | `Get-SelectedMode`/`Show-ModeMenu` (mode-selection prompt, including the Cover Deletion submenu) and `Show-OptionsMenuLevel` (data-driven options-menu renderer). |
| `Modules\Summary.ps1` | The clean-run summary report - `New-StatsTracker`, `Format-ElapsedTime`, `Get-SummaryLines`/`Write-SummaryReport`. |
| `Modules\ChapterDispatch.ps1` | `Invoke-ChapterDispatch` - the generalized process-dispatch/abort/drain primitive all three real conversion entry points (modes 1, 2, 3) now run on, letting idle concurrency pick up the next chapter's work instead of blocking. |
| `Modules\AnimatedConversionPipeline.ps1` | `Convert-AnimatedBatch` (AVIF→WebP batch conversion engine) plus `Invoke-LooseAnimatedConversionPipeline` (mode "Animated Conversion" end to end). |
| `Modules\UnwantedImage.ps1` | Detects/deletes known unwanted images by size+dimensions+hash match, a trailing-zero-filename audit, and profile persistence (`Add-UnwantedImageProfileFromFile`). |
| `Modules\Controller.ps1` | Full Pipeline's two-engine dispatch (image + animated conversion each running their own chapter walk concurrently, sharing one process budget, zips only when both succeed) plus the real top-level dispatcher (`Invoke-Mode`/`Invoke-MainLoop`). |
| `Modules\_Harness\*.Harness.ps1` | Standalone test harness per module - dot-sources the real module from `..\`. |
| `Modules\_Reference\*.reference.ps1` | The extraction each module was built FROM - historical build input, not pending work (14 of 18 modules have one; `ZipParallelProcessing`, `CleanConsoleRendering`, `Controller.ps1`, and `ChapterDispatch.ps1` legitimately don't). |

Earlier working scripts, including the standalone `Zip_Files-claude-parallel.ps1`
that the staleness-check and former-container-guard logic were ported from,
live in `Backups\Old Scripts\` - kept for reference, not tracked in git (see
folder layout below).

## Requirements

- Windows PowerShell 5.1 (all scripts are written for 5.1 compatibility, not PowerShell 7+ only features)
- [cjxl](https://github.com/libjxl/libjxl) (JPEG XL encoder)
- [ImageMagick](https://imagemagick.org/) (for WebP/ICC-profile pre-processing and animated AVIF handling)

**Thread count vs. RAM (animated conversion):** the animated-AVIF-to-WebP
step (`magick ... -coalesce`) decodes every frame of the source
animation into memory to reassemble it - a real, large multi-frame AVIF
can need a lot of RAM per file, and that scales with how many run
concurrently. Live-measured on this project's own real animated test
library: 12 concurrent animated conversions pushed system RAM usage from
a ~20GB baseline up to ~60GB, transiently, for the duration of the run -
not a leak, it releases back down the moment each conversion finishes.
Worth keeping in mind when raising the animated-conversion thread count
setting on a machine with less RAM to spare, or when the library being
converted skews toward large/long animated files.

## Folder layout (local, not all tracked)

```
Conversion Script/
├── .git/
├── .gitignore
├── README.md
├── CLAUDE.md              <- persistent context for Claude Code sessions
├── CHANGELOG.md           <- full version history (v1.0 → v16.1, plus the rewrite's own build history)
├── Todo.md                <- live tracker: open items, not-yet-built ideas
├── Docs/                  <- extracted reference material (lessons learned, repo guard, backups, module loading, Clean Console Output, menu/full-pipeline design)
├── Conversion Script Main.ps1   <- the live script: bootstrap + Invoke-MainLoop
├── Modules/               <- all 18 built modules live here
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
│   ├── ChapterDispatch.ps1
│   ├── AnimatedConversionPipeline.ps1
│   ├── UnwantedImage.ps1
│   ├── Controller.ps1
│   ├── _Harness/          <- test harness per module, plus GuardRules/Lint/MainLoopIntegration
│   └── _Reference/        <- extraction each module was built from, plus the frozen old monolithic script
├── Tools/
│   ├── Run-Harness.ps1    <- runs one or all harnesses, compresses output to
│   │                          PASS/FAIL summaries instead of every assertion line
│   ├── Backup-Repo.ps1    <- pushes to the E: backup mirror, reads it back to confirm
│   └── PreToolUse-Guard.ps1  <- repo guard hook, see Docs/repo-guard.md
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
and only merged into the main script once proven. That's how all 19
current modules were built, and it's still the process for anything new.

Testing is manual: `.\Tools\Run-Harness.ps1 -All` runs every harness and
compresses output to PASS/FAIL summaries (full output still shown on
failure); there's no CI runner configured against this local-only repo.

## Known open items

See `CLAUDE.md`'s "Known gaps / open work" section for the current,
maintained list of real open items (a couple of cosmetic-only display
limitations, a design point deliberately left as-is, and similar) - not
duplicated here since it changes often enough that a second copy would go
stale.

## Language

PowerShell (5.1-compatible), settled - not switching to Python. Real
version history now comes from git itself, which was the strongest
argument for Python; staying in PowerShell keeps the zero-install-friction
Windows-native tooling (Recycle Bin integration via
`Microsoft.VisualBasic.FileIO`, `SetConsoleCtrlHandler` for robust
Ctrl+C/window-close handling) that a Python rewrite would have had to
reproduce.

## License / scope

Personal-use tooling, not published or intended for general distribution.
