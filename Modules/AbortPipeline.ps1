# See Docs/module-descriptions.md for this module's full description.

if (-not ([System.Management.Automation.PSTypeName]'ConsoleCtrl').Type) {
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

    // Whether a real pipeline run is currently dispatched - see
    // Docs/function-notes.md's AbortPipeline.ps1 section for the full
    // RunActive reasoning.
    public static volatile bool RunActive = false;

    // The handler signals this when abort is requested; the main thread calls
    // Set() when the graceful drain is complete so the handler can return.
    public static readonly ManualResetEventSlim DrainComplete = new ManualResetEventSlim(false);

    private static HandlerRoutine _handler;   // keep a strong ref so the GC can't collect it

    // Whether the most recent Register() call actually succeeded
    // (2026-09-15 fix) - SetConsoleCtrlHandler's own BOOL return was
    // previously discarded entirely, so a failed registration left the
    // whole abort system silently inert with no way for the caller to
    // even find out.
    public static bool LastRegisterSucceeded = false;

    public static void Register()
    {
        // Unregister the previous handler first if Register() has already
        // been called once in this process (2026-09-15 fix, real bug) -
        // SetConsoleCtrlHandler is additive; calling Register() a second
        // time in the same console session (e.g. a manual smoke test run
        // twice without restarting the shell) left the FIRST delegate
        // still registered with the OS on top of the new one, unrooted
        // and eligible for GC once _handler is reassigned below. A
        // Ctrl+C reaching that orphaned delegate after it's been
        // collected is undefined behavior. The Add-Type guard above
        // means this static class survives the whole PowerShell session,
        // so this is a real, reachable path, not just a defensive guard.
        if (_handler != null)
        {
            SetConsoleCtrlHandler(_handler, false);
        }
        _handler = new HandlerRoutine(Handler);
        LastRegisterSucceeded = SetConsoleCtrlHandler(_handler, true);
    }

    private static bool Handler(uint ctrlType)
    {
        // ctrlType: 0=CTRL_C, 1=CTRL_BREAK, 2=CTRL_CLOSE, 5=CTRL_LOGOFF, 6=CTRL_SHUTDOWN
        // !RunActive now exempts EVERY ctrl type, not just Ctrl+C/Break
        // (2026-09-15 fix, real bug) - closing the window (or logging
        // off/shutting down) while sitting at the menu, with nothing
        // actually running, used to still set AbortRequested and park
        // here for the full 65s wait for a drain that will never
        // complete (nothing is dispatched to complete it) - a ~5s hang
        // before Windows force-kills the process, every time.
        if (!RunActive)
        {
            return false;
        }
        if (ctrlType == 0 || ctrlType == 1 || ctrlType == 2 || ctrlType == 5 || ctrlType == 6)
        {
            // IsCloseEvent set BEFORE AbortRequested (2026-09-15 fix, real
            // bug) - Test-AbortSignal (PowerShell side) reads
            // AbortRequested first as its own "is this a NEW abort" latch,
            // then reads IsCloseEvent to decide which message to print. A
            // poll landing in the gap between the two writes under the
            // OLD order would see AbortRequested=true while IsCloseEvent
            // was still stale, permanently mislabeling a window close as
            // Ctrl+C for the rest of the run (Test-AbortSignal's own latch
            // means it only reads these two fields once). Reordering
            // closes the race - by the time AbortRequested is visibly
            // true, IsCloseEvent already reflects this event correctly.
            IsCloseEvent   = (ctrlType == 2 || ctrlType == 5 || ctrlType == 6);
            AbortRequested = true;
            DrainComplete.Wait(65000);   // 65 s > our default 60 s drain timeout
            return true;   // suppress default OS action
        }
        return false;
    }
}
'@ -Language CSharp
}

