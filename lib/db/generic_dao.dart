import 'package:sqflite/sqflite.dart';

import '../models/table_config.dart';
import '../util/sql_identifiers.dart';
import 'database_helper.dart';

/// Thrown by [GenericDao.delete] when the row is still referenced by an
/// `ON DELETE RESTRICT` foreign key elsewhere -- the project default for
/// every FK (see CLAUDE.md "Parent-child relationships"). The UI should
/// show this message rather than letting the raw SQLite constraint error
/// surface or crash the app.
class StillInUseException implements Exception {
  StillInUseException(this.tableName);

  final String tableName;

  @override
  String toString() =>
      "Can't delete -- this $tableName record is still in use by other records.";
}

/// CRUD operations for a single table, driven entirely by a [TableConfig].
/// One instance per screen; no per-table subclassing needed for batch 1/2.
class GenericDao {
  GenericDao(this.config);

  final TableConfig config;

  Future<Database> get _db async => DatabaseHelper.instance.database;

  Future<List<Map<String, Object?>>> getAll() async {
    final db = await _db;
    return db.query(
      config.readSource ?? config.tableName,
      where: config.filterWhere,
      whereArgs: config.filterArgs,
      orderBy: config.orderBy ?? config.displayColumn,
    );
  }

  /// Inserts a new row and returns its real `id` column value. Not simply
  /// [Database.insert]'s own return value -- that's the internal SQLite
  /// rowid, which only equals `id` for the older `id INTEGER PRIMARY KEY
  /// AUTOINCREMENT` tables (where `id` is a rowid alias). For the newer
  /// timestamp+random `id` scheme (`orders`/`order_items`, and now
  /// `journal`/`shipment`/`subscription` -- see CLAUDE.md "id convention
  /// changed"), `id` is declared UNIQUE, not PRIMARY KEY, so it is *not* a
  /// rowid alias and the two values diverge. Re-reading `id` by rowid
  /// immediately after the insert, inside the same transaction, gives the
  /// real value under either scheme.
  Future<int> insert(Map<String, Object?> values) async {
    final db = await _db;
    return db.transaction((txn) async {
      final rowId = await txn.insert(config.tableName, values);
      final result = await txn.query(
        config.tableName,
        columns: ['id'],
        where: 'rowid = ?',
        whereArgs: [rowId],
      );
      return result.first['id'] as int;
    });
  }

  Future<int> update(int id, Map<String, Object?> values) async {
    final db = await _db;
    return db.update(config.tableName, values, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> delete(int id) async {
    final db = await _db;
    try {
      await db.delete(config.tableName, where: 'id = ?', whereArgs: [id]);
    } on DatabaseException catch (e) {
      // sqflite_common has no isForeignKeyConstraintError() helper (only
      // isUniqueConstraintError/isNotNullConstraintError/etc.) -- match the
      // raw SQLite message directly, same technique those helpers use.
      if (e.toString().toLowerCase().contains('foreign key constraint failed')) {
        throw StillInUseException(config.tableName);
      }
      rethrow;
    }
  }

  /// Every other real table that still holds at least one row referencing
  /// (this row's id) via a non-`CASCADE` foreign key -- i.e. exactly what
  /// would block [delete] today via SQLite's own `RESTRICT` enforcement.
  /// `CASCADE` FKs are deliberately excluded (e.g. `order_items.order_id`
  /// -> `orders`) -- those are expected to cascade, not a reason to block
  /// (see CLAUDE.md "Parent-child (one-to-many) relationships").
  ///
  /// Checked by [GenericListScreen] *before* showing a delete confirmation,
  /// rather than only discovering the block after the user already clicked
  /// Delete (the [StillInUseException] path above, still kept as a
  /// defensive fallback for a same-instant race -- e.g. another device
  /// syncing in a new referencing row between this check and the actual
  /// delete). A confirm dialog that implies success is possible when it
  /// structurally isn't is worse than no upfront confirmation at all --
  /// found by Mike deleting a `supplier` still referenced by `shipment`/
  /// `orders`.
  Future<List<String>> findBlockingReferences(int id) async {
    final db = await _db;
    final tableName = config.tableName;
    final allTables = await db.query(
      'sqlite_master',
      columns: ['name'],
      where: 'type = ?',
      whereArgs: ['table'],
    );

    final blockers = <String>{};
    for (final row in allTables) {
      final otherTable = row['name'] as String;
      if (otherTable == tableName) continue;
      assertSafeSqlIdentifier(otherTable);

      final foreignKeys = await db.rawQuery('PRAGMA foreign_key_list("$otherTable")');
      for (final fk in foreignKeys) {
        if (fk['table'] != tableName) continue;
        if ((fk['on_delete'] as String).toUpperCase() == 'CASCADE') continue;

        final fromColumn = fk['from'] as String;
        assertSafeSqlIdentifier(fromColumn);
        final count = Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM "$otherTable" WHERE "$fromColumn" = ?',
            [id],
          ),
        );
        if ((count ?? 0) > 0) {
          blockers.add(otherTable);
          break;
        }
      }
    }
    return blockers.toList()..sort();
  }

  Future<List<Map<String, Object?>>> getLookupOptions(LookupConfig lookup) async {
    final db = await _db;
    return db.query(
      lookup.table,
      columns: [lookup.valueColumn, lookup.displayColumn],
      orderBy: lookup.displayColumn,
    );
  }
}
