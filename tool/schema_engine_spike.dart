// ignore_for_file: avoid_print
// Phase 1 verification spike -- run with `dart run tool/schema_engine_spike.dart`.
//
// Answers the three open questions from claude/essentials-v2-phase1-design.md
// step 1, against a throwaway scratch database (never touches essentials.db):
//
//   (a) does a double-quoted "key" column survive sqlite_crdt's CREATE TABLE
//       rewrite? (schema.sql's migrations/007 comment says quoting fixes the
//       known sqlparser bug that silently drops a bare `key` column -- this
//       confirms it rather than trusting the note)
//   (b) does sqlite_crdt append its four bookkeeping columns (is_deleted,
//       hlc, node_id, modified) exactly once when a CREATE TABLE statement
//       doesn't already declare them?
//   (c) what happens when a CREATE TABLE statement DOES already declare all
//       four -- skipped, or duplicated? This decides whether
//       SchemaEditorService.createTable's generator should emit them itself
//       or leave them to the rewrite.
//
// Uses a scratch file under the system temp directory, deleted and recreated
// on every run -- never opens or modifies the real essentials.db.
import 'dart:io';

import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

const List<String> _crdtBookkeepingColumns = [
  'is_deleted',
  'hlc',
  'node_id',
  'modified',
];

Future<void> main() async {
  sqfliteFfiInit();

  final scratchPath = join(Directory.systemTemp.path, 'essentials_schema_spike.db');
  await _deleteIfExists(scratchPath);
  await _deleteIfExists('$scratchPath-wal');
  await _deleteIfExists('$scratchPath-shm');

  print('Scratch db: $scratchPath\n');

  final crdt = await SqliteCrdt.open(scratchPath);
  var allPassed = true;

  try {
    // --- Test A: CREATE TABLE with a bare `key` column, unquoted. ---
    // Expected to reproduce the known bug -- confirms the failure mode
    // exists before confirming the fix, rather than assuming the CLAUDE.md
    // note is still accurate on this sqlite_crdt version (^3.0.4).
    print('=== Test A: unquoted "key" column (expected to fail/drop) ===');
    await crdt.execute('CREATE TABLE test_unquoted (id INTEGER PRIMARY KEY, key TEXT, notes TEXT)');
    final unquotedColumns = await _columnNames(crdt, 'test_unquoted');
    print('Columns after CREATE TABLE: $unquotedColumns');
    final unquotedKeySurvived = unquotedColumns.contains('key');
    print(unquotedKeySurvived
        ? 'UNEXPECTED: unquoted "key" column survived -- bug may be fixed in this sqlite_crdt version.'
        : 'CONFIRMED: unquoted "key" column was dropped, matching the known sqlparser bug.');
    print('');

    // --- Test B: CREATE TABLE with a quoted "key" column. ---
    print('=== Test B: quoted "key" column (the mitigation) ===');
    await crdt.execute('CREATE TABLE "test_quoted" ("id" INTEGER PRIMARY KEY, "key" TEXT, "notes" TEXT)');
    final quotedColumns = await _columnNames(crdt, 'test_quoted');
    print('Columns after CREATE TABLE: $quotedColumns');
    final quotedKeySurvived = quotedColumns.contains('key');
    final quotedCrdtCounts = _crdtColumnCounts(quotedColumns);
    print('CRDT bookkeeping column counts: $quotedCrdtCounts');
    final quotedCrdtExactlyOnce = quotedCrdtCounts.values.every((c) => c == 1);

    if (quotedKeySurvived) {
      print('PASS (a): quoted "key" column survived.');
    } else {
      print('FAIL (a): quoted "key" column did NOT survive -- quoting alone is not sufficient.');
      allPassed = false;
    }
    if (quotedCrdtExactlyOnce) {
      print('PASS (b): all four CRDT bookkeeping columns present exactly once.');
    } else {
      print('FAIL (b): CRDT bookkeeping columns not all present exactly once: $quotedCrdtCounts');
      allPassed = false;
    }
    print('');

    // --- Test C: CREATE TABLE that already declares all four CRDT columns. ---
    // Wrapped in try/catch: a first run (2026-08-22, live against sqlite_crdt
    // ^3.0.4) showed the rewrite blindly appends its own four columns without
    // checking whether they're already declared -- SQLite itself then rejects
    // the reconstructed statement with "duplicate column name: is_deleted",
    // an *exception*, not silent duplication. That's itself the answer to
    // the open question (see the print below), but the run must survive it
    // to reach Test D.
    print('=== Test C: CREATE TABLE already declaring all 4 CRDT columns ===');
    try {
      await crdt.execute('''
        CREATE TABLE "test_predeclared" (
          "id" INTEGER PRIMARY KEY,
          "notes" TEXT,
          "is_deleted" INTEGER DEFAULT 0,
          "hlc" TEXT NOT NULL,
          "node_id" TEXT NOT NULL,
          "modified" TEXT NOT NULL
        )
      ''');
      final predeclaredColumns = await _columnNames(crdt, 'test_predeclared');
      print('Columns after CREATE TABLE: $predeclaredColumns');
      final predeclaredCrdtCounts = _crdtColumnCounts(predeclaredColumns);
      print('CRDT bookkeeping column counts: $predeclaredCrdtCounts');
      final predeclaredExactlyOnce = predeclaredCrdtCounts.values.every((c) => c == 1);
      final predeclaredAnyDoubled = predeclaredCrdtCounts.values.any((c) => c > 1);

      if (predeclaredExactlyOnce) {
        print('RESULT (c): pre-declared columns were recognized, NOT duplicated. '
            '=> generator SHOULD emit the four CRDT columns itself (or it is at least safe to).');
      } else if (predeclaredAnyDoubled) {
        print('RESULT (c): pre-declared columns were DUPLICATED (e.g. "hlc", "hlc:1", or similar). '
            '=> generator must NOT emit the four CRDT columns itself -- let the rewrite add them.');
        allPassed = false;
      } else {
        print('RESULT (c): unexpected column shape -- inspect manually: $predeclaredColumns');
        allPassed = false;
      }
    } catch (e) {
      print('RESULT (c): CREATE TABLE THREW rather than silently duplicating: $e');
      print('=> generator must NOT emit the four CRDT columns itself -- predeclaring them '
          'does not risk duplicate columns, it makes the CREATE TABLE fail outright. '
          'Confirmed FAIL-loud, not silent corruption -- treat as a hard rule, not a guess.');
      allPassed = false;
    }
    print('');

    // --- Confirm ALTER TABLE ADD COLUMN also survives a quoted `key`-like name. ---
    print('=== Test D: ALTER TABLE ADD COLUMN with a quoted reserved-ish name ===');
    await crdt.execute('ALTER TABLE "test_quoted" ADD COLUMN "order" TEXT');
    final alteredColumns = await _columnNames(crdt, 'test_quoted');
    print('Columns after ALTER TABLE: $alteredColumns');
    if (alteredColumns.contains('order')) {
      print('PASS (d): quoted "order" column added via ALTER TABLE survived.');
    } else {
      print('FAIL (d): quoted "order" column did NOT survive ALTER TABLE ADD COLUMN.');
      allPassed = false;
    }
    print('');

    print(allPassed
        ? 'SPIKE PASSED: quoting mitigation confirmed; see Test C result above for generator design.'
        : 'SPIKE FOUND ISSUES: see FAIL lines above before writing SchemaEditorService.createTable.');
  } finally {
    await crdt.close();
  }
}

Future<List<String>> _columnNames(SqliteCrdt crdt, String tableName) async {
  final rows = await crdt.query('PRAGMA table_info("$tableName")');
  return [for (final row in rows) row['name'] as String];
}

Map<String, int> _crdtColumnCounts(List<String> columns) {
  return {
    for (final name in _crdtBookkeepingColumns)
      name: columns.where((c) => c == name).length,
  };
}

Future<void> _deleteIfExists(String path) async {
  final file = File(path);
  if (await file.exists()) {
    await file.delete();
  }
}
