import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../util/sql_identifiers.dart';
import 'database_helper.dart';
import 'migration_service.dart';
import 'table_discovery_service.dart';

/// Essentials v2 Phase 1's schema-editing entry point. Before Step 7,
/// this class also carried a single-device `ALTER TABLE ... ADD COLUMN`
/// path (`addColumn`/`buildDdl`, backing the now-deleted
/// `AddColumnScreen`) -- retired once `addField` (below) was confirmed
/// working end to end on both platforms: `addField` supersedes it
/// entirely, syncing through `migration_log` automatically instead of
/// needing the same DDL re-triggered by hand on every device. See
/// CLAUDE.md "Essentials v2 Phase 1 -- Step 7" for the verification that
/// made this retirement safe.
class SchemaEditorService {
  SchemaEditorService({TableDiscoveryService? discovery})
    : _discovery = discovery ?? TableDiscoveryService();

  final TableDiscoveryService _discovery;

  Future<SqliteCrdt> get _db async => DatabaseHelper.instance.crdt;

  /// Names not allowed for a new column -- sqlite_crdt's own bookkeeping
  /// columns (would collide with the sync layer) and `id` (always the
  /// structural surrogate key, see schema.sql).
  static const Set<String> _reservedColumnNames = {'id', ...crdtBookkeepingColumns};

  /// The physical identifier [createTable] would generate for
  /// [displayName] right now, without creating anything -- [NewTableScreen]
  /// shows this live as the user types, "so it's never a surprise"
  /// (claude/essentials-v2-phase1-design.md, "New UI"). Same collision
  /// -avoidance logic [createTable] itself uses, since this just calls
  /// straight through to it.
  Future<String> previewTableIdentifier(String displayName) async {
    final crdt = await _db;
    return _generateTableIdentifier(crdt, displayName.trim());
  }

  /// The physical identifier [addField] would generate for [displayName]
  /// on [tableName] right now, without adding anything -- [AddFieldScreen]
  /// shows this live, same reasoning as [previewTableIdentifier].
  Future<String> previewFieldIdentifier(String tableName, String displayName) async {
    final crdt = await _db;
    return _generateFieldIdentifier(crdt, tableName, displayName.trim());
  }

  // =====================================================================
  // Essentials v2 Phase 1 -- build order step 3. See
  // claude/essentials-v2-phase1-design.md "SchemaEditorService". Unlike
  // [addColumn] above (still the right tool for a plain, single-device
  // ALTER TABLE -- see that method's doc comment), [createTable] and
  // [addField] are the *only* way a business table/field gets created
  // from here on: both write through `migration_log` from the start, no
  // interim single-device version, since the AUTOINCREMENT collision risk
  // already hit once for real (`migration_log.id`, CLAUDE.md "Critical
  // risks found in the code" #2) gives no safe reason to build one.
  // =====================================================================

