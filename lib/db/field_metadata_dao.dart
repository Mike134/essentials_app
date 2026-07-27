import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'database_helper.dart';
import 'sql_helpers.dart';

/// One `field_metadata` row -- the override layer for a discovered (or
/// converted) table's introspection-derived defaults. See CLAUDE.md
/// "Real-usage findings" Step 3 for the schema and the override model this
/// mirrors (Theme vs. explicit font/color settings, applied here to
/// fields instead). A value present here overrides
/// [TableDiscoveryService]'s heuristic derivation for that one attribute;
/// absence falls back to the heuristic.
class FieldMetadata {
  const FieldMetadata({
    required this.tableName,
    required this.fieldName,
    this.displayLabel,
    this.defaultValue,
    this.lookupDisplayColumn,
    this.isLink,
  });

  final String tableName;
  final String fieldName;
  final String? displayLabel;

  /// Raw text as stored -- [TableDiscoveryService] parses this into the
  /// field's actual Dart type (bool/int/double/String) once the field's
  /// resolved [FieldType] is known, same as it already does for a column's
  /// own SQL-level `DEFAULT`.
  final String? defaultValue;
  final String? lookupDisplayColumn;

  /// `null` means "no override, use the heuristic" -- distinct from an
  /// explicit `0` (force off) the same way [defaultValue] being absent
  /// differs from an explicit empty string.
  final bool? isLink;
}

/// Reads and writes `field_metadata`, keyed by `(table_name, field_name)`
/// -- the runtime override layer for [TableDiscoveryService]'s
/// introspection heuristics. Was "edited via Letos" only -- see
/// [FieldMetadataScreen] and CLAUDE.md "Syncing at the Record Level" for
/// why that stopped being safe once sync moved to the record level: a
/// Letos edit never touches sqlite_crdt's bookkeeping columns, so it
/// silently never syncs. This app writes to it now through the same
/// crdt.execute() path every other table uses.
class FieldMetadataDao {
  Future<SqliteCrdt> get _db async => DatabaseHelper.instance.crdt;

  /// Every row across every table, for [FieldMetadataScreen]'s list view --
  /// unlike [loadForTable], not scoped to one table.
  Future<List<FieldMetadata>> loadAll() async {
    final db = await _db;
    final rows = await db.query(
      'SELECT * FROM field_metadata WHERE is_deleted = 0 '
      'ORDER BY table_name, field_name',
    );
    return [
      for (final row in rows)
        FieldMetadata(
          tableName: row['table_name'] as String,
          fieldName: row['field_name'] as String,
          displayLabel: row['display_label'] as String?,
          defaultValue: row['default_value'] as String?,
          lookupDisplayColumn: row['lookup_display_column'] as String?,
          isLink: switch (row['is_link'] as int?) {
            null => null,
            0 => false,
            _ => true,
          },
        ),
    ];
  }

  /// Removes a single override, leaving every other row for [tableName]
  /// alone -- distinct from [deleteForTable], which clears all of them
  /// (used by the startup orphan-cleanup pass for a table that no longer
  /// exists at all, not a targeted single-field removal).
  Future<void> deleteOne(String tableName, String fieldName) async {
    final db = await _db;
    await db.deleteWhere('field_metadata', {'table_name': tableName, 'field_name': fieldName});
  }

  /// All rows for [tableName], keyed by `field_name` -- one query per table
  /// per discovery pass rather than one query per field.
  Future<Map<String, FieldMetadata>> loadForTable(String tableName) async {
    final db = await _db;
    final rows = await db.query(
      'SELECT * FROM field_metadata WHERE table_name = ?1 AND is_deleted = 0',
      [tableName],
    );
    return {
      for (final row in rows)
        row['field_name'] as String: FieldMetadata(
          tableName: tableName,
          fieldName: row['field_name'] as String,
          displayLabel: row['display_label'] as String?,
          defaultValue: row['default_value'] as String?,
          lookupDisplayColumn: row['lookup_display_column'] as String?,
          isLink: switch (row['is_link'] as int?) {
            null => null,
            0 => false,
            _ => true,
          },
        ),
    };
  }

  /// Every row in the table, regardless of `table_name` -- used by the
  /// startup orphan-cleanup pass (see CLAUDE.md "Part D") to find rows
  /// whose table no longer exists in `sqlite_master`.
  Future<List<String>> allTableNames() async {
    final db = await _db;
    final rows =
        await db.query('SELECT DISTINCT table_name FROM field_metadata WHERE is_deleted = 0');
    return [for (final row in rows) row['table_name'] as String];
  }

  Future<void> deleteForTable(String tableName) async {
    final db = await _db;
    await db.deleteWhere('field_metadata', {'table_name': tableName});
  }

  /// [FieldMetadataScreen]'s save action, and originally the one-time
  /// `table_configs.dart` -> `field_metadata` seeding pass (see CLAUDE.md
  /// "Part E") -- upsert rather than plain insert so both re-running the
  /// old seed and editing an existing override through the screen are
  /// idempotent either way.
  Future<void> upsert({
    required String tableName,
    required String fieldName,
    String? displayLabel,
    String? defaultValue,
    String? lookupDisplayColumn,
    bool? isLink,
  }) async {
    final db = await _db;
    await db.upsert('field_metadata', {
      'table_name': tableName,
      'field_name': fieldName,
      'display_label': displayLabel,
      'default_value': defaultValue,
      'lookup_display_column': lookupDisplayColumn,
      'is_link': isLink == null ? null : (isLink ? 1 : 0),
    });
  }
}
