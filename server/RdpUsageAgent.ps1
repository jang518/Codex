param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'agent-config.json'),
    [int]$Port = 0,
    [string]$Prefix = '',
    [string]$Token = '',
    [string]$DataPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'RdpUsage.Common.psm1') -Force

function Resolve-AgentConfig {
    $defaultDataPath = Join-Path $PSScriptRoot 'data\agent-store.json'
    $config = [ordered]@{
        Port     = 8765
        Prefix   = 'http://+:8765/'
        Token    = $env:RDP_USAGE_TOKEN
        DataPath = $defaultDataPath
    }

    if (Test-Path -LiteralPath $ConfigPath) {
        $fileConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in 'Port', 'Prefix', 'Token', 'DataPath') {
            if ((Get-Member -InputObject $fileConfig -Name $name -MemberType NoteProperty) -and $fileConfig.$name) {
                $config[$name] = [string]$fileConfig.$name
            }
        }
    }

    if ($Port -gt 0) { $config['Port'] = $Port }
    if (-not [string]::IsNullOrWhiteSpace($Prefix)) { $config['Prefix'] = $Prefix }
    if (-not [string]::IsNullOrWhiteSpace($Token)) { $config['Token'] = $Token }
    if (-not [string]::IsNullOrWhiteSpace($DataPath)) { $config['DataPath'] = $DataPath }

    if ([string]::IsNullOrWhiteSpace([string]$config['Prefix'])) {
        $config['Prefix'] = "http://+:$($config['Port'])/"
    }

    if ([string]::IsNullOrWhiteSpace([string]$config['Token'])) {
        throw "No API token configured. Set RDP_USAGE_TOKEN or create server\agent-config.json."
    }

    if (-not [IO.Path]::IsPathRooted([string]$config['DataPath'])) {
        $config['DataPath'] = Join-Path $PSScriptRoot ([string]$config['DataPath'])
    }

    return [pscustomobject]$config
}

function Write-AgentPidFile {
    param([string]$DataPath)
    try {
        $directory = Split-Path -Parent $DataPath
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $directory 'agent.pid') -Value $PID -Encoding ASCII
    }
    catch {}
}

function Remove-AgentPidFile {
    param([string]$DataPath)
    try {
        $directory = Split-Path -Parent $DataPath
        $path = Join-Path $directory 'agent.pid'
        if (Test-Path -LiteralPath $path) {
            $value = (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ([string]$value -eq [string]$PID) {
                Remove-Item -LiteralPath $path -Force
            }
        }
    }
    catch {}
}

$config = Resolve-AgentConfig
Initialize-RdpUsageStore -Path $config.DataPath
Write-AgentPidFile -DataPath $config.DataPath

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, [int]$config.Port)

try {
    $listener.Start()
    Write-Host "RDP Usage Agent listening on port $($config.Port)"
    Write-Host "Data path: $($config.DataPath)"
    while ($true) { Start-Sleep -Seconds 1 }
}
finally {
    $listener.Stop()
    Remove-AgentPidFile -DataPath $config.DataPath
}
