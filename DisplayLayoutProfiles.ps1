Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

function Get-DisplayLayoutState {
    $screens = [System.Windows.Forms.Screen]::AllScreens |
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
            Version = 2
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

        return [pscustomobject]@{
            Version = if ($RawConfig.PSObject.Properties.Name -contains "Version") { [int]$RawConfig.Version } else { 2 }
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
        Version = 2
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
            Version = 2
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
