// ignore_for_file: avoid_print
// Companion to tool/create_image_test_table.dart -- run this once the
// image field's real-device pass is confirmed working (both directions,
// see claude/essentials-v2-image-field-ui-design.md build order step 6),
// to leave essentials.db free of the throwaway table again.
//
//   flutter test tool/remove_image_test_table.dart
//
// (Not `dart run` -- see create_image_test_table.dart's own doc comment
// for why.)
//
// Soft-deletes only (table_definitions row), same reasoning as
// tool/remove_kanban_test_table.dart: this device's own copy is safe to
// permanently drop via SchemaEditorService.dropTable once the soft-delete
// has actually synced everywhere (Manage Tables' own "Permanently delete"
// gating exists specifically to check that), but a script has no reliable
// way to confirm that from here. Leave the real permanent delete to Mike,
// through the app, once both devices show it gone. Does NOT delete the
// captured image bytes themselves (local files-root or hub copy) -- see
// the storage design doc's already-flagged "delete behavior" open item;
// harmless orphans on disk, not touched here.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/sql_helpers.dart';

const displayName = 'Image Field Test';

Future<void> main() async {
  final crdt = await DatabaseHelper.instance.crdt;

  final tables = await crdt.query(
    'SELECT table_name FROM table_definitions WHERE display_name = ?1 AND is_deleted = 0',
    [displayName],
  );
  if (tables.isEmpty) {
    print('No live "$displayName" table_definitions row found -- nothing to do.');
    await DatabaseHelper.instance.close();
    return;
  }

  for (final row in tables) {
    final tableName = row['table_name'] as String;
    print('Soft-deleting table_definitions row for "$tableName"...');
    await crdt.deleteWhere('table_definitions', {'table_name': tableName});
  }

  print('Done -- will disappear from nav on next launch/relaunch.');
  await DatabaseHelper.instance.close();
}
