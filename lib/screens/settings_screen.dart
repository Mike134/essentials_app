import 'package:flutter/material.dart';

import '../theme/theme_controller.dart';
import '../theme/theme_preset.dart';
import '../util/color_picker.dart';
import 'add_column_screen.dart';
import 'field_metadata_screen.dart';

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

  Future<void> _pickFontColor(ThemeController controller, Color current) async {
    final picked = await pickColor(context, initial: current);
    if (picked == null) return;
    _fontColorController.text = ThemeController.colorToHex(picked);
    await controller.setFontColorOverride(picked);
  }

  Future<void> _pickBackgroundColor(ThemeController controller, Color current) async {
    final picked = await pickColor(context, initial: current);
    if (picked == null) return;
    _backgroundColorController.text = ThemeController.colorToHex(picked);
    await controller.setBackgroundColorOverride(picked);
  }

  Widget _colorSwatch(Color color) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.grey),
      ),
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
              const Text(
                'Grid row height (this device)',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('No wrap: ${controller.rowHeight.toStringAsFixed(0)}px'),
                  if (controller.rowHeightOverride != null)
                    TextButton(
                      onPressed: () => controller.setRowHeightOverride(null),
                      child: const Text('Reset to default'),
                    ),
                ],
              ),
              Slider(
                value: controller.rowHeight,
                min: 30,
                max: 80,
                divisions: 50, // 1px steps -- (max - min) / divisions
                label: controller.rowHeight.toStringAsFixed(0),
                onChanged: (value) => controller.setRowHeightOverride(value),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Wrapped: ${controller.wrapRowHeight.toStringAsFixed(0)}px'),
                  if (controller.wrapRowHeightOverride != null)
                    TextButton(
                      onPressed: () => controller.setWrapRowHeightOverride(null),
                      child: const Text('Reset to default'),
                    ),
                ],
              ),
              Slider(
                value: controller.wrapRowHeight,
                min: 60,
                max: 300,
                divisions: 120, // 2px steps -- (max - min) / divisions
                label: controller.wrapRowHeight.toStringAsFixed(0),
                onChanged: (value) => controller.setWrapRowHeightOverride(value),
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
                decoration: InputDecoration(
                  hintText: '#RRGGBB -- blank to use the theme default',
                  suffixIcon: IconButton(
                    icon: _colorSwatch(
                      controller.fontColorOverride ?? Theme.of(context).colorScheme.onSurface,
                    ),
                    tooltip: 'Pick a color',
                    onPressed: () => _pickFontColor(
                      controller,
                      controller.fontColorOverride ?? Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
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
                decoration: InputDecoration(
                  hintText: '#RRGGBB -- blank to use the theme default',
                  suffixIcon: IconButton(
                    icon: _colorSwatch(
                      controller.backgroundColorOverride ?? Theme.of(context).scaffoldBackgroundColor,
                    ),
                    tooltip: 'Pick a color',
                    onPressed: () => _pickBackgroundColor(
                      controller,
                      controller.backgroundColorOverride ??
                          Theme.of(context).scaffoldBackgroundColor,
                    ),
                  ),
                ),
                onSubmitted: (text) => _applyBackgroundColor(controller, text),
                onTapOutside: (_) => _applyBackgroundColor(controller, _backgroundColorController.text),
              ),
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 16),
              const Text('Field Labels & Defaults', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                'Overrides a table\'s auto-derived field labels, insert '
                'defaults, lookup display columns, and link-field flags. Was '
                'edited via Letos; now lives here instead so changes actually '
                'sync to other devices.',
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const FieldMetadataScreen())),
                child: const Text('Edit field overrides'),
              ),
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 16),
              const Text('Schema Changes', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                'Adds a column via ALTER TABLE, on this device only -- sqlite_crdt '
                'never propagates a schema change, so this needs running again on '
                'every other device. Removing a table or column stays a manual, '
                'external process on purpose -- see CLAUDE.md.',
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const AddColumnScreen())),
                child: const Text('Add a column'),
              ),
            ],
          );
        },
      ),
    );
  }
}
