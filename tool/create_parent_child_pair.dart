// ignore_for_file: avoid_print
// Builds a real Parent/Child table pair through the actual app-facing
// SchemaEditorService (not a test, not raw SQL, not the interactive UI) --
// same throwaway-proof-table spirit as tool/create_checkpoint_table.dart,
// applied to the one Essentials v2 relationship shape that still needed a
// real, current confirmation: a `select`/linked field with
// `on_delete: cascade`, exercising the exact same RESTRICT/CASCADE/IGNORE
// enforcement path documented in CLAUDE.md "Essentials v2 Phase 1 -- Step 6"
// and re-verified end to end during the real-device verification session.
//
//   flutter test tool/create_parent_child_pair.dart
//
// (not `dart run` -- SchemaEditorService transitively imports Flutter via
// table_config.dart, which crashes the vanilla Dart SDK compiler; see
// CLAUDE.md "Essentials v2 Phase 1 -- Step 5" for the finding. A plain
// script with a bare main() and no test() calls runs to completion fine
// under `flutter test`; its own "No tests ran" afterward is expected.)
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/schema_editor_service.dart';

const parentDisplayName = 'Parent';
const childDisplayName = 'Child';

Future<void> main() async {
  final editor = SchemaEditorService();

  print('Creating "$parentDisplayName"...');
  final parentTable = await editor.createTable(
    displayName: parentDisplayName,
    description: 'Essentials v2 Phase 1 parent/child verification pair -- '
        'proves a select/linked field with on_delete: cascade through the '
        'real engine.',
  );
  print('  table_name: $parentTable');

  print('Adding "Name" (text) to Parent...');
  await editor.addField(tableName: parentTable, displayName: 'Name', format: 'text');

  print('Creating "$childDisplayName"...');
  final childTable = await editor.createTable(
    displayName: childDisplayName,
    description: 'Linked to Parent via a cascade select field -- deleting '
        'a Parent row should delete its Child rows too.',
  );
  print('  table_name: $childTable');

  print('Adding "Name" (text) to Child...');
  await editor.addField(tableName: childTable, displayName: 'Name', format: 'text');

  print('Adding "Parent" (linked, on_delete: cascade) to Child...');
  await editor.addField(
    tableName: childTable,
    displayName: 'Parent',
    format: 'select',
    optionsJson: '{"mode":"linked","table":"$parentTable","on_delete":"cascade"}',
  );

  print('');
  print('Done. Launch essentials_app and look for "$parentDisplayName"/'
      '"$childDisplayName" in the nav.');
  await DatabaseHelper.instance.close();
}
