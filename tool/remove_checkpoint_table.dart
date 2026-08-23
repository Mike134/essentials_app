// ignore_for_file: avoid_print
// Companion to tool/create_checkpoint_table.dart -- run this once Mike has
// confirmed "Schema Engine Checkpoint" renders and syncs correctly on both
// Windows and Android, to leave essentials.db free of the checkpoint
// table again.
//
//   dart run tool/remove_checkpoint_table.dart
//
// Soft-deletes only (is_deleted = 1 on the table_definitions row) -- no
// stage-2 hard-delete (DROP TABLE via migration_log) exists yet (build
// order step 9), so the physical table and its data stay in place on
// every device, just hidden from nav. That's fine for a throwaway proof
// table with nothing worth reclaiming; if a truly clean db matters later,
// finish stage-2 delete first rather than hand-rolling a DROP TABLE here.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/sql_helpers.dart';

const displayName = 'Schema Engine Checkpoint';

Future<void> main() async {
  final crdt = await DatabaseHelper.instance.crdt;

  final rows = await crdt.query(
    'SELECT table_name FROM table_definitions WHERE display_name = ?1 AND is_deleted = 0',
    [displayName],
  );
  if (rows.isEmpty) {
    print('No live "$displayName" table_definitions row found -- nothing to do.');
    await DatabaseHelper.instance.close();
    return;
  }

  for (final row in rows) {
    final tableName = row['table_name'] as String;
    print('Soft-deleting table_definitions row for "$tableName"...');
    await crdt.deleteWhere('table_definitions', {'table_name': tableName});
  }

  print('Done -- will disappear from nav on next launch/relaunch.');
  await DatabaseHelper.instance.close();
}
