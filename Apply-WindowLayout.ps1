param(
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "window-layout.json"),
    [int]$StartupDelaySeconds = 10,
    [int]$WaitForExistingWindowSeconds = 120,
    [int]$PollIntervalSeconds = 2,
    [int]$PostLaunchWindowWaitSeconds = 20,
    [string]$BrowserPath = "",
    [string]$DiscordPath = "",
    [string]$SpotifyPath = (Join-Path $env:APPDATA "Spotify\Spotify.exe"),
    [string[]]$MaximizeProcessNames = @(),
    [switch]$LaunchMissingApps
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
. (Join-Path $scriptRoot "BrowserSupport.ps1")
. (Join-Path $scriptRoot "DisplayLayoutProfiles.ps1")

$logger = New-RunLogger -ScriptName "Apply-WindowLayout" -ScriptRoot $scriptRoot -Parameters @{
    ConfigPath = $ConfigPath
    StartupDelaySeconds = $StartupDelaySeconds
    WaitForExistingWindowSeconds = $WaitForExistingWindowSeconds
    PollIntervalSeconds = $PollIntervalSeconds
    PostLaunchWindowWaitSeconds = $PostLaunchWindowWaitSeconds
    BrowserPath = $BrowserPath
    DiscordPath = $DiscordPath
    SpotifyPath = $SpotifyPath
    MaximizeProcessNames = $MaximizeProcessNames
    LaunchMissingApps = [bool]$LaunchMissingApps
}

$swpNoZOrder = 0x0004
$swpNoActivate = 0x0010
$swRestore = 9
$swMaximize = 3

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

function Test-IgnoredWindow {
    param(
        [string]$ProcessName,
        [string]$Title
    )

    if ([string]::IsNullOrWhiteSpace($Title)) {
        return $false
    }

    switch -Regex ($ProcessName) {
        '^discord$' { return ($Title -match 'Updater') }
        default { return $false }
    }
}

