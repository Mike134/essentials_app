essentials_app's own `crdt_sync` coordinator -- the record-level sync hub
for MIKE-CU. Not a general-purpose service; see `../CLAUDE.md` ("Syncing at
the Record Level") for the full design, findings, and operational history.

## Running it

Auto-starts on login via a Startup-folder shortcut (`shell:startup`) that
launches `launch_tray_hidden.vbs`, which in turn runs `tray_host.ps1`
invisibly -- `tray_host.ps1` starts `server.exe` as a hidden child process
(stdout/stderr redirected to `server.log`/`server.err.log`) and shows a
system tray icon for it instead of a taskbar window. Right-click the tray
icon for "View log", "Restart server", and "Exit" (which also stops the
server); double-click it to view the log. Nothing to do day-to-day.

`tray_host.ps1` and `server.exe` are separate processes on purpose: if the
tray host ever crashes, the sync server itself -- a genuine child process,
not something dependent on the tray host staying alive -- keeps running.

To run the server manually instead (e.g. while iterating on
`bin/server.dart`), bypassing the tray host entirely:

```
dart run bin/server.dart
```

## Rebuilding after a code change

The Startup-folder shortcut points at a compiled executable, not
`bin/server.dart` directly, so a code change needs a rebuild before it
takes effect on next login:

```
dart build cli
```

Produces `build\cli\windows_x64\bundle\bin\server.exe` (plus
`..\lib\sqlite3.dll`, which must stay alongside it) -- this is the exact
path the Startup-folder shortcut targets, so nothing else needs updating
after a rebuild. `dart compile exe` does **not** work here -- `sqlite3`
uses build hooks that only `dart build` supports.

## Recreating the auto-start shortcut

Only needed if it's ever deleted or the repo moves. Points at the VBScript
launcher, not at `server.exe` directly -- the rebuild step above doesn't
change this path, so a rebuild alone never needs this rerun. Per-user, no
admin rights needed:

```powershell
$WshShell = New-Object -ComObject WScript.Shell
$shortcut = $WshShell.CreateShortcut("$([Environment]::GetFolderPath('Startup'))\essentials_app sync server.lnk")
$shortcut.TargetPath = "C:\Windows\System32\wscript.exe"
$shortcut.Arguments = '"C:\Flutter\essentials_app\server\launch_tray_hidden.vbs"'
$shortcut.WorkingDirectory = "C:\Flutter\essentials_app\server"
$shortcut.WindowStyle = 1
$shortcut.Save()
```
