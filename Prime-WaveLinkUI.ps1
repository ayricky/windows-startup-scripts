param(
    [int]$InitialDelaySeconds = 20,
    [int]$WaitForWindowSeconds = 60,
    [int]$HoldUiSeconds = 12,
    [int]$PollSeconds = 1,
    [string]$WaveLinkPath = "C:\Program Files\Elgato\WaveLink\WaveLink.exe"
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "RunLogger.ps1")

$logger = New-RunLogger -ScriptName "Prime-WaveLinkUI" -ScriptRoot $scriptRoot -Parameters @{
    InitialDelaySeconds = $InitialDelaySeconds
    WaitForWindowSeconds = $WaitForWindowSeconds
    HoldUiSeconds = $HoldUiSeconds
    PollSeconds = $PollSeconds
    WaveLinkPath = $WaveLinkPath
}

$signature = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class WaveLinkPrimerNative {
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
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
'@

Add-Type -TypeDefinition $signature -ErrorAction SilentlyContinue

function Get-VisibleWaveLinkWindow {
    $windows = New-Object System.Collections.Generic.List[object]
    $callback = [WaveLinkPrimerNative+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)

        if (-not [WaveLinkPrimerNative]::IsWindowVisible($hWnd)) {
            return $true
        }

        [uint32]$processId = 0
        [void][WaveLinkPrimerNative]::GetWindowThreadProcessId($hWnd, [ref]$processId)
        if ($processId -eq 0) {
            return $true
        }

        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
        }
        catch {
            return $true
        }

        if ($process.ProcessName -ine "WaveLink") {
            return $true
        }

        $rect = New-Object WaveLinkPrimerNative+RECT
        if (-not [WaveLinkPrimerNative]::GetWindowRect($hWnd, [ref]$rect)) {
            return $true
        }

        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
        if ($width -le 250 -or $height -le 150) {
            return $true
        }

        $length = [WaveLinkPrimerNative]::GetWindowTextLength($hWnd)
        $titleBuilder = New-Object System.Text.StringBuilder ($length + 1)
        if ($length -gt 0) {
            [void][WaveLinkPrimerNative]::GetWindowText($hWnd, $titleBuilder, $titleBuilder.Capacity)
        }

        $windows.Add([pscustomobject]@{
            Handle = $hWnd
            ProcessId = $process.Id
            Title = $titleBuilder.ToString()
            Width = $width
            Height = $height
            Area = $width * $height
        }) | Out-Null

        return $true
    }

    [void][WaveLinkPrimerNative]::EnumWindows($callback, [IntPtr]::Zero)
    return $windows | Sort-Object Area -Descending | Select-Object -First 1
}

try {
    Add-RunEvent -Logger $logger -Message "Run started." -Type "start"

    if (-not (Test-Path $WaveLinkPath)) {
        throw "Wave Link executable not found at $WaveLinkPath"
    }

    if ($InitialDelaySeconds -gt 0) {
        Add-RunEvent -Logger $logger -Message "Waiting before surfacing Wave Link UI." -Type "delay" -Data @{
            InitialDelaySeconds = $InitialDelaySeconds
        }
        Start-Sleep -Seconds $InitialDelaySeconds
    }

    Start-Process -FilePath $WaveLinkPath | Out-Null
    Add-RunEvent -Logger $logger -Message "Requested normal Wave Link launch." -Type "launch_requested" -Data @{
        WaveLinkPath = $WaveLinkPath
    }

    $window = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $pollCount = 0

    while ($stopwatch.Elapsed.TotalSeconds -lt $WaitForWindowSeconds) {
        $window = Get-VisibleWaveLinkWindow
        if ($window) {
            break
        }

        $pollCount++
        if (($pollCount % 5) -eq 0) {
            Add-RunEvent -Logger $logger -Message "Still waiting for Wave Link window." -Type "waiting" -Data @{
                WaitedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
                PollCount = $pollCount
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }

    if (-not $window) {
        throw "Wave Link window did not appear within $WaitForWindowSeconds seconds."
    }

    Add-RunEvent -Logger $logger -Message "Wave Link window detected." -Type "window_detected" -Data @{
        WaitedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
        ProcessId = $window.ProcessId
        Title = $window.Title
    }

    if ($HoldUiSeconds -gt 0) {
        Add-RunEvent -Logger $logger -Message "Keeping Wave Link UI open briefly to let routing settle." -Type "stabilizing" -Data @{
            HoldUiSeconds = $HoldUiSeconds
        }
        Start-Sleep -Seconds $HoldUiSeconds
    }

    $closeRequested = [WaveLinkPrimerNative]::PostMessage($window.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
    Add-RunEvent -Logger $logger -Message "Requested Wave Link window close." -Type "window_close_requested" -Data @{
        ProcessId = $window.ProcessId
        Title = $window.Title
        CloseRequested = $closeRequested
    }

    $closeStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $windowClosed = $false
    while ($closeStopwatch.Elapsed.TotalSeconds -lt 30) {
        if (-not (Get-VisibleWaveLinkWindow)) {
            $windowClosed = $true
            break
        }

        Start-Sleep -Milliseconds 500
    }

    if (-not $windowClosed) {
        Add-RunEvent -Logger $logger -Message "Wave Link window remained visible after close request." -Type "warning"
    }

    Complete-RunLogger -Logger $logger -Status "success" -Summary @{
        WindowDetected = $true
        WindowClosed = $windowClosed
        WaitedForWindowSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
        HeldUiSeconds = $HoldUiSeconds
        ProcessId = $window.ProcessId
        Title = $window.Title
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
