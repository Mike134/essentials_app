import 'package:flutter/material.dart';

import '../db/theme_settings_dao.dart';
import '../util/device_id.dart';
import 'theme_preset.dart';

/// Singleton (same pattern as `DatabaseHelper.instance`), app-lifetime,
/// never disposed -- holds the current theme selection plus each
/// attribute's explicit override (if any), computes the merged
/// [ThemeData], and persists changes as they're made.
///
/// **Load timing, deliberate:** [load] is *not* called from `main.dart` at
/// app root -- on Android, the db isn't reachable until
/// `PermissionGate` confirms `MANAGE_EXTERNAL_STORAGE`, and calling it
/// earlier would race that screen's own permission-request flow. Instead
/// `HomeShell.initState` calls [load] (alongside its existing grouping
/// load), which only ever runs once the db is known reachable on both
/// platforms. Until then, [themeData] returns the default preset with no
/// overrides -- a reasonable look for the brief permission-gate/splash
/// window, not a blocking spinner at the very top of the widget tree.
class ThemeController extends ChangeNotifier {
  ThemeController._();

  static final ThemeController instance = ThemeController._();

  String themeName = defaultThemeName;
  String? fontFamilyOverride;
  double? fontSizeOverride;
  Color? fontColorOverride;
  Color? backgroundColorOverride;

  /// Defaults matching TrinaGrid's own out-of-the-box row height
  /// (`TrinaGridSettings.rowHeight`) and this app's original fixed 3x
  /// multiplier for wrapped rows -- unlike the four theme attributes above,
  /// neither has a [ThemePreset] to fall back to, there's no "row height"
  /// concept in a theme, so these fall back straight to a literal default.
  static const double defaultRowHeight = 45.0;
  static const double defaultWrapRowHeight = defaultRowHeight * 3;

  double? rowHeightOverride;
  double? wrapRowHeightOverride;

  double get rowHeight => rowHeightOverride ?? defaultRowHeight;
  double get wrapRowHeight => wrapRowHeightOverride ?? defaultWrapRowHeight;

  ThemeSettingsDao? _dao;
  bool _loaded = false;
  bool get loaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;

    final deviceId = await DeviceId.resolve();
    final dao = _dao ??= ThemeSettingsDao(deviceId: deviceId);

    final appSettings = await dao.loadAppSettings();
    themeName = appSettings['theme_name'] ?? defaultThemeName;
    fontFamilyOverride = _nullIfEmpty(appSettings['font_family']);
    fontColorOverride = parseHexColor(appSettings['font_color']);
    backgroundColorOverride = parseHexColor(appSettings['background_color']);

    final fontSizeText = await dao.loadDeviceFontSize();
    fontSizeOverride = fontSizeText == null ? null : double.tryParse(fontSizeText);

    final rowHeightText = await dao.loadDeviceSetting(ThemeSettingsDao.noWrapRowHeightKey);
    rowHeightOverride = rowHeightText == null ? null : double.tryParse(rowHeightText);

    final wrapRowHeightText = await dao.loadDeviceSetting(ThemeSettingsDao.wrapRowHeightKey);
    wrapRowHeightOverride = wrapRowHeightText == null ? null : double.tryParse(wrapRowHeightText);

    _loaded = true;
    notifyListeners();
  }

  Future<void> setThemeName(String name) async {
    themeName = name;
    await _dao?.setAppSetting('theme_name', name);
    notifyListeners();
  }

  Future<void> setFontFamilyOverride(String? family) async {
    fontFamilyOverride = family;
    await _dao?.setAppSetting('font_family', family);
    notifyListeners();
  }

  Future<void> setFontColorOverride(Color? color) async {
    fontColorOverride = color;
    await _dao?.setAppSetting('font_color', color == null ? null : colorToHex(color));
    notifyListeners();
  }

  Future<void> setBackgroundColorOverride(Color? color) async {
    backgroundColorOverride = color;
    await _dao?.setAppSetting(
      'background_color',
      color == null ? null : colorToHex(color),
    );
    notifyListeners();
  }

  Future<void> setFontSizeOverride(double? size) async {
    fontSizeOverride = size;
    await _dao?.setDeviceFontSize(size?.toString());
    notifyListeners();
  }

  Future<void> setRowHeightOverride(double? height) async {
    rowHeightOverride = height;
    await _dao?.setDeviceSetting(ThemeSettingsDao.noWrapRowHeightKey, height?.toString());
    notifyListeners();
  }

  Future<void> setWrapRowHeightOverride(double? height) async {
    wrapRowHeightOverride = height;
    await _dao?.setDeviceSetting(ThemeSettingsDao.wrapRowHeightKey, height?.toString());
    notifyListeners();
  }

  /// The base-plus-override merge itself -- each of the four overridable
  /// attributes falls back independently to [presetFor]'s value when null,
  /// per CLAUDE.md's "Theme override model": symmetric across all four,
  /// not an all-or-nothing switch between presets.
  ThemeData get themeData {
    final preset = presetFor(themeName);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: preset.seedColor,
      brightness: preset.brightness,
    );
    final backgroundColor = backgroundColorOverride ?? colorScheme.surface;
    final fontColor = fontColorOverride ?? colorScheme.onSurface;
    final fontFamily = fontFamilyOverride ?? preset.fontFamily;
    final fontSize = fontSizeOverride ?? preset.fontSize;

    final base = ThemeData(
      brightness: preset.brightness,
      colorScheme: colorScheme.copyWith(surface: backgroundColor, onSurface: fontColor),
      scaffoldBackgroundColor: backgroundColor,
      fontFamily: fontFamily,
    );

    // `base.textTheme` has no `fontSize` set on any style yet -- Flutter fills
    // those in later, per-locale, when the `Theme` widget calls
    // `ThemeData.localize` (English gets `typography.englishLike`, CJK
    // `dense`, Farsi `tall`). Applying a non-1.0 fontSizeFactor to a style
    // whose own fontSize is still null trips TextStyle.apply's assertion, so
    // merge in that same geometry ourselves first to give every style a size
    // to scale from.
    final sizedTextTheme = base.typography.englishLike.merge(base.textTheme);

    return base.copyWith(
      textTheme: sizedTextTheme.apply(
        fontSizeFactor: fontSize / preset.fontSize,
        bodyColor: fontColor,
        displayColor: fontColor,
      ),
    );
  }

  static String? _nullIfEmpty(String? value) => (value == null || value.isEmpty) ? null : value;

  static Color? parseHexColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    var cleaned = hex.trim().replaceFirst('#', '');
    if (cleaned.length == 6) cleaned = 'FF$cleaned';
    final value = int.tryParse(cleaned, radix: 16);
    return value == null ? null : Color(value);
  }

  static String colorToHex(Color color) {
    return '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
  }
}
