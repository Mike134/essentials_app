// ignore_for_file: avoid_print
// Essentials v2 Phase 7, build order step 2 -- one-time bootstrap that adds
// the new `template_definitions` infra table to an EXISTING, already-live
// essentials.db. Same chicken-and-egg reasoning as table_definitions/
// field_definitions'/view_definitions' own original bootstraps (CLAUDE.md,
// Essentials v2 Phase 1/Phase 3): the migration_log/MigrationService
// pipeline that self-applies every *other* schema change can't create the
// table it needs to record what to apply, the first time.
//
// Authors a real `migration_log` row (so the DDL is a normal, synced
// migration going forward -- MIKE-12R and the server pick it up exactly
// like any user-created table's migration would, next time they connect,
// via MigrationService.applyPending on each side) AND applies the DDL to
// THIS device's own essentials.db immediately, in the same spirit as
// SchemaEditorService.createTable's "apply pending immediately" step.
//
//   dart run tool/add_template_definitions_table.dart --path C:\Databases\essentials_app\essentials.db
//
// Idempotent: does nothing (prints and exits 0) if template_definitions
// already physically exists.
import 'dart:io';

import 'package:sqlite_crdt/sqlite_crdt.dart';

const _ddl =
    'CREATE TABLE "template_definitions" (\n'
    '  "template_id"  INTEGER PRIMARY KEY DEFAULT (\n'
    "    CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000\n"
    '    + (abs(random()) % 1000)\n'
    '  ),\n'
    '  "display_name" TEXT NOT NULL,\n'
    '  "description"  TEXT,\n'
    '  "icon"         TEXT,\n'
    '  "fields_json"  TEXT NOT NULL,\n'
    '  "created_at"   TEXT NOT NULL\n'
    ')';

Future<void> main(List<String> args) async {
  final path = _argValue(args, '--path') ?? r'C:\Databases\essentials_app\essentials.db';
  // Same refusal as add_view_definitions_table.dart's own -- see that
  // file's doc comment for the full reasoning: a wrong device_id (e.g.
  // this machine's own hostname applied against hub.db) poisons
  // migration_status under the wrong peer identity, and re-running this
  // against an already-bootstrapped db authors a brand-new, colliding
  // migration_log row every time.
  final explicitDeviceId = _argValue(args, '--device-id');
  final isDefaultPath = _argValue(args, '--path') == null;
  final deviceId = explicitDeviceId ?? (isDefaultPath ? Platform.localHostname : null);
  if (deviceId == null) {
    print('REFUSING: pass --device-id explicitly when --path targets anything other than');
    print('this machine\'s own essentials.db (e.g. --device-id server for hub.db, or the');
    print('real device_id for a pulled-and-about-to-be-pushed-back device copy).');
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
    final existing = await crdt.query(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'template_definitions'",
    );
    if (existing.isNotEmpty) {
      print('template_definitions already exists -- nothing to do.');
      return;
    }

    // migration_log.id's own DEFAULT expression, injected raw -- same
    // rowid-alias-bypasses-DEFAULT gotcha as every other timestamp+random-id
    // insert in this codebase (see SchemaEditorService._insertMigrationLog).
    String? migrationIdDefault;
    final migrationLogColumns = await crdt.query('PRAGMA table_info("migration_log")');
    for (final column in migrationLogColumns) {
      if (column['name'] == 'id') {
        migrationIdDefault = column['dflt_value'] as String?;
      }
    }

    final createdAt = DateTime.now().toUtc().toIso8601String();
    final columnList = migrationIdDefault == null
        ? 'sql_text, description, created_at'
        : 'id, sql_text, description, created_at';
    final valuesSql = migrationIdDefault == null
        ? '?1, ?2, ?3'
        : '($migrationIdDefault), ?1, ?2, ?3';

    print('Authoring migration_log entry ...');
    await crdt.transaction((txn) async {
      await txn.execute(
        'INSERT INTO migration_log ($columnList) VALUES ($valuesSql)',
        [_ddl, 'Create table "template_definitions" (Phase 7 infra)', createdAt],
      );
    });

    print('Applying DDL to this device ...');
    await crdt.execute('PRAGMA foreign_keys = OFF');
    try {
      await crdt.transaction((txn) async {
        await txn.execute(_ddl);
      });
    } finally {
      await crdt.execute('PRAGMA foreign_keys = ON');
    }

    // Record migration_status for this device -- same shape
    // MigrationService._attempt writes, so a real device's own later
    // applyPending() correctly sees this migration as already succeeded
    // here rather than re-attempting it.
    await crdt.execute(
      "INSERT INTO migration_status (migration_id, device_id, outcome, attempted_at) "
      "SELECT id, ?1, 'succeeded', ?2 FROM migration_log WHERE sql_text = ?3 ORDER BY id DESC LIMIT 1",
      [deviceId, DateTime.now().toUtc().toIso8601String(), _ddl],
    );

    final columns = await crdt.query('PRAGMA table_info("template_definitions")');
    final columnNames = [for (final c in columns) c['name'] as String];
    const expectedCrdtColumns = ['is_deleted', 'hlc', 'node_id', 'modified'];
    final missing = [
      for (final expected in expectedCrdtColumns)
        if (!columnNames.contains(expected)) expected,
    ];
    if (missing.isEmpty) {
      print('OK: template_definitions created (${columnNames.length} columns, CRDT columns present).');
      print('This device ($deviceId) is done. The migration_log row will sync to the');
      print('server and MIKE-12R normally next time each connects -- nothing further');
      print('to run by hand on those.');
    } else {
      print('FAIL: template_definitions missing CRDT columns: $missing');
      exitCode = 1;
    }
  } finally {
    await crdt.close();
  }
}

String? _argValue(List<String> args, String flag) {
  final index = args.indexOf(flag);
  if (index == -1 || index + 1 >= args.length) return null;
  return args[index + 1];
}
