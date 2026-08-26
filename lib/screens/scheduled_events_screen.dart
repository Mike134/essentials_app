import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../db/event_definitions_dao.dart';
import '../db/script_definitions_dao.dart';

/// Essentials v2 Phase 5 build order step 5 -- the one *global* (not
/// per-table) event binding screen, since `schedule_daily`/
/// `schedule_weekly`/`schedule_hourly`/`app_launch` events aren't attached
/// to any one table's data (`event_definitions.table_name` is `NULL` for
/// all four). See claude/essentials-v2-phase5-design.md's "Event binding
/// UI".
///
/// **`app_launch` fires from `HomeShell` itself (build order step 6); the
/// other three now fire for real on both platforms too.** Android:
/// a periodic `workmanager` task registered from `HomeShell` (build order
/// step 7). Windows: a Scheduled Task (registered once, manually --
/// `windows/register_background_schedule_task.ps1`) launches
/// `essentials_app.exe --background-schedule-check`, which hides its own
/// window immediately and exits once done (build order step 8 -- no
/// headless Flutter engine exists on Windows the way Android's
/// `workmanager` gives one, confirmed via a real spike; see
/// claude/essentials-v2-phase5-design.md's step 8 write-up). Both
/// platforms check at most every ~15 minutes, so "daily at 8:00am"
/// genuinely means "the first check after 8:00am," not the exact minute.
class ScheduledEventsScreen extends StatefulWidget {
  const ScheduledEventsScreen({super.key});

  @override
  State<ScheduledEventsScreen> createState() => _ScheduledEventsScreenState();
}

class _ScheduledEventsScreenState extends State<ScheduledEventsScreen> {
  final _events = EventDefinitionsDao();
  final _scripts = ScriptDefinitionsDao();
  List<EventDefinition> _bindings = const [];
  List<ScriptDefinition> _availableScripts = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final bindings = await _events.loadScheduled();
    final scripts = await _scripts.loadAll();
    if (!mounted) return;
    setState(() {
      _bindings = bindings;
      _availableScripts = scripts;
      _loading = false;
    });
  }

  /// Android aggressively kills background work for apps it hasn't been
  /// told to leave alone -- this project already hit exactly this once
  /// for foreground sync itself (see CLAUDE.md "Real, non-code finding:
  /// MIKE-12R's connection is unstable when the app backgrounds or the
  /// screen sleeps"), fixed there by a manual Settings toggle Mike found
  /// himself. A background `workmanager` task is at least as exposed to
  /// the same battery-optimization killing -- worth a direct in-app
  /// prompt this time rather than hoping it gets found the same way
  /// twice. `Permission.ignoreBatteryOptimizations.request()` shows
  /// Android's own native "Allow this app to ignore battery
  /// optimizations?" system dialog; nothing to do on Windows.
  Future<void> _requestBatteryExemption() async {
    // Also requests POST_NOTIFICATIONS (Android 13+) while we have the
    // user's attention on this screen -- without it, a scheduled
    // script's `notify()` effect would silently never show anything at
    // all in the background (see ScriptNotifications, the caller of
    // this permission on the notification-plugin side).
    await Permission.notification.request();
    final status = await Permission.ignoreBatteryOptimizations.request();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          status.isGranted
              ? 'Battery optimization exemption granted -- scheduled scripts can run reliably in the background.'
              : 'Not granted -- scheduled scripts may run late or not at all while the app is closed.',
        ),
      ),
    );
  }

  Future<void> _add() async {
    if (_availableScripts.isEmpty) return;
    final result = await showDialog<_NewScheduleResult>(
      context: context,
      builder: (context) => _NewScheduleDialog(scripts: _availableScripts),
    );
    if (result == null) return;
    await _events.create(
      scriptId: result.scriptId,
      eventType: result.eventType,
      scheduleConfig: result.scheduleConfig,
    );
    await _reload();
  }

  String _scriptNameFor(int scriptId) => _availableScripts
      .firstWhere((s) => s.id == scriptId, orElse: () => ScriptDefinition(id: scriptId, name: '(deleted script)', code: '', description: null))
      .name;

  String _describe(EventDefinition binding) {
    switch (binding.eventType) {
      case 'app_launch':
        return 'Every app launch';
      case 'schedule_hourly':
        return 'Approximately every hour';
      case 'schedule_daily':
        final config = binding.scheduleConfig == null ? null : jsonDecode(binding.scheduleConfig!) as Map;
        return 'Approximately daily at ${config?['time'] ?? '?'}';
      case 'schedule_weekly':
        final config = binding.scheduleConfig == null ? null : jsonDecode(binding.scheduleConfig!) as Map;
        return 'Approximately weekly, ${config?['day'] ?? '?'} at ${config?['time'] ?? '?'}';
      default:
        return binding.eventType;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scheduled Events')),
      floatingActionButton: FloatingActionButton(onPressed: _add, child: const Icon(Icons.add)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
              children: [
                const Text(
                  'Runs a script on a schedule, or once per app launch. Not tied '
                  'to any one table. "Every app launch" fires from the app itself; '
                  'hourly/daily/weekly fire in the background on both platforms, '
                  'checked approximately every 15 minutes.',
                ),
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _requestBatteryExemption,
                    icon: const Icon(Icons.battery_saver),
                    label: const Text('Allow reliable background running'),
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Windows: run windows\\register_background_schedule_task.ps1 '
                    'once (elevated PowerShell) to register the background check. '
                    'See claude/essentials-v2-phase5-design.md for details.',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
                ],
                const SizedBox(height: 12),
                if (_availableScripts.isEmpty)
                  const Text('No scripts exist yet -- create one first, from Scripts in the nav.'),
                if (_bindings.isEmpty)
                  const Padding(padding: EdgeInsets.only(top: 8), child: Text('No scheduled events yet.'))
                else
                  for (final binding in _bindings)
                    ListTile(
                      title: Text(_describe(binding)),
                      subtitle: Text('Runs "${_scriptNameFor(binding.scriptId)}"'),
                      leading: Switch(
                        value: binding.enabled,
                        onChanged: (value) async {
                          await _events.setEnabled(binding.id, value);
                          await _reload();
                        },
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await _events.softDelete(binding.id);
                          await _reload();
                        },
                      ),
                    ),
              ],
            ),
    );
  }
}

