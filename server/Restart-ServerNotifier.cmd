@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Stop-ScheduledTask -TaskName 'RdpUsageServerNotifier' -ErrorAction SilentlyContinue; Start-ScheduledTask -TaskName 'RdpUsageServerNotifier'"