  /// Creates a new user table: generates a fully-quoted `CREATE TABLE`
  /// declaring only `id` (the same timestamp+random generator every entity
  /// table already uses -- see schema.sql) and NEVER sqlite_crdt's four
  /// bookkeeping columns -- predeclaring even one makes the whole
  /// statement fail outright, not just duplicate (confirmed live,
  /// `tool/schema_engine_spike.dart`, see CLAUDE.md's Essentials v2 wipe
  /// write-up). Writes that DDL into `migration_log` and the new
  /// `table_definitions` row in the same `crdt.transaction` -- a device
  /// can never receive metadata for a table whose DDL it never got, or
  /// vice versa. Then applies pending migrations immediately on this
  /// device (`MigrationService.applyPending`, safe to call anytime, same
  /// idempotent self-apply every launch/reconnect already uses) so the
  /// table exists and is usable here right away, not only after the next
  /// relaunch/reconnect.
  ///
  /// Returns the generated physical table name.
  Future<String> createTable({
    required String displayName,
    String? description,
    String? icon,
  }) async {
    final trimmedDisplayName = displayName.trim();
    if (trimmedDisplayName.isEmpty) {
      throw ArgumentError('A table needs a name.');
    }

    final crdt = await _db;
    final tableName = await _generateTableIdentifier(crdt, trimmedDisplayName);

    final ddl =
        'CREATE TABLE "$tableName" (\n'
        '  "id" INTEGER PRIMARY KEY DEFAULT (\n'
        "    CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000\n"
        '    + (abs(random()) % 1000)\n'
        '  )\n'
        ')';

    final createdAt = DateTime.now().toUtc().toIso8601String();
    final migrationIdDefault = await _migrationLogIdDefault(crdt);

    await crdt.transaction((txn) async {
      await _insertMigrationLog(
        txn,
        idDefault: migrationIdDefault,
        sqlText: ddl,
        description: 'Create table "$trimmedDisplayName" ($tableName)',
        createdAt: createdAt,
      );
      await txn.execute(
        'INSERT OR REPLACE INTO table_definitions '
        '(table_name, display_name, description, icon, created_at) '
        'VALUES (?1, ?2, ?3, ?4, ?5)',
        [tableName, trimmedDisplayName, description, icon, createdAt],
      );
    });

    await MigrationService().applyPending();
    return tableName;
  }

