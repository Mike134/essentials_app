import 'dart:convert';

import 'package:flutter/material.dart';

import '../db/schema_editor_service.dart';
import '../db/schema_metadata_dao.dart';
import '../models/table_config.dart';
import '../util/color_default_value_field.dart';
import '../util/field_format_choice.dart';
import '../util/field_options.dart';
import '../util/formula/formula_field_editor.dart';
import '../util/formula/formula_service.dart';
import '../util/inline_option_editor.dart';
import '../util/linked_field/linked_field_service.dart';

/// Display labels for [LinkedFieldService.aggregates], shared by
/// [AddFieldScreen] and [ManageFieldsScreen]'s field editor -- both need
/// the exact same "Aggregate" dropdown for a `rollup` field.
const Map<String, String> rollupAggregateLabels = {
  LinkedFieldService.aggregateSum: 'Sum',
  LinkedFieldService.aggregateAvg: 'Average',
  LinkedFieldService.aggregateMin: 'Minimum',
  LinkedFieldService.aggregateMax: 'Maximum',
  LinkedFieldService.aggregateCount: 'Count',
};

/// `field_definitions.format`s this app currently treats as "numeric
/// enough" to be worth offering first for a `rollup`'s "Which field"
/// picker when the aggregate isn't `count` -- a nice-to-have narrowing per
/// claude/essentials-v2-phase4-design.md ("not a hard validation rule"),
/// so an empty result here just means "show everything" rather than
/// blocking the picker.
const Set<String> _rollupNumericFormats = {'integer', 'real', 'currency', 'percentage'};

/// Candidate fields on a `rollup`/`lookup`'s target table for the "Which
/// field on the linked table" picker -- shared by [AddFieldScreen] and
/// [ManageFieldsScreen]'s field editor.
List<FieldDefinitionRow> rollupSourceCandidates(
  List<FieldDefinitionRow> targetFields, {
  required bool isRollup,
  required String aggregate,
}) {
  if (!isRollup || aggregate == LinkedFieldService.aggregateCount) return targetFields;
  final numeric = targetFields.where((f) => _rollupNumericFormats.contains(f.format)).toList();
  return numeric.isNotEmpty ? numeric : targetFields;
}