class _NewScheduleResult {
  const _NewScheduleResult({required this.eventType, required this.scriptId, this.scheduleConfig});
  final String eventType;
  final int scriptId;
  final String? scheduleConfig;
}

class _NewScheduleDialog extends StatefulWidget {
  const _NewScheduleDialog({required this.scripts});
  final List<ScriptDefinition> scripts;

  @override
  State<_NewScheduleDialog> createState() => _NewScheduleDialogState();
}

class _NewScheduleDialogState extends State<_NewScheduleDialog> {
  String _eventType = 'app_launch';
  TimeOfDay _time = const TimeOfDay(hour: 8, minute: 0);
  String _day = 'mon';
  int? _scriptId;

  static const _days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

  @override
  void initState() {
    super.initState();
    _scriptId = widget.scripts.first.id;
  }

  String get _timeString =>
      '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';

  String? get _scheduleConfig {
    switch (_eventType) {
      case 'schedule_daily':
        return jsonEncode({'time': _timeString});
      case 'schedule_weekly':
        return jsonEncode({'day': _day, 'time': _timeString});
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New scheduled event'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _eventType,
              decoration: const InputDecoration(labelText: 'Schedule'),
              items: const [
                DropdownMenuItem(value: 'app_launch', child: Text('Every app launch')),
                DropdownMenuItem(value: 'schedule_hourly', child: Text('Hourly')),
                DropdownMenuItem(value: 'schedule_daily', child: Text('Daily')),
                DropdownMenuItem(value: 'schedule_weekly', child: Text('Weekly')),
              ],
              onChanged: (value) => setState(() => _eventType = value ?? 'app_launch'),
            ),
            if (_eventType == 'schedule_daily' || _eventType == 'schedule_weekly') ...[
              const SizedBox(height: 12),
              if (_eventType == 'schedule_weekly')
                DropdownButtonFormField<String>(
                  initialValue: _day,
                  decoration: const InputDecoration(labelText: 'Day'),
                  items: [for (final d in _days) DropdownMenuItem(value: d, child: Text(d))],
                  onChanged: (value) => setState(() => _day = value ?? 'mon'),
                ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () async {
                  final picked = await showTimePicker(context: context, initialTime: _time);
                  if (picked != null) setState(() => _time = picked);
                },
                child: Text('Time: $_timeString'),
              ),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _scriptId,
              decoration: const InputDecoration(labelText: 'Script'),
              items: [
                for (final s in widget.scripts) DropdownMenuItem(value: s.id, child: Text(s.name)),
              ],
              onChanged: (value) => setState(() => _scriptId = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _scriptId == null
              ? null
              : () => Navigator.pop(
                  context,
                  _NewScheduleResult(eventType: _eventType, scriptId: _scriptId!, scheduleConfig: _scheduleConfig),
                ),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
