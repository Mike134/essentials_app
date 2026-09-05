// ignore_for_file: avoid_print
// Cleanup for tool/create_alarm_step8_test_binding.dart -- soft-deletes
// (never a raw hard-delete against these sqlite_crdt-managed tables) the
// script + binding it created, once step 8's real-device fire/reschedule
// check is confirmed.
//
//   flutter test tool/remove_alarm_step8_test_binding.dart
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/event_definitions_dao.dart';
import 'package:essentials_app/db/script_definitions_dao.dart';

const _scriptName = 'Alarm step 8 test';

Future<void> main() async {
  final scripts = ScriptDefinitionsDao();
  final events = EventDefinitionsDao();

  final allScripts = await scripts.loadAll();
  final matches = allScripts.where((s) => s.name == _scriptName).toList();
  if (matches.isEmpty) {
    print('No script named "$_scriptName" found -- already cleaned up?');
  }

  for (final script in matches) {
    // event_definitions rows reference script_id but there's no dedicated
    // "load bindings for a script" query -- table_name is null for every
    // scheduled binding, so loadForTable() doesn't apply either. Load
    // every scheduled binding directly and filter by scriptId, same
    // approach BackgroundScheduleService itself uses via loadScheduled().
    final scheduled = await events.loadScheduled();
    for (final binding in scheduled.where((b) => b.scriptId == script.id)) {
      print('Soft-deleting event_definitions #${binding.id} (${binding.eventType})...');
      await events.softDelete(binding.id);
    }
    print('Soft-deleting script_definitions #${script.id} ("${script.name}")...');
    await scripts.softDelete(script.id);
  }

  print('Done.');
  await DatabaseHelper.instance.close();
}
