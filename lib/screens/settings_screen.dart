import 'package:flutter/material.dart';

import '../theme/theme_controller.dart';
import '../theme/theme_preset.dart';

/// Reads/writes `app_settings` (theme, font family, font color, background
/// color -- shared) and `device_settings` (font size -- per-device) via
/// [ThemeController], which owns the actual base-plus-override merge. See
/// CLAUDE.md "Real-usage findings" -- Step 5.
///
/// Every field here writes through immediately on change (dropdowns/slider)
/// or on submit (the two hex fields) -- these are infrequent, deliberate
/// settings changes, not something like column drag that needs debouncing
/// (see `GenericListScreen`'s per-device view-state persistence for that
/// pattern, which doesn't apply here).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _fontColorController;
  late final TextEditingController _backgroundColorController;

  @override
  void initState() {
    super.initState();
    final controller = ThemeController.instance;
    _fontColorController = TextEditingController(
      text: controller.fontColorOverride == null
          ? ''
          : ThemeController.colorToHex(controller.fontColorOverride!),
    );
    _backgroundColorController = TextEditingController(
      text: controller.backgroundColorOverride == null
          ? ''
          : ThemeController.colorToHex(controller.backgroundColorOverride!),
    );
  }

  @override
  void dispose() {
    _fontColorController.dispose();
    _backgroundColorController.dispose();
    super.dispose();
  }

  Future<void> _applyFontColor(ThemeController controller, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      await controller.setFontColorOverride(null);
      return;
    }
    final color = ThemeController.parseHexColor(trimmed);
    if (color == null) {
      _showInvalidHexMessage();
      _fontColorController.text = controller.fontColorOverride == null
          ? ''
          : ThemeController.colorToHex(controller.fontColorOverride!);
      return;
    }
    await controller.setFontColorOverride(color);
  }

  Future<void> _applyBackgroundColor(ThemeController controller, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      await controller.setBackgroundColorOverride(null);
      return;
    }
    final color = ThemeController.parseHexColor(trimmed);
    if (color == null) {
      _showInvalidHexMessage();
      _backgroundColorController.text = controller.backgroundColorOverride == null
          ? ''
          : ThemeController.colorToHex(controller.backgroundColorOverride!);
      return;
    }
    await controller.setBackgroundColorOverride(color);
  }

  void _showInvalidHexMessage() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Not a valid hex color (e.g. #1A73E8).')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: ThemeController.instance,
        builder: (context, _) {
          final controller = ThemeController.instance;
          final preset = presetFor(controller.themeName);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('Theme', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: controller.themeName,
                items: [
                  for (final name in themePresets.keys)
                    DropdownMenuItem(value: name, child: Text(name)),
                ],
                onChanged: (value) {
                  if (value != null) controller.setThemeName(value);
                },
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Font family', style: TextStyle(fontWeight: FontWeight.bold)),
                  if (controller.fontFamilyOverride != null)
                    TextButton(
                      onPressed: () => controller.setFontFamilyOverride(null),
                      child: const Text('Reset to theme'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String?>(
                initialValue: controller.fontFamilyOverride,
                items: [
                  for (final family in fontFamilyChoices)
                    DropdownMenuItem(value: family, child: Text(fontFamilyLabel(family))),
                ],
                onChanged: controller.setFontFamilyOverride,
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Font size (this device)',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (controller.fontSizeOverride != null)
                    TextButton(
                      onPressed: () => controller.setFontSizeOverride(null),
                      child: const Text('Reset to theme'),
                    ),
                ],
              ),
              Slider(
                value: controller.fontSizeOverride ?? preset.fontSize,
                min: 10,
                max: 24,
                divisions: 14,
                label: (controller.fontSizeOverride ?? preset.fontSize).toStringAsFixed(0),
                onChanged: (value) => controller.setFontSizeOverride(value),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Font color', style: TextStyle(fontWeight: FontWeight.bold)),
                  if (controller.fontColorOverride != null)
                    TextButton(
                      onPressed: () {
                        controller.setFontColorOverride(null);
                        _fontColorController.clear();
                      },
                      child: const Text('Reset to theme'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _fontColorController,
                decoration: const InputDecoration(
                  hintText: '#RRGGBB -- blank to use the theme default',
                ),
                onSubmitted: (text) => _applyFontColor(controller, text),
                onTapOutside: (_) => _applyFontColor(controller, _fontColorController.text),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Background color', style: TextStyle(fontWeight: FontWeight.bold)),
                  if (controller.backgroundColorOverride != null)
                    TextButton(
                      onPressed: () {
                        controller.setBackgroundColorOverride(null);
                        _backgroundColorController.clear();
                      },
                      child: const Text('Reset to theme'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _backgroundColorController,
                decoration: const InputDecoration(
                  hintText: '#RRGGBB -- blank to use the theme default',
                ),
                onSubmitted: (text) => _applyBackgroundColor(controller, text),
                onTapOutside: (_) => _applyBackgroundColor(controller, _backgroundColorController.text),
              ),
            ],
          );
        },
      ),
    );
  }
}
