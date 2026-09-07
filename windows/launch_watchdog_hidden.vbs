' Launches background_check_watchdog.ps1 with zero visible window -- not
' even the brief flash "-WindowStyle Hidden" alone can leave when launched
' directly by Task Scheduler. Same technique as server/launch_tray_hidden.vbs.
' See CLAUDE.md "Every once in a while there is a black PowerShell..." for
' why this exists -- the watchdog task used to launch pwsh.exe directly.
Set shell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
cmd = "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptDir & "\background_check_watchdog.ps1"""
shell.Run cmd, 0, False
