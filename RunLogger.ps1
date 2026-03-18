function Get-RunHistory {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return @()
    }

    $raw = Get-Content -Path $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    if ($parsed -is [System.Collections.IEnumerable] -and $parsed -isnot [string]) {
        return @($parsed)
    }

    return @($parsed)
}

function Save-RunHistory {
    param(
        [string]$Path,
        [object[]]$Runs,
        [int]$MaxRuns = 100
    )

    $trimmedRuns = @($Runs | Select-Object -Last $MaxRuns)
    $trimmedRuns | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding ASCII
}

function New-RunLogger {
    param(
        [string]$ScriptName,
        [string]$ScriptRoot,
        [hashtable]$Parameters = @{},
        [int]$MaxRuns = 100
    )

    $logDir = Join-Path $ScriptRoot "logs"
    $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue

    $startedAt = [DateTimeOffset]::Now
    $historyPath = Join-Path $logDir "$ScriptName.runs.json"

    return @{
        ScriptName = $ScriptName
        HistoryPath = $historyPath
        MaxRuns = $MaxRuns
        StartedAt = $startedAt
        Run = [ordered]@{
            RunId = [guid]::NewGuid().Guid
            ScriptName = $ScriptName
            StartedAt = $startedAt.ToString("o")
            Status = "running"
            Parameters = [pscustomobject]$Parameters
            Events = @()
        }
    }
}

function Add-RunEvent {
    param(
        [hashtable]$Logger,
        [string]$Message,
        [string]$Type = "info",
        [object]$Data = $null
    )

    $now = [DateTimeOffset]::Now
    $Logger.Run.Events += [pscustomobject]@{
        At = $now.ToString("o")
        OffsetSeconds = [math]::Round(($now - $Logger.StartedAt).TotalSeconds, 2)
        Type = $Type
        Message = $Message
        Data = $Data
    }
}

function Complete-RunLogger {
    param(
        [hashtable]$Logger,
        [ValidateSet("success", "failed", "skipped")]
        [string]$Status,
        [object]$Summary = $null
    )

    $endedAt = [DateTimeOffset]::Now
    $Logger.Run.Status = $Status
    $Logger.Run.EndedAt = $endedAt.ToString("o")
    $Logger.Run.DurationSeconds = [math]::Round(($endedAt - $Logger.StartedAt).TotalSeconds, 2)
    $Logger.Run.Summary = $Summary

    $existingRuns = Get-RunHistory -Path $Logger.HistoryPath
    $updatedRuns = @($existingRuns) + [pscustomobject]$Logger.Run
    Save-RunHistory -Path $Logger.HistoryPath -Runs $updatedRuns -MaxRuns $Logger.MaxRuns
}
