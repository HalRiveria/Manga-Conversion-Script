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

    public static void Register()
    {
        _handler = new HandlerRoutine(Handler);
        SetConsoleCtrlHandler(_handler, true);
    }

    private static bool Handler(uint ctrlType)
    {
        // ctrlType: 0=CTRL_C, 1=CTRL_BREAK, 2=CTRL_CLOSE, 5=CTRL_LOGOFF, 6=CTRL_SHUTDOWN
        if ((ctrlType == 0 || ctrlType == 1) && !RunActive)
        {
            return false;
        }
        if (ctrlType == 0 || ctrlType == 1 || ctrlType == 2 || ctrlType == 5 || ctrlType == 6)
        {
            AbortRequested = true;
            IsCloseEvent   = (ctrlType == 2 || ctrlType == 5 || ctrlType == 6);
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

$script:abortRequested = $false
$script:ctrlCloseAbort  = $false

$script:abortCancellationSources = [System.Collections.Generic.List[System.Threading.CancellationTokenSource]]::new()

function Register-AbortHandler {
    [ConsoleCtrl]::Register()
}

function Set-AbortHandlerRunActive {
    param([Parameter(Mandatory)][bool]$Active)
    [ConsoleCtrl]::RunActive = $Active
}

function Set-ConsoleQuickEditEnabled {
    param([Parameter(Mandatory)][bool]$Enabled)
    return [ConsoleQuickEdit]::SetEnabled($Enabled)
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
    $null = [ConsoleQuickEdit]::SetEnabled($true)
}

function Test-AbortSignal {
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
        if ($null -ne $script:workerConsoleQueue) {
            # Inside a runspace worker: Write-GatedConsoleMessage isn't in
            # every worker's -SharedFunctionNames list and CCR state doesn't
            # exist here anyway, so queue for the main thread to print -
            # same pattern Write-Log uses (Logging.ps1's $script:workerConsoleQueue).
            $script:workerConsoleQueue.Enqueue(@{ Message = $abortMessage; Level = "Warn" })
        } else {
            Write-GatedConsoleMessage -Text $abortMessage -Color Yellow -CleanConsoleOutputEnabled ([bool]$script:CleanConsoleOutputEnabled)
        }
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
                    & $ErrorHandler ("Error collecting runspace result during abort drain: " + $_)
                }
            } finally {
                $h.PS.Dispose()
            }
            if ($null -ne $ResultHandler -and $null -ne $results) {
                foreach ($r in $results) { & $ResultHandler $r }
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
    if ($AbortWaitMessage -ne "") {
        Write-GatedConsoleMessage -Text $AbortWaitMessage -Color Yellow -CleanConsoleOutputEnabled ([bool]$script:CleanConsoleOutputEnabled)
    }

    $localHandles  = $Handles
    $abortDeadline = [System.Diagnostics.Stopwatch]::StartNew()
    $forceStoppedCount = 0

    try {
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
                try { $h.PS.Stop() } catch { }
                try { $h.PS.Dispose() } catch { }
            }
        }

        if ($null -ne $ConsoleQueue) { Flush-ConsoleQueue -Queue $ConsoleQueue }
    } finally {
        Complete-AbortDrain
    }

    return @{ ForceStoppedCount = $forceStoppedCount }
}
