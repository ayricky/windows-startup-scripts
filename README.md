# windows-startup-scripts

Windows logon automation for:

- starting your default browser, `Discord`, and `Spotify`
- restoring the saved default-browser, `Discord`, and `Spotify` layout
- restoring windows relative to their saved monitor, even if that monitor changes resolution
- briefly surfacing `Wave Link`, then closing only its window
- applying `RawAccel` with `writer.exe settings.json`

## Scripts

- `Install-AppStartupShortcuts.ps1`: removes managed Startup-folder shortcuts by default so Task Scheduler is the single app-launch path; use `-CreateShortcuts` only for fallback/testing
- `Apply-WindowLayout.ps1`: starts missing tracked apps when requested, waits for `Discord`, your default browser, and `Spotify`, restores the saved size and position, and maximizes the browser window
- `DisplayLayoutProfiles.ps1`: maps each saved window to its left/center/right monitor role first, then recalculates its position from that monitor's current bounds
- `Prime-WaveLinkUI.ps1`: tries to surface the full `Wave Link` UI briefly after sign-in, then closes only the window; if Wave Link stays background-only, the run is logged as skipped instead of failed
- `Post-BootCheck.ps1`: diagnostics for layout and Wave Link priming; add `-Remediate` only when you explicitly want it to retry work
- `Register-WindowLayoutTask.ps1`: registers the `Apply Window Layout` task; by default this task starts missing tracked apps and then applies the layout
- `Register-WaveLinkPrimerTask.ps1`: registers the `Prime Wave Link UI` task
- `Register-PostBootCheckTask.ps1`: optional diagnostics task; not part of the clean default setup
- `Register-RawAccelTask.ps1`: configures RawAccel through `HKCU\...\Run`
- `Save-WindowLayout.ps1`: captures the current `Discord`, default browser, and `Spotify` geometry into `window-layout.json`
- `Update-WindowLayout.ps1`: refreshes the saved layout
- `Get-AutomationMetrics.ps1`: summarizes recent run history
- `RunLogger.ps1`: shared bounded JSON logging
- `Start-DefaultBrowser.ps1`: resolves and starts the current default browser at logon

## Setup

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Save-WindowLayout.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Register-WindowLayoutTask.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Register-WaveLinkPrimerTask.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Register-RawAccelTask.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-AppStartupShortcuts.ps1
```

Sign out and back in, or reboot, to test.

`Register-WindowLayoutTask.ps1` is the app orchestrator. It starts any missing tracked app and applies the layout in one place. `Install-AppStartupShortcuts.ps1` is intentionally last because its default job is to remove duplicate Startup-folder launchers for the tracked apps.

## Configure

- `Apply-WindowLayout.ps1`
  - `StartupDelaySeconds`
  - `WaitForExistingWindowSeconds`
  - `PollIntervalSeconds`
  - `BrowserPath`
  - `LaunchMissingApps`
- `Register-WindowLayoutTask.ps1`
  - `DoNotLaunchMissingApps`
- `Prime-WaveLinkUI.ps1`
  - `InitialDelaySeconds`
  - `WaitForWindowSeconds`
  - `HoldUiSeconds`
- `Post-BootCheck.ps1`
  - `InitialDelaySeconds`
  - `LayoutTolerancePixels`
  - `Remediate`
- `Register-RawAccelTask.ps1`
  - `InstallRoot`
  - `ValueName`

Run `Update-WindowLayout.ps1` any time you move the apps to a new desired position.

## State

- `window-layout.json`: saved window positions
- `window-layout.json` stores monitor-relative window positions and tracks the browser as a logical app
- `logs/*.runs.json`: last 100 runs per script
- Managed Startup shortcuts, if explicitly created for fallback: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup`

## Metrics

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Get-AutomationMetrics.ps1 -LastRuns 20
```
