param(
    [string]$StartupFolder = (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"),
    [string]$BrowserStarterScriptPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Start-DefaultBrowser.ps1"),
    [string]$DiscordUpdatePath = (Join-Path $env:LOCALAPPDATA "Discord\Update.exe"),
    [string]$SpotifyPath = (Join-Path $env:APPDATA "Spotify\Spotify.exe")
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "RunLogger.ps1")

$logger = New-RunLogger -ScriptName "Install-AppStartupShortcuts" -ScriptRoot $scriptRoot -Parameters @{
    StartupFolder = $StartupFolder
    BrowserStarterScriptPath = $BrowserStarterScriptPath
    DiscordUpdatePath = $DiscordUpdatePath
    SpotifyPath = $SpotifyPath
}

function New-StartupShortcut {
    param(
        [string]$ShortcutPath,
        [string]$TargetPath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$Description
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = ($Arguments -join " ")
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Description = $Description
    $shortcut.Save()
}

try {
    Add-RunEvent -Logger $logger -Message "Run started." -Type "start"

    if (-not (Test-Path $StartupFolder)) {
        New-Item -ItemType Directory -Path $StartupFolder -Force | Out-Null
    }

    if (-not (Test-Path $BrowserStarterScriptPath)) {
        throw "Default browser starter script not found at $BrowserStarterScriptPath"
    }

    if (-not (Test-Path $DiscordUpdatePath)) {
        throw "Discord launcher not found at $DiscordUpdatePath"
    }

    $browserShortcutPath = Join-Path $StartupFolder "Default Browser.lnk"
    New-StartupShortcut `
        -ShortcutPath $browserShortcutPath `
        -TargetPath "powershell.exe" `
        -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$BrowserStarterScriptPath`"") `
        -WorkingDirectory $scriptRoot `
        -Description "Start the current default browser at logon"

    Add-RunEvent -Logger $logger -Message "Created default browser startup shortcut." -Type "shortcut_created" -Data @{
        ShortcutPath = $browserShortcutPath
        TargetPath = "powershell.exe"
        Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $BrowserStarterScriptPath)
    }

    $discordShortcutPath = Join-Path $StartupFolder "Discord.lnk"
    New-StartupShortcut `
        -ShortcutPath $discordShortcutPath `
        -TargetPath $DiscordUpdatePath `
        -Arguments @("--processStart", "Discord.exe") `
        -WorkingDirectory (Split-Path -Parent $DiscordUpdatePath) `
        -Description "Start Discord at logon"

    Add-RunEvent -Logger $logger -Message "Created Discord startup shortcut." -Type "shortcut_created" -Data @{
        ShortcutPath = $discordShortcutPath
        TargetPath = $DiscordUpdatePath
        Arguments = @("--processStart", "Discord.exe")
    }

    if (Test-Path $SpotifyPath) {
        $spotifyShortcutPath = Join-Path $StartupFolder "Spotify.lnk"
        New-StartupShortcut `
            -ShortcutPath $spotifyShortcutPath `
            -TargetPath $SpotifyPath `
            -Arguments @() `
            -WorkingDirectory (Split-Path -Parent $SpotifyPath) `
            -Description "Start Spotify at logon"

        Add-RunEvent -Logger $logger -Message "Created Spotify startup shortcut." -Type "shortcut_created" -Data @{
            ShortcutPath = $spotifyShortcutPath
            TargetPath = $SpotifyPath
        }
    }
    else {
        Add-RunEvent -Logger $logger -Message "Spotify executable was not found. Skipping Spotify startup shortcut." -Type "skipped" -Data @{
            SpotifyPath = $SpotifyPath
        }
    }

    Complete-RunLogger -Logger $logger -Status "success" -Summary @{
        StartupFolder = $StartupFolder
        Shortcuts = @(
            [pscustomobject]@{
                Name = "Default Browser"
                ShortcutPath = $browserShortcutPath
                TargetPath = "powershell.exe"
                Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $BrowserStarterScriptPath)
            },
            [pscustomobject]@{
                Name = "Discord"
                ShortcutPath = $discordShortcutPath
                TargetPath = $DiscordUpdatePath
                Arguments = @("--processStart", "Discord.exe")
            },
            [pscustomobject]@{
                Name = "Spotify"
                ShortcutPath = if (Test-Path $SpotifyPath) { (Join-Path $StartupFolder "Spotify.lnk") } else { $null }
                TargetPath = if (Test-Path $SpotifyPath) { $SpotifyPath } else { $null }
            }
        )
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
