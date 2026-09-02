// ignore_for_file: avoid_print
// General-purpose migration retraction tool -- soft-deletes (tombstones) a
// migration_log row via the real sqlite_crdt API, the same "is_deleted"
// retraction convention this project has used before (see
// tool/dedupe_view_definitions_migration.dart and CLAUDE.md's own
// "retracting the failed one via the existing is_deleted convention" notes).
//
// A migration recorded 'failed' in migration_status for some device
// permanently halts MigrationService.applyPending's progression for that
// device (see lib/db/migration_service.dart) -- everything with a higher id
// stays stuck behind it, forever, until the migration_log row itself is
// retracted. applyPending only ever reads migration_log rows with
// is_deleted = 0, so tombstoning it here makes every device that receives
// this tombstone skip straight past it on their next applyPending run,
// regardless of whatever 'failed' migration_status row already exists for
// it (that row is simply never consulted once the migration_log row itself
// is excluded from the query).
//
// Never does a raw SQL DELETE -- crdt.execute rewrites it into a real
// tombstone with a fresh hlc/node_id/modified, which is what actually makes
// this sync to every other device. A raw SQL edit would never sync at all
// (see CLAUDE.md "Letos/DBeaver workflow going forward").
//
//   dart run tool/retract_migration.dart --path <db> --id <migration_id>
import 'dart:io';

import 'package:sqlite_crdt/sqlite_crdt.dart';

Future<void> main(List<String> args) async {
  final path = _argValue(args, '--path');
  final id = int.tryParse(_argValue(args, '--id') ?? '');

  if (path == null || id == null) {
    print('Usage: dart run tool/retract_migration.dart --path <db> --id <migration_id>');
    exitCode = 64;
    return;
  }
  if (!await File(path).exists()) {
    print('REFUSING: no file at $path');
    exitCode = 1;
    return;
  }

  print('Opening $path ...');
  final crdt = await SqliteCrdt.open(path);
  try {
    final row = await crdt.query(
      'SELECT id, is_deleted, description FROM migration_log WHERE id = ?1',
      [id],
    );
    if (row.isEmpty) {
      print('No migration_log row with id $id in this copy -- nothing to do.');
      return;
    }
    if ((row.first['is_deleted'] as int) == 1) {
      print('migration_log row $id already tombstoned in this copy.');
      return;
    }
    print('Retracting migration_log row $id (${row.first['description']}) ...');
    await crdt.execute('DELETE FROM migration_log WHERE id = ?1', [id]);
    print('OK.');
  } finally {
    await crdt.close();
  }
}

String? _argValue(List<String> args, String flag) {
  final index = args.indexOf(flag);
  if (index == -1 || index + 1 >= args.length) return null;
  return args[index + 1];
}
