// ignore_for_file: avoid_print
// One-off recovery script, 2026-09-11: the "Agenda" table's "End" field
// (physical column literally named `end`, a SQL reserved keyword) broke
// every save with "NOT NULL constraint failed: agenda.hlc" -- `sql_crdt`'s
// `sqlparser` dependency silently failed to recognize the unquoted `end`
// column and never appended its own hlc/node_id/modified/is_deleted values
// to the INSERT. Same failure shape already documented for a column
// literally named `key` (see CLAUDE.md's "007_rename_settings_key_column
// .sql"). `SchemaEditorService`'s identifier generator now blocks every SQL
// reserved keyword (see lib/util/sql_identifiers.dart's `sqlReservedKeywords`)
// so this can't recur for a *new* field -- this script fixes the one field
// already created before that fix landed. The table had zero real rows
// (every save attempt failed before ever inserting), so this is a pure
// schema fix, no data migration needed.
//
// Run via `flutter test tool/fix_agenda_end_field.dart` -- NOT `dart run`,
// which can't compile anything importing SchemaEditorService's own
// TableDiscoveryService -> table_config.dart -> Flutter dependency chain
// (see CLAUDE.md "Essentials v2 Phase 1 -- Step 5" for why). A bare
// script with no test() calls runs to completion fine this way; "No tests
// ran" afterward is expected, not a failure.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';

const tableName = 'agenda';
const brokenFieldName = 'end';

Future<void> main() async {
  final editor = SchemaEditorService();
  final metadata = SchemaMetadataDao();

  final before = await metadata.loadFields(tableName, includeDeleted: false);
  final originalOrder = [for (final f in before) f.fieldName];
  print('Original field order: $originalOrder');
  if (!originalOrder.contains(brokenFieldName)) {
    print('No "$brokenFieldName" field found on "$tableName" -- nothing to do.');
    await DatabaseHelper.instance.close();
    return;
  }
  final brokenIndex = originalOrder.indexOf(brokenFieldName);

  print('Soft-deleting "$brokenFieldName"...');
  await metadata.softDeleteField(tableName, brokenFieldName);

  print('Permanently dropping "$brokenFieldName" (physical column + metadata)...');
  await editor.dropField(tableName, brokenFieldName);

  print('Adding replacement "End" field (dateTime)...');
  await editor.addField(tableName: tableName, displayName: 'End', format: 'dateTime');

  final after = await metadata.loadFields(tableName, includeDeleted: false);
  final newFieldName = after.map((f) => f.fieldName).firstWhere((n) => !originalOrder.contains(n));
  print('New physical column name: $newFieldName');

  final restoredOrder = [...originalOrder]..remove(brokenFieldName);
  restoredOrder.insert(brokenIndex, newFieldName);
  print('Restoring field order: $restoredOrder');
  await metadata.reorderFields(tableName, restoredOrder);

  print('');
  print('Done. "$tableName" now has a working "End" field (column "$newFieldName") '
      'in its original position. Relaunch essentials_app to pick it up.');
  await DatabaseHelper.instance.close();
}