function Get-BestWindowMatch {
    param(
        [string]$ProcessName,
        [string]$Title,
        [object[]]$Windows
    )

    if (-not $PSBoundParameters.ContainsKey("Windows") -or $null -eq $Windows) {
        $Windows = Get-TopLevelWindows
    }

    $matches = @($Windows) |
        Where-Object {
            $_.ProcessName -ieq $ProcessName -and
            $_.Visible -and
            $_.Width -gt 200 -and
            $_.Height -gt 150 -and
            -not (Test-IgnoredWindow -ProcessName $_.ProcessName -Title $_.Title)
        }

    if ($Title) {
        $titleMatch = $matches | Where-Object { $_.Title -eq $Title } | Sort-Object Area -Descending | Select-Object -First 1
        if ($titleMatch) {
            return $titleMatch
        }
    }

    return $matches | Sort-Object Area -Descending | Select-Object -First 1
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

function Get-EntryAppKey {
    param([object]$Entry)

    if ($Entry.PSObject.Properties.Name -contains "AppKey" -and -not [string]::IsNullOrWhiteSpace($Entry.AppKey)) {
        return [string]$Entry.AppKey
    }

    switch -Regex ([string]$Entry.ProcessName) {
        '^zen$' { return "Browser" }
        '^discord$' { return "Discord" }
        '^spotify$' { return "Spotify" }
        default { return [string]$Entry.ProcessName }
    }
}

function Resolve-EntryProcessName {
    param(
        [object]$Entry,
        [object]$BrowserInfo
    )

    $appKey = Get-EntryAppKey -Entry $Entry
    if ($appKey -ieq "Browser" -and $BrowserInfo) {
        return $BrowserInfo.ProcessName
    }

    return [string]$Entry.ProcessName
}

function Resolve-LaunchSpec {
    param(
        [object]$Entry,
        [object]$BrowserInfo
    )

    switch -Regex (Get-EntryAppKey -Entry $Entry) {
        '^Browser$' {
            if ($BrowserInfo -and (Test-Path $BrowserInfo.FilePath -ErrorAction SilentlyContinue)) {
                return @{
                    FilePath = $BrowserInfo.FilePath
                    ArgumentList = @()
                    WorkingDirectory = $BrowserInfo.WorkingDirectory
                }
            }

            return $null
        }
        '^Discord$' {
            $discordLaunch = Resolve-DiscordLaunch -PreferredPath $DiscordPath
            if ($discordLaunch) {
                $discordLaunch.WorkingDirectory = Split-Path -Parent $discordLaunch.FilePath
            }

            return $discordLaunch
        }
        '^Spotify$' {
            if (Test-Path $SpotifyPath -ErrorAction SilentlyContinue) {
                return @{
                    FilePath = $SpotifyPath
                    ArgumentList = @()
                    WorkingDirectory = (Split-Path -Parent $SpotifyPath)
                }
            }

            return $null
        }
        default {
            return $null
        }
    }
}

function Start-TrackedApp {
    param(
        [object]$Entry,
        [object]$BrowserInfo
    )

    $launchSpec = Resolve-LaunchSpec -Entry $Entry -BrowserInfo $BrowserInfo
    if (-not $launchSpec) {
        return [pscustomobject]@{
            Started = $false
            FilePath = $null
            ArgumentList = @()
            Error = "No launch command available."
        }
    }

    try {
        if (@($launchSpec.ArgumentList).Count -gt 0) {
            Start-Process -FilePath $launchSpec.FilePath -WorkingDirectory $launchSpec.WorkingDirectory -ArgumentList $launchSpec.ArgumentList | Out-Null
        }
        else {
            Start-Process -FilePath $launchSpec.FilePath -WorkingDirectory $launchSpec.WorkingDirectory | Out-Null
        }

        return [pscustomobject]@{
            Started = $true
            FilePath = $launchSpec.FilePath
            ArgumentList = @($launchSpec.ArgumentList)
            WorkingDirectory = $launchSpec.WorkingDirectory
            Error = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Started = $false
            FilePath = $launchSpec.FilePath
            ArgumentList = @($launchSpec.ArgumentList)
            WorkingDirectory = $launchSpec.WorkingDirectory
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

    $displayState = Get-DisplayLayoutState
    $config = Read-WindowLayoutConfig -Path $ConfigPath
    $layoutPlan = Resolve-WindowLayoutPlan -Config $config -DisplayState $displayState
    $browserInfo = Get-DefaultBrowserInfo -PreferredPath $BrowserPath
    $effectiveMaximizeProcessNames = if (@($MaximizeProcessNames).Count -gt 0) {
        @($MaximizeProcessNames)
    }
    elseif ($browserInfo) {
        @($browserInfo.ProcessName)
    }
    else {
        @()
    }

    if (-not $layoutPlan) {
        Add-RunEvent -Logger $logger -Message "No saved layout plan was available." -Type "skipped" -Data @{
            ConfigPath = $ConfigPath
            Signature = $displayState.Signature
        }
        Complete-RunLogger -Logger $logger -Status "skipped" -Summary @{
            Reason = "No layout plan available."
            ConfigPath = $ConfigPath
            Signature = $displayState.Signature
        }
        return
    }

    $layout = @($layoutPlan.Windows)
    Add-RunEvent -Logger $logger -Message "Selected layout plan." -Type "profile_selected" -Data @{
        MatchType = $layoutPlan.MatchType
        WindowCount = $layout.Count
    }
    if ($browserInfo) {
        Add-RunEvent -Logger $logger -Message "Resolved default browser." -Type "browser_resolved" -Data @{
            ProcessName = $browserInfo.ProcessName
            FilePath = $browserInfo.FilePath
            ProgId = $browserInfo.ProgId
        }
    }

    if ($StartupDelaySeconds -gt 0) {
        Add-RunEvent -Logger $logger -Message "Waiting before window handling." -Type "delay" -Data @{
            StartupDelaySeconds = $StartupDelaySeconds
        }
        Start-Sleep -Seconds $StartupDelaySeconds
    }

    $results = New-Object System.Collections.Generic.List[object]
    $windowsByIndex = @{}
    $pendingLookups = New-Object System.Collections.Generic.List[object]
    $windowSnapshot = Get-TopLevelWindows

    for ($i = 0; $i -lt $layout.Count; $i++) {
        $entry = $layout[$i]
        $resolvedProcessName = Resolve-EntryProcessName -Entry $entry -BrowserInfo $browserInfo
        $result = [pscustomobject]@{
            AppKey = Get-EntryAppKey -Entry $entry
            ProcessName = $resolvedProcessName
            SavedProcessName = $entry.ProcessName
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
        $results.Add($result) | Out-Null

        $window = Get-BestWindowMatch -Windows $windowSnapshot -ProcessName $resolvedProcessName -Title $entry.Title
        if ($window) {
            $result.WaitedForExistingWindowSeconds = 0
            $result.ExistingWindowPolls = 0
            $windowsByIndex[$i] = $window
            continue
        }

        if ($LaunchMissingApps) {
            Add-RunEvent -Logger $logger -Message "No existing window found in startup snapshot. Launching app." -Type "launch_attempt" -Data @{
                ProcessName = $resolvedProcessName
                AppKey = $result.AppKey
            }

            $launchResult = Start-TrackedApp -Entry $entry -BrowserInfo $browserInfo
            $result.LaunchedByScript = $true
            $result.LaunchSucceeded = $launchResult.Started
            $result.LaunchPath = $launchResult.FilePath
            $result.LaunchArguments = @($launchResult.ArgumentList)

            if ($launchResult.Started) {
                Add-RunEvent -Logger $logger -Message "Started app." -Type "launched" -Data @{
                    ProcessName = $resolvedProcessName
                    FilePath = $launchResult.FilePath
                    WorkingDirectory = $launchResult.WorkingDirectory
                    Arguments = @($launchResult.ArgumentList)
                }

                $pendingLookups.Add([pscustomobject]@{
                    Index = $i
                    ProcessName = $resolvedProcessName
                    Title = $entry.Title
                    StartedAt = Get-Date
                    Deadline = (Get-Date).AddSeconds($PostLaunchWindowWaitSeconds)
                    PollCount = 0
                    WaitingPhase = "post_launch"
                }) | Out-Null
            }
            else {
                Add-RunEvent -Logger $logger -Message "Failed to start app." -Type "launch_failed" -Data @{
                    ProcessName = $resolvedProcessName
                    Error = $launchResult.Error
                    FilePath = $launchResult.FilePath
                    WorkingDirectory = $launchResult.WorkingDirectory
                }
            }

            continue
        }

        $pendingLookups.Add([pscustomobject]@{
            Index = $i
            ProcessName = $resolvedProcessName
            Title = $entry.Title
            StartedAt = Get-Date
            Deadline = (Get-Date).AddSeconds($WaitForExistingWindowSeconds)
            PollCount = 0
            WaitingPhase = "existing"
        }) | Out-Null
    }

    while ($pendingLookups.Count -gt 0) {
        $windowSnapshot = Get-TopLevelWindows
        $now = Get-Date
        $nextPendingLookups = New-Object System.Collections.Generic.List[object]

        foreach ($lookup in $pendingLookups) {
            $window = Get-BestWindowMatch -Windows $windowSnapshot -ProcessName $lookup.ProcessName -Title $lookup.Title
            if ($window) {
                $windowsByIndex[$lookup.Index] = $window
                $waitedSeconds = [math]::Round(($now - $lookup.StartedAt).TotalSeconds, 2)
                if ($lookup.WaitingPhase -eq "post_launch") {
                    $results[$lookup.Index].WaitedAfterLaunchSeconds = $waitedSeconds
                    $results[$lookup.Index].PostLaunchPolls = $lookup.PollCount
                }
                else {
                    $results[$lookup.Index].WaitedForExistingWindowSeconds = $waitedSeconds
                    $results[$lookup.Index].ExistingWindowPolls = $lookup.PollCount
                }

                continue
            }

            if ($now -ge $lookup.Deadline) {
                $waitedSeconds = [math]::Round(($now - $lookup.StartedAt).TotalSeconds, 2)
                if ($lookup.WaitingPhase -eq "post_launch") {
                    $results[$lookup.Index].WaitedAfterLaunchSeconds = $waitedSeconds
                    $results[$lookup.Index].PostLaunchPolls = $lookup.PollCount
                }
                else {
                    $results[$lookup.Index].WaitedForExistingWindowSeconds = $waitedSeconds
                    $results[$lookup.Index].ExistingWindowPolls = $lookup.PollCount
                }

                continue
            }

            $lookup.PollCount++
            if ($lookup.PollCount % 5 -eq 0) {
                Add-RunEvent -Logger $logger -Message "Still waiting for app window." -Type "waiting" -Data @{
                    ProcessName = $lookup.ProcessName
                    Title = $lookup.Title
                    WaitedSeconds = [math]::Round(($now - $lookup.StartedAt).TotalSeconds, 2)
                    PollCount = $lookup.PollCount
                    WaitingPhase = $lookup.WaitingPhase
                }
            }

            $nextPendingLookups.Add($lookup) | Out-Null
        }

        if ($nextPendingLookups.Count -eq 0) {
            break
        }

        Start-Sleep -Seconds $PollIntervalSeconds
        $pendingLookups = $nextPendingLookups
    }

    for ($i = 0; $i -lt $results.Count; $i++) {
        $entry = $layout[$i]
        $result = $results[$i]
        $window = $windowsByIndex[$i]

        if (-not $window) {
            Add-RunEvent -Logger $logger -Message "No window found for app." -Type "window_missing" -Data @{
                ProcessName = $result.ProcessName
                AppKey = $result.AppKey
                LaunchMissingApps = [bool]$LaunchMissingApps
            }
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
                ProcessName = $result.ProcessName
                Left = [int]$entry.Left
                Top = [int]$entry.Top
                Width = [int]$entry.Width
                Height = [int]$entry.Height
            }
        }
        else {
            Add-RunEvent -Logger $logger -Message "Failed to position app window." -Type "position_failed" -Data @{
                ProcessName = $result.ProcessName
            }
        }

        if ($moved -and ($effectiveMaximizeProcessNames -icontains $result.ProcessName)) {
            Start-Sleep -Milliseconds 150
            $maximized = [WindowLayoutApplyNative]::ShowWindowAsync($hWnd, $swMaximize)
            $result.Maximized = [bool]$maximized
            Add-RunEvent -Logger $logger -Message "Maximized app window." -Type "maximized" -Data @{
                ProcessName = $result.ProcessName
                Maximized = [bool]$maximized
            }
        }
    }

    Complete-RunLogger -Logger $logger -Status "success" -Summary @{
        MatchType = $layoutPlan.MatchType
        Apps = @($results)
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
