Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

function Get-DisplayLayoutState {
    $rawScreens = [System.Windows.Forms.Screen]::AllScreens |
        ForEach-Object {
            [pscustomobject]@{
                DeviceName = $_.DeviceName
                X = $_.Bounds.X
                Y = $_.Bounds.Y
                Width = $_.Bounds.Width
                Height = $_.Bounds.Height
                Primary = [bool]$_.Primary
            }
        } |
        Sort-Object X, Y, DeviceName

    $screenIndex = 0
    $screens = foreach ($screen in $rawScreens) {
        $screenIndex++
        [pscustomobject]@{
            DeviceName = $screen.DeviceName
            Role = "screen$screenIndex"
            X = $screen.X
            Y = $screen.Y
            Width = $screen.Width
            Height = $screen.Height
            Primary = $screen.Primary
        }
    }

    $virtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $signature = ($screens | ForEach-Object {
        "{0}:{1},{2},{3}x{4}:{5}" -f $_.DeviceName, $_.X, $_.Y, $_.Width, $_.Height, [int]$_.Primary
    }) -join "|"

    return [pscustomobject]@{
        Signature = $signature
        MonitorCount = @($screens).Count
        VirtualScreen = [pscustomobject]@{
            X = $virtual.X
            Y = $virtual.Y
            Width = $virtual.Width
            Height = $virtual.Height
        }
        Screens = @($screens)
    }
}

function ConvertTo-WindowLayoutConfig {
    param([object]$RawConfig)

    if ($null -eq $RawConfig) {
        return [pscustomobject]@{
            Version = 3
            DynamicWindows = @()
            Profiles = @()
        }
    }

    if ($RawConfig.PSObject.Properties.Name -contains "Profiles") {
        $profiles = foreach ($profile in @($RawConfig.Profiles)) {
            [pscustomobject]@{
                Signature = if ($profile.PSObject.Properties.Name -contains "Signature") { $profile.Signature } else { $null }
                DisplayState = if ($profile.PSObject.Properties.Name -contains "DisplayState") { $profile.DisplayState } else { $null }
                CapturedAt = if ($profile.PSObject.Properties.Name -contains "CapturedAt") { $profile.CapturedAt } else { $null }
                Windows = @($profile.Windows)
            }
        }

        $dynamicWindows = if ($RawConfig.PSObject.Properties.Name -contains "DynamicWindows") {
            @($RawConfig.DynamicWindows)
        }
        else {
            @()
        }

        return [pscustomobject]@{
            Version = if ($RawConfig.PSObject.Properties.Name -contains "Version") { [int]$RawConfig.Version } else { 3 }
            DynamicWindows = $dynamicWindows
            Profiles = @($profiles)
        }
    }

    $legacyWindows = if ($RawConfig -is [System.Collections.IEnumerable] -and $RawConfig -isnot [string]) {
        @($RawConfig)
    }
    else {
        @($RawConfig)
    }

    return [pscustomobject]@{
        Version = 3
        DynamicWindows = @()
        Profiles = @(
            [pscustomobject]@{
                Signature = $null
                DisplayState = $null
                CapturedAt = $null
                Windows = @($legacyWindows)
            }
        )
    }
}

function Read-WindowLayoutConfig {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return [pscustomobject]@{
            Version = 3
            DynamicWindows = @()
            Profiles = @()
        }
    }

    $raw = Get-Content $Path -Raw | ConvertFrom-Json
    return ConvertTo-WindowLayoutConfig -RawConfig $raw
}

function Select-WindowLayoutProfile {
    param(
        [object]$Config,
        [object]$DisplayState
    )

    $profiles = @($Config.Profiles)
    if (-not $profiles) {
        return $null
    }

    $exact = @($profiles | Where-Object { $_.Signature -and $_.Signature -eq $DisplayState.Signature })
    if ($exact.Count -gt 0) {
        return [pscustomobject]@{
            MatchType = "exact"
            Profile = $exact[-1]
        }
    }

    $legacy = @($profiles | Where-Object { [string]::IsNullOrWhiteSpace($_.Signature) })
    if ($legacy.Count -gt 0) {
        return [pscustomobject]@{
            MatchType = "legacy_fallback"
            Profile = $legacy[-1]
        }
    }

    if ($profiles.Count -eq 1) {
        return [pscustomobject]@{
            MatchType = "single_fallback"
            Profile = $profiles[0]
        }
    }

    return [pscustomobject]@{
        MatchType = "last_resort"
        Profile = $profiles[-1]
    }
}

