import 'package:flutter/material.dart';

import '../db/field_metadata_dao.dart';
import '../db/table_discovery_service.dart';

/// Edits `field_metadata` -- the override layer for a table's display
/// label, insert default, lookup display column, and link-field flag (see
/// [FieldMetadataDao]'s doc comment for the override model). Reached from
/// [SettingsScreen]. This exists specifically because "edited via Letos"
/// stopped being safe once sync moved to the record level -- a Letos edit
/// never touches sqlite_crdt's bookkeeping columns, so it would silently
/// never sync (see CLAUDE.md "Syncing at the Record Level"). Deliberately
/// its own small screen, not routed through [GenericListScreen]/
/// [GenericFormScreen]: those assume every table has a single-column `id`
/// primary key, and `field_metadata`'s real key is the composite
/// `(table_name, field_name)` -- reworking the generic CRUD screens to
/// support composite keys generically, for the sake of this one table,
/// would be a much larger and riskier change than a small dedicated screen.
class FieldMetadataScreen extends StatefulWidget {
  const FieldMetadataScreen({super.key});

  @override
  State<FieldMetadataScreen> createState() => _FieldMetadataScreenState();
}

class _FieldMetadataScreenState extends State<FieldMetadataScreen> {
  final _dao = FieldMetadataDao();
  final _discovery = TableDiscoveryService();
  late Future<List<FieldMetadata>> _rowsFuture;

  @override
  void initState() {
    super.initState();
    _rowsFuture = _dao.loadAll();
  }

  void _reload() {
    setState(() => _rowsFuture = _dao.loadAll());
  }

  Future<void> _openEditor({FieldMetadata? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _FieldMetadataEditorDialog(
        discovery: _discovery,
        dao: _dao,
        existing: existing,
      ),
    );
    if (saved == true) _reload();
  }

