import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../db/event_definitions_dao.dart';
import '../db/script_definitions_dao.dart';
import '../db/sync_service.dart';
import '../util/scripting/alarm_schedule_service.dart';
import '../util/scripting/recurrence.dart';

/// Essentials v2 Phase 5 build order step 5 -- the one *global* (not
/// per-table) event binding screen, since `schedule_interval`/
/// `app_launch` events aren't attached to any one table's data
/// (`event_definitions.table_name` is `NULL` for both). See
/// claude/essentials-v2-phase5-design.md's "Event binding UI".
///
/// **`app_launch` fires from `HomeShell` itself; `schedule_interval` fires
/// for real on both platforms via the exact-time alarm chain** (see
/// claude/essentials-v2-alarm-scheduling-design.md) -- not a periodic
/// poll, an alarm armed for the next real due time. `schedule_interval`
/// replaced `schedule_hourly`/`schedule_daily`/`schedule_weekly`'s three
/// fixed buckets with one generic `{interval, unit, anchor}` shape -- see
/// claude/essentials-v2-recurring-schedule-design.md.
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

  /// Live-refresh subscription -- see `ScriptEditorScreen`'s own doc
  /// comment for the "sync works, this screen's own reactivity doesn't"
  /// reasoning, extended here for the same gap.
  StreamSubscription<Set<String>>? _dataChangeSubscription;
  Timer? _dataChangeDebounce;

  @override
  void initState() {
    super.initState();
    _reload();
    _dataChangeSubscription = SyncService.dataChanges.listen(_onDataChanged);
  }

  void _onDataChanged(Set<String> tables) {
    if (!tables.contains('event_definitions') &&
        !tables.contains('script_definitions'))
      return;
    _dataChangeDebounce?.cancel();
    _dataChangeDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _reload();
      // A binding created/edited/deleted on a *different* device syncs
      // in here too -- this device's own armed alarm needs to reflect it
      // just as much as a local edit does. Beyond the design doc's own
      // literal step 4 list (which only names this screen's local
      // actions plus app launch), but the hook already exists for the
      // reload above and rescheduleNextAlarm() is cheap/idempotent to
      // call redundantly -- cheaper than leaving this device's alarm
      // stale until its next natural fire or app relaunch.
      _afterScheduleChanged();
    });
  }

  /// Essentials v2 alarm-based scheduling, build order step 4 (see
  /// claude/essentials-v2-alarm-scheduling-design.md) -- called after
  /// every action on this screen that could change what this device's
  /// own armed alarm should be (create/edit/delete/enable/disable),
  /// alongside `HomeShell`'s own app-launch trigger. Android only, same
  /// reasoning as every other `android_alarm_manager_plus` call site in
  /// this app -- the plugin has no Windows implementation.
  void _afterScheduleChanged() {
    if (Platform.isAndroid) unawaited(rescheduleNextAlarm());
  }

  @override
  void dispose() {
    _dataChangeSubscription?.cancel();
    _dataChangeDebounce?.cancel();
    super.dispose();
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
    _afterScheduleChanged();
  }

  String _scriptNameFor(int scriptId) => _availableScripts
      .firstWhere(
        (s) => s.id == scriptId,
        orElse: () => ScriptDefinition(
          id: scriptId,
          name: '(deleted script)',
          code: '',
          description: null,
        ),
      )
      .name;

  String _describe(EventDefinition binding) {
    switch (binding.eventType) {
      case 'app_launch':
        return 'Every app launch';
      case 'schedule_interval':
        final recurrence = parseRecurrenceConfig(binding.scheduleConfig);
        if (recurrence == null)
          return 'Approximately every interval (unconfigured)';
        final anchor = recurrence.anchor;
        final everyText =
            'Approximately every ${_describeDuration(recurrence.interval)}';
        return anchor == null
            ? everyText
            : '$everyText, starting ${_describeAnchor(anchor)}';
      default:
        return binding.eventType;
    }
  }

  /// Renders back the coarsest whole unit that evenly divides [interval]
  /// (weeks, then days, then hours, then minutes) -- the same four units
  /// `_NewScheduleDialog` offers, so a binding's own description always
  /// reads back in the unit it was most naturally created in (e.g. "every
  /// 2 days," not "every 48 hours").
  String _describeDuration(Duration interval) {
    final minutes = interval.inMinutes;
    if (minutes % (60 * 24 * 7) == 0)
      return _plural(minutes ~/ (60 * 24 * 7), 'week');
    if (minutes % (60 * 24) == 0) return _plural(minutes ~/ (60 * 24), 'day');
    if (minutes % 60 == 0) return _plural(minutes ~/ 60, 'hour');
    return _plural(minutes, 'minute');
  }

  String _plural(int count, String unit) =>
      '$count $unit${count == 1 ? '' : 's'}';

  String _describeAnchor(DateTime anchor) =>
      '${anchor.year}-${anchor.month.toString().padLeft(2, '0')}-${anchor.day.toString().padLeft(2, '0')} '
      '${anchor.hour.toString().padLeft(2, '0')}:${anchor.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scheduled Events')),
      floatingActionButton: FloatingActionButton(
        onPressed: _add,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                16 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                const Text(
                  'Runs a script on a schedule, or once per app launch. Not tied '
                  'to any one table. "Every app launch" fires from the app itself; '
                  'a recurring schedule fires in the background on both platforms, '
                  'as close to on time as the OS allows (usually within a minute or '
                  'two). 5 minutes is the shortest interval allowed.',
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
                  const Text(
                    'No scripts exist yet -- create one first, from Scripts in the nav.',
                  ),
                if (_bindings.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('No scheduled events yet.'),
                  )
                else
                  for (final binding in _bindings)
                    ListTile(
                      title: Text(_describe(binding)),
                      subtitle: Text(
                        'Runs "${_scriptNameFor(binding.scriptId)}"',
                      ),
                      leading: Switch(
                        value: binding.enabled,
                        onChanged: (value) async {
                          await _events.setEnabled(binding.id, value);
                          await _reload();
                          _afterScheduleChanged();
                        },
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await _events.softDelete(binding.id);
                          await _reload();
                          _afterScheduleChanged();
                        },
                      ),
                    ),
              ],
            ),
    );
  }
}

