import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../util/sql_identifiers.dart';
import 'database_helper.dart';
import 'sql_helpers.dart';
import 'table_discovery_service.dart' show crdtBookkeepingColumns;

/// One `field_definitions` row, for [ManageFieldsScreen]. Unlike
/// [SchemaRegistry.buildConfig]'s [FieldConfig] output, this carries the
/// raw metadata columns directly (format as a string, options as raw
/// JSON) rather than the translated grid/form runtime shape -- what an
/// editor screen needs to show and let Mike change, not what the grid
/// needs to render.
class FieldDefinitionRow {
  FieldDefinitionRow({
    required this.tableName,
    required this.fieldName,
    required this.displayName,
    required this.format,
    required this.optionsJson,
    required this.defaultValue,
    required this.required,
    required this.position,
    required this.isDeleted,
    required this.modified,
  });

  factory FieldDefinitionRow.fromRow(Map<String, Object?> row) => FieldDefinitionRow(
    tableName: row['table_name'] as String,
    fieldName: row['field_name'] as String,
    displayName: row['display_name'] as String,
    format: row['format'] as String,
    optionsJson: row['options'] as String?,
    defaultValue: row['default_value'] as String?,
    required: (row['required'] as int) == 1,
    position: row['position'] as int,
    isDeleted: (row['is_deleted'] as int) == 1,
    modified: row['modified'] as String,
  );

  final String tableName;
  final String fieldName;
  final String displayName;
  final String format;
  final String? optionsJson;
  final String? defaultValue;
  final bool required;
  final int position;
  final bool isDeleted;

  /// This row's own CRDT `modified` HLC timestamp (`Hlc.toString()`
  /// format) -- carried through so [ManageFieldsScreen] can gate
  /// "Permanently delete" on whether *this specific* soft-delete has
  /// plausibly reached the server yet. See [SyncService.lastConnectedAt]'s
  /// doc comment for how that comparison works and why it's a best-effort
  /// signal, not a guarantee.
  final String modified;
}

/// One `table_definitions` row, for [ManageTablesScreen] -- same
/// reasoning as [FieldDefinitionRow]: the raw metadata columns an editor
/// screen needs, not [SchemaRegistry.buildConfig]'s translated runtime
/// shape.
class TableDefinitionRow {
  TableDefinitionRow({
    required this.tableName,
    required this.displayName,
    required this.description,
    required this.icon,
    required this.calendarField,
    required this.isDeleted,
    required this.modified,
  });

  factory TableDefinitionRow.fromRow(Map<String, Object?> row) => TableDefinitionRow(
    tableName: row['table_name'] as String,
    displayName: row['display_name'] as String,
    description: row['description'] as String?,
    icon: row['icon'] as String?,
    // Essentials v2 Phase 3 (Calendar) -- added later than every other
    // column here via migration_log, so a row synced in from a device that
    // hasn't applied that migration yet could theoretically be missing it;
    // `row['calendar_field']` on a `Map` just reads `null` for an absent
    // key either way, same lenient handling as every other nullable column
    // read here.
    calendarField: row['calendar_field'] as String?,
    isDeleted: (row['is_deleted'] as int) == 1,
    modified: row['modified'] as String,
  );

  final String tableName;
  final String displayName;
  final String? description;
  final String? icon;

  /// Raw `table_definitions.calendar_field` JSON -- parse with
  /// `CalendarFieldConfig.tryParse`/`resolveCalendarField`
  /// (`lib/util/calendar_field.dart`), never read directly.
  final String? calendarField;

  final bool isDeleted;

  /// Same reasoning as [FieldDefinitionRow.modified] -- see there.
  final String modified;
}

