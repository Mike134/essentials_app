// ignore_for_file: avoid_print
// Essentials v2 recurring-schedule design -- creates a real, throwaway
// schedule_interval binding through the actual app-facing
// ScriptDefinitionsDao/EventDefinitionsDao/ThemeSettingsDao (never raw SQL
// against these sqlite_crdt-managed tables), deliberately backdating
// MIKE-12R's own schedule_last_run so several whole slots have already
// been missed by the time it's picked up -- exercises
// BackgroundScheduleService._notifyIfOccurrencesWereMissed for real, on
// real hardware, not just in a unit test's captured notify() callback.
//
//   flutter test tool/create_missed_occurrence_test.dart
//
// (Not `dart run` -- see CLAUDE.md "Essentials v2 Phase 1 -- Step 5" for
// why anything touching DatabaseHelper needs `flutter test`, not `dart
// run`.) Paired with tool/remove_missed_occurrence_test.dart.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/event_definitions_dao.dart';
import 'package:essentials_app/db/script_definitions_dao.dart';
import 'package:essentials_app/db/theme_settings_dao.dart';

const _scriptName = 'Missed occurrence test';
const _targetDeviceId = 'MIKE-12R';

Future<void> main() async {
  final scripts = ScriptDefinitionsDao();
  final events = EventDefinitionsDao();
  final settings = ThemeSettingsDao(deviceId: _targetDeviceId);

  print('Creating script "$_scriptName"...');
  final scriptId = await scripts.create(
    name: _scriptName,
    code: "notify('Missed occurrence test fired at ' + new Date().toISOString());",
    description: 'Recurring-schedule missed-occurrence notification test. Safe to delete once '
        'confirmed -- see tool/remove_missed_occurrence_test.dart.',
  );
  print('  script_id: $scriptId');

  // Anchor 90 minutes ago, 5-minute interval -- 18 slots have passed since
  // the anchor. Setting schedule_last_run to the anchor itself simulates
  // "it serviced its very first slot, then the device was offline/closed
  // for a while" -- a real gap, not a never-run binding (which never
  // triggers a missed-occurrence notice at all, by design).
  final anchor = DateTime.now().subtract(const Duration(minutes: 90));
  print('Binding it to schedule_interval (5 minutes, anchored at $anchor)...');
  final eventId = await events.create(
    scriptId: scriptId,
    eventType: 'schedule_interval',
    tableName: null,
    scheduleConfig: '{"interval": 5, "unit": "minutes", "anchor": "${anchor.toIso8601String()}"}',
  );
  print('  event_definitions id: $eventId');

  print('Backdating $_targetDeviceId\'s own schedule_last_run to the anchor...');
  await settings.setDeviceSetting('schedule_last_run:$eventId', anchor.toIso8601String());

  print('');
  print('Done. The next time MIKE-12R evaluates this binding (app launch, or');
  print('its next alarm fire), it should be ~18 slots overdue -- expect a');
  print('real notification naming "$_scriptName" and the missed count.');
  await DatabaseHelper.instance.close();
}
