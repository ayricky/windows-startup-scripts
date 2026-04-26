param(
    [int]$InitialDelaySeconds = 180,
    [int]$LayoutTolerancePixels = 20,
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "window-layout.json"),
    [string[]]$ClosedProcessNames = @(),
    [string[]]$HiddenWindowProcessNames = @(
        "StreamDeck",
        "WaveLink",
        "WaveLinkSE",
        "rawaccel"
    ),
    [switch]$Remediate
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "RunLogger.ps1")
. (Join-Path $scriptRoot "BrowserSupport.ps1")
. (Join-Path $scriptRoot "DisplayLayoutProfiles.ps1")

$logger = New-RunLogger -ScriptName "Post-BootCheck" -ScriptRoot $scriptRoot -Parameters @{
    InitialDelaySeconds = $InitialDelaySeconds
    LayoutTolerancePixels = $LayoutTolerancePixels
    ConfigPath = $ConfigPath
    ClosedProcessNames = $ClosedProcessNames
    HiddenWindowProcessNames = $HiddenWindowProcessNames
    Remediate = [bool]$Remediate
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

function Test-WithinTolerance {
    param(
        [int]$Actual,
        [int]$Expected,
        [int]$Tolerance
    )

    return ([math]::Abs($Actual - $Expected) -le $Tolerance)
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

function Get-LayoutChecks {
    param(
        [object[]]$Windows,
        [object[]]$LayoutEntries,
        [object]$BrowserInfo,
        [int]$Tolerance
    )

    $checks = foreach ($entry in @($LayoutEntries)) {
        $processName = Resolve-EntryProcessName -Entry $entry -BrowserInfo $BrowserInfo
        $window = Get-BestWindowMatch -Windows $Windows -ProcessName $processName -Title $entry.Title

        if (-not $window) {
            [pscustomobject]@{
                AppKey = Get-EntryAppKey -Entry $entry
                ProcessName = $processName
                SavedProcessName = $entry.ProcessName
                Found = $false
                InPosition = $false
                Reason = "Window not found"
            }
            continue
        }

        $inPosition =
            (Test-WithinTolerance -Actual $window.Left -Expected ([int]$entry.Left) -Tolerance $Tolerance) -and
            (Test-WithinTolerance -Actual $window.Top -Expected ([int]$entry.Top) -Tolerance $Tolerance) -and
            (Test-WithinTolerance -Actual $window.Width -Expected ([int]$entry.Width) -Tolerance $Tolerance) -and
            (Test-WithinTolerance -Actual $window.Height -Expected ([int]$entry.Height) -Tolerance $Tolerance)

        [pscustomobject]@{
            AppKey = Get-EntryAppKey -Entry $entry
            ProcessName = $processName
            SavedProcessName = $entry.ProcessName
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

    return @($checks)
}

function Invoke-RemediationScript {
    param(
        [hashtable]$Logger,
        [string]$Name,
        [string]$ScriptPath,
        [string[]]$ArgumentList = @()
    )

    $startedAt = [DateTimeOffset]::Now
    Add-RunEvent -Logger $Logger -Message "Starting remediation script." -Type "remediation_start" -Data @{
        Name = $Name
        ScriptPath = $ScriptPath
        Arguments = @($ArgumentList)
    }

    $process = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $ScriptPath) + @($ArgumentList) `
        -WindowStyle Hidden `
        -PassThru `
        -Wait

    $result = [pscustomobject]@{
        Name = $Name
        ScriptPath = $ScriptPath
        Arguments = @($ArgumentList)
        StartedAt = $startedAt.ToString("o")
        ExitCode = $process.ExitCode
        Succeeded = ($process.ExitCode -eq 0)
    }

    Add-RunEvent -Logger $Logger -Message "Finished remediation script." -Type "remediation_complete" -Data $result
    return $result
}

try {
    Add-RunEvent -Logger $logger -Message "Run started." -Type "start"

    if ($InitialDelaySeconds -gt 0) {
        Start-Sleep -Seconds $InitialDelaySeconds
    }

    $sessionWindowStart = $logger.StartedAt.AddMinutes(-2)
    $now = [DateTimeOffset]::Now

    $applyRuns = Get-RunHistory -Path (Join-Path $scriptRoot "logs\Apply-WindowLayout.runs.json")
    $primeRuns = Get-RunHistory -Path (Join-Path $scriptRoot "logs\Prime-WaveLinkUI.runs.json")
    $applyRun = @($applyRuns | Where-Object { ([DateTimeOffset]$_.StartedAt) -ge $sessionWindowStart -and ([DateTimeOffset]$_.StartedAt) -le $now } | Select-Object -Last 1)[0]
    $primeRun = @($primeRuns | Where-Object { ([DateTimeOffset]$_.StartedAt) -ge $sessionWindowStart -and ([DateTimeOffset]$_.StartedAt) -le $now } | Select-Object -Last 1)[0]

    $layoutChecks = @()
    $windows = Get-TopLevelWindows
    $browserInfo = Get-DefaultBrowserInfo
    $displayState = $null
    $layoutPlan = $null
    $layoutEntries = @()
    if (Test-Path $ConfigPath) {
        $displayState = Get-DisplayLayoutState
        $config = Read-WindowLayoutConfig -Path $ConfigPath
        $layoutPlan = Resolve-WindowLayoutPlan -Config $config -DisplayState $displayState
        $layoutEntries = if ($layoutPlan) { @($layoutPlan.Windows) } else { @() }

        if ($layoutPlan) {
            Add-RunEvent -Logger $logger -Message "Selected layout plan for verification." -Type "profile_selected" -Data @{
                MatchType = $layoutPlan.MatchType
                WindowCount = $layoutEntries.Count
            }
        }
        else {
            Add-RunEvent -Logger $logger -Message "No saved layout plan matched the current display layout." -Type "warning" -Data @{
                MonitorCount = $displayState.MonitorCount
            }
        }
        $layoutChecks = Get-LayoutChecks -Windows $windows -LayoutEntries $layoutEntries -BrowserInfo $browserInfo -Tolerance $LayoutTolerancePixels
    }
    else {
        Add-RunEvent -Logger $logger -Message "Layout config not found." -Type "warning" -Data @{
            ConfigPath = $ConfigPath
        }
    }

    $processChecks = @(
        foreach ($processName in $ClosedProcessNames) {
        $running = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
        [pscustomobject]@{
            ProcessName = $processName
            Running = ($running.Count -gt 0)
            Pids = @($running | Select-Object -ExpandProperty Id)
        }
        }
    )

    $hiddenWindowChecks = @(
        foreach ($processName in $HiddenWindowProcessNames) {
        $window = Get-BestWindowMatch -Windows $windows -ProcessName $processName -Title ""
        [pscustomobject]@{
            ProcessName = $processName
            WindowVisible = [bool]$window
            WindowTitle = if ($window) { $window.Title } else { $null }
            Handle = if ($window) { $window.Handle } else { $null }
        }
        }
    )

    $layoutNeedsRemediation = @($layoutChecks | Where-Object { -not $_.Found -or -not $_.InPosition }).Count -gt 0
    $primeNeedsRemediation = (-not $primeRun) -or ($primeRun.Status -notin @("success", "skipped"))
    $remediation = [ordered]@{
        Layout = $null
        PrimeWaveLink = $null
    }

    if ($Remediate -and $primeNeedsRemediation) {
        $primeScriptPath = Join-Path $scriptRoot "Prime-WaveLinkUI.ps1"
        if (Test-Path $primeScriptPath) {
            $remediation.PrimeWaveLink = Invoke-RemediationScript `
                -Logger $logger `
                -Name "Prime-WaveLinkUI" `
                -ScriptPath $primeScriptPath `
                -ArgumentList @("-InitialDelaySeconds", "0", "-WaitForWindowSeconds", "20", "-HoldUiSeconds", "8")

            $primeRuns = Get-RunHistory -Path (Join-Path $scriptRoot "logs\Prime-WaveLinkUI.runs.json")
            $primeRun = @($primeRuns | Where-Object { ([DateTimeOffset]$_.StartedAt) -ge ([DateTimeOffset]$remediation.PrimeWaveLink.StartedAt) } | Select-Object -Last 1)[0]
        }
    }

    if ($Remediate -and $layoutNeedsRemediation -and $layoutEntries.Count -gt 0) {
        $applyScriptPath = Join-Path $scriptRoot "Apply-WindowLayout.ps1"
        if (Test-Path $applyScriptPath) {
            $remediation.Layout = Invoke-RemediationScript `
                -Logger $logger `
                -Name "Apply-WindowLayout" `
                -ScriptPath $applyScriptPath `
                -ArgumentList @("-StartupDelaySeconds", "0", "-WaitForExistingWindowSeconds", "20", "-PollIntervalSeconds", "1")

            $applyRuns = Get-RunHistory -Path (Join-Path $scriptRoot "logs\Apply-WindowLayout.runs.json")
            $applyRun = @($applyRuns | Where-Object { ([DateTimeOffset]$_.StartedAt) -ge ([DateTimeOffset]$remediation.Layout.StartedAt) } | Select-Object -Last 1)[0]

            $windows = Get-TopLevelWindows
            $layoutChecks = Get-LayoutChecks -Windows $windows -LayoutEntries $layoutEntries -BrowserInfo $browserInfo -Tolerance $LayoutTolerancePixels
            $hiddenWindowChecks = @(
                foreach ($processName in $HiddenWindowProcessNames) {
                    $window = Get-BestWindowMatch -Windows $windows -ProcessName $processName -Title ""
                    [pscustomobject]@{
                        ProcessName = $processName
                        WindowVisible = [bool]$window
                        WindowTitle = if ($window) { $window.Title } else { $null }
                        Handle = if ($window) { $window.Handle } else { $null }
                    }
                }
            )
        }
    }

    $issues = @()
    if (-not $applyRun) {
        $issues += "Apply-WindowLayout did not run after boot."
    }
    elseif ($applyRun.Status -ne "success") {
        $issues += "Apply-WindowLayout last run after boot was $($applyRun.Status)."
    }

    if (-not $primeRun) {
        $issues += "Prime-WaveLinkUI did not run after boot."
    }
    elseif ($primeRun.Status -notin @("success", "skipped")) {
        $issues += "Prime-WaveLinkUI last run after boot was $($primeRun.Status)."
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

    foreach ($entry in $hiddenWindowChecks) {
        if ($entry.WindowVisible) {
            $issues += "$($entry.ProcessName) window is still visible."
        }
    }

    foreach ($issue in $issues) {
        Add-RunEvent -Logger $logger -Message $issue -Type "issue"
    }

    $status = if ($issues.Count -eq 0) { "success" } else { "failed" }
    Complete-RunLogger -Logger $logger -Status $status -Summary @{
        SessionWindowStart = $sessionWindowStart.ToString("o")
        ApplyRun = if ($applyRun) { $applyRun } else { $null }
        PrimeRun = if ($primeRun) { $primeRun } else { $null }
        DisplayState = if ($displayState) { $displayState } else { $null }
        Browser = if ($browserInfo) {
            [pscustomobject]@{
                ProcessName = $browserInfo.ProcessName
                FilePath = $browserInfo.FilePath
                ProgId = $browserInfo.ProgId
            }
        } else { $null }
        ProfileMatchType = if ($layoutPlan) { $layoutPlan.MatchType } else { $null }
        LayoutChecks = $layoutChecks
        ProcessChecks = $processChecks
        HiddenWindowChecks = $hiddenWindowChecks
        RemediationEnabled = [bool]$Remediate
        Remediation = [pscustomobject]$remediation
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
