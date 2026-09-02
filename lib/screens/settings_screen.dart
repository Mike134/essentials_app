import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../db/database_backup_service.dart';
import '../db/search_index_service.dart';
import '../theme/theme_controller.dart';
import '../theme/theme_preset.dart';
import '../util/color_picker.dart';
import 'add_field_screen.dart';
import 'manage_events_screen.dart';
import 'manage_fields_screen.dart';
import 'manage_tables_screen.dart';
import 'new_table_screen.dart';
import 'scheduled_events_screen.dart';

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
  late final TextEditingController _gridStripeColorController;
  late final TextEditingController _listStripeColorController;
  bool _rebuildingSearchIndex = false;
  bool _backingUp = false;

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
    _gridStripeColorController = TextEditingController(
      text: controller.gridStripeColorOverride == null
          ? ''
          : ThemeController.colorToHex(controller.gridStripeColorOverride!),
    );
    _listStripeColorController = TextEditingController(
      text: controller.listStripeColorOverride == null
          ? ''
          : ThemeController.colorToHex(controller.listStripeColorOverride!),
    );
  }

  @override
  void dispose() {
    _fontColorController.dispose();
    _backgroundColorController.dispose();
    _gridStripeColorController.dispose();
    _listStripeColorController.dispose();
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

  /// Essentials v2 Phase 6 (Global Search) manual escape hatch, for the
  /// known, accepted staleness gap `SearchIndexService`'s own doc comment
  /// describes -- a field's format changing or a new field being added
  /// touches only `field_definitions` metadata, no row data, so no reindex
  /// hook fires for it. This forces a full rebuild across every table.
  Future<void> _rebuildSearchIndex() async {
    setState(() => _rebuildingSearchIndex = true);
    try {
      await SearchIndexService().reindexAll();
    } finally {
      if (mounted) setState(() => _rebuildingSearchIndex = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Search index rebuilt.')),
    );
  }

  /// "Backup Database" -- Essentials v2 Phase 7, build order step 5.
  /// Picks a destination *folder*, not a destination file -- `VACUUM INTO`
  /// refuses to overwrite an already-existing file (see
  /// [DatabaseBackupService.backupTo]'s own doc comment), which rules out
  /// `FilePicker.saveFile`: this pinned file_picker version's `saveFile`
  /// requires `bytes` up front and writes them itself, so the target path
  /// it hands back already has a file sitting at it by the time this code
  /// would run `VACUUM INTO` against it. `FilePicker.getDirectoryPath`
  /// sidesteps that entirely -- pick a folder, then generate a
  /// guaranteed-fresh filename inside it. No progress UI -- `VACUUM INTO`
  /// on a personal-scale database is expected to be fast, confirmed
  /// against Mike's actual data volume during real-device verification,
  /// not assumed indefinitely (see the design doc's own "UI integration"
  /// note).
  Future<void> _backupDatabase() async {
    setState(() => _backingUp = true);
    try {
      final directory = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose a backup location',
      );
      if (directory == null) return; // user cancelled
      final service = DatabaseBackupService();
      final destination = p.join(directory, service.suggestedFileName());
      await service.backupTo(destination);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Backed up to $destination')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Backup failed: $e')));
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  Future<void> _applyGridStripeColor(ThemeController controller, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      await controller.setGridStripeColorOverride(null);
      return;
    }
    final color = ThemeController.parseHexColor(trimmed);
    if (color == null) {
      _showInvalidHexMessage();
      _gridStripeColorController.text = controller.gridStripeColorOverride == null
          ? ''
          : ThemeController.colorToHex(controller.gridStripeColorOverride!);
      return;
    }
    await controller.setGridStripeColorOverride(color);
  }

  Future<void> _applyListStripeColor(ThemeController controller, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      await controller.setListStripeColorOverride(null);
      return;
    }
    final color = ThemeController.parseHexColor(trimmed);
    if (color == null) {
      _showInvalidHexMessage();
      _listStripeColorController.text = controller.listStripeColorOverride == null
          ? ''
          : ThemeController.colorToHex(controller.listStripeColorOverride!);
      return;
    }
    await controller.setListStripeColorOverride(color);
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

  Future<void> _pickGridStripeColor(ThemeController controller, Color current) async {
    final picked = await pickColor(context, initial: current);
    if (picked == null) return;
    _gridStripeColorController.text = ThemeController.colorToHex(picked);
    await controller.setGridStripeColorOverride(picked);
  }

  Future<void> _pickListStripeColor(ThemeController controller, Color current) async {
    final picked = await pickColor(context, initial: current);
    if (picked == null) return;
    _listStripeColorController.text = ThemeController.colorToHex(picked);
    await controller.setListStripeColorOverride(picked);
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
            // Real bug, found live on 12R (three-button nav bar): a plain
            // EdgeInsets.all(16) has no idea the system nav bar exists, so
            // the last row of content (the schema-engine buttons) sat
            // partly underneath it -- visible but not reliably tappable.
            // Scaffold's own `body` slot does NOT automatically avoid
            // system UI the way people often assume; only explicitly
            // consulting MediaQuery's bottom inset (or wrapping in
            // SafeArea) does. Added on top of the existing uniform 16, not
            // replacing it, so nothing above the bottom edge changes.
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
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
              const Text('Row colors', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Alternate row colors in Grid view'),
                value: controller.gridStripeEnabled,
                onChanged: (v) => controller.setGridStripeEnabled(v ?? false),
              ),
              if (controller.gridStripeEnabled) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Grid stripe color'),
                    if (controller.gridStripeColorOverride != null)
                      TextButton(
                        onPressed: () {
                          controller.setGridStripeColorOverride(null);
                          _gridStripeColorController.clear();
                        },
                        child: const Text('Reset to default'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _gridStripeColorController,
                  decoration: InputDecoration(
                    hintText: '#RRGGBB -- blank to use the default',
                    suffixIcon: IconButton(
                      icon: _colorSwatch(controller.gridStripeColor(context)),
                      tooltip: 'Pick a color',
                      onPressed: () =>
                          _pickGridStripeColor(controller, controller.gridStripeColor(context)),
                    ),
                  ),
                  onSubmitted: (text) => _applyGridStripeColor(controller, text),
                  onTapOutside: (_) => _applyGridStripeColor(controller, _gridStripeColorController.text),
                ),
                const SizedBox(height: 16),
              ],
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Alternate row colors in List view'),
                value: controller.listStripeEnabled,
                onChanged: (v) => controller.setListStripeEnabled(v ?? false),
              ),
              if (controller.listStripeEnabled) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('List stripe color'),
                    if (controller.listStripeColorOverride != null)
                      TextButton(
                        onPressed: () {
                          controller.setListStripeColorOverride(null);
                          _listStripeColorController.clear();
                        },
                        child: const Text('Reset to default'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _listStripeColorController,
                  decoration: InputDecoration(
                    hintText: '#RRGGBB -- blank to use the default',
                    suffixIcon: IconButton(
                      icon: _colorSwatch(controller.listStripeColor(context)),
                      tooltip: 'Pick a color',
                      onPressed: () =>
                          _pickListStripeColor(controller, controller.listStripeColor(context)),
                    ),
                  ),
                  onSubmitted: (text) => _applyListStripeColor(controller, text),
                  onTapOutside: (_) => _applyListStripeColor(controller, _listStripeColorController.text),
                ),
              ],
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 16),
              const Text('Schema Engine (Essentials v2)', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                'Creates tables and fields through the actual schema engine -- '
                'syncs to every device automatically, no manual per-device steps.',
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).push(MaterialPageRoute(builder: (_) => const NewTableScreen())),
                    child: const Text('New table'),
                  ),
                  OutlinedButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).push(MaterialPageRoute(builder: (_) => const AddFieldScreen())),
                    child: const Text('Add a field'),
                  ),
                  OutlinedButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).push(MaterialPageRoute(builder: (_) => const ManageFieldsScreen())),
                    child: const Text('Manage fields'),
                  ),
                  OutlinedButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).push(MaterialPageRoute(builder: (_) => const ManageTablesScreen())),
                    child: const Text('Manage tables'),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 16),
              const Text('Automation (Essentials v2 Phase 5)', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                'Write scripts under Scripts in the nav, then bind them to '
                'events here -- a record being created/saved/updated/deleted, '
                'a form opening/closing, a field changing, a button being '
                'tapped, or a schedule.',
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).push(MaterialPageRoute(builder: (_) => const ManageEventsScreen())),
                    child: const Text('Manage events'),
                  ),
                  OutlinedButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).push(MaterialPageRoute(builder: (_) => const ScheduledEventsScreen())),
                    child: const Text('Scheduled events'),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 16),
              const Text('Search', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                'Search normally stays current on its own. Rebuild it here if a '
                "field's format changed or a new field was added and search "
                "results still show its old shape.",
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _rebuildingSearchIndex ? null : _rebuildSearchIndex,
                child: _rebuildingSearchIndex
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Rebuild search index'),
              ),
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 16),
              const Text('Backup', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                'Saves a complete, self-contained snapshot of essentials.db as a '
                'plain .db file -- openable in Letos/DBeaver like any other '
                'SQLite file. Export only -- there is no restore/import-a-backup '
                'flow yet.',
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _backingUp ? null : _backupDatabase,
                child: _backingUp
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Backup Database'),
              ),
            ],
          );
        },
      ),
    );
  }
}
