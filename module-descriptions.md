# Module Descriptions

Every module's own top-of-file `.SYNOPSIS`/`.DESCRIPTION`/`.NOTES` comment
block, migrated out of the source files themselves to keep those files
short and code-forward. Each module's own file now carries a one-line
pointer back here instead of the full block.

One section per file, in the same order Conversion Script Main.ps1
dot-sources them.

---

## ZipValidation.ps1

**Synopsis:** ZipValidation - Test-ZipArchive, the post-creation ZIP sanity check
used by Full Pipeline (1) and Zip Folders (4).

**Description:** Pure definitions only - no top-level side effects, safe to dot-source
more than once or alongside other modules. No cross-module
dependencies - this module is fully standalone.

This module owns its own Add-Type call for
System.IO.Compression.FileSystem rather than relying on a caller to
have hoisted it - same reasoning as ZipCreation.ps1/FileDeletion.ps1.
No guard needed: Add-Type -AssemblyName is idempotent (verified live
elsewhere in this project).

**Notes:** Extracted from Conversion Script Main.ps1 - see
Modules\_Reference\ZipValidation.reference.ps1 for the verbatim source
this was built from, with original line numbers.

---

## ZipCreation.ps1

**Synopsis:** ZipCreation - Compress-FolderToZip, the shared folder-to-ZIP step used
by Full Pipeline (1) and Zip Folders (4).

**Description:** Pure definitions only - no top-level side effects, safe to dot-source
more than once or alongside other modules. This module owns its own
Add-Type call for System.IO.Compression.FileSystem rather than relying
on a caller to have hoisted it - each module self-contained, matching
FileDeletion.ps1's reasoning. No guard needed: Add-Type -AssemblyName
is idempotent (verified live elsewhere in this project) - the guard
ConsoleCtrl needs in AbortPipeline.ps1/ZipParallelProcessing.ps1 is
specifically for -TypeDefinition, a different case.

This "owns its own Add-Type" self-containedness only holds for a normal
dot-source. `-SharedFunctionNames` (see "Modularization" in `CLAUDE.md`)
only propagates function DEFINITIONS into a fresh runspace, not this
module's top-level `Add-Type` statement - a runspace caller that reaches
`Compress-FolderToZip` via `-SharedFunctionNames` alone, without also
dot-sourcing this file (or something else that already loaded
`System.IO.Compression.FileSystem`) inside that runspace, does not get
this module's own Add-Type for free. Harmless today (every current
runspace caller of `Compress-FolderToZip` already loads the assembly
some other way), but the module is not actually self-contained for that
call path the way the description above implies.

FORWARD REFERENCES (not defined in this module - callers must
dot-source the owning module first, matching the pattern already
established by Logging.ps1's Move-ToRecycleBin forward reference):
  - Write-Log (Modules\Logging.ps1)
  - Remove-Source and $script:PermanentDelete (Modules\FileDeletion.ps1) -
    used to clear a pre-existing same-name ZIP before overwriting, and
    to describe (Recycle Bin vs. permanent) how it was cleared.
  - Remove-ItemPermanently (Modules\FileDeletion.ps1) - used to clean up
    a stray/broken ZIP CreateFromDirectory can leave behind when it
    throws (see Compress-FolderToZip's own notes in function-notes.md).

Modules\_Harness\ZipCreation.Harness.ps1 stubs all three, since this
module must stay standalone-testable without FileDeletion.ps1/
Logging.ps1 existing.

**Notes:** Extracted from Conversion Script Main.ps1 - see
Modules\_Reference\ZipCreation.reference.ps1 for the verbatim source
this was built from, with original line numbers.

---

## Summary.ps1

**Synopsis:** Summary - the clean-run (non-aborted) summary report: the $stats
counter shape every pipeline module writes into, elapsed-time
formatting, and building/writing the final report.

**Description:** Pure definitions only - no top-level side effects, safe to dot-source
more than once or alongside other modules.

Forward-references (Modules\Logging.ps1):
  - Write-Log (used at -Level Summary for each report line)
  - Write-SummaryLog (writes the report to the separate Summary log
    file, when not in full-logging mode)

NOT extracted here, on purpose (see Modules\_Reference\Summary.reference.ps1
for the full reasoning): the two ABORT-path summaries (old mode 4's
and old modes 1/2's) - those carry abort-specific content (trigger
label, "last completed jobs", forced-stop counts) that's AbortPipeline.ps1's
territory more than this module's. Format-ElapsedTime below is written
so those can eventually call it too (all three call sites used the
exact same one-liner in the reference) - not wired up yet.

REGATED onto Menu.ps1's mode-flags shape, not the reference's four
independent $runZipPhase/$runLooseConv/$runLooseZip/$runZipOnly
booleans - Get-SummaryLines takes one -ModeFlags hashtable matching
Resolve-ModeSelection's real output (RunImageConversion/
RunAnimatedConversion/RunZip/RunZipOnly), so a caller can pass
Get-SelectedMode's actual return value straight in.
A new Loose Animated Converted/Deleted row-group was added (gated on
RunAnimatedConversion) since AnimatedConversionPipeline.ps1 has no
reference-extraction equivalent to draw from - same "designed ahead
of the module" situation as Config.ps1's Animated* keys. Field names
confirmed against the real module: the animated conversion machinery
produces ConvertedSuccess/ConvertedFail/ConvertedSkipped/DeletedSuccess/
DeletedFail output that these fields directly map onto, tested in
Controller.Harness.ps1.

InspectFailed gets its own field, kept out of every engine's Fail
count. A file we couldn't determine is animated or not (a real
Test-AvifAnimated failure) is a different kind of outcome than a
conversion that actually failed - same distinction this module
already draws for StaticSkippedCount getting no row at all (a static
AVIF being left alone is expected, while InspectFailed is a genuine
"couldn't tell" problem worth reporting). Both the image and animated
engines can hit this failure mode independently, so it's shown as one
shared line whenever either RunImageConversion or
RunAnimatedConversion is active, rather than two near-duplicate rows.

**Notes:** Extracted from Conversion Script Main.ps1 - see
Modules\_Reference\Summary.reference.ps1 for the verbatim source this
was built from, with original line numbers, and the reasoning behind
what's deliberately NOT included.

---

## DependencyDetection.ps1

**Synopsis:** DependencyDetection - Find-Exe, a generalized executable-locator used
for cjxl/magick (and eventually ffmpeg) detection.

**Description:** Pure definitions only - no top-level side effects, safe to dot-source
more than once or alongside other modules.

Built around Convert-AnimatedToJxl.ps1's Find-Exe shape rather than
keeping the main script's Find-Cjxl/Find-Magick as two near-identical
hardcoded copies - per the explicit decision in this module's
reference extraction (Modules\_Reference\DependencyDetection.reference.ps1).
A caller migrating off Find-Cjxl/Find-Magick calls Find-Exe directly
with its own -ExeName/-Candidates, rather than through any
tool-specific wrapper function - none is provided here, on purpose.

Lookup order: -UserPath (if supplied and it exists) > PATH (via
Get-Command) > -Candidates, in order > $null if nothing matched.

Find-ExeCached wraps Find-Exe with a settings-hashtable-backed cache
(see Modules\Config.ps1) so a caller doesn't repeat the PATH/
-Candidates search every single run once a tool's been found once.
It takes/mutates a plain hashtable rather than depending on
Config.ps1's Import-/Export-ScriptSettings directly, so this module
stays standalone (no cross-module dependency, no forward reference to
load/save) - the caller owns loading the settings in and persisting
them back out (e.g. Import-ScriptSettings before, Export-ScriptSettings
after).

**Example:**
```powershell
Find-Exe -UserPath $CjxlPath -ExeName "cjxl" -Candidates @(
    ($env:ProgramFiles + "\libjxl\cjxl.exe"),
    ($env:ProgramFiles + "\cjxl\cjxl.exe"),
    ($env:LOCALAPPDATA + "\Programs\libjxl\cjxl.exe"),
    "C:\tools\cjxl.exe"
)
```

**Example:**
```powershell
Find-Exe -UserPath $MagickPath -ExeName "magick" -Candidates @(
    ($env:ProgramFiles + "\ImageMagick-7\magick.exe"),
    ($env:ProgramFiles + "\ImageMagick\magick.exe"),
    ($env:ProgramFiles + " (x86)\ImageMagick-7\magick.exe"),
    ($env:LOCALAPPDATA + "\Programs\ImageMagick\magick.exe"),
    "C:\tools\ImageMagick\magick.exe"
)
```

**Notes:** Extracted from Conversion Script Main.ps1 (Find-Cjxl/Find-Magick) and
Backups\Old Scripts\Convert-AnimatedToJxl.ps1 (Find-Exe, the shape
this module is built around) - see
Modules\_Reference\DependencyDetection.reference.ps1 for the verbatim
source, with original line numbers.

---

## FileDeletion.ps1

**Synopsis:** FileDeletion - Move-ToRecycleBin, Remove-ItemPermanently, and the
Remove-Source wrapper every mode calls to delete an original/source
file or folder.

