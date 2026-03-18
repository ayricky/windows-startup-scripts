param(
    [string]$RunKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
    [string]$ValueName = "RawAccel",
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "Programs\RawAccel")
)

$writerPath = Join-Path $InstallRoot "writer.exe"
$settingsPath = Join-Path $InstallRoot "settings.json"
$legacyTaskName = "RawAccel (User Logon)"

if (-not (Test-Path $writerPath)) {
    throw "RawAccel writer not found at $writerPath"
}

if (-not (Test-Path $settingsPath)) {
    throw "RawAccel settings file not found at $settingsPath"
}

$commandValue = "`"$writerPath`" `"$settingsPath`""
$null = New-Item -Path $RunKeyPath -Force -ErrorAction SilentlyContinue
New-ItemProperty -Path $RunKeyPath -Name $ValueName -PropertyType String -Value $commandValue -Force | Out-Null

$legacyTask = Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
if ($legacyTask) {
    Disable-ScheduledTask -InputObject $legacyTask | Out-Null
}

Write-Output "Configured RawAccel startup via HKCU Run:"
Write-Output $commandValue