  /// Adds a new field to an existing table -- always physically `TEXT`
  /// (the user picks a presentation *format*, not a storage type; every
  /// user field is TEXT from day one, see CLAUDE.md's Essentials v2 wipe
  /// write-up). Unlike [addColumn], the `ALTER TABLE` is never run
  /// locally by itself -- it's written to `migration_log` (plus the new
  /// `field_definitions` row, same transaction, same reasoning as
  /// [createTable]), then applied immediately on this device the same way
  /// [createTable] does.
  Future<void> addField({
    required String tableName,
    required String displayName,
    required String format,
    String? optionsJson,
    String? defaultValue,
    bool required = false,
  }) async {
    assertSafeSqlIdentifier(tableName);
    final trimmedDisplayName = displayName.trim();
    if (trimmedDisplayName.isEmpty) {
      throw ArgumentError('A field needs a name.');
    }
    if (!await _discovery.tableExists(tableName)) {
      throw ArgumentError('No table named "$tableName" exists.');
    }
    if (required && (defaultValue == null || defaultValue.trim().isEmpty)) {
      throw ArgumentError('A required field needs a default value.');
    }

    final crdt = await _db;
    final fieldName = await _generateFieldIdentifier(crdt, tableName, trimmedDisplayName);

    final buffer = StringBuffer('ALTER TABLE "$tableName" ADD COLUMN "$fieldName" TEXT');
    if (required) {
      buffer.write(" NOT NULL DEFAULT '${defaultValue!.trim().replaceAll("'", "''")}'");
    }
    final ddl = buffer.toString();

    final createdAt = DateTime.now().toUtc().toIso8601String();
    final migrationIdDefault = await _migrationLogIdDefault(crdt);

    // Append after every existing field for this table -- computed before
    // the transaction, same "not perfectly atomic against a concurrent
    // same-device call" tradeoff GenericDao.insert already accepts for its
    // own id-default lookup.
    final positionRows = await crdt.query(
      'SELECT COALESCE(MAX(position), -1) AS max_position FROM field_definitions '
      'WHERE table_name = ?1',
      [tableName],
    );
    final nextPosition = (positionRows.first['max_position'] as int) + 1;

    await crdt.transaction((txn) async {
      await _insertMigrationLog(
        txn,
        idDefault: migrationIdDefault,
        sqlText: ddl,
        description: 'Add field "$trimmedDisplayName" ($fieldName) to "$tableName"',
        createdAt: createdAt,
      );
      await txn.execute(
        'INSERT OR REPLACE INTO field_definitions '
        '(table_name, field_name, display_name, format, options, default_value, required, position) '
        'VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)',
        [
          tableName,
          fieldName,
          trimmedDisplayName,
          format,
          optionsJson,
          defaultValue,
          required ? 1 : 0,
          nextPosition,
        ],
      );
    });

    await MigrationService().applyPending();
  }

  // =====================================================================
  // Essentials v2 Phase 1 -- build order step 9. See
  // claude/essentials-v2-phase1-design.md "Two-stage delete". Stage 1
  // ([SchemaMetadataDao.softDeleteTable]/[softDeleteField]) is a pure
  // metadata tombstone, fully undoable, no DDL. Stage 2 here is the
  // opposite: real, irreversible DDL through `migration_log`, refused
  // outright unless the target is already stage-1 soft-deleted -- a
  // `DROP TABLE`/`DROP COLUMN` that reaches a device still holding
  // unsynced rows for it would reproduce the exact all-or-nothing batch
  // failure `MigrationService`'s own doc comment describes, which is
  // exactly what requiring the soft-delete first (data tombstoned and
  // propagated *before* the drop is ever authored) exists to prevent.
  // =====================================================================

  /// Every other table with a live (`is_deleted = 0`) `select`/linked or
  /// `link_record` field still pointing at [tableName] -- same enforcement query
  /// `GenericDao._linkedFieldRefs` uses for row-level RESTRICT, one layer
  /// up (a schema-level "would dropping this table break something,"
  /// matching `schema_admin.checkDropSafety`'s existing spirit -- CLAUDE.md
  /// "schema_admin -- migration authoring tool"). [dropTable] refuses
  /// outright when this is non-empty, per
  /// claude/essentials-v2-phase1-design.md's "known gap" note on
  /// `SchemaMetadataDao.softDeleteTable` explicitly flagging this as
  /// stage-2's job, not stage-1's.
  Future<List<String>> _tablesLinkingTo(SqliteCrdt crdt, String tableName) async {
    final rows = await crdt.query(
      // Essentials v2 Phase 4: matches `link_record` fields too, not just
      // `select`/linked -- exactly the same broadening
      // `GenericDao._linkedFieldRefs` needed, for the same reason. A
      // `link_record` field pointing at a table is every bit as much a
      // reason to refuse dropping it; missing it here would let a
      // `dropTable` succeed and leave a live field pointing at nothing.
      // No format branch needed at this level (unlike the row-level match)
      // -- this only asks "which tables reference this one", never "which
      // rows".
      "SELECT DISTINCT table_name FROM field_definitions "
      "WHERE is_deleted = 0 "
      "AND ((format = 'select' AND options ->> 'mode' = 'linked') "
      "     OR format = 'link_record') "
      "AND options ->> 'table' = ?1 "
      "AND table_name != ?1",
      [tableName],
    );
    return [for (final row in rows) row['table_name'] as String]..sort();
  }

  /// Permanently deletes [tableName]: generates a real `DROP TABLE`,
  /// written to `migration_log` exactly like [createTable]/[addField]'s
  /// DDL. In the SAME `crdt.transaction`, tombstones every
  /// `field_definitions`/`table_column_settings`/`table_view_settings` row
  /// scoped to this table (via a plain `DELETE`, which `sqlite_crdt`
  /// rewrites into `is_deleted = 1` the same way every other delete in
  /// this app already works -- there is no other primitive available: a
  /// genuine raw hard SQL delete against a sqlite_crdt-managed table is
  /// exactly what caused the real incident documented in CLAUDE.md's
  /// Essentials v2 Phase 1 -- Step 3 write-up, never to be repeated).
  /// `table_definitions`' own row is already tombstoned by the stage-1
  /// precondition below -- nothing further to do to it. Bundling all of
  /// this into one transaction means a receiving device gets the DDL and
  /// every one of these metadata tombstones together in one sync batch,
  /// same "never one without the other" reasoning as [createTable]/
  /// [addField]. Applies pending migrations immediately afterward so the
  /// physical table is actually gone on this device right away, same as
  /// every other [SchemaEditorService] mutator.
  ///
  /// Throws [StateError] if [tableName] isn't already stage-1 soft-deleted,
  /// or if another table still has a live linked field pointing at it.
  Future<void> dropTable(String tableName) async {
    assertSafeSqlIdentifier(tableName);
    final crdt = await _db;

    final existing = await crdt.query(
      'SELECT is_deleted FROM table_definitions WHERE table_name = ?1',
      [tableName],
    );
    if (existing.isEmpty) {
      throw ArgumentError('No table_definitions row for "$tableName".');
    }
    if ((existing.first['is_deleted'] as int) != 1) {
      throw StateError('"$tableName" must be deleted first (stage 1) before it can be permanently deleted.');
    }

    final linkedFrom = await _tablesLinkingTo(crdt, tableName);
    if (linkedFrom.isNotEmpty) {
      throw StateError('Still linked from ${linkedFrom.join(', ')} -- remove or repoint those fields first.');
    }

    final ddl = 'DROP TABLE "$tableName"';
    final createdAt = DateTime.now().toUtc().toIso8601String();
    final migrationIdDefault = await _migrationLogIdDefault(crdt);

    await crdt.transaction((txn) async {
      await _insertMigrationLog(
        txn,
        idDefault: migrationIdDefault,
        sqlText: ddl,
        description: 'Permanently delete table "$tableName"',
        createdAt: createdAt,
      );
      await txn.execute('DELETE FROM table_definitions WHERE table_name = ?1', [tableName]);
      await txn.execute('DELETE FROM field_definitions WHERE table_name = ?1', [tableName]);
      await txn.execute('DELETE FROM table_column_settings WHERE table_name = ?1', [tableName]);
      await txn.execute('DELETE FROM table_view_settings WHERE table_name = ?1', [tableName]);
    });

    await MigrationService().applyPending();
  }

  /// `true` if [fieldName] on [tableName] is part of any real SQLite index
  /// (`PRAGMA index_list`/`PRAGMA index_info`) -- checked defensively
  /// before [dropField] emits `ALTER TABLE ... DROP COLUMN`, which SQLite
  /// (3.35+) refuses outright for a column that's part of a PRIMARY KEY,
  /// UNIQUE constraint, or index. No v2 user field can have any of those
  /// today (always plain TEXT, no FKs, no indexes ever declared -- see
  /// claude/essentials-v2-phase1-design.md, "Critical risks" #3), so this
  /// should always return `false` in practice -- kept anyway per the
  /// design doc's own explicit ask, so a future feature that *does* index
  /// a field (the same doc's "worth adding an index..." open question)
  /// can't silently reintroduce a migration that fails on every device and
  /// halts its chain.
  Future<bool> _isIndexed(SqliteCrdt crdt, String tableName, String fieldName) async {
    final indexes = await crdt.query('PRAGMA index_list("$tableName")');
    for (final index in indexes) {
      final columns = await crdt.query('PRAGMA index_info("${index['name']}")');
      if (columns.any((c) => c['name'] == fieldName)) return true;
    }
    return false;
  }

  /// Permanently deletes [fieldName] from [tableName]: generates a real
  /// `ALTER TABLE ... DROP COLUMN`, same `migration_log`/transaction/
  /// tombstone pattern as [dropTable] -- see that method's doc comment for
  /// the shared reasoning. Only [fieldName]'s own `field_definitions` row
  /// and its `table_column_settings` rows (scoped by `column_name`) are
  /// tombstoned -- unlike [dropTable], `table_view_settings` is left alone:
  /// it's scoped to the whole table, not keyed per-column, so there's no
  /// single row to remove here (a dropped field referenced by
  /// `sort_column`/`filter_json`/`group_column`/`row_color_column` is a
  /// pre-existing gap stage-1 soft-delete already has too -- not something
  /// stage-2 newly introduces, and not this method's job to reconcile).
  ///
  /// Throws [StateError] if [fieldName] isn't already stage-1 soft-deleted,
  /// or if it's part of a real SQL index (see [_isIndexed] -- should never
  /// actually happen for a v2 field).
  Future<void> dropField(String tableName, String fieldName) async {
    assertSafeSqlIdentifier(tableName);
    assertSafeSqlIdentifier(fieldName);
    final crdt = await _db;

    final existing = await crdt.query(
      'SELECT is_deleted FROM field_definitions WHERE table_name = ?1 AND field_name = ?2',
      [tableName, fieldName],
    );
    if (existing.isEmpty) {
      throw ArgumentError('No field_definitions row for "$tableName.$fieldName".');
    }
    if ((existing.first['is_deleted'] as int) != 1) {
      throw StateError('"$fieldName" must be deleted first (stage 1) before it can be permanently deleted.');
    }
    if (await _isIndexed(crdt, tableName, fieldName)) {
      throw StateError('"$fieldName" is part of an index or constraint and can\'t be dropped this way.');
    }

    final ddl = 'ALTER TABLE "$tableName" DROP COLUMN "$fieldName"';
    final createdAt = DateTime.now().toUtc().toIso8601String();
    final migrationIdDefault = await _migrationLogIdDefault(crdt);

    await crdt.transaction((txn) async {
      await _insertMigrationLog(
        txn,
        idDefault: migrationIdDefault,
        sqlText: ddl,
        description: 'Permanently delete field "$fieldName" from "$tableName"',
        createdAt: createdAt,
      );
      await txn.execute(
        'DELETE FROM field_definitions WHERE table_name = ?1 AND field_name = ?2',
        [tableName, fieldName],
      );
      await txn.execute(
        'DELETE FROM table_column_settings WHERE table_name = ?1 AND column_name = ?2',
        [tableName, fieldName],
      );
    });

    await MigrationService().applyPending();
  }

  /// Derives a physical SQLite identifier from [displayName]: lowercase,
  /// every run of non-alphanumeric characters collapsed to a single `_`,
  /// leading/trailing `_` trimmed. Collision-checked against every real
  /// table (`sqlite_master`, unconditional -- covers a table that's stage-1
  /// soft-deleted but not yet [dropTable]'d, since its physical table is
  /// still genuinely there), every *active* (`is_deleted = 0`)
  /// `table_definitions` row, and this app's own reserved infra table
  /// names. Appends a numeric suffix (`_2`, `_3`, ...) until clear.
  /// `table_name` is immutable once created (see CLAUDE.md's phase1 design
  /// write-up) while a table is merely stage-1 soft-deleted -- but once
  /// [dropTable] (stage 2) has actually run, both checks clear (physical
  /// table gone from `sqlite_master`, metadata row excluded here for being
  /// `is_deleted = 1`) and the name genuinely becomes reusable, exactly as
  /// claude/essentials-v2-phase1-design.md's "Two-stage delete" promises
  /// ("a deleted table's name could never be reused. Stage 2 solves
  /// both.").
  Future<String> _generateTableIdentifier(SqliteCrdt crdt, String displayName) async {
    final base = _identifierBase(displayName, fallbackPrefix: 't');
    final taken = await _takenTableNames(crdt);

    var candidate = base;
    var suffix = 2;
    while (taken.contains(candidate) || isInfraTable(candidate)) {
      candidate = '${base}_$suffix';
      suffix++;
    }

    assertSafeSqlIdentifier(candidate);
    return candidate;
  }

  Future<Set<String>> _takenTableNames(SqliteCrdt crdt) async {
    final sqliteTables = await crdt.query("SELECT name FROM sqlite_master WHERE type = 'table'");
    final definedTables = await crdt.query(
      'SELECT table_name FROM table_definitions WHERE is_deleted = 0',
    );
    return {
      for (final row in sqliteTables) (row['name'] as String).toLowerCase(),
      for (final row in definedTables) (row['table_name'] as String).toLowerCase(),
    };
  }

  /// Same scheme as [_generateTableIdentifier], scoped to one table.
  /// Collision-checked against the table's real physical columns (`PRAGMA
  /// table_info`, unconditional -- covers a field that's stage-1
  /// soft-deleted but not yet [dropField]'d) and every *active*
  /// `field_definitions` row for this table -- same "becomes reusable
  /// only after stage 2" reasoning as [_takenTableNames].
  Future<String> _generateFieldIdentifier(SqliteCrdt crdt, String tableName, String displayName) async {
    final base = _identifierBase(displayName, fallbackPrefix: 'f');
    final taken = await _takenFieldNames(crdt, tableName);

    var candidate = base;
    var suffix = 2;
    while (taken.contains(candidate) || _reservedColumnNames.contains(candidate)) {
      candidate = '${base}_$suffix';
      suffix++;
    }

    assertSafeSqlIdentifier(candidate);
    return candidate;
  }

  Future<Set<String>> _takenFieldNames(SqliteCrdt crdt, String tableName) async {
    assertSafeSqlIdentifier(tableName);
    final physicalColumns = await crdt.query('PRAGMA table_info("$tableName")');
    final definedFields = await crdt.query(
      'SELECT field_name FROM field_definitions WHERE table_name = ?1 AND is_deleted = 0',
      [tableName],
    );
    return {
      for (final row in physicalColumns) (row['name'] as String).toLowerCase(),
      for (final row in definedFields) (row['field_name'] as String).toLowerCase(),
    };
  }

  String _identifierBase(String displayName, {required String fallbackPrefix}) {
    var base = displayName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (base.isEmpty) {
      return fallbackPrefix;
    }
    if (RegExp(r'^[0-9]').hasMatch(base)) {
      base = '${fallbackPrefix}_$base';
    }
    return base;
  }

  /// [migrationLog]'s `id` column's own SQL `DEFAULT` expression text (the
  /// timestamp+random generator, as of the Essentials v2 wipe -- see
  /// CLAUDE.md "Critical risks found in the code" #2) -- `null` would mean
  /// a plain `AUTOINCREMENT` table, which `migration_log` no longer is.
  /// Same pattern as `GenericDao._idDefaultExpression`, reused here rather
  /// than duplicated in spirit -- `migration_log` isn't a `GenericDao`
  /// table (composite-key siblings aside, it has its own reserved
  /// `AUTOINCREMENT`-free id scheme, not a normal entity table), so the
  /// lookup is repeated, not shared code.
  Future<String?> _migrationLogIdDefault(SqliteCrdt crdt) async {
    final columns = await crdt.query('PRAGMA table_info("migration_log")');
    for (final column in columns) {
      if (column['name'] == 'id') return column['dflt_value'] as String?;
    }
    return null;
  }

  /// Inserts one `migration_log` row inside [txn] -- must run inside the
  /// same transaction as the matching `table_definitions`/
  /// `field_definitions` write (see [createTable]/[addField]), so `id`'s
  /// `DEFAULT` expression is injected as a raw SQL fragment (not a bound
  /// value) exactly like `GenericDao.insert` already does for every
  /// timestamp+random-id entity table -- SQLite's rowid-alias
  /// auto-assignment silently bypasses a column's own `DEFAULT` whenever
  /// that column is omitted from the INSERT, so `id` can never just be
  /// left out here.
  Future<void> _insertMigrationLog(
    CrdtExecutor txn, {
    required String? idDefault,
    required String sqlText,
    required String description,
    required String createdAt,
  }) async {
    final columnList = idDefault == null ? 'sql_text, description, created_at' : 'id, sql_text, description, created_at';
    final valuesSql = idDefault == null ? '?1, ?2, ?3' : '($idDefault), ?1, ?2, ?3';
    await txn.execute(
      'INSERT INTO migration_log ($columnList) VALUES ($valuesSql)',
      [sqlText, description, createdAt],
    );
  }
}
