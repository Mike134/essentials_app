import 'dart:async';

import 'package:flutter/material.dart';

import '../db/database_helper.dart';
import '../db/event_definitions_dao.dart';
import '../db/sync_service.dart';
import '../util/scripting/background_schedule_service.dart';

/// Shows every device's own recent `runDueScheduledEvents` pass --
/// [BackgroundScheduleService.statusLastAttemptKey] and its siblings,
/// written into `device_settings` (keyed `bg_check:*`) on every
/// Android `workmanager`/Windows scheduled-task run. Reads across *all*
/// device_ids, not just this one -- `device_settings` syncs like
/// everything else, so MIKE-CU can see MIKE-12R's background-check
/// health here too, not only its own.
///
/// This is the historical/diagnostic view: "has this been running, and
/// did it error." It does not, on its own, notify anyone of a live
/// problem -- that's `windows/background_check_watchdog.ps1`'s job (a
/// separate, real-time toast-on-failure alarm reading these same keys),
/// since this screen only ever gets looked at when someone thinks to
/// open it. Built after `essentials_app.exe` crash-looped every 15
/// minutes for over a week, undetected, until an unrelated investigation
/// stumbled onto it -- see this session's own history for the incident.
class BackgroundProcessesScreen extends StatefulWidget {
  const BackgroundProcessesScreen({super.key});

  @override
  State<BackgroundProcessesScreen> createState() => _BackgroundProcessesScreenState();
}

class _DeviceStatus {
  _DeviceStatus(this.deviceId);

  final String deviceId;
  String? lastAttemptAt;
  String? lastResult;
  String? lastError;
  String? lastSuccessAt;
  int consecutiveFailures = 0;
  int? lastAppliedCount;

  /// Whether at least one enabled `schedule_interval` binding currently
  /// targets this device -- see [EventDefinitionsDao
  /// .loadActiveScheduleIntervalTargetDevices]'s own doc comment for why
  /// this matters: without it, "hasn't run in a long time" reads as a
  /// failure even when it's just this device having nothing scheduled.
  bool hasActiveSchedule = false;
}

class _BackgroundProcessesScreenState extends State<BackgroundProcessesScreen> {
  List<_DeviceStatus> _statuses = const [];
  bool _loading = true;

  StreamSubscription<Set<String>>? _dataChangeSubscription;
  Timer? _dataChangeDebounce;

  static const _keyPrefix = 'bg_check:';

  @override
  void initState() {
    super.initState();
    _reload();
    _dataChangeSubscription = SyncService.dataChanges.listen(_onDataChanged);
  }

