# Module reference

How the tool is put together, one section per file. For what the tool does and how to use it, see [README.md](README.md).

## The big picture

`Conversion Script Main.ps1` loads every module in `Modules\` and hands over to `Controller.ps1`, which runs the menu. Each menu option is one entry point:

| Menu option | Entry point | Module |
|---|---|---|
| 1 Full Pipeline | `Invoke-FullPipeline` | `Controller.ps1` |
| 2 Image Conversion | `Invoke-LooseImageConversionPipeline` | `ImageConversionPipeline.ps1` |
| 3 Animated Conversion | `Invoke-LooseAnimatedConversionPipeline` | `AnimatedConversionPipeline.ps1` |
| 4 Zip Folders | `Invoke-ZipOnlyPipeline` | `ZipPipeline.ps1` |
| 5 Cover Deletion | `Show-CoverDeletionMenu` → `Invoke-UnwantedImageScan` | `Menu.ps1`, `UnwantedImage.ps1` |
| 0 Options | `Show-OptionsMenuLevel` | `Menu.ps1`, `Config.ps1` |

The rest are shared building blocks:

- **Running work in parallel:** `ChapterDispatch.ps1` runs external processes (cjxl, magick) a bounded number at a time, chapter by chapter. `ZipParallelProcessing.ps1` runs PowerShell worker scripts in parallel runspaces (Zip Folders' zip workers, and Full Pipeline's two engines).
- **Stopping cleanly:** `AbortPipeline.ps1` handles Ctrl+C and window close, makes child processes die with the script, and keeps the PC awake during a run.
- **Files:** `LeafDirectoryDiscovery.ps1` finds series and chapter folders; `FileDeletion.ps1` deletes (Recycle Bin or permanent); `ZipCreation.ps1` and `ZipValidation.ps1` make and check zips.
- **Output:** `Logging.ps1` writes the console and log files; `CleanConsoleRendering.ps1` draws the optional live progress view; `Summary.ps1` prints the end-of-run report.
- **Setup:** `Config.ps1` (settings), `DependencyDetection.ps1` (finding cjxl/magick).

Every module is a file of function (and type) definitions with no side effects when loaded, and each has a test suite in `Modules\_Harness\`.

## Rules for code that runs in worker runspaces

Zip Folders' workers and Full Pipeline's two engines run in separate PowerShell runspaces, and anything they call must follow three rules. Each module's section says which of its functions run there.

1. **Don't read `$script:` variables directly.** A function copied into a runspace can resolve `$script:` to an empty scope (inside a `.GetNewClosure()` block, for example), and the read silently comes back empty. Workers get their state as parameters, or through `Get-WorkerRunspaceValue` (`Logging.ps1`).
2. **Don't call cmdlets; use .NET calls.** Two fresh runspaces calling the same cmdlet for the first time at the same moment can deadlock in Windows PowerShell 5.1.
3. **Don't hand a scriptblock to .NET as a delegate** (`[Func[...]]{ }`, or a scriptblock passed to a .NET method such as `ConcurrentDictionary.GetOrAdd`). Nested, these deadlock.

A runspace starts with only the functions it's given, so a function a worker calls must be in its caller's `-SharedFunctionNames` list (built from each module's `Get-...SharedFunctionNames`). `Modules\_Harness\Lint.Harness.ps1` checks all of this.

---

## Conversion Script Main.ps1

The entry point. It holds no conversion logic of its own: it finds the `Modules` folder, loads every module, loads settings, locates `cjxl` and `magick`, and hands over to `Controller.ps1`'s `Invoke-MainLoop`, which runs the menu.

**Parameters**

| Parameter | What it does |
|---|---|
| `-Path` | The library folder to work on. Defaults to the current folder. Must exist. |
| `-CjxlPath` | Where `cjxl.exe` is, if it isn't found automatically. Remembered in settings. |
| `-MagickPath` | Where `magick.exe` is, if it isn't found automatically. Remembered in settings. |
| `-ModulesPathOverride` | Use a `Modules` folder somewhere other than next to the script. |

**How it works**

- **Finding `Modules\`:** the module-finding functions (`Resolve-ModulesPath`, `Test-ModulesFolderCandidate`, `Get-ExpectedModuleFileNames`) live in this file, not in a module, since they're what finds the modules. A candidate folder only counts if every file in `Get-ExpectedModuleFileNames` is in it. The order tried is: `-ModulesPathOverride`; the `Modules` folder next to the script; a path remembered in `settings.json` (read directly here, before `Config.ps1` is loaded); and finally a prompt. If input is redirected and there's nothing to prompt with, it fails with a message saying to pass `-ModulesPathOverride`.
- **Loading:** every module is dot-sourced into the script's own scope, in a fixed order (`Config`, `Logging`, `FileDeletion`, `AbortPipeline`, ... , `Menu`, `Controller`). Modules only define functions and types, so loading has no side effects beyond those.
- **Start-up:** after settings are loaded it registers the Ctrl+C / window-close handler, raises the thread-pool minimum, sets up the Job Object that ends child processes with the script, resolves `-Path`, sets up logging, Clean Console Output and the delete mode from settings, and finds `cjxl` (required) and `magick` (optional at start-up; the modes that need it check for it themselves).
- **Finding the tools:** `Find-ExeCached` (`DependencyDetection.ps1`) tries the path given on the command line, then the path remembered in settings, then `PATH`, then a few usual install locations (including the winget links folder for `cjxl` and `C:\Program Files\ImageMagick-*` for `magick`). Whatever it finds is saved back to settings.
- **Errors:** the whole start-up is in one `try`/`catch`. Once `AbortPipeline.ps1` is loaded, failures go through `Invoke-AbortOrFatalHandler` (which stays quiet for an abort the user asked for); before that, a plain message is printed. Either way the window waits for a key before closing, unless input is redirected, so the error can be read.

**Things to watch out for**

- A new module has to be added in two places here: the dot-source list and `Get-ExpectedModuleFileNames`. Without the second, a `Modules` folder missing the new file would still be accepted.
- The dot-source order matters: a module's functions can be called from modules loaded before it only at run time, never while loading. Keep `Controller.ps1` last.
- `#Requires -Version 5.1` is at the top. The project targets Windows PowerShell 5.1; nothing here relies on PowerShell 7.

---

## Config.ps1

The settings file. It defines every setting and its default, loads `settings.json` (checking each value and recovering from a missing, locked or corrupt file), and saves it. The Controller loads settings at startup, and the options menu in `Menu.ps1` saves after each change.

The file lives at `%LOCALAPPDATA%\ConversionScript\settings.json`.

**Main functions**

