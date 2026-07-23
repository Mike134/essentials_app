import 'package:sqflite/sqflite.dart';

import 'database_helper.dart';

/// One saved column's per-device grid state -- mirrors a row in
/// `table_column_settings`. `frozen` is `null`, `'left'`, or `'right'`.
class ColumnSetting {
  const ColumnSetting({
    required this.columnName,
    this.width,
    this.displayOrder,
    this.visible = true,
    this.frozen,
  });

  final String columnName;
  final double? width;
  final int? displayOrder;
  final bool visible;
  final String? frozen;
}

/// One saved table's per-device sort/filter state -- mirrors the single row
/// (if any) in `table_view_settings` for a table+device. `filterJson` is a
/// JSON-encoded array of `{column, type, value}` objects, one per active
/// TrinaGrid filter row -- see GenericListScreen for the encode/decode.
class ViewSetting {
  const ViewSetting({this.sortColumn, this.sortDirection, this.filterJson});

  final String? sortColumn;
  final String? sortDirection; // 'asc' or 'desc'
  final String? filterJson;
}

/// Reads/writes one table's per-device view state (`table_column_settings`
/// + `table_view_settings`). One instance per [GenericListScreen], scoped to
/// that screen's table and the live [deviceId] (see `lib/util/device_id.dart`).
class TableViewSettingsDao {
  TableViewSettingsDao({required this.tableName, required this.deviceId});

  final String tableName;
  final String deviceId;

  Future<Database> get _db async => DatabaseHelper.instance.database;

  Future<List<ColumnSetting>> loadColumnSettings() async {
    final db = await _db;
    final rows = await db.query(
      'table_column_settings',
      where: 'table_name = ? AND device_id = ?',
      whereArgs: [tableName, deviceId],
    );
    return [
      for (final row in rows)
        ColumnSetting(
          columnName: row['column_name'] as String,
          width: (row['width'] as num?)?.toDouble(),
          displayOrder: row['display_order'] as int?,
          visible: (row['visible'] as int? ?? 1) == 1,
          frozen: row['frozen'] as String?,
        ),
    ];
  }

  Future<ViewSetting?> loadViewSettings() async {
    final db = await _db;
    final rows = await db.query(
      'table_view_settings',
      where: 'table_name = ? AND device_id = ?',
      whereArgs: [tableName, deviceId],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return ViewSetting(
      sortColumn: row['sort_column'] as String?,
      sortDirection: row['sort_direction'] as String?,
      filterJson: row['filter_json'] as String?,
    );
  }

  /// Replaces every `table_column_settings` row for this table+device with
  /// [settings] -- whole-set replace rather than per-column upsert, since
  /// the caller always has the full current column list on hand (there's no
  /// partial-update use case) and this can't drift into stale leftover rows
  /// for columns that no longer apply.
  Future<void> saveColumnSettings(List<ColumnSetting> settings) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.delete(
        'table_column_settings',
        where: 'table_name = ? AND device_id = ?',
        whereArgs: [tableName, deviceId],
      );
      for (final setting in settings) {
        await txn.insert('table_column_settings', {
          'table_name': tableName,
          'device_id': deviceId,
          'column_name': setting.columnName,
          'width': setting.width,
          'display_order': setting.displayOrder,
          'visible': setting.visible ? 1 : 0,
          'frozen': setting.frozen,
        });
      }
    });
  }

  Future<void> saveViewSettings(ViewSetting setting) async {
    final db = await _db;
    await db.insert('table_view_settings', {
      'table_name': tableName,
      'device_id': deviceId,
      'sort_column': setting.sortColumn,
      'sort_direction': setting.sortDirection,
      'filter_json': setting.filterJson,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Clears this table+device's rows from both tables -- "Restore Defaults"
  /// (see GenericListScreen). Structurally cannot touch `app_settings`/
  /// `device_settings` (theme/font/color): different tables entirely, never
  /// referenced here.
  Future<void> restoreDefaults() async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.delete(
        'table_column_settings',
        where: 'table_name = ? AND device_id = ?',
        whereArgs: [tableName, deviceId],
      );
      await txn.delete(
        'table_view_settings',
        where: 'table_name = ? AND device_id = ?',
        whereArgs: [tableName, deviceId],
      );
    });
  }
}
