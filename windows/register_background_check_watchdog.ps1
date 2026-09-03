# One-time (per machine) registration for background_check_watchdog.ps1
# -- run manually, once, from an ELEVATED PowerShell prompt:
#
#   powershell -ExecutionPolicy Bypass -File windows\register_background_check_watchdog.ps1
#
# Elevation matters here specifically (unlike register_background_schedule_
# task.ps1): registering a *new* Windows Event Log source requires admin
# rights, one-time, but *writing* to an already-registered source later
# does not -- so doing it here, once, lets the watchdog's own unattended,
# non-elevated Task Scheduler runs use that fallback successfully.
# Confirmed live: without this, New-EventLog inside the watchdog silently
# fails every run (caught by its own best-effort try/catch) since Task
# Scheduler runs it non-elevated.
#
# Also installs the BurntToast module (CurrentUser scope) if missing --
# that's what actually shows a real Windows toast; the Event Log entry is
# just a backup trail for exactly the case a toast doesn't show for some
# reason, not the primary way this is meant to reach Mike. Skipped
# (with guidance printed) if PSGallery isn't reachable right now -- worth
# retrying later with `Install-Module BurntToast -Scope CurrentUser`
# rather than blocking the rest of this registration on it.
#
# Runs every 30 minutes -- doesn't need to match
# EssentialsAppBackgroundScheduleCheck's own 15-minute cadence, only to
# be frequent enough that a real problem doesn't sit unnoticed for long;
# this only reads essentials.db, it never launches essentials_app.exe.
# A separate task from EssentialsAppBackgroundScheduleCheck on purpose --
# a bug in one should never be able to silence the other.

$ErrorActionPreference = 'Stop'

$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated) {
    Write-Error 'Run this from an elevated (Run as Administrator) PowerShell prompt -- registering the Event Log source requires it.'
    exit 1
}

$eventSource = 'EssentialsAppWatchdog'
if (-not [System.Diagnostics.EventLog]::SourceExists($eventSource)) {
    New-EventLog -LogName Application -Source $eventSource
    Write-Host "Registered Event Log source '$eventSource'."
} else {
    Write-Host "Event Log source '$eventSource' already registered."
}

if (Get-Module -ListAvailable -Name BurntToast) {
    Write-Host 'BurntToast module already installed.'
} else {
    try {
        Install-Module BurntToast -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Write-Host 'Installed BurntToast module -- real toast notifications are now live.'
    } catch {
        Write-Warning "Could not install BurntToast automatically ($($_.Exception.Message)). Real toasts won't show until it's installed -- retry later with:"
        Write-Warning '  Install-Module BurntToast -Scope CurrentUser'
        Write-Warning 'Until then, the watchdog still logs to the Application event log and console -- just not a toast.'
    }
}

$scriptPath = Join-Path $PSScriptRoot 'background_check_watchdog.ps1'
$scriptPath = [System.IO.Path]::GetFullPath($scriptPath)

$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwsh) {
    Write-Error 'pwsh.exe (PowerShell 7+) not found -- background_check_watchdog.ps1 uses syntax (??, ConvertFrom-Json -AsHashtable) that needs it, not Windows PowerShell 5.1.'
    exit 1
}

$taskName = 'EssentialsAppBackgroundCheckWatchdog'

$action = New-ScheduledTaskAction -Execute $pwsh.Source -Argument "-NoProfile -File `"$scriptPath`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration (New-TimeSpan -Days (365 * 20))
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description 'Essentials app: alerts if the background schedule check is failing or has stopped running.' -Force | Out-Null

Write-Host "Registered scheduled task '$taskName', running every 30 minutes, targeting:"
Write-Host "  $scriptPath"
Write-Host 'Re-run this script (still elevated) if the watchdog script ever moves.'