# See Docs/function-notes.md's AbortPipeline.ps1 section for the full
# QuickEdit-mode reasoning.
if (-not ([System.Management.Automation.PSTypeName]'ConsoleQuickEdit').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ConsoleQuickEdit
{
    private const int STD_INPUT_HANDLE = -10;
    private const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
    private const uint ENABLE_EXTENDED_FLAGS  = 0x0080;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    // 1 = on, 0 = off, -1 = can't tell (no real console attached).
    public static int GetEnabled()
    {
        IntPtr handle = GetStdHandle(STD_INPUT_HANDLE);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) { return -1; }
        uint mode;
        if (!GetConsoleMode(handle, out mode)) { return -1; }
        return (mode & ENABLE_QUICK_EDIT_MODE) != 0 ? 1 : 0;
    }

    public static bool SetEnabled(bool enabled)
    {
        IntPtr handle = GetStdHandle(STD_INPUT_HANDLE);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) { return false; }
        uint mode;
        if (!GetConsoleMode(handle, out mode)) { return false; }
        if (enabled) { mode |= ENABLE_QUICK_EDIT_MODE; } else { mode &= ~ENABLE_QUICK_EDIT_MODE; }
        mode |= ENABLE_EXTENDED_FLAGS;
        return SetConsoleMode(handle, mode);
    }
}
'@ -Language CSharp
}

if (-not ([System.Management.Automation.PSTypeName]'ChildProcessJob').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

// See Docs/function-notes.md's AbortPipeline.ps1 section (Initialize-ChildProcessJob).
public static class ChildProcessJob
{
    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr hJob, int infoClass, IntPtr lpInfo, uint cbInfoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    // Deliberately never closed: the OS closes it when this process exits,
    // for ANY reason (force-kill included), and KILL_ON_JOB_CLOSE then
    // kills every process still assigned. Closing it early would kill
    // running conversions.
    private static IntPtr _job = IntPtr.Zero;
    private static readonly object _lock = new object();

    public static bool IsInitialized { get { return _job != IntPtr.Zero; } }
    public static int LastError { get; private set; }

    public static bool Initialize()
    {
        lock (_lock)
        {
            if (_job != IntPtr.Zero) { return true; }
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) { LastError = Marshal.GetLastWin32Error(); return false; }

            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(info, buffer, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)size))
                {
                    LastError = Marshal.GetLastWin32Error();
                    CloseHandle(job);
                    return false;
                }
            }
            finally { Marshal.FreeHGlobal(buffer); }
            _job = job;
            return true;
        }
    }

    // Never throws - called right after every Process.Start() in this
    // project, including inside worker runspaces, and a failed assignment
    // must never fail the conversion itself (it only loses the
    // force-kill cleanup guarantee for that one process).
    public static bool Assign(System.Diagnostics.Process process)
    {
        if (_job == IntPtr.Zero || process == null) { return false; }
        try
        {
            if (AssignProcessToJobObject(_job, process.Handle)) { return true; }
            LastError = Marshal.GetLastWin32Error();
            return false;
        }
        catch { return false; }
    }
}
'@ -Language CSharp
}

$script:abortRequested = $false
$script:ctrlCloseAbort  = $false

$script:abortCancellationSources = [System.Collections.Generic.List[System.Threading.CancellationTokenSource]]::new()

function Register-AbortHandler {
    [ConsoleCtrl]::Register()
    # 2026-09-15 fix, real bug - SetConsoleCtrlHandler's own BOOL return
    # was previously discarded entirely inside Register(), so a failed
    # registration left the whole abort system silently inert with no
    # way for anything to even find out. Warn loudly rather than stay
    # quiet - a failure here is rare (a process out of handle slots, or
    # already at the OS's per-process handler limit) but means Ctrl+C
    # won't drain gracefully at all for the rest of this run.
    if (-not [ConsoleCtrl]::LastRegisterSucceeded) {
        Write-Host "[WARNING] Could not register the Ctrl+C/window-close handler - aborting a run may not drain gracefully (Ctrl+C will use the OS default action instead)." -ForegroundColor Yellow
    }
}

