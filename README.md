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
| `Conversion Script Main.ps1` | Main conversion script (currently v16.0). Extracts ZIPs, converts images to `.jxl`, re-zips, handles loose files, zip-only archiving. Four modes: loose-only, loose+zip, zip-only, rezip-only. |
| `Test-InvokeParallelFolderJobs.ps1` | Standalone test harness for `Invoke-ParallelFolderJobs`, the shared parallel-dispatch module. Copies the real function verbatim (not reimplemented) so it tests actual behavior, not a guess at it. |

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
├── CHANGELOG.md           <- full version history (v1.0 → v16.0)
├── Conversion Script Main.ps1
├── Test-InvokeParallelFolderJobs.ps1
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
its own test harness), verified working in isolation, and only merged into
the main script once proven. `Invoke-ParallelFolderJobs` / its test harness
is the first example of this pattern - not a one-off, the intended process
going forward.

Testing is currently manual: standalone `Test-*.ps1` harnesses run directly
(`.\Test-InvokeParallelFolderJobs.ps1 -RunSlowTest`), since there's no CI
runner configured against this local-only repo yet.

## Known open items

- Mode 4 (rezip/ZIP-extraction pipeline) still uses its own inline parallel-
  dispatch logic rather than `Invoke-ParallelFolderJobs` - migration planned,
  not yet done.
- A narrow race condition exists in `Invoke-ParallelFolderJobs`'s abort-drain
  logic (a job finishing in the final ~250ms before the 60s force-stop
  timeout can have its result silently dropped) - documented, not yet fixed.
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