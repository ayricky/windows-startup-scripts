param(
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "window-layout.json"),
    [string[]]$ProcessNames = @("Discord", "zen")
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

$logger = New-RunLogger -ScriptName "Save-WindowLayout" -ScriptRoot $scriptRoot -Parameters @{
    ConfigPath = $ConfigPath
    ProcessNames = $ProcessNames
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

try {
    Add-RunEvent -Logger $logger -Message "Run started." -Type "start"

    $windows = Get-TopLevelWindows
    $layout = foreach ($processName in $ProcessNames) {
        $match = $windows |
            Where-Object {
                $_.ProcessName -ieq $processName -and
                $_.Visible -and
                $_.Width -gt 200 -and
                $_.Height -gt 150
            } |
            Sort-Object Area -Descending |
            Select-Object -First 1

        if (-not $match) {
            Add-RunEvent -Logger $logger -Message "No matching visible window found." -Type "window_missing" -Data @{
                ProcessName = $processName
            }
            Write-Warning "No matching visible window found for $processName."
            continue
        }

        Add-RunEvent -Logger $logger -Message "Captured window layout." -Type "window_captured" -Data @{
            ProcessName = $match.ProcessName
            Title = $match.Title
            Left = $match.Left
            Top = $match.Top
            Width = $match.Width
            Height = $match.Height
        }

        [pscustomobject]@{
            ProcessName = $match.ProcessName
            Title = $match.Title
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
        throw "No matching windows were captured. Arrange Discord and Zen, then run this script from your desktop session."
    }

    $layout | ConvertTo-Json -Depth 3 | Set-Content -Path $ConfigPath -Encoding ASCII
    Add-RunEvent -Logger $logger -Message "Saved layout file." -Type "saved" -Data @{
        ConfigPath = $ConfigPath
        CapturedWindows = $layout.Count
    }
    Complete-RunLogger -Logger $logger -Status "success" -Summary @{
        ConfigPath = $ConfigPath
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
