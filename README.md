# Manga Conversion Toolkit

A Windows PowerShell tool for keeping a large manga/comic library small and
tidy. It converts loose chapter images to [JPEG XL](https://jpegxl.info/)
(`.jxl`), converts animated AVIF files to animated WebP, zips each finished
chapter folder, and can sweep out known unwanted images (scanlator credit
pages and the like) before it starts.

It works on a library laid out as folders: `Library\Series\Chapter\images`.
Everything runs from one interactive menu.

## Features

- **Full Pipeline:** one pass over the whole library. Each chapter's images
  are converted to JPEG XL and its animated AVIFs to WebP, then the chapter
  is zipped and the folder removed. A chapter is only zipped if every file in
  it converted cleanly. Anything that failed, or needs a decision from you,
  is left untouched for the next run.
- **Individual steps:** Image Conversion, Animated Conversion and Zip
  Folders can each run on their own.
- **Cover Deletion:** finds and deletes images you've taught it to recognise
  (by size, dimensions and file hash), with a dry-run mode and a report of
  suspicious "trailing-zero" file names.
- **Parallel:** converts many files at once, with configurable process
  counts. Image and animated conversion run side by side in Full Pipeline,
  sharing one process limit.
- **Safe to stop:** Ctrl+C or closing the window lets the files already in
  progress finish, cleans up anything half-written, and stops. Converter
  processes never outlive the script, even if the window is force-closed.
- **Careful with your files:** originals go to the Recycle Bin by default
  (permanent delete is an option), the tool refuses to start on a drive
  with no Recycle Bin unless you've turned permanent delete on, and every
  zip is verified before its folder is deleted.
- **Clean Console Output:** an optional live progress view per series,
  instead of a line per file. The log files still get every detail.
- **Settings remembered** between runs, editable from an options menu.
- **Keeps the PC awake** while a run is going (idle sleep only), and lets it
  sleep normally at the menu.

### File formats

| Input | Becomes |
|---|---|
| `.jpg`, `.jpeg` | `.jxl` (quality 90 by default, or lossless JPEG recompression) |
| `.png`, `.webp`, `.bmp`, `.heic`, `.heif`, static `.avif` | `.jxl` (quality 90) |
| animated `.avif` | animated `.webp` |
| animated `.webp`, `.gif` | left as they are |

## Requirements

- Windows with **Windows PowerShell 5.1** (built into Windows 10 and 11).
  PowerShell 7 isn't supported.
- **cjxl**, the JPEG XL encoder from [libjxl](https://github.com/libjxl/libjxl/releases).
- **ImageMagick 7** ([download](https://imagemagick.org/script/download.php#windows)).
  Needed for Full Pipeline and Animated Conversion, and for any non-JPEG/PNG
  input.

## Install

1. Install the two tools. The quickest way is winget, from any terminal:

   ```powershell
   winget install libjxl.libjxl
   winget install ImageMagick.ImageMagick
   ```

   Or use the installers linked above. For libjxl, unzip a Windows release
   somewhere such as `C:\Program Files\libjxl\`.
2. Open a new terminal so the tools are on your `PATH`.
3. Download or clone this repository. Keep `Conversion Script Main.ps1` and
   the `Modules` folder together.
4. If Windows blocks the script because it was downloaded, right-click
   `Conversion Script Main.ps1` → Properties → tick **Unblock**, or run
   `Unblock-File` on the folder's `.ps1` files.

The script looks for `cjxl` and `magick` on your `PATH` and in the usual
install folders. If it can't find one, pass the path once with `-CjxlPath` or
`-MagickPath`. It remembers the location after that.

## Usage

Run it from PowerShell, pointing it at your library folder:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Conversion Script Main.ps1" -Path "D:\Manga"
```

Without `-Path`, it works on the current folder.

### Library layout

```
D:\Manga\
├── Series A\
│   ├── Chapter 001\   <- images
│   ├── Chapter 002\
│   └── Chapter 003.zip   (already done - skipped)
└── Some Category\     <- optional grouping folders are fine
    └── Series B\
        └── Chapter 01\
```

Each folder of images is treated as one chapter and becomes one `.zip` next
to it.

### The menu

```
1 - Full Pipeline         convert images and animated files, then zip
2 - Image Conversion      convert loose images only; no zipping
3 - Animated Conversion   convert animated AVIFs only; no zipping
4 - Zip Folders           zip folders that are already converted
5 - Cover Deletion        scan for and remove known unwanted images
0 - Options               change settings (saved for future runs)
```

After each run you get a summary. Press any key to go back to the menu, or
Esc to exit.

### Options worth knowing

- **Permanent Delete:** off by default, so originals go to the Recycle Bin.
  Turn it on only if you're sure, or if the library is on a drive without a
  Recycle Bin (network shares, most removable drives).
- **Process counts:** how many converters run at once. Animated conversion
  can use a lot of memory per file (a long animated AVIF is decoded frame
  by frame), so raise that one carefully on a machine with limited RAM.
- **JPEG quality / lossless:** JPEGs are converted at quality 90 by
  default. The lossless toggle recompresses them with no quality loss
  instead, at a larger size.
- **Full Pipeline → Animated Conversion:** turn off to leave animated AVIFs
  as they are, and still zip their chapters.
- **Full Pipeline → Run Cover Deletion Before Conversion:** runs a Cover
  Deletion scan first.
- **Clean Console Output, Full Logging:** how much you see on screen and in
  the logs.

### Cover Deletion

Cover Deletion only removes images it has been taught. Use **Add Image** in
its menu and point it at an example of an image you never want (a credits
page, say). It saves that image's size, dimensions and hash as a profile,
and future scans delete exact matches. **Dry Run** reports what would be
deleted without deleting anything.

### When a chapter isn't zipped

Full Pipeline leaves a chapter folder as it is, and says why in the summary
and log, when:

- a file failed to convert,
- a file name clashes with an existing `.jxl` that wasn't made from it,
- an AVIF couldn't be inspected, or
- the folder holds both an `.avif` and the `.webp` made from it (when
  "Delete Original" is off for animated files).

Fix the cause and run it again. Finished chapters are skipped.

### Where things are kept

| What | Where |
|---|---|
| Settings | `%LOCALAPPDATA%\ConversionScript\settings.json` |
| Cover Deletion profiles | `%LOCALAPPDATA%\ConversionScript\unwanted-image-profiles.json` |
| Logs | next to `Conversion Script Main.ps1` (`Conversion Log - ….log`) |

## Testing

Each module has its own test suite in `Modules\_Harness\`, using real
`cjxl`/`magick` stand-ins built on the fly. Run them all with:

```powershell
.\Tools\Run-Harness.ps1 -All
```

## For contributors

- `Conversion Script Main.ps1` only bootstraps: it finds `Modules\`, loads
  settings, locates `cjxl`/`magick`, and hands over to `Controller.ps1`.
- `Modules\` holds the 18 modules, one per job (logging, deletion, zip
  creation, the conversion pipelines, the menu, and so on), each with a test
  harness.
- `Docs\` has the design notes and per-function documentation, including
  [`Docs/lessons-learned.md`](Docs/lessons-learned.md), a list of the
  PowerShell traps this code has hit and how they're avoided.
- `CHANGELOG.md` is the full history. `Todo.md` lists open items.
- This project was developed with Claude Code as a pair programmer.
  `CLAUDE.md` is the working context those sessions use.

## License

No license has been chosen yet.
