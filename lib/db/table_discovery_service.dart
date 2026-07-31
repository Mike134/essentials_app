import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../models/table_config.dart';
import '../util/sql_identifiers.dart';
import '../util/strings.dart';
import 'database_helper.dart';
import 'field_metadata_dao.dart';

/// sqlite_crdt's own bookkeeping columns, added to every real table by the
/// "Syncing at the Record Level" migration (see CLAUDE.md) -- structural
/// implementation detail of the sync layer, never a real business field.
/// Excluded at the source, in [TableDiscoveryService._columnInfo], so every
/// heuristic below (display column, order by, field list) never sees them
/// -- without this, they'd show up as live, editable grid columns and form
/// fields on every table in the app, since nothing else here filters by
/// column name, only by table name ([isInfraTable]).
const Set<String> crdtBookkeepingColumns = {
  'is_deleted',
  'hlc',
  'node_id',
  'modified',
};

/// Tables that exist in `essentials.db` but should never appear as a
/// discovered "library" table in the nav -- this app's own settings/
/// persistence machinery, not user data. **Maintenance note:** update this
/// set the one time a new infra table is ever added (see CLAUDE.md "Table
/// Discovery phase") -- forgetting to would make the new table show up as
/// a normal (nonsensical) nav entry rather than erroring, so it's worth
/// remembering deliberately rather than relying on it being obvious later.
///
/// `sqlite_sequence` (auto-created by any `AUTOINCREMENT` column) and
/// `android_metadata` (an Android/sqflite system table -- see
/// `database_helper.dart`'s `_verifyRealSchema` doc comment) are excluded
/// by the `sqlite_`-prefix / literal-name checks in [isInfraTable] rather
/// than listed here, since they're SQLite/platform-level, not this app's.
const Set<String> infraTables = {
  'table_column_settings',
  'table_view_settings',
  'app_settings',
  'device_settings',
  'field_metadata',
  'table_group',
  // schema_admin's migration system -- see CLAUDE.md "schema_admin --
  // migration authoring tool". Real CRDT-tracked tables (sync like
  // everything else), but never a normal nav/grid entry.
  'migration_log',
  'migration_status',
};

bool isInfraTable(String tableName) {
  return infraTables.contains(tableName) ||
      tableName.startsWith('sqlite_') ||
      tableName == 'android_metadata';
}

/// Reserved `field_metadata.field_name` values that don't refer to a real
/// column -- table-level overrides for [TableConfig.displayColumn]/
/// [TableConfig.orderBy], stored in the existing `field_metadata` table's
/// `display_label` cell rather than adding a new schema table for
/// something needed by exactly one table so far. **Deliberately narrow,
/// last-resort convention**, not a general mechanism: only used when a
/// table has neither a `name` column nor any `NOT NULL` column for
/// [TableDiscoveryService._deriveDisplayColumn]'s heuristic to land on --
/// `shipment` is the one table this applies to today (CLAUDE.md "Table
/// Discovery phase" Part E.2). A row present here always wins over the
/// heuristic, same override-precedence rule as every other
/// `field_metadata` row.
const String reservedDisplayColumnFieldName = '_display_column';
const String reservedOrderByFieldName = '_order_by';

/// Introspects `essentials.db` at startup and builds a [TableConfig] for
/// every real table, with no hand-written Dart config required. See
/// CLAUDE.md "Table Discovery phase" for the full design -- this is Parts
/// A/B: discovery + the `field_metadata` override layer. Runs once, at
/// launch, not live -- a table added in Letos mid-session shows up the
/// next time the app opens, matching how [FieldMetadataDao] overrides are
/// deliberately edited out-of-band (Letos), not through this app's own UI.
class TableDiscoveryService {
  TableDiscoveryService({FieldMetadataDao? fieldMetadataDao})
    : _fieldMetadataDao = fieldMetadataDao ?? FieldMetadataDao();

  final FieldMetadataDao _fieldMetadataDao;

  Future<SqliteCrdt> get _db async => DatabaseHelper.instance.crdt;

  /// Every real, non-infra table currently in the database, alphabetically
  /// -- `sqlite_master`'s own row order isn't a meaningful nav order (it's
  /// creation order), so callers needing a stable base order should sort;
  /// alphabetical is as good a base as any before `table_group`/`position`
  /// layering (see `home_shell.dart`) takes over. `type = 'table'` already
  /// excludes views (e.g. `subscription_computed`) with no extra filtering
  /// needed -- see CLAUDE.md Part A's scope note on views staying excluded.
  Future<List<String>> discoverTableNames() async {
    final db = await _db;
    final rows = await db.query(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    );
    return [
      for (final row in rows)
        if (!isInfraTable(row['name'] as String)) row['name'] as String,
    ];
  }

