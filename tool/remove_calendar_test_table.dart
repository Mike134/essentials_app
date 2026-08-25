// ignore_for_file: avoid_print
// Companion to tool/create_calendar_test_table.dart -- run this once Mike's
// done exercising the Calendar view against "Calendar Test", to leave
// essentials.db free of the throwaway table again. This table has no view
// of its own (Calendar is the one aggregate view, not per-table), so this
// only needs to soft-delete the table_definitions row -- unlike
// remove_kanban_test_table.dart, there's no matching view_definitions row
// to clean up.
//
//   flutter test tool/remove_calendar_test_table.dart
//
// (Not `dart run` -- see create_calendar_test_table.dart's own doc comment
// for why.)
//
// Soft-delete only, same reasoning as remove_kanban_test_table.dart: leave
// the real permanent delete (Manage Tables' "Permanently delete") to Mike,
// through the app, once he's satisfied both devices show it gone.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/sql_helpers.dart';

const displayName = 'Calendar Test';

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

  print('Done -- will disappear from Manage Tables/nav and the Calendar\'s Lists panel on next launch/relaunch.');
  await DatabaseHelper.instance.close();
}
