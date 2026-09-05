// ignore_for_file: avoid_print
// Essentials v2 alarm-based scheduling, build order step 8 -- creates a
// real, throwaway `schedule_hourly` binding through the actual app-facing
// ScriptDefinitionsDao/EventDefinitionsDao (never raw SQL against these
// sqlite_crdt-managed tables -- see CLAUDE.md "Letos/DBeaver workflow
// going forward" for why that's a hard rule in this project), so it syncs
// to every device exactly like a binding created through
// ScheduledEventsScreen would.
//
// Purpose: with no lastRun recorded, nextDueTime() treats an hourly
// binding as due immediately -- so once this binding lands on a device
// and that device's own rescheduleNextAlarm() picks it up (either via its
// own SyncService.dataChanges-triggered _afterScheduleChanged(), or a
// relaunch), a real one-shot alarm should arm for "now," fire shortly
// after, and the self-rescheduling chain should immediately re-arm for
// one hour later. This exercises the one part of the alarm-scheduling
// design that step 4's own real-device pass couldn't (nothing was due at
// the time) -- a real binding actually going through the fire/reschedule
// cycle.
//
//   flutter test tool/create_alarm_step8_test_binding.dart
//
// (Not `dart run` -- see CLAUDE.md "Essentials v2 Phase 1 -- Step 5" for
// why anything touching DatabaseHelper needs `flutter test`, not `dart
// run`.) Paired with tool/remove_alarm_step8_test_binding.dart.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/event_definitions_dao.dart';
import 'package:essentials_app/db/script_definitions_dao.dart';

const _scriptName = 'Alarm step 8 test';

Future<void> main() async {
  final scripts = ScriptDefinitionsDao();
  final events = EventDefinitionsDao();

  print('Creating script "$_scriptName"...');
  final scriptId = await scripts.create(
    name: _scriptName,
    code: "notify('Alarm step 8 test fired at ' + new Date().toISOString());",
    description: 'Essentials v2 alarm-based scheduling, build order step 8. '
        'Safe to delete once confirmed firing/rescheduling correctly -- see '
        'tool/remove_alarm_step8_test_binding.dart.',
  );
  print('  script_id: $scriptId');

  print('Binding it to schedule_hourly (enabled, no schedule_config -- hourly needs none)...');
  final eventId = await events.create(scriptId: scriptId, eventType: 'schedule_hourly', tableName: null);
  print('  event_definitions id: $eventId');

  print('');
  print('Done. Never having a recorded last-run means this binding is due');
  print('immediately -- rescheduleNextAlarm() on any device that picks this');
  print('up should arm a one-shot alarm for "now," which should fire shortly');
  print('and reschedule for one hour later.');
  await DatabaseHelper.instance.close();
}
