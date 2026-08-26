# Essentials v2 Phase 5 build order step 8 -- one-time (per machine)
# registration of the Windows Scheduled Task that fires hourly/daily/
# weekly scripts in the background, the Windows equivalent of Android's
# workmanager periodic task (see background_schedule_service.dart's own
# doc comment). Run manually, once, from an elevated PowerShell prompt:
#
#   powershell -ExecutionPolicy Bypass -File windows\register_background_schedule_task.ps1
#
# Re-running is safe -- Register-ScheduledTask below replaces any
# existing task of the same name rather than erroring or duplicating it,
# same "idempotent to call again" property registerBackgroundScheduleTask
# has on the Android side.
#
# Every 15 minutes, indefinitely, matching Android's own WorkManager
# floor -- picked for consistency between platforms, not because Windows
# itself imposes the same limit. Launches the real, already-built exe
# with the one flag main.dart checks for (see
# windows_background_entrypoint.dart) -- the exe hides its own window
# immediately (windows/runner/main.cpp) and exits itself when done
# (windows_background_entrypoint.dart's exit(0)), so nothing here needs
# to manage the process's lifetime beyond letting Task Scheduler launch
# and wait for it.

$ErrorActionPreference = 'Stop'

$exePath = Join-Path $PSScriptRoot '..\build\windows\x64\runner\Release\essentials_app.exe'
$exePath = [System.IO.Path]::GetFullPath($exePath)

if (-not (Test-Path $exePath)) {
    Write-Error "No exe at $exePath -- run 'flutter build windows' first."
    exit 1
}

$taskName = 'EssentialsAppBackgroundScheduleCheck'

$action = New-ScheduledTaskAction -Execute $exePath -Argument '--background-schedule-check'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration ([TimeSpan]::MaxValue)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description 'Essentials app: runs due hourly/daily/weekly scheduled scripts in the background.' -Force | Out-Null

Write-Host "Registered scheduled task '$taskName', running every 15 minutes, targeting:"
Write-Host "  $exePath"
Write-Host 'Note: this points at the exe currently at that path. Re-run this script after any'
Write-Host 'future `flutter build windows` if the task ever seems to stop picking up new builds --'
Write-Host 'it always launches whatever is physically at that path, not a snapshot taken at registration.'
