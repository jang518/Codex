param(
    [string]$TaskName = 'RdpUsageServerNotifier'
)

$ErrorActionPreference = 'Continue'

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Write-Host "RDP reservation notifier task was removed."
