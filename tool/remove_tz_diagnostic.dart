// ignore_for_file: avoid_print
// Cleanup for tool/create_tz_diagnostic.dart -- soft-deletes the script,
// the event binding, and the throwaway table (never a raw hard-delete
// against a sqlite_crdt-managed table, per this project's standing rule).
//
//   flutter test tool/remove_tz_diagnostic.dart
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/event_definitions_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/script_definitions_dao.dart';

const _tableDisplayName = 'Tz Diagnostic';
const _scriptName = 'Tz Diagnostic Script';

Future<void> main() async {
  final metadata = SchemaMetadataDao();
  final scripts = ScriptDefinitionsDao();
  final events = EventDefinitionsDao();
  final editor = SchemaEditorService();

  final tables = await metadata.loadActiveTables();
  final table = tables.where((t) => t.displayName == _tableDisplayName).toList();
  if (table.isNotEmpty) {
    final tableName = table.first.tableName;
    for (final binding in await events.loadScheduled()) {
      final scriptName = await scripts.loadName(binding.scriptId);
      if (scriptName == _scriptName) await events.softDelete(binding.id);
    }
    for (final s in await scripts.loadAll()) {
      if (s.name == _scriptName) await scripts.softDelete(s.id);
    }
    await metadata.softDeleteTable(tableName);
    await editor.dropTable(tableName);
    print('Removed "$_tableDisplayName" ($tableName) and its script/event.');
  } else {
    print('No "$_tableDisplayName" table found -- already cleaned up.');
  }
  await DatabaseHelper.instance.close();
}
