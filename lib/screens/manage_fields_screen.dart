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
import '../util/permanent_delete_gate.dart';
import 'add_field_screen.dart';

/// Essentials v2 Phase 1's "Manage Fields" screen (build order step 7) --
/// replaced the retired `FieldMetadataScreen` entirely. Per claude/essentials-v2
/// -phase1-design.md's "New UI": per table, reorder (drag), rename,
/// change format, edit format options, set default, mark required,
/// soft-delete -- and shows soft-deleted fields in a collapsed "Deleted"
/// section with Restore. Every action here is a pure metadata write
/// ([SchemaMetadataDao]) -- no DDL, no `migration_log` entry, syncs like
/// any other row change.
///
/// **"Permanently delete" (build order step 9,
/// [SchemaEditorService.dropField]) is real DDL through `migration_log`** --
/// gated on [tombstoneLikelySynced], same reasoning as
/// [ManageTablesScreen]'s table-level "Permanently delete".
class ManageFieldsScreen extends StatefulWidget {
  const ManageFieldsScreen({super.key});

  @override
  State<ManageFieldsScreen> createState() => _ManageFieldsScreenState();
}

/// [SchemaMetadataDao.loadFields]'s rows, split the same way
/// [ManageTablesScreen]'s `_TablesData` splits table rows -- see
/// [_ManageFieldsScreenState._loadFields]'s doc comment.
class _FieldsData {
  _FieldsData({required this.active, required this.recoverableDeleted});

  final List<FieldDefinitionRow> active;
  final List<FieldDefinitionRow> recoverableDeleted;
}

class _ManageFieldsScreenState extends State<ManageFieldsScreen> {
  final _metadata = SchemaMetadataDao();
  final _editor = SchemaEditorService();

  late Future<List<TableDefinitionRow>> _tableNamesFuture;
  String? _selectedTable;

  /// Held directly, not behind a `Future<_FieldsData>` tracked by a
  /// `FutureBuilder`. Real bug found live on 12R, not fully explained but
  /// genuinely reproducible: adding (or deleting) a field sometimes never
  /// showed up until the whole screen was left and re-entered, sometimes
  /// worked immediately, and a second add right after a missed one would
  /// bring *both* into view at once -- a pattern more consistent with a
  /// dropped/superseded update somewhere in the load-and-rebuild chain
  /// than a single deterministic defect. Rather than keep guessing at the
  /// exact mechanism, removed the whole class of risk: [_loadFieldsInto]
  /// awaits the query itself and calls `setState` with the real result,
  /// tagged with a request id ([_fieldsRequestId]) so an older, slower
  /// reload that resolves *after* a newer one can never clobber it -- the
  /// exact race two adds fired close together could otherwise hit. A
  /// `FutureBuilder` has no such protection: it only tracks whether the
  /// `future` *identity* changed, not whether a still-in-flight older one
  /// might resolve out of order relative to a newer one.
  _FieldsData? _fieldsData;
  bool _fieldsLoading = false;
  Object? _fieldsError;
  int _fieldsRequestId = 0;

  bool _deletedExpanded = false;
  bool _dropping = false;

  @override
  void initState() {
    super.initState();
    _tableNamesFuture = _metadata.loadActiveTables();
  }

  /// Same reasoning as [ManageTablesScreen]'s `_loadTables`: a
  /// soft-deleted field whose physical column is already gone (stage-2
  /// `dropField`, or the table itself already stage-2 dropped) can never
  /// actually be restored, so it's filtered out of "Deleted" entirely
  /// rather than shown with a Restore button that would do nothing.
  Future<_FieldsData> _loadFields(String tableName) async {
    final rows = await _metadata.loadFields(tableName, includeDeleted: true);
    final physicalColumns = await _metadata.loadPhysicalColumnNames(tableName);
    return _FieldsData(
      active: [for (final f in rows) if (!f.isDeleted) f],
      recoverableDeleted: [
        for (final f in rows)
          if (f.isDeleted && physicalColumns.contains(f.fieldName)) f,
      ],
    );
  }

  /// The one place `_fieldsData` is ever written -- see that field's own
  /// doc comment for why this exists instead of a `FutureBuilder`.
  Future<void> _loadFieldsInto(String tableName) async {
    final requestId = ++_fieldsRequestId;
    setState(() {
      _fieldsLoading = true;
      _fieldsError = null;
    });
    try {
      final data = await _loadFields(tableName);
      if (!mounted || requestId != _fieldsRequestId) return;
      setState(() {
        _fieldsData = data;
        _fieldsLoading = false;
      });
    } catch (e) {
      if (!mounted || requestId != _fieldsRequestId) return;
      setState(() {
        _fieldsError = e;
        _fieldsLoading = false;
      });
    }
  }