class _NewScheduleResult {
  const _NewScheduleResult({
    required this.eventType,
    required this.scriptId,
    this.scheduleConfig,
  });
  final String eventType;
  final int scriptId;
  final String? scheduleConfig;
}

/// Every unit this dialog offers, paired with its length in minutes --
/// shared between the interval-count validation and building the actual
/// `Duration` for the 5-minute-minimum check. Matches `recurrence.dart`'s
/// own `_unitToDuration`, kept separate (this is UI-only bookkeeping, that
/// one's the real parsed-config source of truth) same as this project's
/// established convention for a small, stable format duplicated across a
/// UI layer and its underlying model (e.g. `_lastRunKey`'s own doc
/// comment on `alarm_schedule_service.dart`).
const _unitMinutes = {
  'minutes': 1,
  'hours': 60,
  'days': 60 * 24,
  'weeks': 60 * 24 * 7,
};

class _NewScheduleDialog extends StatefulWidget {
  const _NewScheduleDialog({required this.scripts});
  final List<ScriptDefinition> scripts;

  @override
  State<_NewScheduleDialog> createState() => _NewScheduleDialogState();
}

class _NewScheduleDialogState extends State<_NewScheduleDialog> {
  String _eventType = 'app_launch';
  final _intervalController = TextEditingController(text: '1');
  String _unit = 'hours';
  bool _useAnchor = false;
  DateTime _anchorDate = DateTime.now();
  TimeOfDay _anchorTime = TimeOfDay.now();
  int? _scriptId;

  @override
  void initState() {
    super.initState();
    _scriptId = widget.scripts.first.id;
    _intervalController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _intervalController.dispose();
    super.dispose();
  }

  int? get _intervalValue => int.tryParse(_intervalController.text);

