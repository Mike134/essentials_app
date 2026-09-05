// ignore_for_file: avoid_print
// Cleanup for tool/create_missed_occurrence_test.dart -- soft-deletes
// (never a raw hard-delete against these sqlite_crdt-managed tables) the
// script + binding it created, and clears the backdated schedule_last_run
// key, once the missed-occurrence notification is confirmed on MIKE-12R.
//
//   flutter test tool/remove_missed_occurrence_test.dart
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

  final allScripts = await scripts.loadAll();
  final matches = allScripts.where((s) => s.name == _scriptName).toList();
  if (matches.isEmpty) {
    print('No script named "$_scriptName" found -- already cleaned up?');
  }

  for (final script in matches) {
    final scheduled = await events.loadScheduled();
    for (final binding in scheduled.where((b) => b.scriptId == script.id)) {
      print('Soft-deleting event_definitions #${binding.id} (${binding.eventType})...');
      await events.softDelete(binding.id);
      await settings.setDeviceSetting('schedule_last_run:${binding.id}', null);
    }
    print('Soft-deleting script_definitions #${script.id} ("${script.name}")...');
    await scripts.softDelete(script.id);
  }

  print('Done.');
  await DatabaseHelper.instance.close();
}
