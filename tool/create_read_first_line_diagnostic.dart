// ignore_for_file: avoid_print
// One-off diagnostic -- proves readFileFirstLine(path)/readFileLines(path,
// n) end-to-end through the real QuickJS bridge (not just the pure-Dart
// unit tests), same pattern as tool/create_tz_diagnostic.dart. Creates a
// real throwaway table + an app_launch-bound script that calls both
// against a few real paths (a real file, a missing file, a directory) and
// writes the results into a field. Relaunching the real Windows exe fires
// app_launch immediately -- no waiting on a schedule.
//
//   flutter test tool/create_read_first_line_diagnostic.dart
//
// Paired with tool/remove_read_first_line_diagnostic.dart.
import 'dart:io';

import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/event_definitions_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/script_definitions_dao.dart';

const _tableDisplayName = 'Read First Line Diagnostic';
const _scriptName = 'Read First Line Diagnostic Script';

Future<void> main() async {
  final editor = SchemaEditorService();
  final scripts = ScriptDefinitionsDao();
  final events = EventDefinitionsDao();

  final probeFile = File('${Directory.systemTemp.path}/rfl_diagnostic_probe.txt');
  probeFile.writeAsStringSync('Hello from a real file\nsecond line');
  print('Wrote probe file: ${probeFile.path}');

  print('Creating "$_tableDisplayName"...');
  final tableName = await editor.createTable(
    displayName: _tableDisplayName,
    description: 'readFirstLine() diagnostic. Safe to delete -- see tool/remove_read_first_line_diagnostic.dart.',
  );
  await editor.addField(tableName: tableName, displayName: 'Info', format: 'text');
  print('  table_name: $tableName');

  final missingPath = '${Directory.systemTemp.path}/rfl_diagnostic_missing_${DateTime.now().microsecondsSinceEpoch}.txt';
  final code =
      "table('$tableName').create({info: "
      "'firstLine=' + readFileFirstLine(${_jsString(probeFile.path)}) + "
      "' | lines=' + JSON.stringify(readFileLines(${_jsString(probeFile.path)}, 1)) + "
      "' | missing=' + readFileFirstLine(${_jsString(missingPath)}) + "
      "' | dir=' + readFileFirstLine(${_jsString(Directory.systemTemp.path)})});";

  final scriptId = await scripts.create(name: _scriptName, code: code, description: 'readFileFirstLine()/readFileLines() diagnostic script.');

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

String _jsString(String value) {
  final escaped = value.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
  return "'$escaped'";
}
