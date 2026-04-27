Option Explicit

Dim shell
Dim fso
Dim scriptDir
Dim scriptPath
Dim command

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(scriptDir, "RdpUsageServerNotifier.ps1")

command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File " & Chr(34) & scriptPath & Chr(34)
shell.Run command, 0, False