  void _onDataChanged(Set<String> tables) {
    if (!tables.contains('device_settings')) return;
    _dataChangeDebounce?.cancel();
    _dataChangeDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _reload();
    });
  }

  @override
  void dispose() {
    _dataChangeSubscription?.cancel();
    _dataChangeDebounce?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final crdt = await DatabaseHelper.instance.crdt;
    final rows = await crdt.query(
      "SELECT device_id, setting_key, value FROM device_settings "
      "WHERE setting_key LIKE ?1 AND is_deleted = 0",
      ['$_keyPrefix%'],
    );
    final activeScheduleDevices = await EventDefinitionsDao()
        .loadActiveScheduleIntervalTargetDevices();

    final byDevice = <String, _DeviceStatus>{};
    for (final row in rows) {
      final deviceId = row['device_id'] as String;
      final status = byDevice.putIfAbsent(deviceId, () => _DeviceStatus(deviceId));
      final key = row['setting_key'] as String;
      final value = row['value'] as String?;
      switch (key) {
        case BackgroundScheduleService.statusLastAttemptKey:
          status.lastAttemptAt = value;
        case BackgroundScheduleService.statusLastResultKey:
          status.lastResult = value;
        case BackgroundScheduleService.statusLastErrorKey:
          status.lastError = value;
        case BackgroundScheduleService.statusLastSuccessAtKey:
          status.lastSuccessAt = value;
        case BackgroundScheduleService.statusConsecutiveFailuresKey:
          status.consecutiveFailures = int.tryParse(value ?? '0') ?? 0;
        case BackgroundScheduleService.statusLastAppliedCountKey:
          status.lastAppliedCount = int.tryParse(value ?? '');
      }
    }
    // A device can be actively targeted by a schedule it's never had a
    // chance to run yet (binding just created) -- show it too, not only
    // devices with existing bg_check history.
    for (final deviceId in activeScheduleDevices) {
      byDevice.putIfAbsent(deviceId, () => _DeviceStatus(deviceId));
    }
    for (final status in byDevice.values) {
      status.hasActiveSchedule = activeScheduleDevices.contains(status.deviceId);
    }

    final statuses = byDevice.values.toList()
      ..sort((a, b) => (b.lastAttemptAt ?? '').compareTo(a.lastAttemptAt ?? ''));

    if (!mounted) return;
    setState(() {
      _statuses = statuses;
      _loading = false;
    });
  }

  String _relativeTime(String? iso) {
    if (iso == null) return 'never';
    final time = DateTime.tryParse(iso);
    if (time == null) return iso;
    final diff = DateTime.now().toUtc().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Background Processes'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _reload)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
                children: [
                  const Text(
                    'Every device\'s own schedule-check runs. Windows polls '
                    'on its own scheduled task; Android only runs this when '
                    'an exact alarm actually fires, which only happens while '
                    'at least one schedule_interval binding targets that '
                    'device -- a device with nothing scheduled shows as '
                    'idle, not stale, since there is nothing to check.',
                  ),
                  const SizedBox(height: 16),
                  if (_statuses.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('No background-check activity recorded yet.'),
                    )
                  else
                    for (final status in _statuses) _DeviceStatusCard(status: status, relativeTime: _relativeTime),
                ],
              ),
            ),
    );
  }
}

class _DeviceStatusCard extends StatelessWidget {
  const _DeviceStatusCard({required this.status, required this.relativeTime});

  final _DeviceStatus status;
  final String Function(String?) relativeTime;

  @override
  Widget build(BuildContext context) {
    // A device with nothing currently scheduled can't be "stale" or
    // "failing" -- on Android specifically, runDueScheduledEvents is only
    // ever invoked by an alarm, and no alarm is armed unless a
    // schedule_interval binding actively targets this device (see
    // EventDefinitionsDao.loadActiveScheduleIntervalTargetDevices's own
    // doc comment). Whatever last_result/consecutive_failures happen to
    // still say is leftover from before the last binding was removed, not
    // a live problem -- show it as idle, not red, regardless.
    final isIdle = !status.hasActiveSchedule;
    final isError = !isIdle && status.lastResult == 'error';
    final isStale = !isIdle && status.consecutiveFailures >= 2;
    final color = isError || isStale ? Theme.of(context).colorScheme.error : null;

    IconData icon;
    if (isIdle) {
      icon = Icons.pause_circle_outline;
    } else if (isError || isStale) {
      icon = Icons.error_outline;
    } else {
      icon = Icons.check_circle_outline;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 8),
                Text(status.deviceId, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            if (isIdle)
              Text(
                'No active schedule -- nothing bound to this device right now, '
                'so there is nothing to run. Not a failure.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontStyle: FontStyle.italic,
                ),
              ),
            Text('Last attempt: ${relativeTime(status.lastAttemptAt)}'),
            Text('Last success: ${relativeTime(status.lastSuccessAt)}'),
            if (status.lastAppliedCount != null)
              Text('Bindings applied last pass: ${status.lastAppliedCount}'),
            if (!isIdle && status.consecutiveFailures > 0)
              Text(
                'Consecutive failures: ${status.consecutiveFailures}',
                style: TextStyle(color: color, fontWeight: FontWeight.bold),
              ),
            if (isError && status.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                status.lastError!,
                style: TextStyle(color: color, fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
