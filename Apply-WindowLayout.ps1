param(
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "window-layout.json"),
    [int]$StartupDelaySeconds = 20,
    [int]$WaitForExistingWindowSeconds = 120,
    [int]$PollIntervalSeconds = 5,
    [int]$PostLaunchWindowWaitSeconds = 45,
    [string]$ZenPath = "C:\Program Files\Zen Browser\zen.exe",
    [string]$DiscordPath = ""
)

$signature = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class WindowLayoutApplyNative {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
'@

Add-Type -TypeDefinition $signature -ErrorAction SilentlyContinue

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "RunLogger.ps1")

$logger = New-RunLogger -ScriptName "Apply-WindowLayout" -ScriptRoot $scriptRoot -Parameters @{
    ConfigPath = $ConfigPath
    StartupDelaySeconds = $StartupDelaySeconds
    WaitForExistingWindowSeconds = $WaitForExistingWindowSeconds
    PollIntervalSeconds = $PollIntervalSeconds
    PostLaunchWindowWaitSeconds = $PostLaunchWindowWaitSeconds
    ZenPath = $ZenPath
    DiscordPath = $DiscordPath
}

$swpNoZOrder = 0x0004
$swpNoActivate = 0x0010
$swRestore = 9

function Get-TopLevelWindows {
    $windows = New-Object System.Collections.Generic.List[object]
    $callback = [WindowLayoutApplyNative+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)

        [uint32]$processId = 0
        [void][WindowLayoutApplyNative]::GetWindowThreadProcessId($hWnd, [ref]$processId)
        if ($processId -eq 0) {
            return $true
        }

        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
        }
        catch {
            return $true
        }

        $rect = New-Object WindowLayoutApplyNative+RECT
        if (-not [WindowLayoutApplyNative]::GetWindowRect($hWnd, [ref]$rect)) {
            return $true
        }

        $length = [WindowLayoutApplyNative]::GetWindowTextLength($hWnd)
        $titleBuilder = New-Object System.Text.StringBuilder ($length + 1)
        if ($length -gt 0) {
            [void][WindowLayoutApplyNative]::GetWindowText($hWnd, $titleBuilder, $titleBuilder.Capacity)
        }

        $windows.Add([pscustomobject]@{
            ProcessName = $process.ProcessName
            Id = $process.Id
            Handle = $hWnd.ToInt64()
            Visible = [WindowLayoutApplyNative]::IsWindowVisible($hWnd)
            Title = $titleBuilder.ToString()
            Left = $rect.Left
            Top = $rect.Top
            Width = $rect.Right - $rect.Left
            Height = $rect.Bottom - $rect.Top
            Area = ($rect.Right - $rect.Left) * ($rect.Bottom - $rect.Top)
        }) | Out-Null

        return $true
    }

    [void][WindowLayoutApplyNative]::EnumWindows($callback, [IntPtr]::Zero)
    return $windows
}

function Get-BestWindowMatch {
    param(
        [string]$ProcessName,
        [string]$Title
    )

    $windows = Get-TopLevelWindows |
        Where-Object {
            $_.ProcessName -ieq $ProcessName -and
            $_.Visible -and
            $_.Width -gt 200 -and
            $_.Height -gt 150
        }

    if ($Title) {
        $titleMatch = $windows | Where-Object { $_.Title -eq $Title } | Sort-Object Area -Descending | Select-Object -First 1
        if ($titleMatch) {
            return $titleMatch
        }
    }

    return $windows | Sort-Object Area -Descending | Select-Object -First 1
}

