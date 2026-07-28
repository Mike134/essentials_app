' Launches tray_host.ps1 with zero visible window -- not even the brief
' flash "-WindowStyle Hidden" alone can leave. This is what the Startup
' folder shortcut targets. See CLAUDE.md "Syncing at the Record Level".
Set shell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptDir & "\tray_host.ps1"""
shell.Run cmd, 0, False
