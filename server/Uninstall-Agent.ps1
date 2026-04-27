param(
    [int]$Port = 8765,
    [string]$TaskName = 'RdpUsageAgent'
)

$ErrorActionPreference = 'Continue'

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$ruleName = "RDP Usage Agent $Port"
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule

Write-Host "RDP Usage Agent startup task and firewall rule were removed."
