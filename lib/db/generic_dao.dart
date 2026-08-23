import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../models/table_config.dart';
import '../util/field_options.dart';
import '../util/sql_identifiers.dart';
import 'database_helper.dart';

/// Thrown by [GenericDao.delete] when the row is still referenced by an
/// `ON DELETE RESTRICT` foreign key elsewhere -- the project default for
/// every FK (see CLAUDE.md "Parent-child relationships"). The UI should
/// show this message rather than letting a raw SQL error surface or crash
/// the app. Since sqlite_crdt rewrites every DELETE into a soft-delete
/// UPDATE (see CLAUDE.md "Syncing at the Record Level"), SQLite's own FK
/// enforcement never actually fires through this pathway anymore --
/// [findBlockingReferences] (checked *before* attempting a delete) is now
/// the real enforcement, not this exception. This stays only as a
/// same-instant-race fallback and is unlikely to ever fire in practice.
class StillInUseException implements Exception {
  StillInUseException(this.tableName);

  final String tableName;

  @override
  String toString() =>
      "Can't delete -- this $tableName record is still in use by other records.";
}

/// One other real table's `select`/linked field pointing at
/// [GenericDao.config]'s table -- Essentials v2 Phase 1's replacement for
/// a real declared SQL foreign key, since no v2 table ever declares one
/// (see claude/essentials-v2-phase1-design.md, "Critical risks" #3).
/// [onDelete] is `field_definitions.options.on_delete`, defaulting to
/// `'RESTRICT'` when unset -- matches this project's long-standing
/// default posture (every relationship blocks deletion unless explicitly
/// marked otherwise; see CLAUDE.md "Parent-child (one-to-many)
/// relationships").
class _LinkedFieldRef {
  _LinkedFieldRef(this.table, this.column, this.onDelete);

  final String table;
  final String column;
  final String onDelete;
}

/// CRUD operations for a single table, driven entirely by a [TableConfig].
/// One instance per screen; no per-table subclassing needed for batch 1/2.
///
/// Reads through sqlite_crdt via raw SQL (it has no sqflite-style typed
/// query/insert/update/delete API -- only `query(sql, args)` and
/// `execute(sql, args)`), and every read filters `is_deleted = 0` -- rows
/// are never really removed by sqlite_crdt, only tombstoned, so an
/// unfiltered read would show deleted rows again.
class GenericDao {
  GenericDao(this.config);

  final TableConfig config;

  Future<SqliteCrdt> get _crdt async => DatabaseHelper.instance.crdt;

  Future<List<Map<String, Object?>>> getAll() async {
    final crdt = await _crdt;
    final source = config.readSource ?? config.tableName;
    assertSafeSqlIdentifier(source);

    final args = <Object?>[];
    var where = 'is_deleted = 0';
    if (config.filterWhere != null) {
      where = '$where AND (${config.filterWhere})';
      args.addAll(config.filterArgs ?? const []);
    }

    final orderBy = config.orderBy ?? config.displayColumn;

    // Plain `?` placeholders, not explicitly numbered -- sqlite_crdt
    // auto-numbers every bare `?` in a statement by encounter order (see
    // SqlUtil.transformAutomaticExplicit), so this composes correctly with
    // config.filterWhere's own bare-`?` convention without this method
    // needing to know how many placeholders came before it.
    return crdt.query(
      'SELECT * FROM $source WHERE $where ORDER BY $orderBy',
      args,
    );
  }

