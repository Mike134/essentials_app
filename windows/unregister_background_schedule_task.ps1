# Removes the scheduled task registered by register_background_schedule_task.ps1.
# Run from an elevated PowerShell prompt:
#   powershell -ExecutionPolicy Bypass -File windows\unregister_background_schedule_task.ps1

$taskName = 'EssentialsAppBackgroundScheduleCheck'
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "Removed scheduled task '$taskName' (if it existed)."