| Function | What it does |
|---|---|
| `Get-DefaultScriptSettings` | Returns a fresh hashtable with every setting and its default. This is the list of what `settings.json` may contain. |
| `Import-ScriptSettings` | Loads the file on top of the defaults. Always returns a hashtable containing every default key; never throws. |
| `Export-ScriptSettings` | Writes a settings hashtable to the file as JSON, creating the folder if needed. |
| `Get-ScriptSettingsPath` | `<BaseDir>\ConversionScript\settings.json`, with `BaseDir` defaulting to `$env:LOCALAPPDATA`. |
| `Test-ScriptSettingValue`, `ConvertTo-SettingsHashtable` | Private helpers: value validation, and flattening the parsed JSON (PowerShell 5.1's `ConvertFrom-Json` has no `-AsHashtable`). |

**Settings and defaults**

| Key | Default | Notes |
|---|---|---|
| `ModulesPath`, `CjxlPath`, `MagickPath` | `""` | Stored paths; empty means not resolved yet. |
| `ZipParallelThreads` | 1 | Zip Folders workers. Minimum 1. |
| `MaxCjxlProcs` | 8 | Image Conversion cjxl processes. Minimum 1. |
| `FullPipelineMaxConcurrentProcs` | 8 | Total cjxl + magick processes in Full Pipeline. Minimum 1. |
| `JpegLossless` / `JpegQuality` | off / 90 | Quality is 1-100. |
| `AnimatedThreads` | 8 | Minimum 1. |
| `AnimatedQuality` | 90 | 1-100. |
| `AnimatedLossless`, `AnimatedOverwrite` | off | |
| `AnimatedDeleteSource` | on | Delete the source `.avif` after a successful conversion. |
| `FullPipelineAnimatedConversion` | on | Off skips animated files in Full Pipeline. |
| `RunCoverDeletionBeforeConversion` | off | Full Pipeline runs a Cover Deletion pre-scan first. |
| `PermanentDelete` | off | Recycle Bin by default. |
| `FullLogging`, `DisableSummaryFile`, `CleanConsoleOutputEnabled` | off | |
| `LastCoverDeletionPath` | `""` | Last folder used by Cover Deletion. |
| `CoverDeletionAskForFolder`, `CoverDeletionDryRun` | off | |

**How it works**

- Key names match the parameter names of the functions that use them (`PermanentDelete`, `FullLogging`, `DisableSummaryFile`, `MaxCjxlProcs`, `JpegLossless`, `JpegQuality`, and so on), so a caller can pass values straight through.
- `Import-ScriptSettings` starts from the defaults and copies over each key found in the file that passes `Test-ScriptSettingValue`. The type must match the default's type: bool, int or string. A JSON `null` is rejected. Integer keys accept a whole-number decimal or double (`75.0`) and store it as an `[int]`. Integer values outside the Int32 range are rejected, as are values outside the key's range (the minimums and the 1-100 quality range in the table).
- An unknown key, or a bad value for a known key, is skipped with a `Warn` log line and that key keeps its default. The rest of the file still loads. The key `ZipWithUnconvertedAnimated`, which older files may contain, is dropped without a warning.
- A missing file returns the defaults without logging anything.
- Reading and parsing are separate steps. If the file can't be read (locked, momentarily inaccessible), the defaults are used for this run and the file is left alone, since it may read fine next time.
- If the file was read but is not valid JSON, or is valid JSON that is not an object (a bare `null`, an array), `Import-ScriptSettings` copies it to `settings.json.corrupt-<yyyyMMdd-HHmmss>.bak` and only then overwrites the original with the defaults. If the backup copy fails, the original is left untouched and a warning says so.
- `Export-ScriptSettings` writes with `ConvertTo-Json -Depth 5` and `Set-Content -Encoding UTF8`. It is not an atomic write, so an interrupted save can leave a truncated file; the load path above recovers from that.

**Things to watch out for**

- Add a new setting by adding it to `Get-DefaultScriptSettings`. Its default decides what type the value is validated as. Add a case to `Test-ScriptSettingValue` if it needs a range.
- Removing a setting means adding its key to `$retiredKeys` in `Import-ScriptSettings`, or users with older files see an "unknown setting" warning on every launch.
- `Import-ScriptSettings` calls `Write-Log` for warnings, so `Logging.ps1` should be loaded first. Those warnings can be logged before `Initialize-LogPaths` has run.
- `Import-ScriptSettings` has a near-copy of its corrupt-file recovery in `UnwantedImage.ps1`'s `Import-UnwantedImageProfiles`. Keep the two in sync.
- Pass `-Path` or `-BaseDir` to point at a different folder (the harness does) instead of touching the real AppData folder.
- Whether `CjxlPath` and `MagickPath` are reused is up to `Find-ExeCached` in `DependencyDetection.ps1`; this module only stores them.

---

## Logging.ps1

Console and log-file output for the whole tool. It picks the log file names for a target folder, writes log lines (safely from several runspaces at once), keeps each run's Errors/Warnings content on top of earlier runs, and drains the queue that worker runspaces use to hand their messages back to the main thread. Every other module calls `Write-Log`; the Controller sets it up and flushes the queue.

**Main functions**

| Function | What it does |
|---|---|
| `Write-Log` | Logs one message at `Info`, `Warn`, `Error` or `Summary`. `-ForceConsole` shows it on the console even with Clean Console Output on. In a worker runspace it queues the message instead of writing. Runs in workers. |
| `Initialize-LogPaths` | Hashes the target path (SHA-256 of the lower-cased path; the first 10 hex characters go in file names) and sets the log file names in the script directory. Full logging: one `Conversion Log - <timestamp> - <hash>.log` per run. Otherwise fixed-name `Summary`, `Errors` and `Warnings` files per target (Summary skipped if disabled). |
| `Initialize-LogMutex` | Creates the named system-wide mutex `JxlLogMutex_<pathHash>` that guards the log files. Takes `-PathHash` for callers (such as workers) that don't have the main thread's hash. |
| `Start-LogRun` / `Complete-LogRun` | Bracket one run on the main thread. Start writes a `=== Run: <timestamp> ===` header into the Errors and Warnings files and remembers their earlier content; Complete moves this run's new lines above that content so the newest run is on top. Both do nothing in full-logging mode. |
| `Write-SummaryLog` | Prepends one `=== Run ... === / === End of run ===` block to the Summary file. |
| `Flush-ConsoleQueue` | Main thread only. Drains the worker queue: writes each item to the run's log files, then to the console. |
| `Initialize-CleanConsoleOutput` | Sets whether `Write-Log` skips console echo for ordinary messages. |
| `Get-WorkerRunspaceValue` | Reads `workerConsoleQueue` or `PermanentDelete` from the script scope, falling back to the global scope. Runs in workers. |
| `Write-LogFileSummary` | Prints which log files this run used. |
| `Get-LogMutex` | Plain accessor for the mutex, for code that can't read `$script:logMutex` directly (see below). |
| `Get-LoggingSharedFunctionNames` | The list of functions to copy into worker runspaces. |
| Helpers | `Invoke-MutexGuardedWrite`, `Format-LogLine`, `Write-LogLineToHost`, `Write-LogLineToFile`, `Write-LogLineToRunFiles`, `Write-LogWriteFailureWarning`. |

**How it works**

- Which functions run in worker runspaces: `Get-LoggingSharedFunctionNames` returns `Write-Log`, `Get-WorkerRunspaceValue`, `Invoke-MutexGuardedWrite`, `Format-LogLine`, `Write-LogLineToHost`, `Write-LogLineToFile`, `Write-LogLineToRunFiles` and `Write-LogWriteFailureWarning`. Everything else (`Initialize-*`, `Start-LogRun`, `Complete-LogRun`, `Write-SummaryLog`, `Flush-ConsoleQueue`, `Write-LogFileSummary`, `Get-LogMutex`) is main thread only.
- In a worker, `Write-Log` finds the queue through `Get-WorkerRunspaceValue -Name workerConsoleQueue`. If there is one it enqueues `{ Message, Level, Line, ForceConsole }` and returns without touching the console or any file. The main thread's `Flush-ConsoleQueue` then does the file and console writes, so all console output stays on one thread.
- On the main thread there is no queue, so `Write-Log` writes directly. A line goes to a file when full logging is on, or when the level is `Error` or `Warn`. With full logging off, `Info` and `Summary` lines are console-only (the Summary file is written by `Write-SummaryLog`). In full-logging mode everything goes to the one log file; otherwise errors go to the Errors file and warnings to the Warnings file.
- Clean Console Output only affects the console; log file content is the same either way. With it on, `Write-Log` echoes nothing unless `-ForceConsole` is set. `Flush-ConsoleQueue` still writes every queued message to the files, then skips the echo for `Info` lines without `ForceConsole`; the rest go through `Write-GatedConsoleMessage` (from `CleanConsoleRendering.ps1`) in red, yellow or cyan.
- Console colours: `Error` red, `Warn` yellow, `Summary` cyan, `Info` default.
- All file writes go through `Invoke-MutexGuardedWrite`, which waits up to 10 seconds for the mutex. An abandoned mutex (previous holder died) counts as acquired. If the wait times out, the write is skipped and a warning is printed straight to the console rather than writing unguarded, since `Write-SummaryLog` and `Complete-LogRun` read and rewrite whole files.
- A failed log write (locked file, antivirus, cloud sync) is never fatal. `Write-LogWriteFailureWarning` prints one console warning per file per run and the run carries on.
- Errors and Warnings files accumulate across runs, newest on top. `Start-LogRun` reads the file's existing text and appends the run header; `Complete-LogRun` later rewrites the file as this run's lines followed by the earlier text. If the file no longer starts with the earlier text, it is left as it is. Log files are UTF-8.
- Messages about log problems (`Start-LogRun`, `Complete-LogRun`, `Write-SummaryLog`, the mutex timeout, write failures) go straight to the console and never through `Write-Log`, because `Write-Log` would write to the same file that just failed.

**Things to watch out for**

- Worker code must not read `$script:` variables directly. Use `Get-WorkerRunspaceValue`, which checks `$script:` and then `$global:`. Any new helper that `Write-Log` calls in a worker has to be added to `Get-LoggingSharedFunctionNames`, or it fails with "term not recognized" in the worker.
- A closure made with `.GetNewClosure()` can't see `$script:logMutex`. Call `Get-LogMutex` through a function reference (`& ${function:Get-LogMutex}`) instead.
- The queue variable is named `$script:workerConsoleQueue` on purpose so it can't clash with a local `$consoleQueue` used when setting up dispatch. Don't rename it.
- `Initialize-LogMutex` does not dispose a mutex it replaces. `ZipParallelProcessing.ps1` depends on that.
- `Initialize-LogMutex` throws if there is no `-PathHash` and `Initialize-LogPaths` hasn't run.
- `Initialize-LogPaths` must run before `Write-Log` is used for file output. Worker runspaces need their own mutex and queue set up (the queue as `workerConsoleQueue`, in `$script:` or `$global:`).
- `Flush-ConsoleQueue` calls `Write-GatedConsoleMessage`, so `CleanConsoleRendering.ps1` must be loaded too.

---

## FileDeletion.ps1

Deletes original files and folders after they've been converted or zipped. It sends them to the Recycle Bin by default, or deletes them for good when Permanent Delete is on. Image Conversion, Animated Conversion, Zip Folders, Full Pipeline and Cover Deletion all call `Remove-Source`.

**Main functions**

| Function | What it does |
|---|---|
| `Remove-Source` | The call for deleting an original file or folder. Permanent Delete on: `Remove-ItemPermanently`. Off: `Move-ToRecycleBin`. Runs in workers. |
| `Move-ToRecycleBin` | Sends a file or folder to the Recycle Bin. Throws instead when Windows would delete it permanently. Runs in workers. |
| `Remove-ItemPermanently` | Deletes a file or folder tree for good, clearing read-only attributes. Runs in workers. |
| `Initialize-FileDeletion` | Sets the Permanent Delete value. Call it before any deletion. Main thread only. |
| `Get-RecycleBinRefusalMessage` | Pre-flight check: returns an error message if the target folder's drive can't use the Recycle Bin (and Permanent Delete is off), otherwise `$null`. Main thread only. |
| `Get-FileDeletionSharedFunctionNames` | The list of functions to copy into worker runspaces. |
| Helpers | `Remove-DirectoryTreePermanently`, `Test-VanishedPathException`, `Invoke-DeleteTreatingVanishedAsFalse`, `Resolve-ItemPathOrNull`. |

**How it works**

- Which functions run in worker runspaces: `Get-FileDeletionSharedFunctionNames` returns `Remove-Source`, `Move-ToRecycleBin`, `Remove-ItemPermanently`, `Remove-DirectoryTreePermanently`, `Test-VanishedPathException`, `Invoke-DeleteTreatingVanishedAsFalse` and `Resolve-ItemPathOrNull`. `Remove-Source` also calls `Get-WorkerRunspaceValue` from `Logging.ps1`, so a worker needs that module's group too.
- `Remove-Source` reads the setting with `Get-WorkerRunspaceValue -Name PermanentDelete` rather than `$script:PermanentDelete`, so it works in a worker (script scope, then global scope). `Initialize-FileDeletion` only sets `$script:PermanentDelete` on the thread that calls it.
- The delete functions return `$true` if they deleted something and `$false` if the item was already gone (`Invoke-DeleteTreatingVanishedAsFalse` turns a file-not-found or directory-not-found error into `$false`). Any other failure is thrown to the caller. Callers use the `$false` to report "already gone" rather than "deleted".
- Files the tool created itself (extracted folders, temp files) are meant to be deleted with `Remove-ItemPermanently` directly, not `Remove-Source`; only originals follow the Permanent Delete setting.
- `Move-ToRecycleBin` uses `Microsoft.VisualBasic.FileIO.FileSystem` (loaded at the top of the file). Before deleting, it asks the C# `RecycleBinProbe` class whether Windows would really recycle the item. It throws instead of deleting if the item is on a network share or drive, a removable drive, a drive set to delete immediately, a PC with the Recycle Bin turned off by policy, or the item is larger than that drive's Recycle Bin limit (Windows would delete such items permanently without saying so). The message tells the user to turn on Permanent Delete.
- `RecycleBinProbe` reads volume facts (drive type, "delete immediately" flag, max capacity from the registry) with Win32 calls and caches them per volume. Any error inside the probe is swallowed and treated as "no reason to refuse". Its `Test*` static fields let a harness fake drive facts.
- `Remove-ItemPermanently` clears the read-only flag, then deletes. A directory junction or symlink is unlinked without recursion and never followed. `Remove-DirectoryTreePermanently` walks the tree by hand, unlinks reparse points without entering them, clears read-only flags on children, and skips children that vanish mid-walk.
- `Resolve-ItemPathOrNull` turns rooted paths into full paths with plain .NET (no PowerShell provider calls); only relative paths use the session state. It returns `$null` on error, which makes the delete return `$false`.
- `Get-RecycleBinRefusalMessage` resets the probe cache and checks volume-level reasons only (not item size). With Permanent Delete on it returns `$null`. The Controller and the Cover Deletion run use it to stop before starting a run in which nothing could be deleted.

**Things to watch out for**

- Several runspaces run these functions at once, so keep them on plain .NET calls. That is why `Resolve-ItemPathOrNull` skips the PowerShell path-resolution cmdlets for rooted paths.
- If you add a helper that a worker-run function calls, add it to `Get-FileDeletionSharedFunctionNames`.
- The `Add-Type` for `RecycleBinProbe` is guarded by a `PSTypeName` check so the file can be dot-sourced more than once in a process without a duplicate-type error. Keep any similar `Add-Type` guarded.
- Call `Initialize-FileDeletion` again whenever the setting changes (the Controller does it before each run, and `Menu.ps1` does it before Cover Deletion).
- `Move-ToRecycleBin` throws a "Left in place, not deleted" error for items that can't be recycled, so callers must handle a throw as a failed delete as well as a `$false` return.

---

## AbortPipeline.ps1

Everything about stopping a run cleanly and keeping the machine well-behaved while one is in progress: the Ctrl+C / window-close handler, the shared abort flag, a registry of cancellation sources, the graceful drain of worker runspaces, and three small Win32 helpers (QuickEdit mode, sleep blocking, and a job object that kills child processes if the script dies). `Controller.ps1`'s `Invoke-MainLoop` and `Invoke-FullPipeline`, `ZipParallelProcessing.ps1`, `ChapterDispatch.ps1`, the mode pipelines and `Menu.ps1` all use it.

**Main functions**

| Function | What it does |
|---|---|
| `Register-AbortHandler` | Installs the console control handler (`[ConsoleCtrl]::Register()`); warns if Windows refused the registration. |
| `Reset-AbortState` | Clears the abort flags, `RunActive`, and the drain event. Called at the top of each main-loop iteration. |
| `Set-AbortHandlerRunActive` | Sets `[ConsoleCtrl]::RunActive`, which tells the native handler whether a run is in progress. |
| `Test-AbortSignal` | The polling function. On the main thread it detects a new abort once, cancels every registered cancellation source, prints the abort message, and returns whether an abort has been requested. |
| `Register-AbortCancellationSource` / `Unregister-AbortCancellationSource` | Add or remove a `CancellationTokenSource` that `Test-AbortSignal` should cancel on abort. |
| `Get-AbortTriggerLabel` | Returns "Ctrl+C" or "window close (X button)" for the abort that happened. |
| `Invoke-GracefulDrain` | Waits for runspace handles to finish after an abort (default 60 s), then force-stops what's left. Always calls `Complete-AbortDrain`. |
| `Receive-CompletedHandles` | One pass over a list of runspace handles: ends and disposes finished ones, feeds their results to a handler, returns the still-running ones. |
| `Complete-AbortDrain` | Signals the native handler thread that draining is done. Safe to call any number of times. |
| `Test-OwnAbortException` / `Invoke-AbortOrFatalHandler` | Tell an exception caused by the abort (a pipeline-stopped or operation-cancelled exception while an abort is requested) apart from a real failure. A real failure is passed to a log handler as "FATAL ERROR" plus the stack trace; an abort completes the drain. Returns `$true` for an abort. |
| `Initialize-ChildProcessJob` | Creates the kill-on-close Windows job object; warns with the Win32 error if that fails. |
| `Set-SystemSleepBlocked` | Blocks or unblocks idle system sleep. |
| `Set-ConsoleQuickEditEnabled` / `Get-ConsoleQuickEditEnabled` | Set or read the console's QuickEdit mode (`1` on, `0` off, `-1` unknown). |

The file also defines four C# types through `Add-Type`: `ConsoleCtrl`, `ConsoleQuickEdit`, `SystemSleepBlock` and `ChildProcessJob`. Each is guarded with a type-exists check, so dot-sourcing the file twice in one session is fine.

**How it works**

- **Native handler.** `ConsoleCtrl` registers a handler for Ctrl+C, Ctrl+Break, window close, logoff and shutdown. If `RunActive` is false it returns immediately and lets the OS do its default, so closing the window at the menu doesn't hang. Otherwise it sets `IsCloseEvent` (true for close/logoff/shutdown, false for Ctrl+C/Break) and then `AbortRequested`, then blocks on `DrainComplete` for up to 65 seconds and tells Windows the event was handled. The 65 s wait is deliberately longer than the 60 s drain timeout.
- **Main-thread polling.** The handler only sets flags. `Test-AbortSignal` on the main thread notices `AbortRequested` the first time, copies `IsCloseEvent`, cancels every registered cancellation source (errors from `Cancel` are ignored), and prints a Ctrl+C or window-close message through `Write-GatedConsoleMessage`. After that it just returns `$true`.
- **Worker runspaces.** `Test-AbortSignal` checks `Get-WorkerRunspaceValue -Name workerConsoleQueue`; when that's set (we're inside a worker runspace) it returns the raw `[ConsoleCtrl]::AbortRequested` and does nothing else. The static class is shared by the whole process, so workers see the flag without having any of the main script's state. Workers never cancel tokens or print the abort message; the main thread does that.
- **Drain.** `Invoke-GracefulDrain` returns at once if there are no handles. Otherwise it prints the wait message, polls the handles every 250 ms (flushing the console queue) until they finish, the timeout passes, or a window-close event is seen, makes one last collection pass, then asks any remaining workers to stop with `BeginStop` and reports their count as `ForceStoppedCount`. It does not call `Dispose` or a blocking `Stop` on them. A `finally` always calls `Complete-AbortDrain`, so the native handler thread is released even if printing or flushing throws.
- **Window close skips the wait.** Both the drain loop and `ChapterDispatch.ps1`'s graceful wait stop waiting as soon as `IsCloseEvent` is true, since the OS will end the process shortly anyway.
- **Child process cleanup.** `ChildProcessJob.Initialize()` creates one job object with `KILL_ON_JOB_CLOSE` and never closes the handle, so Windows closes it when this process exits for any reason, killing every `cjxl`/`magick` process assigned to it. Code that starts a process calls `[ChildProcessJob]::Assign($proc)` right after `Process.Start()`; `Assign` never throws and returns `$false` on failure, so a failed assignment can't fail a conversion.
- **Sleep and QuickEdit.** `SystemSleepBlock` uses `SetThreadExecutionState`, which is per-thread: block and unblock from the same thread. `ConsoleQuickEdit` lets `Invoke-MainLoop` switch QuickEdit off for the duration of a run (only if it was on) and back on afterwards.
- `Register-AbortHandler` calls `Register()` more than once safely: it removes the previous delegate before adding the new one, and keeps a strong reference to the current one so it can't be garbage-collected.

**Things to watch out for**

