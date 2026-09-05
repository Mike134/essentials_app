// ignore_for_file: avoid_print
// One-off diagnostic -- proves writeFile(path, text) end-to-end through
// the real QuickJS bridge (not just the pure-Dart unit tests), same
// pattern as tool/create_read_first_line_diagnostic.dart. Creates a real
// throwaway table + an app_launch-bound script that writes a real file,
// then reads it back via readFileFirstLine to prove the round trip, and
// separately reports the write-side error message for a bad path.
//
//   flutter test tool/create_write_file_diagnostic.dart
//
// Paired with tool/remove_write_file_diagnostic.dart. This tool does NOT
// pre-create the target file -- writeFile itself is what's meant to
// create it.
import 'dart:io';

import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/event_definitions_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/script_definitions_dao.dart';

const _tableDisplayName = 'Write File Diagnostic';
const _scriptName = 'Write File Diagnostic Script';

Future<void> main() async {
  final editor = SchemaEditorService();
  final scripts = ScriptDefinitionsDao();
  final events = EventDefinitionsDao();

  final targetPath = '${Directory.systemTemp.path}/wfl_diagnostic_target.txt';
  final targetFile = File(targetPath);
  if (targetFile.existsSync()) targetFile.deleteSync();
  print('Target path (should not exist yet): $targetPath');

  print('Creating "$_tableDisplayName"...');
  final tableName = await editor.createTable(
    displayName: _tableDisplayName,
    description: 'writeFile() diagnostic. Safe to delete -- see tool/remove_write_file_diagnostic.dart.',
  );
  await editor.addField(tableName: tableName, displayName: 'Info', format: 'text');
  print('  table_name: $tableName');

  final badPath = '${Directory.systemTemp.path}/wfl_no_such_dir_${DateTime.now().microsecondsSinceEpoch}/out.txt';
  final code =
      "table('$tableName').create({info: "
      "'write=' + writeFile(${_jsString(targetPath)}, 'line one\\nline two') + "
      "' | readback=' + readFileFirstLine(${_jsString(targetPath)}) + "
      "' | badWrite=' + writeFile(${_jsString(badPath)}, 'x')});";

  final scriptId = await scripts.create(name: _scriptName, code: code, description: 'writeFile() diagnostic script.');

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
