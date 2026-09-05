// ignore_for_file: avoid_print
// One-off diagnostic -- checks whether flutter_js's embedded QuickJS Date
// implementation applies the device's real local timezone, or defaults to
// UTC. Creates a real throwaway table + an app_launch-bound script that
// writes new Date()'s raw string forms into a field (never a notify()
// message, which can't be read back programmatically), targeted at
// MIKE-CU only. Relaunching the real Windows exe fires app_launch
// immediately -- no waiting on an interval.
//
//   flutter test tool/create_tz_diagnostic.dart
//
// Paired with tool/remove_tz_diagnostic.dart.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/event_definitions_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/script_definitions_dao.dart';

const _tableDisplayName = 'Tz Diagnostic';
const _scriptName = 'Tz Diagnostic Script';

Future<void> main() async {
  final editor = SchemaEditorService();
  final scripts = ScriptDefinitionsDao();
  final events = EventDefinitionsDao();

  print('Creating "$_tableDisplayName"...');
  final tableName = await editor.createTable(
    displayName: _tableDisplayName,
    description: 'Timezone diagnostic. Safe to delete -- see tool/remove_tz_diagnostic.dart.',
  );
  await editor.addField(tableName: tableName, displayName: 'Info', format: 'text');
  print('  table_name: $tableName');

  final scriptId = await scripts.create(
    name: _scriptName,
    code:
        "table('$tableName').create({info: "
        "'device=' + deviceId() + "
        "' localTime=' + localTime() + "
        "' localTime.iso=' + localTime.iso() + "
        "' (broken) new Date()=' + new Date().toString()});",
    description: 'Timezone/device-id diagnostic script.',
  );

  final eventId = await events.create(
    scriptId: scriptId,
    eventType: 'app_launch',
    tableName: null,
    targetDevices: const ['MIKE-CU'],
  );

  print('  script_id: $scriptId, event_id: $eventId');
  print('');
  print('Done. Relaunch the real Windows exe to fire app_launch, then check');
  print('the "$tableName" table for the result.');
  await DatabaseHelper.instance.close();
}
