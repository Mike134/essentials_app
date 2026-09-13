' Launches hub_watchdog.ps1 with zero visible window -- same technique as
' server/launch_tray_hidden.vbs and launch_watchdog_hidden.vbs. pwsh.exe
' specifically (PowerShell 7+), not Windows PowerShell 5.1 -- this script
' uses -AsHashtable (ConvertFrom-Json), same requirement as
' background_check_watchdog.ps1.
Set shell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
cmd = "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptDir & "\hub_watchdog.ps1"""
shell.Run cmd, 0, False