  void _selectTable(String? table) {
    setState(() {
      _selectedTable = table;
      _fieldsData = null;
      _fieldsError = null;
      _deletedExpanded = false;
    });
    if (table != null) _loadFieldsInto(table);
  }

  void _reload() {
    final table = _selectedTable;
    if (table == null) return;
    _loadFieldsInto(table);
  }

  Future<void> _openEditor(FieldDefinitionRow field) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _FieldEditorDialog(metadata: _metadata, field: field),
    );
    if (saved == true) _reload();
  }

  Future<void> _addField() async {
    final added = await Navigator.of(
      context,
    ).push(MaterialPageRoute<bool>(builder: (_) => AddFieldScreen(initialTableName: _selectedTable)));
    if (added == true) _reload();
  }

  Future<void> _softDelete(FieldDefinitionRow field) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete field?'),
        content: Text(
          '"${field.displayName}" will disappear from the grid and form on '
          'every device. Nothing is lost -- the column and its data stay '
          'exactly where they are, and this can be undone from the '
          'Deleted section below.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _metadata.softDeleteField(field.tableName, field.fieldName);
    _reload();
  }

  Future<void> _restore(FieldDefinitionRow field) async {
    await _metadata.restoreField(field.tableName, field.fieldName);
    _reload();
  }

  Future<void> _permanentlyDelete(FieldDefinitionRow field) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permanently delete field?'),
        content: Text(
          '"${field.displayName}" and every value stored in it will be '
          'gone -- on every device, forever. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Permanently delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _dropping = true);
    try {
      await _editor.dropField(field.tableName, field.fieldName);
      _reload();
    } catch (e) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("Couldn't permanently delete"),
            content: Text('$e'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _dropping = false);
    }
  }

  Future<void> _reorder(List<FieldDefinitionRow> active, int oldIndex, int newIndex) async {
    // onReorderItem (unlike the deprecated onReorder) already adjusts
    // newIndex for the removed item at oldIndex -- no manual `-1` needed.
    final reordered = [...active];
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);

    await _metadata.reorderFields(_selectedTable!, [for (final f in reordered) f.fieldName]);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Fields')),
      floatingActionButton: _selectedTable == null
          ? null
          : FloatingActionButton(onPressed: _addField, tooltip: 'Add field', child: const Icon(Icons.add)),
      body: Padding(
        // Same system-nav-bar overlap fix as SettingsScreen -- see that
        // screen's own doc comment for why a plain EdgeInsets.all(16)
        // isn't enough. This screen's list is inside an Expanded, so the
        // fix belongs on this outer Padding (what actually constrains the
        // whole Column), not on the inner ListView's own default padding.
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                  onChanged: _selectTable,
                );
              },
            ),
            const SizedBox(height: 16),
            if (_fieldsLoading) const LinearProgressIndicator(minHeight: 2),
            if (_selectedTable != null)
              Expanded(
                child: Builder(
                  builder: (context) {
                    if (_fieldsError != null) {
                      return Center(child: Text('Failed to load: $_fieldsError'));
                    }
                    final data = _fieldsData;
                    if (data == null) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final active = data.active;
                    final deleted = data.recoverableDeleted;

                    return ListView(
                      children: [
                        if (active.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Text('No fields yet. Add one with the + button.'),
                          )
                        else
                          ReorderableListView(
                            // Real bug, found live on 12R: deleting a
                            // field left it visibly rendered until the
                            // whole screen was left and re-entered, even
                            // though the underlying data (and Manage
                            // Tables' own, structurally simpler active
                            // list) updated correctly and immediately.
                            // ReorderableListView keeps internal state for
                            // its own drag-and-drop bookkeeping tied to
                            // its children's keys -- a membership change
                            // that didn't come from its own reorder
                            // gesture (a deletion, here) isn't guaranteed
                            // to be picked up cleanly by that internal
                            // state, unlike a plain list of widgets, which
                            // has none of this to go stale. Keying the
                            // whole widget on the active field set forces
                            // a full remount (fresh internal state) on any
                            // membership change, not just reorders.
                            key: ValueKey(active.map((f) => f.fieldName).join(',')),
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            onReorderItem: (oldIndex, newIndex) => _reorder(active, oldIndex, newIndex),
                            children: [
                              for (final field in active)
                                ListTile(
                                  key: ValueKey(field.fieldName),
                                  title: Text(field.displayName),
                                  subtitle: Text(_summarize(field)),
                                  onTap: () => _openEditor(field),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline),
                                        tooltip: 'Delete field',
                                        onPressed: () => _softDelete(field),
                                      ),
                                      const Icon(Icons.drag_handle),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        if (deleted.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          ExpansionTile(
                            title: Text('Deleted (${deleted.length})'),
                            initiallyExpanded: _deletedExpanded,
                            onExpansionChanged: (v) => setState(() => _deletedExpanded = v),
                            children: [
                              for (final field in deleted)
                                ListTile(
                                  title: Text(field.displayName),
                                  subtitle: Text(_summarize(field)),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      TextButton(
                                        onPressed: () => _restore(field),
                                        child: const Text('Restore'),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.delete_forever),
                                        tooltip:
                                            permanentDeleteDisabledReason(field.modified) ??
                                            'Permanently delete',
                                        onPressed: _dropping || !tombstoneLikelySynced(field.modified)
                                            ? null
                                            : () => _permanentlyDelete(field),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ],
                    );
                  },
                ),
              )
            else
              const Expanded(
                child: Center(child: Text('Pick a table above to manage its fields.')),
              ),
          ],
        ),
      ),
    );
  }

  String _summarize(FieldDefinitionRow field) {
    final options = parseFieldOptions(field.optionsJson);
    // .resolve, not .fromValue -- a url field's stored format is plain
    // 'text' (see FieldFormatChoice.url's doc comment), so .fromValue
    // alone would show "Text" here for a field that's actually a link.
    final choice = FieldFormatChoice.resolve(field.format, options);
    final parts = <String>[
      choice.label,
      if (field.required) 'required',
      if (field.defaultValue != null) 'default: ${field.defaultValue}',
    ];
    if (choice == FieldFormatChoice.select || choice == FieldFormatChoice.linkRecord) {
      final table = options['table'] as String?;
      if (table != null) parts.insert(1, 'to $table');
    }
    if (choice == FieldFormatChoice.lookup || choice == FieldFormatChoice.rollup) {
      final linkField = options['link_field'] as String?;
      if (linkField != null) parts.insert(1, 'via $linkField');
    }
    if (choice == FieldFormatChoice.formula) {
      final expression = (options['expression'] as String?)?.trim();
      if (expression != null && expression.isNotEmpty) parts.insert(1, expression);
    }
    return parts.join(' · ');
  }
}

