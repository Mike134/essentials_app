import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'database_helper.dart';
import 'sql_helpers.dart';

/// One saved column's per-device grid state -- mirrors a row in
/// `table_column_settings`. `frozen` is `null`, `'left'`, or `'right'`.
class ColumnSetting {
  const ColumnSetting({
    required this.columnName,
    this.width,
    this.displayOrder,
    this.visible = true,
    this.frozen,
    this.wrapText = false,
  });

  final String columnName;
  final double? width;
  final int? displayOrder;
  final bool visible;
  final String? frozen;
  final bool wrapText;
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
      await txn.execute(
        'DELETE FROM table_column_settings WHERE table_name = ?1 AND device_id = ?2',
        [tableName, deviceId],
      );
      for (final setting in settings) {
        await txn.execute(
          'INSERT INTO table_column_settings '
          '(table_name, device_id, column_name, width, display_order, visible, frozen, wrap_text) '
          'VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)',
          [
            tableName,
            deviceId,
            setting.columnName,
            setting.width,
            setting.displayOrder,
            setting.visible ? 1 : 0,
            setting.frozen,
            setting.wrapText ? 1 : 0,
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