  /// Inserts a new row and returns its real `id` column value. `id` is a
  /// rowid alias on every real table as of the "Syncing at the Record
  /// Level" id-scheme migration (`INTEGER PRIMARY KEY DEFAULT (...)` or
  /// `INTEGER PRIMARY KEY AUTOINCREMENT`, never bare `UNIQUE` anymore), so
  /// `last_insert_rowid()` inside the same transaction reliably gives the
  /// real value -- see migrations/005_entity_id_scheme_and_crdt_columns.sql.
  ///
  /// One real subtlety this method exists to paper over: SQLite's rowid
  /// -alias auto-assignment (next available rowid) fires whenever `id` is
  /// *omitted* from an INSERT's column list, completely bypassing the
  /// column's own SQL `DEFAULT` clause -- confirmed empirically, not from
  /// docs alone, after this was caught by generic_dao_insert_id_test.dart
  /// actually failing (id came back `2`, not a large timestamp+random
  /// value). Every FieldConfig-driven insert always omits `id` (it's never
  /// user-edited), so without this, every *new* row on the five
  /// timestamp+random-id tables would silently get a small sequential id
  /// instead -- exactly the collision-avoidance property that scheme
  /// exists for. Fix: look up `id`'s own `DEFAULT` expression via `PRAGMA
  /// table_info` and inject it verbatim as a real SQL expression (not a
  /// bound value) in the INSERT when `id` isn't already in [values] --
  /// re-uses whatever schema.sql actually says rather than duplicating the
  /// formula in Dart, so it can't drift. A plain `AUTOINCREMENT` table (no
  /// per-column `dflt_value` -- AUTOINCREMENT is a PRIMARY KEY-level
  /// keyword, not a column DEFAULT) is unaffected: `id` stays omitted and
  /// SQLite's normal auto-assignment is exactly what's wanted there.
  Future<int> insert(Map<String, Object?> values) async {
    final crdt = await _crdt;
    final idDefault = values.containsKey('id') ? null : await _idDefaultExpression(crdt);

    // crdt.transaction()'s callback is Future<void> -- unlike sqflite's
    // generic db.transaction<T>(), it can't return a value directly, so the
    // id is captured into this local instead.
    late final int id;
    await crdt.transaction((txn) async {
      final columns = values.keys.toList();
      for (final c in columns) {
        assertSafeSqlIdentifier(c);
      }

      if (columns.isEmpty && idDefault == null) {
        // No explicit field values and no id DEFAULT to inject -- a plain
        // AUTOINCREMENT table with zero other columns. Genuinely reachable
        // in Essentials v2: a table created via SchemaEditorService
        // .createTable with no addField calls yet has no FieldConfig
        // entries at all, so an "Add" on it inserts nothing but `id`.
        // `INSERT INTO t () VALUES ()` isn't valid SQL, and SQLite's own
        // all-default-row syntax (`INSERT INTO t DEFAULT VALUES`) isn't
        // supported by sql_crdt itself -- confirmed live, not assumed:
        // `CrdtWriteExecutor._insert` asserts `targetColumns.isNotEmpty`
        // ("target columns must be explicitly stated"), since it needs an
        // explicit column list to know where to splice in its own
        // is_deleted/hlc/node_id/modified values. Explicitly inserting
        // `NULL` into `id` is SQLite's own documented equivalent to
        // omitting it for a plain rowid-alias column (still triggers
        // normal auto-assignment) while satisfying sql_crdt's requirement.
        // Found live by generic_dao_linked_fields_test.dart's fieldless
        // parent tables, not a v1 case (every v1 table always had real
        // business columns).
        await txn.execute('INSERT INTO ${config.tableName} (id) VALUES (NULL)');
      } else {
        final columnNames = [if (idDefault != null) 'id', ...columns];
        final valueExpressions = [
          if (idDefault != null) '($idDefault)',
          ...List.generate(columns.length, (i) => '?${i + 1}'),
        ];
        await txn.execute(
          'INSERT INTO ${config.tableName} (${columnNames.join(', ')}) '
          'VALUES (${valueExpressions.join(', ')})',
          columns.map((c) => values[c]).toList(),
        );
      }

      final result = await txn.query('SELECT last_insert_rowid() AS id');
      id = result.first['id'] as int;
    });
    return id;
  }

