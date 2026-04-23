function Get-RegistryDefaultValue {
    param([string]$Path)

    try {
        return (Get-ItemProperty -Path $Path -ErrorAction Stop).'(default)'
    }
    catch {
        return $null
    }
}

function Get-DefaultBrowserProgId {
    $associationRoots = @(
        "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice",
        "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice"
    )

    foreach ($root in $associationRoots) {
        try {
            $progId = (Get-ItemProperty -Path $root -Name ProgId -ErrorAction Stop).ProgId
            if (-not [string]::IsNullOrWhiteSpace($progId)) {
                return $progId
            }
        }
        catch {
        }
    }

    return $null
}

function Get-BrowserCommandForProgId {
    param([string]$ProgId)

    if ([string]::IsNullOrWhiteSpace($ProgId)) {
        return $null
    }

    $commandRoots = @(
        "HKCU:\Software\Classes\$ProgId\shell\open\command",
        "Registry::HKEY_CLASSES_ROOT\$ProgId\shell\open\command",
        "HKLM:\Software\Classes\$ProgId\shell\open\command"
    )

    foreach ($root in $commandRoots) {
        $command = Get-RegistryDefaultValue -Path $root
        if (-not [string]::IsNullOrWhiteSpace($command)) {
            return $command
        }
    }

    return $null
}

function Resolve-ExecutablePathFromCommand {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return $null
    }

    if ($Command -match '^\s*"([^"]+)"') {
        return $matches[1]
    }

    if ($Command -match '^\s*([^\s]+)') {
        return $matches[1]
    }

    return $null
}

function Get-DefaultBrowserInfo {
    param([string]$PreferredPath = "")

    if ($PreferredPath -and (Test-Path $PreferredPath -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            ProgId = $null
            Command = $null
            FilePath = $PreferredPath
            WorkingDirectory = Split-Path -Parent $PreferredPath
            ProcessName = [System.IO.Path]::GetFileNameWithoutExtension($PreferredPath)
        }
    }

    $progId = Get-DefaultBrowserProgId
    $command = Get-BrowserCommandForProgId -ProgId $progId
    $filePath = Resolve-ExecutablePathFromCommand -Command $command
    if (-not $filePath) {
        return $null
    }

    return [pscustomobject]@{
        ProgId = $progId
        Command = $command
        FilePath = $filePath
        WorkingDirectory = Split-Path -Parent $filePath
        ProcessName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
    }
}
