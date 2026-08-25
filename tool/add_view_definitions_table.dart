// ignore_for_file: avoid_print
// Essentials v2 Phase 3, build-order step 1 -- one-time bootstrap that adds
// the new `view_definitions` infra table to an EXISTING, already-live
// essentials.db. Same chicken-and-egg reasoning as table_definitions/
// field_definitions' own original bootstrap (CLAUDE.md, Essentials v2
// Phase 1): the migration_log/MigrationService pipeline that self-applies
// every *other* schema change can't create the table it needs to record
// what to apply, the first time.
//
// Authors a real `migration_log` row (so the DDL is a normal, synced
// migration going forward -- MIKE-12R and the server pick it up exactly
// like any user-created table's migration would, next time they connect,
// via MigrationService.applyPending on each side) AND applies the DDL to
// THIS device's own essentials.db immediately, in the same spirit as
// SchemaEditorService.createTable's "apply pending immediately" step.
//
//   dart run tool/add_view_definitions_table.dart --path C:\Databases\essentials_app\essentials.db
//
// Idempotent: does nothing (prints and exits 0) if view_definitions already
// physically exists.
import 'dart:io';

import 'package:sqlite_crdt/sqlite_crdt.dart';

const _ddl =
    'CREATE TABLE "view_definitions" (\n'
    '  "view_id"      INTEGER PRIMARY KEY DEFAULT (\n'
    "    CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000\n"
    '    + (abs(random()) % 1000)\n'
    '  ),\n'
    '  "table_name"   TEXT,\n'
    '  "view_type"    TEXT NOT NULL,\n'
    '  "display_name" TEXT NOT NULL,\n'
    '  "position"     INTEGER,\n'
    '  "config"       TEXT,\n'
    '  "created_at"   TEXT NOT NULL\n'
    ')';

Future<void> main(List<String> args) async {
  final path = _argValue(args, '--path') ?? r'C:\Databases\essentials_app\essentials.db';
  // Real mistake made running this against server/hub.db directly (see
  // CLAUDE.md's Phase 3 session write-up): defaulting silently to
  // Platform.localHostname recorded migration_status under this MACHINE's
  // name ("MIKE-CU") even when the target file was the server's hub.db --
  // wrong identity for that peer (server's own device_id is the constant
  // 'server', not a hostname -- see server/bin/migration_service.dart).
  // Worse, re-running this script against an already-bootstrapped db
  // authors a brand-new migration_log row every time (a fresh
  // timestamp+random id), which would then sync out and collide with
  // every other device's own already-applied copy of the identical DDL
  // ("table already exists" -> recorded failed -> halts that device's
  // future migrations, the exact double-authoring poisoning class of bug
  // documented elsewhere in this project). Refusing to guess a device id
  // for anything but the literal default path forces whoever runs this to
  // consciously pass --device-id when targeting hub.db or a pulled device
  // copy, and to check first whether the target already has the table.
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
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'view_definitions'",
    );
    if (existing.isNotEmpty) {
      print('view_definitions already exists -- nothing to do.');
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
        [_ddl, 'Create table "view_definitions" (Phase 3 infra)', createdAt],
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

    final columns = await crdt.query('PRAGMA table_info("view_definitions")');
    final columnNames = [for (final c in columns) c['name'] as String];
    const expectedCrdtColumns = ['is_deleted', 'hlc', 'node_id', 'modified'];
    final missing = [
      for (final expected in expectedCrdtColumns)
        if (!columnNames.contains(expected)) expected,
    ];
    if (missing.isEmpty) {
      print('OK: view_definitions created (${columnNames.length} columns, CRDT columns present).');
      print('This device ($deviceId) is done. The migration_log row will sync to the');
      print('server and MIKE-12R normally next time each connects -- nothing further');
      print('to run by hand on those.');
    } else {
      print('FAIL: view_definitions missing CRDT columns: $missing');
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
