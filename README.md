# windows-startup-scripts

PowerShell scripts for automating Windows startup behavior:

- apply saved window positions for Discord and Zen Browser
- wait for and close selected startup apps after they initialize
- capture and update saved window layouts
- collect bounded run history and basic timing metrics

## Main Scripts

- `Apply-WindowLayout.ps1`
- `Close-PeripheralStartupApps.ps1`
- `Save-WindowLayout.ps1`
- `Update-WindowLayout.ps1`
- `Get-AutomationMetrics.ps1`

## Generated Files

These are local machine state and are not committed:

- `logs/`
- `window-layout.json`

## Automatic Tasks

The included registration scripts create these Scheduled Tasks:

- `Apply Window Layout`
- `Close Peripheral Startup Apps`
