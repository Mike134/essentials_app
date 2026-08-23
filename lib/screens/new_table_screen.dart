import 'dart:convert';

import 'package:flutter/material.dart';

import '../db/schema_editor_service.dart';
import '../db/schema_metadata_dao.dart';
import '../util/field_format_choice.dart';

class _PendingField {
  _PendingField({
    required this.displayName,
    required this.format,
    this.linkedTable,
    this.onDelete,
  });

  final String displayName;
  final FieldFormatChoice format;

  /// Only meaningful when [format] is [FieldFormatChoice.select] -- the
  /// existing table this field links to, and what happens to it when
  /// that linked row is deleted. Always an *already-existing* table
  /// (never the one being created here, which doesn't exist yet at
  /// field-definition time) -- same target-table picker
  /// [AddFieldScreen] already uses for exactly this reason.
  final String? linkedTable;
  final OnDeleteChoice? onDelete;
}

/// Essentials v2 Phase 1's "New Table" screen (build order step 7) --
/// the one thing v1's `TableDiscoveryService`/Letos-based workflow could
/// never do: create a table Mike never had before, from inside the app,
/// syncing to every device automatically via
/// [SchemaEditorService.createTable]. Per claude/essentials-v2-phase1
/// -design.md's "New UI": display name, icon, initial fields, and the
/// generated identifier shown live "so it's never a surprise."
///
/// Initial fields are name+format, plus a target-table picker for a
/// `select`/linked field -- everything else ([FieldFormatChoice] options
/// beyond that, default value, required) is still left to [AddFieldScreen]/
/// [ManageFieldsScreen] once the table exists, keeping this screen close
/// to the minimum needed to get a usable table started rather than
/// duplicating that entire editor inline.
///
/// **Linked fields were originally excluded here entirely** -- the
/// original reasoning was "there's nothing to link to until this table
/// exists yet," true only for linking a table to *itself*. Found live,
/// real-device verification session: creating a genuine parent/child pair
/// (an *already-existing* table, created first, then a second table with
/// a field linking to it) needed a detour through Add Field/Manage
/// Fields immediately after creation just to wire up the one thing that
/// actually made it a child table -- Mike's own words, "this process
/// should happen during table creation ... not later in manage fields."
/// The target-table picker only ever offers already-existing tables
/// (never this one, which doesn't exist yet at field-definition time),
/// so the original constraint never actually applied to this case.
class NewTableScreen extends StatefulWidget {
  const NewTableScreen({super.key});

  @override
  State<NewTableScreen> createState() => _NewTableScreenState();
}

class _NewTableScreenState extends State<NewTableScreen> {
  final _editor = SchemaEditorService();
  final _metadata = SchemaMetadataDao();

  final _displayNameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _iconController = TextEditingController();
  final _fieldNameController = TextEditingController();

  FieldFormatChoice _fieldFormat = FieldFormatChoice.text;
  String? _linkedTable;
  OnDeleteChoice _onDelete = OnDeleteChoice.restrict;
  final _pendingFields = <_PendingField>[];

  late Future<List<TableDefinitionRow>> _tableNamesFuture;

