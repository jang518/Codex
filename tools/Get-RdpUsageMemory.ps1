param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [switch]$IncludeCommandLineFallback
)

$ErrorActionPreference = 'Stop'

function ConvertTo-Megabytes {
    param([long]$Bytes)
    return [Math]::Round($Bytes / 1MB, 1)
}

function Get-PidFileProcess {
    param(
        [string]$Role,
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Role         = $Role
            PID          = $null
            ProcessName  = ''
            WorkingSetMB = 0
            PrivateMB    = 0
            StartTime    = $null
            Status       = 'PID file not found'
            PidFile      = $Path
        }
    }

    $pidValue = (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Select-Object -First 1)
    $process = $null
    if ($pidValue -match '^\d+$') {
        $process = Get-Process -Id ([int]$pidValue) -ErrorAction SilentlyContinue
    }

    if ($null -eq $process) {
        return [pscustomobject]@{
            Role         = $Role
            PID          = $pidValue
            ProcessName  = ''
            WorkingSetMB = 0
            PrivateMB    = 0
            StartTime    = $null
            Status       = 'Process not running'
            PidFile      = $Path
        }
    }

    return [pscustomobject]@{
        Role         = $Role
        PID          = $process.Id
        ProcessName  = $process.ProcessName
        WorkingSetMB = ConvertTo-Megabytes $process.WorkingSet64
        PrivateMB    = ConvertTo-Megabytes $process.PrivateMemorySize64
        StartTime    = $process.StartTime
        Status       = 'Running'
        PidFile      = $Path
    }
}

$rows = @()
$rows += Get-PidFileProcess -Role 'Server Agent' -Path (Join-Path $Root 'server\data\agent.pid')
$rows += Get-PidFileProcess -Role 'Client Tray' -Path (Join-Path $env:APPDATA 'RdpUsageTool\client.pid')
$rows += Get-PidFileProcess -Role 'Server Notifier' -Path (Join-Path $env:APPDATA 'RdpUsageTool\server-notifier.pid')

if ($IncludeCommandLineFallback) {
    try {
        $processes = Get-CimInstance Win32_Process -Filter "name = 'powershell.exe' or name = 'wscript.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -like '*RdpUsage*' -or $_.CommandLine -like '*RdpUsageTool*' }

        foreach ($processInfo in $processes) {
            if ($rows.PID -contains $processInfo.ProcessId) {
                continue
            }

            $process = Get-Process -Id $processInfo.ProcessId -ErrorAction SilentlyContinue
            if ($process) {
                $rows += [pscustomobject]@{
                    Role         = 'CommandLine Match'
                    PID          = $process.Id
                    ProcessName  = $process.ProcessName
                    WorkingSetMB = ConvertTo-Megabytes $process.WorkingSet64
                    PrivateMB    = ConvertTo-Megabytes $process.PrivateMemorySize64
                    StartTime    = $process.StartTime
                    Status       = 'Running'
                    PidFile      = ''
                }
            }
        }
    }
    catch {
        Write-Warning "Command-line process fallback was skipped: $($_.Exception.Message)"
    }
}

$runningRows = @($rows | Where-Object { $_.Status -eq 'Running' })
$total = [pscustomobject]@{
    Role         = 'TOTAL'
    PID          = ''
    ProcessName  = ''
    WorkingSetMB = [Math]::Round((($runningRows | Measure-Object -Property WorkingSetMB -Sum).Sum), 1)
    PrivateMB    = [Math]::Round((($runningRows | Measure-Object -Property PrivateMB -Sum).Sum), 1)
    StartTime    = $null
    Status       = "$($runningRows.Count) running process(es)"
    PidFile      = ''
}

$rows + $total | Format-Table Role, PID, ProcessName, WorkingSetMB, PrivateMB, Status -AutoSize
