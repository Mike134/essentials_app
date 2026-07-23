import 'package:flutter/material.dart';

/// A named base theme -- supplies default values for font family, font
/// size, font color, and background color (the latter two derived from
/// [seedColor]'s generated [ColorScheme], not hardcoded hex, so they stay
/// in Material 3's color harmony). See CLAUDE.md "Real-usage findings" --
/// "Theme override model": an explicit value in `app_settings`/
/// `device_settings` for any one of those four attributes overrides what
/// the active preset would otherwise supply for that attribute alone, a
/// base-plus-override merge (see [ThemeController]), not an all-or-nothing
/// switch between presets.
class ThemePreset {
  const ThemePreset({
    required this.brightness,
    required this.seedColor,
    this.fontFamily,
    this.fontSize = 14,
  });

  final Brightness brightness;
  final Color seedColor;

  /// Null means "platform default" -- this app bundles no font assets
  /// (see pubspec.yaml), so family choices are limited to names the OS's
  /// own font resolution can already find (see [fontFamilyChoices]).
  final String? fontFamily;

  final double fontSize;
}

/// Only two presets for now -- Mike hasn't asked for more, and the
/// override model means any one-off tweak (a specific font color, a
/// larger size on the phone) doesn't need its own preset, just an
/// override on top of Light or Dark.
const Map<String, ThemePreset> themePresets = {
  'Light': ThemePreset(brightness: Brightness.light, seedColor: Colors.teal),
  'Dark': ThemePreset(brightness: Brightness.dark, seedColor: Colors.teal),
};

const String defaultThemeName = 'Light';

ThemePreset presetFor(String themeName) =>
    themePresets[themeName] ?? themePresets[defaultThemeName]!;

/// Curated, not arbitrary free text -- with no bundled font assets, an
/// arbitrary family name would silently fall back to the platform default
/// anyway (Flutter doesn't error on an unresolvable family), so offering
/// only names likely to actually resolve on both Windows and Android
/// avoids a picker full of options that all look identical. `null` means
/// "use the preset's own default."
const List<String?> fontFamilyChoices = [
  null,
  'Roboto',
  'Georgia',
  'Consolas',
];

String fontFamilyLabel(String? family) => family ?? 'Default (from theme)';