function Initialize-ChildProcessJob {
    if ([ChildProcessJob]::Initialize()) { return $true }
    Write-Host ("[WARNING] Could not set up child-process cleanup (Win32 error " + [ChildProcessJob]::LastError + ") - if this window is force-closed mid-run, a running magick.exe/cjxl.exe may be left behind and need ending in Task Manager.") -ForegroundColor Yellow
    return $false
}

function Set-AbortHandlerRunActive {
    param([Parameter(Mandatory)][bool]$Active)
    [ConsoleCtrl]::RunActive = $Active
}

function Set-ConsoleQuickEditEnabled {
    param([Parameter(Mandatory)][bool]$Enabled)
    return [ConsoleQuickEdit]::SetEnabled($Enabled)
}

function Get-ConsoleQuickEditEnabled {
    return [ConsoleQuickEdit]::GetEnabled()
}

function Register-AbortCancellationSource {
    param(
        [Parameter(Mandatory)]
        [System.Threading.CancellationTokenSource]$Cts
    )
    $script:abortCancellationSources.Add($Cts)
}

function Unregister-AbortCancellationSource {
    param(
        [Parameter(Mandatory)]
        [System.Threading.CancellationTokenSource]$Cts
    )
    $null = $script:abortCancellationSources.Remove($Cts)
}

function Reset-AbortState {
    $script:abortRequested = $false
    $script:ctrlCloseAbort = $false
    [ConsoleCtrl]::AbortRequested = $false
    [ConsoleCtrl]::IsCloseEvent   = $false
    [ConsoleCtrl]::RunActive      = $false
    [ConsoleCtrl]::DrainComplete.Reset()
}

function Test-AbortSignal {
    if ($null -ne (Get-WorkerRunspaceValue -Name workerConsoleQueue)) {
        return [ConsoleCtrl]::AbortRequested
    }

    if ([ConsoleCtrl]::AbortRequested -and -not $script:abortRequested) {
        $script:abortRequested = $true
        $script:ctrlCloseAbort = [ConsoleCtrl]::IsCloseEvent
        foreach ($cts in @($script:abortCancellationSources)) {
            try { $cts.Cancel() } catch { }
        }
        $abortMessage = if (-not $script:ctrlCloseAbort) {
            "`n[ABORT] Ctrl+C detected - finishing current jobs, please wait..."
        } else {
            "`n[ABORT] Window close detected - finishing current jobs, please wait..."
        }
        Write-GatedConsoleMessage -Text $abortMessage -Color Yellow -CleanConsoleOutputEnabled ([bool]$script:CleanConsoleOutputEnabled)
    }
    return $script:abortRequested
}

function Get-AbortTriggerLabel {
    if ($script:ctrlCloseAbort) { return "window close (X button)" }
    return "Ctrl+C"
}

function Complete-AbortDrain {
    if ($script:CleanConsoleOutputEnabled -and [ConsoleCtrl]::IsCloseEvent) {
        try { Complete-AllActiveSeriesProgress } catch { }
    }
    try { [ConsoleCtrl]::DrainComplete.Set() } catch { }
}

function Test-OwnAbortException {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    $exType = $ErrorRecord.Exception.GetType().FullName
    return ((Test-AbortSignal) -and ($exType -like '*PipelineStoppedException*' -or $exType -like '*OperationCanceled*'))
}

function Invoke-AbortOrFatalHandler {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [scriptblock]$LogHandler = { param($Message) Write-Host ("`r`n" + $Message) -ForegroundColor Red }
    )

    if (Test-OwnAbortException -ErrorRecord $ErrorRecord) {
        Complete-AbortDrain
        return $true
    }

    $fatalMsg = "FATAL ERROR: " + $ErrorRecord.ToString() + "`r`nStack Trace:`r`n" + $ErrorRecord.ScriptStackTrace
    & $LogHandler $fatalMsg
    return $false
}

