@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Stop-ScheduledTask -TaskName 'RdpUsageAgent' -ErrorAction SilentlyContinue; Start-ScheduledTask -TaskName 'RdpUsageAgent'"
