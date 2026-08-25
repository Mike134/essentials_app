// ignore_for_file: avoid_print
// One-time cleanup for a real mistake made while unblocking Essentials v2
// Phase 3 Step 2's real-device verification (see the session write-up):
// tool/add_view_definitions_table.dart was (wrongly) re-run directly
// against hub.db/MIKE-12R's own copies rather than letting the ONE
// canonical row authored on MIKE-CU (id 1787656408781004) sync out
// normally -- each re-run authors a genuinely NEW migration_log row (its
// own timestamp+random id), which would otherwise sync out and collide:
// every other device already has the physical table from its OWN
// bootstrap, so applying a second device's identical CREATE TABLE DDL
// fails ("table already exists"), gets recorded 'failed', and halts
// MigrationService.applyPending's future migrations for that device --
// the exact double-authoring poisoning class of bug this project has hit
// before (CLAUDE.md "Bug 2b").
//
// Fixes a target db (already stopped/isolated, same discipline as every
// prior incident recovery in this project) by:
//   1. Soft-deleting (tombstoning, never a raw hard-delete) the duplicate
//      migration_log row this device wrongly authored for the same DDL.
//   2. Adopting the ONE canonical row (MIKE-CU's original id) under this
//      device's own identity via crdt.upsert -- same pattern
//      MigrationService.fetchFromServer already uses for "this device
//      didn't author it, but needs the same row" -- getting a fresh
//      hlc/node_id here, not copied from MIKE-CU's.
//   3. Recording migration_status as already 'succeeded' for the real
//      device_id WITHOUT re-running the DDL (the physical table already
//      exists here, correctly, from the wrongly-authored row's own
//      earlier application -- re-running would itself fail).
//
//   dart run tool/dedupe_view_definitions_migration.dart --path <db> --device-id <id> --duplicate-id <id>
import 'dart:io';

import 'package:sqlite_crdt/sqlite_crdt.dart';

const _canonicalId = 1787656408781004;
const _canonicalSql =
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
const _canonicalDescription = 'Create table "view_definitions" (Phase 3 infra)';
const _canonicalCreatedAt = '2026-08-25T11:13:28.759480Z';

Future<void> main(List<String> args) async {
  final path = _argValue(args, '--path');
  final deviceId = _argValue(args, '--device-id');
  final duplicateId = int.tryParse(_argValue(args, '--duplicate-id') ?? '');

  if (path == null || deviceId == null || duplicateId == null) {
    print('Usage: dart run tool/dedupe_view_definitions_migration.dart '
        '--path <db> --device-id <id> --duplicate-id <id>');
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
    final dup = await crdt.query(
      'SELECT id, is_deleted FROM migration_log WHERE id = ?1',
      [duplicateId],
    );
    if (dup.isEmpty) {
      print('No migration_log row with id $duplicateId -- nothing to tombstone.');
    } else if ((dup.first['is_deleted'] as int) == 1) {
      print('migration_log row $duplicateId already tombstoned.');
    } else {
      print('Tombstoning duplicate migration_log row $duplicateId ...');
      await crdt.execute('DELETE FROM migration_log WHERE id = ?1', [duplicateId]);
    }

    final existingCanonical = await crdt.query(
      'SELECT id FROM migration_log WHERE id = ?1',
      [_canonicalId],
    );
    if (existingCanonical.isEmpty) {
      print('Adopting the canonical migration_log row ($_canonicalId) under this device...');
      await crdt.execute(
        'INSERT OR REPLACE INTO migration_log (id, sql_text, description, created_at) '
        'VALUES (?1, ?2, ?3, ?4)',
        [_canonicalId, _canonicalSql, _canonicalDescription, _canonicalCreatedAt],
      );
    } else {
      print('Canonical migration_log row ($_canonicalId) already present.');
    }

    final tableExists = await crdt.query(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'view_definitions'",
    );
    if (tableExists.isEmpty) {
      print('FAIL: view_definitions does not physically exist here -- '
          'this script only records status for a table already created.');
      exitCode = 1;
      return;
    }

    print('Recording migration_status: $_canonicalId succeeded for device "$deviceId" ...');
    await crdt.execute(
      'INSERT OR REPLACE INTO migration_status '
      '(migration_id, device_id, outcome, error_message, attempted_at) '
      'VALUES (?1, ?2, ?3, ?4, ?5)',
      [_canonicalId, deviceId, 'succeeded', null, DateTime.now().toUtc().toIso8601String()],
    );

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
