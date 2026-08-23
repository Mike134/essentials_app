import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../models/table_config.dart';
import '../util/field_options.dart';
import '../util/sql_identifiers.dart';
import 'database_helper.dart';

/// Thrown by [SchemaRegistry.buildConfig] when `table_definitions`/
/// `field_definitions` metadata has diverged from the real physical
/// schema on this device -- e.g. a migration that succeeded on another
/// device but failed (or hasn't arrived yet) on this one. Deliberately
/// loud rather than silently working around it (the old
/// `TableDiscoveryService`/`orphan_cleanup_service` pattern of quietly
/// reconciling): per claude/essentials-v2-phase1-design.md, `PRAGMA` is
/// now a *validation* check only, not a source of truth, so a mismatch is
/// something worth surfacing, not papering over.
class SchemaValidationException implements Exception {
  SchemaValidationException(this.message);

  final String message;

  @override
  String toString() => 'SchemaValidationException: $message';
}

/// Essentials v2 Phase 1's schema source -- replaces the heuristic
/// discovery `TableDiscoveryService.buildConfig` did (`PRAGMA table_info`/
/// `PRAGMA foreign_key_list` plus `field_metadata` overrides) with reading
/// `table_definitions`/`field_definitions` directly. See
/// claude/essentials-v2-phase1-design.md, "`TableDiscoveryService` ->
/// `SchemaRegistry`": there is no discovery step left to replace, because
/// `table_definitions`/`field_definitions` are now the *only* place a
/// table's display column, order-by, or field formats are ever decided --
/// explicitly, at creation time (`SchemaEditorService.createTable`/
/// `addField`), not derived from column names/SQL types after the fact.
///
/// Deliberately produces the exact same [TableConfig]/[FieldConfig] shape
/// [TableDiscoveryService] already did -- per the design doc, "Keep
/// `TableConfig` as the runtime shape the grid and form consume -- it
/// stays the interface, only its source changes." `generic_list_screen
/// .dart`/`generic_form_screen.dart` need no changes for this.
///
/// Build order step 4 only (claude/essentials-v2-phase1-design.md) --
/// this class is standalone and tested in isolation. It is NOT yet wired
/// into `table_registry.dart`/`HomeShell` as of this commit; that wiring,
/// and confirming the grid/form screens actually render a table built
/// this way, is build order step 5's job (the checkpoint), not this
/// step's.
class SchemaRegistry {
  Future<SqliteCrdt> get _db async => DatabaseHelper.instance.crdt;

  /// Every real, non-soft-deleted table `table_definitions` knows about,
  /// ordered by `position` (nulls last) then `table_name` -- the
  /// `SchemaRegistry` equivalent of `TableDiscoveryService
  /// .discoverTableNames()`, sourced from metadata instead of
  /// `sqlite_master`.
  Future<List<String>> discoverTableNames() async {
    final db = await _db;
    final rows = await db.query(
      'SELECT table_name FROM table_definitions WHERE is_deleted = 0 '
      'ORDER BY position IS NULL, position, table_name',
    );
    return [for (final row in rows) row['table_name'] as String];
  }

  Future<bool> tableExists(String tableName) async {
    final db = await _db;
    final rows = await db.query(
      'SELECT 1 FROM table_definitions WHERE table_name = ?1 AND is_deleted = 0',
      [tableName],
    );
    return rows.isNotEmpty;
  }

