// ignore_for_file: avoid_print
// Companion to tool/create_kanban_test_table.dart -- run this once Mike's
// done exercising the Kanban view against "Kanban Test", to leave
// essentials.db free of the throwaway table and its "Board" view again.
//
//   flutter test tool/remove_kanban_test_table.dart
//
// (Not `dart run` -- see create_kanban_test_table.dart's own doc comment
// for why.)
//
// Soft-deletes only (table_definitions + view_definitions rows), same
// reasoning as tool/remove_checkpoint_table.dart: this device's own copy
// is safe to permanently drop via SchemaEditorService.dropTable once the
// soft-delete has actually synced everywhere (Manage Tables' own
// "Permanently delete" gating exists specifically to check that -- see
// PermanentDeleteGate), but a script has no reliable way to confirm that
// from here. Leave the real permanent delete to Mike, through the app,
// once he's satisfied both devices show it gone.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/sql_helpers.dart';

const displayName = 'Kanban Test';

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

    final views = await crdt.query(
      'SELECT view_id FROM view_definitions WHERE table_name = ?1 AND is_deleted = 0',
      [tableName],
    );
    for (final view in views) {
      final viewId = view['view_id'] as int;
      print('Soft-deleting view_definitions row #$viewId for "$tableName"...');
      await crdt.deleteWhere('view_definitions', {'view_id': viewId});
    }

    print('Soft-deleting table_definitions row for "$tableName"...');
    await crdt.deleteWhere('table_definitions', {'table_name': tableName});
  }

  print('Done -- will disappear from nav on next launch/relaunch.');
  await DatabaseHelper.instance.close();
}
