import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../util/sql_identifiers.dart';

/// Small helpers translating sqflite's typed convenience calls (`insert`
/// with `ConflictAlgorithm.replace`, `delete` with an equality `where`) into
/// the raw SQL sqlite_crdt requires -- it only exposes `query`/`execute`,
/// not sqflite's `Database` API. Used across the per-device/settings DAOs,
/// which share the same upsert-by-primary-key and delete-by-equality shapes.
extension SqliteCrdtHelpers on SqliteCrdt {
  /// `INSERT OR REPLACE INTO table (...) VALUES (...)`.
  Future<void> upsert(String table, Map<String, Object?> values) async {
    assertSafeSqlIdentifier(table);
    final columns = values.keys.toList();
    for (final c in columns) {
      assertSafeSqlIdentifier(c);
    }
    final columnList = columns.join(', ');
    final placeholders = List.generate(columns.length, (i) => '?${i + 1}').join(', ');
    await execute(
      'INSERT OR REPLACE INTO $table ($columnList) VALUES ($placeholders)',
      columns.map((c) => values[c]).toList(),
    );
  }

  /// `INSERT INTO table (...) VALUES (...)`, returning the new row's
  /// `last_insert_rowid()` -- `id` is a rowid alias on every real table as
  /// of migrations/005 (see CLAUDE.md "Syncing at the Record Level"), so
  /// this reliably gives the real `id` value.
  Future<int> insertGetId(String table, Map<String, Object?> values) async {
    assertSafeSqlIdentifier(table);
    final columns = values.keys.toList();
    for (final c in columns) {
      assertSafeSqlIdentifier(c);
    }
    final columnList = columns.join(', ');
    final placeholders = List.generate(columns.length, (i) => '?${i + 1}').join(', ');
    await execute(
      'INSERT INTO $table ($columnList) VALUES ($placeholders)',
      columns.map((c) => values[c]).toList(),
    );
    final result = await query('SELECT last_insert_rowid() AS id');
    return result.first['id'] as int;
  }

  /// `DELETE FROM table WHERE col1 = ?1 AND col2 = ?2 ...` from a plain
  /// column->value equality map -- the only shape of `where` this app's
  /// DAOs actually need.
  Future<void> deleteWhere(String table, Map<String, Object?> match) async {
    assertSafeSqlIdentifier(table);
    final columns = match.keys.toList();
    for (final c in columns) {
      assertSafeSqlIdentifier(c);
    }
    final whereClause =
        List.generate(columns.length, (i) => '${columns[i]} = ?${i + 1}').join(' AND ');
    await execute(
      'DELETE FROM $table WHERE $whereClause',
      columns.map((c) => match[c]).toList(),
    );
  }
}
