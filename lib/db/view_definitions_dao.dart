import 'dart:convert';

import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../util/sql_identifiers.dart';
import 'database_helper.dart';
import 'sql_helpers.dart';

/// One `view_definitions` row -- a saved List/Kanban (per-table) or
/// Calendar (aggregate, [tableName] `null`) view. See
/// claude/essentials-v2-phase3-design.md, "Data model" -- shared/synced,
/// same bucket as `table_definitions`/`field_definitions`, not per-device
/// like `table_column_settings`/`table_view_settings`.
class ViewDefinition {
  ViewDefinition({
    required this.viewId,
    required this.tableName,
    required this.viewType,
    required this.displayName,
    required this.position,
    required this.config,
    required this.createdAt,
    required this.isDeleted,
    required this.modified,
  });

  factory ViewDefinition.fromRow(Map<String, Object?> row) {
    final configJson = row['config'] as String?;
    Map<String, Object?> config = const {};
    if (configJson != null && configJson.trim().isNotEmpty) {
      final decoded = jsonDecode(configJson);
      if (decoded is Map) config = decoded.cast<String, Object?>();
    }
    return ViewDefinition(
      viewId: row['view_id'] as int,
      tableName: row['table_name'] as String?,
      viewType: row['view_type'] as String,
      displayName: row['display_name'] as String,
      position: row['position'] as int?,
      config: config,
      createdAt: row['created_at'] as String,
      isDeleted: (row['is_deleted'] as int) == 1,
      modified: row['modified'] as String,
    );
  }

  final int viewId;
  final String? tableName;
  final String viewType; // 'list' | 'calendar' | 'kanban'
  final String displayName;
  final int? position;
  final Map<String, Object?> config;
  final String createdAt;
  final bool isDeleted;
  final String modified;
}

/// CRUD for `view_definitions` -- sibling of `SchemaMetadataDao`, same
/// soft-delete/restore shape and the same `INSERT OR REPLACE` upsert
/// convention every other maintenance write in this app already uses. See
/// claude/essentials-v2-phase3-design.md, "`ViewDefinitionsDao` (new)".
///
/// Deliberately never authors a `migration_log` entry -- the physical
/// `view_definitions` table itself is created once, out-of-band, by
/// `tool/add_view_definitions_table.dart` (mirroring how `table_definitions`/
/// `field_definitions` were originally bootstrapped -- see CLAUDE.md's
/// Essentials v2 Phase 1 write-up). Every method here is a plain row-level
/// CRDT write against an already-existing table, same as `SchemaMetadataDao`.
class ViewDefinitionsDao {
  Future<SqliteCrdt> get _db async => DatabaseHelper.instance.crdt;

  /// Active (`is_deleted = 0`) List/Kanban views belonging to [tableName],
  /// ordered by `position`. Never returns the aggregate Calendar row
  /// (`table_name IS NULL`) -- see [loadCalendarView] for that.
  Future<List<ViewDefinition>> loadViewsForTable(String tableName) async {
    final db = await _db;
    final rows = await db.query(
      'SELECT * FROM view_definitions '
      'WHERE table_name = ?1 AND is_deleted = 0 '
      'ORDER BY position IS NULL, position, view_id',
      [tableName],
    );
    return [for (final row in rows) ViewDefinition.fromRow(row)];
  }

  /// Every view for [tableName], active and soft-deleted alike -- for
  /// `ManageViewsScreen`, the one place both states are shown together so a
  /// soft-deleted view can actually be found again to restore it. Unlike
  /// `SchemaMetadataDao.loadAllTables`'s table-level counterpart, this
  /// needs no "does the soft-deleted row still physically exist" filter --
  /// there is no stage-2 hard-delete for views in this phase (see the
  /// design doc's "Confirmed decisions"), so a soft-deleted view is always
  /// fully recoverable.
  Future<List<ViewDefinition>> loadAllViewsForTable(String tableName) async {
    final db = await _db;
    final rows = await db.query(
      'SELECT * FROM view_definitions '
      'WHERE table_name = ?1 '
      'ORDER BY position IS NULL, position, view_id',
      [tableName],
    );
    return [for (final row in rows) ViewDefinition.fromRow(row)];
  }

  /// The one active `table_name IS NULL` (`view_type = 'calendar'`) row, if
  /// it's ever been created -- `null` otherwise. Only one calendar view is
  /// ever created in this phase (see the design doc's "Confirmed decisions"),
  /// but this reads the first active match rather than assuming exactly one
  /// row exists, in case that's ever relaxed later.
  Future<ViewDefinition?> loadCalendarView() async {
    final db = await _db;
    final rows = await db.query(
      "SELECT * FROM view_definitions "
      "WHERE table_name IS NULL AND view_type = 'calendar' AND is_deleted = 0 "
      'ORDER BY view_id LIMIT 1',
    );
    return rows.isEmpty ? null : ViewDefinition.fromRow(rows.first);
  }

