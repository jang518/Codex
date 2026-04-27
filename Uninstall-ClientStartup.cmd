@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0client\Uninstall-ClientStartup.ps1" %*