  /// [config.tableName]'s `id` column's own SQL `DEFAULT` expression text
  /// (e.g. the timestamp+random generator), or `null` for a plain
  /// `AUTOINCREMENT` table (no per-column default -- AUTOINCREMENT lives on
  /// the `PRIMARY KEY` constraint itself, not `dflt_value`) or any table
  /// with no `id` column at all.
  Future<String?> _idDefaultExpression(SqliteCrdt crdt) async {
    assertSafeSqlIdentifier(config.tableName);
    final columns = await crdt.query('PRAGMA table_info("${config.tableName}")');
    for (final column in columns) {
      if (column['name'] == 'id') return column['dflt_value'] as String?;
    }
    return null;
  }

  Future<void> update(int id, Map<String, Object?> values) async {
    final crdt = await _crdt;
    final columns = values.keys.toList();
    for (final c in columns) {
      assertSafeSqlIdentifier(c);
    }
    final setClause =
        List.generate(columns.length, (i) => '${columns[i]} = ?${i + 1}').join(', ');

    await crdt.execute(
      'UPDATE ${config.tableName} SET $setClause WHERE id = ?${columns.length + 1}',
      [...columns.map((c) => values[c]), id],
    );
  }

  /// Deletes the row, cascading explicitly to any child rows a
  /// `field_definitions.options.on_delete = 'cascade'` linked field
  /// declares (e.g. an `order_items`-shaped table's `order_id` field
  /// pointing at `orders`) -- no v2 table ever declares a real SQL FK, so
  /// there is nothing for SQLite's own cascade to fire on; this is the
  /// actual enforcement, not a formality (same as it already was for the
  /// v1 `PRAGMA`-declared-FK path this replaces -- see CLAUDE.md "Syncing
  /// at the Record Level"). Single-level only -- extend recursively if a
  /// table ever needs its own CASCADE children.
  ///
  /// [findBlockingReferences] should always be checked by the caller before
  /// this is reached (see [GenericListScreen]) -- the [StillInUseException]
  /// catch here is only a defensive fallback (a hand-created table outside
  /// this app's own schema engine could still declare a real SQL FK) and
  /// unlikely to actually fire for anything created through
  /// [SchemaEditorService.createTable].
  Future<void> delete(int id) async {
    final crdt = await _crdt;
    try {
      await crdt.transaction((txn) async {
        // Deliberately queries via txn, not the parent crdt -- sql_crdt's
        // own transaction() doc comment warns that calling back into the
        // parent crdt from inside a transaction deadlocks. Hit this for
        // real: a live CASCADE delete against actual synced data hung for
        // 30+ seconds and timed out before this fix.
        final cascadeRefs = await _linkedFieldRefs(
          txn,
          onDeleteFilter: (onDelete) => onDelete == 'CASCADE',
        );
        for (final ref in cascadeRefs) {
          await txn.execute(
            'DELETE FROM ${ref.table} WHERE ${ref.column} = ?1',
            [id],
          );
        }
        await txn.execute('DELETE FROM ${config.tableName} WHERE id = ?1', [id]);
      });
    } on DatabaseException catch (e) {
      if (e.toString().toLowerCase().contains('foreign key constraint failed')) {
        throw StillInUseException(config.tableName);
      }
      rethrow;
    }
  }

  /// Every other real table that still holds at least one *live*
  /// (`is_deleted = 0`) row referencing this row's id via a `select`/
  /// linked field whose `options.on_delete` is `'RESTRICT'` (the default
  /// when unset -- see [_LinkedFieldRef]'s doc comment) -- i.e. what would
  /// block [delete]. This is the real enforcement, not a pre-check
  /// backstopped by the database, since v2 never declares a real SQL FK
  /// for SQLite to enforce in the first place (see
  /// claude/essentials-v2-phase1-design.md, "Critical risks" #3).
  /// `'CASCADE'` and `'IGNORE'` fields are both excluded -- `'CASCADE'`
  /// is expected to cascade via [delete], not block; `'IGNORE'` is
  /// explicitly opted out of both blocking and cascading, left as a
  /// dangling reference by design.
  ///
  /// Checked by [GenericListScreen] *before* showing a delete confirmation,
  /// rather than only discovering the block after the user already clicked
  /// Delete. Found by Mike deleting a `supplier` still referenced by
  /// `shipment`/`orders` (v1; the same pre-check discipline carries
  /// forward unchanged into v2, only its source query changed).
  Future<List<String>> findBlockingReferences(int id) async {
    final crdt = await _crdt;
    final refs = await _linkedFieldRefs(
      crdt,
      onDeleteFilter: (onDelete) => onDelete == 'RESTRICT',
    );

    final blockers = <String>{};
    for (final ref in refs) {
      List<Map<String, Object?>> count;
      try {
        count = await crdt.query(
          'SELECT COUNT(*) AS c FROM ${ref.table} WHERE ${ref.column} = ?1 AND is_deleted = 0',
          [id],
        );
      } on DatabaseException {
        // The referencing table itself no longer physically exists --
        // stale field_definitions metadata (e.g. the other table was
        // dropped outside the app's own schema engine). Nothing to block
        // on; not this method's job to reconcile that drift.
        continue;
      }
      if ((count.first['c'] as int) > 0) {
        blockers.add(ref.table);
      }
    }
    return blockers.toList()..sort();
  }

