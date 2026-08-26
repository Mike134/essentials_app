// ignore_for_file: avoid_print
// General-purpose recovery tool -- adopts one or more already-authored
// `migration_log` rows (read from a SOURCE db) onto a TARGET db, physically
// applying their DDL there and recording migration_status as succeeded
// under the target device's own identity, WITHOUT re-authoring new
// migration_log rows (which would collide with every other device's
// already-applied copy -- see tool/dedupe_view_definitions_migration.dart's
// own doc comment for the exact failure shape this avoids).
//
// Exists because of a real, recurring architectural gap: a brand-new
// table's own row data can arrive at a peer bundled in the SAME changeset
// as the migration_log/table_definitions rows that create it, in one
// all-or-nothing crdt_sync merge transaction -- if the peer's physical
// table doesn't exist yet at that exact moment, the whole batch fails and
// rolls back (`ON CONFLICT ()` -- sql_crdt has no cached PK info for a
// table it doesn't have), taking the migration_log rows down with it, so
// the peer can never even learn about the migration that would fix it.
// Hit for `view_definitions` (Essentials v2 Phase 3 Step 1) and again for
// a freshly-created business table (`kanban_test`, Step 3's own test-data
// script) -- confirmed a systemic risk, not a one-off. This script is the
// manual escape hatch until/unless the underlying crdt_sync batch-ordering
// gap gets a real fix (flagged, not attempted here).
//
//   dart run tool/adopt_migrations.dart --source <db> --target <db> --device-id <id> --ids <id1,id2,...>
//
// Target should already be stopped/isolated (no live process holding it)
// before running this, same discipline as every other direct-db recovery
// in this project.
import 'dart:io';

import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'package:essentials_app/util/sql_statements.dart';

Future<void> main(List<String> args) async {
  final sourcePath = _argValue(args, '--source');
  final targetPath = _argValue(args, '--target');
  final deviceId = _argValue(args, '--device-id');
  final idsArg = _argValue(args, '--ids');

  if (sourcePath == null || targetPath == null || deviceId == null || idsArg == null) {
    print('Usage: dart run tool/adopt_migrations.dart --source <db> --target <db> '
        '--device-id <id> --ids <id1,id2,...>');
    exitCode = 64;
    return;
  }
  final ids = idsArg.split(',').map(int.parse).toList();

  if (!await File(sourcePath).exists()) {
    print('REFUSING: no file at $sourcePath');
    exitCode = 1;
    return;
  }
  if (!await File(targetPath).exists()) {
    print('REFUSING: no file at $targetPath');
    exitCode = 1;
    return;
  }

  print('Reading ${ids.length} migration(s) from $sourcePath ...');
  final source = await SqliteCrdt.open(sourcePath);
  final rows = <Map<String, Object?>>[];
  try {
    for (final id in ids) {
      final result = await source.query(
        'SELECT id, sql_text, description, created_at FROM migration_log WHERE id = ?1',
        [id],
      );
      if (result.isEmpty) {
        print('  FAIL: no migration_log row with id $id in source.');
        exitCode = 1;
        return;
      }
      rows.add(result.first);
      print('  #$id  ${result.first['description']}');
    }
  } finally {
    await source.close();
  }

  print('');
  print('Opening target $targetPath ...');
  final target = await SqliteCrdt.open(targetPath);
  try {
    for (final row in rows) {
      final id = row['id'] as int;
      final sqlText = row['sql_text'] as String;

      final existingLog = await target.query('SELECT id FROM migration_log WHERE id = ?1', [id]);
      if (existingLog.isEmpty) {
        await target.execute(
          'INSERT INTO migration_log (id, sql_text, description, created_at) VALUES (?1, ?2, ?3, ?4)',
          [id, sqlText, row['description'], row['created_at']],
        );
        print('  adopted migration_log row #$id');
      } else {
        print('  migration_log row #$id already present, leaving as-is');
      }

      final existingStatus = await target.query(
        'SELECT outcome FROM migration_status WHERE migration_id = ?1 AND device_id = ?2',
        [id, deviceId],
      );
      if (existingStatus.isNotEmpty && existingStatus.first['outcome'] == 'succeeded') {
        print('  #$id already recorded succeeded for "$deviceId" -- not re-applying DDL.');
        continue;
      }

      print('  applying DDL for #$id ...');
      await target.execute('PRAGMA foreign_keys = OFF');
      try {
        await target.transaction((txn) async {
          // Split first -- a real, found-live bug otherwise: a
          // multi-statement migration's `sql_text` (e.g. two CREATE
          // TABLEs joined by `;`, exactly the shape
          // migration_log's own doc comment describes as normal --
          // "a whole related-tables script is a single row") passed
          // whole to one `txn.execute()` call only ran its FIRST
          // statement, with no error raised for the rest -- confirmed
          // live against a real Phase 5 migration creating
          // script_definitions/event_definitions together: only
          // script_definitions came into existence, migration_status
          // was still recorded 'succeeded', and nothing surfaced the
          // gap until a real query against the missing table failed
          // downstream. `MigrationService._attempt` already gets this
          // right (`for (final statement in
          // splitSqlStatements(sqlText))`); this tool just never
          // matched it.
          for (final statement in splitSqlStatements(sqlText)) {
            await txn.execute(statement);
          }
        });
        await target.execute(
          'INSERT OR REPLACE INTO migration_status '
          '(migration_id, device_id, outcome, error_message, attempted_at) '
          'VALUES (?1, ?2, ?3, ?4, ?5)',
          [id, deviceId, 'succeeded', null, DateTime.now().toUtc().toIso8601String()],
        );
        print('    OK');
      } catch (e) {
        print('    FAILED: $e');
        exitCode = 1;
        return;
      } finally {
        await target.execute('PRAGMA foreign_keys = ON');
      }
    }
  } finally {
    await target.close();
  }

  print('');
  print('Done. Row data for any table these migrations created will merge normally on next sync.');
}

String? _argValue(List<String> args, String flag) {
  final index = args.indexOf(flag);
  if (index == -1 || index + 1 >= args.length) return null;
  return args[index + 1];
}
