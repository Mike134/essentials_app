import 'dart:convert';

import 'package:flutter/material.dart';

import '../db/schema_editor_service.dart';
import '../db/schema_metadata_dao.dart';
import '../models/table_config.dart';
import '../util/field_format_choice.dart';
import '../util/formula/formula_field_editor.dart';
import '../util/formula/formula_service.dart';
import '../util/inline_option_editor.dart';

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
  final _currencySymbolController = TextEditingController();
  final _decimalsController = TextEditingController();
  final _ratingMaxController = TextEditingController();
  final _expressionController = TextEditingController();

  String? _selectedTable;
  FieldFormatChoice _format = FieldFormatChoice.text;
  bool _required = false;
  String? _linkedTable;
  OnDeleteChoice _onDelete = OnDeleteChoice.restrict;
  List<InlineOption> _inlineOptions = [];
  String _resultType = FormulaService.resultTypeNumber;

  /// The selected table's existing fields (field name -> display name),
  /// for the formula editor's insert-a-field chips. Reloaded whenever the
  /// table changes; empty until it resolves, which the editor handles.
  Map<String, String> _availableFields = const {};

  String? _identifierPreview;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selectedTable = widget.initialTableName;
    _tableNamesFuture = _metadata.loadActiveTables();
    _displayNameController.addListener(_updatePreview);
    if (_selectedTable != null) _loadAvailableFields(_selectedTable!);
  }

  Future<void> _loadAvailableFields(String tableName) async {
    final fields = await _metadata.loadFields(tableName, includeDeleted: false);
    if (!mounted || _selectedTable != tableName) return;
    setState(() {
      _availableFields = {for (final f in fields) f.fieldName: f.displayName};
    });
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _defaultValueController.dispose();
    _currencySymbolController.dispose();
    _decimalsController.dispose();
    _ratingMaxController.dispose();
    _expressionController.dispose();
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
    if (_showsRequired && _required && _defaultValueController.text.trim().isEmpty) return false;
    if (_format == FieldFormatChoice.select && _linkedTable == null) return false;
    if (_format == FieldFormatChoice.inlineSelect && !_hasValidInlineOptions) return false;
    if (_format == FieldFormatChoice.formula && !isUsableFormula(_expressionController.text)) {
      return false;
    }
    return true;
  }

  bool get _hasValidInlineOptions =>
      _inlineOptions.any((o) => o.key.isNotEmpty && o.label.isNotEmpty);

  /// A formula field is never written and never validated by the form
  /// (it's [FieldConfig.readOnly]), so "required" and a default value are
  /// both meaningless for it -- hidden rather than shown-but-ignored.
  bool get _showsRequired => _format != FieldFormatChoice.formula;

  /// `real`/`currency`/`percentage`, plus a `formula` whose result is a
  /// number, all read an optional `decimals` display hint (see
  /// claude/essentials-v2-phase2-design.md's format catalog) -- shown as
  /// one shared field rather than several near-duplicate ones, since only
  /// one format is ever selected at a time.
  bool get _showsDecimals =>
      _format == FieldFormatChoice.real ||
      _format == FieldFormatChoice.currency ||
      _format == FieldFormatChoice.percentage ||
      (_format == FieldFormatChoice.formula && _resultType == FormulaService.resultTypeNumber);

  String? _buildOptionsJson() {
    if (_format == FieldFormatChoice.select) {
      return jsonEncode({
        'mode': 'linked',
        'table': _linkedTable,
        'on_delete': _onDelete.value,
      });
    }
    // `url` isn't a real stored format -- see FieldFormatChoice.url's doc
    // comment. Picking it writes plain `format: 'text'` (already what
    // `_format.value` resolves to) with this one flag, which is all
    // SchemaRegistry._buildField needs to turn on FieldConfig.isLink.
    if (_format == FieldFormatChoice.url) {
      return jsonEncode({'isLink': true});
    }
    // `inlineSelect` isn't a real stored format either -- see
    // FieldFormatChoice.inlineSelect's doc comment. Filters out any
    // blank leftover row rather than trusting _canSubmit's own gate was
    // the only thing standing between a stray empty row and storage.
    if (_format == FieldFormatChoice.inlineSelect) {
      return jsonEncode({
        'mode': 'inline',
        'options': [
          for (final o in _inlineOptions)
            if (o.key.isNotEmpty && o.label.isNotEmpty) o.toJson(),
        ],
      });
    }
    // Blank means "let the format's own default apply" (2 for real/
    // currency, 0 for percentage -- see each handler's own default) --
    // omitted from the JSON entirely rather than writing a guessed
    // default here, so the handler stays the one place that default
    // actually lives.
    final options = <String, Object?>{};
    if (_format == FieldFormatChoice.formula) {
      options['expression'] = _expressionController.text.trim();
      options['resultType'] = _resultType;
    }
    if (_format == FieldFormatChoice.currency) {
      final symbol = _currencySymbolController.text.trim();
      if (symbol.isNotEmpty) options['symbol'] = symbol;
    }
    if (_showsDecimals) {
      final decimals = int.tryParse(_decimalsController.text.trim());
      if (decimals != null) options['decimals'] = decimals;
    }
    if (_format == FieldFormatChoice.rating) {
      final max = int.tryParse(_ratingMaxController.text.trim());
      if (max != null) options['max'] = max;
    }
    return options.isEmpty ? null : jsonEncode(options);
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
        // A formula field is readOnly and never written, so a NOT NULL
        // default on its column would be both pointless and impossible to
        // satisfy -- forced off here regardless of what the (hidden for
        // this format) checkbox last held.
        defaultValue: _showsRequired && _defaultValueController.text.trim().isNotEmpty
            ? _defaultValueController.text
            : null,
        required: _showsRequired && _required,
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
                        setState(() {
                          _selectedTable = value;
                          _availableFields = const {};
                        });
                        _updatePreview();
                        if (value != null) _loadAvailableFields(value);
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
          if (_format == FieldFormatChoice.formula) ...[
            const SizedBox(height: 12),
            FormulaFieldEditor(
              expressionController: _expressionController,
              resultType: _resultType,
              onResultTypeChanged: (value) => setState(() => _resultType = value),
              availableFields: _availableFields,
              // _canSubmit gates on the expression parsing, so the Add
              // Field button has to re-evaluate as the user types.
              onChanged: () => setState(() {}),
            ),
          ],
          if (_format == FieldFormatChoice.currency) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _currencySymbolController,
              decoration: const InputDecoration(labelText: 'Symbol', hintText: r'Default: $'),
            ),
          ],
          if (_showsDecimals) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _decimalsController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Decimal places',
                hintText: 'Default: ${_format == FieldFormatChoice.percentage ? '0' : '2'}',
              ),
            ),
          ],
          if (_format == FieldFormatChoice.rating) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _ratingMaxController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Max stars', hintText: 'Default: 5'),
            ),
          ],
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
          if (_format == FieldFormatChoice.inlineSelect) ...[
            const SizedBox(height: 12),
            InlineOptionListEditor(
              options: _inlineOptions,
              // setState -- _canSubmit reads _inlineOptions on every
              // build to gate the Add Field button; without this the
              // button's enabled state wouldn't update live as options
              // are added/edited/removed (same arrow-closure-adjacent
              // pitfall as everywhere else in this app that mutates state
              // from a callback).
              onChanged: (options) => setState(() => _inlineOptions = options),
            ),
          ],
          if (_showsRequired) ...[
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
                : const Text('Add Field'),
          ),
        ],
      ),
    );
  }
}