- Call `Set-AbortHandlerRunActive -Active $true` only while a real run is in progress, and `Reset-AbortState` between runs. With `RunActive` false the handler never signals an abort.
- Anything that makes the native handler thread wait must end with `Complete-AbortDrain`. `Invoke-MainLoop` calls it unconditionally after every run for this reason; `Invoke-GracefulDrain` and `Invoke-AbortOrFatalHandler` call it too.
- `IsCloseEvent` is written before `AbortRequested` on purpose. `Test-AbortSignal` reads `AbortRequested` first as its "new abort" latch and `IsCloseEvent` second, so the order keeps a window close from being reported as Ctrl+C.
- `Test-AbortSignal` is listed in `Controller.ps1`'s `-SharedFunctionNames` because workers call it. Its main-thread branch calls `Write-GatedConsoleMessage` and `Complete-AbortDrain` calls `Complete-AllActiveSeriesProgress`, neither of which is propagated into worker runspaces; that's safe only because those branches never run inside a worker. Don't add worker-side calls to them.
- `Test-AbortSignal` and the drain read `$script:CleanConsoleOutputEnabled` and call `Write-GatedConsoleMessage`, `Get-WorkerRunspaceValue` and `Complete-AllActiveSeriesProgress`, so the Logging and Clean Console modules need to be loaded in the same session. `Invoke-GracefulDrain` also uses `Flush-ConsoleQueue` from `Logging.ps1`.
- `Receive-CompletedHandles` returns its list with a leading comma so an empty or single-item list stays a `List` instead of collapsing; keep that when editing.
- A worker stuck in a .NET call can't be stopped, so the drain reports it as force-stopped and moves on without waiting for it.

---

## DependencyDetection.ps1

Finds external executables on the machine. `Conversion Script Main.ps1` uses `Find-ExeCached` at startup for `cjxl` and `magick`, passing each one's exe name and candidate paths. Nothing in the module is specific to those two tools: the caller supplies the name and the candidates. The module depends on no other module. Its cache is a plain hashtable that the caller passes in.

**Main functions**

| Function | What it does |
|---|---|
| `Find-Exe -ExeName <string> [-UserPath <string>] [-Candidates <string[]>]` | Returns the first usable path, or `$null` if nothing matches. Search order: `-UserPath`, then `Get-Command` on `-ExeName`, then each `-Candidates` entry in order. |
| `Find-ExeCached -Settings <hashtable> -SettingsKey <string> -ExeName <string> [-UserPath <string>] [-Candidates <string[]>]` | Same search, but it first checks `$Settings[$SettingsKey]`, and it writes a newly found path back into that hashtable. |
| `Test-PathSafely -Path <string>` | Helper. Returns `$true` only if the path is an existing file. An invalid or too-long path returns `$false` instead of throwing. |

**How it works**

- `Find-Exe` checks each source in turn and returns the first hit: `-UserPath` if it points to an existing file, then the first application that `Get-Command` finds for `-ExeName`, then the candidates in order.
- `Find-ExeCached` checks `-UserPath` first, and a hit there is not written to the cache. Next it checks the cached value in `$Settings[$SettingsKey]`. If neither matches, it calls `Find-Exe` with `-ExeName` and `-Candidates` only, since `-UserPath` was already tried. A result from `Find-Exe` is stored in `$Settings[$SettingsKey]`. When nothing is found, the cache is left as it was.
- A cached path that no longer exists is skipped, not removed. The stale value stays in the hashtable until a later search succeeds and overwrites it.
- `Test-PathSafely` uses `Test-Path -LiteralPath -PathType Leaf`, so a directory never counts as a match.
- The module never reads or writes the settings file. The caller loads the hashtable before the call and saves it afterwards.
- The file contains only function definitions, so dot-sourcing it runs nothing.

**Things to watch out for**

- Each candidate, the cached value, and `-UserPath` are checked with `$x -and` before `Test-PathSafely` is called. `Test-PathSafely`'s `-Path` is a mandatory string, and Windows PowerShell 5.1 rejects an empty string for a mandatory parameter when the call binds. That error happens before the function's own `try` runs, so an empty entry would stop the whole search instead of being skipped. Keep those guards.
- The PATH lookup uses `-CommandType Application`. A PowerShell function or alias with the same name as the executable is not matched.
- `Test-PathSafely` catches only `ArgumentException` and `PathTooLongException`. Any other error propagates to the caller.
- A `-UserPath` that does not exist is ignored silently. Nothing is logged, and the search continues.
- Persistence depends entirely on the caller. If the caller never saves the settings hashtable, the cache is lost after the run.

---

## ZipCreation.ps1

Holds `Compress-FolderToZip`, the single step that turns a finished folder into a `.zip`. Full Pipeline calls it for each chapter through `Controller.ps1`, and Zip Folders calls it from `ZipPipeline.ps1`. The ZIP is checked afterwards by `Test-ZipArchive` in `ZipValidation.ps1`; that check is not part of this module.

**Main functions**

| Function | What it does |
|---|---|
| `Compress-FolderToZip -SourceDir <string> -ZipOut <string>` | Writes a ZIP of `SourceDir` to `ZipOut` and returns the ZIP's size in bytes. Replaces any file already at `ZipOut`. |
| `Get-ZipCreationSharedFunctionNames` | Returns `@('Compress-FolderToZip')` for use as `-SharedFunctionNames` when a worker runspace needs this function. |

**How it works**

- If a file already exists at `ZipOut`, it is removed with `Remove-Source` (`FileDeletion.ps1`). That sends it to the Recycle Bin unless permanent delete is on. A log line records which way it went, or a warning if the file had already disappeared. This removal happens before the new ZIP is written, so if the build then fails, nothing is left at that path.
- The archive is built with `System.IO.Compression.ZipFile::CreateFromDirectory`, using `CompressionLevel::Optimal` and `includeBaseDirectory = $false`. The folder's contents go to the top level of the ZIP, with no wrapper folder.
- After the build, the function checks that the file exists and is not zero bytes. Either failure throws. Only when both pass does it return the size.
- If anything inside the build-and-check block throws, a file left at `ZipOut` is deleted with `Remove-ItemPermanently` and the original error is rethrown. Errors from that cleanup are swallowed on purpose, so the caller sees the real failure.
- The pre-delete of an old ZIP sits outside the `try`. An error from `Remove-Source` there propagates straight to the caller.
- The permanent-delete setting is read only to choose the wording of the log line. It does not change what gets deleted; `Remove-Source` decides that.

**Things to watch out for**

- Before this runs, `Write-Log` (`Logging.ps1`), `Get-WorkerRunspaceValue` (`Logging.ps1`), `Remove-Source` and `Remove-ItemPermanently` (`FileDeletion.ps1`) must already be defined. Dot-source those modules first.
- The `Add-Type` at the top of the file loads `System.IO.Compression.FileSystem` when the file is dot-sourced. `-SharedFunctionNames` copies only function definitions into a worker runspace, so a worker that receives `Compress-FolderToZip` this way must load that assembly by some other route.
- The return value is the byte count as a number, not a boolean. A zero-byte result never reaches the caller because it throws first.
- Callers that need the ZIP to be valid should follow up with `Test-ZipArchive`. This function does not read the ZIP back.

---

## ZipValidation.ps1

Holds `Test-ZipArchive`, a read-only sanity check that runs on a ZIP after `Compress-FolderToZip` (`ZipCreation.ps1`) has built it. Full Pipeline calls it through `Controller.ps1`, and Zip Folders calls it from `ZipPipeline.ps1`.

**Main functions**

| Function | What it does |
|---|---|
| `Test-ZipArchive -ZipPath <string> [-RequireJxlEntry <bool>]` | Opens the ZIP, counts its entries and its `.jxl` entries, and throws if the checks fail. Returns a hashtable with `EntryCount` and `JxlCount`. `-RequireJxlEntry` defaults to `$true`. |
| `Get-ZipValidationSharedFunctionNames` | Returns `@('Test-ZipArchive')` for use as `-SharedFunctionNames`. |

**How it works**

- The archive is opened with `ZipFile::OpenRead`. The function reads `Entries`, which is the archive's directory listing. It does not extract or decompress any file body, so it does not catch a damaged entry whose directory record is intact.
- Every entry in the listing counts toward `EntryCount`. There is no filter, so any directory entries are included.
- `JxlCount` counts entries whose full name ends in `.jxl`, matched case-insensitively with `-imatch '\.jxl$'`.
- The archive is disposed in a `finally` block, so it is released even if the counting loop throws.
- Two throws happen, in this order: if `EntryCount` is 0, and if `RequireJxlEntry` is true and `JxlCount` is 0. Each message includes the ZIP path.
- The callers set `-RequireJxlEntry` differently. Full Pipeline passes `$imageActuallyConverted` (`Controller.ps1`). Zip Folders passes `$false` (`ZipPipeline.ps1`), since it does no image conversion.

**Things to watch out for**

- `OpenRead` sits outside the `try` block. If the file is missing, locked, or not a valid ZIP, the raw .NET exception reaches the caller without this module's usual path-and-action message.
- The check reads names only. A ZIP with a `.jxl`-named entry that is not really JPEG XL still passes.
- The function needs `System.IO.Compression.FileSystem`. The `Add-Type` at the top of the file loads it on dot-source. As with `ZipCreation.ps1`, `-SharedFunctionNames` carries only the function definition into a worker runspace, not that `Add-Type`.
- Read the result by key (`$result.JxlCount`, `$result.EntryCount`). It is a plain hashtable.

---

## CleanConsoleRendering.ps1

The renderer behind the "Clean Console Output" option. Instead of printing a line per file, it draws a live per-series progress display: the series name, a progress bar with a chapters-done count, any chapters that ended in a warning or error, and the chapters currently queued or in progress. Image Conversion, Animated Conversion, Zip Folders and Full Pipeline call it; it only changes what is shown on the console, not what is written to the log file.

**Main functions**

| Function | What it does |
|---|---|
| `Start-SeriesProgress` | Registers a series with a chapter total and redraws. A total of 0 prints the series once as already finished. Throws if the name is already active or the total is negative. |
| `Start-ChapterProgress` | Adds a chapter to a series' active list (`-Queued` marks it as queued). Throws if the series isn't active. |
| `Set-ChapterInProgress` | Flips a queued chapter to "in progress". Does nothing if the series or chapter isn't queued. |
| `Complete-ChapterProgress` | Finishes a chapter with `Success`, `Warning` or `Error` and an optional detail. When all of a series' chapters are resolved, the series is removed from the live area and printed permanently. Returns `@{ SeriesCompleted = ... }`. Throws if the series or chapter isn't active. |
| `Complete-AllActiveSeriesProgress` | Ends the display for everything still active: remaining chapters are recorded as `Aborted` and every series is printed permanently. |
| `Write-CleanConsoleMessage` | Prints a message above the live area (for messages that must not be overwritten), splitting on `\r?\n`. |
| `Write-GatedConsoleMessage` | Calls `Write-CleanConsoleMessage` if the caller says Clean Console Output is on, otherwise a plain `Write-Host`. The caller passes the flag in. |
| `Update-CleanConsoleDisplay` | Does the actual drawing: erases the previous live area, writes frozen rows then live rows, and pads or clears leftover rows. |
| Layout helpers | `Format-SeriesLines`, `Get-WrappedSeriesRows`, `Get-CappedLiveRows`, `Get-ProgressBarString`, `Split-TextToWidth`, `Get-DisplayWidth`, `Test-WideCharacter`, `Set-PadToDisplayWidth`, `Get-IssueStatusColor`, `Write-ColoredConsoleRow`, `Test-CleanConsoleCursorAvailable`. |

**How it works**

