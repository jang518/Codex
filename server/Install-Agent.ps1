param(
    [int]$Port = 8765,
    [string]$TaskName = 'RdpUsageAgent',
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'agent-config.json')
)

$ErrorActionPreference = 'Stop'

function New-AgentToken {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$dataPath = 'data\agent-store.json'

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $config = [pscustomobject]@{
        Port     = $Port
        Token    = New-AgentToken
        DataPath = $dataPath
    }
    $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}
else {
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

$ruleName = "RDP Usage Agent $Port"
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $Port `
        -Profile Domain,Private | Out-Null
}

$agentPath = Join-Path $PSScriptRoot 'RdpUsageAgent.ps1'
$argument = "-NoProfile -ExecutionPolicy Bypass -File `"$agentPath`" -ConfigPath `"$ConfigPath`""
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'RDP usage status and reservation API agent.' `
    -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName

Write-Host ""
Write-Host "RDP Usage Agent installed."
Write-Host "Server URL: http://$env:COMPUTERNAME`:$Port"
Write-Host "Token: $($config.Token)"
Write-Host "Config: $ConfigPath"
