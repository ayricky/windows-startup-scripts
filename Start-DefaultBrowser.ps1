param(
    [string]$BrowserPath = ""
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "RunLogger.ps1")
. (Join-Path $scriptRoot "BrowserSupport.ps1")

$logger = New-RunLogger -ScriptName "Start-DefaultBrowser" -ScriptRoot $scriptRoot -Parameters @{
    BrowserPath = $BrowserPath
}

try {
    Add-RunEvent -Logger $logger -Message "Run started." -Type "start"

    $browserInfo = Get-DefaultBrowserInfo -PreferredPath $BrowserPath
    if (-not $browserInfo) {
        throw "Default browser could not be resolved."
    }

    Start-Process -FilePath $browserInfo.FilePath -WorkingDirectory $browserInfo.WorkingDirectory | Out-Null
    Complete-RunLogger -Logger $logger -Status "success" -Summary @{
        ProcessName = $browserInfo.ProcessName
        FilePath = $browserInfo.FilePath
        ProgId = $browserInfo.ProgId
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
