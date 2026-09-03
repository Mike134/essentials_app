import 'dart:async';

import 'package:flutter/material.dart';

import '../db/database_helper.dart';
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
                    'Every device\'s own hourly/daily/weekly schedule-check '
                    'runs -- Android\'s workmanager, Windows\' scheduled task. '
                    'Checks approximately every 15 minutes; most passes have '
                    'nothing due, which is normal.',
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
    final isError = status.lastResult == 'error';
    final isStale = status.consecutiveFailures >= 2;
    final color = isError || isStale ? Theme.of(context).colorScheme.error : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isError || isStale ? Icons.error_outline : Icons.check_circle_outline,
                  color: color,
                ),
                const SizedBox(width: 8),
                Text(status.deviceId, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            Text('Last attempt: ${relativeTime(status.lastAttemptAt)}'),
            Text('Last success: ${relativeTime(status.lastSuccessAt)}'),
            if (status.lastAppliedCount != null)
              Text('Bindings applied last pass: ${status.lastAppliedCount}'),
            if (status.consecutiveFailures > 0)
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