  /// Every other real table's `select`/linked field pointing at
  /// [config.tableName], filtered by [onDeleteFilter] on the field's
  /// `options.on_delete`. Reads `field_definitions` directly (Essentials
  /// v2 Phase 1 -- see claude/essentials-v2-phase1-design.md,
  /// `GenericDao.findBlockingReferences`) instead of `PRAGMA
  /// foreign_key_list`, since no v2 table ever declares a real SQL FK.
  /// Takes [CrdtApi] (implemented by both [SqliteCrdt] itself and the
  /// [CrdtExecutor] a transaction hands its callback) rather than
  /// concretely [SqliteCrdt], so [delete] can pass its transaction's `txn`
  /// instead of the parent `crdt` -- required, not just tidier, per the
  /// deadlock note on [delete].
  Future<List<_LinkedFieldRef>> _linkedFieldRefs(
    CrdtApi crdt, {
    required bool Function(String onDelete) onDeleteFilter,
  }) async {
    final tableName = config.tableName;
    final rows = await crdt.query(
      "SELECT table_name, field_name, options FROM field_definitions "
      "WHERE is_deleted = 0 AND format = 'select' "
      "AND options ->> 'mode' = 'linked' AND options ->> 'table' = ?1",
      [tableName],
    );

    final refs = <_LinkedFieldRef>[];
    for (final row in rows) {
      final otherTable = row['table_name'] as String;
      if (otherTable == tableName) continue; // no v2 table self-references today; matches the old PRAGMA path's same skip.
      assertSafeSqlIdentifier(otherTable);
      final fieldName = row['field_name'] as String;
      assertSafeSqlIdentifier(fieldName);

      final options = parseFieldOptions(row['options'] as String?);
      final onDelete = ((options['on_delete'] as String?) ?? 'restrict').toUpperCase();
      if (!onDeleteFilter(onDelete)) continue;

      refs.add(_LinkedFieldRef(otherTable, fieldName, onDelete));
    }
    return refs;
  }

  /// `SELECT *`, not just [LookupConfig.valueColumn]/[LookupConfig.displayColumn]
  /// -- the only two columns either consumer (this screen's `lookupMaps`,
  /// the form's dropdown) actually reads, until row coloring by lookup
  /// (see `GenericListScreen`'s `_loadData`) needed the referenced row's
  /// own `color` column too, if it has one. Reading everything and letting
  /// each consumer pick out what it needs is simpler than adding a second,
  /// near-identical query just for one more optional column -- and stays
  /// correct automatically if a lookup target ever gains other columns a
  /// future feature wants the same way.
  Future<List<Map<String, Object?>>> getLookupOptions(LookupConfig lookup) async {
    final crdt = await _crdt;
    assertSafeSqlIdentifier(lookup.table);
    assertSafeSqlIdentifier(lookup.displayColumn);
    return crdt.query(
      'SELECT * FROM ${lookup.table} '
      'WHERE is_deleted = 0 ORDER BY ${lookup.displayColumn}',
    );
  }
}
