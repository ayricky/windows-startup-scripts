param(
    [string]$StartupFolder = (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"),
    [string]$BrowserStarterScriptPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Start-DefaultBrowser.ps1"),
    [string]$DiscordUpdatePath = (Join-Path $env:LOCALAPPDATA "Discord\Update.exe"),
    [string]$SpotifyPath = (Join-Path $env:APPDATA "Spotify\Spotify.exe"),
    [switch]$CreateShortcuts,
    [switch]$KeepLegacyBrowserShortcuts
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "RunLogger.ps1")

$logger = New-RunLogger -ScriptName "Install-AppStartupShortcuts" -ScriptRoot $scriptRoot -Parameters @{
    StartupFolder = $StartupFolder
    BrowserStarterScriptPath = $BrowserStarterScriptPath
    DiscordUpdatePath = $DiscordUpdatePath
    SpotifyPath = $SpotifyPath
    CreateShortcuts = [bool]$CreateShortcuts
    KeepLegacyBrowserShortcuts = [bool]$KeepLegacyBrowserShortcuts
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

$managedShortcutNames = @(
    "Default Browser.lnk",
    "Discord.lnk",
    "Spotify.lnk"
)

if (-not $KeepLegacyBrowserShortcuts) {
    $managedShortcutNames += "Zen Browser.lnk"
}

try {
    Add-RunEvent -Logger $logger -Message "Run started." -Type "start"

    if (-not (Test-Path $StartupFolder)) {
        New-Item -ItemType Directory -Path $StartupFolder -Force | Out-Null
    }

    $removedShortcuts = New-Object System.Collections.Generic.List[object]
    foreach ($shortcutName in $managedShortcutNames) {
        $shortcutPath = Join-Path $StartupFolder $shortcutName
        if (Test-Path $shortcutPath -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $shortcutPath -Force
            $removedShortcuts.Add([pscustomobject]@{
                Name = $shortcutName
                ShortcutPath = $shortcutPath
            }) | Out-Null
            Add-RunEvent -Logger $logger -Message "Removed managed startup shortcut." -Type "shortcut_removed" -Data @{
                Name = $shortcutName
                ShortcutPath = $shortcutPath
            }
        }
    }

    $removedShortcutSummary = for ($removedIndex = 0; $removedIndex -lt $removedShortcuts.Count; $removedIndex++) {
        $removedShortcut = $removedShortcuts[$removedIndex]
        [pscustomobject]@{
            Name = $removedShortcut.Name
            ShortcutPath = $removedShortcut.ShortcutPath
        }
    }

    if (-not $CreateShortcuts) {
        Complete-RunLogger -Logger $logger -Status "success" -Summary @{
            StartupFolder = $StartupFolder
            Mode = "cleanup"
            RemovedShortcuts = @($removedShortcutSummary)
            CreatedShortcuts = @()
        }
        return
    }

    if (-not (Test-Path $BrowserStarterScriptPath)) {
        throw "Default browser starter script not found at $BrowserStarterScriptPath"
    }

    if (-not (Test-Path $DiscordUpdatePath)) {
        throw "Discord launcher not found at $DiscordUpdatePath"
    }

    $createdShortcuts = New-Object System.Collections.Generic.List[object]

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
    $createdShortcuts.Add([pscustomobject]@{
        Name = "Default Browser"
        ShortcutPath = $browserShortcutPath
        TargetPath = "powershell.exe"
        Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $BrowserStarterScriptPath)
    }) | Out-Null

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
    $createdShortcuts.Add([pscustomobject]@{
        Name = "Discord"
        ShortcutPath = $discordShortcutPath
        TargetPath = $DiscordUpdatePath
        Arguments = @("--processStart", "Discord.exe")
    }) | Out-Null

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
        $createdShortcuts.Add([pscustomobject]@{
            Name = "Spotify"
            ShortcutPath = $spotifyShortcutPath
            TargetPath = $SpotifyPath
            Arguments = @()
        }) | Out-Null
    }
    else {
        Add-RunEvent -Logger $logger -Message "Spotify executable was not found. Skipping Spotify startup shortcut." -Type "skipped" -Data @{
            SpotifyPath = $SpotifyPath
        }
    }

    $createdShortcutSummary = for ($createdIndex = 0; $createdIndex -lt $createdShortcuts.Count; $createdIndex++) {
        $createdShortcut = $createdShortcuts[$createdIndex]
        [pscustomobject]@{
            Name = $createdShortcut.Name
            ShortcutPath = $createdShortcut.ShortcutPath
            TargetPath = $createdShortcut.TargetPath
            Arguments = @($createdShortcut.Arguments)
        }
    }

    Complete-RunLogger -Logger $logger -Status "success" -Summary @{
        StartupFolder = $StartupFolder
        Mode = "create"
        RemovedShortcuts = @($removedShortcutSummary)
        CreatedShortcuts = @($createdShortcutSummary)
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
