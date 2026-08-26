// ignore_for_file: avoid_print
// Essentials v2 Phase 1, build-order step 2 -- creates a FRESH, EMPTY
// essentials.db containing only infra/bookkeeping tables.
//
//   dart run tool/bootstrap_fresh_db.dart --out C:\Databases\essentials_app\essentials.db
//   dart run tool/bootstrap_fresh_db.dart --out .\mike-12r-essentials.db --reset-node-id
//
// Deliberately creates NO business tables. Per claude/essentials-v2-phase1-design.md's
// clean-slate directive, `domain`, `subscription`, `journal` etc. do not come back
// automatically -- they get created through the app's own New Table UI, whenever
// Mike wants them, like any table he'd never had before.
//
// CRITICAL -- CRDT bookkeeping columns are NEVER declared here.
// Verified live 2026-08-22 (tool/schema_engine_spike.dart, sqlite_crdt ^3.0.4):
// sqlite_crdt's CREATE TABLE rewrite blindly appends its own is_deleted/hlc/
// node_id/modified without checking whether the statement already declares
// them. Predeclaring even one does not produce a duplicate column -- SQLite
// rejects the reconstructed statement outright ("duplicate column name:
// is_deleted") and the whole CREATE TABLE fails. Every statement below
// declares only its own real columns and lets the rewrite do the rest, exactly
// as server/bin/server.dart's schemaStatements already does.
//
// Every identifier is double-quoted -- the same spike confirmed the known
// sqlparser bug (a bare `key` column is silently dropped, along with any
// PRIMARY KEY constraint referencing it) is still live on this version, and
// that quoting is a complete mitigation.
import 'dart:io';

import 'package:sqlite_crdt/sqlite_crdt.dart';

