import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'database_helper.dart';
import 'sql_helpers.dart';

/// Reads/writes theme/font/color settings -- `app_settings` (shared: theme
/// name, font family, font color, background color) and `device_settings`
/// (per-device: font size, and the grid's wrap/no-wrap row heights -- all
/// attributes where shared didn't make sense, same real DPI/screen-size
/// reasoning as font size for the two row heights: what reads as a
/// comfortable row height on a Windows monitor isn't the same number on an
/// Android phone). See CLAUDE.md "Real-usage findings" -- "Settings
/// methodology."
class ThemeSettingsDao {
  ThemeSettingsDao({required this.deviceId});

  final String deviceId;

  static const String fontSizeKey = 'font_size';
  static const String noWrapRowHeightKey = 'no_wrap_row_height';
  static const String wrapRowHeightKey = 'wrap_row_height';

  Future<SqliteCrdt> get _db async => DatabaseHelper.instance.crdt;

  Future<Map<String, String>> loadAppSettings() async {
    final db = await _db;
    final rows = await db.query('SELECT * FROM app_settings WHERE is_deleted = 0');
    return {
      for (final row in rows) row['key'] as String: row['value'] as String? ?? '',
    };
  }

  /// Generic per-device key/value read -- backs [loadDeviceFontSize] and the
  /// grid row-height settings ([GenericListScreen]'s wrap-text feature)
  /// alike, same `device_settings` table (`device_id`, `key`) -> `value`,
  /// no schema change needed per new setting.
  Future<String?> loadDeviceSetting(String key) async {
    final db = await _db;
    final rows = await db.query(
      'SELECT * FROM device_settings WHERE device_id = ?1 AND key = ?2 AND is_deleted = 0',
      [deviceId, key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setDeviceSetting(String key, String? value) async {
    final db = await _db;
    if (value == null) {
      await db.deleteWhere('device_settings', {'device_id': deviceId, 'key': key});
    } else {
      await db.upsert('device_settings', {
        'device_id': deviceId,
        'key': key,
        'value': value,
      });
    }
  }

  /// `null` deletes the row -- app_settings is a flexible key-value store
  /// with no `NOT NULL` on `value`, but a missing row (not a stored null)
  /// is what "no override, fall back to the theme preset" means throughout
  /// this app's override model.
  Future<void> setAppSetting(String key, String? value) async {
    final db = await _db;
    if (value == null) {
      await db.deleteWhere('app_settings', {'key': key});
    } else {
      await db.upsert('app_settings', {'key': key, 'value': value});
    }
  }

  Future<String?> loadDeviceFontSize() => loadDeviceSetting(fontSizeKey);

  Future<void> setDeviceFontSize(String? value) => setDeviceSetting(fontSizeKey, value);
}
