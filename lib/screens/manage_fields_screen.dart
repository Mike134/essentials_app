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
    if (choice == FieldFormatChoice.select) {
      final table = options['table'] as String?;
      if (table != null) parts.insert(1, 'to $table');
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

  /// Sibling fields available to a formula, excluding this field itself
  /// -- a field referencing itself is the one cycle that's both trivially
  /// avoidable and certain to be a mistake, so it isn't offered.
  Map<String, String> _availableFields = const {};

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
    _currencySymbolController = TextEditingController(text: (options['symbol'] as String?) ?? '');
    _decimalsController = TextEditingController(text: options['decimals']?.toString() ?? '');
    _inlineOptions = InlineOption.parseList(options['options']);
    _ratingMaxController = TextEditingController(text: options['max']?.toString() ?? '');
    _expressionController = TextEditingController(text: (options['expression'] as String?) ?? '');
    _resultType = (options['resultType'] as String?) ?? FormulaService.resultTypeNumber;
    _loadAvailableFields();
  }

  Future<void> _loadAvailableFields() async {
    final fields = await widget.metadata.loadFields(widget.field.tableName, includeDeleted: false);
    if (!mounted) return;
    setState(() {
      _availableFields = {
        for (final f in fields)
          if (f.fieldName != widget.field.fieldName) f.fieldName: f.displayName,
      };
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
    if (_format == FieldFormatChoice.inlineSelect && !_hasValidInlineOptions) return false;
    if (_format == FieldFormatChoice.formula && !isUsableFormula(_expressionController.text)) {
      return false;
    }
    return true;
  }

  bool get _hasValidInlineOptions =>
      _inlineOptions.any((o) => o.key.isNotEmpty && o.label.isNotEmpty);

  /// Same reasoning as [AddFieldScreen]'s own `_showsRequired`.
  bool get _showsRequired => _format != FieldFormatChoice.formula;

  /// Same shared "one field, several formats" shape as [AddFieldScreen]'s
  /// own `_showsDecimals` -- see that getter's doc comment.
  bool get _showsDecimals =>
      _format == FieldFormatChoice.real ||
      _format == FieldFormatChoice.currency ||
      _format == FieldFormatChoice.percentage ||
      (_format == FieldFormatChoice.formula && _resultType == FormulaService.resultTypeNumber);

  String? _buildOptionsJson() {
    if (_format == FieldFormatChoice.select) {
      return jsonEncode({'mode': 'linked', 'table': _linkedTable, 'on_delete': _onDelete.value});
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
                        .where((t) => t.tableName != widget.field.tableName)
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