  Future<bool> tableExists(String tableName) async {
    final db = await _db;
    final rows = await db.query(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?1",
      [tableName],
    );
    return rows.isNotEmpty;
  }

  /// [tableName]'s real column names, excluding the primary key and
  /// sqlite_crdt's bookkeeping columns -- i.e. exactly the set a
  /// `field_metadata` override could sensibly target. Used by
  /// [FieldMetadataScreen]'s field picker, so a new override can only ever
  /// be created against a column that actually exists.
  Future<List<String>> editableColumnNames(String tableName) async {
    final db = await _db;
    final columns = await _columnInfo(db, tableName);
    return [for (final c in columns) if (!c.isPrimaryKey) c.name];
  }

  /// Builds a [TableConfig] for [tableName] purely from `PRAGMA
  /// table_info`/`PRAGMA foreign_key_list` plus any `field_metadata`
  /// overrides -- no hand-written Dart config for this table is consulted
  /// or required. Callers needing the two subscription-specific exceptions
  /// (`subscription_computed` as the read source, the extra view-only
  /// `yearly_cost`/`next_date` columns, `computePreview`) layer those on
  /// top of the result -- see `table_configs.dart`.
  Future<TableConfig> buildConfig(String tableName) async {
    final db = await _db;
    final columns = await _columnInfo(db, tableName);
    final foreignKeys = await _foreignKeyMap(db, tableName);
    final overrides = await _fieldMetadataDao.loadForTable(tableName);
    final uniqueColumns = await _singleColumnUniques(db, tableName);

    final fields = <FieldConfig>[];
    for (final column in columns) {
      if (column.isPrimaryKey) continue; // `id` -- structurally handled, never a FieldConfig.
      fields.add(
        await _buildField(db, column, foreignKeys[column.name], overrides[column.name]),
      );
    }

    final displayColumn = overrides[reservedDisplayColumnFieldName]?.displayLabel ??
        _deriveDisplayColumn(columns, uniqueColumns);
    final orderBy = overrides[reservedOrderByFieldName]?.displayLabel ??
        _deriveOrderBy(columns, displayColumn, fields);
    return TableConfig(
      tableName: tableName,
      displayColumn: displayColumn,
      orderBy: orderBy,
      fields: fields,
    );
  }

  Future<FieldConfig> _buildField(
    SqliteCrdt db,
    _ColumnInfo column,
    String? fkTable,
    FieldMetadata? override,
  ) async {
    final required = column.notNull && column.defaultValue == null;

    LookupConfig? lookup;
    if (fkTable != null) {
      lookup = LookupConfig(
        table: fkTable,
        displayColumn: override?.lookupDisplayColumn ?? await _lookupDisplayColumnFor(db, fkTable),
      );
    }

    final type = lookup != null ? FieldType.text : _deriveType(column);
    final label = override?.displayLabel ?? _deriveLabel(column.name, isLookup: lookup != null);
    final isLink = override?.isLink ?? (lookup == null && _looksLikeLink(column.name));
    final isColor = lookup == null && column.name.toLowerCase() == 'color';

    return FieldConfig(
      column: column.name,
      label: label,
      type: type,
      // Required is purely about nullability (NOT NULL, no SQL default) --
      // applies just as much to a lookup FK column (e.g. time_frame.unit_id)
      // as a plain one. Was previously forced false for every lookup
      // regardless of nullability -- a real bug, caught before it shipped:
      // a required FK left optional lets the form submit a null id, which
      // then fails at the SQL layer with a raw NOT NULL constraint error
      // instead of the form's own friendlier required-field validation.
      required: required,
      lookup: lookup,
      defaultValue: _deriveDefaultValue(column, type, override),
      isLink: isLink,
      isColor: isColor,
    );
  }

  /// A referenced table's own display column, for a lookup that has no
  /// `field_metadata.lookup_display_column` override -- CLAUDE.md Part A's
  /// heuristic: assume a column literally named `name`; if the referenced
  /// table doesn't have one, fall back to showing the raw id rather than
  /// guessing further (`'id'` here, since [LookupConfig.displayColumn]
  /// `'id'` against `valueColumn` `'id'` is literally the id value).
  Future<String> _lookupDisplayColumnFor(SqliteCrdt db, String referencedTable) async {
    final columns = await _columnInfo(db, referencedTable);
    final hasName = columns.any((c) => c.name.toLowerCase() == 'name');
    return hasName ? 'name' : 'id';
  }

