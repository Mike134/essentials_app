// ignore_for_file: avoid_print
// One-time cleanup for the orphaned physical table left behind by a
// retracted DROP TABLE migration (see lib/db/migration_service.dart's
// _isAlreadyGoneError doc comment for the full incident).
//
// migration_log id 1787789550490409 ('DROP TABLE
// "script_delete_1787789549921449"') failed with "no such table" on device
// MIKE-CU -- a prior sync had already removed the table there through a
// different path -- and was retracted (is_deleted = 1) to unblock MIKE-CU's
// pipeline under the old halt-on-failure behavior. Retracting stopped that
// row from ever reaching hub.db too, so hub.db's own physical copy of
// "script_delete_1787789549921449" (table_definitions row already
// stage-1 soft-deleted there) never got its stage-2 physical DROP.
//
// Now that MigrationService._isAlreadyGoneError treats "no such table" as a
// safe no-op instead of a fatal failure, it's safe to author a genuinely
// NEW DROP TABLE migration for the same DDL: hub.db (where the table still
// physically exists) will apply it for real, and any other device that's
// already lost the table the way MIKE-CU did will now no-op instead of
// halting its own pipeline.
//
// Deliberately does NOT reuse SchemaEditorService.dropTable() (that runs
// against essentials_app's own client-side essentials.db, checks physical
// existence *there* first, and would just silently no-op without ever
// authoring anything, since the table is already gone from that copy) --
// same reasoning CLAUDE.md documents for schema_admin's MigrationDao.submit()
// existing as the direct-into-hub.db authoring path. Writes only through
// sqlite_crdt's own API (crdt.execute), never raw sqlite3, so this gets a
// real hlc/node_id/modified and actually syncs out to every other device --
// same discipline as every other tool/*.dart one-time migration script.
//
//   dart run tool/reauthor_script_delete_drop.dart
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

const _hubDbPath = r'C:\Databases\essentials_app\server\hub.db';
const _tableName = 'script_delete_1787789549921449';
const _retractedMigrationId = 1787789550490409;

Future<void> main() async {
  if (!await File(_hubDbPath).exists()) {
    print('REFUSING: no file at $_hubDbPath');
    exitCode = 1;
    return;
  }

  sqfliteFfiInit();
  print('Opening $_hubDbPath ...');
  final crdt = await SqliteCrdt.open(_hubDbPath);
  try {
    final retracted = await crdt.query(
      'SELECT is_deleted FROM migration_log WHERE id = ?1',
      [_retractedMigrationId],
    );
    if (retracted.isEmpty || (retracted.first['is_deleted'] as int) != 1) {
      print('FAIL: expected migration_log id $_retractedMigrationId to be '
          'the already-retracted row this is replacing -- refusing, '
          'something has changed since this script was written.');
      exitCode = 1;
      return;
    }

    final physical = await crdt.query(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
      [_tableName],
    );
    if (physical.isEmpty) {
      print('"$_tableName" is not physically present in hub.db -- nothing to do.');
      return;
    }

    final tableDef = await crdt.query(
      'SELECT is_deleted FROM table_definitions WHERE table_name = ?1',
      [_tableName],
    );
    if (tableDef.isEmpty || (tableDef.first['is_deleted'] as int) != 1) {
      print('FAIL: table_definitions row for "$_tableName" is not stage-1 '
          'soft-deleted in hub.db -- refusing to author a DROP TABLE for a '
          'table that has not gone through stage 1.');
      exitCode = 1;
      return;
    }

    final ddl = 'DROP TABLE "$_tableName"';
    print('Authoring a fresh migration_log row for: $ddl ...');
    await crdt.execute(
      'INSERT INTO migration_log (sql_text, description, created_at) VALUES (?1, ?2, ?3)',
      [
        ddl,
        'Permanently delete table "$_tableName" (re-authored replacement for '
            'retracted migration $_retractedMigrationId -- see '
            'lib/db/migration_service.dart _isAlreadyGoneError)',
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    print('OK. Restart the server (or wait for its periodic check) to apply it.');
  } finally {
    await crdt.close();
  }
}
