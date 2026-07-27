essentials_app's own `crdt_sync` coordinator -- the record-level sync hub
for MIKE-CU. Not a general-purpose service; see
`C:\Users\Mike\OneDrive\Documents\Essentials\CLAUDE.md` ("Syncing at the
Record Level") for the full design, findings, and operational history.

## Running it

Auto-starts on login via a minimized shortcut in the Startup folder
(`shell:startup`) -- nothing to do day-to-day. To run it manually instead
(e.g. while iterating on `bin/server.dart`):

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

Only needed if it's ever deleted or the exe moves. Per-user, no admin
rights needed:

```powershell
$WshShell = New-Object -ComObject WScript.Shell
$shortcut = $WshShell.CreateShortcut("$([Environment]::GetFolderPath('Startup'))\essentials_app sync server.lnk")
$shortcut.TargetPath = "C:\Flutter\essentials_app\server\build\cli\windows_x64\bundle\bin\server.exe"
$shortcut.WorkingDirectory = "C:\Flutter\essentials_app\server\build\cli\windows_x64\bundle\bin"
$shortcut.WindowStyle = 7  # minimized
$shortcut.Save()
```
