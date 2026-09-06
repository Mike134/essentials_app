# Real-time alarm bell for the exact class of bug essentials_app.exe hit
# for over a week undetected (crash-looping every 15 minutes on its own
# `--background-schedule-check` scheduled task) -- see
# BackgroundProcessesScreen for this project's other half of the fix, the
# in-app historical/diagnostic view. This script is the thing that
# actually notices *while it's happening*, since nobody reliably thinks
# to open that screen on a normal day.
#
# Reads the same `device_settings` rows (`bg_check:*` keys) that
# BackgroundScheduleService.runDueScheduledEvents writes on every pass
# (lib/util/scripting/background_schedule_service.dart) -- one source of
# truth for both the in-app screen and this watchdog, so what the UI
# shows and what trips the alarm can never silently disagree.
#
# Run this on its own schedule (register with
# register_background_check_watchdog.ps1, once, elevated/current user --
# separate task from EssentialsAppBackgroundScheduleCheck so a bug in one
# can't silence the other) -- every 30 minutes is plenty; this only
# reads `essentials.db`, it never launches essentials_app.exe itself.
#
# Alarms on two independent conditions, either one being real trouble --
# but only for a device currently targeted by at least one enabled
# schedule_interval binding (see $activeScheduleDevices below). On
# Android, runDueScheduledEvents is only ever invoked by an exact alarm
# firing, and no alarm is armed for a device with nothing bound to it --
# so a device with zero active bindings will *always* look stale/frozen,
# forever, and that's correct, not a problem. Confirmed live: MIKE-12R
# went a full day "stale" this way once its one schedule_interval test
# binding was deleted, with nothing actually wrong -- see CLAUDE.md's
# "Background-check reliability session" for the investigation this
# fix grew out of.
#   - consecutive_failures >= 2 for any device (one transient failure is
#     expected/normal -- MigrationService's own "transient errors should
#     retry, not permanently fail" posture, matched here rather than
#     alarming on noise).
#   - last_attempt_at older than $staleThresholdMinutes for any device
#     that has ever recorded one -- catches the background check having
#     stopped running entirely (task disabled/removed/hung), which a
#     pure failure-count check would never see since no failure ever
#     gets recorded if nothing runs at all.
#
# Re-alerts only when a device's bad state gets worse (failure count
# rises further) or after $realertCooldownHours has passed while still
# bad -- a local state file (next to essentials.db, same convention as
# DeviceId's own `.device_id_cache`) tracks what was last alerted, so a
# known, still-unresolved problem doesn't spam a fresh toast every single
# run.

$ErrorActionPreference = 'Stop'

$dbPath = 'C:\Databases\essentials_app\essentials.db'
$stateFile = 'C:\Databases\essentials_app\.watchdog_state.json'
$staleThresholdMinutes = 45
$failureStreakThreshold = 2
$realertCooldownHours = 4

if (-not (Test-Path $dbPath)) {
    Write-Warning "essentials.db not found at $dbPath -- nothing to check."
    exit 0
}

$sqlite3 = Get-Command sqlite3 -ErrorAction SilentlyContinue
if (-not $sqlite3) {
    Write-Warning 'sqlite3.exe not found on PATH -- cannot read essentials.db. Install it (e.g. the copy that ships with the Android SDK platform-tools) and ensure it is on PATH.'
    exit 1
}

