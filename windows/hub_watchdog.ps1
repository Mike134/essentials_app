# Detects the sync server (server.exe, tray-hosted) actually being dead --
# a real, confirmed incident, not a hypothetical: an unhandled exception
# inside server.exe (see CLAUDE.md "Incident: the sync server crash-looped
# for real") killed the process outright, and the tray host wrapper around
# it has no crash-monitoring of its own -- only a manual "Restart server"
# tray-menu click recovers it. This is the missing piece Mike expected to
# already exist: something that actually notices *and* self-heals, the
# same "real-time alarm bell" role background_check_watchdog.ps1 already
# plays for scheduled-script health, just for the sync server's own
# process liveness instead. The underlying applyPending()/getChangeset()
# race that caused that specific crash is now fixed at the code level
# (MigrationService.schemaLock) -- this watchdog is defense in depth for
# *any* future cause of the server dying, not a substitute for that fix.
#
# Checks two things, either one failing means "not healthy":
#   - a process named "server" is running at all
#   - port 1340 is actually accepting a TCP connection (catches a process
#     that's alive but hung before/after HttpServer.bind -- confirmed
#     this project's own crash always fully exits the process, so this is
#     belt-and-suspenders, not the primary signal)
#
# On failure: stops any orphaned tray_host.ps1 wrapper (the exact leftover
# this project has hit repeatedly this session -- the tray icon survives a
# server.exe crash with no child left to serve anything), relaunches
# cleanly via server/launch_tray_hidden.vbs, and alerts (BurntToast,
# falling back to the Application event log) either way -- a self-healing
# restart is not a substitute for Mike knowing it happened, since the
# underlying cause might not always be something this script can fix by
# restarting.
#
# Re-alerts on a cooldown basis, same shape as
# background_check_watchdog.ps1's own state file, so a still-unresolved
# problem doesn't spam a fresh toast every single run -- but does NOT
# stop attempting a restart each run, since a restart is cheap and a
# healthy server is always better than a dead one, alert or no alert.
# Gives up attempting further restarts (alerting instead) once a streak
# of them hasn't produced a lasting recovery, so a fundamentally broken
# state (e.g. a corrupted hub.db) doesn't restart-loop forever.
#
# Register with register_hub_watchdog.ps1, once, elevated.

$ErrorActionPreference = 'Stop'

$serverDir = 'C:\Flutter\essentials_app\server'
$launchVbs = Join-Path $serverDir 'launch_tray_hidden.vbs'
$stateFile = 'C:\Databases\essentials_app\.hub_watchdog_state.json'
$port = 1340
$realertCooldownHours = 4
$maxConsecutiveRestartsBeforeGivingUp = 5

function Test-HubListening {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $connectTask = $client.ConnectAsync('127.0.0.1', $port)
        $completed = $connectTask.Wait(2000)
        $ok = $completed -and $client.Connected
        $client.Close()
        return $ok
    } catch {
        return $false
    }
}

$serverProcess = Get-Process -Name 'server' -ErrorAction SilentlyContinue
$listening = if ($serverProcess) { Test-HubListening } else { $false }
$healthy = ($null -ne $serverProcess) -and $listening

$state = if (Test-Path $stateFile) {
    Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
} else {
    @{ consecutiveRestarts = 0; lastAlertedAt = $null }
}

if ($healthy) {
    if ([int]$state.consecutiveRestarts -gt 0) {
        Write-Host 'Hub is healthy again -- resetting restart streak.'
    }
    $state.consecutiveRestarts = 0
    $state | ConvertTo-Json | Set-Content $stateFile
    exit 0
}

Write-Warning "Hub not healthy (process running: $([bool]$serverProcess), listening on port $port`: $listening)."

if ([int]$state.consecutiveRestarts -ge $maxConsecutiveRestartsBeforeGivingUp) {
    Write-Warning "Already attempted $($state.consecutiveRestarts) consecutive restarts with no lasting recovery -- not attempting another. Investigate manually."
} else {
    # Stop any orphaned tray host wrapper first -- see this script's own
    # header comment for why one can be left running with no server.exe
    # child after a crash.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*tray_host.ps1*' } |
        ForEach-Object {
            Write-Host "Stopping orphaned tray host (PID $($_.ProcessId))."
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    if ($serverProcess) {
        Write-Host "Stopping unresponsive server.exe (PID $($serverProcess.Id))."
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 1
    Write-Host 'Relaunching hub...'
    $wscript = Get-Command wscript -ErrorAction SilentlyContinue
    if ($wscript) {
        Start-Process -FilePath $wscript.Source -ArgumentList "`"$launchVbs`"" -WindowStyle Hidden
    } else {
        Write-Warning 'wscript.exe not found -- cannot relaunch automatically.'
    }
    $state.consecutiveRestarts = [int]$state.consecutiveRestarts + 1
}

$now = Get-Date
$lastAlertedAt = if ($state.lastAlertedAt) { [DateTime]::Parse($state.lastAlertedAt) } else { $null }
$cooldownElapsed = -not $lastAlertedAt -or (($now - $lastAlertedAt).TotalHours -ge $realertCooldownHours)

if ($cooldownElapsed) {
    $state.lastAlertedAt = $now.ToString('o')
    $title = 'Essentials sync hub was down'
    $body = "The sync server wasn't responding and a restart was attempted (streak: $($state.consecutiveRestarts))."

    $burntToast = Get-Module -ListAvailable -Name BurntToast
    if ($burntToast) {
        Import-Module BurntToast
        New-BurntToastNotification -Text $title, $body
    } else {
        Write-Warning 'BurntToast module not installed -- no toast shown, only this console warning. Install once with: Install-Module BurntToast -Scope CurrentUser'
        try {
            if (-not [System.Diagnostics.EventLog]::SourceExists('EssentialsAppWatchdog')) {
                New-EventLog -LogName Application -Source 'EssentialsAppWatchdog'
            }
            Write-EventLog -LogName Application -Source 'EssentialsAppWatchdog' -EntryType Warning -EventId 2 -Message "$title`n$body"
        } catch {
            # Best-effort fallback only -- the console Write-Warning above
            # still works regardless of whether this notification path does.
        }
    }
}

$state | ConvertTo-Json | Set-Content $stateFile
