param(
    [int]$WatchMinutes = 5,
    [int]$PollSeconds = 1,
    [int]$SecondsOpenBeforeClose = 60,
    [string[]]$ProcessNames = @(
        "StreamDeck",
        "WaveLink",
        "WaveLinkSE",
        "rawaccel"
    )
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "RunLogger.ps1")

$logger = New-RunLogger -ScriptName "Close-PeripheralStartupApps" -ScriptRoot $scriptRoot -Parameters @{
    WatchMinutes = $WatchMinutes
    PollSeconds = $PollSeconds
    SecondsOpenBeforeClose = $SecondsOpenBeforeClose
    ProcessNames = $ProcessNames
}
$runStartedAt = $logger.StartedAt.LocalDateTime

$deadline = (Get-Date).AddMinutes($WatchMinutes)
$state = @{}

foreach ($processName in $ProcessNames) {
    $state[$processName] = [ordered]@{
        FirstSeenAt = $null
        LastSeenAt = $null
        Closed = $false
        Seen = $false
        ClosedAt = $null
        CloseAttempts = 0
        ClosedPids = @()
    }
}

try {
    Add-RunEvent -Logger $logger -Message "Run started." -Type "start" -Data @{
        WatchMinutes = $WatchMinutes
        PollSeconds = $PollSeconds
        SecondsOpenBeforeClose = $SecondsOpenBeforeClose
        ProcessNames = $ProcessNames
    }

    while ((Get-Date) -lt $deadline) {
        $pending = $false

        foreach ($processName in $ProcessNames) {
            $entry = $state[$processName]
            if ($entry.Closed) {
                continue
            }

            $pending = $true
            $now = Get-Date
            $processes = Get-Process -Name $processName -ErrorAction SilentlyContinue

            if (-not $processes) {
                if ($entry.FirstSeenAt) {
                    Add-RunEvent -Logger $logger -Message "$processName exited before the close timer elapsed." -Type "reset" -Data @{
                        ProcessName = $processName
                        SecondsObserved = [math]::Round(($now - $entry.FirstSeenAt).TotalSeconds, 2)
                    }
                    $entry.FirstSeenAt = $null
                }

                continue
            }

            $entry.LastSeenAt = $now

            if (-not $entry.Seen) {
                $entry.Seen = $true
                Add-RunEvent -Logger $logger -Message "Detected $processName running." -Type "detected" -Data @{
                    ProcessName = $processName
                    Pids = @($processes.Id)
                }
            }

            if (-not $entry.FirstSeenAt) {
                $entry.FirstSeenAt = $now
                Add-RunEvent -Logger $logger -Message "Started close timer for $processName." -Type "timer_started" -Data @{
                    ProcessName = $processName
                }
                continue
            }

            $secondsOpen = [int](($now - $entry.FirstSeenAt).TotalSeconds)
            if ($secondsOpen -lt $SecondsOpenBeforeClose) {
                continue
            }

            $entry.CloseAttempts++
            foreach ($process in $processes) {
                try {
                    Stop-Process -Id $process.Id -ErrorAction Stop
                    $entry.ClosedPids += $process.Id
                    Add-RunEvent -Logger $logger -Message "Stopped $($process.ProcessName) (PID $($process.Id))." -Type "stopped" -Data @{
                        ProcessName = $process.ProcessName
                        Pid = $process.Id
                        SecondsOpen = $secondsOpen
                    }
                }
                catch {
                    Add-RunEvent -Logger $logger -Message "Failed to stop $($process.ProcessName) (PID $($process.Id))." -Type "stop_failed" -Data @{
                        ProcessName = $process.ProcessName
                        Pid = $process.Id
                        Error = $_.Exception.Message
                    }
                }
            }

            $remainingProcesses = Get-Process -Name $processName -ErrorAction SilentlyContinue
            if (-not $remainingProcesses) {
                $entry.Closed = $true
                $entry.ClosedAt = Get-Date
            }
        }

        if (-not $pending) {
            Add-RunEvent -Logger $logger -Message "All target apps were handled before the watch window ended." -Type "complete"
            break
        }

        Start-Sleep -Seconds $PollSeconds
    }

    foreach ($processName in $ProcessNames) {
        $entry = $state[$processName]

        if ($entry.Closed) {
            continue
        }

        if (-not $entry.Seen) {
            Add-RunEvent -Logger $logger -Message "Did not detect $processName during the watch window." -Type "not_detected" -Data @{
                ProcessName = $processName
            }
            continue
        }

        Add-RunEvent -Logger $logger -Message "Stopped watching $processName before it could be closed." -Type "watch_ended" -Data @{
            ProcessName = $processName
            SecondsObserved = [math]::Round(((Get-Date) - $entry.FirstSeenAt).TotalSeconds, 2)
        }
    }

    $summary = foreach ($processName in $ProcessNames) {
        $entry = $state[$processName]
        [pscustomobject]@{
            ProcessName = $processName
            Seen = $entry.Seen
            Closed = $entry.Closed
            FirstSeenAt = if ($entry.FirstSeenAt) { $entry.FirstSeenAt.ToString("o") } else { $null }
            LastSeenAt = if ($entry.LastSeenAt) { $entry.LastSeenAt.ToString("o") } else { $null }
            ClosedAt = if ($entry.ClosedAt) { $entry.ClosedAt.ToString("o") } else { $null }
            SecondsUntilFirstSeen = if ($entry.FirstSeenAt) { [math]::Round(($entry.FirstSeenAt - $runStartedAt).TotalSeconds, 2) } else { $null }
            SecondsObservedBeforeClose = if ($entry.FirstSeenAt -and $entry.ClosedAt) { [math]::Round(($entry.ClosedAt - $entry.FirstSeenAt).TotalSeconds, 2) } else { $null }
            CloseAttempts = $entry.CloseAttempts
            ClosedPids = @($entry.ClosedPids)
        }
    }

    Complete-RunLogger -Logger $logger -Status "success" -Summary @{
        Processes = $summary
    }
}
catch {
    Add-RunEvent -Logger $logger -Message "Run failed." -Type "error" -Data @{
        Error = $_.Exception.Message
    }
    Complete-RunLogger -Logger $logger -Status "failed" -Summary @{
        Error = $_.Exception.Message
    }
    throw
}