$json = (& sqlite3.exe -json $dbPath @"
SELECT device_id, setting_key, value FROM device_settings
WHERE setting_key LIKE 'bg_check:%' AND is_deleted = 0
"@) -join "`n"

# -join above matters: PowerShell captures external-process stdout as a
# string[] (one element per line), and piping that straight into
# ConvertFrom-Json runs it once per line instead of once over the whole
# JSON array -- fails immediately on any multi-row result. Confirmed live.
$rows = if ([string]::IsNullOrWhiteSpace($json)) { @() } else { $json | ConvertFrom-Json }

$byDevice = @{}
foreach ($row in $rows) {
    if (-not $byDevice.ContainsKey($row.device_id)) {
        $byDevice[$row.device_id] = @{}
    }
    $byDevice[$row.device_id][$row.setting_key] = $row.value
}

# Which devices currently have at least one enabled, non-deleted
# schedule_interval binding targeting them -- mirrors
# EventDefinitionsDao.loadActiveScheduleIntervalTargetDevices exactly
# (same query, same "target_devices" JSON-array-of-device-ids shape), so
# the in-app screen and this watchdog can never disagree about which
# devices are actually expected to be checking in.
$targetJson = (& sqlite3.exe -json $dbPath @"
SELECT target_devices FROM event_definitions
WHERE is_deleted = 0 AND table_name IS NULL
  AND event_type = 'schedule_interval' AND enabled = 1
"@) -join "`n"
$targetRows = if ([string]::IsNullOrWhiteSpace($targetJson)) { @() } else { $targetJson | ConvertFrom-Json }
$activeScheduleDevices = [System.Collections.Generic.HashSet[string]]::new()
foreach ($row in $targetRows) {
    if ([string]::IsNullOrWhiteSpace($row.target_devices)) { continue }
    try {
        foreach ($deviceId in ($row.target_devices | ConvertFrom-Json)) {
            [void]$activeScheduleDevices.Add($deviceId)
        }
    } catch {
        # Malformed target_devices JSON -- treat as "targets nothing",
        # same lenient fallback EventDefinitionsDao._parseTargetDevices
        # uses on the Dart side.
    }
}

$state = if (Test-Path $stateFile) {
    Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
} else {
    @{}
}

$now = Get-Date
$problems = @()

foreach ($deviceId in $byDevice.Keys) {
    # A device with nothing currently scheduled can't be stale or
    # failing -- see this script's own header comment. Whatever
    # last_result/consecutive_failures still say is leftover from before
    # its last binding was removed, not a live problem.
    if (-not $activeScheduleDevices.Contains($deviceId)) { continue }

    $status = $byDevice[$deviceId]
    $failures = [int]($status['bg_check:consecutive_failures'] ?? '0')
    $lastAttemptText = $status['bg_check:last_attempt_at']
    $lastAttempt = if ($lastAttemptText) { [DateTime]::Parse($lastAttemptText).ToUniversalTime() } else { $null }
    $staleMinutes = if ($lastAttempt) { ($now.ToUniversalTime() - $lastAttempt).TotalMinutes } else { $null }

    $isFailing = $failures -ge $failureStreakThreshold
    $isStale = $lastAttempt -and ($staleMinutes -gt $staleThresholdMinutes)
    if (-not ($isFailing -or $isStale)) { continue }

    $priorAlert = $state[$deviceId]
    $priorFailures = if ($priorAlert) { [int]$priorAlert.failures } else { 0 }
    $priorAlertedAt = if ($priorAlert -and $priorAlert.alertedAt) { [DateTime]::Parse($priorAlert.alertedAt) } else { $null }
    $cooldownElapsed = -not $priorAlertedAt -or (($now - $priorAlertedAt).TotalHours -ge $realertCooldownHours)
    $gotWorse = $failures -gt $priorFailures

    if (-not ($gotWorse -or $cooldownElapsed)) { continue }

    $reason = if ($isStale) {
        "hasn't run in {0:N0} minutes (last attempt: $lastAttemptText)" -f $staleMinutes
    } else {
        "$failures consecutive failures (last: $($status['bg_check:last_error']))"
    }
    $problems += [PSCustomObject]@{ DeviceId = $deviceId; Reason = $reason }
    $state[$deviceId] = @{ failures = $failures; alertedAt = $now.ToString('o') }
}

# Clear alert-state for any device no longer in trouble, so a real
# recovery doesn't leave a stale cooldown blocking a genuinely new
# problem's first alert.
foreach ($deviceId in @($state.Keys)) {
    if (-not $activeScheduleDevices.Contains($deviceId)) {
        # No longer targeted by anything -- can't still be "in trouble"
        # by definition, regardless of what its frozen bg_check values say.
        $state.Remove($deviceId)
        continue
    }
    $status = $byDevice[$deviceId]
    if (-not $status) { continue }
    $failures = [int]($status['bg_check:consecutive_failures'] ?? '0')
    $lastAttemptText = $status['bg_check:last_attempt_at']
    $lastAttempt = if ($lastAttemptText) { [DateTime]::Parse($lastAttemptText).ToUniversalTime() } else { $null }
    $staleMinutes = if ($lastAttempt) { ($now.ToUniversalTime() - $lastAttempt).TotalMinutes } else { $null }
    if ($failures -lt $failureStreakThreshold -and -not ($lastAttempt -and $staleMinutes -gt $staleThresholdMinutes)) {
        $state.Remove($deviceId)
    }
}

$state | ConvertTo-Json | Set-Content $stateFile

if ($problems.Count -eq 0) {
    exit 0
}

$title = if ($problems.Count -eq 1) { 'Essentials background check problem' } else { 'Essentials background check problems' }
$body = ($problems | ForEach-Object { "$($_.DeviceId): $($_.Reason)" }) -join "`n"

Write-Warning "$title -- $body"

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
        Write-EventLog -LogName Application -Source 'EssentialsAppWatchdog' -EntryType Warning -EventId 1 -Message "$title`n$body"
    } catch {
        # Best-effort fallback only -- the console Write-Warning above and
        # BackgroundProcessesScreen (which reads the same underlying data)
        # both still work regardless of whether this notification path does.
    }
}
