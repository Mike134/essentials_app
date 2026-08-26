import 'dart:convert';

import 'package:flutter/material.dart';

import '../db/event_definitions_dao.dart';
import '../db/script_definitions_dao.dart';

/// Essentials v2 Phase 5 build order step 5 -- the one *global* (not
/// per-table) event binding screen, since `schedule_daily`/
/// `schedule_weekly`/`schedule_hourly`/`app_launch` events aren't attached
/// to any one table's data (`event_definitions.table_name` is `NULL` for
/// all four). See claude/essentials-v2-phase5-design.md's "Event binding
/// UI".
///
/// **`app_launch` actually fires now (build order step 6) -- the other
/// three are still inert.** Real background firing for hourly/daily/
/// weekly needs steps 7-8 (Android `workmanager`/Windows, the latter
/// still pending that build's own spike); creating one of those bindings
/// today is stored correctly but nothing runs it yet, same "visibly
/// staged, not yet functional" precedent `button` fields carried between
/// steps 1 and 4. [_describe] marks this distinction directly in the UI
/// rather than leaving all four looking equally live.
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
        return 'Approximately every hour (not yet active)';
      case 'schedule_daily':
        final config = binding.scheduleConfig == null ? null : jsonDecode(binding.scheduleConfig!) as Map;
        return 'Approximately daily at ${config?['time'] ?? '?'} (not yet active)';
      case 'schedule_weekly':
        final config = binding.scheduleConfig == null ? null : jsonDecode(binding.scheduleConfig!) as Map;
        return 'Approximately weekly, ${config?['day'] ?? '?'} at ${config?['time'] ?? '?'} (not yet active)';
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
                  'to any one table. "Every app launch" is live now; the hourly/'
                  'daily/weekly schedules are stored correctly but nothing runs '
                  'them yet -- real background firing needs later build steps, '
                  'and even then "approximately" -- neither Android nor Windows '
                  'background scheduling is exact-time.',
                ),
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