class _FieldEditorDialog extends StatefulWidget {
  const _FieldEditorDialog({required this.metadata, required this.field});

  final SchemaMetadataDao metadata;
  final FieldDefinitionRow field;

  @override
  State<_FieldEditorDialog> createState() => _FieldEditorDialogState();
}

class _FieldEditorDialogState extends State<_FieldEditorDialog> {
  late final TextEditingController _displayNameController;
  late final TextEditingController _defaultValueController;
  late final TextEditingController _currencySymbolController;
  late final TextEditingController _decimalsController;
  late final TextEditingController _ratingMaxController;
  late final TextEditingController _expressionController;
  late Future<List<TableDefinitionRow>> _tableNamesFuture;

  late FieldFormatChoice _format;
  late bool _required;
  String? _linkedTable;
  late OnDeleteChoice _onDelete;
  late List<InlineOption> _inlineOptions;
  late String _resultType;
  late bool _autocomplete;

  /// `link_record`'s "Allow linking to more than one record".
  late bool _linkMultiple;

  /// `lookup`/`rollup`'s "Which link field"/"Which field on the linked
  /// table"/aggregate -- same shape as [AddFieldScreen]'s own state.
  String? _linkFieldColumn;
  String? _sourceField;
  late String _rollupAggregate;

  /// Sibling fields available to a formula, excluding this field itself
  /// -- a field referencing itself is the one cycle that's both trivially
  /// avoidable and certain to be a mistake, so it isn't offered. Also
  /// backs `lookup`/`rollup`'s "Which link field" picker (filtered to
  /// `link_record` fields) -- same dual purpose as [AddFieldScreen]'s
  /// `_availableFieldRows`.
  List<FieldDefinitionRow> _availableFieldRows = const [];

