// ignore_for_file: avoid_print
// Same as tool/create_read_first_line_diagnostic.dart but targeting
// MIKE-12R with real Android storage paths, since Windows/Android paths
// aren't interchangeable. Run against MIKE-CU's own essentials.db (the
// event syncs to MIKE-12R normally); the probe file itself must already
// be pushed to the device separately (adb push).
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/event_definitions_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/script_definitions_dao.dart';

const _tableDisplayName = 'Read First Line Diagnostic';
const _scriptName = 'Read First Line Diagnostic Script 12R';
const _probePath = '/storage/emulated/0/Download/rfl_probe.txt';
const _missingPath = '/storage/emulated/0/Download/rfl_probe_missing.txt';
const _dirPath = '/storage/emulated/0/Download';

Future<void> main() async {
  final editor = SchemaEditorService();
  final scripts = ScriptDefinitionsDao();
  final events = EventDefinitionsDao();

  print('Creating "$_tableDisplayName"...');
  final tableName = await editor.createTable(
    displayName: _tableDisplayName,
    description: 'readFirstLine() diagnostic (12R). Safe to delete.',
  );
  await editor.addField(tableName: tableName, displayName: 'Info', format: 'text');
  print('  table_name: $tableName');

  final code =
      "table('$tableName').create({info: "
      "'firstLine=' + readFileFirstLine('$_probePath') + "
      "' | lines=' + JSON.stringify(readFileLines('$_probePath', 1)) + "
      "' | missing=' + readFileFirstLine('$_missingPath') + "
      "' | dir=' + readFileFirstLine('$_dirPath')});";

  final scriptId = await scripts.create(name: _scriptName, code: code, description: 'readFileFirstLine()/readFileLines() diagnostic script (12R).');

  final eventId = await events.create(
    scriptId: scriptId,
    eventType: 'app_launch',
    tableName: null,
    targetDevices: const ['MIKE-12R'],
  );

  print('  script_id: $scriptId, event_id: $eventId');
  print('Done. Relaunch essentials_app on MIKE-12R to fire app_launch.');
  await DatabaseHelper.instance.close();
}