  String? _identifierPreview;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _displayNameController.addListener(_updatePreview);
    _tableNamesFuture = _metadata.loadActiveTables();
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _descriptionController.dispose();
    _iconController.dispose();
    _fieldNameController.dispose();
    super.dispose();
  }

  void _updatePreview() {
    final name = _displayNameController.text.trim();
    if (name.isEmpty) {
      if (_identifierPreview != null) setState(() => _identifierPreview = null);
      return;
    }
    _editor.previewTableIdentifier(name).then((preview) {
      if (mounted && _displayNameController.text.trim() == name) {
        setState(() => _identifierPreview = preview);
      }
    });
  }

  bool get _canAddPendingField {
    if (_fieldNameController.text.trim().isEmpty) return false;
    if (_fieldFormat == FieldFormatChoice.select && _linkedTable == null) return false;
    return true;
  }

  void _addPendingField() {
    if (!_canAddPendingField) return;
    final name = _fieldNameController.text.trim();
    setState(() {
      _pendingFields.add(
        _PendingField(
          displayName: name,
          format: _fieldFormat,
          linkedTable: _fieldFormat == FieldFormatChoice.select ? _linkedTable : null,
          onDelete: _fieldFormat == FieldFormatChoice.select ? _onDelete : null,
        ),
      );
      _fieldNameController.clear();
      _fieldFormat = FieldFormatChoice.text;
      _linkedTable = null;
      _onDelete = OnDeleteChoice.restrict;
    });
  }

  bool get _canSubmit => _displayNameController.text.trim().isNotEmpty;

  Future<void> _submit() async {
    // Real bug, found live: a field that looked fully filled in (name,
    // format, even a linked-table target already picked) but was never
    // explicitly committed via the + button got silently dropped on
    // Create Table, with no warning it hadn't actually been added --
    // Mike filled in a "Home" linked field, hit Create Table directly,
    // and the new table came out with only its other, already-added
    // field. Auto-commit whatever's still sitting in the row if it's
    // actually valid; if it's non-empty but incomplete (a linked format
    // with no target chosen yet), refuse to submit rather than silently
    // discard it either way -- the user typed something, it should never
    // just vanish.
    if (_fieldNameController.text.trim().isNotEmpty) {
      if (!_canAddPendingField) {
        setState(() {
          _error =
              'Finish adding "${_fieldNameController.text.trim()}" (pick a linked table) '
              'or clear it before creating the table.';
        });
        return;
      }
      _addPendingField();
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final tableName = await _editor.createTable(
        displayName: _displayNameController.text,
        description: _descriptionController.text.trim().isEmpty ? null : _descriptionController.text.trim(),
        icon: _iconController.text.trim().isEmpty ? null : _iconController.text.trim(),
      );
      // Sequential, not concurrent -- addField's own position lookup
      // reads the current max position first, so two concurrent calls
      // for the same table could race and land on the same position.
      for (final field in _pendingFields) {
        await _editor.addField(
          tableName: tableName,
          displayName: field.displayName,
          format: field.format.value,
          optionsJson: field.linkedTable == null
              ? null
              : jsonEncode({
                  'mode': 'linked',
                  'table': field.linkedTable,
                  'on_delete': field.onDelete!.value,
                }),
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"$tableName" created -- syncing to every other device.')),
      );
      Navigator.pop(context, tableName);
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
      appBar: AppBar(title: const Text('New Table')),
      body: ListView(
        // Same system-nav-bar overlap fix as SettingsScreen -- see that
        // screen's own doc comment for why a plain EdgeInsets.all(16)
        // isn't enough.
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
        children: [
          const Text(
            'Creates a table through the schema engine -- syncs to every '
            'other device automatically, no manual copy-paste step.',
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _displayNameController,
            decoration: InputDecoration(
              labelText: 'Table name',
              helperText: _identifierPreview == null ? null : 'Physical name: $_identifierPreview',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descriptionController,
            decoration: const InputDecoration(labelText: 'Description (optional)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _iconController,
            decoration: const InputDecoration(
              labelText: 'Icon (optional)',
              hintText: 'Not shown anywhere yet -- stored for later use',
            ),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          Text('Initial fields', style: Theme.of(context).textTheme.titleMedium),
          const Text(
            'Optional -- you can always add more later. A linked field can '
            'target any already-existing table.',
          ),
          const SizedBox(height: 12),
          for (final field in _pendingFields)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(field.displayName),
              subtitle: Text(
                field.linkedTable == null
                    ? field.format.label
                    : '${field.format.label} to ${field.linkedTable}',
              ),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Remove',
                onPressed: () => setState(() => _pendingFields.remove(field)),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _fieldNameController,
                  decoration: const InputDecoration(labelText: 'Field name'),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _addPendingField(),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<FieldFormatChoice>(
                  initialValue: _fieldFormat,
                  decoration: const InputDecoration(labelText: 'Format'),
                  items: [
                    for (final choice in FieldFormatChoice.values)
                      DropdownMenuItem(value: choice, child: Text(choice.label)),
                  ],
                  onChanged: (value) => setState(() {
                    _fieldFormat = value ?? FieldFormatChoice.text;
                    if (_fieldFormat != FieldFormatChoice.select) _linkedTable = null;
                  }),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                tooltip: 'Add field',
                onPressed: _canAddPendingField ? _addPendingField : null,
              ),
            ],
          ),
          if (_fieldFormat == FieldFormatChoice.select) ...[
            const SizedBox(height: 12),
            FutureBuilder<List<TableDefinitionRow>>(
              future: _tableNamesFuture,
              builder: (context, snapshot) {
                final tables = snapshot.data ?? const [];
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
          const SizedBox(height: 20),
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 12),
          ],
          ElevatedButton(
            onPressed: _canSubmit && !_saving ? _submit : null,
            child: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Create Table'),
          ),
        ],
      ),
    );
  }
}