  /// Builds a [TableConfig] for [tableName] from `table_definitions` +
  /// `field_definitions` alone -- no column-name/SQL-type heuristics.
  /// `PRAGMA table_info` is still consulted, but purely to validate that
  /// every declared field actually has a matching physical column;
  /// [SchemaValidationException] surfaces a mismatch rather than silently
  /// skipping the field or guessing around it.
  ///
  /// Unlike [TableDiscoveryService.buildConfig], no `subscription`-style
  /// special case exists or is needed here -- Essentials v2's clean-slate
  /// directive means every table goes through this exact same path, with
  /// no `is_builtin` concept and no computed-column exception (that's
  /// deferred to a Phase 2 `formula` field, see claude/essentials-v2-phase1
  /// -design.md).
  Future<TableConfig> buildConfig(String tableName) async {
    assertSafeSqlIdentifier(tableName);
    final db = await _db;

    final tableRows = await db.query(
      'SELECT * FROM table_definitions WHERE table_name = ?1 AND is_deleted = 0',
      [tableName],
    );
    if (tableRows.isEmpty) {
      throw SchemaValidationException(
        'No table_definitions row for "$tableName" -- this table was not '
        'created through the schema engine, or its metadata has not synced '
        'to this device yet.',
      );
    }
    final tableRow = tableRows.first;

    final physicalColumns = await _physicalColumnNames(db, tableName);
    if (physicalColumns.isEmpty) {
      throw SchemaValidationException(
        'table_definitions has a row for "$tableName" but no matching '
        'physical table exists on this device -- its migration_log entry '
        'may have failed or not arrived yet. Check migration_status.',
      );
    }

    final fieldRows = await db.query(
      'SELECT * FROM field_definitions WHERE table_name = ?1 AND is_deleted = 0 '
      'ORDER BY position',
      [tableName],
    );

    final fields = <FieldConfig>[];
    for (final row in fieldRows) {
      final fieldName = row['field_name'] as String;
      if (!physicalColumns.contains(fieldName)) {
        throw SchemaValidationException(
          'field_definitions declares "$tableName.$fieldName" but no '
          'matching physical column exists on this device -- its '
          'migration_log entry may have failed or not arrived yet. Check '
          'migration_status.',
        );
      }
      fields.add(_buildField(row));
    }

    return TableConfig(
      tableName: tableName,
      displayName: tableRow['display_name'] as String,
      displayColumn: (tableRow['display_field'] as String?) ?? 'id',
      orderBy: tableRow['order_by'] as String?,
      fields: fields,
    );
  }

  FieldConfig _buildField(Map<String, Object?> row) {
    final fieldName = row['field_name'] as String;
    final format = row['format'] as String;
    final options = parseFieldOptions(row['options'] as String?);

    final lookup = _lookupFor(format, options);

    return FieldConfig(
      column: fieldName,
      label: row['display_name'] as String,
      type: _formatToFieldType(format, lookup: lookup),
      required: (row['required'] as int) == 1,
      lookup: lookup,
      defaultValue: row['default_value'] as String?,
      isLink: options['isLink'] == true,
      isColor: options['isColor'] == true,
    );
  }

  /// `options` JSON's documented shape (claude/essentials-v2-phase1-design
  /// .md, "Critical risks" #3 and the `field_definitions` schema comment):
  /// for a `format: 'select'` field in linked-lookup mode, `table` (the
  /// referenced table), and optionally `displayField`/`valueField`
  /// (default `name`/`id`, matching [LookupConfig]'s own defaults).
  /// **Provisional** -- no Add Field UI exists yet to actually produce
  /// this shape (build order step 7); this is SchemaRegistry's side of the
  /// documented contract, ready for that UI once it's built.
  LookupConfig? _lookupFor(String format, Map<String, Object?> options) {
    if (format != 'select' || options['mode'] != 'linked') return null;
    final table = options['table'] as String?;
    if (table == null) return null;
    return LookupConfig(
      table: table,
      displayColumn: options['displayField'] as String? ?? 'name',
      valueColumn: options['valueField'] as String? ?? 'id',
    );
  }

  /// **Provisional format catalog** -- matches [FieldType]'s own names
  /// 1:1 except `select` (a linked lookup, see [_lookupFor]). No Add
  /// Field UI exists yet to constrain what a user can actually pick (build
  /// order step 7); this is deliberately conservative (mirrors the
  /// existing, already-working enum) rather than guessing at a new
  /// catalog (e.g. a collapsed `'number'`) ahead of that UI actually
  /// being designed. Unrecognized formats fall back to [FieldType.text],
  /// the same safe default [TableDiscoveryService._deriveType] already
  /// uses for anything it doesn't recognize.
  FieldType _formatToFieldType(String format, {LookupConfig? lookup}) {
    if (lookup != null) return FieldType.text;
    return switch (format) {
      'integer' => FieldType.integer,
      'real' => FieldType.real,
      'boolean' => FieldType.boolean,
      'date' => FieldType.date,
      'dateTime' => FieldType.dateTime,
      _ => FieldType.text,
    };
  }

  Future<Set<String>> _physicalColumnNames(SqliteCrdt db, String tableName) async {
    assertSafeSqlIdentifier(tableName);
    final rows = await db.query('PRAGMA table_info("$tableName")');
    return {for (final row in rows) row['name'] as String};
  }
}
