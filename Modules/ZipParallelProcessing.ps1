# See module-descriptions.md for this module's full description.

function Test-ZipJobValueIsMaterializedCollection {
    param($Value)
    if ($Value -is [System.Collections.ICollection]) { return $true }
    foreach ($i in $Value.GetType().GetInterfaces()) {
        if ($i.IsGenericType) {
            $def = $i.GetGenericTypeDefinition()
            if ($def -eq [System.Collections.Generic.ICollection`1] -or $def -eq [System.Collections.Generic.IReadOnlyCollection`1]) { return $true }
        }
    }
    return $false
}

function Test-ZipJobValueHasScriptBlock {
    param($Value, [System.Collections.Generic.HashSet[object]]$Seen, [int]$Depth)
    if ($null -eq $Value) { return $false }
    if ($Value -is [scriptblock]) { return $true }
    if ($Depth -ge 4 -or $Value -is [string]) { return $false }
    $type = $Value.GetType()
    $itemsAreProperties = $false
    if ($Value -is [System.Collections.DictionaryEntry] -or
        ($type.IsGenericType -and $type.GetGenericTypeDefinition() -eq [System.Collections.Generic.KeyValuePair`2])) {
        $items = @($Value.Key, $Value.Value)
    } elseif ($Value -is [System.Management.Automation.PSCustomObject]) {
        if (-not $Seen.Add($Value)) { return $false }
        $items = $Value.PSObject.Properties
        $itemsAreProperties = $true
    } elseif ($Value -is [System.Collections.IEnumerable] -and (Test-ZipJobValueIsMaterializedCollection -Value $Value)) {
        if (-not $type.IsValueType -and -not $Seen.Add($Value)) { return $false }
        if ($Value -is [System.Collections.IDictionary]) { $items = $Value.Values } else { $items = $Value }
    } else {
        return $false
    }
    try {
        foreach ($item in $items) {
            if ($itemsAreProperties) { $item = $item.Value }
            if (Test-ZipJobValueHasScriptBlock -Value $item -Seen $Seen -Depth ($Depth + 1)) { return $true }
        }
    } catch [System.InvalidOperationException] {
        # "Collection was modified": something else is writing to it right
        # now, so it can't be read safely. Let it through unchecked rather
        # than fail the run over it.
    }
    return $false
}

function Get-ZipJobScriptBlockKey {
    param([hashtable]$Job, [System.Collections.Generic.HashSet[object]]$Seen)
    foreach ($key in $Job.Keys) {
        try {
            $found = Test-ZipJobValueHasScriptBlock -Value $Job[$key] -Seen $Seen -Depth 0
        } catch {
            throw ("Invoke-ZipParallelProcessing: couldn't check job parameter '" + $key + "' for scriptblocks - reading it failed: " + $_)
        }
        if ($found) { return [string]$key }
    }
    return $null
}

function Invoke-ZipParallelProcessing {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$WorkerScript,
        [System.Collections.Generic.List[hashtable]]$JobParams = $null,
        [scriptblock]$NextJobProvider = $null,
        [string[]]$SharedFunctionNames,
        [Parameter(Mandatory)]
        [int]$MaxParallel,
        [Parameter(Mandatory)]
        [System.Threading.CancellationTokenSource]$Cts,
        [Parameter(Mandatory)]
        [scriptblock]$ResultHandler,
        [string]$AbortWaitMessage = "[ABORT] Waiting for current jobs to finish (up to 60s)...",
        [scriptblock]$PollCallback = $null,
        [scriptblock]$JobCrashedHandler = $null
    )

    if ($null -eq $JobParams -and $null -eq $NextJobProvider) {
        throw "Invoke-ZipParallelProcessing: must supply either -JobParams or -NextJobProvider."
    }
    if ($null -ne $JobParams -and $null -ne $NextJobProvider) {
        throw "Invoke-ZipParallelProcessing: supply only one of -JobParams or -NextJobProvider, not both."
    }

    if ($null -ne $JobParams -and $JobParams.Count -eq 0) { return @{ ForceStoppedCount = 0 } }

    $scriptBlockJobError = "Invoke-ZipParallelProcessing: job parameter '{0}' is (or contains) a scriptblock. A scriptblock belongs to the runspace that created it, and run inside a worker it can deadlock or crash the process. Pass plain data instead, or pass the code as a string and build it inside the worker with [scriptblock]::Create()."
    $checkedJobValues = [System.Collections.Generic.HashSet[object]]::new()
    $refusedJobError = $null
    if ($null -ne $JobParams) {
        foreach ($job in $JobParams) {
            $badKey = Get-ZipJobScriptBlockKey -Job $job -Seen $checkedJobValues
            if ($null -ne $badKey) { throw ($scriptBlockJobError -f $badKey) }
        }
    }

    $fixedListIndex = 0

    $previousLogMutex  = $null
    $localLogMutex     = $null
    $localConsoleQueue = $null
    $localPool         = $null
    $localHandles      = [System.Collections.Generic.List[hashtable]]::new()
    $scanExhausted     = $false
    $forceStoppedCount = 0

    try {
        $previousLogMutex = $script:logMutex
        Initialize-LogMutex
        $localLogMutex = $script:logMutex
        $localConsoleQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

        $localIss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($sharedFn in $SharedFunctionNames) {
            try {
                $fnDef = (Get-Item ("Function:\" + $sharedFn) -ErrorAction Stop).Definition
            } catch {
                throw ("Invoke-ZipParallelProcessing: -SharedFunctionNames entry '" + $sharedFn + "' does not resolve to a defined function - check for a typo, or that the module defining it was dot-sourced before this call. Original error: " + $_)
            }
            $localIss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $sharedFn, $fnDef))
        }

        $localPool = [RunspaceFactory]::CreateRunspacePool(1, $MaxParallel, $localIss, $Host)
        $localPool.Open()

        while ((-not $scanExhausted -or $localHandles.Count -gt 0) -and -not $Cts.Token.IsCancellationRequested) {

            while (-not $scanExhausted -and $localHandles.Count -lt $MaxParallel -and -not $Cts.Token.IsCancellationRequested) {
                if ($null -ne $JobParams) {
                    if ($fixedListIndex -lt $JobParams.Count) {
                        $nextJob = $JobParams[$fixedListIndex]
                        $fixedListIndex++
                    } else {
                        $nextJob = $null
                    }
                } else {
                    $nextJob = & $NextJobProvider
                    if ($null -ne $nextJob) {
                        $badKey = Get-ZipJobScriptBlockKey -Job $nextJob -Seen $checkedJobValues
                        if ($null -ne $badKey) { $refusedJobError = $scriptBlockJobError -f $badKey; $nextJob = $null }
                    }
                }
                if ($null -eq $nextJob) { $scanExhausted = $true; break }

                $ps = [PowerShell]::Create()
                $ps.RunspacePool = $localPool
                $null = $ps.AddScript($WorkerScript)
                foreach ($key in $nextJob.Keys) { $null = $ps.AddParameter($key, $nextJob[$key]) }
                $null = $ps.AddParameter("CancelToken", $Cts.Token)
                $null = $ps.AddParameter("LogMutex", $localLogMutex)
                $null = $ps.AddParameter("ConsoleQueue", $localConsoleQueue)
                $localHandles.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
            }

            $null = Test-AbortSignal
            Flush-ConsoleQueue -Queue $localConsoleQueue
            if ($null -ne $PollCallback) { $null = & $PollCallback }

            $localStillPending = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($h in $localHandles) {
                if ($h.Handle.IsCompleted) {
                    $localResults = $null
                    try {
                        $localResults = $h.PS.EndInvoke($h.Handle)
                        if ($h.PS.HadErrors) {
                            foreach ($e in $h.PS.Streams.Error) { Write-Log ("Runspace error: " + $e.ToString()) -Level Error }
                        }
                    } catch {
                        Write-Log ("Error collecting runspace result: " + $_) -Level Error
                        # An unhandled exception in the worker script itself
                        # (not just a non-terminating error in its output
                        # streams, above) lands here - EndInvoke rethrows it.
                        # -JobCrashedHandler exists so a caller whose "job" is
                        # a long-lived worker (Controller.ps1's Full Pipeline
                        # engines, one job = one whole engine) can react to
                        # losing that worker entirely - -ResultHandler is
                        # NEVER called for a job that lands here, since there
                        # is no result (a caller with no
                        # -JobCrashedHandler has no way to learn a
                        # worker died mid-run).
                        if ($null -ne $JobCrashedHandler) { try { $null = & $JobCrashedHandler $_ } catch { } }
                    } finally {
                        $h.PS.Dispose()
                    }
                    if ($null -ne $localResults) {
                        foreach ($r in $localResults) { $null = & $ResultHandler $r }
                    }
                } else {
                    $localStillPending.Add($h)
                }
            }
            $localHandles = $localStillPending
            if ($localHandles.Count -gt 0 -and ($scanExhausted -or $localHandles.Count -ge $MaxParallel)) { Start-Sleep -Milliseconds 100 }
        }

        if ($Cts.Token.IsCancellationRequested) {
            $drainResult = Invoke-GracefulDrain -Handles $localHandles -ResultHandler $ResultHandler `
                -ConsoleQueue $localConsoleQueue -TimeoutSeconds 60 -AbortWaitMessage $AbortWaitMessage `
                -ErrorHandler { param($msg) Write-Log $msg -Level Error }
            $forceStoppedCount = $drainResult.ForceStoppedCount
        }

        Flush-ConsoleQueue -Queue $localConsoleQueue
        if ($null -ne $PollCallback) { $null = & $PollCallback }
        if ($null -ne $refusedJobError) { throw $refusedJobError }
    } finally {
        # A worker stuck inside a .NET call can't be stopped, and Stop()/
        # Dispose()/Close() would all sit and wait for it, so an abandoned worker may keep running.
        $stillRunning = $false
        foreach ($h in $localHandles) {
            try {
                if ($h.Handle.IsCompleted) { $h.PS.Dispose() }
                else { $stillRunning = $true; $null = $h.PS.BeginStop($null, $null) }
            } catch { }
        }
        if ($stillRunning) { try { $Cts.Cancel() } catch { } }
        if ($null -ne $localPool) {
            if ($stillRunning) { try { $null = $localPool.BeginClose($null, $null) } catch { } }
            else               { try { $localPool.Close() } catch { }; try { $localPool.Dispose() } catch { } }
        }
        # Best-effort drain on a failing path; the original exception is the one to surface.
        if ($null -ne $localConsoleQueue) { try { Flush-ConsoleQueue -Queue $localConsoleQueue } catch { } }
        $script:logMutex = $previousLogMutex
        if ($null -ne $localLogMutex) { try { $localLogMutex.Dispose() } catch { } }
    }

    return @{ ForceStoppedCount = $forceStoppedCount }
}