function Receive-CompletedHandles {
    param(
        [System.Collections.Generic.List[hashtable]]$Handles,
        [scriptblock]$ResultHandler,
        [scriptblock]$ErrorHandler
    )
    $stillActive = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($h in $Handles) {
        if ($h.Handle.IsCompleted) {
            $results = $null
            try {
                $results = $h.PS.EndInvoke($h.Handle)
            } catch {
                if ($null -ne $ErrorHandler) {
                    $null = & $ErrorHandler ("Error collecting runspace result during abort drain: " + $_)
                }
            } finally {
                $h.PS.Dispose()
            }
            if ($null -ne $ResultHandler -and $null -ne $results) {
                foreach ($r in $results) { $null = & $ResultHandler $r }
            }
        } else {
            $stillActive.Add($h)
        }
    }
    return ,$stillActive
}

function Invoke-GracefulDrain {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[hashtable]]$Handles,
        [scriptblock]$ResultHandler,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ConsoleQueue,
        [scriptblock]$ErrorHandler = { param($msg) Write-Host $msg -ForegroundColor Red },
        [int]$TimeoutSeconds = 60,
        [string]$AbortWaitMessage
    )

    if ($Handles.Count -eq 0) {
        Complete-AbortDrain
        return @{ ForceStoppedCount = 0 }
    }

    if (-not $PSBoundParameters.ContainsKey('AbortWaitMessage')) {
        $AbortWaitMessage = "[ABORT] Waiting for current jobs to finish (up to " + $TimeoutSeconds + "s)..."
    }

    $localHandles  = $Handles
    $abortDeadline = [System.Diagnostics.Stopwatch]::StartNew()
    $forceStoppedCount = 0

    try {
        # Moved inside the try (2026-09-15 fix, real bug) - this call used
        # to sit BEFORE the try/finally below that guarantees
        # Complete-AbortDrain runs. If it threw (Docs/function-notes.md
        # already documents Flush-ConsoleQueue-on-a-bad-queue and
        # Write-GatedConsoleMessage-not-resolving as exactly the failure
        # modes that try/finally exists to protect against), Complete-AbortDrain
        # never ran, DrainComplete never got Set(), and the native Ctrl+C
        # handler thread stayed parked in its own 65s wait for a drain
        # that already effectively failed.
        if ($AbortWaitMessage -ne "") {
            Write-GatedConsoleMessage -Text $AbortWaitMessage -Color Yellow -CleanConsoleOutputEnabled ([bool]$script:CleanConsoleOutputEnabled)
        }

        while ($localHandles.Count -gt 0 -and -not [ConsoleCtrl]::IsCloseEvent -and $abortDeadline.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $localHandles = Receive-CompletedHandles -Handles $localHandles -ResultHandler $ResultHandler -ErrorHandler $ErrorHandler
            if ($null -ne $ConsoleQueue) { Flush-ConsoleQueue -Queue $ConsoleQueue }
            if ($localHandles.Count -gt 0) { Start-Sleep -Milliseconds 250 }
        }

        if ($localHandles.Count -gt 0) {
            $localHandles = Receive-CompletedHandles -Handles $localHandles -ResultHandler $ResultHandler -ErrorHandler $ErrorHandler
            if ($null -ne $ConsoleQueue) { Flush-ConsoleQueue -Queue $ConsoleQueue }
        }

        if ($localHandles.Count -gt 0) {
            $forceStoppedCount = $localHandles.Count
            $forceStopMessage = "[ABORT] Force-stopping " + $forceStoppedCount + " job(s) that did not finish within " + $TimeoutSeconds + "s."
            Write-GatedConsoleMessage -Text $forceStopMessage -Color Red -CleanConsoleOutputEnabled ([bool]$script:CleanConsoleOutputEnabled)
            foreach ($h in $localHandles) {
                # BeginStop, not Stop, and no Dispose: both block until the
                # worker's current .NET call returns. See Docs/function-notes.md.
                try { $null = $h.PS.BeginStop($null, $null) } catch { }
            }
        }

        if ($null -ne $ConsoleQueue) { Flush-ConsoleQueue -Queue $ConsoleQueue }
    } finally {
        Complete-AbortDrain
    }

    return @{ ForceStoppedCount = $forceStoppedCount }
}
