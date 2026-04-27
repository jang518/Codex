param(
    [string]$TaskName = 'RdpUsageClient'
)

$ErrorActionPreference = 'Stop'

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$launcherPath = Join-Path $PSScriptRoot 'Run-ClientHidden.vbs'
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
    -Description 'Starts the RDP usage tray app for the current user.' `
    -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName

Write-Host "RDP usage client startup installed for $user."
Write-Host "Task name: $TaskName"