- State lives in script-level variables: an ordered dictionary of active series (each with total, success count, active chapters, queued chapters and issue chapters), the number of rows the live area took on the last draw, and a cached "can the cursor be moved" flag. It is main-thread state; nothing here is meant to be called from a worker runspace.
- Each draw has two parts. Frozen rows (finished series and extra messages) are written once and stay in the scrollback. Live rows (series still running) are rewritten in place on the next draw: the cursor moves up by the previous live row count, rows are written padded to the full width, and if the new area is shorter, blank rows clear the leftovers.
- A series line is the name, then a bar like `[####----] 3/8 chapters`, then one line per issue chapter (`name - Status: detail`) and one per active chapter (`(queued)` or `(in progress)`). The bar is yellow if any chapter has a warning and red if any has an error. Error/warning lines are red/yellow, and `Aborted` is yellow.
- The bar uses `Floor`, so it only shows full when every chapter has finished. A series with failures therefore never shows a completely full bar before the series is finished.
- Width handling counts East Asian wide characters (CJK, Hangul, fullwidth forms) as 2 columns, so names in those scripts wrap and pad correctly. Text is wrapped to console width minus 1 (79 if the width can't be read), and rows are padded so a shorter new row fully overwrites an older, longer one.
- The live area is capped at the window height minus 4 rows (when the window is more than 6 rows tall). If the series don't fit, the first series are shown and the rest are replaced by a "... and N more series in progress" line; a single series too tall to fit is cut with a "... N more line(s)" line. `$script:ccrMaxLiveRows` overrides the cap (used by tests).
- If the console width changed since the last draw, the in-place rewrite is skipped for that one draw and the display is drawn fresh from the current cursor position, because the old row count may no longer match what is on screen. The next draw goes back to normal.
- Falling back: if the cursor position can't be read (output redirected, no console), the renderer appends rows without moving the cursor. If a cursor move fails mid-draw, that draw is redone as a plain write and the next draw tries again; only if even a plain write throws does it switch to append-only for good.
- `Write-CleanConsoleMessage` splits on `\r?\n` so a trailing carriage return can't move the cursor back to column 0 and blank the row.

**Things to watch out for**

- Call order matters and misuse throws: `Start-SeriesProgress` before `Start-ChapterProgress`, `Start-ChapterProgress` before `Complete-ChapterProgress`, and every chapter must be completed before the same series name is started again. A caller that can fail halfway should make sure `Complete-AllActiveSeriesProgress` runs in a `finally` block; the pipelines do.
- Callers gate every call on `$script:CleanConsoleOutputEnabled` themselves; this module doesn't read that flag. `Write-GatedConsoleMessage` takes it as a parameter so this module has no dependency on the module that owns the setting.
- A series total of 0 is handled by printing the series immediately; don't pass a negative number.
- Because rows are rewritten by cursor position, anything else writing to the console while a live area is showing (a stray `Write-Host`) will leave the display out of step until the next full redraw. Use `Write-CleanConsoleMessage`/`Write-GatedConsoleMessage` for messages during a run.
- `Complete-ChapterProgress` only accepts `Success`, `Warning` or `Error`; `Aborted` is set internally by `Complete-AllActiveSeriesProgress`.

---

## LeafDirectoryDiscovery.ps1

Finds the folders the tool works on: "leaf" chapter folders that should be zipped, the series folders that contain them, and every file under a folder. Image Conversion, Animated Conversion, Zip Folders and Full Pipeline all use it to decide what a "series" and a "chapter" are. The module contains only function definitions; it has no state of its own.

**Main functions**

| Function | What it does |
|---|---|
| `Get-ZippableLeafDirs` | Eager scan under a path. Returns a `List[hashtable]` of `@{ Dir; ZipOut }` for every folder that should be zipped. Throws if the path doesn't exist. |
| `New-ZippableLeafDirProvider` | Same scan, but incremental: returns a scriptblock that yields one candidate per call and `$null` when finished, so zipping can start before a large tree is fully scanned. Throws if the path doesn't exist. |
| `Test-ZippableLeafDirCandidate` | The decision for one folder: returns `@{ Dir; ZipOut }` if it should be zipped, otherwise `$null`. A folder whose only qualifying files are named `cover.*` is not a candidate (it's a series folder holding its cover), so Zip Folders never zips one. Shared by both scans above. |
| `New-SeriesProvider` | Returns a scriptblock that yields one series folder (`DirectoryInfo`) per call, lazily, and `$null` at the end. Descends into category folders (see below). |
| `Test-SeriesCategoryFolder` | True if a folder is a category folder (it holds series, not chapter content). |
| `Get-SeriesChapters` | Runs `Get-ZippableLeafDirs` on one series and returns its chapters; on failure it logs a warning and returns an empty list. |
| `Get-FilesRecursiveSafe` | Returns a `List[FileInfo]` of every file under a path, tolerating unreadable folders. |
| `Test-SeriesCoverFile` | True if a file is a series cover: named `cover.<ext>` in any capitalization and sitting directly in the given series folder. A `cover.*` inside a chapter folder is a page, not a cover. |
| `Get-LeafDirectoryDiscoverySharedFunctionNames` | Names of the functions to copy into worker runspaces (see below). |

**How it works**

- A folder is a zippable chapter when it has no subfolders, isn't inside an excluded staging folder, contains at least one file with a qualifying extension, and contains no `.zip` files. The zip is planned at `<parent>\<folder name>.zip`.
- A folder with a `.zip` directly inside it is skipped with a warning. After every chapter subfolder of a series has been zipped and deleted, the series folder holds only `.zip` files and would otherwise look like a leaf; zipping it would wrap the existing archives inside another one.
- Unless `-ForceRezip` is set, a folder whose zip already exists is skipped (with a warning) when the zip's last-write time is the same as or newer than the newest qualifying file in the folder.
- A folder that is not a candidate is searched further down; a folder that is a candidate is not searched further.
- `New-SeriesProvider` walks the library with a stack of directory enumerators. A folder is treated as a category folder, and descended into, only when `Test-SeriesCategoryFolder` says so: it has no qualifying or `.zip` files directly in it, has at least one subfolder, and none of those subfolders directly hold a qualifying file. Anything else is returned as a series. If the check itself fails, the folder is treated as a series.
- `Get-FilesRecursiveSafe` and both leaf scans keep going past errors: a folder that can't be listed is logged as a warning and skipped, and in `Get-FilesRecursiveSafe` its subfolders are still explored. A series folder that disappears between being listed and being scanned makes `Get-SeriesChapters` return an empty result instead of throwing, so one vanished series doesn't stop a run.
- Junctions and symlinks (reparse points) are never followed or treated as candidates. A link pointing back into the tree would otherwise cause the same folders to be scanned repeatedly.
- Functions that return a collection use `return ,$collection` so a one-item or empty list isn't unrolled by the pipeline.
- The providers are closures over their own enumerator stacks (`GetNewClosure()`), so each provider call continues where the previous one stopped.

**Worker runspaces**

`Get-LeafDirectoryDiscoverySharedFunctionNames` returns `New-SeriesProvider`, `Test-SeriesCategoryFolder`, `Get-SeriesChapters`, `Get-ZippableLeafDirs`, `Test-ZippableLeafDirCandidate`, `Get-FilesRecursiveSafe` and `Test-SeriesCoverFile`. `ZipPipeline.ps1`'s zip worker uses `Get-FilesRecursiveSafe` inside a worker runspace, so that function and everything it calls must stay free of `$script:` state, cmdlets that need the host, and scriptblocks passed to .NET. They do call `Write-Log`, which has to be present in the runspace too (from `Get-LoggingSharedFunctionNames`). `New-ZippableLeafDirProvider` is not in the list because it only runs on the main thread.

**Things to watch out for**

- `Write-Log` is not defined here; `Logging.ps1` must be dot-sourced first. The harness supplies a stand-in.
- The reparse-point guard is deliberately repeated in five places: `Get-FilesRecursiveSafe`, `Get-ZippableLeafDirs`, `New-ZippableLeafDirProvider`, `Test-SeriesCategoryFolder` and `New-SeriesProvider`. Each copy has a comment naming the others; keep them in sync.
- If you add a new helper that a shared function calls, add it to `Get-LeafDirectoryDiscoverySharedFunctionNames`, or workers will fail with "term not recognized".
- `Get-ZippableLeafDirs` throws for a missing path (it catches typos at startup), while `Get-SeriesChapters` swallows that and returns nothing. This is intentional.
- Qualifying extensions are matched case-insensitively and always exclude `.zip`, which is handled separately.

---

## ChapterDispatch.ps1

The generic job scheduler behind Image Conversion, Animated Conversion and both Full Pipeline engines. It pulls chapters from a provider, turns each into zero or more jobs (one external process per file), starts jobs up to a concurrency limit, polls them, and tells the caller when each chapter's jobs have all finished. It knows nothing about cjxl, magick or zipping: the caller supplies that as scriptblocks.

**Main functions**

| Function | What it does |
|---|---|
| `Invoke-ChapterDispatch` | The dispatch loop. Takes the caller's scriptblocks, runs all chapters to completion (or abort), and returns a result hashtable. |
| `New-LibraryChapterProvider` | Builds a chapter-provider scriptblock for a whole library: walks series with `New-SeriesProvider`, lists each series' chapters with `Get-SeriesChapters`, and returns one chapter hashtable (`SeriesName`, `ChapterName`, `Dir`, `ZipOut`) per call, then `$null`. |
| `Invoke-BoundedProcess` | Runs one short helper process (`magick identify`, the ICC strip, the series cover conversion) to completion with a time limit. The process is put in `ChildProcessJob`, waited on through a `ManualResetEvent` wrapping its handle (killed when `-ExitTimeoutMs` runs out), and its stdout/stderr reads are bounded too (`-StreamTimeoutMs`, 15 seconds by default). Returns `@{ StartError; TimedOut; StreamTimedOut; ExitCode; Stdout; Stderr }` and never throws for a failed start; callers turn the result into their own log line or exception. Safe in worker runspaces. |
| `Initialize-ChildProcessReadThreadPool` | Raises the .NET thread pool's minimum worker threads to at least `max(128, 2 x processes + 32)` so many redirected-output reads can run at once without the pool starving. Returns whether the setting is in effect. |
| `Get-ChapterDispatchSharedFunctionNames` | Names of this module's functions that worker runspaces need (`New-LibraryChapterProvider`, `Invoke-ChapterDispatch`, `Invoke-BoundedProcess`). |

**How it works**

The caller passes these scriptblocks to `Invoke-ChapterDispatch`:

| Parameter | Contract |
|---|---|
| `-ChapterProvider` | Returns the next chapter object, or `$null` when there are no more. |
| `-JobBuilder` | Given a chapter, returns an array of job hashtables. Return `@()` (or `$null`, which is normalised) if the chapter has nothing to do. |
| `-JobStarter` | Given a job, starts it and returns the job (with `Proc` set to the started process). May throw. |
| `-JobPollCompleted` | Given a job, returns true when it has finished. |
| `-JobFinalize` | Given a finished job and the pending queue, does the per-job completion work. Returning an object with `Requeued = $true` means the job was put back on the pending queue and the chapter is not yet one job closer to done. |
| `-JobAbortCleanup` | Given a job that was force-stopped or never started, cleans up its partial output. |
| `-ChapterCompleteCallback` | Called once per chapter when its last job is done. |
| `-AbortPollCallback` | Optional. Called every loop with the list of running jobs; callers use it to check `Test-AbortSignal`. |
| `-ChapterReleaseCheck` | Optional. See below. |

- **Chapter queue-ahead.** Up to `-MaxQueueAhead` (default 3) chapters are "active" at once: pulled from the provider, built into jobs, and counted until all their jobs finish. Every job gets a `ChapterKey` (the chapter object itself) added to it, which is how finished jobs are matched back to their chapter.
- **Concurrency.** `-MaxConcurrent` is either an integer (a per-call cap on running jobs) or a `SemaphoreSlim`. With a semaphore, a slot is taken with `Wait(0)` before each start and released when the job finishes, fails to start, or is force-stopped. Full Pipeline passes one shared semaphore to both engines so the two together never exceed the process budget.
- **Loop order.** Each pass: release held chapters, top up active chapters from the provider, call the abort-poll callback, start pending jobs while slots are free, poll every running job, sleep 50 ms. The loop ends when the provider is exhausted and nothing is active, pending or running, or when the cancel token fires.
- **Finishing a job.** When `-JobPollCompleted` says a job is done: `-JobFinalize` runs, the job's `Proc` is disposed, the semaphore slot is released, and (unless requeued) its chapter's outstanding count drops. At zero, `-ChapterCompleteCallback` runs once and a result `@{ ChapterInfo; Completed = $true; Aborted = $false }` is recorded.
- **Zero-job chapters** complete immediately in the same pass that builds them. If `-ChapterReleaseCheck` is given, such a chapter is "held": it keeps counting against the queue-ahead limit until `-ChapterReleaseCheck` returns true for it. (Full Pipeline's check is "the main thread has finished merging this chapter".) Chapters that had jobs are not held.
- **Job start failures.** If `-JobStarter` throws, the semaphore slot is released first, the failure is logged and counted in `JobStarterFailedCount`, and the chapter's outstanding count is decremented so it can still complete.
- **Abort.** When the cancel token fires, no new jobs start. If jobs are running, the function polls them every 250 ms for up to `-AbortTimeoutSeconds` (default 60), or less if a window-close event is seen, then does one last check pass. Any job still running is force-killed (`Proc.Kill()`, wait up to 5 s), passed to `-JobAbortCleanup`, its slot released, and counted in `ForceKilledCount`. Jobs that were pending and never started also go through `-JobAbortCleanup` and are removed from their chapter's count.
- **After an abort**, every chapter that hadn't completed still gets `-ChapterCompleteCallback` called (so work its other jobs already finished is credited to the caller's totals; exceptions from that callback are swallowed) and is recorded as `Completed = $false; Aborted = $true`.
- **Return value.** A hashtable: `ChapterResults` (list), `Aborted`, `ForceKilledCount`, `JobStarterFailedCount`.
- **Unexpected exceptions** in the loop or the abort wait kill every running process, run `-JobAbortCleanup` on jobs whose slot hasn't been released, release their slots, and rethrow.
- **Where it runs.** On the main thread for Image Conversion and Animated Conversion. In Full Pipeline each engine's worker runspace calls it, which is why it and `New-LibraryChapterProvider` are in the shared function names.

**Things to watch out for**

- The poll/finalize/completion block appears three times: in the main loop, in the graceful-wait loop, and in the mandatory final check pass after it. Each copy is marked in a comment. Keep all three in sync, including the "ChapterKey not in chapter states" error log. (The final pass exists because a window-close can end the wait loop before it polls even once.)
- The dispatcher itself kills and disposes `$job.Proc` when it exists (a missing or `$null` `Proc` is fine), and ignores kill and dispose failures. The starter is expected to set `Proc`; the existing poll callbacks read `Proc.HasExited`.
- `-JobBuilder` should return `@()` for "nothing to do". A single returned hashtable is wrapped as one job. The code assigns `$jobs` inside each branch of an `if` rather than capturing an `if` expression, because capturing a block's output enumerates a lone hashtable into its entries.
- Closures that need to remember something between calls (such as `New-LibraryChapterProvider`'s "series exhausted" flag) keep it in a hashtable, because a plain variable assigned inside a `.GetNewClosure()` scriptblock doesn't persist across calls.
- If you add a new caller, follow the same contract as the existing ones in `ImageConversionPipeline.ps1`, `AnimatedConversionPipeline.ps1` and `Controller.ps1`: they supply all seven mandatory scriptblocks and the semaphore or integer limit.
- Code that runs inside Full Pipeline's worker runspaces (including this function) can't read the main script's `$script:` variables or use anything not in the shared function names. See `ZipParallelProcessing.ps1`.
- References `[ConsoleCtrl]::IsCloseEvent`, so `AbortPipeline.ps1` must be loaded first. It also calls `Write-Log`, `New-SeriesProvider` and `Get-SeriesChapters` (`LeafDirectoryDiscovery.ps1`).

---

## ZipParallelProcessing.ps1

A shared runspace-pool dispatcher. It runs a worker scriptblock once per job in a pool of PowerShell runspaces, collects each job's results on the main thread, and handles Ctrl+C / window-close by draining the pool. Zip Folders uses it to zip chapters in parallel, and Full Pipeline uses it to run its two engines (image and animated), where one "job" is one whole long-lived engine.

**Main functions**

| Function | What it does |
|---|---|
| `Invoke-ZipParallelProcessing` | Runs `-WorkerScript` for each job in a runspace pool of at most `-MaxParallel`, feeds every result to `-ResultHandler` on the main thread, and returns `@{ ForceStoppedCount = n }`. |

**How it works**

- Jobs come from exactly one of two sources: `-JobParams` (a fixed list of parameter hashtables) or `-NextJobProvider` (a scriptblock called on the main thread that returns the next hashtable, or `$null` when finished). Supplying both or neither throws. An empty `-JobParams` list returns immediately.
- Each job's hashtable keys are passed to the worker as named parameters. The function adds three more: `CancelToken` (from `-Cts`), `LogMutex` and `ConsoleQueue`. A worker script must declare those parameters.
- The pool is built from a fresh `InitialSessionState`. Only the functions named in `-SharedFunctionNames` are copied into it (by reading each function's definition and adding a function entry). A name that doesn't resolve throws a message naming the entry. Nothing else from the calling script exists inside a worker.
- Each run creates its own log mutex (`Initialize-LogMutex`) and a `ConcurrentQueue` for console output. The previous `$script:logMutex` is restored, and the new mutex disposed, when the call ends.
- The main loop keeps the pool filled up to `-MaxParallel`, then on each pass: checks `Test-AbortSignal`, flushes the console queue (`Flush-ConsoleQueue`), calls `-PollCallback` if given, and harvests completed jobs. It sleeps 100 ms only when it has nothing to start.
- Harvesting a finished job calls `EndInvoke`; any non-terminating errors from the worker's error stream are logged as `Runspace error`. Each returned object goes to `-ResultHandler` (called once per output object, so a worker returns its result as the single object it emits).
- If a worker throws an unhandled exception, `EndInvoke` rethrows it. That is logged, and `-JobCrashedHandler` (if supplied) is called with the error. `-ResultHandler` is never called for a crashed job. Full Pipeline uses this to mark the run aborted and cancel the other engine.
- On cancellation, the loop stops starting jobs and `Invoke-GracefulDrain` waits up to 60 seconds for running workers (printing `-AbortWaitMessage`). Workers that don't finish are asked to stop with `BeginStop`, and their count is returned as `ForceStoppedCount`.
- The `finally` block always runs. Finished handles are disposed. If any worker is still running it is asked to stop asynchronously, the cancellation source is cancelled, and the pool is closed with `BeginClose` instead of `Close`. Otherwise the pool is closed and disposed. The console queue is flushed one last time.

**Things to watch out for**

- Worker code runs in a separate runspace with no access to the caller's `$script:` variables, no caller-defined functions beyond `-SharedFunctionNames`, and no closures from the caller. Everything a worker needs must arrive through its job parameters. A function listed in `-SharedFunctionNames` that calls another user-defined function not on the list fails with "term not recognized" at run time. Each module that owns such a group exports a `Get-...SharedFunctionNames` getter, and `Modules\_Harness\Lint.Harness.ps1` checks the call graph for gaps.
- `-WorkerScript` itself is passed as a script block, so it also can't capture the caller's variables. Pass state as job parameters (thread-safe collections, semaphores and so on, which are shared by reference).
- The stop and close calls on an abandoned worker are the asynchronous versions (`BeginStop`, `BeginClose`) on purpose. A worker blocked inside a .NET call can't be interrupted, and `Stop`, `Dispose` and `Close` would all wait for it, so a plain call would hang the run.
- `-ResultHandler`, `-PollCallback` and `-JobCrashedHandler` all run on the main thread. `-PollCallback` is also where Full Pipeline drains its event queue and does per-chapter zipping, so a slow callback slows polling for every worker.
- `-NextJobProvider` runs on the main thread between polls, so it should return quickly.
- Must be dot-sourced after `Logging.ps1` and `AbortPipeline.ps1`; it calls `Initialize-LogMutex`, `Write-Log`, `Flush-ConsoleQueue`, `Test-AbortSignal` and `Invoke-GracefulDrain`.

---

## ZipPipeline.ps1

Zip Folders (menu option 4): finds every chapter folder under a library path, zips each one in parallel, verifies the archive, and optionally deletes the source folder. It converts nothing. The zip work itself is done by `Compress-FolderToZip` and `Test-ZipArchive`; this module decides what to zip, runs the workers, and reports results.

**Main functions**

| Function | What it does |
|---|---|
| `Invoke-ZipOnlyPipeline` | The Zip Folders entry point. Discovers chapter folders incrementally, hands each to a worker runspace via `Invoke-ZipParallelProcessing`, and returns a totals hashtable (`CandidateCount`, `ZippedSuccess`, `ZippedFail`, `PairBlocked`, `FolderDeletedSuccess`, `FolderDeletedFail`, `ForceStoppedCount`, `Aborted`). |
| `$script:zipOnlyWorker` | The scriptblock that runs in each worker runspace: guards, scratch-file cleanup, zip, verify, optional source delete. Returns a result hashtable per folder. |
| `Get-ZipChapterProgressStatus` | Maps a worker result to a Clean Console Output status and detail text. |
| `Start-Ccr...IfEnabled`, `Complete-Ccr...IfEnabled`, `Test-CcrEnabledForZipOnly` | Thin wrappers that call the Clean Console Output functions only when `$script:CleanConsoleOutputEnabled` is on. |

**How it works**

- Discovery uses `New-ZippableLeafDirProvider`, so zipping starts as soon as the first folder is found instead of after a full scan. The job provider runs on the main thread; each job it returns carries the folder path, planned zip path, series name, and the delete settings. Folders whose zip is already up to date are skipped during discovery.
- Each job runs in a worker runspace, up to `-MaxParallel` at once, through `Invoke-ZipParallelProcessing`. The pipeline creates one `CancellationTokenSource`, registers it with `Register-AbortCancellationSource`, and unregisters and disposes it in `finally`. `ForceStoppedCount` comes from the dispatcher's outcome, and `Aborted` is set from the token.
- Worker steps, in order:
  1. If the cancel token is already set, return `Cancelled` without doing anything.
  2. If the folder holds an `.avif` and a non-empty `.webp` with the same base name, don't zip it (`PairBlocked`). The log message says the animated originals were kept and tells the user to delete one of each pair and run again.
  3. Delete orphaned scratch files left by an interrupted conversion (`_tmp_iccstrip`, `_tmp_<fmt>2png.png`, `_tmp_overwrite.webp`) so they don't end up in the archive. If one can't be deleted it is logged and will be archived.
  4. `Compress-FolderToZip`, then `Test-ZipArchive -RequireJxlEntry $false` (a zip doesn't have to contain a `.jxl` here). On any failure the half-built zip is deleted and the result is marked failed.
  5. If `-DeleteFolders` is on, remove the source folder with `Remove-Source` (Recycle Bin by default, or permanent when `-PermanentDelete` is set). If an abort has been requested by then, the folder is left in place and a warning is logged, even though its zip is complete.
- The source-folder delete is outside the zip try/catch on purpose. If it were inside, a problem in the delete or its logging would be treated as a zip failure and would delete the archive that was just verified.
- The worker only sets two script-level values in its runspace (`$script:workerConsoleQueue` for logging through the console queue, and `$script:PermanentDelete`), and loads the `Microsoft.VisualBasic` and `System.IO.Compression.FileSystem` assemblies itself.
- Series names for Clean Console Output are derived from the folder's path relative to the scan root: the first path segment, or deeper if that segment is a category folder (checked with `Test-SeriesCategoryFolder`, cached per root). The first time a series appears, its chapter count is found with a separate `Get-ZippableLeafDirs` scan so the progress bar has a total. All of this is wrapped in a try/catch: a failure there only logs a warning, because it is display bookkeeping and must not stop the zip run.
- If no candidates are found the run logs either "aborted before any leaf directory was found" or "no qualifying leaf directories found", depending on `Aborted`. Otherwise it logs a summary line with zipped/failed counts and any force-stopped jobs. `Complete-AllActiveSeriesProgress` runs in `finally`.
- Default qualifying extensions cover images (`.jpg .jpeg .png .gif .webp .avif .jxl .bmp .tiff .tif .heic .heif`), video (`.mp4 .mkv .webm .avi .mov .wmv`) and `.cbz .cbr .epub .pdf`.
- There is no check that the layout is a proper Series/Chapter tree; any leaf folder with qualifying files gets zipped.

**Worker runspaces**

`$script:zipOnlyWorker` is the code that runs in worker runspaces, together with the functions listed in `$zipOnlyWorkerSharedFunctionNames`: the `Logging.ps1`, `FileDeletion.ps1`, `ZipCreation.ps1` and `ZipValidation.ps1` shared-name groups plus `Get-FilesRecursiveSafe`. The worker therefore must not read `$script:` variables other than the two it sets itself, call cmdlets that need the host, or hand scriptblocks to .NET as delegates. Everything else in this file (`Invoke-ZipOnlyPipeline`, the job provider, the result handler, the Ccr wrappers) runs on the main thread, where `$script:` state and the console are available.

**Things to watch out for**

- Dot-source order: this module needs `LeafDirectoryDiscovery.ps1`, `ZipParallelProcessing.ps1`, `AbortPipeline.ps1`, `CleanConsoleRendering.ps1`, `ZipCreation.ps1`, `ZipValidation.ps1`, `FileDeletion.ps1` and `Logging.ps1`. Their functions are called but not defined here.
- Two documented duplicates are kept inline because this module's harness doesn't dot-source the modules that own them. Keep them in sync:
  - the orphaned-scratch regex trio versus `Test-OrphanedScratchFileName` in `ImageConversionPipeline.ps1` (`ImageConversionPipeline.Harness.ps1` checks this copy hasn't drifted);
  - the `.avif`/`.webp` pair check versus `Test-AvifWebpPairPresent` in `AnimatedConversionPipeline.ps1`.
- The worker's own calls to other functions must all be reachable from `$zipOnlyWorkerSharedFunctionNames`. A function used in the worker but missing from that list fails with "term not recognized" only when a real run reaches that code path.
- `Get-ZipChapterProgressStatus` expects the worker result keys (`Cancelled`, `PairBlocked`, `Failed`, `FolderDeleteFailed`); if you add an outcome to the worker, add it there too.

---

## ImageConversionPipeline.ps1

Image Conversion (menu option 2), end to end: it finds loose images in each series, converts them to `.jxl` with `cjxl`, and deletes each source once its `.jxl` exists. It does not zip anything. The module's helpers (candidate discovery, the per-job finish step, the ICC-strip retry, the WebP animation check) are also reused by Full Pipeline in `Controller.ps1`, which runs its own conversion engine rather than calling `Invoke-LooseImageConversionPipeline`.

**Main functions**

| Function | What it does |
|---|---|
| `Invoke-LooseImageConversionPipeline` | The Image Conversion entry point. Walks the library series by series, builds one job list per chapter, and runs `cjxl` processes through `Invoke-ChapterDispatch`. Returns a totals hashtable (converted/failed/skipped/deleted counts, stale-source cleanup counts, force-killed count, `Aborted`, and the path lists the summary uses). |
| `Get-LooseImageCandidates` | Recursively lists loose images under a series, drops ones that shouldn't be touched, and sorts the rest into `NeedsConversion`, `StaleSources` and `NamingCollisions`. |
| `Remove-StaleLooseSources` | Deletes the `StaleSources` (via `Remove-Source`, so it honours the permanent-delete setting) and returns `Success`/`Fail` counts. |
| `Complete-ImageDispatchJob` | Finishes one `cjxl` job: reads its output, checks exit code and output file, cleans up temp files, deletes the source on success, and updates the chapter's counters. Returns `@{ Success = ... }`, or `@{ Requeued = $true }` after an ICC retry. |
| `Invoke-IccStripRetryOrFail` | Runs `magick <src> -strip <src>_tmp_iccstrip.png` and queues a retry job that feeds the stripped PNG to `cjxl`. Returns `$false` if the strip fails. |
| `Test-WebPAnimated` | Reads the first 24 bytes of a WebP and checks the animation flag in the VP8X chunk. No process is spawned. |
| `Get-LooseImageExtensions` | The default set of extensions treated as loose images: `.jpg .jpeg .png .webp .tiff .tif .avif .gif .bmp .heic .heif`. |
| `Get-NeverConvertedExtensions` | Extensions the project never converts (currently `.gif`). |
| `Invoke-SeriesCoverNormalization` | Leaves a series folder with a single lower-case `cover.jpg`. Returns `@{ Success; Fail }`. Runs once per series in Image Conversion and in Full Pipeline's image engine. |
| `Get-SeriesCoverConvertibleExtensions` | Cover formats converted to `cover.jpg`: `.webp .png .avif .bmp .tif .tiff .heic .heif .jxl`. |
| `Test-OrphanedScratchFileName` | True for leftover scratch-file names (`_tmp_iccstrip`, `_tmp_<fmt>2png.png`, `_tmp_overwrite.webp`). |
| `Get-ChapterProgressStatus`, `Get-ZipBlockedStatusOverride` | Turn a chapter's counters into a Clean Console Output status (`Success`/`Warning`/`Error`) and detail text; the override downgrades a non-error status to `Warning` when a zip was skipped. |
| `Get-ImageConversionSharedFunctionNames` | Names of the functions to copy into worker runspaces (see below). |

**How it works**

- `Invoke-LooseImageConversionPipeline` runs entirely on the main thread. Parallelism comes from running up to `-MaxCjxlProcs` external `cjxl`/`magick` processes at once, not from PowerShell runspaces. The pipeline passes its own provider/builder/starter/finalizer scriptblocks to `Invoke-ChapterDispatch`, which owns the loop, the concurrency limit and the abort drain.
- Discovery is two-tier: `New-SeriesProvider` hands out one series at a time, `Get-SeriesChapters` lists that series' chapters, and `Get-LooseImageCandidates` scans only that series. Images in a folder that chapter discovery didn't return are still converted (with a warning) but that folder is not treated as zippable.
- Candidate classification, per image, by looking at the sibling `.jxl` with the same base name:
  - no `.jxl`, or a 0-byte `.jxl`: needs conversion;
  - `.jxl` exists and the source is older than it: a stale source, deleted without reconverting;
  - `.jxl` exists and the source is not older: a naming collision. Both files are left alone, an error is logged, and the chapter is reported with a warning.
- Candidates are skipped if they are a series cover (`Test-SeriesCoverFile`), are `.gif`, are scratch files left by an interrupted run, or sit in a folder that a known zip would be built from (`-KnownZipPaths`, `-FolderExcludeStagingDirs`). `-ScanPath` is always one series folder, which is what the cover check compares against.
- Series covers: once per series, `Invoke-SeriesCoverNormalization` looks for an image named `cover.*` (any capitalization) directly in the series folder: `.jpg`, `.jpeg`, `.gif`, or a format from `Get-SeriesCoverConvertibleExtensions`. Other `cover.*` files (a `cover.json`, say) are ignored. None: nothing happens. More than one: all are left alone and a warning is logged. A `.jpg` in any capitalization is left untouched. A `.jpeg` is renamed to `cover.jpg` without re-encoding. A format from `Get-SeriesCoverConvertibleExtensions` is converted with `magick "<src>[0]" -background white -alpha remove -alpha off -quality 95 cover.jpg` (run through `Invoke-BoundedProcess`: 120 seconds to exit, 15 for the streams), the output is checked to exist and be non-empty, and the original is deleted with `Remove-Source`. A failed conversion logs an error, deletes any partial `cover.jpg` and leaves the original; the series' chapters carry on. A `.gif` cover is left alone with a warning. Each rename or conversion is logged, and the counts reach the summary's "Covers Normalised" row.
- Job building per image: animated WebP is skipped (checked with `Test-WebPAnimated`); animated AVIF is skipped (checked with `Test-AvifAnimated`, which spawns `magick identify`, and which is skipped if an abort is already signalled). A check that fails counts as an inspect failure, not a conversion failure. Two sources in one chapter that would produce the same `.jxl` path (for example `1.png` and `1.jpg`) are both rejected and counted as failed.
- Conversion command: JPEG uses `--lossless_jpeg=1` when `-JpegLossless` is set, otherwise `--lossless_jpeg=0 --quality=<JpegQuality>`. Everything else uses `--lossless_jpeg=0 --quality=90`. Always `--num_threads=1`; concurrency comes from running several processes.
- Formats `cjxl` can't read directly (AVIF, WebP, BMP, HEIC, HEIF, TIFF) go through a `magick` pre-conversion of frame `[0]` to a temp PNG named `<name>_tmp_<format>2png.png`, which `cjxl` then reads. The temp PNG is deleted afterward. If `-MagickExe` is not set, these files fail with a clear log line.
- The `magick` pre-conversion runs in `jobStarter` on the main thread and is bounded: 120 seconds for the process to exit (then it is killed), and 15 seconds for its stdout/stderr readers to finish. A hung `magick` therefore fails one file rather than freezing the run. The wait uses a `ManualResetEvent` wrapping the process handle rather than `Process.WaitForExit(int)`.
- When `cjxl` exits 1 with "Getting pixel data failed" and the job hasn't been retried, `Complete-ImageDispatchJob` calls `Invoke-IccStripRetryOrFail`, which strips the colour profile with `magick` (60 second limit, then killed), deletes any half-written `.jxl`, and queues a retry job. `IccRetried` stops it looping.
- Success is judged by exit code 0 and a non-empty `.jxl`. Reading `cjxl`'s output is bounded (15 seconds) and a failed read only logs a warning. Failure deletes any partial `.jxl`. On success the source is removed with `Remove-Source` (Recycle Bin by default, permanent if that setting is on). A source that is already gone isn't counted as deleted.
- A `%` in an output path is doubled (`%%`) when passed to `magick`, because ImageMagick reads `%` as an escape in output file names. Input paths are not escaped.
- Abort handling: the pipeline registers a `CancellationTokenSource` with `Register-AbortCancellationSource` and unregisters and disposes it in `finally`. `jobAbortCleanup` deletes temp and partial output for force-killed jobs and increments `ForceKilledCount` so the chapter reports as force-stopped. The `finally` block also calls `Complete-AllActiveSeriesProgress` when Clean Console Output is on.
- Clean Console Output calls (`Start-SeriesProgress`, `Start-ChapterProgress`, `Set-ChapterInProgress`, `Complete-ChapterProgress`) are gated on `$script:CleanConsoleOutputEnabled`; log lines are written either way. The optional `-PostChapterCallback` is called per chapter with the series, chapter, directory, the chapter's result (`$null` if the chapter had nothing to convert) and `HasNamingCollision`.

**Worker runspaces**

`Get-ImageConversionSharedFunctionNames` returns `Invoke-IccStripRetryOrFail`, `Test-AvifAnimated`, `Get-NeverConvertedExtensions`, `Test-WebPAnimated`, `Invoke-SeriesCoverNormalization`, `Get-SeriesCoverConvertibleExtensions` and `Invoke-BoundedProcess` (from `ChapterDispatch.ps1`, listed because the others call it). Those are the helpers that can run inside worker runspaces (Full Pipeline). They avoid `$script:` state and don't pass scriptblocks to .NET; they call `Write-Log`, which must also be in the runspace's function list (from `Get-LoggingSharedFunctionNames`), and the `ChildProcessJob` type. Everything else in the module (`Invoke-LooseImageConversionPipeline`, `Complete-ImageDispatchJob`, `Get-LooseImageCandidates`, `Remove-StaleLooseSources`) runs on the main thread and uses `$script:` state, `Remove-Source` and the Clean Console Output functions freely. Don't add a call to any of these to a shared function.

**Things to watch out for**

- Dot-source order: this module calls `Write-Log` (`Logging.ps1`), `Remove-Source` (`FileDeletion.ps1`), `Get-WorkerRunspaceValue` (`Logging.ps1`), `Test-AbortSignal`, `Register-AbortCancellationSource`, `Unregister-AbortCancellationSource` and `ChildProcessJob` (`AbortPipeline.ps1`), `Invoke-ChapterDispatch` (`ChapterDispatch.ps1`), `New-SeriesProvider`/`Get-SeriesChapters`/`Get-FilesRecursiveSafe` (`LeafDirectoryDiscovery.ps1`), the Clean Console Output functions (`CleanConsoleRendering.ps1`), and `Test-AvifAnimated` (`AnimatedConversionPipeline.ps1`). None of these are defined here.
- A helper that a shared function calls but isn't listed in `Get-ImageConversionSharedFunctionNames` will fail with "term not recognized" inside a worker runspace. Update the list if a shared function gains a new call. This is why `Test-OrphanedScratchFileName` is not in the list and `ZipPipeline.ps1` keeps its own copy.
- Documented duplicates, keep in sync:
  - the three orphaned-scratch regexes in `Test-OrphanedScratchFileName` and in `ZipPipeline.ps1`'s zip worker;
  - the 15 second stream bound shared by `Invoke-BoundedProcess` (`ChapterDispatch.ps1`), `Complete-ImageDispatchJob`, the `magick` pre-conversion detour here, and the matching one in `Controller.ps1`'s image engine;
  - `Complete-ImageDispatchJob` and `AnimatedConversionPipeline.ps1`'s `Complete-AnimatedDispatchJob`;
  - `Get-ChapterProgressStatus` and `Get-ChapterAnimatedStatus`;
  - the format-label switch here and in `Controller.ps1`'s image engine;
  - the abort check before `Test-AvifAnimated`, the once-per-chapter "queued to in progress" flip, and the abort-poll callback pattern, each also in `AnimatedConversionPipeline.ps1` and `Controller.ps1`.
- Scriptblocks passed to `Invoke-ChapterDispatch` are closures. State that has to latch across calls (`$chapterProviderState`, `$abortState`) is kept in hashtables, because a plain scalar assigned inside a `GetNewClosure()` scriptblock doesn't persist between invocations.
- Never convert or delete something on a naming collision. The collision rule (source not older than the existing `.jxl`) is the only thing separating "safe to delete the source" from "would lose an unconverted image".

---

## AnimatedConversionPipeline.ps1

Animated Conversion (menu option 3): finds animated `.avif` files and converts each to an animated `.webp` with ImageMagick, optionally deleting the source afterward. It also supplies `Test-AvifAnimated` and a few other helpers that Full Pipeline (`Controller.ps1`) and Image Conversion (`ImageConversionPipeline.ps1`) reuse to tell animated AVIF from static AVIF.

**Main functions**

| Function | What it does |
|---|---|
| `Invoke-LooseAnimatedConversionPipeline` | The Animated Conversion entry point. Walks the library series by series, builds one job list per chapter, and runs `magick` processes through `Invoke-ChapterDispatch`. Returns a totals hashtable (converted/failed/skipped, static-skipped, inspect-failed, deleted, force-killed, `Aborted`, plus path lists for the summary). |
| `Test-AvifAnimated` | Runs `magick identify -ping -format "%T\n" "<file>[0]"` and returns true if the first frame's delay is greater than 0. Throws if `magick` fails, times out, or prints something non-numeric. |
| `Get-LooseAnimatedCandidates` | Recursively lists files with the animated extensions (default `.avif`) under a series, skipping the series cover (`Test-SeriesCoverFile`) and folders that a known zip would be built from. Animated Conversion never touches a series cover; the image modes normalise it to `cover.jpg`. |
| `Complete-AnimatedDispatchJob` | Finishes one `magick` job: reads its output, checks exit code and output file, swaps in an overwrite temp file if needed, optionally deletes the source, and updates the chapter's counters. Returns `@{ Success = ... }`. |
| `Test-AvifWebpPairPresent` | True if a folder holds an `.avif` and a non-empty `.webp` with the same base name. |
| `Get-ChapterAnimatedStatus` | Turns a chapter's counters into a Clean Console Output status and detail text. |
| `Get-AnimatedConversionSharedFunctionNames` | Returns `@('Test-AvifAnimated', 'Invoke-BoundedProcess')`: the one function here meant for worker runspaces, plus the `ChapterDispatch.ps1` helper it calls. |

**How it works**

- The pipeline runs on the main thread. Parallelism comes from running up to `-AnimatedThreads` external `magick` processes at once, driven by `Invoke-ChapterDispatch`, not from PowerShell runspaces. Discovery is the same two-tier walk as Image Conversion (`New-SeriesProvider`, then `Get-SeriesChapters` for each series). Animated files in a folder that chapter discovery didn't return are still converted, with a warning.
- Per file, the job builder:
  - skips it if a non-empty `.webp` with the same name exists and `-AnimatedOverwrite` is off (counted as skipped). A 0-byte `.webp` is treated as missing so an interrupted run's leftover doesn't block the source forever;
  - checks it with `Test-AvifAnimated` (unless an abort is already signalled). A static AVIF is left alone and counted as static-skipped. A failed check is counted as an inspect failure and the file is skipped;
  - when overwriting an existing `.webp`, writes to `<name>_tmp_overwrite.webp` instead, so the old file stays until the new one is verified.
- The conversion command is `magick "<src>" -coalesce -loop 0 <quality> "<out>"`, where quality is `-define webp:lossless=true` if `-AnimatedLossless`, else `-quality <AnimatedQuality>`. A `%` in the output path is doubled (`%%`) because ImageMagick would otherwise read it as an escape when writing multi-frame output. The input path is not escaped.
- Success needs exit code 0 and a non-empty output file. On success with an overwrite, `File.Replace` swaps the temp file over the existing `.webp` (a `_replace_backup.tmp` file is used during the swap and removed). On failure the output file (or temp overwrite file) is deleted. Reading `magick`'s stdout/stderr is bounded (15 seconds) and a failed read only logs a warning.
- When `-AnimatedDeleteSource` is true (the default) and the conversion succeeded, the source `.avif` is removed with `Remove-Source` (Recycle Bin by default, permanent if that setting is on). A source that is already gone isn't counted as deleted; a delete failure is counted separately and the chapter is reported as an error.
- `Test-AvifAnimated` runs `magick` through `Invoke-BoundedProcess` (`ChapterDispatch.ps1`): 30 seconds to exit (then it is killed), and 15 seconds for the stdout/stderr readers.
- While a job runs, `jobPollCompleted` logs a heartbeat line every `-HeartbeatIntervalSeconds` (default 30; 0 disables it) with the elapsed time and the chapter's progress, since a large animated conversion can take minutes.
- Abort handling: the pipeline registers a `CancellationTokenSource` with `Register-AbortCancellationSource` and unregisters and disposes it in `finally`. `jobAbortCleanup` deletes the partial output and temp overwrite file for force-killed jobs and increments `ForceKilledCount`. The `finally` block also calls `Complete-AllActiveSeriesProgress` when Clean Console Output is on.
- Clean Console Output calls are gated on `$script:CleanConsoleOutputEnabled`; log lines are written either way. The optional `-PostChapterCallback` is called per chapter with the series, chapter, directory and the chapter's result (`$null` if the chapter had nothing to convert).
- `Get-ChapterAnimatedStatus` reports `Error` for any failure, force-stop, source-delete failure or inspect failure, `Warning` for skipped (output already exists), and `Success` otherwise.

**Worker runspaces**

Only `Test-AvifAnimated` is listed in `Get-AnimatedConversionSharedFunctionNames`, so it is the one function meant to run inside a worker runspace (Full Pipeline). It doesn't read `$script:` state, call `Write-Log` or hand scriptblocks to .NET; it needs only `Invoke-BoundedProcess` and the `ChildProcessJob` type. Everything else here (`Invoke-LooseAnimatedConversionPipeline`, `Complete-AnimatedDispatchJob`, `Get-LooseAnimatedCandidates`) runs on the main thread. `Test-AvifWebpPairPresent` is also main-thread only; it isn't in the shared list.

**Things to watch out for**

- Dot-source order: this module calls `Write-Log` and `Remove-Source` (`FileDeletion.ps1`), `Get-WorkerRunspaceValue` (`Logging.ps1`), `Test-AbortSignal`, `Register-AbortCancellationSource`, `Unregister-AbortCancellationSource` and `ChildProcessJob` (`AbortPipeline.ps1`), `Invoke-ChapterDispatch` (`ChapterDispatch.ps1`), `New-SeriesProvider`/`Get-SeriesChapters`/`Get-FilesRecursiveSafe` (`LeafDirectoryDiscovery.ps1`), and the Clean Console Output functions including `Write-GatedConsoleMessage` (`CleanConsoleRendering.ps1`). None are defined here.
- Documented duplicates, keep in sync:
  - the 15 second stream bound shared by `Invoke-BoundedProcess`, `Complete-AnimatedDispatchJob`, `Complete-ImageDispatchJob`, and both `magick` pre-conversion detours;
  - `Complete-AnimatedDispatchJob` and `Complete-ImageDispatchJob`;
  - `Get-ChapterAnimatedStatus` and `Get-ChapterProgressStatus`;
  - `Test-AvifWebpPairPresent` and the inline copy in `ZipPipeline.ps1`'s zip worker (that module's harness doesn't load this one);
  - the "non-empty `.webp` exists" check also in `Controller.ps1`'s Full Pipeline animated job builder;
  - the abort check before `Test-AvifAnimated`, the once-per-chapter queued-to-in-progress flip, the abort-poll callback pattern, and the try/catch around `Process.Start` in `jobStarter` (also in `Controller.ps1`).
- The try/catch around `Process.Start` in `jobStarter` matters: an uncaught start failure leaves `$job.Proc` null, `jobPollCompleted` never sees an exit, and the dispatch loop hangs. The catch logs, counts a failure, and rethrows so `Invoke-ChapterDispatch` can account for the job.
- State that must latch across calls inside closures (`$chapterProviderState`, `$abortState`) lives in hashtables because a plain scalar assigned inside a `GetNewClosure()` scriptblock doesn't persist.
- Unlike Image Conversion, this module's chapter provider doesn't check `Test-AbortSignal` between series; it relies on the dispatch loop and token for abort.

---

## Summary.ps1

Builds the end-of-run summary. It covers three things: the counter hashtable that pipelines write into (`New-StatsTracker`), elapsed-time formatting (`Format-ElapsedTime`), and turning the counters into report lines and printing them (`Get-SummaryLines`, `Write-SummaryReport`). `Controller.ps1` is the caller. It creates the counters, formats the elapsed time, builds the lines from the resolved mode flags returned by `Menu.ps1`, and then calls `Write-SummaryReport`.

**Main functions**

| Function | What it does |
|---|---|
| `New-StatsTracker` | Returns a new hashtable with every counter at zero. Each call returns an independent copy. |
| `Format-ElapsedTime -Elapsed <timespan>` | Returns the time as `HHh MMm SSs`, zero-padded. |
| `Get-SummaryLines -Stats <hashtable> -ElapsedString <string> -ModeFlags <hashtable>` | Returns the report as an array of strings. Only the sections for modes that ran are included. |
| `Write-SummaryReport -Lines <string[]> -FullLogging <bool>` | Prints each line at Summary level. When full logging is off, it also writes the same lines to the summary log file. |

**How it works**

- Counter keys: `LooseImgConverted`, `LooseImgDeleted`, `LooseStaleCleaned`, `CoversNormalized`, `LooseAnimatedConverted`, `LooseAnimatedDeleted`, `LooseFolderZipped`, `LooseFolderDeleted`, `ZipOnlyZipped` and `ZipOnlyFolderDeleted` each hold `Success` and `Fail` counts. The converted and zipped keys also hold `Skipped`. `InspectFailed` holds only `Count`. There are also top-level `Aborted` (boolean) and `ForceKilledCount` (integer) values.
- `Get-SummaryLines` adds sections based on the mode flags: `RunImageConversion` adds four rows (the fourth is "Covers Normalised", shown even at zero like the others), `RunAnimatedConversion` adds two, and `RunZip` and `RunZipOnly` add two each. The "Inspect Failed" row appears when either conversion flag is set. It is kept apart from the Fail counts because it means the file could not be checked for animation, not that a conversion failed. A missing flag counts as off.
- Every report then has a `Time taken` line. If `Stats.Aborted` is true, it adds a "Run was ABORTED" line with the `ForceKilledCount` value and ends with `=== Processing ABORTED ===`. Otherwise it ends with `=== Processing complete ===`.
- `Get-SummaryLines` returns with `return ,` so the array reaches the caller intact.
- `Format-ElapsedTime` uses the total hours, so a run longer than a day shows as `25h 05m 09s` rather than wrapping.
- `Write-SummaryReport` writes a blank line first. Each report line goes through `Write-Log -Level Summary -ForceConsole`, so the summary still appears when Clean Console Output is on. When `FullLogging` is false, the same lines are also written as one block by `Write-SummaryLog`. When it is true, that file write is skipped and the lines reach the log only through `Write-Log`.

**Things to watch out for**

- `-ForceConsole` is required. Without it, `Write-Log` drops console output whenever Clean Console Output is on, and the summary would not show on screen at all.
- The module calls `Write-Log` and `Write-SummaryLog` from `Logging.ps1`. Dot-source that file before calling anything here.
- `Get-SummaryLines` reads counters by these exact key names. A pipeline that writes a counter under a different name will have its results silently left out of the report.
- A missing counter field prints as a blank value rather than raising an error.
- `Get-SummaryLines` expects `ElapsedString` already formatted. It does not call `Format-ElapsedTime` itself.

---

## UnwantedImage.ps1

The Cover Deletion backend. It finds images that match known unwanted images (for example advertisement cover pages added by a scan source) and deletes them, and it can report files with trailing-zero names. `Menu.ps1`'s Cover Deletion submenu calls it, and Full Pipeline can call `Invoke-UnwantedImageScan` as a pre-scan when "Run Cover Deletion Before Conversion" is on.

An image counts as unwanted only if it matches a stored profile on size, dimensions and SHA-256 hash. Nothing is deleted on a looser match.

**Main functions**

| Function | What it does |
|---|---|
| `Invoke-UnwantedImageScan` | Scans a folder tree, deletes (or in dry-run mode only reports) files that match a profile, and returns a totals hashtable. |
| `Test-UnwantedImageMatch` | Checks one file against the profiles: size, then dimensions, then hash. Returns a status of `Match`, `HashMismatch`, `HashFailure` or `NoMatch`. |
| `Get-AllUnwantedImageProfiles` | The profiles to match against: everything saved in the profiles file. |
| `Import-UnwantedImageProfiles` / `Export-UnwantedImageProfiles` | Load and save the user's profiles at `%LOCALAPPDATA%\ConversionScript\unwanted-image-profiles.json`. |
| `Show-AddUnwantedImageProfileFlow` | The interactive "Add Image" flow: asks for a path and label, shows what was read, asks Y/N, then saves. |
| `Add-UnwantedImageProfileFromFile`, `New-UnwantedImageProfileFromFile`, `Add-UnwantedImageProfile` | Build a profile from a real image file (dimensions, size, SHA-256) and save it. A profile whose hash already exists is refused. |
| `Invoke-TrailingZeroAudit` | Finds files whose names end in `_000`, `_00` or `_0`, groups them by hash, and writes a text report. Never deletes. |
| `Get-TrailingZeroGroups`, `Get-TrailingZeroReportLines`, `Test-TrailingZeroName` | The scan, report text builder, and name test behind the audit. |
| `Get-ScannableFiles`, `Get-ImageDimensions` | Recursive file listing, and image width/height through `System.Drawing`. |
| `Get-UnwantedImageProfilesPath`, `Get-TrailingZeroReportPath` | `unwanted-image-profiles.json` and `trailing-zero-report.txt` under `%LOCALAPPDATA%\ConversionScript\`. |

**How it works**

- Profiles hold `Label`, `Width`, `Height`, `SizeBytes`, `SizeTolerance` (5000 bytes by default) and `Hash`.
- `Test-UnwantedImageMatch` goes cheapest first and skips to the next profile as soon as a check fails. A profile is tried only if the file size is within `SizeTolerance` of its `SizeBytes`. Dimensions are read once and the hash computed once per file, however many profiles are checked. A file counts as a `Match` only when width, height and SHA-256 hash all equal the profile's. If the size and dimensions fit but the hash differs, the status is `HashMismatch`. If the hash can't be computed, it returns `HashFailure` right away.
- `Invoke-UnwantedImageScan` lists every file under the folder, then only looks at those with an image extension (`.jpg .jpeg .png .webp .bmp .gif .tiff .tif`). The full file list is returned as `AllScannedFiles` so the trailing-zero audit can reuse it. It checks `Test-AbortSignal` before every file and stops early on Ctrl+C, reporting how many files were never scanned.
- A match is deleted through `Remove-Source`, so it follows the Permanent Delete setting (Recycle Bin by default). If `Remove-Source` returns `$false` the file is counted as "already gone". If it throws (for example the Recycle Bin can't take it), the error is logged and counted as a delete failure; the scan continues. A `HashMismatch` is logged as a warning and the file is not deleted.
- Dry run (`-DryRun $true`) logs `WOULD DELETE` lines and counts them in `WouldDeleteCount`, not `DeletedCount`, and deletes nothing.
- The totals hashtable has `ScannedCount`, `DeletedCount`, `WouldDeleteCount`, `DeleteFailedCount`, `HashMismatchCount`, `HashFailureCount`, `AlreadyGoneCount`, `Aborted` and `AllScannedFiles`. A `Summary`-level line with the counts is always logged. Per-file results use `-ForceConsole` so they show even with Clean Console Output on.
- `Import-UnwantedImageProfiles` returns an empty list for a missing file. A file that isn't valid JSON is copied to `<file>.corrupt-<timestamp>.bak` and only then rewritten as an empty list (if the backup fails, the file is left alone with a warning). A bad entry in an otherwise valid file is skipped with a warning and doesn't affect the other entries or the file.
- `Add-UnwantedImageProfile` rejects a new profile if a saved one already has the same hash.
- `Get-TrailingZeroGroups` checks all file types (not only images), computes SHA-256 for each trailing-zero file, and groups identical files, keeping each distinct folder they appear in. `Invoke-TrailingZeroAudit` writes the report only if at least one group is found, and returns `ReportPath = $null` otherwise.

**Things to watch out for**

- Needs `Logging.ps1` (`Write-Log`), `FileDeletion.ps1` (`Remove-Source`) and `AbortPipeline.ps1` (`Test-AbortSignal`) loaded first. The scan runs on the main thread; it does not use worker runspaces.
- `Invoke-UnwantedImageScan` reads `$script:PermanentDelete` directly, only to word the "Deleted (permanently / Recycle Bin)" message. That works on the main thread only; the deletion itself goes through `Remove-Source`.
- `Add-Type -AssemblyName System.Drawing` is needed for image dimensions; a file `System.Drawing` can't read has no dimensions and never matches.
- `Import-UnwantedImageProfiles` has a near-copy of `Config.ps1`'s corrupt-file recovery in `Import-ScriptSettings`. Keep the two in sync.
- `Get-ScannableFiles` and `Get-TrailingZeroGroups` each build the excluded-path set with a `foreach` and `Add` (not the `HashSet` constructor, which throws on `$null`). Each copy's comment names the other; keep them in sync.
- `Get-AllUnwantedImageProfiles` and `Import-UnwantedImageProfiles` return arrays with a leading comma so an empty or single-item result isn't collapsed into `$null` or a bare hashtable. Keep that when changing them.
- `Get-ScannableFiles` uses `-ErrorAction SilentlyContinue`, so folders it can't read are skipped silently.

---

## Menu.ps1

The interactive console menus: the main mode menu, the options menu with its submenus, and the Cover Deletion submenu. The Controller's main loop calls `Get-SelectedMode` to find out what to run, and `Show-PostRunPrompt` after a run. The options menu saves changes straight to `settings.json` through `Config.ps1`; the Cover Deletion submenu is wiring around `UnwantedImage.ps1`.

The menu is: 1 Full Pipeline, 2 Image Conversion, 3 Animated Conversion, 4 Zip Folders, 5 Cover Deletion, 0 Options.

**Main functions**

| Function | What it does |
|---|---|
| `Get-SelectedMode` | Shows the main menu until a mode is chosen, logs `Mode selected: <name>`, and returns the mode hashtable. |
| `Show-ModeMenu` | The main menu loop. Handles `0` (options) and `5` (Cover Deletion) itself and loops back; returns only when 1-4 is chosen. |
| `Resolve-ModeSelection` | Maps `1`-`4` to `@{ Mode; RunImageConversion; RunAnimatedConversion; RunZip; RunZipOnly }` (modes `FullPipeline`, `ImageConversion`, `AnimatedConversion`, `ZipFolders`). Anything else returns `$null`. |
| `Get-OptionsMenuSchema` | The options menu as data: an array of `Submenu`, `Bool`, `Int` and `Action` items, with the setting key, range and description for each. |
| `Show-OptionsMenuLevel` | One recursive renderer and handler for any schema level. Bool items toggle, Int items prompt for a value, Submenu items recurse, Action items call a handler. |
| `Format-OptionsMenuLines` | Builds the text lines for one options level, with current values. |
| `Show-CoverDeletionMenu` | The Cover Deletion submenu loop. |
| `Invoke-CoverDeletionRun` | Option 1: asks for a folder, checks the Recycle Bin, runs `Invoke-UnwantedImageScan`. |
| `Invoke-TrailingZeroAuditRun` | Option 5: asks for a folder, runs `Invoke-TrailingZeroAudit`, then opens the report. |
| `Get-CoverDeletionMenuLines`, `Get-CoverDeletionSetting`, `Set-CoverDeletionToggle`, `Save-LastCoverDeletionPath`, `Get-PathWithDefault`, `Invoke-CoverDeletionAction` | Cover Deletion helpers. |
| `Show-PostRunPrompt` | "Press any key to return to the main menu, or press Esc to exit." Returns `ReturnToMenu` or `Exit`. |
| Others | `Get-ModeMenuLines`, `Clear-MenuScreen`, `Open-FolderInExplorer`, `Invoke-OptionsMenuAction`, `Get-OptionsIntRangeText`. |

**How it works**

- Every prompt goes through a `-PromptFunc` scriptblock (default: `Read-Host`). Screen clearing, the options-menu actions, and every Cover Deletion step (run, add image, trailing-zero audit, open folder) are also injectable scriptblocks. This lets `Modules\_Harness\Menu.Harness.ps1` drive whole menu sessions with canned input.
- Options menu layout: 1 Full Pipeline Settings, 2 Image Conversion Settings, 3 Animated Conversion Settings, 4 Zip Settings, 5 Logging (Full Logging, Disable Summary File, Clean Console Output), 6 Permanent Delete, 7 Open Settings File Location. Adding an option means editing the schema, not the loop.
- Every Bool toggle and accepted Int value is applied to the in-memory `$Settings` hashtable and written to the settings file immediately through `Export-ScriptSettings`. A blank Int entry cancels; a non-number or out-of-range entry shows "Invalid value." and changes nothing.
- All three menu loops (`Show-ModeMenu`, `Show-OptionsMenuLevel`, `Show-CoverDeletionMenu`) clear the screen before redrawing, and show a one-shot yellow notice such as "Invalid selection." under the menu. Clearing is skipped when output is redirected.
- Choosing `5` in the main menu does not return to the Controller. Before opening the submenu, `Show-ModeMenu` does the setup a normal run gets: calls `-ReinitLogPathsHandler` if Full Logging or Disable Summary File changed in the options menu, then `Initialize-CleanConsoleOutput`, `Initialize-FileDeletion` and `Start-LogRun`. It marks the abort handler active, turns off console QuickEdit if it was on, and blocks system sleep so Ctrl+C and long scans behave as in a real run. All of that is undone in a `finally`, along with `Complete-AbortDrain` and `Complete-LogRun`.
- Cover Deletion menu items: 1 Run, 2 Add Image, 4 Open Profile Location, 5 Trailing-Zero Report, 6 Dry Run toggle, 7 Ask For Folder toggle, 0 Back. There is no item 3.
- Cover Deletion folder choice: with Ask For Folder off and a target folder known, a run scans that target folder. Otherwise it prompts, offering the last used folder (`LastCoverDeletionPath`) as the Enter default, and saves the folder it was given back to settings.
- Cover Deletion Run: if Dry Run is off, it first calls `Get-RecycleBinRefusalMessage` and refuses to scan when the drive has no Recycle Bin and Permanent Delete is off. After a scan that ran, it automatically runs the trailing-zero audit on the files that still exist, reusing the scan's file list so the folder isn't walked twice.
- The Cover Deletion screen is not cleared after Run, Add Image or the trailing-zero report, so their output stays readable; it is cleared on the next redraw after a non-output choice.

**Things to watch out for**

- Needs `Config.ps1` (`Export-ScriptSettings`, `Get-DefaultScriptSettings`), `Logging.ps1`, `FileDeletion.ps1`, `AbortPipeline.ps1` (the abort, QuickEdit and sleep functions used around Cover Deletion) and `UnwantedImage.ps1` loaded before the menus run.
- The "clear, redraw, show notice" loop is duplicated in `Show-ModeMenu`, `Show-OptionsMenuLevel` and `Show-CoverDeletionMenu`. Each copy has a comment naming the others; keep all three in sync.
- The run bracket around Cover Deletion in `Show-ModeMenu` (sleep block and so on) duplicates the one in `Invoke-MainLoop` in `Controller.ps1`. Keep both in sync.
- Scriptblock handlers return values that would otherwise leak into a function's output (for example the open handler in `Invoke-TrailingZeroAuditRun`); callers assign them to `$null` so the function still returns the one result hashtable. Do the same with new handlers.
- `Open-FolderInExplorer` wraps the path in quotes itself because PowerShell 5.1's `Start-Process -ArgumentList` doesn't, and paths with spaces would be split.
- A few `lint:ignore` comments in this file mark places where the lint harness's name matching hits an unrelated variable in another function; they are not skipped checks.

---

## Controller.ps1

The top of the tool. It holds Full Pipeline (convert images, convert animated AVIF, zip each finished chapter, delete the chapter folder) plus `Invoke-Mode`, which runs whichever mode the menu picked, and `Invoke-MainLoop`, the menu-run-summary loop that `Conversion Script Main.ps1` hands off to once it has loaded settings and the modules.

**Main functions**

| Function | What it does |
|---|---|
| `Invoke-MainLoop` | The program's outer loop: show the menu, set up logging and console state, run the chosen mode, print the summary, ask whether to run again. |
| `Invoke-Mode` | Runs one resolved menu choice (Image Conversion, Animated Conversion, Zip Folders, Full Pipeline) and copies the pipeline's result into a stats tracker for the summary. |
| `Invoke-FullPipeline` | Full Pipeline: starts two engine workers, merges their per-chapter results on the main thread, then zips and deletes finished chapters. Returns a totals hashtable. |
| `$script:fullPipelineEngineWorker` | The scriptblock each engine runs inside its own runspace (image engine or animated engine). |
| `Complete-MergedFullPipelineChapter` | Main-thread step for one chapter once both engines have reported: merge status, delete orphaned scratch files, zip, verify, delete the folder. |
| `Get-MergedChapterStatus` | Combines the image and animated results into one Success / Warning / Error status and a detail string; the worse status wins. |
| `Get-OrCreateFullPipelineSeriesBundle`, `Get-OrCreateFullPipelineChapterClassification`, `Get-OrCreateFullPipelineCacheEntry` | Shared per-series and per-chapter caches so the two engines don't scan or classify the same thing twice. |
| `Add-FullPipelineZipBlockReason` | Records, thread-safely, why a chapter must not be zipped. |

**How it works: Full Pipeline**

- **Two engines, one process budget.** `Invoke-FullPipeline` starts an image engine and, if animated conversion is enabled, an animated engine. It does this with `Invoke-ZipParallelProcessing`, where each "job" is one whole engine (`-MaxParallel` equals the engine count). Each engine's worker runs `Invoke-ChapterDispatch` over every series and chapter in the library. Both share one `SemaphoreSlim` sized to `FullPipelineMaxConcurrentProcs`, so cjxl and magick processes together never exceed it.
- **Engine worker.** Each engine builds its own series/chapter provider and its own job builder, starter, poll, finalize and abort-cleanup scriptblocks. The image engine builds one cjxl job per image (via a magick-to-PNG step first for formats cjxl can't read, such as AVIF, WebP, BMP, HEIC/HEIF and TIFF). It skips animated WebP and the extensions the project never converts. The animated engine builds one magick job per animated AVIF. Completing a job reuses `Complete-ImageDispatchJob` / `Complete-AnimatedDispatchJob` from the pipeline modules.
- **Shared caches.** The first engine to reach a series builds its bundle (chapters, loose images, animated candidates, "extra" folders that aren't chapters) and the other engine reuses it. After getting a series' bundle, the image engine (which always runs) calls `Invoke-SeriesCoverNormalization` on it, outside the bundle's lock so a slow cover conversion never holds up the animated engine; both candidate scans already skip series-root covers, so the order doesn't matter. Its counts travel on a `CoverNormalized` event into the totals' `CoverNormalizedSuccess`/`CoverNormalizedFail`, which `Invoke-Mode` maps to the summary's "Covers Normalised" row (Image Conversion's totals carry the same two fields). The first to reach a chapter classifies it: each AVIF in a chapter is checked for animation once, and is then given to exactly one engine (static to the image engine, animated to the animated engine, undeterminable to neither). Stale loose sources are cleaned there too. Each cache slot is guarded so its factory runs once even when both engines ask at the same moment.
- **Events instead of shared state.** Workers don't touch the console or the totals. They put small event hashtables on a `ConcurrentQueue` (`SeriesReady`, `CoverNormalized`, `ChapterStarted`, `ChapterRunning`, `ChapterInspectFailed`, `ChapterStaleCleanup`, `AbortMessage`, `EngineChapterDone`). The main thread drains the queue from `Invoke-ZipParallelProcessing`'s poll callback.
- **Merge on the main thread.** Each engine sends `EngineChapterDone` for every chapter it handled (with `Result = $null` if it had nothing there). The first event creates a merge entry; when both engines have reported (or immediately, if animated conversion is off), the chapter is finalized: totals are updated, then `Complete-MergedFullPipelineChapter` zips and deletes. Zipping and folder deletion therefore happen on the main thread while the engines keep working on later chapters. A chapter is marked merged when finalizing ends, which releases any engine that was holding it (see `-ChapterReleaseCheck` in `ChapterDispatch.ps1`).
- **When a chapter is zipped.** The chapter must be zippable (a real chapter folder, not an "extra" folder converted in place), have no zip-block reason, have no `.avif`/`.webp` pair left in it, merge to a non-Error status, and the run must not be cancelled. Zipping removes leftover scratch files from earlier interrupted conversions, runs `Compress-FolderToZip`, verifies the zip with `Test-ZipArchive` (requiring a `.jxl` entry if any image was actually converted), then deletes the folder with `Remove-Source` (Recycle Bin unless Permanent Delete is on). If zipping fails, the partial zip is deleted and the folder is left alone. A chapter that was converted but not zipped gets a status that says why.
- **Zip block reasons** currently come from filename collisions in the chapter, an AVIF whose animation check failed, and an `.avif`/`.webp` pair in the chapter.
- **Crash and abort handling.** If an engine's runspace throws, `-JobCrashedHandler` marks the run aborted, logs it, and cancels the run's cancellation source so the other engine stops. After the engines finish, any chapter still in the merge table where one engine never reported is not zipped and not deleted; whatever results did arrive are still added to the totals, and a warning is logged if the chapter had been started. The run's cancellation source is registered with `Register-AbortCancellationSource` so Ctrl+C reaches it.
- **Cover Deletion first (optional).** With `-RunCoverDeletionBeforeConversion`, the Cover Deletion scan (`Invoke-UnwantedImageScan`) runs before anything else. If it throws, the user is asked whether to continue; any answer other than Y aborts the run.
- **Clean Console Output.** When it's on, series and chapters are announced only once an engine actually has work for them (or when a zip-only chapter reaches the merge step), so the progress display isn't flooded with chapters that need nothing.
- **Result.** The totals hashtable counts conversions, deletions, stale cleanups, zips, folder deletions, force-killed jobs, inspect failures, series, chapters and `Aborted`.

**How it works: Invoke-Mode and Invoke-MainLoop**

- `Invoke-Mode` first refuses to run when the target would hit the Recycle Bin and `Get-RecycleBinRefusalMessage` says it can't (logs the message, returns `$null`). The one exception is Animated Conversion with source deletion off. Animated Conversion and Full Pipeline need `magick.exe`, otherwise it throws. It raises the .NET thread-pool minimum with `Initialize-ChildProcessReadThreadPool`, creates a stats tracker, calls the matching handler, and maps its result onto the tracker. Exceptions go to `Invoke-AbortOrFatalHandler`; the function returns `$null` in that case.
- Each mode handler (Image, Animated, Zip, Full Pipeline) is a parameter defaulting to the real function, so tests can substitute a fake.
- `Invoke-MainLoop` loops forever until the post-run prompt returns `Exit`. Each iteration: `Reset-AbortState`, get the mode from the menu, re-initialize log paths if Full Logging or Disable Summary File changed, apply the Clean Console and permanent-delete settings, start the log run, mark the abort handler active, turn QuickEdit off if it was on, and block system sleep. It then runs the mode. A `finally` restores sleep, QuickEdit and `RunActive`, and always calls `Complete-AbortDrain`. Afterwards it prints the summary (`Get-SummaryLines`, `Write-SummaryReport`) and completes the log run. If the menu or the run returned nothing, it logs "Run did not complete" and goes back to the prompt.
- Every external dependency of `Invoke-MainLoop` is a parameter defaulting to the real function (menu, abort handlers, QuickEdit, sleep block, logging), so tests can drive it with fakes.

**Things to watch out for**

- **Worker-runspace rules.** The engine worker and everything it calls run in a runspace with only the functions listed in `$engineWorkerSharedFunctionNames` (built from each module's `Get-...SharedFunctionNames` plus a hand-written list of Controller and helper functions). So worker code must not read the main script's `$script:` state (the worker sets its own `$script:workerConsoleQueue` and `$script:PermanentDelete` at the top and reads them through `Get-WorkerRunspaceValue`), must not call anything not in that list, and must not call cmdlets that are unsafe to run for the first time concurrently in two fresh runspaces; the code uses .NET calls (`[System.IO.File]::Delete`, `Get-FilesRecursiveSafe` and so on) instead. Don't pass a scriptblock into a .NET API as a delegate (for example as a callback to a task or event); use the process and task APIs the way the existing code does.
- A new function that the worker calls directly or indirectly must be added to `$engineWorkerSharedFunctionNames` (or its module's getter). `Lint.Harness.ps1` checks this. It has one known exception: `Write-GatedConsoleMessage` is deliberately left off the Controller list (its calls sit in main-thread-only branches).
- **Closures and state.** The worker's scriptblocks use `.GetNewClosure()`. A plain variable assigned inside one doesn't persist between calls and `$script:` reads inside one don't see the real script scope, so the code keeps changing state in hashtables (`$totals`, `$abortState`, `$chapterProviderState`) and reads settings through handler functions. Mutating a captured hashtable works; rebinding a captured scalar doesn't.
- **Main thread vs worker.** Totals, console output, Clean Console Output calls, zipping and deleting folders happen only on the main thread (in the poll callback and the post-run loop). Workers only produce events and per-chapter result hashtables.
- **Documented duplicates.** Several blocks mirror code in `ImageConversionPipeline.ps1` and `AnimatedConversionPipeline.ps1`, and each copy has a "DOCUMENTED DUPLICATE" comment naming the others. Change them together: the per-file animation check before each AVIF inspection, the once-per-chapter "queued to in progress" event in the job starters, the magick-to-PNG pre-conversion (bounded wait with kill, bounded stream reads, `%` doubled in the output path), the format-label switch, the zero-byte `.webp` check, the abort-poll callback's once-only message, and the abort-cleanup counter. The `Invoke-MainLoop` sleep-block bracket mirrors the one in `Menu.ps1`'s Cover Deletion option.
- `Get-ZipBlockedStatusOverride` is defined in `ImageConversionPipeline.ps1`, not here. Controller depends on the pipeline modules, `Menu.ps1`, `Summary.ps1`, `UnwantedImage.ps1`, `Logging.ps1`, `FileDeletion.ps1`, `ZipCreation.ps1`, `ZipValidation.ps1`, `LeafDirectoryDiscovery.ps1`, `ChapterDispatch.ps1`, `ZipParallelProcessing.ps1` and `AbortPipeline.ps1` all being dot-sourced first.
- The merge step never zips a chapter it only has half the information about. If you change how results or the `Got...` flags are tracked, keep that guarantee.
- Both engines' result handlers and the crash handler run on the main thread and must not throw; they only update `$totals` and cancel the token.

---