  /// Creates a new view, appended after every existing view for the same
  /// scope ([tableName], or the aggregate calendar scope when `null`).
  /// Returns the new row's real `view_id`.
  ///
  /// `view_id` needs the same explicit-`DEFAULT`-injection handling
  /// `GenericDao.insert`/`SchemaEditorService` already established for every
  /// other timestamp+random-id table -- omitting it from the INSERT would
  /// silently bypass the column's own `DEFAULT` and hand back a small
  /// sequential rowid instead (SQLite's rowid-alias auto-assignment ignores
  /// a column's `DEFAULT` whenever that column is omitted).
  Future<int> createView({
    required String? tableName,
    required String viewType,
    required String displayName,
    Map<String, Object?> config = const {},
  }) async {
    final trimmedName = displayName.trim();
    if (trimmedName.isEmpty) throw ArgumentError('A view needs a name.');
    if (tableName != null) assertSafeSqlIdentifier(tableName);

    final db = await _db;
    final idDefault = await _viewIdDefaultExpression(db);
    final nextPosition = await _nextPosition(db, tableName: tableName);
    final createdAt = DateTime.now().toUtc().toIso8601String();

    late final int viewId;
    await db.transaction((txn) async {
      final columnList = idDefault == null
          ? 'table_name, view_type, display_name, position, config, created_at'
          : 'view_id, table_name, view_type, display_name, position, config, created_at';
      final valuesSql = idDefault == null
          ? '?1, ?2, ?3, ?4, ?5, ?6'
          : '($idDefault), ?1, ?2, ?3, ?4, ?5, ?6';
      await txn.execute(
        'INSERT INTO view_definitions ($columnList) VALUES ($valuesSql)',
        [tableName, viewType, trimmedName, nextPosition, jsonEncode(config), createdAt],
      );
      final result = await txn.query('SELECT last_insert_rowid() AS id');
      viewId = result.first['id'] as int;
    });
    return viewId;
  }

  Future<void> renameView(int viewId, String displayName) async {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) throw ArgumentError('A view needs a name.');
    final db = await _db;
    await db.execute(
      'UPDATE view_definitions SET display_name = ?1 WHERE view_id = ?2',
      [trimmed, viewId],
    );
  }

  Future<void> updateViewConfig(int viewId, Map<String, Object?> config) async {
    final db = await _db;
    await db.execute(
      'UPDATE view_definitions SET config = ?1 WHERE view_id = ?2',
      [jsonEncode(config), viewId],
    );
  }

  /// Whole-set `position` replace, matching `SchemaMetadataDao.reorderFields`'s
  /// established pattern -- [orderedViewIds] is the complete new order for
  /// every active view in [tableName]'s scope.
  Future<void> reorderViews(String? tableName, List<int> orderedViewIds) async {
    final db = await _db;
    for (var i = 0; i < orderedViewIds.length; i++) {
      await db.execute(
        'UPDATE view_definitions SET position = ?1 WHERE view_id = ?2',
        [i, orderedViewIds[i]],
      );
    }
  }

  /// Fully undoable (`is_deleted` tombstone, no DDL) -- same shape as
  /// `SchemaMetadataDao.softDeleteField`/`softDeleteTable`. There is no
  /// stage-2 hard-delete for views in this phase; a soft-deleted view just
  /// stays hidden from [loadViewsForTable]/[loadCalendarView] forever unless
  /// restored.
  Future<void> softDeleteView(int viewId) async {
    final db = await _db;
    await db.deleteWhere('view_definitions', {'view_id': viewId});
  }

  Future<void> restoreView(int viewId) async {
    final db = await _db;
    await db.execute(
      'UPDATE view_definitions SET is_deleted = 0 WHERE view_id = ?1',
      [viewId],
    );
  }

  Future<int> _nextPosition(SqliteCrdt db, {required String? tableName}) async {
    final where = tableName == null ? 'table_name IS NULL' : 'table_name = ?1';
    final args = tableName == null ? <Object?>[] : [tableName];
    final rows = await db.query(
      'SELECT COALESCE(MAX(position), -1) AS max_position FROM view_definitions WHERE $where',
      args,
    );
    return (rows.first['max_position'] as int) + 1;
  }

  /// `view_definitions.view_id`'s own SQL `DEFAULT` expression -- same
  /// lookup shape as `GenericDao._idDefaultExpression`/`SchemaEditorService
  /// ._migrationLogIdDefault`, repeated rather than shared since this DAO
  /// isn't a `GenericDao` table (a real column name, `view_id`, not the
  /// generic `id` every `GenericDao` table uses).
  Future<String?> _viewIdDefaultExpression(SqliteCrdt db) async {
    final columns = await db.query('PRAGMA table_info("view_definitions")');
    for (final column in columns) {
      if (column['name'] == 'view_id') return column['dflt_value'] as String?;
    }
    return null;
  }
}