  /// Prefer a column literally named `name`; else the first single-column
  /// `UNIQUE`-constrained text-affinity column in declaration order (a
  /// real schema-level signal that this column identifies the row to a
  /// human -- e.g. `orders.order_number`, once it's actually declared
  /// `UNIQUE`; added CLAUDE.md "Split-Pane Layout" session, Mike's
  /// suggestion after noticing `orders` fell all the way through to `id`);
  /// else the first `NOT NULL` text-affinity column (excluding FK columns,
  /// which hold ids, not human-readable text); else `id` itself -- same
  /// "don't guess further, fall back to the id" philosophy throughout.
  /// Verified against every hand-written config this reproduces before the
  /// `UNIQUE` step existed: matches all 18 of 19 exactly (the one
  /// exception, `shipment`, has no `name` and no `NOT NULL` column at all
  /// -- see CLAUDE.md "Table Discovery phase" for that known, accepted
  /// gap, still handled via its `field_metadata` sentinel override, which
  /// wins over every heuristic step here regardless).
  String _deriveDisplayColumn(List<_ColumnInfo> columns, Set<String> uniqueColumns) {
    for (final column in columns) {
      if (column.isPrimaryKey) continue;
      if (column.name.toLowerCase() == 'name') return column.name;
    }
    for (final column in columns) {
      if (column.isPrimaryKey || column.isForeignKeyLike) continue;
      if (uniqueColumns.contains(column.name) && column.sqlType.toUpperCase() == 'TEXT') {
        return column.name;
      }
    }
    for (final column in columns) {
      if (column.isPrimaryKey || column.isForeignKeyLike) continue;
      if (column.notNull && column.sqlType.toUpperCase() == 'TEXT') return column.name;
    }
    return 'id';
  }

  /// Column names covered by a single-column `UNIQUE` constraint (SQLite
  /// auto-creates one of these, `origin = 'u'`, for a column declared
  /// `UNIQUE` in `CREATE TABLE`) -- a composite unique index across
  /// multiple columns doesn't identify any one of them as a display
  /// column, so those are deliberately excluded (`index_info` length > 1).
  Future<Set<String>> _singleColumnUniques(SqliteCrdt db, String tableName) async {
    assertSafeSqlIdentifier(tableName);
    final indexes = await db.query('PRAGMA index_list("$tableName")');
    final result = <String>{};
    for (final index in indexes) {
      if ((index['unique'] as int) != 1) continue;
      final indexName = index['name'] as String;
      assertSafeSqlIdentifier(indexName);
      final info = await db.query('PRAGMA index_info("$indexName")');
      if (info.length == 1) result.add(info.first['name'] as String);
    }
    return result;
  }

  /// `position, <displayColumn>` when the table has a `position` column
  /// (every batch-1/2 lookup-shaped table) -- matches
  /// `TableConfig._lookupConfig`'s hand-written `orderBy` exactly.
  /// Otherwise, `<displayColumn> DESC` when [displayColumn] resolved to a
  /// date/dateTime field (a chronological log naturally reads newest-first
  /// -- matches `journal`'s hand-written `entry_time DESC` exactly).
  /// Otherwise plain `<displayColumn>` ascending.
  String _deriveOrderBy(List<_ColumnInfo> columns, String displayColumn, List<FieldConfig> fields) {
    final hasPosition = columns.any((c) => c.name.toLowerCase() == 'position');
    if (hasPosition) return 'position, $displayColumn';

    for (final field in fields) {
      if (field.column != displayColumn) continue;
      if (field.type == FieldType.date || field.type == FieldType.dateTime) {
        return '$displayColumn DESC';
      }
      break;
    }
    return displayColumn;
  }

  /// FK-column label derivation strips a trailing `_id` before
  /// title-casing (`used_by_id` -> "Used By", `who_id` -> "Who") --
  /// verified against every hand-written batch-2/3 lookup label. Plain
  /// columns are title-cased directly, matching CLAUDE.md Part B's
  /// "display label = title-cased column name."
  String _deriveLabel(String column, {required bool isLookup}) {
    if (isLookup && column.toLowerCase().endsWith('_id')) {
      return titleCase(column.substring(0, column.length - 3));
    }
    return titleCase(column);
  }

  /// Non-FK type/flag derivation. Boolean has no distinct SQLite type
  /// (SQLite stores it as an `INTEGER` regardless of the declared type
  /// text) -- heuristic: an `INTEGER` column that's `NOT NULL` with a SQL
  /// default of literally `0` or `1` (this schema's actual convention for
  /// `active`/`scheduled`, the only two `INTEGER NOT NULL DEFAULT` columns
  /// in the whole schema) is treated as boolean. Date/dateTime/link/color
  /// have no SQLite type either -- name-suffix/exact-name heuristics, same
  /// spirit as the lookup-display-column fallback: a real signal (the
  /// column's own name, following this project's naming convention) rather
  /// than a guess.
  FieldType _deriveType(_ColumnInfo column) {
    final sqlType = column.sqlType.toUpperCase();
    final name = column.name.toLowerCase();

    if (sqlType.contains('INT')) {
      final isZeroOrOneDefault = column.defaultValue == '0' || column.defaultValue == '1';
      if (column.notNull && isZeroOrOneDefault) return FieldType.boolean;
      return FieldType.integer;
    }
    if (sqlType.contains('REAL') || sqlType.contains('FLOA') || sqlType.contains('DOUB')) {
      return FieldType.real;
    }
    // TEXT (or blank/other -- SQLite is dynamically typed; anything not
    // recognized above falls through to text, the safest default).
    if (name.endsWith('_date')) return FieldType.date;
    if (name.endsWith('_time') || name == 'entry_time') return FieldType.dateTime;
    return FieldType.text;
  }

