import 'dart:convert';

import 'package:flutter/material.dart';

import '../db/schema_editor_service.dart';
import '../db/schema_metadata_dao.dart';
import '../util/field_format_choice.dart';
import 'add_field_screen.dart' show autoDisplayField;

/// Formats [NewTableScreen]'s own inline field row can fully support --
/// everything else falls into one of two buckets, deliberately excluded
/// from this screen's Format picker rather than half-supported the way
/// `link_record` used to be (see this file's own history: picking it here
/// used to silently produce a field with no target table at all, since
/// only the pre-existing `select` format ever got its options actually
/// wired up):
///
/// - [FieldFormatChoice.lookup]/[FieldFormatChoice.rollup] reference a
///   `link_record` field on THIS SAME table (the one being created) --
///   for the very first field added, that field doesn't exist yet. Not a
///   UI gap, a genuine ordering constraint -- these can only ever make
///   sense once the table (and its link field) already exist, i.e. via
///   [AddFieldScreen]/`ManageFieldsScreen` afterward.
/// - [FieldFormatChoice.inlineSelect]/[FieldFormatChoice.formula] need a
///   real dedicated editor (an option-list builder, an expression
///   builder) -- building those inline here would defeat the point of
///   this screen staying close to the minimum needed to get a table
///   started (see the class doc comment below). Same "left to AddFieldScreen"
///   treatment.
///
/// Every other format either needs no extra options at all
/// (text/integer/real/boolean/date/dateTime, currency/percentage/rating/
/// barcode -- all degrade to sensible defaults with none captured) or is
/// fully supported inline below (`select`/`link_record`'s target-table +
/// on-delete + "which field to show" + "allow multiple" block, `url`/
/// `color`'s options flag).
final List<FieldFormatChoice> _supportedInitialFieldFormats = [
  for (final choice in FieldFormatChoice.values)
    if (choice != FieldFormatChoice.lookup &&
        choice != FieldFormatChoice.rollup &&
        choice != FieldFormatChoice.inlineSelect &&
        choice != FieldFormatChoice.formula)
      choice,
];

class _PendingField {
  _PendingField({
    required this.displayName,
    required this.format,
    this.linkedTable,
    this.onDelete,
    this.multiple = false,
    this.displayField,
  });

  final String displayName;
  final FieldFormatChoice format;

  /// Only meaningful when [format] is [FieldFormatChoice.select] or
  /// [FieldFormatChoice.linkRecord] -- the existing table this field
  /// links to, and what happens to it when that linked row is deleted.
  /// Always an *already-existing* table (never the one being created
  /// here, which doesn't exist yet at field-definition time) -- same
  /// target-table picker [AddFieldScreen] already uses for exactly this
  /// reason.
  final String? linkedTable;
  final OnDeleteChoice? onDelete;

  /// [FieldFormatChoice.linkRecord] only -- see `LinkRecordConfig
  /// .multiple`'s own doc comment for what this controls.
  final bool multiple;

  /// [FieldFormatChoice.select]/[FieldFormatChoice.linkRecord] only --
  /// see `autoDisplayField`'s doc comment for why this is never left to
  /// silently default to a literal `'name'` column that might not exist.
  final String? displayField;
}

