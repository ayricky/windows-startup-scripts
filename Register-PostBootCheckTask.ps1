$taskName = "Post Boot Check"
$scriptPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Post-BootCheck.ps1"
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

if (-not (Test-Path $scriptPath)) {
    throw "Post-boot check script not found at $scriptPath"
}

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 20) `
    -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Checks post-boot startup automation results and logs any issues." `
    -Force