function Get-RectOverlapArea {
    param(
        [int]$LeftA,
        [int]$TopA,
        [int]$WidthA,
        [int]$HeightA,
        [int]$LeftB,
        [int]$TopB,
        [int]$WidthB,
        [int]$HeightB
    )

    $rightA = $LeftA + $WidthA
    $bottomA = $TopA + $HeightA
    $rightB = $LeftB + $WidthB
    $bottomB = $TopB + $HeightB

    $overlapWidth = [Math]::Min($rightA, $rightB) - [Math]::Max($LeftA, $LeftB)
    $overlapHeight = [Math]::Min($bottomA, $bottomB) - [Math]::Max($TopA, $TopB)

    if ($overlapWidth -le 0 -or $overlapHeight -le 0) {
        return 0
    }

    return $overlapWidth * $overlapHeight
}

function Get-BestScreenForWindow {
    param(
        [object]$DisplayState,
        [object]$Window
    )

    $bestScreen = $null
    $bestOverlap = -1
    foreach ($screen in @($DisplayState.Screens)) {
        $overlap = Get-RectOverlapArea `
            -LeftA ([int]$Window.Left) `
            -TopA ([int]$Window.Top) `
            -WidthA ([int]$Window.Width) `
            -HeightA ([int]$Window.Height) `
            -LeftB ([int]$screen.X) `
            -TopB ([int]$screen.Y) `
            -WidthB ([int]$screen.Width) `
            -HeightB ([int]$screen.Height)

        if ($overlap -gt $bestOverlap) {
            $bestOverlap = $overlap
            $bestScreen = $screen
        }
    }

    return $bestScreen
}

function ConvertTo-DynamicWindowLayoutEntries {
    param(
        [object[]]$Windows,
        [object]$DisplayState
    )

    $dynamicEntries = foreach ($window in @($Windows)) {
        $screen = Get-BestScreenForWindow -DisplayState $DisplayState -Window $window
        if (-not $screen) {
            continue
        }

        [pscustomobject]@{
            ProcessName = $window.ProcessName
            Title = if ($window.PSObject.Properties.Name -contains "Title") { $window.Title } else { "" }
            MonitorDeviceName = $screen.DeviceName
            MonitorRole = $screen.Role
            RelativeLeft = [Math]::Round((([double]$window.Left - [double]$screen.X) / [double]$screen.Width), 6)
            RelativeTop = [Math]::Round((([double]$window.Top - [double]$screen.Y) / [double]$screen.Height), 6)
            RelativeWidth = [Math]::Round(([double]$window.Width / [double]$screen.Width), 6)
            RelativeHeight = [Math]::Round(([double]$window.Height / [double]$screen.Height), 6)
            Left = [int]$window.Left
            Top = [int]$window.Top
            Width = [int]$window.Width
            Height = [int]$window.Height
        }
    }

    return @($dynamicEntries)
}

function Resolve-DynamicWindowLayoutEntries {
    param(
        [object[]]$DynamicWindows,
        [object]$DisplayState
    )

    $resolvedEntries = foreach ($entry in @($DynamicWindows)) {
        $screen = @($DisplayState.Screens | Where-Object { $_.DeviceName -eq $entry.MonitorDeviceName } | Select-Object -First 1)[0]
        if (-not $screen -and $entry.PSObject.Properties.Name -contains "MonitorRole") {
            $screen = @($DisplayState.Screens | Where-Object { $_.Role -eq $entry.MonitorRole } | Select-Object -First 1)[0]
        }

        if (-not $screen) {
            continue
        }

        [pscustomobject]@{
            ProcessName = $entry.ProcessName
            Title = if ($entry.PSObject.Properties.Name -contains "Title") { $entry.Title } else { "" }
            Left = [int][Math]::Round([double]$screen.X + ([double]$entry.RelativeLeft * [double]$screen.Width))
            Top = [int][Math]::Round([double]$screen.Y + ([double]$entry.RelativeTop * [double]$screen.Height))
            Width = [Math]::Max(1, [int][Math]::Round([double]$entry.RelativeWidth * [double]$screen.Width))
            Height = [Math]::Max(1, [int][Math]::Round([double]$entry.RelativeHeight * [double]$screen.Height))
            MonitorDeviceName = $screen.DeviceName
            MonitorRole = $screen.Role
        }
    }

    return @($resolvedEntries)
}

function Resolve-WindowLayoutPlan {
    param(
        [object]$Config,
        [object]$DisplayState
    )

    $dynamicWindows = @($Config.DynamicWindows)
    if ($dynamicWindows.Count -gt 0) {
        $resolvedWindows = Resolve-DynamicWindowLayoutEntries -DynamicWindows $dynamicWindows -DisplayState $DisplayState
        if ($resolvedWindows.Count -eq $dynamicWindows.Count) {
            return [pscustomobject]@{
                MatchType = "dynamic_relative"
                Profile = $null
                Windows = @($resolvedWindows)
            }
        }
    }

    $profileSelection = Select-WindowLayoutProfile -Config $Config -DisplayState $DisplayState
    if ($profileSelection) {
        return [pscustomobject]@{
            MatchType = $profileSelection.MatchType
            Profile = $profileSelection.Profile
            Windows = @($profileSelection.Profile.Windows)
        }
    }

    return $null
}