  /// `null` means the current interval/unit combination is below the
  /// 5-minute floor -- see `recurrence.dart`'s own `minRecurrenceInterval`
  /// doc comment for why that's the real precision ceiling of the
  /// underlying alarm mechanism, not an arbitrary restriction.
  int? get _totalMinutes {
    final interval = _intervalValue;
    if (interval == null || interval <= 0) return null;
    final minutes = interval * _unitMinutes[_unit]!;
    return minutes < 5 ? null : minutes;
  }

  DateTime get _anchorDateTime => DateTime(
    _anchorDate.year,
    _anchorDate.month,
    _anchorDate.day,
    _anchorTime.hour,
    _anchorTime.minute,
  );

  String? get _scheduleConfig {
    if (_eventType != 'schedule_interval') return null;
    return jsonEncode({
      'interval': _intervalValue,
      'unit': _unit,
      if (_useAnchor) 'anchor': _anchorDateTime.toIso8601String(),
    });
  }

  bool get _canSubmit =>
      _scriptId != null &&
      (_eventType != 'schedule_interval' || _totalMinutes != null);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New scheduled event'),
      content: SizedBox(
        width: 360,
        // The anchor date/time row pushed this dialog's content past a
        // plain fixed-height AlertDialog on a phone -- especially with the
        // on-screen keyboard open for the interval field, which halves the
        // available vertical space. A ConstrainedBox capping height to 80%
        // of the screen plus a scroll view is the standard fix for a
        // dialog whose content can outgrow the viewport, rather than
        // trying to guess a height that always fits.
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _eventType,
                  decoration: const InputDecoration(labelText: 'Schedule'),
                  items: const [
                    DropdownMenuItem(
                      value: 'app_launch',
                      child: Text('Every app launch'),
                    ),
                    DropdownMenuItem(
                      value: 'schedule_interval',
                      child: Text('Recurring'),
                    ),
                  ],
                  onChanged: (value) =>
                      setState(() => _eventType = value ?? 'app_launch'),
                ),
                if (_eventType == 'schedule_interval') ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('Every'),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 70,
                        child: TextField(
                          controller: _intervalController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(isDense: true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      DropdownButton<String>(
                        value: _unit,
                        items: const [
                          DropdownMenuItem(
                            value: 'minutes',
                            child: Text('minutes'),
                          ),
                          DropdownMenuItem(
                            value: 'hours',
                            child: Text('hours'),
                          ),
                          DropdownMenuItem(value: 'days', child: Text('days')),
                          DropdownMenuItem(
                            value: 'weeks',
                            child: Text('weeks'),
                          ),
                        ],
                        onChanged: (value) =>
                            setState(() => _unit = value ?? 'hours'),
                      ),
                    ],
                  ),
                  if (_totalMinutes == null)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        'Minimum is 5 minutes.',
                        style: TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Starting at a specific time'),
                    subtitle: const Text(
                      'Off: runs relative to whenever it last ran.',
                    ),
                    value: _useAnchor,
                    onChanged: (value) => setState(() => _useAnchor = value),
                  ),
                  if (_useAnchor) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: _anchorDate,
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2100),
                              );
                              if (picked != null)
                                setState(() => _anchorDate = picked);
                            },
                            child: Text(
                              '${_anchorDate.year}-${_anchorDate.month.toString().padLeft(2, '0')}-'
                              '${_anchorDate.day.toString().padLeft(2, '0')}',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: _anchorTime,
                              );
                              if (picked != null)
                                setState(() => _anchorTime = picked);
                            },
                            child: Text(
                              '${_anchorTime.hour.toString().padLeft(2, '0')}:'
                              '${_anchorTime.minute.toString().padLeft(2, '0')}',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _scriptId,
                  decoration: const InputDecoration(labelText: 'Script'),
                  items: [
                    for (final s in widget.scripts)
                      DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (value) => setState(() => _scriptId = value),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: !_canSubmit
              ? null
              : () => Navigator.pop(
                  context,
                  _NewScheduleResult(
                    eventType: _eventType,
                    scriptId: _scriptId!,
                    scheduleConfig: _scheduleConfig,
                  ),
                ),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
