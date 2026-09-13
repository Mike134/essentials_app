# One-time (per machine) registration for hub_watchdog.ps1 -- run
# manually, once, from an ELEVATED PowerShell prompt:
#
#   powershell -ExecutionPolicy Bypass -File windows\register_hub_watchdog.ps1
#
# Elevation matters for the same reason as register_background_check_
# watchdog.ps1: registering a *new* Windows Event Log source requires
# admin rights, one-time, so the watchdog's own unattended, non-elevated
# Task Scheduler runs can use that fallback successfully later. Reuses
# the same 'EssentialsAppWatchdog' event source the other watchdog
# already registers -- one generic "something's wrong with essentials_app"
# channel, not a second one to remember.
#
# Also installs the BurntToast module (CurrentUser scope, via pwsh.exe
# specifically) if missing -- same reasoning and same real gotcha already
# documented in register_background_check_watchdog.ps1 (installing from
# whatever shell is running this script can land it in Windows PowerShell
# 5.1's own module path, which pwsh.exe -- what the scheduled task always
# launches -- never looks in).
#
# Runs every 5 minutes -- tighter than the 30-minute schedule-health
# watchdog, deliberately: the sync hub being down is far more impactful
# (nothing syncs at all, for every device, the whole time) than one
# scheduled script being late, so it's worth checking more often. A
# separate task from both EssentialsAppBackgroundScheduleCheck and
# EssentialsAppBackgroundCheckWatchdog on purpose -- a bug in any one of
# the three should never be able to silence either of the others.

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

$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwsh) {
    Write-Error 'pwsh.exe (PowerShell 7+) not found -- hub_watchdog.ps1 uses syntax (-AsHashtable) that needs it, not Windows PowerShell 5.1.'
    exit 1
}

$hasBurntToast = & $pwsh.Source -NoProfile -Command "if (Get-Module -ListAvailable -Name BurntToast) { 'yes' } else { 'no' }"
if ($hasBurntToast -eq 'yes') {
    Write-Host 'BurntToast module already installed (for pwsh.exe).'
} else {
    & $pwsh.Source -NoProfile -Command "Install-Module BurntToast -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop"
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'Installed BurntToast module for pwsh.exe -- real toast notifications are now live.'
    } else {
        Write-Warning "Could not install BurntToast automatically. Real toasts won't show until it's installed -- retry later with:"
        Write-Warning '  pwsh -Command "Install-Module BurntToast -Scope CurrentUser"'
        Write-Warning 'Until then, the watchdog still logs to the Application event log and console -- just not a toast.'
    }
}

$scriptPath = Join-Path $PSScriptRoot 'hub_watchdog.ps1'
$scriptPath = [System.IO.Path]::GetFullPath($scriptPath)

$taskName = 'EssentialsAppHubWatchdog'

$vbsPath = Join-Path $PSScriptRoot 'launch_hub_watchdog_hidden.vbs'
$vbsPath = [System.IO.Path]::GetFullPath($vbsPath)
$wscript = Get-Command wscript -ErrorAction SilentlyContinue
if (-not $wscript) {
    Write-Error 'wscript.exe (Windows Script Host) not found -- required to launch the watchdog with a fully hidden window.'
    exit 1
}

$action = New-ScheduledTaskAction -Execute $wscript.Source -Argument "`"$vbsPath`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days (365 * 20))
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description 'Essentials app: detects the sync hub (server.exe) being down, restarts it, and alerts.' -Force | Out-Null

Write-Host "Registered scheduled task '$taskName', running every 5 minutes, targeting:"
Write-Host "  $scriptPath"
Write-Host 'Re-run this script (still elevated) if the watchdog script ever moves.'