function Wait-ForWindow {
    param(
        [string]$ProcessName,
        [string]$Title,
        [int]$TimeoutSeconds,
        [int]$PollSeconds
    )

    $startedWaitingAt = Get-Date
    $pollCount = 0
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $match = Get-BestWindowMatch -ProcessName $ProcessName -Title $Title
        if ($match) {
            return [pscustomobject]@{
                Window = $match
                WaitedSeconds = [math]::Round(((Get-Date) - $startedWaitingAt).TotalSeconds, 2)
                PollCount = $pollCount
            }
        }

        $pollCount++
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)

    return [pscustomobject]@{
        Window = $null
        WaitedSeconds = [math]::Round(((Get-Date) - $startedWaitingAt).TotalSeconds, 2)
        PollCount = $pollCount
    }
}

function Resolve-DiscordLaunch {
    param([string]$PreferredPath)

    if ($PreferredPath -and (Test-Path $PreferredPath -ErrorAction SilentlyContinue)) {
        return @{
            FilePath = $PreferredPath
            ArgumentList = @()
        }
    }

    $updateExe = Join-Path $env:LOCALAPPDATA "Discord\Update.exe"
    if (Test-Path $updateExe -ErrorAction SilentlyContinue) {
        return @{
            FilePath = $updateExe
            ArgumentList = @("--processStart", "Discord.exe")
        }
    }

    $discordExe = Get-ChildItem (Join-Path $env:LOCALAPPDATA "Discord") -Filter "Discord.exe" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1

    if ($discordExe) {
        return @{
            FilePath = $discordExe.FullName
            ArgumentList = @()
        }
    }

    return $null
}

function Resolve-LaunchSpec {
    param([string]$ProcessName)

    switch -Regex ($ProcessName) {
        '^zen$' {
            if (Test-Path $ZenPath -ErrorAction SilentlyContinue) {
                return @{
                    FilePath = $ZenPath
                    ArgumentList = @()
                }
            }

            return $null
        }
        '^discord$' {
            return Resolve-DiscordLaunch -PreferredPath $DiscordPath
        }
        default {
            return $null
        }
    }
}

function Start-TrackedApp {
    param([string]$ProcessName)

    $launchSpec = Resolve-LaunchSpec -ProcessName $ProcessName
    if (-not $launchSpec) {
        return [pscustomobject]@{
            Started = $false
            FilePath = $null
            ArgumentList = @()
            Error = "No launch command available."
        }
    }

    try {
        Start-Process -FilePath $launchSpec.FilePath -ArgumentList $launchSpec.ArgumentList | Out-Null
        return [pscustomobject]@{
            Started = $true
            FilePath = $launchSpec.FilePath
            ArgumentList = @($launchSpec.ArgumentList)
            Error = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Started = $false
            FilePath = $launchSpec.FilePath
            ArgumentList = @($launchSpec.ArgumentList)
            Error = $_.Exception.Message
        }
    }
}

