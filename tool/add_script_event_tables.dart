// ignore_for_file: avoid_print
// Essentials v2 Phase 5, build order step 1 -- one-time bootstrap that adds
// the new `script_definitions`/`event_definitions` infra tables to an
// EXISTING, already-live essentials.db. Same chicken-and-egg reasoning as
// table_definitions/field_definitions'/view_definitions'/
// template_definitions' own original bootstraps (CLAUDE.md, Essentials v2
// Phase 1/3/7): the migration_log/MigrationService pipeline that
// self-applies every *other* schema change can't create the tables it
// needs to record what to apply, the first time.
//
// Authors ONE `migration_log` row holding both CREATE TABLE statements (a
// whole related-tables script is a single row -- see migration_log's own
// doc comment in schema.sql) so the DDL is a normal, synced migration going
// forward -- MIKE-12R and the server pick it up exactly like any
// user-created table's migration would, next time they connect, via
// MigrationService.applyPending on each side -- AND applies the DDL to THIS
// device's own essentials.db immediately, in the same spirit as
// SchemaEditorService.createTable's "apply pending immediately" step.
//
//   dart run tool/add_script_event_tables.dart --path C:\Databases\essentials_app\essentials.db
//
// Idempotent: does nothing (prints and exits 0) if script_definitions
// already physically exists.
import 'dart:io';

import 'package:sqlite_crdt/sqlite_crdt.dart';

const _scriptDefinitionsDdl =
    'CREATE TABLE "script_definitions" (\n'
    '  "id" INTEGER PRIMARY KEY DEFAULT (\n'
    "    CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000\n"
    '    + (abs(random()) % 1000)\n'
    '  ),\n'
    '  "name"        TEXT NOT NULL,\n'
    '  "code"        TEXT NOT NULL,\n'
    '  "description" TEXT\n'
    ')';

const _eventDefinitionsDdl =
    'CREATE TABLE "event_definitions" (\n'
    '  "id" INTEGER PRIMARY KEY DEFAULT (\n'
    "    CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000\n"
    '    + (abs(random()) % 1000)\n'
    '  ),\n'
    '  "script_id"       INTEGER NOT NULL,\n'
    '  "event_type"      TEXT NOT NULL,\n'
    '  "table_name"      TEXT,\n'
    '  "field_name"      TEXT,\n'
    '  "schedule_config" TEXT,\n'
    '  "enabled"         INTEGER NOT NULL DEFAULT 1\n'
    ')';

const _combinedDdl = '$_scriptDefinitionsDdl;\n$_eventDefinitionsDdl';

Future<void> main(List<String> args) async {
  final path = _argValue(args, '--path') ?? r'C:\Databases\essentials_app\essentials.db';
  // Same refusal as add_view_definitions_table.dart/add_template_definitions_table.dart's
  // own -- see those files' doc comments for the full reasoning: a wrong
  // device_id (e.g. this machine's own hostname applied against hub.db)
  // poisons migration_status under the wrong peer identity, and re-running
  // this against an already-bootstrapped db authors a brand-new, colliding
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
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'script_definitions'",
    );
    if (existing.isNotEmpty) {
      print('script_definitions already exists -- nothing to do.');
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
        [
          _combinedDdl,
          'Create tables "script_definitions"/"event_definitions" (Phase 5 infra)',
          createdAt,
        ],
      );
    });

    print('Applying DDL to this device ...');
    await crdt.execute('PRAGMA foreign_keys = OFF');
    try {
      await crdt.transaction((txn) async {
        await txn.execute(_scriptDefinitionsDdl);
        await txn.execute(_eventDefinitionsDdl);
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
      [deviceId, DateTime.now().toUtc().toIso8601String(), _combinedDdl],
    );

    var allOk = true;
    for (final table in ['script_definitions', 'event_definitions']) {
      final columns = await crdt.query('PRAGMA table_info("$table")');
      final columnNames = [for (final c in columns) c['name'] as String];
      const expectedCrdtColumns = ['is_deleted', 'hlc', 'node_id', 'modified'];
      final missing = [
        for (final expected in expectedCrdtColumns)
          if (!columnNames.contains(expected)) expected,
      ];
      if (missing.isEmpty) {
        print('OK: $table created (${columnNames.length} columns, CRDT columns present).');
      } else {
        print('FAIL: $table missing CRDT columns: $missing');
        allOk = false;
      }
    }
    if (allOk) {
      print('This device ($deviceId) is done. The migration_log row will sync to the');
      print('server and MIKE-12R normally next time each connects -- nothing further');
      print('to run by hand on those.');
    } else {
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