/// Infra/bookkeeping tables only -- no business tables, by design.
///
/// Kept byte-for-byte in sync with server/bin/server.dart's `schemaStatements`
/// (minus nothing -- after Phase 1 the two lists are identical, since the
/// server no longer bootstraps business tables either). Duplicated rather than
/// shared because server/ is a separate Dart package -- same reasoning as
/// `safeChangesetBuilder` and `splitSqlStatements` already being duplicated.
const infraSchemaStatements = <String>[
  // sqflite_common_ffi's own internal table. Not part of this app's design,
  // but Android's sqflite creates it locally and the sync layer doesn't
  // distinguish business tables from anything else -- without a structural
  // counterpart on every peer, merging its changeset fails (found live against
  // the real server, see server.dart's own comment). `locale` is a real
  // PRIMARY KEY, not bare -- per migrations/006.
  '''
    CREATE TABLE "android_metadata" (
      "locale" TEXT PRIMARY KEY
    )
  ''',

  // ---------- Dynamic schema metadata (NEW in v2 Phase 1) ----------
  // The heart of the dynamic schema engine. One row per user-visible table.
  // `table_name` is the physical SQLite identifier and is IMMUTABLE once
  // created; only `display_name` ever changes. That single rule is what makes
  // rename/delete/reorder pure metadata operations with zero DDL.
  '''
    CREATE TABLE "table_definitions" (
      "table_name"     TEXT PRIMARY KEY,
      "display_name"   TEXT NOT NULL,
      "description"    TEXT,
      "icon"           TEXT,
      "display_field"  TEXT,
      "order_by"       TEXT,
      "position"       INTEGER,
      "created_at"     TEXT NOT NULL,
      "calendar_field" TEXT
    )
  ''',
  // One row per field. Supersedes v1's `field_metadata` entirely -- that table
  // held only the policy half (label, default, lookup display column) and
  // derived the structural half from PRAGMA introspection. This holds both, so
  // `field_metadata` is NOT created here.
  //
  // `format` is a presentation/input hint, never a storage constraint --
  // every user field's physical column is TEXT. `options` is JSON (format
  // mask, currency symbol, select source table + display field, on_delete,
  // etc.).
  '''
    CREATE TABLE "field_definitions" (
      "table_name"    TEXT NOT NULL,
      "field_name"    TEXT NOT NULL,
      "display_name"  TEXT NOT NULL,
      "format"        TEXT NOT NULL,
      "options"       TEXT,
      "default_value" TEXT,
      "required"      INTEGER NOT NULL DEFAULT 0,
      "position"      INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY ("table_name", "field_name")
    )
  ''',

  // ---------- Per-device table view state ----------
  '''
    CREATE TABLE "table_column_settings" (
      "table_name"    TEXT NOT NULL,
      "device_id"     TEXT NOT NULL,
      "column_name"   TEXT NOT NULL,
      "width"         REAL,
      "display_order" INTEGER,
      "visible"       INTEGER NOT NULL DEFAULT 1,
      "frozen"        TEXT,
      "wrap_text"     INTEGER NOT NULL DEFAULT 0,
      "aggregate"     TEXT,
      PRIMARY KEY ("table_name", "device_id", "column_name")
    )
  ''',
  '''
    CREATE TABLE "table_view_settings" (
      "table_name"       TEXT NOT NULL,
      "device_id"        TEXT NOT NULL,
      "sort_column"      TEXT,
      "sort_direction"   TEXT,
      "filter_json"      TEXT,
      "group_column"     TEXT,
      "row_color_column" TEXT,
      PRIMARY KEY ("table_name", "device_id")
    )
  ''',

  // ---------- App/device settings, groups ----------
  // `setting_key`, never a bare `key` -- migrations/007 renamed it precisely
  // because of the sqlparser bug this file's header describes. Quoting would
  // also fix it now, but the rename stands so no future fresh CREATE TABLE
  // depends on remembering to quote.
  '''
    CREATE TABLE "app_settings" (
      "setting_key" TEXT PRIMARY KEY,
      "value"       TEXT
    )
  ''',
  '''
    CREATE TABLE "device_settings" (
      "device_id"   TEXT NOT NULL,
      "setting_key" TEXT NOT NULL,
      "value"       TEXT,
      PRIMARY KEY ("device_id", "setting_key")
    )
  ''',
  '''
    CREATE TABLE "table_group" (
      "table_name"     TEXT PRIMARY KEY,
      "group_name"     TEXT NOT NULL,
      "group_position" INTEGER
    )
  ''',

  // ---------- Views (Essentials v2 Phase 3) ----------
  // Saved List/Kanban (per-table, table_name set) / Calendar (aggregate,
  // table_name NULL) views -- shared/synced, same bucket as
  // table_definitions/field_definitions. `view_id` is the timestamp+random
  // scheme, not AUTOINCREMENT, same collision-avoidance reasoning as
  // migration_log.id. MUST stay identical to schema.sql / server/bin/
  // server.dart's schemaStatements.
  '''
    CREATE TABLE "view_definitions" (
      "view_id"      INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
      ),
      "table_name"   TEXT,
      "view_type"    TEXT NOT NULL,
      "display_name" TEXT NOT NULL,
      "position"     INTEGER,
      "config"       TEXT,
      "created_at"   TEXT NOT NULL
    )
  ''',

  // ---------- Templates (Essentials v2 Phase 7) ----------
  // User-saved templates only -- built-in templates are a compiled Dart
  // catalog (lib/models/builtin_templates.dart), never rows here. See
  // claude/essentials-v2-phase7-design.md, "Data model". `template_id` is
  // the timestamp+random scheme, same collision-avoidance reasoning as
  // migration_log.id/view_definitions.view_id. MUST stay identical to
  // schema.sql / server/bin/server.dart's schemaStatements.
  '''
    CREATE TABLE "template_definitions" (
      "template_id"  INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
      ),
      "display_name" TEXT NOT NULL,
      "description"  TEXT,
      "icon"         TEXT,
      "fields_json"  TEXT NOT NULL,
      "created_at"   TEXT NOT NULL
    )
  ''',

  // ---------- Schema migration system ----------
  // `id` is the timestamp+random scheme, NOT AUTOINCREMENT -- changed for v2.
  // v1's AUTOINCREMENT was safe only because migrations were authored from
  // exactly one place (schema_admin on MIKE-CU). Phase 1 breaks that: any
  // device can create a table, so any device authors migration_log rows.
  // AUTOINCREMENT is max(existing)+1, so two devices both synced through
  // migration N will BOTH deterministically pick N+1 -- and since `id` is the
  // primary key, CRDT merges the two rows into one and silently loses a
  // migration. Not a microsecond race; the window is the whole sync interval.
  '''
    CREATE TABLE "migration_log" (
      "id" INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
      ),
      "sql_text"    TEXT NOT NULL,
      "description" TEXT,
      "created_at"  TEXT NOT NULL
    )
  ''',
  '''
    CREATE TABLE "migration_status" (
      "migration_id"  INTEGER NOT NULL REFERENCES "migration_log"("id"),
      "device_id"     TEXT NOT NULL,
      "outcome"       TEXT NOT NULL,
      "error_message" TEXT,
      "attempted_at"  TEXT,
      PRIMARY KEY ("migration_id", "device_id")
    )
  ''',
];

