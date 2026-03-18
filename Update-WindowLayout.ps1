param(
    [switch]$ApplyAfterSave
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$saveScript = Join-Path $scriptRoot "Save-WindowLayout.ps1"
$applyScript = Join-Path $scriptRoot "Apply-WindowLayout.ps1"
$configPath = Join-Path $scriptRoot "window-layout.json"
. (Join-Path $scriptRoot "RunLogger.ps1")

$logger = New-RunLogger -ScriptName "Update-WindowLayout" -ScriptRoot $scriptRoot -Parameters @{
    ApplyAfterSave = [bool]$ApplyAfterSave
}

try {
    Add-RunEvent -Logger $logger -Message "Run started." -Type "start"

    if (-not (Test-Path $saveScript)) {
        throw "Save script not found at $saveScript"
    }

    Add-RunEvent -Logger $logger -Message "Running save script." -Type "step" -Data @{
        ScriptPath = $saveScript
    }
    & $saveScript -ConfigPath $configPath

    if ($LASTEXITCODE -ne 0) {
        throw "Save script exited with code $LASTEXITCODE."
    }

    if ($ApplyAfterSave) {
        Add-RunEvent -Logger $logger -Message "Running apply script." -Type "step" -Data @{
            ScriptPath = $applyScript
        }
        & $applyScript -ConfigPath $configPath -StartupDelaySeconds 0 -WaitForExistingWindowSeconds 5 -PollIntervalSeconds 1 -PostLaunchWindowWaitSeconds 5

        if ($LASTEXITCODE -ne 0) {
            throw "Apply script exited with code $LASTEXITCODE."
        }
    }

    Complete-RunLogger -Logger $logger -Status "success" -Summary @{
        ConfigPath = $configPath
        ApplyAfterSave = [bool]$ApplyAfterSave
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
