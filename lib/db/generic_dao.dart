import 'dart:async';

import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../models/table_config.dart';
import '../util/field_options.dart';
import '../util/formula/formula_service.dart';
import '../util/link_record.dart';
import '../util/linked_field/linked_field_service.dart';
import '../util/sql_identifiers.dart';
import 'database_helper.dart';
import 'file_sync_service.dart';
import 'search_index_service.dart';

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

/// One other real table's linking field pointing at [GenericDao.config]'s
/// table -- Essentials v2 Phase 1's replacement for a real declared SQL
/// foreign key, since no v2 table ever declares one (see
/// claude/essentials-v2-phase1-design.md, "Critical risks" #3).
/// [onDelete] is `field_definitions.options.on_delete`, defaulting to
/// `'RESTRICT'` when unset -- matches this project's long-standing
/// default posture (every relationship blocks deletion unless explicitly
/// marked otherwise; see CLAUDE.md "Parent-child (one-to-many)
/// relationships").
///
/// Covers **two** formats as of Essentials v2 Phase 4, which is what
/// [isMultiValue] exists to tell apart -- they store their reference
/// completely differently, so the row-level matching SQL differs:
/// - `select` in linked mode -- one scalar target id in the column
///   (`WHERE column = ?1`).
/// - `link_record` -- a JSON *array* of target ids
///   (`json_each`-based array-membership match, see
///   [GenericDao._referenceMatchSql]).
class _LinkedFieldRef {
  _LinkedFieldRef(this.table, this.column, this.onDelete, {required this.isMultiValue});

  final String table;
  final String column;
  final String onDelete;

  /// `true` for a `link_record` field (JSON array storage), `false` for a
  /// `select`/linked field (single scalar id).
  final bool isMultiValue;
}

/// One other table's records linking back to a specific row via a live
/// `link_record` field -- [GenericDao.getReverseLinks]'s per-table group.
class ReverseLink {
  ReverseLink({
    required this.tableName,
    required this.displayName,
    required this.displayColumn,
    required this.fieldDisplayName,
    required this.rows,
  });

  /// The referencing table's physical identifier.
  final String tableName;

  /// The referencing table's `table_definitions.display_name`.
  final String displayName;

  /// Column to show for each row in [rows] alongside its `id` -- that
  /// table's own `table_definitions.display_field` if set, else its first
  /// field by position (see [GenericDao.getReverseLinks]'s own doc
  /// comment for why the fallback matters: no v2 table's UI actually sets
  /// `display_field` yet, so relying on it alone left every reverse-relation
  /// row showing a bare id). `null` only for a referencing table with no
  /// fields at all.
  final String? displayColumn;

  /// The `link_record` field's own display name -- context for when a
  /// table has more than one field linking back here.
  final String fieldDisplayName;

  /// Every live row on [tableName] whose `link_record` field's array
  /// includes the id being looked up.
  final List<Map<String, Object?>> rows;
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
    final rows = await crdt.query(
      'SELECT * FROM $source WHERE $where ORDER BY $orderBy',
      args,
    );

