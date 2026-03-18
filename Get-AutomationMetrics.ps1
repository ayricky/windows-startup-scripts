param(
    [int]$LastRuns = 20
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "RunLogger.ps1")

function Get-Average {
    param([double[]]$Values)

    if (-not $Values -or $Values.Count -eq 0) {
        return $null
    }

    return [math]::Round((($Values | Measure-Object -Average).Average), 2)
}

$scriptNames = @(
    "Apply-WindowLayout",
    "Close-PeripheralStartupApps",
    "Save-WindowLayout",
    "Update-WindowLayout"
)

$histories = foreach ($scriptName in $scriptNames) {
    $path = Join-Path $scriptRoot "logs\$scriptName.runs.json"
    $runs = @(Get-RunHistory -Path $path | Select-Object -Last $LastRuns)

    if (-not $runs) {
        continue
    }

    [pscustomobject]@{
        ScriptName = $scriptName
        Runs = $runs
    }
}

if (-not $histories) {
    Write-Output "No automation run history found."
    return
}

"Script Summary"
$histories | ForEach-Object {
    $durations = @($_.Runs | ForEach-Object { if ($_.DurationSeconds -ne $null) { [double]$_.DurationSeconds } })
    [pscustomobject]@{
        ScriptName = $_.ScriptName
        Runs = $_.Runs.Count
        Successes = @($_.Runs | Where-Object Status -eq "success").Count
        Failures = @($_.Runs | Where-Object Status -eq "failed").Count
        Skipped = @($_.Runs | Where-Object Status -eq "skipped").Count
        AvgDurationSeconds = Get-Average -Values $durations
        LastStatus = $_.Runs[-1].Status
        LastStartedAt = $_.Runs[-1].StartedAt
    }
} | Format-Table -AutoSize

$applyHistory = $histories | Where-Object ScriptName -eq "Apply-WindowLayout" | Select-Object -First 1
if ($applyHistory) {
    "Apply Window Layout Per-App Summary"
    $applyRows = foreach ($run in $applyHistory.Runs) {
        foreach ($app in @($run.Summary.Apps)) {
            [pscustomobject]@{
                ProcessName = $app.ProcessName
                WaitedForExistingWindowSeconds = $app.WaitedForExistingWindowSeconds
                WaitedAfterLaunchSeconds = $app.WaitedAfterLaunchSeconds
                LaunchedByScript = $app.LaunchedByScript
                LaunchSucceeded = $app.LaunchSucceeded
                WindowFound = $app.WindowFound
                Positioned = $app.Positioned
            }
        }
    }

    $applyRows | Group-Object ProcessName | ForEach-Object {
        $rows = $_.Group
        [pscustomobject]@{
            ProcessName = $_.Name
            Samples = $rows.Count
            AvgExistingWaitSeconds = Get-Average -Values @($rows | ForEach-Object { if ($_.WaitedForExistingWindowSeconds -ne $null) { [double]$_.WaitedForExistingWindowSeconds } })
            AvgPostLaunchWaitSeconds = Get-Average -Values @($rows | ForEach-Object { if ($_.WaitedAfterLaunchSeconds -ne $null) { [double]$_.WaitedAfterLaunchSeconds } })
            LaunchCount = @($rows | Where-Object LaunchedByScript).Count
            LaunchSuccessCount = @($rows | Where-Object LaunchSucceeded).Count
            WindowFoundCount = @($rows | Where-Object WindowFound).Count
            PositionedCount = @($rows | Where-Object Positioned).Count
        }
    } | Format-Table -AutoSize
}

$closeHistory = $histories | Where-Object ScriptName -eq "Close-PeripheralStartupApps" | Select-Object -First 1
if ($closeHistory) {
    "Close Peripheral Startup Apps Per-Process Summary"
    $closeRows = foreach ($run in $closeHistory.Runs) {
        foreach ($process in @($run.Summary.Processes)) {
            [pscustomobject]@{
                ProcessName = $process.ProcessName
                Seen = $process.Seen
                Closed = $process.Closed
                SecondsUntilFirstSeen = $process.SecondsUntilFirstSeen
                SecondsObservedBeforeClose = $process.SecondsObservedBeforeClose
                CloseAttempts = $process.CloseAttempts
            }
        }
    }

    $closeRows | Group-Object ProcessName | ForEach-Object {
        $rows = $_.Group
        [pscustomobject]@{
            ProcessName = $_.Name
            Samples = $rows.Count
            SeenCount = @($rows | Where-Object Seen).Count
            ClosedCount = @($rows | Where-Object Closed).Count
            AvgSecondsUntilFirstSeen = Get-Average -Values @($rows | ForEach-Object { if ($_.SecondsUntilFirstSeen -ne $null) { [double]$_.SecondsUntilFirstSeen } })
            AvgSecondsObservedBeforeClose = Get-Average -Values @($rows | ForEach-Object { if ($_.SecondsObservedBeforeClose -ne $null) { [double]$_.SecondsObservedBeforeClose } })
            AvgCloseAttempts = Get-Average -Values @($rows | ForEach-Object { if ($_.CloseAttempts -ne $null) { [double]$_.CloseAttempts } })
        }
    } | Format-Table -AutoSize
}
