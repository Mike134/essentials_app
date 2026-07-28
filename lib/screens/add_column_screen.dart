import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../db/schema_editor_service.dart';

/// Runs `ALTER TABLE ... ADD COLUMN` on this device's own database. See
/// [SchemaEditorService]'s doc comment for why this is deliberately
/// single-device -- sqlite_crdt never propagates a schema change, so
/// running this screen here doesn't touch MIKE-12R or the server's
/// `hub.db`; Mike still has to trigger it again on each. What this
/// replaces is hand-typing the `ALTER TABLE` separately per device (risk
/// of a typo making them subtly different) -- see CLAUDE.md "Letos/DBeaver
/// workflow going forward".
class AddColumnScreen extends StatefulWidget {
  const AddColumnScreen({super.key});

  @override
  State<AddColumnScreen> createState() => _AddColumnScreenState();
}

class _AddColumnScreenState extends State<AddColumnScreen> {
  final _service = SchemaEditorService();
  late Future<List<String>> _tableNamesFuture;

  final _columnNameController = TextEditingController();
  final _defaultValueController = TextEditingController();

  String? _selectedTable;
  NewColumnType _type = NewColumnType.text;
  bool _notNull = false;
  bool _booleanDefault = false;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tableNamesFuture = _service.tableNames();
  }

  @override
  void dispose() {
    _columnNameController.dispose();
    _defaultValueController.dispose();
    super.dispose();
  }

  String? get _previewDdl {
    final table = _selectedTable;
    final column = _columnNameController.text.trim();
    if (table == null || column.isEmpty) return null;
    try {
      return _service.buildDdl(
        tableName: table,
        columnName: column,
        type: _type,
        notNull: _notNull,
        defaultValue: _defaultValueController.text,
        booleanDefault: _booleanDefault,
      );
    } on ArgumentError {
      return null; // Invalid default mid-typing -- just don't show a preview yet.
    }
  }

  bool get _canSubmit {
    if (_selectedTable == null) return false;
    if (_columnNameController.text.trim().isEmpty) return false;
    if (_type != NewColumnType.boolean && _notNull && _defaultValueController.text.trim().isEmpty) {
      return false;
    }
    return true;
  }

  Future<void> _submit() async {
    final table = _selectedTable;
    if (table == null) return;
    final column = _columnNameController.text.trim();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add column?'),
        content: Text(
          'This runs on $table on this device only. Close essentials_app on '
          'your other devices first -- a device that\'s still connected '
          'while schemas don\'t match risks a failed sync. This cannot be '
          'undone from within the app.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add Column')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final ddl = await _service.addColumn(
        tableName: table,
        columnName: column,
        type: _type,
        notNull: _notNull,
        defaultValue: _defaultValueController.text,
        booleanDefault: _booleanDefault,
      );
      if (!mounted) return;
      setState(() => _saving = false);
      await _showSuccess(table, ddl);
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

  Future<void> _showSuccess(String table, String ddl) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Column added'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Added to $table on this device.'),
              const SizedBox(height: 12),
              const Text(
                'Still to do, in order:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const Text('• Close essentials_app here too, before it reconnects.'),
              const Text('• Add this statement to schema.sql.'),
              const Text('• Copy it from schema.sql to MIKE-12R (SQLite Pro).'),
              const Text('• Copy it from schema.sql to the server\'s hub.db.'),
              const Text('• Copy it from schema.sql into server.dart and commit.'),
              const Text('• Reopen essentials_app on every device.'),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SelectableText(ddl, style: const TextStyle(fontFamily: 'monospace')),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: ddl));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard.')),
                );
              }
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() {
      _columnNameController.clear();
      _defaultValueController.clear();
      _notNull = false;
      _booleanDefault = false;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ddlPreview = _previewDdl;
    return Scaffold(
      appBar: AppBar(title: const Text('Add Column')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Adds a real column to a table on this device via ALTER TABLE. '
            'Does not sync or propagate -- run it again on each other device.',
          ),
          const SizedBox(height: 20),
          FutureBuilder<List<String>>(
            future: _tableNamesFuture,
            builder: (context, snapshot) {
              final tables = snapshot.data ?? const [];
              return DropdownButtonFormField<String>(
                initialValue: _selectedTable,
                decoration: const InputDecoration(labelText: 'Table'),
                items: [
                  for (final t in tables) DropdownMenuItem(value: t, child: Text(t)),
                ],
                onChanged: (value) => setState(() => _selectedTable = value),
              );
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _columnNameController,
            decoration: const InputDecoration(
              labelText: 'Column name',
              hintText: 'lower_snake_case, matching this schema\'s convention',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<NewColumnType>(
            initialValue: _type,
            decoration: const InputDecoration(labelText: 'Type'),
            items: const [
              DropdownMenuItem(value: NewColumnType.text, child: Text('Text')),
              DropdownMenuItem(value: NewColumnType.integer, child: Text('Integer')),
              DropdownMenuItem(value: NewColumnType.real, child: Text('Decimal')),
              DropdownMenuItem(value: NewColumnType.boolean, child: Text('Yes/No')),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _type = value;
                if (value == NewColumnType.boolean) _notNull = false;
              });
            },
          ),
          const SizedBox(height: 12),
          if (_type == NewColumnType.boolean)
            DropdownButtonFormField<bool>(
              initialValue: _booleanDefault,
              decoration: const InputDecoration(labelText: 'Default'),
              items: const [
                DropdownMenuItem(value: false, child: Text('No')),
                DropdownMenuItem(value: true, child: Text('Yes')),
              ],
              onChanged: (value) => setState(() => _booleanDefault = value ?? false),
            )
          else ...[
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Required (NOT NULL)'),
              subtitle: const Text('Needs a default below -- existing rows must get a value.'),
              value: _notNull,
              onChanged: (value) => setState(() => _notNull = value ?? false),
            ),
            TextField(
              controller: _defaultValueController,
              decoration: InputDecoration(
                labelText: _notNull ? 'Default (required)' : 'Default (optional)',
                hintText: 'Blank = no default, column starts NULL on existing rows',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
          const SizedBox(height: 20),
          if (ddlPreview != null) ...[
            const Text('Preview', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: SelectableText(ddlPreview, style: const TextStyle(fontFamily: 'monospace')),
            ),
            const SizedBox(height: 20),
          ],
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 12),
          ],
          ElevatedButton(
            onPressed: _canSubmit && !_saving ? _submit : null,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Add Column'),
          ),
        ],
      ),
    );
  }
}
