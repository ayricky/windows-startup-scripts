# windows-startup-scripts

Windows logon automation for:

- starting `Zen` and `Discord`
- restoring the saved `Zen` and `Discord` layout
- briefly surfacing `Wave Link`, then closing only its window
- applying `RawAccel` with `writer.exe settings.json`

## Scripts

- `Install-AppStartupShortcuts.ps1`: creates Startup-folder shortcuts for `Zen` and `Discord`
- `Apply-WindowLayout.ps1`: waits for `Discord` and `Zen`, then restores the saved size and position
- `Prime-WaveLinkUI.ps1`: opens the full `Wave Link` UI briefly after sign-in, then closes only the window
- `Post-BootCheck.ps1`: verifies that layout and Wave Link priming ran and logs issues
- `Register-WindowLayoutTask.ps1`: registers the `Apply Window Layout` task
- `Register-WaveLinkPrimerTask.ps1`: registers the `Prime Wave Link UI` task
- `Register-PostBootCheckTask.ps1`: registers the `Post Boot Check` task
- `Register-RawAccelTask.ps1`: configures RawAccel through `HKCU\...\Run`
- `Save-WindowLayout.ps1`: captures the current `Discord` and `Zen` geometry into `window-layout.json`
- `Update-WindowLayout.ps1`: refreshes the saved layout
- `Get-AutomationMetrics.ps1`: summarizes recent run history
- `RunLogger.ps1`: shared bounded JSON logging

## Setup

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-AppStartupShortcuts.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Save-WindowLayout.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Register-WindowLayoutTask.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Register-WaveLinkPrimerTask.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Register-PostBootCheckTask.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Register-RawAccelTask.ps1
```

Sign out and back in, or reboot, to test.

## Configure

- `Apply-WindowLayout.ps1`
  - `StartupDelaySeconds`
  - `WaitForExistingWindowSeconds`
  - `PollIntervalSeconds`
- `Prime-WaveLinkUI.ps1`
  - `InitialDelaySeconds`
  - `WaitForWindowSeconds`
  - `HoldUiSeconds`
- `Post-BootCheck.ps1`
  - `InitialDelaySeconds`
  - `LayoutTolerancePixels`
- `Register-RawAccelTask.ps1`
  - `InstallRoot`
  - `ValueName`

Run `Update-WindowLayout.ps1` any time your monitor layout changes.

## State

- `window-layout.json`: saved window positions
- `logs/*.runs.json`: last 100 runs per script
- Startup shortcuts: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup`

## Metrics

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Get-AutomationMetrics.ps1 -LastRuns 20
```