try {
    Add-RunEvent -Logger $logger -Message "Run started." -Type "start"

    if (-not (Test-Path $ConfigPath)) {
        Add-RunEvent -Logger $logger -Message "Layout config not found." -Type "skipped" -Data @{
            ConfigPath = $ConfigPath
        }
        Complete-RunLogger -Logger $logger -Status "skipped" -Summary @{
            Reason = "Layout config not found."
            ConfigPath = $ConfigPath
        }
        return
    }

    $layout = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if ($layout -isnot [System.Collections.IEnumerable]) {
        $layout = @($layout)
    }

    if ($StartupDelaySeconds -gt 0) {
        Add-RunEvent -Logger $logger -Message "Initial startup delay elapsed." -Type "delay" -Data @{
            StartupDelaySeconds = $StartupDelaySeconds
        }
        Start-Sleep -Seconds $StartupDelaySeconds
    }

    $results = @()

    foreach ($entry in $layout) {
        $result = [ordered]@{
            ProcessName = $entry.ProcessName
            Title = $entry.Title
            WaitedForExistingWindowSeconds = $null
            ExistingWindowPolls = $null
            LaunchedByScript = $false
            LaunchSucceeded = $false
            LaunchPath = $null
            LaunchArguments = @()
            WaitedAfterLaunchSeconds = $null
            PostLaunchPolls = $null
            WindowFound = $false
            Positioned = $false
            TargetLeft = [int]$entry.Left
            TargetTop = [int]$entry.Top
            TargetWidth = [int]$entry.Width
            TargetHeight = [int]$entry.Height
        }

        $windowLookup = Wait-ForWindow `
            -ProcessName $entry.ProcessName `
            -Title $entry.Title `
            -TimeoutSeconds $WaitForExistingWindowSeconds `
            -PollSeconds $PollIntervalSeconds

        $result.WaitedForExistingWindowSeconds = $windowLookup.WaitedSeconds
        $result.ExistingWindowPolls = $windowLookup.PollCount
        $window = $windowLookup.Window

        if (-not $window) {
            Add-RunEvent -Logger $logger -Message "No existing window found. Launching app." -Type "launch_attempt" -Data @{
                ProcessName = $entry.ProcessName
                WaitedSeconds = $windowLookup.WaitedSeconds
                PollCount = $windowLookup.PollCount
            }

            $launchResult = Start-TrackedApp -ProcessName $entry.ProcessName
            $result.LaunchedByScript = $true
            $result.LaunchSucceeded = $launchResult.Started
            $result.LaunchPath = $launchResult.FilePath
            $result.LaunchArguments = @($launchResult.ArgumentList)

            if ($launchResult.Started) {
                Add-RunEvent -Logger $logger -Message "Started app." -Type "launched" -Data @{
                    ProcessName = $entry.ProcessName
                    FilePath = $launchResult.FilePath
                    Arguments = @($launchResult.ArgumentList)
                }

                $postLaunchLookup = Wait-ForWindow `
                    -ProcessName $entry.ProcessName `
                    -Title $entry.Title `
                    -TimeoutSeconds $PostLaunchWindowWaitSeconds `
                    -PollSeconds $PollIntervalSeconds

                $result.WaitedAfterLaunchSeconds = $postLaunchLookup.WaitedSeconds
                $result.PostLaunchPolls = $postLaunchLookup.PollCount
                $window = $postLaunchLookup.Window
            }
            else {
                Add-RunEvent -Logger $logger -Message "Failed to start app." -Type "launch_failed" -Data @{
                    ProcessName = $entry.ProcessName
                    Error = $launchResult.Error
                    FilePath = $launchResult.FilePath
                }
            }
        }

        if (-not $window) {
            Add-RunEvent -Logger $logger -Message "No window found for app." -Type "window_missing" -Data @{
                ProcessName = $entry.ProcessName
            }
            $results += [pscustomobject]$result
            continue
        }

        $result.WindowFound = $true
        $result.FoundWindowTitle = $window.Title
        $result.FoundWindowHandle = $window.Handle

        $hWnd = [IntPtr]::new([int64]$window.Handle)
        [void][WindowLayoutApplyNative]::ShowWindowAsync($hWnd, $swRestore)

        $moved = [WindowLayoutApplyNative]::SetWindowPos(
            $hWnd,
            [IntPtr]::Zero,
            [int]$entry.Left,
            [int]$entry.Top,
            [int]$entry.Width,
            [int]$entry.Height,
            ($swpNoZOrder -bor $swpNoActivate)
        )

        $result.Positioned = [bool]$moved

        if ($moved) {
            Add-RunEvent -Logger $logger -Message "Positioned app window." -Type "positioned" -Data @{
                ProcessName = $entry.ProcessName
                Left = [int]$entry.Left
                Top = [int]$entry.Top
                Width = [int]$entry.Width
                Height = [int]$entry.Height
            }
        }
        else {
            Add-RunEvent -Logger $logger -Message "Failed to position app window." -Type "position_failed" -Data @{
                ProcessName = $entry.ProcessName
            }
        }

        $results += [pscustomobject]$result
    }

    Complete-RunLogger -Logger $logger -Status "success" -Summary @{
        Apps = $results
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
