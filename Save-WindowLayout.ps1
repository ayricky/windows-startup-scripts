param(
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "window-layout.json"),
    [string[]]$ProcessNames = @(),
    [string]$BrowserPath = ""
)

$signature = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class WindowLayoutNative {
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
}
'@

Add-Type -TypeDefinition $signature -ErrorAction SilentlyContinue

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "RunLogger.ps1")
. (Join-Path $scriptRoot "BrowserSupport.ps1")
. (Join-Path $scriptRoot "DisplayLayoutProfiles.ps1")

function Resolve-TrackedProcesses {
    param(
        [string[]]$RequestedProcessNames,
        [object]$BrowserInfo
    )

    if (@($RequestedProcessNames).Count -eq 0) {
        if (-not $BrowserInfo) {
            throw "Default browser could not be resolved."
        }

        return @(
            [pscustomobject]@{ AppKey = "Discord"; ProcessName = "Discord" },
            [pscustomobject]@{ AppKey = "Browser"; ProcessName = $BrowserInfo.ProcessName },
            [pscustomobject]@{ AppKey = "Spotify"; ProcessName = "Spotify" }
        )
    }

    $tracked = foreach ($requestedName in @($RequestedProcessNames)) {
        switch -Regex ($requestedName) {
            '^(browser|zen)$' {
                if (-not $BrowserInfo) {
                    throw "Default browser could not be resolved."
                }

                [pscustomobject]@{
                    AppKey = "Browser"
                    ProcessName = $BrowserInfo.ProcessName
                }
            }
            '^discord$' {
                [pscustomobject]@{
                    AppKey = "Discord"
                    ProcessName = "Discord"
                }
            }
            '^spotify$' {
                [pscustomobject]@{
                    AppKey = "Spotify"
                    ProcessName = "Spotify"
                }
            }
            default {
                [pscustomobject]@{
                    AppKey = $null
                    ProcessName = $requestedName
                }
            }
        }
    }

    return @($tracked)
}

$logger = New-RunLogger -ScriptName "Save-WindowLayout" -ScriptRoot $scriptRoot -Parameters @{
    ConfigPath = $ConfigPath
    ProcessNames = $ProcessNames
    BrowserPath = $BrowserPath
}

function Get-TopLevelWindows {
    $windows = New-Object System.Collections.Generic.List[object]
    $callback = [WindowLayoutNative+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)

        [uint32]$processId = 0
        [void][WindowLayoutNative]::GetWindowThreadProcessId($hWnd, [ref]$processId)

        if ($processId -eq 0) {
            return $true
        }

        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
        }
        catch {
            return $true
        }

        $length = [WindowLayoutNative]::GetWindowTextLength($hWnd)
        $titleBuilder = New-Object System.Text.StringBuilder ($length + 1)
        if ($length -gt 0) {
            [void][WindowLayoutNative]::GetWindowText($hWnd, $titleBuilder, $titleBuilder.Capacity)
        }

        $rect = New-Object WindowLayoutNative+RECT
        if (-not [WindowLayoutNative]::GetWindowRect($hWnd, [ref]$rect)) {
            return $true
        }

        $windows.Add([pscustomobject]@{
            ProcessName = $process.ProcessName
            Id = $process.Id
            Handle = $hWnd.ToInt64()
            Visible = [WindowLayoutNative]::IsWindowVisible($hWnd)
            Title = $titleBuilder.ToString()
            Left = $rect.Left
            Top = $rect.Top
            Width = $rect.Right - $rect.Left
            Height = $rect.Bottom - $rect.Top
            Area = ($rect.Right - $rect.Left) * ($rect.Bottom - $rect.Top)
        }) | Out-Null

        return $true
    }

    [void][WindowLayoutNative]::EnumWindows($callback, [IntPtr]::Zero)
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

try {
    Add-RunEvent -Logger $logger -Message "Run started." -Type "start"

    $browserInfo = Get-DefaultBrowserInfo -PreferredPath $BrowserPath
    $trackedProcesses = Resolve-TrackedProcesses -RequestedProcessNames $ProcessNames -BrowserInfo $browserInfo
    Add-RunEvent -Logger $logger -Message "Resolved tracked apps." -Type "tracked_apps" -Data @{
        Apps = $trackedProcesses
    }

    $displayState = Get-DisplayLayoutState
    Add-RunEvent -Logger $logger -Message "Detected current display layout." -Type "display_detected" -Data @{
        MonitorCount = $displayState.MonitorCount
        Screens = $displayState.Screens
    }

    $windows = Get-TopLevelWindows
    $layout = foreach ($trackedProcess in $trackedProcesses) {
        $match = $windows |
            Where-Object {
                $_.ProcessName -ieq $trackedProcess.ProcessName -and
                $_.Visible -and
                $_.Width -gt 200 -and
                $_.Height -gt 150 -and
                -not (Test-IgnoredWindow -ProcessName $_.ProcessName -Title $_.Title)
            } |
            Sort-Object Area -Descending |
            Select-Object -First 1

        if (-not $match) {
            Add-RunEvent -Logger $logger -Message "No matching visible window found." -Type "window_missing" -Data @{
                ProcessName = $trackedProcess.ProcessName
                AppKey = $trackedProcess.AppKey
            }
            Write-Warning "No matching visible window found for $($trackedProcess.ProcessName)."
            continue
        }

        Add-RunEvent -Logger $logger -Message "Captured window layout." -Type "window_captured" -Data @{
            ProcessName = $match.ProcessName
            Title = $match.Title
            Left = $match.Left
            Top = $match.Top
            Width = $match.Width
            Height = $match.Height
            AppKey = $trackedProcess.AppKey
        }

        [pscustomobject]@{
            ProcessName = $match.ProcessName
            AppKey = $trackedProcess.AppKey
            Title = ""
            Left = $match.Left
            Top = $match.Top
            Width = $match.Width
            Height = $match.Height
        }
    }

    if (-not $layout) {
        Complete-RunLogger -Logger $logger -Status "failed" -Summary @{
            Error = "No matching windows were captured."
        }
        throw "No matching windows were captured. Arrange Discord, your default browser, and Spotify, then run this script from your desktop session."
    }

    $dynamicLayout = ConvertTo-DynamicWindowLayoutEntries -Windows $layout -DisplayState $displayState

    $configToSave = [pscustomobject]@{
        Version = 4
        DynamicWindows = @($dynamicLayout)
    }

    $configToSave | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding ASCII
    Add-RunEvent -Logger $logger -Message "Saved layout file." -Type "saved" -Data @{
        ConfigPath = $ConfigPath
        CapturedWindows = $layout.Count
        DynamicWindows = $dynamicLayout.Count
    }
    Complete-RunLogger -Logger $logger -Status "success" -Summary @{
        ConfigPath = $ConfigPath
        DynamicWindows = $dynamicLayout
        CapturedWindows = $layout
    }
    Write-Output "Saved layout to $ConfigPath"
}
catch {
    if (-not $_.Exception.Message.StartsWith("No matching windows were captured")) {
        Add-RunEvent -Logger $logger -Message "Run failed." -Type "error" -Data @{
            Error = $_.Exception.Message
        }
        Complete-RunLogger -Logger $logger -Status "failed" -Summary @{
            Error = $_.Exception.Message
        }
    }
    throw
}
