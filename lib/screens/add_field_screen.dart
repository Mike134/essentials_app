import 'dart:convert';

import 'package:flutter/material.dart';

import '../db/schema_editor_service.dart';
import '../db/schema_metadata_dao.dart';
import '../util/field_format_choice.dart';

/// Essentials v2 Phase 1's "Add Field" screen (build order step 7) --
/// replaced the retired `AddColumnScreen`'s type picker with a format
/// picker, and, unlike that screen, actually syncs:
/// [SchemaEditorService.addField] writes through `migration_log`, so
/// this needs running exactly once, not once per device. Verified
/// working on both platforms before `AddColumnScreen` was removed (see
/// CLAUDE.md "Essentials v2 Phase 1 -- Step 7").
class AddFieldScreen extends StatefulWidget {
  const AddFieldScreen({super.key, this.initialTableName});

  /// Pre-selects a table and locks the picker -- used when reached from
  /// [ManageFieldsScreen]'s "Add field" action, where the table is already
  /// known and re-picking it would be pointless.
  final String? initialTableName;

  @override
  State<AddFieldScreen> createState() => _AddFieldScreenState();
}

class _AddFieldScreenState extends State<AddFieldScreen> {
  final _editor = SchemaEditorService();
  final _metadata = SchemaMetadataDao();
  late Future<List<TableDefinitionRow>> _tableNamesFuture;

  final _displayNameController = TextEditingController();
  final _defaultValueController = TextEditingController();

  String? _selectedTable;
  FieldFormatChoice _format = FieldFormatChoice.text;
  bool _required = false;
  String? _linkedTable;
  OnDeleteChoice _onDelete = OnDeleteChoice.restrict;

  String? _identifierPreview;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selectedTable = widget.initialTableName;
    _tableNamesFuture = _metadata.loadActiveTables();
    _displayNameController.addListener(_updatePreview);
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _defaultValueController.dispose();
    super.dispose();
  }

  void _updatePreview() {
    final table = _selectedTable;
    final name = _displayNameController.text.trim();
    if (table == null || name.isEmpty) {
      if (_identifierPreview != null) setState(() => _identifierPreview = null);
      return;
    }
    _editor.previewFieldIdentifier(table, name).then((preview) {
      if (mounted && _displayNameController.text.trim() == name) {
        setState(() => _identifierPreview = preview);
      }
    });
  }

  bool get _canSubmit {
    if (_selectedTable == null) return false;
    if (_displayNameController.text.trim().isEmpty) return false;
    if (_required && _defaultValueController.text.trim().isEmpty) return false;
    if (_format == FieldFormatChoice.select && _linkedTable == null) return false;
    return true;
  }

  String? _buildOptionsJson() {
    if (_format != FieldFormatChoice.select) return null;
    return jsonEncode({
      'mode': 'linked',
      'table': _linkedTable,
      'on_delete': _onDelete.value,
    });
  }

  Future<void> _submit() async {
    final table = _selectedTable;
    if (table == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await _editor.addField(
        tableName: table,
        displayName: _displayNameController.text,
        format: _format.value,
        optionsJson: _buildOptionsJson(),
        defaultValue: _defaultValueController.text.trim().isEmpty ? null : _defaultValueController.text,
        required: _required,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Field added to "$table" -- syncing to every other device.')),
      );
      Navigator.pop(context, true);
    } on ArgumentError catch (e) {
      setState(() {
        _saving = false;
        _error = e.message.toString();
      });
    } catch (e) {
      setState(() {
        _saving = false;
        _error = 'Failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Field')),
      body: ListView(
        // Same system-nav-bar overlap fix as SettingsScreen -- see that
        // screen's own doc comment for why a plain EdgeInsets.all(16)
        // isn't enough.
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
        children: [
          const Text(
            'Adds a field to a table, through the schema engine -- syncs to '
            'every other device automatically, no manual copy-paste step.',
          ),
          const SizedBox(height: 20),
          FutureBuilder<List<TableDefinitionRow>>(
            future: _tableNamesFuture,
            builder: (context, snapshot) {
              final tables = snapshot.data ?? const [];
              return DropdownButtonFormField<String>(
                initialValue: _selectedTable,
                decoration: const InputDecoration(labelText: 'Table'),
                items: [
                  for (final t in tables) DropdownMenuItem(value: t.tableName, child: Text(t.displayName)),
                ],
                onChanged: widget.initialTableName != null
                    ? null
                    : (value) {
                        setState(() => _selectedTable = value);
                        _updatePreview();
                      },
              );
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _displayNameController,
            decoration: InputDecoration(
              labelText: 'Field name',
              helperText: _identifierPreview == null ? null : 'Column name: $_identifierPreview',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<FieldFormatChoice>(
            initialValue: _format,
            decoration: const InputDecoration(labelText: 'Format'),
            items: [
              for (final choice in FieldFormatChoice.values)
                DropdownMenuItem(value: choice, child: Text(choice.label)),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _format = value;
                if (value != FieldFormatChoice.select) _linkedTable = null;
              });
            },
          ),
          if (_format == FieldFormatChoice.select) ...[
            const SizedBox(height: 12),
            FutureBuilder<List<TableDefinitionRow>>(
              future: _tableNamesFuture,
              builder: (context, snapshot) {
                final tables = (snapshot.data ?? const [])
                    .where((t) => t.tableName != _selectedTable)
                    .toList();
                return DropdownButtonFormField<String>(
                  initialValue: _linkedTable,
                  decoration: const InputDecoration(labelText: 'Linked to table'),
                  items: [
                    for (final t in tables) DropdownMenuItem(value: t.tableName, child: Text(t.displayName)),
                  ],
                  onChanged: (value) => setState(() => _linkedTable = value),
                );
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<OnDeleteChoice>(
              initialValue: _onDelete,
              decoration: const InputDecoration(labelText: 'When the linked row is deleted'),
              items: [
                for (final choice in OnDeleteChoice.values)
                  DropdownMenuItem(value: choice, child: Text(choice.label)),
              ],
              onChanged: (value) => setState(() => _onDelete = value ?? OnDeleteChoice.restrict),
            ),
          ],
          const SizedBox(height: 12),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Required'),
            subtitle: const Text('Needs a default below -- existing rows must get a value.'),
            value: _required,
            onChanged: (value) => setState(() => _required = value ?? false),
          ),
          TextField(
            controller: _defaultValueController,
            decoration: InputDecoration(
              labelText: _required ? 'Default (required)' : 'Default (optional)',
              hintText: 'Blank = no default, field starts empty on existing rows',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 20),
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 12),
          ],
          ElevatedButton(
            onPressed: _canSubmit && !_saving ? _submit : null,
            child: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Add Field'),
          ),
        ],
      ),
    );
  }
}