**Description:** Pure definitions only - no top-level side effects, safe to dot-source
more than once or alongside other modules (matches Logging.ps1/
AbortPipeline.ps1's pattern). This module owns its own Add-Type call
for Microsoft.VisualBasic (Recycle Bin support) rather than relying on
a caller to have hoisted it - each module self-contained. No guard
needed around it (unlike ConsoleCtrl in AbortPipeline.ps1/
ZipParallelProcessing.ps1): Add-Type -AssemblyName is idempotent -
calling it twice does not
throw. The guard those two modules use is specifically for
-TypeDefinition (compiling custom C# source), which DOES throw on a
duplicate type name - a different case, not applicable here.

State this module owns: $script:PermanentDelete, set once via
Initialize-FileDeletion (matches Initialize-LogPaths's "call once
before anything else" pattern) rather than being re-passed as a
parameter to every Remove-Source call.

Deletion-semantics convention (see CLAUDE.md): deletion of
original/source files goes through Remove-Source, which respects
$PermanentDelete (Recycle Bin by default). Deletion of job-generated
intermediates (extracted folders, temp files - never "original" data)
should call Remove-ItemPermanently directly, unconditionally,
regardless of $PermanentDelete - Remove-Source is not the right call
for that case.

Logging.ps1's Initialize-LogPaths already calls Move-ToRecycleBin as a
forward reference (it was built before this module existed for real).
Both branches (full-logging and split-log) call it, not just one -
split-log's own stale-log cleanup used to permanently Remove-Item
instead, which didn't respect the Recycle Bin setting. That call site
uses `-ItemPath <string>`, a single file path - matches this module's
real signature exactly, so no changes needed there now that this
module exists. Dot-source
FileDeletion.ps1 before Logging.ps1 (or in either order, as long as
both are dot-sourced before Initialize-LogPaths actually runs) so
Move-ToRecycleBin resolves when that cleanup code executes.

All three deletion functions return $true if ItemPath existed and was
processed, $false if it didn't exist (nothing to do) - lets a caller
log "skipped, already gone" vs. "deleted" instead of assuming the
latter. This is beyond the original reference extraction, which was
void.

Remove-ItemPermanently special-cases directory reparse points
(junctions/symlinks): a plain recursive Directory.Delete on a reparse
point is a known .NET footgun that can delete through the link into
the real target's contents instead of just unlinking it, so that path
uses a non-recursive delete instead. Verified live against a real
NTFS junction (Harness Scenarios K/L) that both this and
Move-ToRecycleBin (via the Shell-based VB FileIO Recycle Bin API,
which turned out to already be junction-safe without any change)
correctly unlink only, leaving the real target's contents untouched.

**Notes:** Extracted from Conversion Script Main.ps1 - see
Modules\_Reference\FileDeletion.reference.ps1 for the verbatim source
this was built from, with original line numbers.

---

## ZipParallelProcessing.ps1

**Synopsis:** Invoke-ZipParallelProcessing - the parallel-dispatch engine for the
zip-only pipeline (mode 3).

**Description:** This file IS the canonical definition of Invoke-ZipParallelProcessing -
not a copy kept in sync with something else. Conversion Script Main.ps1
currently still has its own separate inline copy of the same algorithm,
under the older name Invoke-ParallelFolderJobs, wired into mode 3, that
predates this module and this rename. Migrating mode 3 (and eventually
mode 4) onto this module - replacing that inline copy with a dot-source
of this file - is still open (see CLAUDE.md "Known gaps"). Until that
migration happens, changes here do NOT need to be back-ported to the
main script's inline copy, or vice versa - they're two independent
implementations of the same proven algorithm, not mirrors, and this
file's own historical notes about "copy X here if Y changes" no longer
apply.

This file dot-sources Logging.ps1/AbortPipeline.ps1 rather than
carrying its own inline ConsoleCtrl/Write-Log/Flush-ConsoleQueue/
Test-AbortSignal copies. Pure definitions only - no top-level side
effects. Dot-source
AbortPipeline.ps1 and Logging.ps1 BEFORE this file (see FORWARD
REFERENCES below); dot-source this file to get
Invoke-ZipParallelProcessing itself.

FORWARD REFERENCES (not defined in this module - callers must
dot-source the owning module(s) first):
  - ConsoleCtrl (the type), Test-AbortSignal, Register-/Unregister-
    AbortCancellationSource, Invoke-GracefulDrain (AbortPipeline.ps1)
  - Write-Log, Flush-ConsoleQueue, Initialize-LogMutex, $script:pathHash
    (Logging.ps1)

Modules\_Harness\ZipParallelProcessing.Harness.ps1 dot-sources both
real modules now instead of stubbing this file's own former inline
copies - re-verify against the real ordering rule ZipPipeline.ps1's
own header already documents: dot-source Logging.ps1/FileDeletion.ps1
BEFORE this file if anything else in the same session also dot-sources
them, since -SharedFunctionNames captures whichever definition is
CURRENTLY active in the caller's scope at call time.

ABORT REGISTRATION IS THE CALLER'S JOB, NOT THIS FUNCTION'S: matching
AbortPipeline.ps1's own documented contract (register once per
pipeline phase, right after creating that phase's CTS; unregister
when disposing it), Invoke-ZipParallelProcessing does NOT call
Register-/Unregister-AbortCancellationSource on the -Cts it's handed
- the caller that created that CTS (ZipPipeline.ps1's
Invoke-ZipOnlyPipeline) owns that lifecycle, exactly like
ImageConversionPipeline.ps1's own $looseCts. This replaces the OLD
Test-AbortSignal's hardcoded three-variable cancellation
($script:cts/$script:looseCts/$script:zipOnlyCts) with the
generalized registry - a caller no longer needs a magically-named
script-scope CTS variable to participate in abort handling.

THE GRACEFUL-DRAIN RACE CONDITION THIS MIGRATION FIXES: the old inline
drain loop force-stopped stragglers immediately after its 60s timeout
expired, with no final completion-check pass first - a job finishing
in the ~250ms gap between the last poll and the timeout firing had its
real result silently discarded and got miscounted as force-stopped
(see CLAUDE.md "Known gaps" for the full history). AbortPipeline.ps1's
Invoke-GracefulDrain already closes this (one final Receive-
CompletedHandles pass before declaring anything force-stopped) -
migrating onto it picks up that fix for mode 3 for the first time.
Also newly fixed as a side effect: the old inline drain never signalled
[ConsoleCtrl]::DrainComplete at all (a separate, already-documented gap
- CTRL_CLOSE_EVENT gives the native handler only ~5s before Windows
force-kills the process, risking a kill mid-drain) - Invoke-GracefulDrain
always signals it now.

Write-Log and Invoke-ZipParallelProcessing expect a handful of
script-scope variables to already exist in the caller's scope (log file
paths, a $pathHash for mutex naming, etc.) - see
Modules\ZipParallelProcessing.Harness.ps1 for the minimal stand-ins a
caller needs to provide, and for the actual test scenarios.

---

## Conversion Script Main.ps1

**Synopsis:** Bootstrap entry point for the modularized conversion script. Resolves
Modules\, loads persisted settings, dot-sources all 18 modules, then
runs the interactive mode menu in a loop until the user exits.

**Description:** This is a REWRITE, not the original monolithic script - see
Modules\_Reference\Conversion Script Main - Old.ps1 for that (now the
frozen reference copy; the guard's freeze protection moved to it, see
Docs/repo-guard.md). All real conversion/zip/deletion/logging logic
now lives in Modules\ - built and harness-tested independently first,
per this repo's own development process (see CLAUDE.md). This file's
only job is bootstrap (find Modules\, load settings, dot-source
everything) and the top-level dispatch loop.

MODULE-FINDING LOGIC IS INLINED, NOT DOT-SOURCED: the three functions
(Get-ExpectedModuleFileNames, Test-ModulesFolderCandidate,
Resolve-ModulesPath) can't live in Modules\ - dot-sourcing anything
from there requires already knowing where Modules\ is, which is
exactly the problem this logic solves. They used to also exist as a
standalone, separately harness-tested copy (ModuleLoading.ps1, repo
root) built to prove the logic before this rewrite existed to call
it - removed once a review confirmed the logic had no open issues and
this inlined copy had already been proven via real runs. See
CLAUDE.md's "Module loading & settings persistence" section.

DISPATCH AND MAIN LOOP: this file now just calls Controller.ps1's
Invoke-MainLoop. Everything that used to be stubbed or inlined here -
per-mode param
translation, output normalization onto Summary.ps1's $stats shape,
the shared abort/fatal-error catch (Invoke-Mode, Phase 3), AND the
run loop itself including Show-PostRunPrompt (Invoke-MainLoop, built
right after) - now lives in Controller.ps1, proven standalone by
Controller.Harness.ps1 before ever being wired in here. This file's
job really is just bootstrap now: find Modules\, load settings,
dot-source everything, resolve dependencies, hand off.

**-Path:** Root directory to operate in. Defaults to the current working
directory.

**-CjxlPath:** Optional explicit path to cjxl.exe if not found automatically.

**-MagickPath:** Optional explicit path to magick.exe if not found automatically.
Required only for WebP/AVIF input.

**-ModulesPathOverride:** Optional explicit path to the Modules\ folder, bypassing the default
script-relative location and any persisted path.

---

## ChapterDispatch.ps1

**Synopsis:** ChapterDispatch - New-LibraryChapterProvider (flattens
New-SeriesProvider + Get-SeriesChapters into one continuous lazy
chapter feed) and Invoke-ChapterDispatch (the generalized process-
dispatch/abort/drain loop extracted from earlier image-conversion
dispatch machinery and generalized to span multiple chapters instead of
one chapter's file list). See Docs\dispatch-redesign-design.md for the
full design and reasoning - this module implements that doc's "New
module: ChapterDispatch.ps1" section as written, filling in only the
details that doc left open (documented in function-notes.md, at each
such point).

**Description:** Pure definitions only - no top-level side effects, safe to dot-source
more than once or alongside other modules.

Dot-sourced at the top level by Conversion Script Main.ps1, right
after LeafDirectoryDiscovery.ps1 and before
ZipParallelProcessing.ps1/ZipPipeline.ps1/ImageConversionPipeline.ps1/
AnimatedConversionPipeline.ps1/Controller.ps1 - see that script's own
dot-source order. All four dispatch-redesign migration steps
(AnimatedConversionPipeline.ps1, ImageConversionPipeline.ps1,
Controller.ps1's two-engine dispatch) call into this module - see
Docs\dispatch-redesign-design.md.

CALLING CONVENTION - READ BEFORE WRITING A NEW CALLER:
every -JobBuilder/-JobStarter/-JobPollCompleted/-JobFinalize/
-JobAbortCleanup/-ChapterCompleteCallback/-ChapterProvider/
-AbortPollCallback scriptblock you pass in MUST be built with
.GetNewClosure() if it references ANY variable from its own
definition scope that isn't one of its own -param()s. Reason: this
module invokes every one of those scriptblocks via `& $callback`
from INSIDE Invoke-ChapterDispatch's own function body - and a plain
(non-closure) PowerShell scriptblock resolves a free variable
DYNAMICALLY, against whatever scope it's actually EXECUTING in at
that moment, not lexically against wherever it was originally
written. Confirmed live: a caller's own callback referencing
$chapterResults (its own per-chapter accumulator) silently read THIS
module's own internal $chapterResults variable instead - two
completely unrelated variables, same name, no error, wrong data -
because without .GetNewClosure() the callback's scope chain starts
from Invoke-ChapterDispatch's own local scope (where it's actually
invoked from), not AnimatedConversionPipeline.ps1's (where it was
written). This is a DIFFERENT failure mode than the closure gotcha
already documented in Docs\lessons-learned.md ("closures that lose
mutated state" - too LITTLE state capture without .GetNewClosure())
- this one is too MUCH ambient scope, in the wrong direction, also
without .GetNewClosure(). A callback that references NOTHING but its
own -param()s (this module's own JobAbortCleanup implementations
included) doesn't need .GetNewClosure() - there's no free variable to
collide on. One further wrinkle if you also do this: .GetNewClosure()
itself breaks a $script:-prefixed variable read/write from inside the
closure (it resolves against the closure's own private, isolated
scope, not the real script scope - a SEPARATE real bug, also caught
building mode 3's migration) - capture any $script: value you need
into a plain local variable BEFORE building the closure, and read
that local variable inside it instead of $script:X directly. See
AnimatedConversionPipeline.ps1's own Invoke-LooseAnimatedConversionPipeline
for a worked example of both fixes together (its own
$cleanConsoleOutputEnabled local capture, and .GetNewClosure() on
every callback that references an outer variable).

FORWARD REFERENCES: Write-Log (Logging.ps1), [ConsoleCtrl]
(AbortPipeline.ps1, a compiled type - visible from a runspace worker
without -SharedFunctionNames propagation, same as every other module
that already uses it for drain logic). Not defined here - this module's
own harness stubs Write-Log and dot-sources AbortPipeline.ps1 for the
real [ConsoleCtrl] type, matching other modules' own conventions.

DOMAIN-AGNOSTIC BY DESIGN: this module never spawns a process itself
and never knows what a "job" actually does - JobBuilder/JobStarter/
JobPollCompleted/JobFinalize/JobAbortCleanup (all caller-supplied
scriptblocks) own every piece of real domain logic (cjxl vs magick,
AVIF/WebP classification, source deletion, temp-file cleanup) exactly
where it already lives. What THIS module owns generically (extracted
from earlier image-conversion dispatch machinery, not reinvented - see
Docs/dispatch-redesign-design.md for the full history and reasoning):
  - The abort/drain TIMING sequence: [ConsoleCtrl]::IsCloseEvent fast
    path (a window-close force-kills the whole process in ~5s
    regardless, so waiting out any part of -AbortTimeoutSeconds there
    is pointless), a 250ms poll interval during the drain wait, and a
    mandatory FINAL completion-check pass immediately before force-
    killing anything (a job that finished in the last few
    milliseconds must not have its real, valid output torn down by
    JobAbortCleanup as if it were a killed process's garbage - a
    real, live-caught bug class in the original code).
  - Releasing exactly one -MaxConcurrent slot (when it's a
    SemaphoreSlim - see JOB CONTRACT below) per job on every exit
    path a job can take (normal finalize, Requeued finalize,
    JobStarter throwing, force-kill) - guarded by a per-job
    SlotReleased marker so a job already finalized earlier in the
    same poll pass can't have its slot released (or its
    JobAbortCleanup run) a second time by a later job's throw - mirrors
    the same invariant exactly.
  - Killing/waiting/disposing a job's own .Proc (see JOB CONTRACT)
    when it's still running at force-kill time.

JOB CONTRACT: every job is a [hashtable]. This module tags each job
with its own .ChapterKey (added internally, right after JobBuilder
returns - JobBuilder itself never sets it) - the exact chapterInfo
value that chapter's own -ChapterProvider call returned, not a
derived path string, compared using .NET's default equality for
whatever type chapterInfo actually is (reference equality for a
hashtable - the normal case, since a real chapterInfo is always the
SAME instance from -ChapterProvider through to
-ChapterCompleteCallback - or value equality for something like a
plain string, the common shape in this module's own harness). This is
what makes Invoke-ChapterDispatch domain-agnostic about chapter
identity too, not just job identity - it never needs to know chapters
have a ".Dir.FullName" or any other specific shape at all.
JobFinalize's -PendingQueue contract MUST copy the original
job's .ChapterKey onto any newly-enqueued retry job itself, since this
module has no other way to know a requeued job belongs to the same
chapter as the job that requeued it. JobStarter is expected to set a
.Proc property (a System.Diagnostics.Process) on the job it returns -
this module's own generic Kill()/WaitForExit()/Dispose() calls on
force-kill, and its Dispose() call after every normal JobFinalize,
are all .Proc-nullchecked, so a caller whose job represents no real
OS process at all (or a harness fake) can safely leave .Proc $null to
opt out of that machinery - JobPollCompleted then owns deciding
"done" some other way (e.g. its own flag on the job hashtable).

CHAPTER COMPLETION: JobBuilder is called exactly once per chapter, up
front, returning that chapter's FULL job list at once. ChapterCompleteCallback
fires exactly once per chapter, the moment every one of its jobs has
reached a non-Requeued JobFinalize outcome (a zero-job chapter
completes immediately, before any job ever dispatches) - never for a
chapter still holding an outstanding job when the run is cancelled or
force-killed. The design doc left the OUTPUTS' ChapterResults shape
unspecified beyond its name - this implementation returns one entry
per chapter JobBuilder was ever called for:
@{ ChapterInfo; Completed = [bool]; Aborted = [bool] } - Completed
mirrors whether ChapterCompleteCallback actually fired for it; Aborted
is true only for a chapter still incomplete when this function
returns (always the mirror image of Completed in practice, kept as
its own field so a caller doesn't have to infer it).

Two other choices this implementation made that the design doc left
open: a JobStarter that throws is counted into a new
JobStarterFailedCount output field (mirroring ForceKilledCount's
shape) rather than silently folded into anything else - "counted,
budget released, loop continues" per the design doc's own wording,
just needed a place to land; and -AbortPollCallback receives the raw
$running job list (not a projected field) since a generic job
hashtable has no guaranteed field name for the caller to want.

---

## Logging.ps1

**Synopsis:** Logging - shared Write-Log/Write-SummaryLog/Flush-ConsoleQueue plus the
log-file-path setup every mode needs.

**Description:** Pure definitions only - no top-level side effects, safe to dot-source
more than once or alongside other modules. Call Initialize-LogPaths
once, near script startup, before anything calls Write-Log.

State this module owns (matches the pattern AbortPipeline.ps1 already
uses for its own $script:abortRequested/$script:ctrlCloseAbort - a
module owns its own script-scope state, callers don't set it up):
$script:logMutex, $script:workerConsoleQueue, $script:FullLogging,
$script:logFile, $script:logSummaryFile, $script:logErrorFile,
$script:logWarnFile, $script:pathHash, $script:CleanConsoleOutputEnabled

Clean Console Output: when Initialize-CleanConsoleOutput -Enabled $true
has been called, Write-Log stops echoing to the console entirely (both
the direct Write-Host path and the worker-queue-then-Flush-ConsoleQueue
path - since nothing gets enqueued in the first place, Flush-ConsoleQueue
naturally has nothing to drain, no separate change needed there). Log
FILE writes are completely unaffected either way - this toggle only ever
controls the console echo, matching this feature's project-wide rule
(see CLAUDE.md's "Clean Console Output" section) that log content is
never touched by it. With the toggle on, all user-facing console output
becomes CleanConsoleRendering.ps1's job (series/chapter/progress-bar
display, including persisted Warning/Error/Aborted chapter lines)
instead of Write-Log's own per-line echo - this module doesn't call into
CCR itself, it just gets out of the way.

Runspace workers get their own independent copy of this state (a
runspace doesn't share the parent scope) - the established pattern
elsewhere in this codebase (see ZipPipeline.ps1's own $script:zipOnlyWorker)
is for the worker scriptblock to set $script:logFile/$script:logMutex/etc.
itself from parameters it was bound at dispatch time, then call Write-Log
exactly as the main thread does. Write-Log/Write-SummaryLog reference
this module's state via explicit $script: prefixes (not bare names,
unlike the original main-script code this was extracted from) so that's
unambiguous regardless of which runspace they're executing in - verified
live (see the harness) that this resolves correctly to whichever
runspace's own script-scope state was set, not the main thread's, when
Write-Log is invoked from inside a worker.

Write-Log/Write-SummaryLog both go through the internal
Invoke-MutexGuardedWrite helper, which absorbs AbandonedMutexException
(a previous holder terminating without releasing - e.g. a force-stopped
worker mid-write - still results in a successful acquire, not a failure)
so every WaitOne() call site doesn't need to repeat that handling itself.

Neither logging mode ever deletes or clears a previous run's own log
content, per the project owner's own explicit call: full-logging mode
gets a fresh uniquely-timestamped file every run (nothing to clear - no
fixed-name ambiguity); split-log mode's fixed-name Errors/Warnings/Summary
files all ACCUMULATE across runs instead, with the NEWEST run always on
top - each run's own content is marked off by a "=== Run: <timestamp> ==="
header. Summary already worked this way (Write-SummaryLog collects the
whole run's lines and prepends them as one block); Errors/Warnings are
written incrementally throughout a run instead, from potentially several
runspace workers at once (Full Pipeline's per-chapter dispatch), so they
use a different mechanism to get the same "newest on top" result:
Write-Log still just appends in real time (Initialize-LogPaths captures
the file's pre-run content first), and Complete-LogRun (call once, on
the main thread, right after a run finishes) moves that run's newly-
appended content above the captured pre-run content - see that
function's own note in Function Notes for why it's done once at the end
rather than per-line. A previous design here Recycle-Binned
Errors/Warnings at the start of every run so a clean run's absence of
new content wasn't confused with a stale previous run's - that
distinction is now made by the run-separator header instead of by
deleting anything.

Log files are written UTF-8, not ASCII - the historical ASCII-only rule
(see CHANGELOG.md v3.0/v4.0) was about emoji/unicode literally
hardcoded into the script's own SOURCE causing problems, not about
runtime log content, so it doesn't apply to the log file's own
encoding. Non-ASCII message text (this project's manga-library domain
routinely has Japanese/Korean/Chinese filenames) is written through
as-is, not sanitized to "?" like the original extraction did.

Initialize-LogMutex centralizes the "JxlLogMutex_" + pathHash naming
convention, previously reimplemented independently at every call site
that needed it (the main script, ZipParallelProcessing.ps1). Both real
call sites have since migrated onto this shared implementation - see its
own note in Function Notes.

**Notes:** Extracted from Conversion Script Main.ps1 - see
Modules\_Reference\Logging.reference.ps1 for the verbatim source this
was built from, with original line numbers.

---

## LeafDirectoryDiscovery.ps1

**Synopsis:** LeafDirectoryDiscovery - Get-ZippableLeafDirs (the shared leaf-folder
scan used by mode 2 loose+zip and mode 3 zip-only), plus
New-ZippableLeafDirProvider, an incremental alternative for callers
that want to start zipping already-found folders while the rest of a
large tree is still being scanned - and New-SeriesProvider +
Get-SeriesChapters, the two-tier series/chapter discovery Clean
Console Output needs (lazy across series, eager within one series).

**Description:** Pure definitions only - no top-level side effects, safe to dot-source
more than once or alongside other modules.

FORWARD REFERENCE: Write-Log (Modules\Logging.ps1) - not defined in
this module. Modules\_Harness\LeafDirectoryDiscovery.Harness.ps1
stubs it, since this module must stay standalone-testable without
Logging.ps1 existing.

Get-ZippableLeafDirs returns a List[hashtable] - per this project's
documented "Lessons learned" (CLAUDE.md), any function returning a
generic collection needs `return ,$collection` (leading comma) to
stop PowerShell's pipeline output from enumerating it: a 1-element
collection silently collapses to its bare element, and a 0-element
one to $null, unless suppressed. This exact bug has already been
caught live twice in this project (Modules\AbortPipeline.ps1's
Receive-CompletedHandles, and again here) - verified live in this
module's own harness (Scenario I/J) that the comma is genuinely
required, not just applied defensively out of caution.

Also fixes a live-reproduced instance of the "parent/container folder"
bug documented in CHANGELOG.md (the former-container guard): once
every chapter subfolder of a series folder has been individually
zipped and its source deleted, the series folder itself can end up
with zero subdirectories and nothing but the chapter .zip files
directly inside it - looking, structurally, like a genuine leaf.
CHANGELOG.md's own note on that guard says its fix was "best-reasoned
... not a confirmed root-cause diagnosis - the exact mechanism wasn't
reproduced." This module's harness (Scenario K, built against a real
folder shape modeled on Backups\Test Images\Only Images /
Backups\Rezip Tests\Only Images) is the first actual live
reproduction and confirmation that the guard works, not just
reasoning about it.

INCREMENTAL SCANNING: Get-ZippableLeafDirs itself scans the ENTIRE
tree before returning anything - a caller building -JobParams from its
full result has to wait out the whole scan before any work can start,
which is slow and looks like a hang on a large library.
Invoke-ZipParallelProcessing already has a -NextJobProvider parameter
built specifically to solve this ("interleave scanning/peeking with
dispatch instead of discovering everything up front" - CHANGELOG.md
v16.1) but it was never actually wired up anywhere until now.
New-ZippableLeafDirProvider provides that: a scriptblock, compatible
with -NextJobProvider, that evaluates one candidate directory at a
time via a genuinely lazy .NET walk, so dispatch can begin on the
first qualifying folder while the rest of a huge tree is still being
walked. Both functions share the exact same per-directory guard logic
via the internal Test-ZippableLeafDirCandidate helper, so the
incremental path can never silently drift from the batch path's
leaf-qualifying behavior.

TRAVERSAL-ERROR PARITY: the guard-logic parity above did not
originally extend to how the two paths handled an inaccessible
directory. A single permission-denied folder anywhere in the tree made
the old incremental provider (a single flat
[System.IO.Directory]::EnumerateDirectories(..., SearchOption.AllDirectories)
enumerator, which throws on the first inaccessible directory and
cannot be resumed) silently abandon everything past that point, while
the batch path (Get-ChildItem -Recurse -ErrorAction SilentlyContinue)
just skipped that one subtree and kept going. New-ZippableLeafDirProvider
now walks the tree manually, one directory level at a time, with each
level's own enumeration wrapped in its own try/catch - an inaccessible
directory now only costs its own subtree, matching the batch path's
resilience. Purely additive to this module's existing, already-tested
surface - ZipPipeline.ps1's current use of New-ZippableLeafDirProvider
is untouched by any of this.

TWO-TIER SERIES/CHAPTER DISCOVERY (for Clean Console Output - see
CLAUDE.md's section of that name): under the FIXED
Library > Series > Chapter > Images layout (decided, not a heuristic),
a series' chapter COUNT needs to be known before Start-SeriesProgress
can report real progress - but scanning the whole library up front to
get every series' count is exactly the hang this module already fixed
once. The split: New-SeriesProvider walks the LIBRARY lazily, one
series at a time (same anti-hang property as New-ZippableLeafDirProvider,
just one level up - series are always exactly one level below the
library root under the fixed layout, so no recursion or per-item
guard/filter logic is even needed there). Get-SeriesChapters then does
an EAGER, full scan bounded to ONE series' chapters - small enough not
to reintroduce the hang - and is a thin wrapper around
Get-ZippableLeafDirs itself: rooting a RECURSIVE scan at one series
folder finds exactly the same chapters a single-level scan would,
since chapters never nest deeper under the fixed layout (they contain
only images), so reusing Get-ZippableLeafDirs directly here means the
guard logic can never drift between the whole-library and per-series
scan paths - there is only the one implementation.

**Notes:** Extracted from Conversion Script Main.ps1 - see
Modules\_Reference\LeafDirectoryDiscovery.reference.ps1 for the
verbatim source this was built from, with original line numbers.

---

## CleanConsoleRendering.ps1

**Synopsis:** CleanConsoleRendering (CCR) - the "Clean Console Output" toggle's
renderer: a live, per-series/chapter progress display, replacing the
default per-file console spam. Never touches log file content - this
module owns console rendering only.

**Description:** Pure definitions only - no top-level side effects, safe to dot-source
more than once or alongside other modules. No forward references -
this module is fully standalone, like DependencyDetection.ps1.

THE MODEL (fixed Library > Series > Chapter > Images layout, decided
during scoping - see CLAUDE.md's "Clean Console Output" section):
- Start-SeriesProgress registers a series and its total chapter count
  (known upfront via a per-series eager scan - see CLAUDE.md for why
  this doesn't reintroduce the incremental-scan hang fix).
- Start-ChapterProgress marks one chapter of that series as now
  running - or, with -Queued, as queued (built but not started yet);
  Set-ChapterInProgress flips a queued chapter to running.
- Complete-ChapterProgress resolves it: -Status Success just removes
  it from the display entirely (it "clears out", per explicit
  instruction). -Status Warning/Error instead moves it into a
  PERSISTENT list that stays visible - even after the whole series
  finishes and freezes into a permanent line - with an optional
  caller-supplied -Detail string. This module never interprets
  -Detail's contents, just displays it - keeps CCR domain-agnostic
  about *why* something went wrong.
- The progress bar's numerator is SuccessCount only - a chapter with
  issues does NOT count toward it, per explicit instruction. A series
  can therefore finish (nothing left running) while its bar still
  shows short of full (e.g. 6/8) - a deliberate signal, not a bug: the
  persisted issue lines right below explain why.
- A series is "resolved" (nothing left running, freezes into a
  permanent console line) once SuccessCount + issue-chapter count
  reaches TotalChapters. Multiple series can be active/live at once;
  each gets its own block. Only cleanly-successful chapters ever
  actually disappear from the display.
- Write-CleanConsoleMessage is a 5th public function, for one-off
  status lines from OTHER modules (currently AbortPipeline.ps1's
  abort/drain messages) that aren't part of the series/chapter model
  at all - printed as permanent content above the live region without
  corrupting it, the same erase-and-reprint mechanism
  Complete-ChapterProgress's NewlyFrozen path already uses, just with
  raw text instead of a formatted series.

RENDERING: tries real in-place redraw via [Console]::SetCursorPosition
(erase the previous live region, reprint - the actual "clean" part of
Clean Console Output), but this requires a real attached interactive
console. [Console]::CursorTop/SetCursorPosition throws a real
System.IO.IOException ("The handle is invalid") when output is
redirected or non-interactive, so cursor support is probed once
(Test-CleanConsoleCursorAvailable, cached) and everything falls back
to simple sequential Write-Host (no erase, accepting scrollback
duplication) if unavailable, rather than throwing an exception into
the middle of a conversion run. This fallback is the deliberately-
designed degradation path, not an afterthought. Two 2026-09-21/22
hardenings keep a real console from ever falling INTO it by accident:
the live region is capped to the window height (Get-CappedLiveRows) so a
big backlog can't overrun the buffer and make SetCursorPosition throw,
and a transient SetCursorPosition failure (e.g. a raw console write from
elsewhere moving the cursor) redraws that one frame fresh instead of
latching the whole rest of the run into append-only - which otherwise
re-appends the entire live region on every later update, a flood in its
own right.

Content generation (Get-ProgressBarString, Split-TextToWidth,
Format-SeriesLines) is fully separated from the actual console I/O
(Update-CleanConsoleDisplay) specifically so it can be tested without
a real console - see Modules\_Harness\CleanConsoleRendering.Harness.ps1's
own header for what is and isn't actually verifiable that way.

COLOR: persisted issue lines and the bar+count line are colored to
match this project's existing Warn/Error console conventions - Yellow
for Warning/Aborted, Red for Error (the bar+count line itself takes
the worst severity present: Red if any Error, else Yellow if any
Warning/Aborted, else uncolored). Series name and active-chapter lines
are always uncolored.

THREAD SAFETY / CALLING CONTEXT - IMPORTANT: every public function in
this module MUST be called from the main/orchestrating thread only -
NEVER from within a runspace worker script. $script:ccrActiveSeries is
per-runspace state, exactly like every other $script:-prefixed module
state in this project - a worker calling these functions would be
mutating its OWN isolated copy, invisible to the main thread's actual
live display. This is a silent failure mode (nothing crashes, nothing
errors, the display just never updates for that chapter) rather than
an obvious one, so it's called out here prominently rather than left
for whoever wires ImageConversionPipeline.ps1/ZipPipeline.ps1 up to
discover the hard way. The correct call sites are the dispatch loop's
own pre-dispatch code (Start-ChapterProgress) and its -ResultHandler
callback (Complete-ChapterProgress) - both already run on the main
thread in this project's established runspace-pool pattern, same as
Write-Log's own $script:workerConsoleQueue/Flush-ConsoleQueue split
exists to solve the identical problem for console output.

**Notes:** Brand new module - no reference extraction exists for this (the
feature didn't exist when the original reference-extraction pass was
done). Built entirely from the scoping discussion recorded in
CLAUDE.md.

---

## ZipPipeline.ps1

**Synopsis:** ZipPipeline - all zip-domain orchestration that isn't the parallel-
dispatch engine itself: mode 3 (zip-only) end to end, and mode 8's
per-folder zip step.

**Description:** Pure definitions only - no top-level side effects (assigning the
$script:zipOnlyWorker scriptblock literal is inert, same category as
AbortPipeline.ps1's $script:abortCancellationSources list init) - safe
to dot-source more than once or alongside other modules.

Per the reference extraction's ARCHITECTURE decision: any zip logic
lives here, not scattered across whichever mode happens to need it.
Covers PART 1 (mode 3, zip-only pipeline) and PART 2 (mode 8's
per-folder zip step, which runs right after ImageConversionPipeline
converts each batch - see that module's own PART 2 for the
orchestration this was pulled out of). PART 2 was built against an
earlier menu design where this was called "mode 2" - the menu was
renumbered (Menu.ps1) before PART 2 got wired up for real, so every
"mode 2" reference in this module's own code actually means what's now
mode 8 ("Image Conversion + Zip"). PART 2 (Invoke-LooseFolderZip) was
removed with Mode 8, 2026-09-23.

FORWARD REFERENCES (not defined in this module - callers must
dot-source the owning module(s) first):
- Write-Log, Get-LoggingSharedFunctionNames (Logging.ps1)
- Move-ToRecycleBin, Remove-ItemPermanently, Remove-Source,
  Get-FileDeletionSharedFunctionNames (FileDeletion.ps1)
- Compress-FolderToZip, Get-ZipCreationSharedFunctionNames (ZipCreation.ps1)
- Test-ZipArchive, Get-ZipValidationSharedFunctionNames (ZipValidation.ps1)
- Get-*SharedFunctionNames are each module's own single source of
  truth for what a caller needs in -SharedFunctionNames - see
  Controller.ps1's own header for the full reasoning.
- New-ZippableLeafDirProvider (LeafDirectoryDiscovery.ps1) -
  incremental leaf discovery, not the full-scan Get-ZippableLeafDirs
  (see "INCREMENTAL SCANNING" below)
- Invoke-ZipParallelProcessing (ZipParallelProcessing.ps1) - mode 3 is
  ZPP's one current caller; this is where that wiring lives.
- Register-AbortCancellationSource, Unregister-AbortCancellationSource
  (AbortPipeline.ps1) - needed now that ZPP is on AbortPipeline.ps1's
  registry (see "ABORT WIRING NOTE" below); ZPP itself also
  forward-references AbortPipeline.ps1/Logging.ps1 directly, so both
  must be dot-sourced before ZPP.

Modules\_Harness\ZipPipeline.Harness.ps1 dot-sources all of the above
real, already-built modules (this is the first module built with
enough real dependencies available to test against the genuine things
instead of stubs for most of them - only Write-Log is stubbed, so log
output can be inspected by the harness).

IMPORTANT ordering note for any caller: dot-source Logging.ps1 (and
FileDeletion.ps1) BEFORE ZipParallelProcessing.ps1. ZipParallelProcessing.ps1
has its own inline (and currently stale - see CLAUDE.md "Known gaps")
copies of Write-Log/Move-ToRecycleBin/etc. Invoke-ZipParallelProcessing's
-SharedFunctionNames mechanism captures whichever definition is
CURRENTLY active in the caller's scope at call time - dot-sourcing
Logging.ps1/FileDeletion.ps1 after ZipParallelProcessing.ps1 (or not at
all) means ZPP's own stale inline copies would silently win instead.

-SharedFunctionNames must include 'Invoke-MutexGuardedWrite', which
Write-Log itself calls internally for every Warn/Error-level line (and
every line at all in full-logging mode). Without it propagated into
the worker runspace's InitialSessionState, any Write-Log call at
Warn/Error level from inside $script:zipOnlyWorker (e.g. "FAILED to
zip '...'") crashes the entire worker with an unhandled "term not
recognized" error - the job's real result never gets returned at all,
silently miscounted as neither a success nor a failure. Any caller
(including a harness) must also forward real
-LogFile/-LogErrorFile/-LogWarnFile paths rather than leaving them at
their empty-string default - PS 5.1 binds an omitted [string]
parameter to "", never $null (see Docs/lessons-learned.md), and
Write-Log's Out-File throws on an empty -FilePath the first time an
Error/Warn line is attempted from a worker.

ABORT WIRING NOTE: now that ZipParallelProcessing.ps1 has migrated
onto AbortPipeline.ps1 (see that module's own header),
Invoke-ZipOnlyPipeline registers $script:zipOnlyCts with
Register-AbortCancellationSource right after creating it, and
unregisters it in the same finally block that disposes it - matching
ImageConversionPipeline.ps1's own $looseCts pattern exactly. It still
keeps the name $script:zipOnlyCts (harmless, just a local variable
name at this point, not a magic name anything else depends on) rather
than renaming it, since nothing about the registry cares what the
caller calls its own CTS.

INCREMENTAL SCANNING: Invoke-ZipOnlyPipeline dispatches via
LeafDirectoryDiscovery.ps1's New-ZippableLeafDirProvider +
Invoke-ZipParallelProcessing's -NextJobProvider, not
Get-ZippableLeafDirs's full-tree scan + -JobParams. The whole point of
-NextJobProvider (built for exactly this, see CHANGELOG.md v16.1,
never wired up anywhere until now) is that dispatch can begin on the
first qualifying folder while the rest of a large library is still
being walked - scanning the ENTIRE tree before doing any work at all
is what actually caused the "hangs while it searches every folder at
once" symptom on large libraries. One real consequence: this
function's own CandidateCount is no longer known before dispatch
starts, so the old "found N folder(s), running..." log line before
dispatch is gone - the total only exists once the whole run finishes.

CLEAN CONSOLE OUTPUT: mode 3 does NOT switch onto
New-SeriesProvider/Get-SeriesChapters the way ImageConversionPipeline.ps1
did - deliberately. Those two enforce the FIXED Library > Series >
Chapter > Images layout (series exactly one level below the root,
chapters found by a recursive scan bounded to one series). Mode 3's
OWN existing, already-tested behavior (ZipPipeline.Harness.ps1
Scenario A) has leaf directories sitting DIRECTLY under -Path with no
series folder at all - "zip-only handles arbitrary already-ready
content" per Invoke-ZipOnlyPipeline's own docstring, not necessarily a
manga library. Porting the strict two-tier model here would have
silently broken that. Instead: New-ZippableLeafDirProvider (unchanged,
arbitrary depth, still the real incremental job source) drives
dispatch exactly as before; for CCR display purposes only, each
discovered leaf's "series" is derived as its own top-level ancestor
directory name relative to -Path (falls back to the leaf's own name
when the leaf sits directly under -Path - a degenerate one-chapter
"series"). The first time a given top-level ancestor is seen, ONE
bounded Get-ZippableLeafDirs scan of just that top-level folder (same
guards as the incremental scan, via the same
Test-ZippableLeafDirCandidate helper) gets a real chapter count for
Start-SeriesProgress - bounded per series, not a whole-library
up-front scan, matching the exact principle that made the two-tier
approach safe elsewhere without requiring its strict layout assumption
here. CCR calls are gated on $script:CleanConsoleOutputEnabled through
small ordinary (non-closure) wrapper functions - reading that flag, or
calling any CCR function, directly inside a .GetNewClosure()'d
scriptblock would reproduce the exact frozen-scope bug
ImageConversionPipeline.ps1's Opus review caught (see CHANGELOG.md) -
$script: inside a closure resolves to that closure's own disconnected
dynamic module, not Logging.ps1's real one.

**Notes:** Extracted from Conversion Script Main.ps1 - see
Modules\_Reference\ZipPipeline.reference.ps1 for the verbatim source
this was built from, with original line numbers.

---

## AbortPipeline.ps1

**Synopsis:** Standalone module: the Ctrl+C / window-close abort pipeline shared by
every pipeline mode.

**Description:** Wired into Conversion Script Main.ps1 (Register-AbortHandler at
bootstrap; Reset-AbortState called once per loop iteration by
Controller.ps1's Invoke-MainLoop) - built and verified standalone
first, per this repo's development process (see CLAUDE.md). Usage:

1. Call Register-AbortHandler once, near script startup, to install the
   native Ctrl+C / window-close handler.
2. Whenever a pipeline creates a CancellationTokenSource it wants
   cancelled on abort, call Register-AbortCancellationSource. Call
   Unregister-AbortCancellationSource when that CTS is disposed, so
   the registry doesn't hold a reference to a disposed object.
3. Poll Test-AbortSignal wherever a pipeline's dispatch loop currently
   polls the equivalent inline check. It cancels every registered CTS
   exactly once and prints a one-time "[ABORT] ..." message.
4. Once a pipeline has stopped dispatching new work and wants to wait
   for in-flight jobs before force-stopping stragglers, call
   Invoke-GracefulDrain. It ALWAYS signals DrainComplete when it
   returns (success or force-stop) - the caller does not need to call
   Complete-AbortDrain itself in that case. Complete-AbortDrain is
   exposed separately for paths that need to unblock the handler
   without going through a drain (e.g. abort detected before any job
   was ever dispatched).
5. In the script's own top-level catch block, call
   Invoke-AbortOrFatalHandler -ErrorRecord $_ - disambiguates
   PowerShell's own internal Ctrl+C handling firing early (a
   PipelineStoppedException/OperationCanceledException thrown before
   step 1's handler suppresses it) from a genuine, unrelated crash.
   Extracted from the main script's own catch block - see
   Modules\_Reference\AbortPipeline.reference.ps1.

What this module deliberately does NOT own: per-pipeline dispatch
loops (job scanning/throttling), per-mode abort summaries (stats
formatting, "last completed" tracking), and resume-state writes. Those
stay in each pipeline/module, using -ResultHandler on
Invoke-GracefulDrain (same pattern as Invoke-ParallelFolderJobs's
-ResultHandler) to fold results into whatever shape the caller needs.

Clean Console Output touch point: Test-AbortSignal's abort message and
Invoke-GracefulDrain's wait/force-stop messages route through
CleanConsoleRendering.ps1's Write-GatedConsoleMessage instead of a raw
Write-Host, when the toggle is on - a raw Write-Host firing while
CCR's live region is mid-redraw would land wherever the cursor happens
to be and get mangled by the next redraw. Write-GatedConsoleMessage
centralizes the gate itself, so each of this module's 3 call sites
just calls it and passes the toggle in, rather than branching between
Write-CleanConsoleMessage/raw Write-Host by hand. Two forward
references this requires, both FROM Logging.ps1/CleanConsoleRendering.ps1
(both already built and tested, so both are confirmed against real
signatures now, not stubbed-forward like Logging.ps1's original
Move-ToRecycleBin reference was):
- $script:CleanConsoleOutputEnabled - owned by Logging.ps1, NOT
  redeclared here. Read directly via the shared script scope every
  dot-sourced module lives in (the same pattern ZipCreation.ps1
  already uses for FileDeletion.ps1's $script:PermanentDelete) -
  deliberately not a second parallel toggle, so there's only ever one
  on/off switch to keep in sync. Defaults to $null/falsy (same as
  "off") if Logging.ps1 was never dot-sourced at all - this half of
  the toggle degrades gracefully on its own.
- Write-GatedConsoleMessage - owned by CleanConsoleRendering.ps1, and
  NOT optional the way the toggle variable above is: Test-AbortSignal
  calls it unconditionally the first time it detects a real abort (see
  below), so CleanConsoleRendering.ps1 must actually be dot-sourced
  (or the function stubbed, as this module's own harness does) for
  that to resolve - dot-sourcing only THIS module and polling
  Test-AbortSignal without either throws CommandNotFoundException.
  Takes the toggle as an explicit -CleanConsoleOutputEnabled parameter
  rather than reading $script:CleanConsoleOutputEnabled itself, since
  CleanConsoleRendering.ps1 documents itself as having NO forward
  references - this call site is what supplies that value, not the
  callee. Write-GatedConsoleMessage only does real CCR work (calling
  Write-CleanConsoleMessage) when the toggle passed in is true, so a
  caller that leaves the toggle off never needs
  CleanConsoleRendering.ps1 dot-sourced at all.

Core abort mechanics (CTS registry, drain loop, force-kill) are
unchanged by any of this - only the console-output call sites.
Complete-AbortDrain also finalizes the CCR display (force-resolving
any still-active series via Complete-AllActiveSeriesProgress) before
signalling DrainComplete, but ONLY for a CTRL_CLOSE_EVENT (see that
function's own notes for why a plain Ctrl+C must NOT do this too) - so
a still-live progress region isn't left stuck forever when the process
might be force-killed moments after a window close.

**Notes:** Extracted from Conversion Script Main.ps1's ConsoleCtrl type, script-scope
abort state, Test-AbortSignal, and the graceful-drain loop that was
previously duplicated (with minor variations) inside both
Invoke-ParallelFolderJobs and the ZIP-extraction pipeline's own inline
dispatch loop. See CLAUDE.md for the history of what's been fixed here
relative to those originals:
- DrainComplete is now always signalled by Invoke-GracefulDrain
  itself, closing a gap where Invoke-ParallelFolderJobs's callers
  (mode 3) never signalled it near the call site and instead relied on
  a catch-all far later in the script - risky given CTRL_CLOSE_EVENT
  gives the native handler only ~5s before Windows force-kills the
  process, and a drain can take up to the configured timeout (60s).
- The drain loop now does one final completion-check pass after its
  timeout expires and before declaring stragglers force-stopped,
  closing the race documented in CLAUDE.md's "Known gaps" (a job that
  finishes in the ~250ms window between the last poll and the timeout
  firing was previously discarded and miscounted as force-stopped).

---

## Menu.ps1

**Synopsis:** Menu - the mode-selection prompt (what to run) and the options menu
(view/change settings, saved immediately via Config.ps1).

**Description:** Pure definitions only - no top-level side effects, safe to dot-source
more than once or alongside other modules.

Forward-references:
- Write-Log (Modules\Logging.ps1) - logs which mode was selected.
- Export-ScriptSettings (Modules\Config.ps1) - every options-menu edit
  saves immediately, not batched, so nothing is lost on a mid-menu
  Ctrl+C (decided explicitly, not a guess).
- Get-AllUnwantedImageProfiles, Get-UnwantedImageProfilesPath,
  Invoke-UnwantedImageScan, Show-AddUnwantedImageProfileFlow,
  Invoke-TrailingZeroAudit, Get-TrailingZeroReportPath
  (Modules\UnwantedImage.ps1) - the Cover Deletion submenu (option 5)
  is pure wiring around these, no new pipeline logic of its own.
- Initialize-CleanConsoleOutput (Modules\Logging.ps1),
  Initialize-FileDeletion (Modules\FileDeletion.ps1) -
  Show-ModeMenu's own "5" branch re-syncs both from the current
  $Settings right before Show-CoverDeletionMenu runs - Cover
  Deletion's real, permanent-deletion-capable scan happens inside that
  same call, before Controller.ps1's own Invoke-MainLoop re-sync would
  ever get a chance to run.

TESTABILITY: every interactive loop takes a -PromptFunc scriptblock
(defaults to a thin `Read-Host` wrapper) instead of calling Read-Host
directly, and Show-OptionsMenuLevel takes an -ActionHandler
scriptblock for its one real side-effecting item (opening Explorer).
This is the same "inject the real dependency, let a harness override
it" shape already used elsewhere in this project (e.g.
Invoke-ZipParallelProcessing's -ResultHandler) - it's what makes an
interactive console menu testable at all without simulating real
stdin. Modules\_Harness\Menu.Harness.ps1 drives entire multi-step menu
sessions (submenu navigation, value entry, back navigation) by queuing
canned responses through -PromptFunc.

DESIGN, settled with the project owner across several rounds before
this was built (full history in CHANGELOG.md) - see Todo.md's "Menu
(main prompt + options submenu)" section for the authoritative,
up-to-date rendered draft this module implements:
- Mode codes are 1, 2, 3, 4, 5, 8 (NOT contiguous - 6/7/9 are
  deliberately unused/reserved for a future mode without renumbering
  everything already shipped; 9 was "Convert Zipped"/rezip, removed
  entirely 2026-09-09 - see CHANGELOG.md). "0" enters the options menu
  rather than selecting a mode. "5" (Cover Deletion) is a submenu,
  same shape as "0" - it does NOT resolve via Resolve-ModeSelection,
  it opens Show-CoverDeletionMenu and then re-shows the main prompt
  afterward.
- Old mode 2 ("loose conversion + zip") was deliberately dropped as
  its own mode - Full Pipeline (1) covers "convert everything and
  zip"; image conversion + zip without the animated engine is Full
  Pipeline with Animated Conversion turned off (Mode 8, which did that
  job, was retired 2026-09-23).
- Full Pipeline (1) is a flag-resolution concern only here - THIS
  MODULE does not implement the per-chapter "convert both types, then
  zip, non-blocking across chapters" execution behavior itself (that's
  ImageConversionPipeline.ps1/AnimatedConversionPipeline.ps1/
  ZipPipeline.ps1's job once wired together) - Resolve-ModeSelection
  just returns the flags a real caller would act on.
- The options-menu schema (Get-OptionsMenuSchema) is DATA, not control
  flow - Show-OptionsMenuLevel is one generic recursive
  renderer/handler for it. Adding a future settings item is a schema
  edit, not a new interactive-loop function.

**Notes:** Extracted from Conversion Script Main.ps1's mode-selection prompt
(see Modules\_Reference\Menu.reference.ps1 for the verbatim original)
plus wholly new functionality (the options menu, which didn't exist in
the main script at all) built against Todo.md's settled design.

---

## UnwantedImage.ps1

**Synopsis:** UnwantedImage - detects and removes known unwanted images (e.g. ad/
promo cover pages injected by a specific scan source) via a cheapest-
first size -> dimensions -> SHA-256 hash match against a known-profile
table.

**Description:** Pure definitions only - no top-level side effects, safe to dot-source
more than once or alongside other modules.

SOURCE: ported from `Backups\Old Scripts\Delete  Cover -
Upgrade (2).ps1`, the reference extraction's own choice among six
variously-named sibling scripts there, based on file date (newest) and
size (largest) - see Modules\_Reference\UnwantedImage.reference.ps1's
own header for that reasoning. Covers BOTH phases of the original
script: PHASE 1 (the profile-match deletion scan,
Invoke-UnwantedImageScan) and PHASE 2 (the trailing-zero-filename
audit, Invoke-TrailingZeroAudit - report/log only, never deletes). The
reference extraction itself only detailed PHASE 1 ("a distinct,
lower-priority concern from the actual deletion logic" was its own
framing for PHASE 2) - PHASE 2 was built here from the real source
script directly rather than from that extraction. PHASE 2 splits into
a scan/group step (Get-TrailingZeroGroups) and a pure line-builder
(Get-TrailingZeroReportLines) the same way Summary.ps1 splits
Get-SummaryLines from Write-SummaryReport - the I/O (writing the
report file) is Invoke-TrailingZeroAudit's job alone.

REWORKED per the reference extraction's own explicit list (not a
straight port):
- Deletion now goes through FileDeletion.ps1's Remove-Source (respects
  $script:PermanentDelete, Recycle Bin by default) rather than the old
  script's own hardcoded
  [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile call, which
  always forced Recycle Bin regardless of any project-wide toggle.
  This IS a real behavior change from the original script, made
  deliberately: these are original/source files sitting in the user's
  library, exactly the category this project's own deletion-semantics
  convention (see CLAUDE.md) says should respect $PermanentDelete, not
  original/source files this specific script happened to hardcode
  differently before there was a project-wide convention to follow.
- Logging now goes through Logging.ps1's Write-Log (hash mismatches at
  -Level Warn, the completion line at -Level Summary) instead of the
  old script's own two hand-rolled log files (deleted_files_log.txt /
  hash_mismatch_log.txt) - Write-Log already handles full-logging vs.
  summary-only routing itself, so there's no need for a second,
  separate logging mechanism here.
- System.Drawing (Get-ImageDimensions) kept as-is - legacy/
  Windows-only, but this whole project is Windows-only already, and
  nothing about porting this module changes that calculus.

PROFILE PERSISTENCE (built per an explicit follow-up request - "point
the script at an image and have it pull the info and add it...
automatically"): $TargetProfiles is still exposed via
Get-UnwantedImageProfiles as a hardcoded table, unchanged - but that's
now only the BUILT-IN half. A separate persisted store lives at
Get-UnwantedImageProfilesPath's location
(%LOCALAPPDATA%\ConversionScript\unwanted-image-profiles.json - same
base directory as Config.ps1's settings.json, but its own file, not
folded into it) via Import-/Export-UnwantedImageProfiles, matching
Config.ps1's own resilience convention (missing file -> empty, corrupt
file -> backed up + Warn, never thrown). Get-AllUnwantedImageProfiles
combines built-in + persisted, and is what Invoke-UnwantedImageScan
actually matches against by default now (still overridable via
-Profiles). Add-UnwantedImageProfileFromFile is the actual feature
requested: builds a real profile from a real image file
(New-UnwantedImageProfileFromFile - dimensions/size/hash all read from
the file, not typed in by hand) and persists it
(Add-UnwantedImageProfile, which refuses a duplicate hash rather than
adding one) in one call - so it's picked up automatically by every
future scan, no further wiring needed. Show-AddUnwantedImageProfileFlow
is the interactive console flow around that (prompt for path -> prompt
for label -> show what was actually read from the file -> require an
explicit Y confirmation before persisting -> report the outcome) - the
design (preview+confirm, a duplicate just informs rather than offering
a rename, one add per visit, fixed default tolerance) was settled with
the project owner before it was built. Wired into Menu.ps1's "5 -
Cover Deletion" submenu (Show-CoverDeletionMenu) as its "2 - Add
Image" item.

FORWARD REFERENCES (not defined in this module - callers must
dot-source the owning module(s) first):
- Write-Log (Modules\Logging.ps1)
- Remove-Source, $script:PermanentDelete (Modules\FileDeletion.ps1)

**Notes:** Extracted from the old standalone script named above - see
Modules\_Reference\UnwantedImage.reference.ps1 for the verbatim source
this was built from, with original line numbers and the full rework
list.

---

## AnimatedConversionPipeline.ps1

**Synopsis:** AnimatedConversionPipeline - Invoke-LooseAnimatedConversionPipeline,
mode 3 ("Animated Conversion") end to end - the library-walking
orchestrator orchestrating per-batch AVIF->WebP conversion (one animated
conversion at a time per magick.exe process, up to -AnimatedThreads
concurrent), mirroring ImageConversionPipeline.ps1's PART 2
(Invoke-LooseImageConversionPipeline), built once Full Pipeline's
per-chapter coordination was settled (see Todo.md), which removed the
"would be built twice" concern that deferred it originally.

**Description:** Pure definitions only - no top-level side effects, safe to dot-source
more than once or alongside other modules.

SCOPE: this module NOW owns the full orchestration for mode 3
("Animated Conversion" alone, no zip, no Full Pipeline involvement).
Controller.ps1 (Full Pipeline mode 1) uses its own per-chapter
per-engine dispatch via Invoke-ChapterDispatch (ChapterDispatch.ps1),
not by calling this module's orchestrator or directly calling the batch
primitives - the two modes are independent paths, each with its own
dispatch shape, built to the architecture decided in Todo.md.

This module mirrors ImageConversionPipeline.ps1 closely, with two real
differences, not oversights:
- No "stale source" pre-filtering pass. Get-LooseImageCandidates
  splits NeedsConversion vs. StaleSources (a valid .jxl counterpart
  already exists) so the image pipeline can proactively delete stale
  sources before batching. The animated conversion loop handles
  skip-vs-convert logic per file inline (an existing .webp with
  -DoAnimatedOverwrite off is a skip, not a pre-filtered deletion) -
  duplicating that check in Get-LooseAnimatedCandidates would just be
  a second, possibly-drifting copy of logic the conversion machinery
  already owns and already tests.
- No ZipOut/IsZippable/-PostChapterCallback zip-domain fields. Mode 3
  never zips (no "Animated Conversion + Zip" mode exists in the
  current menu design), so -PostChapterCallback's payload here is just
  `@{ SeriesName; ChapterName; Dir; ChapterResult }`.

STATIC AVIF, decided explicitly: a real animation check
(Test-AvifAnimated, via `magick identify -ping -format "%T"` on frame
[0] only - the animation delay, not a frame count) runs before each
file is dispatched. A static AVIF (delay 0) is left untouched entirely -
not converted, not deleted, not recorded as a failure. FLAGGED FOR
FUTURE REVIEW, not decided or built: whether static AVIF should
eventually be converted to JXL instead of being left alone forever -
the project owner wants to evaluate whether that's actually worth
doing before any code gets written for it (see Todo.md).

HEARTBEAT LOGGING, decided explicitly: build the primitive now (a
"still converting (Xs elapsed)" line per job exceeding
-HeartbeatIntervalSeconds, via -Level Info Write-Log calls), and
include BATCH-level progress in it (N of Total files done so far -
trivially available from this function's own counters) since that was
asked for and cheap to add. PER-FILE progress (percent complete of one
magick.exe conversion) is NOT included - magick.exe doesn't expose
that, and figuring out a real way to get it (tailing some
progress-monitor output, if one even exists) wasn't worth the time for
this pass - flagged in Todo.md as a real future exploration, not
silently dropped.

This module's own harness uses a compiled fake magick.exe stand-in
(same technique as ImageConversionPipeline.Harness.ps1's fake
cjxl.exe) to test the branching LOGIC (parse the delay value, static
vs. animated, convert vs. skip) against 3 independent fake-magick.exe
copies across this codebase (this module's own, plus
Controller.Harness.ps1's and ImageConversionPipeline.Harness.ps1's) -
Test-AvifAnimated's real classification method was additionally
validated live against 9 real-world AVIF files across 3 independent
encoders/pipelines (this project's own test library, link-u/
avif-sample-images, and AOMediaCodec/libavif's own official animated
conformance test files) - see CHANGELOG.md's matching entry.

REAL DELETION SEMANTICS, ported deliberately from the disregarded
JXL-approach script rather than the WebP script this module's own
approach is otherwise based on (see
Modules\_Reference\AnimatedConversionPipeline.reference.ps1's own
header - both were flagged there as worth porting): the source .avif
is deleted via Remove-Source (respecting $script:PermanentDelete, same
as every other deletion in this project) only when
-AnimatedDeleteSource is true AND the conversion is verified
successful - exit code 0 AND the output .webp exists AND is
non-zero-byte, not just exit code alone (the WebP script only checked
exit code; the JXL script's stricter check is what's used here).

FORWARD REFERENCES (not defined in this module - callers must
dot-source the owning module(s) first):
- Write-Log (Modules\Logging.ps1)
- Remove-Source, $script:PermanentDelete (Modules\FileDeletion.ps1)
- $script:CleanConsoleOutputEnabled, Write-GatedConsoleMessage
  (Modules\CleanConsoleRendering.ps1) - the module's own conversion
  dispatch machinery needs these to gate its straggler-drain wait
  message the same way ImageConversionPipeline.ps1 does (a raw
  Write-Host there would corrupt CCR's live region mid-redraw).
  Write-GatedConsoleMessage takes the toggle as an explicit param rather
  than reading $script:CleanConsoleOutputEnabled itself
  (CleanConsoleRendering.ps1 has no forward references of its own) -
  this call site supplies it.
- PART 2 only: Test-AbortSignal, Register-AbortCancellationSource,
  Unregister-AbortCancellationSource (Modules\AbortPipeline.ps1);
  New-SeriesProvider, Get-SeriesChapters (Modules\LeafDirectoryDiscovery.ps1);
  Start-SeriesProgress, Start-ChapterProgress, Complete-ChapterProgress,
  Complete-AllActiveSeriesProgress (Modules\CleanConsoleRendering.ps1) -
  same set ImageConversionPipeline.ps1's PART 2 forward-references, for
  the same reasons; Invoke-ChapterDispatch (Modules\ChapterDispatch.ps1 -
  see Invoke-LooseAnimatedConversionPipeline's own notes for the
  migration this module was the first real caller of). NOT
  New-LibraryChapterProvider - that function's own notes explain why
  this module builds its own -ChapterProvider closure instead.

**Notes:** Built from Backups\Old Scripts\Convert-AnimatedAvifToWebp.ps1 (the
approach actually used - see Modules\_Reference\AnimatedConversionPipeline.reference.ps1
for the full reasoning) plus two specific improvements ported from the
disregarded Convert-AnimatedToJxl.ps1 (delete-on-success, stricter
success verification) per that reference file's own explicit
recommendation. The PS7-only `ForEach-Object -Parallel` path in the
old WebP script does not exist on PS 5.1 (this project's hard
constraint) - replaced here with an N-concurrent-process pattern where
external processes (magick.exe), not PowerShell code, handle the real
work, using Invoke-ChapterDispatch's own generic dispatch loop as the
orchestration machinery.

---

## ImageConversionPipeline.ps1

**Synopsis:** ImageConversionPipeline - the shared image-conversion engine and mode
1/2 orchestration. This module literally IS mode 1; mode 2 is this
module plus an extra per-folder zip step layered on top (owned by
ZipPipeline.ps1, not here - see that module's PART 2).

**Description:** Pure definitions only - no top-level side effects, safe to dot-source
more than once or alongside other modules.

ARCHITECTURE (per the reference extraction's explicit decision, and an
earlier correction in this project's history - there is no separate
"LooseConversionPipeline" module; don't recreate one):
- Mode 1 (loose-only) IS this module, nothing else.
- Mode 2 (loose+zip) is this module PLUS ZipPipeline.ps1's per-folder
  zip step, wired in via -PostChapterCallback (see
  Invoke-LooseImageConversionPipeline) rather than this module calling
  into ZipPipeline.ps1 directly - keeps this module decoupled from
  zip-domain logic, using a callback hook for the zip step.
- Mode 8 is mode 2 with a different -PostChapterCallback gate logic
  (see Controller.ps1's Invoke-Mode for how it wires this).
- Mode 3 doesn't convert images, not involved here.

CLEAN CONSOLE OUTPUT REWORK: PART 2 walks the library two-tier -
New-SeriesProvider (lazy, one series at a time) then Get-SeriesChapters
(eager, one series' worth of chapters) - and always batches per
chapter, series by series. This replaced the old -PerFolderBatching
toggle (which no longer exists) and its flat whole-library batch mode
(mode 1's own worst hang case - it walked every FILE up front, not
just every directory). The restructuring is unconditional, not gated
behind the Clean Console Output toggle itself (see CLAUDE.md) - only
the actual CCR calls (Start-SeriesProgress/Start-ChapterProgress/
Complete-ChapterProgress/Complete-AllActiveSeriesProgress) are gated
on $script:CleanConsoleOutputEnabled. Get-LooseImageCandidates is now
called once per series (bounded scan) rather than once for the whole
library, per CLAUDE.md's pre-flight note.

A real bug fixed along the way, found while wiring this up rather than
pre-existing in shipped behavior (this module was never merged or
exercised before): the old code created its own $looseCts but never
registered it with AbortPipeline.ps1's Register-AbortCancellationSource,
so Test-AbortSignal could never actually cancel it - the dispatch
machinery's own CancelToken check would never have fired on a real
Ctrl+C. Now registered once per pipeline call and unregistered in the
`finally` block, matching Register-AbortCancellationSource's own "call
once per pipeline phase" contract.

NOT owned here (see Summary.reference.ps1 instead): the mode 1/2
abort-path summary text. This module's orchestration function returns
enough structured data (last-completed/skipped paths, still-pending
paths, per-category totals) for a future Summary module to build that
text - it does not build the text itself, matching the reference
extraction's explicit note on this.

FORWARD REFERENCES (not defined in this module - callers must
dot-source the owning module(s) first):
- Write-Log (Logging.ps1)
- $script:CleanConsoleOutputEnabled (Logging.ps1) - gates every CCR
  call below, same pattern AbortPipeline.ps1 uses; Write-Log calls
  themselves stay unconditional, since Logging.ps1 (not this module)
  is what suppresses their console echo when the toggle is on
- Remove-Source, $script:PermanentDelete (FileDeletion.ps1)
- Test-AbortSignal, Register-AbortCancellationSource,
  Unregister-AbortCancellationSource (AbortPipeline.ps1)
- New-SeriesProvider, Get-SeriesChapters (LeafDirectoryDiscovery.ps1) -
  the two-tier discovery PART 2 now drives unconditionally (see
  CLAUDE.md's "Clean Console Output" - this replaced the old
  Get-ZippableLeafDirs + -PerFolderBatching toggle)
- Start-SeriesProgress, Start-ChapterProgress, Complete-ChapterProgress,
  Complete-AllActiveSeriesProgress, Write-GatedConsoleMessage
  (CleanConsoleRendering.ps1) - the last one gates the module's own
  straggler-drain wait message, matching how AbortPipeline.ps1's
  Invoke-GracefulDrain already handles the same kind of message (this
  module has its own, separate drain implementation - so it needed the
  same CCR gate added explicitly).
  Write-GatedConsoleMessage takes the toggle as an explicit param
  rather than reading $script:CleanConsoleOutputEnabled itself
  (CleanConsoleRendering.ps1 has no forward references of its own) -
  this call site supplies it.
- Test-AvifAnimated (AnimatedConversionPipeline.ps1) - for the
  static-AVIF classification during image conversion (see "STATIC AVIF
  -> JXL" below). Spawns a real magick identify process - not a cheap
  byte read like the WebP animation check - so this module now
  genuinely depends on AnimatedConversionPipeline.ps1 being
  dot-sourced first, a real new coupling between the two, not just a
  docstring note.

Modules\_Harness\ImageConversionPipeline.Harness.ps1 dot-sources the
real Logging.ps1/FileDeletion.ps1/AbortPipeline.ps1/
LeafDirectoryDiscovery.ps1/CleanConsoleRendering.ps1/
AnimatedConversionPipeline.ps1 (the last one for Test-AvifAnimated),
and compiles a small real stand-in executable (via Add-Type
-OutputType ConsoleApplication) to serve as $CjxlExe/$MagickExe - the
module's own dispatch machinery spawns real OS processes via
System.Diagnostics.Process, so a genuine (if fake) executable is used
rather than mocking the process layer away.

PARALLELISM WITHIN MODE 1/2: the module's own N-concurrent-process
dispatch is separate from ZipParallelProcessing.ps1 and AbortPipeline.ps1
- it dispatches raw cjxl.exe/magick.exe OS processes via
ProcessStartInfo, not PowerShell runspaces, with its own independent
wait-then-force-stop abort-drain (Process.Kill(), not PS.Stop()). This
is a fourth distinct implementation of the same "wait then force-stop"
shape in this codebase (the others: ZipParallelProcessing,
AbortPipeline.ps1's rewrite, Controller.ps1's dispatch) - cannot plug
into Invoke-GracefulDrain as-is since that's built around
[PowerShell]/Handle pairs, not System.Diagnostics.Process.

-AbortTimeoutSeconds is a small addition beyond the original extraction
(which hardcoded 60s) - defaults to 60, preserving existing behavior,
but lets a test harness use a short value instead of waiting out a real
60s drain, matching the same fix already applied to AbortPipeline.ps1's
Invoke-GracefulDrain.

STATIC AVIF -> JXL: decided unconditionally, no toggle - convert
static AVIF the same as everything else, for consistency with the
rest of the library. Lives HERE, not AnimatedConversionPipeline.ps1,
since it's a static-image concern - reuses the exact same "transcode
to a temp PNG via magick, then hand that to cjxl" detour already
built for WebP (the two now share one code path in the dispatch loop,
the WebP/AVIF-specific parts are only the pre-checks: Test-WebPAnimated's
own VP8X-chunk byte read for WebP - cheap, no magick spawn - versus a
real Test-AvifAnimated call for AVIF - a magick identify process
spawn, reading the container's animation delay metadata on frame [0]
only, not a cheap byte read). Animated AVIF is left untouched here,
same as animated WebP - it has its own conversion pipeline
(AnimatedConversionPipeline.ps1). A real Test-AvifAnimated failure
(magick itself failed, or returned something that couldn't be parsed
as a delay value) is its own outcome, NOT folded into FailedCount or
SkippedCount - see the InspectFailedCount field in the output, matching
the same field AnimatedConversionPipeline.ps1 uses for the identical
failure mode (this project's own "give it its own field, don't fold
it into Fail" call, see Todo.md's Summary.ps1 decision).

-ZIPSTEPCALLBACK: Mode 8's CCR-fold mechanism - removed with Mode 8,
2026-09-23.

**Notes:** Extracted from Conversion Script Main.ps1 - see
Modules\_Reference\ImageConversionPipeline.reference.ps1 for the
verbatim source this was built from, with original line numbers.

---

## Controller.ps1

**Synopsis:** Controller - Full Pipeline's (mode 1) per-chapter engine: for each
chapter, runs image conversion and animated conversion CONCURRENTLY
(sharing one process budget), merges both outcomes into a single
status, and zips the chapter only when neither engine reported a real
failure.

**Description:** Pure definitions only - no top-level side effects, safe to dot-source
more than once or alongside other modules.

SCOPE - built against the design settled in Todo.md's "Full Pipeline
(per-chapter controller design)" section (read that first for the full
reasoning behind every decision below - this description summarizes,
it doesn't replace it). This module is named generically ("Controller",
not "FullPipeline") because it's expected to grow into the TOP-LEVEL
DISPATCHER for every mode (not just Full Pipeline) once Menu.ps1's
Get-SelectedMode resolves a choice - that role is confirmed in scope
but deliberately NOT designed or built here. Today this module
contains ONLY the Full Pipeline per-chapter engine, which is fully
specified.

ARCHITECTURE: this module owns the per-chapter walk itself (reusing
New-SeriesProvider/Get-SeriesChapters, same two-tier discovery
ImageConversionPipeline.ps1 and AnimatedConversionPipeline.ps1 already use)
and dispatches both engines (image and animated) per chapter, chapter by
chapter - it does NOT call either module's own top-level orchestrator
(Invoke-LooseImageConversionPipeline, Invoke-LooseAnimatedConversionPipeline)
or ZipPipeline.ps1's Invoke-ZipOnlyPipeline in sequence. Calling the three
existing top-level functions one after another would just be the
already-rejected "three sequential whole-library passes" model wearing
a controller costume - this module walks the library exactly ONCE and
dispatches both engines per chapter.

CONCURRENCY MECHANICS (dispatch redesign step 4 of 4 - full design in
the "DISPATCH-REDESIGN STEP 4" comment block right above
Get-OrCreateFullPipelineSeriesBundle in the source): TWO independent
Invoke-ChapterDispatch (ChapterDispatch.ps1) engines - image, animated -
each running its OWN chapter walk across the WHOLE library
concurrently, not the one-chapter-at-a-time blocking dispatch this
module used before. Still reuses Invoke-ZipParallelProcessing
(ZipParallelProcessing.ps1) as the outer 2-runspace mixer - exactly
the same mechanism as before, just called ONCE per Invoke-FullPipeline
run instead of once per chapter, since each of the two runspaces now
spans the whole library for its own engine rather than one chapter for
either engine. $script:fullPipelineEngineWorker (replacing the old
per-chapter $script:fullPipelineChapterWorker) is the shared worker
scriptblock, picking Image vs Animated logic via -EngineType and
calling Invoke-ChapterDispatch itself (see "SHARED PROCESS BUDGET" below
for the dispatch machinery and process budget details).
Idle concurrency in EITHER engine now picks up its own next chapter's
jobs immediately - the actual point of the whole redesign - instead of
the run blocking on one chapter's image AND animated conversion both
finishing before the next chapter is even enumerated.

SHARED PROCESS BUDGET: a single System.Threading.SemaphoreSlim, sized
to -FullPipelineMaxConcurrentProcs, created once per Invoke-FullPipeline
call and passed into BOTH engine workers (as a real object reference -
the same .NET object crosses into each runspace, so both engines'
Invoke-ChapterDispatch calls truly share one counter, via that
primitive's own -MaxConcurrent param accepting a pre-built
SemaphoreSlim instead of an owned int). Disposed in this function's
own `finally`, alongside $fullCts. Full Pipeline builds its own
JobBuilder/JobStarter/JobFinalize per engine (near-verbatim ports of
modes 2/3's own migrated closures - see this module's
"DISPATCH-REDESIGN STEP 4" block in the source), dispatched via
Invoke-ChapterDispatch directly.

MERGED CCR STATUS: Get-MergedChapterStatus combines an image
ChapterResult and an animated ChapterResult (each possibly $null -
nothing to convert for that engine this chapter) into ONE
Status/Detail pair for a single Complete-ChapterProgress call per
chapter - concatenates both engines' own sub-summaries ("Image: ... |
Animated: ..."), Status is whichever of the two is worse (Error >
Warning > Success). Reuses ImageConversionPipeline.ps1's
Get-ChapterProgressStatus and AnimatedConversionPipeline.ps1's
Get-ChapterAnimatedStatus directly - not a third reimplementation of
that severity logic.

ZIP-BLOCKING POLICY: a chapter is NEVER zipped if either engine's own
Status (from the same two functions above) is "Error" -
FailedCount > 0, ForceKilledCount > 0, or DeleteFailedCount > 0 for
either engine. A Warning-tier outcome (something was skipped, but
nothing failed) does NOT block zipping. The zip step calls
ZipCreation.ps1's Compress-FolderToZip and ZipValidation.ps1's
Test-ZipArchive DIRECTLY - NOT ZipPipeline.ps1's Invoke-LooseFolderZip,
even though the confirmed design allowed either. Real reason, found
live during this session's harness testing: Invoke-LooseFolderZip's
own internal "any remaining $LooseImageExtensions file blocks
zipping" guard treats .webp as an unconverted image SOURCE (correct
for mode 2, where .webp only ever means that) - but in Full Pipeline,
.webp is ALSO the animated engine's own successful OUTPUT, so that
guard silently blocked zipping a chapter that had fully succeeded.
This module's own merged Error-tier check (above) is already a
correct, complete gate covering both engines, so Invoke-LooseFolderZip's
guard was redundant even before the .webp collision was found. Also
means this module never passes -SeriesName/-ChapterName to anything
ZipPipeline.ps1 owns - it owns the chapter's one and only CCR
transition (the merged one above) directly.

CHAPTER-DISCOVERY COMPLETENESS: same fix as both engines' own solo
orchestrators, extended to cover BOTH file types at once -
Get-SeriesChapters's former-container/zip-staleness guards decide "is
this worth re-zipping", not "does this hold unconverted content of
either type" - a directory those guards exclude but that actually has
unconverted images AND/OR unconverted animated files is folded in as
an extra chapter-equivalent entry (IsZippable = $false, same
convention as the two solo orchestrators) before Start-SeriesProgress
is called.

TOP-LEVEL DISPATCHER (Invoke-Mode). Runs whichever mode Menu.ps1's
Resolve-ModeSelection resolved, translating one $Settings hashtable
into each real pipeline entry point's own param list (they were never
unified - each was built independently with its own flat param list),
and returns Summary.ps1's canonical $stats shape (New-StatsTracker)
instead of that pipeline's own differently-named raw counters, so a
caller can hand the result straight to Get-SummaryLines. One shared
try/catch around the whole dispatch calls Invoke-AbortOrFatalHandler
on anything that escapes - this is the "shared top-level catch, not
per-pipeline copies" decision (Todo.md), verified against all five
real entry points' actual outer-scope structure before deciding: at
the time, four of five only had try/finally at their outer scope (an
exception already propagates this far as-is); Invoke-ZipOnlyPipeline
was the one known outlier that swallowed its own. Fixed in the later
codebase-review pass (CHANGELOG.md) - its outer catch-swallow was
removed, so all five entry points now match. Each pipeline call is
injectable via a named scriptblock parameter defaulting to the real
function (same DI pattern as Show-CoverDeletionMenu's -RunHandler/
-AddHandler, Menu.ps1) - the harness proves dispatch/translation/
error-catch logic with fakes, never needing real cjxl/magick or a real
ZipPipeline.ps1 dot-source, since every scenario overrides its handler
explicitly (the real-function defaults only matter for an actual
caller that doesn't override them).

Mode 8 (ImageConversionZip) and its zip-step wiring were removed
2026-09-23 - Full Pipeline with Animated Conversion off replaces it.

Invoke-MainLoop is the run loop that used to live inline in the main
script: resolve a mode (Get-SelectedMode), run it (Invoke-Mode),
report it (Format-ElapsedTime/Get-SummaryLines/Write-SummaryReport),
prompt to continue or exit (Show-PostRunPrompt). All four real
functions are injectable, same DI pattern as Invoke-Mode's own
pipeline handlers - a harness proves the LOOP's own control flow
(iteration count, when it stops) without a real interactive prompt or
real pipeline. New forward reference this brings in: Menu.ps1
(Get-SelectedMode, Show-PostRunPrompt) - Controller.ps1 never needed
Menu.ps1 before this.

AVIF CLASSIFICATION exists to close a real race (the mechanism has
been rewritten for the dispatch redesign, but the race itself and why
it exists are unchanged, only where/when classification happens
moved). Invoke-FullPipeline's own -LooseImageExtensions default
includes .avif (previously excluded specifically to avoid this
problem) - static AVIF gets converted here too, for the same
"consistency across the whole library" reason ImageConversionPipeline.ps1
already converts it in every other mode. Since Get-LooseImageCandidates
and Get-LooseAnimatedCandidates are two INDEPENDENT scans, both
discover the same .avif file, which would otherwise get dispatched to
both engines at once - a real race (one engine converting+deleting a
file the other is still identifying). Resolved per CHAPTER now (was
per series), lazily, by whichever engine's own JobBuilder reaches that
chapter FIRST - Get-OrCreateFullPipelineChapterClassification, NOT
necessarily on the main thread anymore, since either engine's own
worker runspace can be the one that gets there first; a
Lazy<hashtable> with ExecutionAndPublication guarantees the real
Test-AvifAnimated work happens at most once per chapter regardless of
which engine wins the race. Ownership logic itself is unchanged: for
every contested .avif, Test-AvifAnimated decides (static -> stays in
the image list, animated -> stays in the animated list, removed from
the other); a file that can't be classified is removed from BOTH
lists, logged at -Level Error, and counted into InspectFailedCount via
the shared -EventQueue (not through either engine's own ChapterResult
counter, since the failure happens before either engine builds its own
jobs for that file). Scoped ONLY to Full Pipeline - modes 2/3/8/9 call
ImageConversionPipeline.ps1/AnimatedConversionPipeline.ps1 directly and
keep their own existing internal checks unchanged; Full Pipeline is
the only mode where two engines can reach the same candidate set at
once, so it's the only one that needs this.

DISPATCH-REDESIGN STEP 4 (the big comment block above
Get-OrCreateFullPipelineSeriesBundle in the source - see
Docs\dispatch-redesign-design.md for the full design): Full Pipeline
runs two INDEPENDENT Invoke-ChapterDispatch engines concurrently (one
per file type), each inside its own Invoke-ZipParallelProcessing
worker runspace, sharing one process budget (-SharedBudget, unchanged) -
instead of the old design's one Invoke-ZipParallelProcessing call PER
CHAPTER, which blocked the next chapter's own dispatch on both engines
finishing the current one.

CHAPTER/SERIES IDENTITY IS SHARED, NOT PER-ENGINE (the one real design
refinement made during this module's build, past what
Docs\dispatch-redesign-design.md's own "Step 4 concrete implementation
plan" had settled): rather than each engine computing its own
independent "which directories are chapters, which are extras" answer
(mirroring modes 2/3's own precedent too literally), BOTH engines
share one Get-OrCreateFullPipelineSeriesBundle cache, keyed by series
path - whichever engine's own walk reaches a series FIRST computes
that series' full chapter list ONCE (Lazy<T> with
ExecutionAndPublication guarantees exactly once, even under a real
race - same mechanism the AVIF classification uses, just scoped to the
whole series' bundle instead of one file's own classification),
including that series' per-chapter AVIF classification and
naming-collision detection - the other engine just reads the cached
result. This was a deliberate departure from independently-computed
per-engine "extra" entries: with two independent extra-computations, a
directory extra to BOTH engines (leftover images AND leftover animated
files, not a real Get-SeriesChapters chapter) would need
Start-ChapterProgress/Complete-ChapterProgress called TWICE for the
"same" chapter under two different chapterInfo object instances, once
each - CCR's ActiveChapters list tolerates the duplicate without
crashing, but finalizing (zipping, in particular) on the FIRST
engine's own report would cut the SECOND engine's still-running
conversion off early for that shared directory, a real correctness
bug, not just a cosmetic one. Sharing chapter identity (both engines
read the IDENTICAL ChapterEntry object for a given directory, from the
SAME cached bundle) makes "wait for exactly 2 reports before
finalizing" true and simple for EVERY chapter, regular or extra, with
no separate case to reason about.

NEITHER ENGINE MAY CALL CLEAN CONSOLE OUTPUT DIRECTLY - both run
inside their own worker runspace (CleanConsoleRendering.ps1's own
module-scope state is per-runspace, not real script scope - see that
module's own "MUST be called from the main/orchestrating thread only"
notes). Every CCR-facing moment (a series starting, a chapter
starting, a chapter's own merged completion) is instead enqueued onto
a shared ConcurrentQueue (-EventQueue) and drained on the MAIN thread
by Invoke-FullPipeline's own -PollCallback (ZipParallelProcessing.ps1's
new param, built for exactly this) - see Complete-FullPipelineEvent
(the -PollCallback closure) in Invoke-FullPipeline.

FORWARD REFERENCES (not defined in this module - callers must
dot-source the owning module(s) first): Write-Log/Invoke-MutexGuardedWrite/
Get-LoggingSharedFunctionNames (Logging.ps1); Remove-Source/
Move-ToRecycleBin/Remove-ItemPermanently/Get-FileDeletionSharedFunctionNames/
$script:PermanentDelete/Initialize-FileDeletion (FileDeletion.ps1);
Get-ImageConversionSharedFunctionNames/Get-LooseImageCandidates/
Remove-StaleLooseSources/Get-ChapterProgressStatus/
Get-NeverConvertedExtensions/Test-WebPAnimated/Complete-ImageDispatchJob
(ImageConversionPipeline.ps1) - the module's dispatch machinery is
wired in via Invoke-ChapterDispatch, not called directly;
Get-AnimatedConversionSharedFunctionNames/Get-LooseAnimatedCandidates/
Get-ChapterAnimatedStatus/Test-AvifAnimated/Complete-AnimatedDispatchJob
(AnimatedConversionPipeline.ps1) - same dispatch-based wiring;
Invoke-ChapterDispatch/Get-ChapterDispatchSharedFunctionNames
(ChapterDispatch.ps1) - NOT New-LibraryChapterProvider (this module
builds its own -ChapterProvider closures instead); the various
Get-*SharedFunctionNames getters (one per group above) are each
module's own single source of truth for what a caller needs in
-SharedFunctionNames to call into it from a runspace worker -
$engineWorkerSharedFunctionNames concatenates all of them instead of
hand-typing every individual name; Compress-FolderToZip (ZipCreation.ps1),
Test-ZipArchive (ZipValidation.ps1) - called directly, NOT via
ZipPipeline.ps1's Invoke-LooseFolderZip (see "ZIP-BLOCKING POLICY"
above); Invoke-UnwantedImageScan (UnwantedImage.ps1) - Invoke-FullPipeline's
RunCoverDeletionBeforeConversion pre-scan, main-thread-only; New-SeriesProvider/
Get-SeriesChapters/Get-LeafDirectoryDiscoverySharedFunctionNames
(LeafDirectoryDiscovery.ps1) - the shared-function-names getter matters
here in a way it doesn't for modes 2/3's own callers of these same two
functions: both of THOSE run main-thread-only, but Full Pipeline's own
two engine workers each call them from inside their own runspace;
Invoke-ZipParallelProcessing (ZipParallelProcessing.ps1) - its
-PollCallback param (built for this migration) is how this module
drains cross-worker CCR events on the main thread; Register-AbortCancellationSource/
Unregister-AbortCancellationSource/Test-AbortSignal/Invoke-AbortOrFatalHandler/
Reset-AbortState (AbortPipeline.ps1) - the last one for Invoke-MainLoop
only; $script:CleanConsoleOutputEnabled/Start-SeriesProgress/
Start-ChapterProgress/Complete-ChapterProgress/Complete-AllActiveSeriesProgress
(CleanConsoleRendering.ps1); Initialize-CleanConsoleOutput (Logging.ps1) -
same per-iteration re-sync reasoning as Initialize-FileDeletion above;
Invoke-ZipOnlyPipeline (ZipPipeline.ps1) - ONLY if a real caller of
Invoke-Mode doesn't override -ZipFoldersHandler; New-StatsTracker/Format-ElapsedTime/Get-SummaryLines/
Write-SummaryReport (Summary.ps1) - the last three for Invoke-MainLoop
specifically, needed unconditionally; Get-SelectedMode/Show-PostRunPrompt
(Menu.ps1) - Invoke-MainLoop only, same caveat as the Invoke-Mode
handlers above. Same dot-source ordering rule as ZipPipeline.ps1:
Logging.ps1/FileDeletion.ps1 BEFORE ZipParallelProcessing.ps1, since
-SharedFunctionNames captures whichever definition is CURRENTLY active
in the caller's scope at call time.

**Notes:** New module, no reference extraction (this coordination never existed
in the original script - Full Pipeline is new functionality, see
Menu.ps1's design). Built from the confirmed design in Todo.md's "Full
Pipeline (per-chapter controller design)" section.

---
