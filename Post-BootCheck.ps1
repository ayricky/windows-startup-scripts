param(
    [int]$InitialDelaySeconds = 480,
    [int]$LayoutTolerancePixels = 12,
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "window-layout.json"),
    [string[]]$ClosedProcessNames = @(
        "StreamDeck",
        "WaveLink",
        "WaveLinkSE"
    )
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "RunLogger.ps1")

$logger = New-RunLogger -ScriptName "Post-BootCheck" -ScriptRoot $scriptRoot -Parameters @{
    InitialDelaySeconds = $InitialDelaySeconds
    LayoutTolerancePixels = $LayoutTolerancePixels
    ConfigPath = $ConfigPath
    ClosedProcessNames = $ClosedProcessNames
}

$signature = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class PostBootNative {
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

function Get-TopLevelWindows {
    $windows = New-Object System.Collections.Generic.List[object]
    $callback = [PostBootNative+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)

        [uint32]$processId = 0
        [void][PostBootNative]::GetWindowThreadProcessId($hWnd, [ref]$processId)
        if ($processId -eq 0) {
            return $true
        }

        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
        }
        catch {
            return $true
        }

        $rect = New-Object PostBootNative+RECT
        if (-not [PostBootNative]::GetWindowRect($hWnd, [ref]$rect)) {
            return $true
        }

        $length = [PostBootNative]::GetWindowTextLength($hWnd)
        $titleBuilder = New-Object System.Text.StringBuilder ($length + 1)
        if ($length -gt 0) {
            [void][PostBootNative]::GetWindowText($hWnd, $titleBuilder, $titleBuilder.Capacity)
        }

        $windows.Add([pscustomobject]@{
            ProcessName = $process.ProcessName
            Handle = $hWnd.ToInt64()
            Visible = [PostBootNative]::IsWindowVisible($hWnd)
            Title = $titleBuilder.ToString()
            Left = $rect.Left
            Top = $rect.Top
            Width = $rect.Right - $rect.Left
            Height = $rect.Bottom - $rect.Top
            Area = ($rect.Right - $rect.Left) * ($rect.Bottom - $rect.Top)
        }) | Out-Null

        return $true
    }

    [void][PostBootNative]::EnumWindows($callback, [IntPtr]::Zero)
    return $windows
}

function Get-BestWindowMatch {
    param(
        [object[]]$Windows,
        [string]$ProcessName,
        [string]$Title
    )

    $matches = $Windows | Where-Object {
        $_.ProcessName -ieq $ProcessName -and
        $_.Visible -and
        $_.Width -gt 200 -and
        $_.Height -gt 150
    }

    if ($Title) {
        $titleMatch = $matches | Where-Object { $_.Title -eq $Title } | Sort-Object Area -Descending | Select-Object -First 1
        if ($titleMatch) {
            return $titleMatch
        }
    }

    return $matches | Sort-Object Area -Descending | Select-Object -First 1
}

function Test-WithinTolerance {
    param(
        [int]$Actual,
        [int]$Expected,
        [int]$Tolerance
    )

    return ([math]::Abs($Actual - $Expected) -le $Tolerance)
}

try {
    Add-RunEvent -Logger $logger -Message "Run started." -Type "start"

    if ($InitialDelaySeconds -gt 0) {
        Start-Sleep -Seconds $InitialDelaySeconds
    }

    $bootTime = (Get-Date).AddMilliseconds(-[Environment]::TickCount64)

    $applyRuns = Get-RunHistory -Path (Join-Path $scriptRoot "logs\Apply-WindowLayout.runs.json")
    $closeRuns = Get-RunHistory -Path (Join-Path $scriptRoot "logs\Close-PeripheralStartupApps.runs.json")
    $applyRun = @($applyRuns | Where-Object { [datetime]$_.StartedAt -ge $bootTime } | Select-Object -Last 1)[0]
    $closeRun = @($closeRuns | Where-Object { [datetime]$_.StartedAt -ge $bootTime } | Select-Object -Last 1)[0]

    $layoutChecks = @()
    if (Test-Path $ConfigPath) {
        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if ($config -isnot [System.Collections.IEnumerable]) {
            $config = @($config)
        }

        $windows = Get-TopLevelWindows
        foreach ($entry in $config) {
            $window = Get-BestWindowMatch -Windows $windows -ProcessName $entry.ProcessName -Title $entry.Title

            if (-not $window) {
                $layoutChecks += [pscustomobject]@{
                    ProcessName = $entry.ProcessName
                    Found = $false
                    InPosition = $false
                    Reason = "Window not found"
                }
                continue
            }

            $inPosition =
                (Test-WithinTolerance -Actual $window.Left -Expected ([int]$entry.Left) -Tolerance $LayoutTolerancePixels) -and
                (Test-WithinTolerance -Actual $window.Top -Expected ([int]$entry.Top) -Tolerance $LayoutTolerancePixels) -and
                (Test-WithinTolerance -Actual $window.Width -Expected ([int]$entry.Width) -Tolerance $LayoutTolerancePixels) -and
                (Test-WithinTolerance -Actual $window.Height -Expected ([int]$entry.Height) -Tolerance $LayoutTolerancePixels)

            $layoutChecks += [pscustomobject]@{
                ProcessName = $entry.ProcessName
                Found = $true
                InPosition = $inPosition
                Reason = if ($inPosition) { "OK" } else { "Window found but geometry differs" }
                ActualLeft = $window.Left
                ActualTop = $window.Top
                ActualWidth = $window.Width
                ActualHeight = $window.Height
                ExpectedLeft = [int]$entry.Left
                ExpectedTop = [int]$entry.Top
                ExpectedWidth = [int]$entry.Width
                ExpectedHeight = [int]$entry.Height
            }
        }
    }
    else {
        Add-RunEvent -Logger $logger -Message "Layout config not found." -Type "warning" -Data @{
            ConfigPath = $ConfigPath
        }
    }

    $processChecks = foreach ($processName in $ClosedProcessNames) {
        $running = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
        [pscustomobject]@{
            ProcessName = $processName
            Running = ($running.Count -gt 0)
            Pids = @($running | Select-Object -ExpandProperty Id)
        }
    }

    $issues = @()
    if (-not $applyRun) {
        $issues += "Apply-WindowLayout did not run after boot."
    }
    elseif ($applyRun.Status -ne "success") {
        $issues += "Apply-WindowLayout last run after boot was $($applyRun.Status)."
    }

    if (-not $closeRun) {
        $issues += "Close-PeripheralStartupApps did not run after boot."
    }
    elseif ($closeRun.Status -ne "success") {
        $issues += "Close-PeripheralStartupApps last run after boot was $($closeRun.Status)."
    }

    foreach ($entry in $layoutChecks) {
        if (-not $entry.Found) {
            $issues += "$($entry.ProcessName) window was not found."
        }
        elseif (-not $entry.InPosition) {
            $issues += "$($entry.ProcessName) window is not in the saved position."
        }
    }

    foreach ($entry in $processChecks) {
        if ($entry.Running) {
            $issues += "$($entry.ProcessName) is still running."
        }
    }

    foreach ($issue in $issues) {
        Add-RunEvent -Logger $logger -Message $issue -Type "issue"
    }

    $status = if ($issues.Count -eq 0) { "success" } else { "failed" }
    Complete-RunLogger -Logger $logger -Status $status -Summary @{
        BootTime = $bootTime.ToString("o")
        ApplyRun = if ($applyRun) { $applyRun } else { $null }
        CloseRun = if ($closeRun) { $closeRun } else { $null }
        LayoutChecks = $layoutChecks
        ProcessChecks = $processChecks
        Issues = $issues
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
