# windows-startup-scripts

PowerShell scripts for two startup automations:

- restore saved `Discord` and `Zen` window positions at logon
- wait for selected startup apps to initialize, then close them automatically

## What Each Script Does

- `Apply-WindowLayout.ps1`: waits for `Discord` and `Zen`, launches them if needed, then moves them to the saved size and position
- `Close-PeripheralStartupApps.ps1`: watches for selected apps, then closes each one after it has been open for the configured amount of time
- `Save-WindowLayout.ps1`: captures the current `Discord` and `Zen` window geometry into `window-layout.json`
- `Update-WindowLayout.ps1`: re-saves the layout file, with an optional immediate apply
- `Register-WindowLayoutTask.ps1`: creates the `Apply Window Layout` scheduled task
- `Register-PeripheralCleanupTask.ps1`: creates the `Close Peripheral Startup Apps` scheduled task
- `Get-AutomationMetrics.ps1`: summarizes recent run history
- `RunLogger.ps1`: shared bounded JSON run logging used by the other scripts

## Setup

1. Put the scripts in a folder you want to keep, then open PowerShell in that folder.
2. Arrange `Discord` and `Zen` exactly how you want them.
3. Save the layout:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Save-WindowLayout.ps1
```

4. Register the startup tasks:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Register-WindowLayoutTask.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Register-PeripheralCleanupTask.ps1
```

5. Sign out and back in, or run the scripts manually to test.

## Configuration

Edit `Apply-WindowLayout.ps1` to change:

- `StartupDelaySeconds`
- `WaitForExistingWindowSeconds`
- `PollIntervalSeconds`
- `PostLaunchWindowWaitSeconds`
- `ZenPath`
- `DiscordPath`

Edit `Close-PeripheralStartupApps.ps1` to change:

- `WatchMinutes`
- `PollSeconds`
- `SecondsOpenBeforeClose`
- `ProcessNames`

Run `Update-WindowLayout.ps1` any time you want to overwrite `window-layout.json` with a new saved layout.

## Logs And State

- `window-layout.json`: saved local window positions
- `logs/*.runs.json`: bounded run history, last 100 runs per script
- `logs/*.log`: older text logs from earlier versions

## Metrics

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Get-AutomationMetrics.ps1 -LastRuns 20
```