/// Non-DDL edits to `table_definitions`/`field_definitions` -- everything
/// [ManageFieldsScreen] needs that ISN'T a real schema change, per
/// claude/essentials-v2-phase1-design.md's Option A table: rename
/// (`display_name`), change format, edit format options, set default,
/// mark required, reorder (`position`), and stage-1 soft delete/restore
/// (`is_deleted`) are all plain metadata writes with no DDL and no
/// `migration_log` entry -- they sync like any other row change, no
/// device-by-device coordination needed. Deliberately kept separate from
/// [SchemaEditorService], which owns exactly the opposite half:
/// operations that DO touch physical DDL and DO write to `migration_log`
/// (`createTable`/`addField`, and eventually `dropTable`/`dropField`).
///
/// **`required`'s toggle here is a pure app-level form-validation flag,
/// not a live SQL constraint change.** A field's *physical* `NOT NULL` is
/// decided once, at [SchemaEditorService.addField] time, and is
/// permanent from then on -- every v2 field is TEXT with `format` as "a
/// presentation/input hint, never a storage constraint" (phase1 doc), and
/// that same principle extends to `required`: toggling it later through
/// this DAO only changes whether [GenericFormScreen] refuses to save a
/// blank value, never the underlying column's own SQL constraint.
class SchemaMetadataDao {
  Future<SqliteCrdt> get _db async => DatabaseHelper.instance.crdt;

  /// Physical column names currently on [tableName] (`PRAGMA table_info`)
  /// -- used by [ManageFieldsScreen] to filter its "Deleted" section down
  /// to fields that still physically exist, same reasoning as
  /// [ManageTablesScreen]'s analogous table-level filter (see that
  /// screen's own `_loadTables` doc comment for the "hundreds of dead
  /// test-residue rows, no way to tell which are real" incident that
  /// motivated both).
  Future<Set<String>> loadPhysicalColumnNames(String tableName) async {
    assertSafeSqlIdentifier(tableName);
    final db = await _db;
    final columns = await db.query('PRAGMA table_info("$tableName")');
    return {for (final c in columns) c['name'] as String};
  }

  /// Every field for [tableName], ordered by `position`. Includes
  /// soft-deleted rows when [includeDeleted] -- [ManageFieldsScreen]'s
  /// collapsed "Deleted" section needs them; the active field list
  /// doesn't.
  Future<List<FieldDefinitionRow>> loadFields(
    String tableName, {
    required bool includeDeleted,
  }) async {
    assertSafeSqlIdentifier(tableName);
    final db = await _db;
    final where = includeDeleted ? 'table_name = ?1' : 'table_name = ?1 AND is_deleted = 0';
    final rows = await db.query(
      'SELECT * FROM field_definitions WHERE $where ORDER BY position',
      [tableName],
    );
    return [for (final row in rows) FieldDefinitionRow.fromRow(row)];
  }

  /// [tableName]'s own `table_definitions` row, or `null` if it doesn't
  /// exist (or is soft-deleted and [includeDeleted] is false).
  Future<Map<String, Object?>?> loadTable(String tableName, {bool includeDeleted = false}) async {
    assertSafeSqlIdentifier(tableName);
    final db = await _db;
    final where = includeDeleted ? 'table_name = ?1' : 'table_name = ?1 AND is_deleted = 0';
    final rows = await db.query('SELECT * FROM table_definitions WHERE $where', [tableName]);
    return rows.isEmpty ? null : rows.first;
  }

  /// Every table, active and soft-deleted alike, for [ManageTablesScreen]
  /// -- unlike [SchemaRegistry.discoverTableNames] (active only, driving
  /// the real nav), this is the one place both states are shown together
  /// so a soft-deleted table can actually be found again to restore it.
  /// Ordered the same way nav itself would fall back to absent explicit
  /// grouping -- `position` (nulls last), then `table_name`.
  Future<List<TableDefinitionRow>> loadAllTables() async {
    final db = await _db;
    final rows = await db.query(
      'SELECT * FROM table_definitions ORDER BY position IS NULL, position, table_name',
    );
    return [for (final row in rows) TableDefinitionRow.fromRow(row)];
  }

  /// Every active table, ordered by `display_name` -- the shape
  /// [AddFieldScreen]'s "Table"/"Linked to table" pickers and
  /// [ManageFieldsScreen]'s "Table"/"Linked to table" pickers all need
  /// (show `display_name`, submit `table_name` as the real value).
  /// [SchemaRegistry.discoverTableNames] returns bare physical
  /// `table_name`s, which is what all four of those dropdowns used before
  /// this method existed -- found live: renaming "My First" to "My
  /// NewName" via Manage Tables didn't change what Manage Fields' table
  /// picker showed, since it was built from `discoverTableNames()` and
  /// rendered the physical name directly. Same root-cause shape as
  /// `TableConfig`'s own missing `displayName` field (CLAUDE.md
  /// "Essentials v2 Phase 1 -- Step 8"), just in a different,
  /// `TableConfig`-bypassing code path that fix never touched.
  Future<List<TableDefinitionRow>> loadActiveTables() async {
    final db = await _db;
    final rows = await db.query(
      'SELECT * FROM table_definitions WHERE is_deleted = 0 ORDER BY display_name',
    );
    return [for (final row in rows) TableDefinitionRow.fromRow(row)];
  }