/// Columns sqlite_crdt appends to every table via its CREATE TABLE rewrite.
/// Verified after creation, not assumed -- this script's whole correctness
/// rests on the rewrite having done its job.
const _expectedCrdtColumns = ['is_deleted', 'hlc', 'node_id', 'modified'];

Future<void> main(List<String> args) async {
  final outPath = _argValue(args, '--out');
  final force = args.contains('--force');
  final resetNodeId = args.contains('--reset-node-id');

  if (outPath == null) {
    print('Usage: dart run tool/bootstrap_fresh_db.dart --out <path> '
        '[--force] [--reset-node-id]');
    print('');
    print('  --out            Target .db path to create.');
    print('  --force          Delete an existing file at that path first.');
    print('  --reset-node-id  Call SqliteCrdt.resetNodeId() after creating.');
    print('                   Use ONLY for a copy destined for another device');
    print('                   (see the node_id gotcha in CLAUDE.md).');
    exitCode = 64;
    return;
  }

  final file = File(outPath);
  if (await file.exists()) {
    if (!force) {
      print('REFUSING: $outPath already exists. Pass --force to delete and recreate it.');
      print('Make sure you have a backup -- this is destructive and there is no undo.');
      exitCode = 1;
      return;
    }
    print('Deleting existing $outPath (--force)...');
    await file.delete();
    for (final suffix in ['-wal', '-shm']) {
      final sidecar = File('$outPath$suffix');
      if (await sidecar.exists()) await sidecar.delete();
    }
  }

  await Directory(file.parent.path).create(recursive: true);

  print('Creating fresh database: $outPath');
  final crdt = await SqliteCrdt.open(outPath);
  var ok = true;

  try {
    await crdt.execute('PRAGMA foreign_keys = ON');

    for (final statement in infraSchemaStatements) {
      await crdt.execute(statement);
    }

    // Verify: every table exists, and the rewrite appended all four CRDT
    // columns to each. A silent failure here would produce a database that
    // opens fine but can never sync.
    final tables = await crdt.query(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    print('');
    print('Created ${tables.length} tables:');
    for (final row in tables) {
      final name = row['name'] as String;
      final columns = await crdt.query('PRAGMA table_info("$name")');
      final columnNames = [for (final c in columns) c['name'] as String];
      final missing = [
        for (final expected in _expectedCrdtColumns)
          if (!columnNames.contains(expected)) expected,
      ];
      if (missing.isEmpty) {
        print('  OK   $name (${columnNames.length} columns, CRDT columns present)');
      } else {
        print('  FAIL $name -- missing CRDT columns: $missing');
        print('       columns present: $columnNames');
        ok = false;
      }
    }

    if (resetNodeId) {
      print('');
      print('Resetting node id (--reset-node-id)...');
      final before = crdt.nodeId;
      await crdt.resetNodeId();
      print('  node id: $before -> ${crdt.nodeId}');
      print('  This copy is now safe to push to another device.');
    } else {
      print('');
      print('Node id: ${crdt.nodeId}');
      print('  NOT reset. If you intend to copy this file to another device,');
      print('  re-run with --reset-node-id against that copy first -- two');
      print('  devices sharing a node id silently breaks sync propagation.');
    }
  } finally {
    await crdt.close();
  }

  print('');
  print(ok
      ? 'BOOTSTRAP OK: fresh infra-only database ready at $outPath'
      : 'BOOTSTRAP FAILED: see FAIL lines above. Do not use this file.');
  if (!ok) exitCode = 1;
}

String? _argValue(List<String> args, String flag) {
  final index = args.indexOf(flag);
  if (index == -1 || index + 1 >= args.length) return null;
  return args[index + 1];
}