  bool _looksLikeLink(String column) => column.toLowerCase().contains('link');

  /// [override] (parsed as text, per [FieldMetadata.defaultValue]'s own
  /// doc comment) wins when present -- this is how a value that was only
  /// ever a hardcoded Dart constant before (e.g. `position: 255`,
  /// `color: '#FFFFFF'` -- neither is a real SQL-level `DEFAULT` in
  /// schema.sql) gets preserved across conversion, via the one-time
  /// seeding pass into `field_metadata` (CLAUDE.md Part E). Absent an
  /// override, fall back to the column's own SQL `DEFAULT` clause, parsed
  /// per [type].
  Object? _deriveDefaultValue(_ColumnInfo column, FieldType type, FieldMetadata? override) {
    final raw = override?.defaultValue ?? column.defaultValue;
    if (raw == null) return null;
    return switch (type) {
      FieldType.boolean => raw == '1' || raw.toLowerCase() == 'true',
      FieldType.integer => int.tryParse(raw),
      FieldType.real => double.tryParse(raw),
      FieldType.text || FieldType.date || FieldType.dateTime => _unquoteSqlLiteral(raw),
    };
  }

  /// `PRAGMA table_info`'s `dflt_value` returns a SQL string default
  /// (e.g. `'#FFFFFF'`) with its quotes still attached, unlike a
  /// `field_metadata` override (already plain text) -- strip them so both
  /// sources end up as the same plain Dart string either way.
  String _unquoteSqlLiteral(String raw) {
    if (raw.length >= 2 && raw.startsWith("'") && raw.endsWith("'")) {
      return raw.substring(1, raw.length - 1);
    }
    return raw;
  }

  Future<List<_ColumnInfo>> _columnInfo(SqliteCrdt db, String tableName) async {
    // PRAGMA doesn't accept bound parameters for its target -- tableName
    // always comes from sqlite_master itself (see discoverTableNames), not
    // external input, but the identifier-shape check below is cheap
    // insurance against a stray quote in a maliciously- or accidentally-
    // named table breaking this into a different statement.
    assertSafeSqlIdentifier(tableName);
    final rows = await db.query('PRAGMA table_info("$tableName")');
    return [
      for (final row in rows)
        if (!crdtBookkeepingColumns.contains(row['name'] as String))
          _ColumnInfo(
            name: row['name'] as String,
            sqlType: row['type'] as String? ?? '',
            notNull: (row['notnull'] as int) == 1,
            defaultValue: row['dflt_value'] as String?,
            // Normally `pk > 0` alone is enough (every lookup table
            // declares `id INTEGER PRIMARY KEY AUTOINCREMENT`, and every
            // entity table declares `id INTEGER PRIMARY KEY DEFAULT (...)`
            // as of the "Syncing at the Record Level" id-scheme migration
            // -- see migrations/005). Matching by name too is now mostly
            // redundant with that, but kept as a second, independent
            // signal rather than assuming the PK declaration is always
            // correct -- a literal `id` column is always this app's
            // structural surrogate key regardless of how it resolves its
            // default.
            isPrimaryKey: (row['pk'] as int) > 0 || (row['name'] as String).toLowerCase() == 'id',
          ),
    ];
  }

  /// Local column name -> referenced table name, for every FK on
  /// [tableName].
  Future<Map<String, String>> _foreignKeyMap(SqliteCrdt db, String tableName) async {
    assertSafeSqlIdentifier(tableName);
    final rows = await db.query('PRAGMA foreign_key_list("$tableName")');
    return {for (final row in rows) row['from'] as String: row['table'] as String};
  }
}

class _ColumnInfo {
  const _ColumnInfo({
    required this.name,
    required this.sqlType,
    required this.notNull,
    required this.defaultValue,
    required this.isPrimaryKey,
  });

  final String name;
  final String sqlType;
  final bool notNull;
  final String? defaultValue;
  final bool isPrimaryKey;

  /// Heuristic used only by [TableDiscoveryService._deriveDisplayColumn]
  /// to skip obvious id-holding columns when a table has no `name` -- an
  /// `INTEGER` column whose name ends `_id` reads as a FK id even without
  /// consulting `PRAGMA foreign_key_list` again.
  bool get isForeignKeyLike => sqlType.toUpperCase().contains('INT') && name.toLowerCase().endsWith('_id');
}
