import 'package:sqflite/sqflite.dart';

import '../models/table_config.dart';
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
      config.tableName,
      orderBy: config.orderBy ?? config.displayColumn,
    );
  }

  Future<int> insert(Map<String, Object?> values) async {
    final db = await _db;
    return db.insert(config.tableName, values);
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

  Future<List<Map<String, Object?>>> getLookupOptions(LookupConfig lookup) async {
    final db = await _db;
    return db.query(
      lookup.table,
      columns: [lookup.valueColumn, lookup.displayColumn],
      orderBy: lookup.displayColumn,
    );
  }
}