  /// Replaces [tableName]'s `display_name`/`description` at once -- same
  /// "callers submit the complete new state" pattern as [updateField].
  /// The physical identifier (`table_name` itself) never changes
  /// (immutable once created, see claude/essentials-v2-phase1-design.md)
  /// -- only these two user-facing attributes are editable after
  /// creation.
  Future<void> updateTable(
    String tableName, {
    required String displayName,
    String? description,
  }) async {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) throw ArgumentError('A table needs a name.');
    final existing = await loadTable(tableName, includeDeleted: true);
    if (existing == null) {
      throw ArgumentError('No table_definitions row for "$tableName".');
    }
    final db = await _db;
    await db.upsert('table_definitions', {
      // Real business columns only -- is_deleted/hlc/node_id/modified are
      // deliberately excluded, not copied forward from [existing]. A real,
      // confirmed bug found live (Essentials v2 Phase 1 -- Step 9 follow-up,
      // see CLAUDE.md): spreading the full `existing` row (as this used to
      // do) carries its OLD `hlc` value along verbatim into this upsert's
      // explicit column list, and sqlite_crdt only auto-stamps a fresh
      // hlc/node_id/modified when a write's SQL *doesn't* mention those
      // columns at all -- explicitly supplying the stale one (even
      // unintentionally, via a spread) freezes it there permanently. A
      // renamed table's row would then never win the CRDT's
      // `WHERE excluded.hlc > table.hlc` last-write-wins comparison against
      // whatever any other device already has for it (same or lesser hlc,
      // forever), so the rename would silently never sync to any other
      // device, no matter how many times it's retried -- confirmed live:
      // pulled the authoring device's own local db directly and found
      // `display_name` correctly updated but `hlc` still exactly the row's
      // original creation timestamp. [updateField] below never had this bug
      // -- it already builds its upsert map from scratch, real columns only,
      // never spreading a prior SELECT's full row.
      for (final entry in existing.entries)
        if (!crdtBookkeepingColumns.contains(entry.key)) entry.key: entry.value,
      'display_name': trimmed,
      'description': description,
    });
  }

  /// Sets/clears [tableName]'s `calendar_field` (Essentials v2 Phase 3) --
  /// same "spread [existing], override just this one column" safe pattern
  /// as [updateTable], for the identical reason (never carry a stale `hlc`
  /// forward). `null` clears the override back to "defaults to the first
  /// date/dateTime field by position" (see `lib/util/calendar_field.dart
  /// .resolveCalendarField`).
  Future<void> updateCalendarField(String tableName, String? calendarFieldJson) async {
    final existing = await loadTable(tableName, includeDeleted: true);
    if (existing == null) {
      throw ArgumentError('No table_definitions row for "$tableName".');
    }
    final db = await _db;
    await db.upsert('table_definitions', {
      for (final entry in existing.entries)
        if (!crdtBookkeepingColumns.contains(entry.key)) entry.key: entry.value,
      'calendar_field': calendarFieldJson,
    });
  }

  /// Replaces every mutable attribute of [tableName].`field_name` at
  /// once -- callers (the edit dialog) always submit the field's complete
  /// new state, pre-populated from its current row, rather than a partial
  /// patch. `position` is preserved from the existing row -- only
  /// [reorderFields] ever changes it.
  Future<void> updateField(
    String tableName,
    String fieldName, {
    required String displayName,
    required String format,
    String? optionsJson,
    String? defaultValue,
    required bool isRequired,
  }) async {
    assertSafeSqlIdentifier(tableName);
    assertSafeSqlIdentifier(fieldName);
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) throw ArgumentError('A field needs a name.');

    final db = await _db;
    final existing = await db.query(
      'SELECT position FROM field_definitions WHERE table_name = ?1 AND field_name = ?2',
      [tableName, fieldName],
    );
    if (existing.isEmpty) {
      throw ArgumentError('No field_definitions row for "$tableName.$fieldName".');
    }

    await db.upsert('field_definitions', {
      'table_name': tableName,
      'field_name': fieldName,
      'display_name': trimmed,
      'format': format,
      'options': optionsJson,
      'default_value': defaultValue,
      'required': isRequired ? 1 : 0,
      'position': existing.first['position'],
    });
  }

  /// Whole-set `position` replace, matching
  /// `TableViewSettingsDao.saveColumnSettings`'s established pattern for
  /// this project's other drag-reorderable lists -- [orderedFieldNames]
  /// is the complete new order for every *active* field on [tableName]
  /// (soft-deleted fields keep whatever position they had when deleted;
  /// [ManageFieldsScreen]'s "Deleted" section isn't reorderable).
  Future<void> reorderFields(String tableName, List<String> orderedFieldNames) async {
    assertSafeSqlIdentifier(tableName);
    final db = await _db;
    for (var i = 0; i < orderedFieldNames.length; i++) {
      final fieldName = orderedFieldNames[i];
      assertSafeSqlIdentifier(fieldName);
      await db.execute(
        'UPDATE field_definitions SET position = ?1 WHERE table_name = ?2 AND field_name = ?3',
        [i, tableName, fieldName],
      );
    }
  }

  /// Stage-1 soft delete (`is_deleted = 1`) -- fully undoable via
  /// [restoreField], no DDL, no data loss: the physical column and
  /// everything already stored in it stay exactly where they are. Just
  /// disappears from the grid/form until restored.
  Future<void> softDeleteField(String tableName, String fieldName) async {
    final db = await _db;
    await db.deleteWhere('field_definitions', {'table_name': tableName, 'field_name': fieldName});
  }

  Future<void> restoreField(String tableName, String fieldName) async {
    assertSafeSqlIdentifier(tableName);
    assertSafeSqlIdentifier(fieldName);
    final db = await _db;
    await db.execute(
      'UPDATE field_definitions SET is_deleted = 0 WHERE table_name = ?1 AND field_name = ?2',
      [tableName, fieldName],
    );
  }

  /// Build order step 8: stage-1 soft delete for *tables*, the same
  /// pattern [softDeleteField]/[restoreField] already proved for fields.
  /// `SchemaRegistry.discoverTableNames`/`buildConfig` already filter on
  /// `table_definitions.is_deleted` (Step 4), so this alone is enough to
  /// make the table vanish from nav on every device -- no other code
  /// needed to touch. Fully undoable via [restoreTable]: no DDL, nothing
  /// about the physical table or its fields' rows changes at all, and
  /// every field on it stays exactly as it was (including which of *its
  /// own* fields were already separately soft-deleted).
  ///
  /// **Known gap, not solved here:** unlike a row-level delete
  /// ([GenericDao.findBlockingReferences]), this doesn't check whether
  /// another table has a `select`/linked field pointing at [tableName].
  /// Soft-deleting doesn't touch data, so an existing linked field keeps
  /// resolving its lookups correctly regardless (`GenericDao
  /// .getLookupOptions` queries the target table's own rows directly, not
  /// `table_definitions`) -- but the target table disappears from
  /// [AddFieldScreen]/[ManageFieldsScreen]'s "Linked to table" picker for
  /// *new* fields, and from nav, which could read as confusing rather
  /// than broken. A real blocking-reference check for table-level delete
  /// is a reasonable candidate for stage-2 (`dropTable`'s own
  /// pre-submission safety check, matching `schema_admin
  /// .checkDropSafety`'s existing spirit) rather than stage-1's job here.
  Future<void> softDeleteTable(String tableName) async {
    final db = await _db;
    await db.deleteWhere('table_definitions', {'table_name': tableName});
  }

  Future<void> restoreTable(String tableName) async {
    assertSafeSqlIdentifier(tableName);
    final db = await _db;
    await db.execute(
      'UPDATE table_definitions SET is_deleted = 0 WHERE table_name = ?1',
      [tableName],
    );
  }
}