/// Essentials v2 Phase 1's "New Table" screen (build order step 7) --
/// the one thing v1's `TableDiscoveryService`/Letos-based workflow could
/// never do: create a table Mike never had before, from inside the app,
/// syncing to every device automatically via
/// [SchemaEditorService.createTable]. Per claude/essentials-v2-phase1
/// -design.md's "New UI": display name, icon, initial fields, and the
/// generated identifier shown live "so it's never a surprise."
///
/// Initial fields are name+format, plus (for `select`/[FieldFormatChoice
/// .linkRecord]) the full target-table/on-delete/"which field to show"/
/// "allow multiple" block [AddFieldScreen] itself uses -- default value and
/// required are still left to [AddFieldScreen]/[ManageFieldsScreen] once
/// the table exists, and [FieldFormatChoice.lookup]/[FieldFormatChoice
/// .rollup]/[FieldFormatChoice.inlineSelect]/[FieldFormatChoice.formula]
/// are excluded from the Format picker entirely -- see
/// [_supportedInitialFieldFormats]'s own doc comment for exactly why each
/// one can't (or, for the two option-editor formats, deliberately doesn't)
/// belong here. Keeps this screen close to the minimum needed to get a
/// usable table started rather than duplicating that entire editor inline.
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
///
/// **`link_record` specifically was picked here for months without
/// actually working** -- it appeared in the Format dropdown (which simply
/// listed every [FieldFormatChoice]), but only [FieldFormatChoice.select]'s
/// branch ever populated the target-table/on-delete UI or wrote real
/// `options` JSON; picking `link_record` silently produced a field with no
/// `table` key at all (`SchemaRegistry._linkRecordFor` returns `null`
/// without one, so it never actually became a link). Found live -- fixed
/// by giving `link_record` the identical full options block `select`
/// already had, rather than leaving a format in the picker that visibly
/// "went away" the moment it was chosen.
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
  bool _linkMultiple = false;
  String? _displayField;
  List<FieldDefinitionRow> _linkedTableFields = const [];
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

  bool get _isLinkedFormat =>
      _fieldFormat == FieldFormatChoice.select || _fieldFormat == FieldFormatChoice.linkRecord;

  bool get _canAddPendingField {
    if (_fieldNameController.text.trim().isEmpty) return false;
    if (_isLinkedFormat && _linkedTable == null) return false;
    return true;
  }

  /// Loads [_linkedTableFields] for [tableName] and seeds [_displayField]
  /// with [autoDisplayField]'s pick -- same shape as [AddFieldScreen]
  /// /`ManageFieldsScreen`'s own loader, called whenever the "Linked to
  /// table" dropdown changes.
  Future<void> _loadLinkedTableFields(String? tableName) async {
    if (tableName == null) {
      setState(() {
        _linkedTableFields = const [];
        _displayField = null;
      });
      return;
    }
    final fields = await _metadata.loadFields(tableName, includeDeleted: false);
    if (!mounted || _linkedTable != tableName) return;
    setState(() {
      _linkedTableFields = fields;
      _displayField = autoDisplayField(fields);
    });
  }

  void _addPendingField() {
    if (!_canAddPendingField) return;
    final name = _fieldNameController.text.trim();
    setState(() {
      _pendingFields.add(
        _PendingField(
          displayName: name,
          format: _fieldFormat,
          linkedTable: _isLinkedFormat ? _linkedTable : null,
          onDelete: _isLinkedFormat ? _onDelete : null,
          multiple: _fieldFormat == FieldFormatChoice.linkRecord ? _linkMultiple : false,
          displayField: _isLinkedFormat ? (_displayField ?? 'id') : null,
        ),
      );
      _fieldNameController.clear();
      _fieldFormat = FieldFormatChoice.text;
      _linkedTable = null;
      _onDelete = OnDeleteChoice.restrict;
      _linkMultiple = false;
      _displayField = null;
      _linkedTableFields = const [];
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
          optionsJson: _pendingFieldOptionsJson(field),
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

  /// Real bug, found live: every format other than `select` silently wrote
  /// `optionsJson: null` here, regardless of what it actually needs to
  /// function -- `url`/`color` (a plain flag) quietly became indistinguishable
  /// from plain text, and `link_record` (a real target table) never
  /// actually became a link at all (no `table` key -> `SchemaRegistry
  /// ._linkRecordFor` returns `null` -> `FieldConfig.isLinkRecord` false).
  /// Mirrors [AddFieldScreen._buildOptionsJson]'s per-format branches for
  /// every format [_supportedInitialFieldFormats] actually offers.
  String? _pendingFieldOptionsJson(_PendingField field) {
    if (field.format == FieldFormatChoice.select) {
      return jsonEncode({
        'mode': 'linked',
        'table': field.linkedTable,
        'on_delete': field.onDelete!.value,
        'displayField': field.displayField ?? 'id',
      });
    }
    if (field.format == FieldFormatChoice.linkRecord) {
      return jsonEncode({
        'table': field.linkedTable,
        'multiple': field.multiple,
        'on_delete': field.onDelete!.value,
        'displayField': field.displayField ?? 'id',
      });
    }
    if (field.format == FieldFormatChoice.url) {
      return jsonEncode({'isLink': true});
    }
    if (field.format == FieldFormatChoice.color) {
      return jsonEncode({'isColor': true});
    }
    return null;
  }

  /// Same as [AddFieldScreen._buildDisplayFieldPicker] -- see that method's
  /// doc comment, including why the guard against a not-yet-loaded
  /// [_displayField] value matters.
  Widget _buildDisplayFieldPicker() {
    final validValues = {'id', for (final f in _linkedTableFields) f.fieldName};
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DropdownButtonFormField<String>(
        initialValue: validValues.contains(_displayField) ? _displayField : null,
        decoration: const InputDecoration(labelText: 'Which field to show'),
        items: [
          const DropdownMenuItem(value: 'id', child: Text('(row id)')),
          for (final f in _linkedTableFields)
            DropdownMenuItem(value: f.fieldName, child: Text(f.displayName)),
        ],
        onChanged: (value) => setState(() => _displayField = value),
      ),
    );
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
                    : '${field.format.label} to ${field.linkedTable}'
                          '${field.multiple ? ' (multiple)' : ''}',
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
                    for (final choice in _supportedInitialFieldFormats)
                      DropdownMenuItem(value: choice, child: Text(choice.label)),
                  ],
                  onChanged: (value) => setState(() {
                    _fieldFormat = value ?? FieldFormatChoice.text;
                    if (!_isLinkedFormat) {
                      _linkedTable = null;
                      _linkedTableFields = const [];
                      _displayField = null;
                      _linkMultiple = false;
                    }
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
          if (_isLinkedFormat) ...[
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
                  onChanged: (value) {
                    setState(() => _linkedTable = value);
                    _loadLinkedTableFields(value);
                  },
                );
              },
            ),
            _buildDisplayFieldPicker(),
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
            if (_fieldFormat == FieldFormatChoice.linkRecord) ...[
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Allow linking to more than one record'),
                value: _linkMultiple,
                onChanged: (value) => setState(() => _linkMultiple = value ?? false),
              ),
            ],
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