/// Default "Which field to show" pick for a `select`/`link_record` field's
/// target table -- `SchemaRegistry._lookupFor`/`_linkRecordFor` otherwise
/// silently default to a literal `'name'` column that may not exist (a real
/// crash found live: a target table's own text field named something other
/// than `name`, e.g. `condition`, blew up `ORDER BY name` -- see
/// `GenericDao._resolveDisplayColumn`'s own doc comment for the DAO-side
/// safety net this UI-side default exists to make mostly unnecessary going
/// forward). Prefers an actual `name` field if the target has one (keeps
/// existing behavior for every target table that already has one, which is
/// most of them); otherwise the target's first plain `text` field; falls
/// back to `'id'` (always present) if neither exists.
String autoDisplayField(List<FieldDefinitionRow> targetFields) {
  for (final f in targetFields) {
    if (f.fieldName == 'name') return 'name';
  }
  for (final f in targetFields) {
    if (f.format == 'text') return f.fieldName;
  }
  return 'id';
}

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
  final _buttonLabelController = TextEditingController();

  String? _selectedTable;
  FieldFormatChoice _format = FieldFormatChoice.text;
  bool _required = false;
  String? _linkedTable;
  OnDeleteChoice _onDelete = OnDeleteChoice.restrict;
  List<InlineOption> _inlineOptions = [];
  String _resultType = FormulaService.resultTypeNumber;
  bool _autocomplete = true;

  /// `link_record`'s own "Allow linking to more than one record" checkbox
  /// -- `options.multiple` (see `LinkRecordConfig`).
  bool _linkMultiple = false;

  /// `lookup`/`rollup`'s "Which link field" -- names a `link_record` field
  /// on THIS table (`options.link_field`).
  String? _linkFieldColumn;

  /// `lookup`/`rollup`'s "Which field on the linked table"
  /// (`options.source_field`).
  String? _sourceField;

  /// `rollup`'s "Aggregate" (`options.aggregate`) -- defaults to `sum`,
  /// matching [LinkedFieldService.defaultAggregate].
  String _rollupAggregate = LinkedFieldService.defaultAggregate;

  /// `select`/`link_record`'s "Which field to show" (`options.displayField`)
  /// -- see [autoDisplayField]'s doc comment for why this exists and what
  /// it defaults to. `null` until [_linkedTableFields] resolves.
  String? _displayField;

  /// [_linkedTable]'s own fields, for the "Which field to show" picker --
  /// reloaded whenever [_linkedTable] changes (a `select`/`link_record`
  /// field can point at a different table each time).
  List<FieldDefinitionRow> _linkedTableFields = const [];

  /// The selected table's existing fields, for the formula editor's
  /// insert-a-field chips (as a name -> display-name map) and for
  /// `lookup`/`rollup`'s "Which link field" picker (filtered to this
  /// table's own `link_record` fields). Reloaded whenever the table
  /// changes; empty until it resolves, which the editor/picker both handle.
  List<FieldDefinitionRow> _availableFieldRows = const [];

  Map<String, String> get _availableFields => {
    for (final f in _availableFieldRows) f.fieldName: f.displayName,
  };

  List<FieldDefinitionRow> get _linkRecordFields =>
      _availableFieldRows.where((f) => f.format == 'link_record').toList();

  /// The target table `link_field` names -- read from that field's own
  /// already-loaded `options` JSON, no extra query needed.
  String? _targetTableFor(String? linkFieldColumn) {
    if (linkFieldColumn == null) return null;
    for (final f in _availableFieldRows) {
      if (f.fieldName == linkFieldColumn) {
        return parseFieldOptions(f.optionsJson)['table'] as String?;
      }
    }
    return null;
  }

  /// `lookup`/`rollup`'s target table's own fields, for the "Which field on
  /// the linked table" picker -- reloaded whenever `_linkFieldColumn`
  /// changes (each link field can point at a different table).
  List<FieldDefinitionRow> _targetFields = const [];

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
      _availableFieldRows = fields;
    });
  }

  Future<void> _loadTargetFields(String? linkFieldColumn) async {
    final targetTable = _targetTableFor(linkFieldColumn);
    if (targetTable == null) {
      setState(() => _targetFields = const []);
      return;
    }
    final fields = await _metadata.loadFields(targetTable, includeDeleted: false);
    if (!mounted || _linkFieldColumn != linkFieldColumn) return;
    setState(() => _targetFields = fields);
  }

  /// Loads [_linkedTableFields] for [tableName] (the target of a `select`/
  /// `link_record` field) and seeds [_displayField] with [autoDisplayField]'s
  /// pick -- called whenever the "Linked to table" dropdown changes.
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

  @override
  void dispose() {
    _displayNameController.dispose();
    _defaultValueController.dispose();
    _currencySymbolController.dispose();
    _decimalsController.dispose();
    _ratingMaxController.dispose();
    _expressionController.dispose();
    _buttonLabelController.dispose();
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
    if (_format == FieldFormatChoice.linkRecord && _linkedTable == null) return false;
    if (_format == FieldFormatChoice.lookup) {
      if (_linkFieldColumn == null || _sourceField == null) return false;
    }
    if (_format == FieldFormatChoice.rollup) {
      if (_linkFieldColumn == null) return false;
      if (_rollupAggregate != LinkedFieldService.aggregateCount && _sourceField == null) {
        return false;
      }
    }
    if (_format == FieldFormatChoice.inlineSelect && !_hasValidInlineOptions) return false;
    if (_format == FieldFormatChoice.formula && !isUsableFormula(_expressionController.text)) {
      return false;
    }
    return true;
  }

  bool get _hasValidInlineOptions =>
      _inlineOptions.any((o) => o.key.isNotEmpty && o.label.isNotEmpty);

  /// A formula/lookup/rollup field is never written and never validated by
  /// the form (it's [FieldConfig.readOnly]), so "required" and a default
  /// value are both meaningless for it -- hidden rather than
  /// shown-but-ignored.
  bool get _showsRequired =>
      _format != FieldFormatChoice.formula &&
      _format != FieldFormatChoice.lookup &&
      _format != FieldFormatChoice.rollup &&
      _format != FieldFormatChoice.button;

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

  /// Only a genuinely plain `text` field is eligible for suggestions --
  /// `url`/`color` both also pick [FieldFormatChoice.text]'s stored
  /// `format` value but already have their own dedicated widget, not a
  /// bare text box (see [FieldConfig.isAutocompleteText]'s doc comment).
  bool get _showsAutocomplete => _format == FieldFormatChoice.text;

  String? _buildOptionsJson() {
    if (_format == FieldFormatChoice.select) {
      return jsonEncode({
        'mode': 'linked',
        'table': _linkedTable,
        'on_delete': _onDelete.value,
        // Explicit, not omitted -- see autoDisplayField's doc comment for
        // why relying on SchemaRegistry's own 'name' default is what
        // crashed for a real target table without one.
        'displayField': _displayField ?? 'id',
      });
    }
    // `url` isn't a real stored format -- see FieldFormatChoice.url's doc
    // comment. Picking it writes plain `format: 'text'` (already what
    // `_format.value` resolves to) with this one flag, which is all
    // SchemaRegistry._buildField needs to turn on FieldConfig.isLink.
    if (_format == FieldFormatChoice.url) {
      return jsonEncode({'isLink': true});
    }
    // `color` isn't a real stored format either -- see
    // FieldFormatChoice.color's doc comment. Same shape as `url`, just
    // turning on FieldConfig.isColor instead of isLink.
    if (_format == FieldFormatChoice.color) {
      return jsonEncode({'isColor': true});
    }
    // `link_record` -- Essentials v2 Phase 4.
    if (_format == FieldFormatChoice.linkRecord) {
      return jsonEncode({
        'table': _linkedTable,
        'multiple': _linkMultiple,
        'on_delete': _onDelete.value,
        // Explicit, not omitted -- same reasoning as the select branch above.
        'displayField': _displayField ?? 'id',
      });
    }
    if (_format == FieldFormatChoice.lookup) {
      return jsonEncode({'link_field': _linkFieldColumn, 'source_field': _sourceField});
    }
    if (_format == FieldFormatChoice.rollup) {
      final rollupOptions = <String, Object?>{
        'link_field': _linkFieldColumn,
        'aggregate': _rollupAggregate,
      };
      if (_rollupAggregate != LinkedFieldService.aggregateCount) {
        rollupOptions['source_field'] = _sourceField;
      }
      return jsonEncode(rollupOptions);
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
    if (_format == FieldFormatChoice.button) {
      final label = _buttonLabelController.text.trim();
      return label.isEmpty ? null : jsonEncode({'label': label});
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
    // Default is true (omitted entirely) -- only write the flag when the
    // user has turned it off, same "blank/absent means the default"
    // convention as every other options key in this method.
    if (_showsAutocomplete && !_autocomplete) {
      options['autocomplete'] = false;
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

  /// "Which field to show" -- shared by `select`'s and `linkRecord`'s
  /// options blocks (both write `options.displayField`, see
  /// [autoDisplayField]'s doc comment for why this exists at all). A plain
  /// `id` entry is always offered first, since it's always valid and a
  /// target table without a `name`/`text` field would otherwise have
  /// nothing else to reasonably show.
  Widget _buildDisplayFieldPicker() {
    final validValues = {'id', for (final f in _linkedTableFields) f.fieldName};
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DropdownButtonFormField<String>(
        // Falls back to null (rather than a stale/not-yet-loaded value)
        // whenever it doesn't match a currently-offered item --
        // DropdownButtonFormField asserts on that in debug builds, the same
        // known pitfall this app already hit for the isLookup dropdown (see
        // GenericFormScreen's own doc comment on that fix).
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
                          _availableFieldRows = const [];
                          _linkFieldColumn = null;
                          _sourceField = null;
                          _targetFields = const [];
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
                if (value != FieldFormatChoice.select && value != FieldFormatChoice.linkRecord) {
                  _linkedTable = null;
                  _linkedTableFields = const [];
                  _displayField = null;
                }
                if (value != FieldFormatChoice.lookup && value != FieldFormatChoice.rollup) {
                  _linkFieldColumn = null;
                  _sourceField = null;
                  _targetFields = const [];
                }
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
          if (_format == FieldFormatChoice.button) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _buttonLabelController,
              decoration: const InputDecoration(labelText: 'Button label', hintText: 'Default: Run script'),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'Scripts aren\'t wired up yet -- this button will show disabled until '
                'later Phase 5 steps land.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
          if (_showsAutocomplete) ...[
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Autocomplete suggestions'),
              subtitle: const Text(
                'Suggests values already typed into this column on other rows, as you type.',
              ),
              value: _autocomplete,
              onChanged: (value) => setState(() => _autocomplete = value ?? true),
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
          ],
          if (_format == FieldFormatChoice.linkRecord) ...[
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
              decoration: const InputDecoration(labelText: 'When a linked row is deleted'),
              items: [
                for (final choice in OnDeleteChoice.values)
                  DropdownMenuItem(value: choice, child: Text(choice.label)),
              ],
              onChanged: (value) => setState(() => _onDelete = value ?? OnDeleteChoice.restrict),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Allow linking to more than one record'),
              subtitle: const Text(
                'Off: one-to-many -- this field picks a single record, but that '
                'record can be linked from many rows here. On: many-to-many -- '
                'this field can pick several records, and each of those can '
                'likewise be linked from many rows here. Either way, the link is '
                'stored only on this field -- open the linked record\'s own form '
                'to see every row here that links to it.',
              ),
              value: _linkMultiple,
              onChanged: (value) => setState(() => _linkMultiple = value ?? false),
            ),
          ],
          if (_format == FieldFormatChoice.lookup || _format == FieldFormatChoice.rollup) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _linkFieldColumn,
              decoration: const InputDecoration(labelText: 'Which link field'),
              items: [
                for (final f in _linkRecordFields) DropdownMenuItem(value: f.fieldName, child: Text(f.displayName)),
              ],
              onChanged: (value) {
                setState(() {
                  _linkFieldColumn = value;
                  _sourceField = null;
                });
                _loadTargetFields(value);
              },
            ),
            if (_linkRecordFields.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'This table has no "Link to another table" field yet -- add one first.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
          ],
          if (_format == FieldFormatChoice.rollup) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _rollupAggregate,
              decoration: const InputDecoration(labelText: 'Aggregate'),
              items: [
                for (final entry in rollupAggregateLabels.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (value) => setState(
                () => _rollupAggregate = value ?? LinkedFieldService.defaultAggregate,
              ),
            ),
          ],
          if ((_format == FieldFormatChoice.lookup || _format == FieldFormatChoice.rollup) &&
              (_format == FieldFormatChoice.lookup ||
                  _rollupAggregate != LinkedFieldService.aggregateCount)) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _sourceField,
              decoration: const InputDecoration(labelText: 'Which field on the linked table'),
              items: [
                for (final f in rollupSourceCandidates(
                  _targetFields,
                  isRollup: _format == FieldFormatChoice.rollup,
                  aggregate: _rollupAggregate,
                ))
                  DropdownMenuItem(value: f.fieldName, child: Text(f.displayName)),
              ],
              onChanged: (value) => setState(() => _sourceField = value),
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
            if (_format == FieldFormatChoice.color)
              ColorDefaultValueField(
                controller: _defaultValueController,
                labelText: _required ? 'Default (required)' : 'Default (optional)',
                onChanged: () => setState(() {}),
              )
            else
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