  Map<String, String> get _availableFields => {
    for (final f in _availableFieldRows)
      if (f.fieldName != widget.field.fieldName) f.fieldName: f.displayName,
  };

  List<FieldDefinitionRow> get _linkRecordFields => _availableFieldRows
      .where((f) => f.format == 'link_record' && f.fieldName != widget.field.fieldName)
      .toList();

  String? _targetTableFor(String? linkFieldColumn) {
    if (linkFieldColumn == null) return null;
    for (final f in _availableFieldRows) {
      if (f.fieldName == linkFieldColumn) {
        return parseFieldOptions(f.optionsJson)['table'] as String?;
      }
    }
    return null;
  }

  List<FieldDefinitionRow> _targetFields = const [];

  /// `select`/`link_record`'s "Which field to show" -- same shape as
  /// [AddFieldScreen]'s own state, see [autoDisplayField]'s doc comment.
  String? _displayField;
  List<FieldDefinitionRow> _linkedTableFields = const [];

  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final field = widget.field;
    _displayNameController = TextEditingController(text: field.displayName);
    _defaultValueController = TextEditingController(text: field.defaultValue ?? '');
    _required = field.required;
    _tableNamesFuture = widget.metadata.loadActiveTables();

    final options = parseFieldOptions(field.optionsJson);
    // .resolve, not .fromValue -- see FieldFormatChoice.url's doc comment.
    // Reopening the editor on an existing link/inline-select field needs
    // to show the right choice selected, or saving would silently drop
    // isLink/the option list.
    _format = FieldFormatChoice.resolve(field.format, options);
    _linkedTable = options['table'] as String?;
    _onDelete = OnDeleteChoice.fromValue(options['on_delete'] as String?);
    _linkMultiple = options['multiple'] == true;
    _linkFieldColumn = options['link_field'] as String?;
    _sourceField = options['source_field'] as String?;
    _displayField = options['displayField'] as String?;
    _rollupAggregate = (options['aggregate'] as String?) ?? LinkedFieldService.defaultAggregate;
    _currencySymbolController = TextEditingController(text: (options['symbol'] as String?) ?? '');
    _decimalsController = TextEditingController(text: options['decimals']?.toString() ?? '');
    _inlineOptions = InlineOption.parseList(options['options']);
    _ratingMaxController = TextEditingController(text: options['max']?.toString() ?? '');
    _expressionController = TextEditingController(text: (options['expression'] as String?) ?? '');
    _resultType = (options['resultType'] as String?) ?? FormulaService.resultTypeNumber;
    _autocomplete = options['autocomplete'] != false;
    _loadAvailableFields();
  }

  Future<void> _loadAvailableFields() async {
    final fields = await widget.metadata.loadFields(widget.field.tableName, includeDeleted: false);
    if (!mounted) return;
    setState(() {
      _availableFieldRows = fields;
    });
    // The target-field picker needs the target table's own fields too, once
    // this field's existing `link_field` (if any) is known.
    if (_linkFieldColumn != null) _loadTargetFields(_linkFieldColumn);
    // Same for select/link_record's "Which field to show" picker.
    if (_linkedTable != null) _loadLinkedTableFields(_linkedTable, seedDefault: false);
  }

  Future<void> _loadTargetFields(String? linkFieldColumn) async {
    final targetTable = _targetTableFor(linkFieldColumn);
    if (targetTable == null) {
      setState(() => _targetFields = const []);
      return;
    }
    final fields = await widget.metadata.loadFields(targetTable, includeDeleted: false);
    if (!mounted || _linkFieldColumn != linkFieldColumn) return;
    setState(() => _targetFields = fields);
  }

  /// Same as [AddFieldScreen._loadLinkedTableFields], except [seedDefault]
  /// lets [initState]'s own initial load (above) preserve an existing
  /// field's already-saved `_displayField` instead of overwriting it with
  /// [autoDisplayField]'s pick -- only a genuine "Linked to table" *change*
  /// (the picker's own `onChanged`) should reset it.
  Future<void> _loadLinkedTableFields(String? tableName, {bool seedDefault = true}) async {
    if (tableName == null) {
      setState(() {
        _linkedTableFields = const [];
        if (seedDefault) _displayField = null;
      });
      return;
    }
    final fields = await widget.metadata.loadFields(tableName, includeDeleted: false);
    if (!mounted || _linkedTable != tableName) return;
    setState(() {
      _linkedTableFields = fields;
      if (seedDefault) _displayField = autoDisplayField(fields);
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

  bool get _canSave {
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

  /// Same reasoning as [AddFieldScreen]'s own `_showsRequired`.
  bool get _showsRequired =>
      _format != FieldFormatChoice.formula &&
      _format != FieldFormatChoice.lookup &&
      _format != FieldFormatChoice.rollup;

  /// Same shared "one field, several formats" shape as [AddFieldScreen]'s
  /// own `_showsDecimals` -- see that getter's doc comment.
  bool get _showsDecimals =>
      _format == FieldFormatChoice.real ||
      _format == FieldFormatChoice.currency ||
      _format == FieldFormatChoice.percentage ||
      (_format == FieldFormatChoice.formula && _resultType == FormulaService.resultTypeNumber);

  /// Same reasoning as [AddFieldScreen]'s own `_showsAutocomplete`.
  bool get _showsAutocomplete => _format == FieldFormatChoice.text;

  String? _buildOptionsJson() {
    if (_format == FieldFormatChoice.select) {
      return jsonEncode({
        'mode': 'linked',
        'table': _linkedTable,
        'on_delete': _onDelete.value,
        // Explicit, not omitted -- see AddFieldScreen's identical branch/
        // autoDisplayField's doc comment for why.
        'displayField': _displayField ?? 'id',
      });
    }
    // See AddFieldScreen._buildOptionsJson's identical branch -- `url`
    // isn't a real stored format, just plain 'text' plus this flag.
    if (_format == FieldFormatChoice.url) {
      return jsonEncode({'isLink': true});
    }
    // See AddFieldScreen._buildOptionsJson's identical branch.
    if (_format == FieldFormatChoice.color) {
      return jsonEncode({'isColor': true});
    }
    // See AddFieldScreen._buildOptionsJson's identical branch.
    if (_format == FieldFormatChoice.linkRecord) {
      return jsonEncode({
        'table': _linkedTable,
        'multiple': _linkMultiple,
        'on_delete': _onDelete.value,
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
    // See AddFieldScreen._buildOptionsJson's identical branch.
    if (_format == FieldFormatChoice.inlineSelect) {
      return jsonEncode({
        'mode': 'inline',
        'options': [
          for (final o in _inlineOptions)
            if (o.key.isNotEmpty && o.label.isNotEmpty) o.toJson(),
        ],
      });
    }
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
    // See AddFieldScreen._buildOptionsJson's identical branch.
    if (_showsAutocomplete && !_autocomplete) {
      options['autocomplete'] = false;
    }
    return options.isEmpty ? null : jsonEncode(options);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.metadata.updateField(
        widget.field.tableName,
        widget.field.fieldName,
        displayName: _displayNameController.text,
        format: _format.value,
        optionsJson: _buildOptionsJson(),
        // Same reasoning as AddFieldScreen's own submit: a formula field
        // is readOnly, so required/default are meaningless for it and the
        // UI hides both -- force them off rather than persisting whatever
        // the hidden controls last held.
        defaultValue: _showsRequired && _defaultValueController.text.trim().isNotEmpty
            ? _defaultValueController.text
            : null,
        isRequired: _showsRequired && _required,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = 'Failed: $e';
      });
    }
  }

  /// Same as [AddFieldScreen._buildDisplayFieldPicker] -- see that method's
  /// doc comment. The guard against a not-yet-loaded [_displayField] value
  /// matters *more* here than there: this dialog seeds [_displayField]
  /// synchronously from the field's already-saved options in [initState],
  /// before [_linkedTableFields] has had a chance to load asynchronously --
  /// a real window where the saved value genuinely doesn't match anything
  /// in [items] yet.
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
    return AlertDialog(
      title: Text('Edit "${widget.field.displayName}"'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _displayNameController,
                decoration: const InputDecoration(labelText: 'Field name'),
                onChanged: (_) => setState(() {}),
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
                        .where((t) => t.tableName != widget.field.tableName)
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
                        .where((t) => t.tableName != widget.field.tableName)
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
                    for (final f in _linkRecordFields)
                      DropdownMenuItem(value: f.fieldName, child: Text(f.displayName)),
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
                  onChanged: (options) => setState(() => _inlineOptions = options),
                ),
              ],
              if (_showsRequired) ...[
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Required'),
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
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(
          onPressed: _canSave && !_saving ? _save : null,
          child: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }
}
