import 'package:sqflite/sqflite.dart';

import 'database_helper.dart';

/// Reads/writes theme/font/color settings -- `app_settings` (shared: theme
/// name, font family, font color, background color) and `device_settings`
/// (per-device: font size only, the one attribute where shared didn't make
/// sense -- real DPI/screen-size differences between Windows desktop and
/// an Android phone). See CLAUDE.md "Real-usage findings" -- "Settings
/// methodology."
class ThemeSettingsDao {
  ThemeSettingsDao({required this.deviceId});

  final String deviceId;

  static const String fontSizeKey = 'font_size';

  Future<Database> get _db async => DatabaseHelper.instance.database;

  Future<Map<String, String>> loadAppSettings() async {
    final db = await _db;
    final rows = await db.query('app_settings');
    return {
      for (final row in rows) row['key'] as String: row['value'] as String? ?? '',
    };
  }

  /// `null` deletes the row -- app_settings is a flexible key-value store
  /// with no `NOT NULL` on `value`, but a missing row (not a stored null)
  /// is what "no override, fall back to the theme preset" means throughout
  /// this app's override model.
  Future<void> setAppSetting(String key, String? value) async {
    final db = await _db;
    if (value == null) {
      await db.delete('app_settings', where: 'key = ?', whereArgs: [key]);
    } else {
      await db.insert(
        'app_settings',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  Future<String?> loadDeviceFontSize() async {
    final db = await _db;
    final rows = await db.query(
      'device_settings',
      where: 'device_id = ? AND key = ?',
      whereArgs: [deviceId, fontSizeKey],
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setDeviceFontSize(String? value) async {
    final db = await _db;
    if (value == null) {
      await db.delete(
        'device_settings',
        where: 'device_id = ? AND key = ?',
        whereArgs: [deviceId, fontSizeKey],
      );
    } else {
      await db.insert('device_settings', {
        'device_id': deviceId,
        'key': fontSizeKey,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }
}