  Future<void> _delete(FieldMetadata row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove override?'),
        content: Text(
          '${row.tableName}.${row.fieldName} will fall back to the '
          'introspection heuristic instead of this override. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _dao.deleteOne(row.tableName, row.fieldName);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Field Labels & Defaults')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(),
        tooltip: 'Add override',
        child: const Icon(Icons.add),
      ),
      body: FutureBuilder<List<FieldMetadata>>(
        future: _rowsFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Failed to load: ${snapshot.error}'));
          }
          final rows = snapshot.data;
          if (rows == null) return const Center(child: CircularProgressIndicator());
          if (rows.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No overrides yet. Every table\'s labels and defaults are '
                  'derived automatically from its columns -- add an override '
                  'here only where that heuristic isn\'t what you want.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final row = rows[index];
              return ListTile(
                title: Text('${row.tableName}.${row.fieldName}'),
                subtitle: Text(_summarize(row)),
                onTap: () => _openEditor(existing: row),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove override',
                  onPressed: () => _delete(row),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _summarize(FieldMetadata row) {
    final parts = <String>[
      if (row.displayLabel != null) 'label: ${row.displayLabel}',
      if (row.defaultValue != null) 'default: ${row.defaultValue}',
      if (row.lookupDisplayColumn != null) 'lookup shows: ${row.lookupDisplayColumn}',
      if (row.isLink != null) 'link: ${row.isLink}',
    ];
    return parts.isEmpty ? '(no overrides set)' : parts.join(' · ');
  }
}

class _FieldMetadataEditorDialog extends StatefulWidget {
  const _FieldMetadataEditorDialog({
    required this.discovery,
    required this.dao,
    this.existing,
  });

  final TableDiscoveryService discovery;
  final FieldMetadataDao dao;
  final FieldMetadata? existing;

  @override
  State<_FieldMetadataEditorDialog> createState() => _FieldMetadataEditorDialogState();
}

class _FieldMetadataEditorDialogState extends State<_FieldMetadataEditorDialog> {
  late Future<List<String>> _tableNamesFuture;
  Future<List<String>>? _fieldNamesFuture;

  String? _selectedTable;
  String? _selectedField;
  late final TextEditingController _displayLabelController;
  late final TextEditingController _defaultValueController;
  late final TextEditingController _lookupDisplayColumnController;
  bool? _isLink;

  bool get _isEditingExisting => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _tableNamesFuture = widget.discovery.discoverTableNames();
    final existing = widget.existing;
    _selectedTable = existing?.tableName;
    _selectedField = existing?.fieldName;
    if (_selectedTable != null) {
      _fieldNamesFuture = widget.discovery.editableColumnNames(_selectedTable!);
    }
    _displayLabelController = TextEditingController(text: existing?.displayLabel ?? '');
    _defaultValueController = TextEditingController(text: existing?.defaultValue ?? '');
    _lookupDisplayColumnController =
        TextEditingController(text: existing?.lookupDisplayColumn ?? '');
    _isLink = existing?.isLink;
  }

  @override
  void dispose() {
    _displayLabelController.dispose();
    _defaultValueController.dispose();
    _lookupDisplayColumnController.dispose();
    super.dispose();
  }

  void _onTableChanged(String? table) {
    setState(() {
      _selectedTable = table;
      _selectedField = null;
      _fieldNamesFuture = table == null ? null : widget.discovery.editableColumnNames(table);
    });
  }

  String? _nullIfEmpty(String text) => text.trim().isEmpty ? null : text.trim();

  Future<void> _save() async {
    final table = _selectedTable;
    final field = _selectedField;
    if (table == null || field == null) return;

    await widget.dao.upsert(
      tableName: table,
      fieldName: field,
      displayLabel: _nullIfEmpty(_displayLabelController.text),
      defaultValue: _nullIfEmpty(_defaultValueController.text),
      lookupDisplayColumn: _nullIfEmpty(_lookupDisplayColumnController.text),
      isLink: _isLink,
    );
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final canSave = _selectedTable != null && _selectedField != null;
    return AlertDialog(
      title: Text(_isEditingExisting ? 'Edit override' : 'Add override'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FutureBuilder<List<String>>(
                future: _tableNamesFuture,
                builder: (context, snapshot) {
                  final tables = snapshot.data ?? const [];
                  return DropdownButtonFormField<String>(
                    initialValue: _selectedTable,
                    decoration: const InputDecoration(labelText: 'Table'),
                    // Table/field identify the row -- changing either on an
                    // existing override would mean editing a different row
                    // entirely, not updating this one. Simplest and safest:
                    // fixed once created; delete and re-add to retarget.
                    onChanged: _isEditingExisting ? null : _onTableChanged,
                    items: [
                      for (final t in tables) DropdownMenuItem(value: t, child: Text(t)),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              if (_fieldNamesFuture != null)
                FutureBuilder<List<String>>(
                  future: _fieldNamesFuture,
                  builder: (context, snapshot) {
                    final fields = snapshot.data ?? const [];
                    return DropdownButtonFormField<String>(
                      initialValue: _selectedField,
                      decoration: const InputDecoration(labelText: 'Field'),
                      onChanged: _isEditingExisting
                          ? null
                          : (value) => setState(() => _selectedField = value),
                      items: [
                        for (final f in fields) DropdownMenuItem(value: f, child: Text(f)),
                      ],
                    );
                  },
                ),
              const SizedBox(height: 20),
              TextField(
                controller: _displayLabelController,
                decoration: const InputDecoration(
                  labelText: 'Display label',
                  hintText: 'Blank = derive from the column name',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _defaultValueController,
                decoration: const InputDecoration(
                  labelText: 'Insert default',
                  hintText: 'Blank = use the column\'s own SQL default, if any',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _lookupDisplayColumnController,
                decoration: const InputDecoration(
                  labelText: 'Lookup display column',
                  hintText: 'Only meaningful for a foreign-key field, e.g. "code"',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<bool?>(
                initialValue: _isLink,
                decoration: const InputDecoration(labelText: 'Is a link field?'),
                items: const [
                  DropdownMenuItem(value: null, child: Text('Derive from the column name')),
                  DropdownMenuItem(value: true, child: Text('Yes')),
                  DropdownMenuItem(value: false, child: Text('No')),
                ],
                onChanged: (value) => setState(() => _isLink = value),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: canSave ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
