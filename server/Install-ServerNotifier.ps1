param(
    [string]$TaskName = 'RdpUsageServerNotifier'
)

$ErrorActionPreference = 'Stop'

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$launcherPath = Join-Path $PSScriptRoot 'Run-ServerNotifierHidden.vbs'
$argument = "`"$launcherPath`""

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $argument
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Shows RDP reservation notifications on the server desktop.' `
    -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName

Write-Host "RDP reservation notifier installed for $user."
Write-Host "Task name: $TaskName"