    // Essentials v2 Phase 2 step 6 / Phase 4 step 2: `formula`, `lookup`
    // and `rollup` fields all have a real physical column that is
    // deliberately never written, so their values are computed here on the
    // way out -- the read-time equivalent of what v1's
    // `subscription_computed` view did in SQL. Both steps are a no-op
    // returning `rows` untouched for a table without such a field, which
    // is almost all of them (see FormulaService.applyTo /
    // LinkedFieldService.applyToAll).
    //
    // Linked fields FIRST, then formulas: a `formula` referencing a
    // `rollup` column (`{task_count} * 2`) then resolves against the real
    // computed number, since FormulaService reads its inputs straight out
    // of the row it's handed. The reverse order would silently give it
    // NULL. Nothing depends on the other direction -- a `lookup`/`rollup`
    // reads another *table*'s stored columns, never this row's formulas.
    final linked = await LinkedFieldService.applyToAll(crdt, config.fields, rows);
    if (!FormulaService.hasFormulaFields(config.fields)) return linked;
    return [for (final row in linked) FormulaService.applyTo(config.fields, row)];
  }

  /// One record by [id], or `null` if it doesn't exist / was soft-deleted --
  /// same read pipeline as [getAll] (readSource, linked-field/formula
  /// computation) but scoped to a single row. Used by `SearchScreen` to
  /// open a search result directly (`search_index.record_id` is enough,
  /// per claude/essentials-v2-phase6-design.md's "Search UI" section)
  /// without re-running the whole table's [getAll] first.
  Future<Map<String, Object?>?> getById(int id) async {
    final crdt = await _crdt;
    final source = config.readSource ?? config.tableName;
    assertSafeSqlIdentifier(source);

    final rows = await crdt.query(
      'SELECT * FROM $source WHERE id = ?1 AND is_deleted = 0',
      [id],
    );
    if (rows.isEmpty) return null;

    final linked = await LinkedFieldService.applyToAll(crdt, config.fields, rows);
    final row = linked.first;
    return FormulaService.hasFormulaFields(config.fields)
        ? FormulaService.applyTo(config.fields, row)
        : row;
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
    // Essentials v2 Phase 6 (Global Search) -- reindexed after the
    // transaction commits, not inside it: SearchIndexService opens its own
    // separate bypass connection to search_index (see that class's own
    // doc comment for why), so there's no reason to hold this connection's
    // transaction open any longer than the actual insert needs.
    await SearchIndexService().reindexRecord(config.tableName, id);
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
    // Essentials v2 Phase 6 (Global Search) -- see the matching comment on
    // insert() above.
    await SearchIndexService().reindexRecord(config.tableName, id);
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

    // Image field cleanup -- resolution to the storage design doc's
    // originally-open "delete behavior" item. GenericListScreen's own
    // delete confirmation already tells the user "This cannot be undone,"
    // so eager file cleanup here matches what's already promised, not
    // ahead of it. Best-effort/fire-and-forget (FileSyncService.delete's
    // own doc comment): a cleanup failure must never block the actual
    // record delete below. Direct fields on this table only -- a
    // CASCADE-deleted child row's own image fields (see the cascade
    // handling below) go through a raw bulk DELETE, not a recursive
    // GenericDao.delete call, so this doesn't reach them. Narrow, known
    // gap, not attempted here.
    final imageFields = config.fields.where((f) => f.format == 'image');
    if (imageFields.isNotEmpty) {
      final rows = await crdt.query('SELECT * FROM "${config.tableName}" WHERE id = ?1', [id]);
      if (rows.isNotEmpty) {
        for (final field in imageFields) {
          final value = rows.first[field.column] as String?;
          if (value != null && value.isNotEmpty) {
            unawaited(FileSyncService().deleteByRelativeKey(value));
          }
        }
      }
    }

    // Essentials v2 Phase 6 (Global Search) -- every cascaded child table
    // touched, collected inside the transaction below (where the cascade
    // itself happens) but only acted on after it commits, since
    // SearchIndexService's reindexTable/removeFromIndex go through a
    // separate bypass connection, not this one. A whole-table reindex,
    // not per-row -- the cascade deletes its children via a bulk `WHERE`
    // clause, so their individual ids are never materialized here (same
    // reasoning SyncService.dataChanges's own listener already uses for
    // "no per-row detail available").
    final cascadedTables = <String>{};
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
        cascadedTables.addAll(cascadeRefs.map((r) => r.table));
        for (final ref in cascadeRefs) {
          if (!ref.isMultiValue) {
            await txn.execute(
              'DELETE FROM "${ref.table}" WHERE "${ref.column}" = ?1',
              [id],
            );
            continue;
          }
          // A `link_record` cascade is deliberately two steps -- collect
          // the matching ids with a SELECT, then delete each by plain
          // scalar id -- rather than one `DELETE ... WHERE EXISTS
          // (json_each ...)`.
          //
          // Not stylistic: sqlite_crdt rewrites every DELETE into a
          // soft-delete UPDATE by *re-parsing* the statement
          // (CrdtWriteExecutor), an already-verified-fragile path in this
          // codebase (the `sqlparser` bug that silently dropped a column
          // named `key` from a rewritten CREATE TABLE -- CLAUDE.md
          // "Syncing at the Record Level" migration 007). A json_each
          // subquery inside a rewritten write statement is exactly the
          // kind of construct that could get mangled silently. The read
          // path (`query`) round-trip has been verified for json_each; the
          // write path stays on the trivially-safe scalar form already
          // proven by every other delete in this app. At this app's scale
          // the extra statements cost nothing.
          //
          // Per the design doc: this deletes the WHOLE referencing row
          // when any one of its linked ids is deleted -- not a partial
          // prune of that id out of the array. Same "cascade wipes the
          // child row" semantics select/linked already has.
          final matches = await txn.query(
            'SELECT id FROM "${ref.table}" WHERE ${_referenceMatchSql(ref)}',
            [id],
          );
          for (final match in matches) {
            await txn.execute(
              'DELETE FROM "${ref.table}" WHERE id = ?1',
              [match['id']],
            );
          }
        }
        await txn.execute('DELETE FROM ${config.tableName} WHERE id = ?1', [id]);
      });
    } on DatabaseException catch (e) {
      if (e.toString().toLowerCase().contains('foreign key constraint failed')) {
        throw StillInUseException(config.tableName);
      }
      rethrow;
    }
    await SearchIndexService().removeFromIndex(config.tableName, id);
    for (final table in cascadedTables) {
      await SearchIndexService().reindexTable(table);
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
          'SELECT COUNT(*) AS c FROM "${ref.table}" WHERE ${_referenceMatchSql(ref)}',
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
      "SELECT table_name, field_name, format, options FROM field_definitions "
      "WHERE is_deleted = 0 "
      "AND ((format = 'select' AND options ->> 'mode' = 'linked') "
      "     OR format = 'link_record') "
      "AND options ->> 'table' = ?1",
      [tableName],
    );

    final refs = <_LinkedFieldRef>[];
    for (final row in rows) {
      final otherTable = row['table_name'] as String;
      if (otherTable == tableName) continue; // no v2 table self-references today; matches the old PRAGMA path's same skip. Unchanged for Phase 4 -- a self-referencing link_record is explicitly out of scope (claude/essentials-v2-phase4-design.md, "Explicitly out of scope").
      assertSafeSqlIdentifier(otherTable);
      final fieldName = row['field_name'] as String;
      assertSafeSqlIdentifier(fieldName);

      final options = parseFieldOptions(row['options'] as String?);
      final onDelete = ((options['on_delete'] as String?) ?? 'restrict').toUpperCase();
      if (!onDeleteFilter(onDelete)) continue;

      refs.add(
        _LinkedFieldRef(
          otherTable,
          fieldName,
          onDelete,
          isMultiValue: (row['format'] as String?) == linkRecordFormat,
        ),
      );
    }
    return refs;
  }

  /// `field_definitions.format` for a `link_record` field -- the one format
  /// whose reference is a JSON array rather than a scalar id.
  static const String linkRecordFormat = 'link_record';

  /// A `WHERE` fragment matching every *live* row of [ref]'s table that
  /// references id `?1`, for whichever storage shape [ref] uses.
  ///
  /// The `link_record` (array) form uses SQLite's JSON1 `json_each`
  /// table-valued function (the same extension this class already relies on
  /// via `->>`) inside an `EXISTS` subquery rather than a top-level join:
  /// `EXISTS` keeps this a single composable `WHERE` fragment usable
  /// unchanged by both a `COUNT(*)` and an id-collecting `SELECT`, and never
  /// double-counts a row whose array happens to contain the same id twice.
  ///
  /// `CAST(... AS INTEGER)` deliberately, not a bare `=`: `json_each.value`
  /// carries the JSON element's own storage class, so an array that ever
  /// held `["42"]` instead of `[42]` would silently compare unequal to a
  /// bound integer (SQLite doesn't apply affinity to a function result).
  /// `encodeLinkedIds` always writes real integers, but [parseLinkedIds] is
  /// deliberately lenient about strings, so the matching side is too --
  /// otherwise the two halves of the same feature could disagree about
  /// whether a row is linked.
  ///
  /// **The `CASE WHEN json_valid(...)` guard is load-bearing, not
  /// defensive tidiness** -- confirmed empirically against real `sqlite3`,
  /// not assumed. `json_each` on a column value that isn't valid JSON
  /// raises `malformed JSON` for the *whole statement*, not just that row:
  /// one row holding junk in its link column (a hand edit, a CSV import, a
  /// half-written value) would make this entire query throw, which
  /// [findBlockingReferences] catches as "the table doesn't exist" and
  /// turns into **no blockers at all** -- silently disabling RESTRICT
  /// protection for every other row in that table. Substituting `'[]'` for
  /// an unparseable value keeps a single bad row local to itself: it links
  /// to nothing, and every well-formed row still matches normally. NULL
  /// needs no special case (`json_valid(NULL)` is falsy, and `json_each`
  /// over `'[]'` yields no rows either way).
  ///
  /// Round-trip-verified against the installed `sqlparser` 0.41.2: every
  /// `sql_crdt` read goes through `SqlUtil.transformAutomaticExplicitSql`,
  /// which re-parses and re-serializes the whole statement, so a construct
  /// it mangles would break silently (exactly how the documented bare-`key`
  /// -column bug behaved). `json_each` in both a join and an `EXISTS`
  /// subquery survives that round trip intact.
  static String _referenceMatchSql(_LinkedFieldRef ref) => ref.isMultiValue
      ? 'is_deleted = 0 AND EXISTS (SELECT 1 FROM json_each('
            'CASE WHEN json_valid("${ref.table}"."${ref.column}") '
            'THEN "${ref.table}"."${ref.column}" ELSE \'[]\' END) '
            'WHERE CAST(json_each.value AS INTEGER) = ?1)'
      : '"${ref.column}" = ?1 AND is_deleted = 0';

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
    final displayColumn = await _resolveDisplayColumn(crdt, lookup.table, lookup.displayColumn);
    // Aliased back onto the *configured* key when it had to fall back --
    // every consumer (this screen's lookupMaps, the form's dropdown) reads
    // `option[lookup.displayColumn]`, the original key, so without this a
    // fallback would leave that key entirely absent (read as the literal
    // string "null" once string-interpolated) instead of showing the id.
    final alias = displayColumn == lookup.displayColumn
        ? ''
        : ', $displayColumn AS ${lookup.displayColumn}';
    return crdt.query(
      'SELECT *$alias FROM ${lookup.table} '
      'WHERE is_deleted = 0 ORDER BY $displayColumn',
    );
  }

  /// Every live row of a `link_record` field's target table, for the
  /// grid/form picker -- `SELECT *` so a "Use Color" row-coloring source or
  /// similar can read a target's own extra columns too, same reasoning as
  /// [getLookupOptions].
  Future<List<Map<String, Object?>>> getLinkedRecordOptions(LinkRecordConfig linkRecord) async {
    final crdt = await _crdt;
    assertSafeSqlIdentifier(linkRecord.table);
    assertSafeSqlIdentifier(linkRecord.displayColumn);
    final displayColumn = await _resolveDisplayColumn(
      crdt,
      linkRecord.table,
      linkRecord.displayColumn,
    );
    // Same aliasing-on-fallback reasoning as getLookupOptions above.
    final alias = displayColumn == linkRecord.displayColumn
        ? ''
        : ', "$displayColumn" AS "${linkRecord.displayColumn}"';
    return crdt.query(
      'SELECT *$alias FROM "${linkRecord.table}" '
      'WHERE is_deleted = 0 ORDER BY "$displayColumn"',
    );
  }

  /// [configuredColumn] if it's actually a physical column on [table], else
  /// `'id'` -- a real, always-present fallback.
  ///
  /// Both [LookupConfig.displayColumn] and [LinkRecordConfig.displayColumn]
  /// default to `'name'` when a field's own `options.displayField` doesn't
  /// override it (see `SchemaRegistry._lookupFor`/`_linkRecordFor`), and
  /// nothing yet stops a target table without a real `name` column from
  /// being picked -- confirmed to crash for real: `SELECT * FROM condition
  /// WHERE is_deleted = 0 ORDER BY name` against a table whose own text
  /// field happens to be named `condition`, not `name`. This is the "never
  /// crash the whole table over one bad field's metadata" posture every
  /// other Phase 4 read path already follows (see `LinkedFieldService`'s
  /// own doc comment) -- a wrong display column degrades to showing raw
  /// ids, ugly but not fatal, and (per `AddFieldScreen`/`ManageFieldsScreen`'s
  /// new "Which field to show" picker) a *newly* created field should never
  /// actually hit this fallback going forward.
  Future<String> _resolveDisplayColumn(
    CrdtApi crdt,
    String table,
    String configuredColumn,
  ) async {
    if (configuredColumn == 'id') return 'id';
    final columns = await crdt.query('PRAGMA table_info("$table")');
    final exists = columns.any((c) => c['name'] == configuredColumn);
    return exists ? configuredColumn : 'id';
  }

  /// Every other-table record whose own `link_record` field points back at
  /// [config.tableName]'s row `id` -- the reverse-relation panel's data
  /// source (Essentials v2 Phase 4, "confirmed decisions": ships in this
  /// pass, not deferred). Grouped by referencing table, since more than one
  /// other table -- or more than one field on the same other table -- can
  /// link here.
  ///
  /// Read-only: this never edits the relationship, only reports it (per the
  /// design doc, "Removing/changing a link stays the other record's own
  /// `link_record` field").
  Future<List<ReverseLink>> getReverseLinks(int id) async {
    final crdt = await _crdt;
    final tableName = config.tableName;

    final fieldRows = await crdt.query(
      "SELECT table_name, field_name, display_name FROM field_definitions "
      "WHERE is_deleted = 0 AND format = 'link_record' AND options ->> 'table' = ?1",
      [tableName],
    );

    final results = <ReverseLink>[];
    final tableDefCache = <String, Map<String, Object?>?>{};
    final firstFieldCache = <String, String?>{};

    for (final fieldRow in fieldRows) {
      final otherTable = fieldRow['table_name'] as String;
      if (!isSafeSqlIdentifier(otherTable)) continue;
      final fieldName = fieldRow['field_name'] as String;
      if (!isSafeSqlIdentifier(fieldName)) continue;
      final fieldDisplayName = fieldRow['display_name'] as String;

      if (!tableDefCache.containsKey(otherTable)) {
        final defRows = await crdt.query(
          'SELECT display_name, display_field FROM table_definitions '
          'WHERE table_name = ?1 AND is_deleted = 0',
          [otherTable],
        );
        tableDefCache[otherTable] = defRows.isEmpty ? null : defRows.first;
      }
      final tableDef = tableDefCache[otherTable];
      if (tableDef == null) continue; // stale metadata -- the other table's own definition is gone/soft-deleted.

      if (!firstFieldCache.containsKey(otherTable)) {
        final firstFieldRows = await crdt.query(
          'SELECT field_name FROM field_definitions '
          'WHERE table_name = ?1 AND is_deleted = 0 ORDER BY position ASC LIMIT 1',
          [otherTable],
        );
        firstFieldCache[otherTable] = firstFieldRows.isEmpty
            ? null
            : firstFieldRows.first['field_name'] as String;
      }

      List<Map<String, Object?>> rows;
      try {
        rows = await crdt.query(
          'SELECT * FROM "$otherTable" WHERE is_deleted = 0 '
          'AND EXISTS (SELECT 1 FROM json_each('
          'CASE WHEN json_valid("$otherTable"."$fieldName") '
          'THEN "$otherTable"."$fieldName" ELSE \'[]\' END) '
          'WHERE CAST(json_each.value AS INTEGER) = ?1)',
          [id],
        );
      } on DatabaseException {
        continue; // the referencing table no longer physically exists.
      }
      if (rows.isEmpty) continue;

      results.add(
        ReverseLink(
          tableName: otherTable,
          displayName: tableDef['display_name'] as String,
          displayColumn: (tableDef['display_field'] as String?) ?? firstFieldCache[otherTable],
          fieldDisplayName: fieldDisplayName,
          rows: rows,
        ),
      );
    }
    return results;
  }

  /// Type-ahead suggestions for a `text`-format field, drawn from other
  /// rows' own values already in the same column -- see
  /// claude/essentials-v2-column-autocomplete-design.md. Prefix match only
  /// (not substring/fuzzy -- cheapest query, standard autocomplete
  /// behavior), live against the real table with no cache/index of its own
  /// -- revisit only if a real table's row count ever makes this slow in
  /// practice (nothing today suggests that's likely at this app's scale).
  /// `is_deleted = 0` -- same soft-delete convention every other read in
  /// this class already respects -- so a value that only exists on a
  /// tombstoned row is never suggested. [excludeValue], when given, drops
  /// that exact value from the results -- used so the value already sitting
  /// in the cell being edited isn't suggested back at itself. Debouncing
  /// (~200ms, per the design doc) is the UI layer's job, not this method's
  /// -- see [ColumnAutocompleteSource].
  Future<List<String>> getDistinctColumnValues(
    String tableName,
    String fieldName, {
    String prefix = '',
    String? excludeValue,
    int limit = 20,
  }) async {
    final crdt = await _crdt;
    assertSafeSqlIdentifier(tableName);
    assertSafeSqlIdentifier(fieldName);

    final args = <Object?>[prefix];
    var where =
        'is_deleted = 0 AND "$fieldName" IS NOT NULL AND "$fieldName" != \'\' '
        'AND "$fieldName" LIKE ?1 || \'%\' COLLATE NOCASE';
    if (excludeValue != null && excludeValue.isNotEmpty) {
      args.add(excludeValue);
      where += ' AND "$fieldName" != ?${args.length}';
    }
    args.add(limit);

    final rows = await crdt.query(
      'SELECT DISTINCT "$fieldName" AS v FROM "$tableName" WHERE $where '
      'ORDER BY "$fieldName" LIMIT ?${args.length}',
      args,
    );
    return [for (final row in rows) row['v'] as String];
  }
}
