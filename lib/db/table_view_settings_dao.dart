import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'database_helper.dart';
import 'sql_helpers.dart';

/// One saved column's per-device grid state -- mirrors a row in
/// `table_column_settings`. `frozen` is `null`, `'left'`, or `'right'`.
/// `aggregate` is `null` (no footer) or a [TrinaAggregateColumnType] name
/// (`'sum'`, `'average'`, `'min'`, `'max'`, `'count'`) -- stored as its
/// name string rather than the enum itself so this DAO doesn't need a
/// trina_grid import for one column.
class ColumnSetting {
  const ColumnSetting({
    required this.columnName,
    this.width,
    this.displayOrder,
    this.visible = true,
    this.frozen,
    this.wrapText = false,
    this.aggregate,
  });

  final String columnName;
  final double? width;
  final int? displayOrder;
  final bool visible;
  final String? frozen;
  final bool wrapText;
  final String? aggregate;
}

/// One saved table's per-device sort/filter/group/row-color state -- mirrors
/// the single row (if any) in `table_view_settings` for a table+device.
/// `filterJson` is a JSON-encoded array of `{column, type, value}` objects,
/// one per active TrinaGrid filter row -- see GenericListScreen for the
/// encode/decode. `groupColumn` is a single field name (grouping is one
/// column at a time, not stacked -- see GenericListScreen's column menu).
/// `rowColorColumn` is likewise a single field name -- the color field or
/// lookup field (if any) currently driving every record's row text color
/// (see GenericListScreen's "Use Color" column menu item) -- same
/// one-at-a-time reasoning as `groupColumn`, and per-device (not shared,
/// unlike the color/link field flags in `field_metadata`) because which
/// column makes sense to color by -- or whether it looks good at all --
/// can genuinely differ by device (Mike's call).
class ViewSetting {
  const ViewSetting({
    this.sortColumn,
    this.sortDirection,
    this.filterJson,
    this.groupColumn,
    this.rowColorColumn,
  });

  final String? sortColumn;
  final String? sortDirection; // 'asc' or 'desc'
  final String? filterJson;
  final String? groupColumn;
  final String? rowColorColumn;
}

/// Reads/writes one table's per-device view state (`table_column_settings`
/// + `table_view_settings`). One instance per [GenericListScreen], scoped to
/// that screen's table and the live [deviceId] (see `lib/util/device_id.dart`).
class TableViewSettingsDao {
  TableViewSettingsDao({required this.tableName, required this.deviceId});

  final String tableName;
  final String deviceId;

  Future<SqliteCrdt> get _db async => DatabaseHelper.instance.crdt;

  Future<List<ColumnSetting>> loadColumnSettings() async {
    final db = await _db;
    final rows = await db.query(
      'SELECT * FROM table_column_settings '
      'WHERE table_name = ?1 AND device_id = ?2 AND is_deleted = 0',
      [tableName, deviceId],
    );
    return [
      for (final row in rows)
        ColumnSetting(
          columnName: row['column_name'] as String,
          width: (row['width'] as num?)?.toDouble(),
          displayOrder: row['display_order'] as int?,
          visible: (row['visible'] as int? ?? 1) == 1,
          frozen: row['frozen'] as String?,
          wrapText: (row['wrap_text'] as int? ?? 0) == 1,
          aggregate: row['aggregate'] as String?,
        ),
    ];
  }

  Future<ViewSetting?> loadViewSettings() async {
    final db = await _db;
    final rows = await db.query(
      'SELECT * FROM table_view_settings '
      'WHERE table_name = ?1 AND device_id = ?2 AND is_deleted = 0',
      [tableName, deviceId],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return ViewSetting(
      sortColumn: row['sort_column'] as String?,
      sortDirection: row['sort_direction'] as String?,
      filterJson: row['filter_json'] as String?,
      groupColumn: row['group_column'] as String?,
      rowColorColumn: row['row_color_column'] as String?,
    );
  }

  /// Replaces every `table_column_settings` row for this table+device with
  /// [settings]. Per-column upsert (`INSERT OR REPLACE`) plus a scoped
  /// prune, not a blanket delete-then-insert -- sqlite_crdt rewrites a plain
  /// `DELETE` into `UPDATE ... SET is_deleted = 1` (a tombstone, needed so
  /// the deletion itself syncs), so the row physically stays behind. A
  /// delete-everything-then-insert-everything pass would re-insert into a
  /// table that still physically holds the just-tombstoned rows, tripping
  /// the `(table_name, device_id, column_name)` unique constraint on the
  /// very next save for the same table+device (`INSERT OR REPLACE` doesn't
  /// have this problem -- its conflict resolution matches on the unique
  /// constraint regardless of `is_deleted`, so it cleanly replaces the old
  /// row). This is the same `INSERT OR REPLACE` pattern `SqliteCrdtHelpers.
  /// upsert` uses everywhere else in this codebase (see sql_helpers.dart);
  /// hand-rolled here only because this call needs a multi-row transaction,
  /// which that single-row helper doesn't cover.
  Future<void> saveColumnSettings(List<ColumnSetting> settings) async {
    final db = await _db;
    await db.transaction((txn) async {
      final columnNames = settings.map((s) => s.columnName).toList();
      if (columnNames.isEmpty) {
        await txn.execute(
          'DELETE FROM table_column_settings WHERE table_name = ?1 AND device_id = ?2',
          [tableName, deviceId],
        );
      } else {
        final placeholders = List.generate(
          columnNames.length,
          (i) => '?${i + 3}',
        ).join(', ');
        await txn.execute(
          'DELETE FROM table_column_settings '
          'WHERE table_name = ?1 AND device_id = ?2 AND column_name NOT IN ($placeholders)',
          [tableName, deviceId, ...columnNames],
        );
      }
      for (final setting in settings) {
        await txn.execute(
          'INSERT OR REPLACE INTO table_column_settings '
          '(table_name, device_id, column_name, width, display_order, visible, frozen, wrap_text, aggregate) '
          'VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)',
          [
            tableName,
            deviceId,
            setting.columnName,
            setting.width,
            setting.displayOrder,
            setting.visible ? 1 : 0,
            setting.frozen,
            setting.wrapText ? 1 : 0,
            setting.aggregate,
          ],
        );
      }
    });
  }

  Future<void> saveViewSettings(ViewSetting setting) async {
    final db = await _db;
    await db.upsert('table_view_settings', {
      'table_name': tableName,
      'device_id': deviceId,
      'sort_column': setting.sortColumn,
      'sort_direction': setting.sortDirection,
      'filter_json': setting.filterJson,
      'group_column': setting.groupColumn,
      'row_color_column': setting.rowColorColumn,
    });
  }

  /// Clears this table+device's rows from both tables -- "Restore Defaults"
  /// (see GenericListScreen). Structurally cannot touch `app_settings`/
  /// `device_settings` (theme/font/color): different tables entirely, never
  /// referenced here.
  Future<void> restoreDefaults() async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.execute(
        'DELETE FROM table_column_settings WHERE table_name = ?1 AND device_id = ?2',
        [tableName, deviceId],
      );
      await txn.execute(
        'DELETE FROM table_view_settings WHERE table_name = ?1 AND device_id = ?2',
        [tableName, deviceId],
      );
    });
  }
}
