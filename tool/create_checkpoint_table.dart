// ignore_for_file: avoid_print
// Essentials v2 Phase 1, build order step 5 -- the checkpoint. Creates one
// real table through the actual app-facing SchemaEditorService (not a
// test, not raw SQL), so Mike can open essentials_app on both Windows and
// Android and confirm the grid/form screens render something built by the
// new engine, and that it syncs through the server -- see
// claude/essentials-v2-phase1-design.md, build order step 5: "This is what
// 'the engine works' means now -- no 19-table rebuild to validate against."
//
//   dart run tool/create_checkpoint_table.dart
//
// Same throwaway-proof-table spirit as the original Table Discovery
// phase's `nav_discovery_test` (created directly in Letos back then --
// this time, deliberately, through the app's own SchemaEditorService,
// since that's the whole point of this phase). Meant to be removed once
// Mike's confirmed it renders/syncs correctly on both platforms -- see
// tool/remove_checkpoint_table.dart.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/schema_editor_service.dart';

const displayName = 'Schema Engine Checkpoint';

Future<void> main() async {
  final editor = SchemaEditorService();

  print('Creating "$displayName"...');
  final tableName = await editor.createTable(
    displayName: displayName,
    description: 'Essentials v2 Phase 1 build order step 5 checkpoint -- '
        'proves createTable/addField/SchemaRegistry render correctly end '
        'to end. Safe to delete once confirmed on both platforms (see '
        'tool/remove_checkpoint_table.dart).',
  );
  print('  table_name: $tableName');

  print('Adding "Notes" (text)...');
  await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');

  print('Adding "Confirmed" (boolean)...');
  await editor.addField(
    tableName: tableName,
    displayName: 'Confirmed',
    format: 'boolean',
    required: true,
    defaultValue: '0',
  );

  print('');
  print('Done. Launch essentials_app and look for "$displayName" in the nav.');
  await DatabaseHelper.instance.close();
}
