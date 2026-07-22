import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../db/generic_dao.dart';
import '../models/table_config.dart';

/// Add/edit form for a single row, entirely driven by [config]. Renders
/// text/number/boolean fields directly and lookup fields (batch 2+) as a
/// dropdown populated from the referenced table.
class GenericFormScreen extends StatefulWidget {
  const GenericFormScreen({super.key, required this.config, this.existing});

  final TableConfig config;

  /// The row being edited, or null when adding a new row.
  final Map<String, Object?>? existing;

  bool get isEditing => existing != null;

  @override
  State<GenericFormScreen> createState() => _GenericFormScreenState();
}

class _GenericFormScreenState extends State<GenericFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final GenericDao _dao;
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, bool> _boolValues = {};
  final Map<String, int?> _lookupValues = {};
  final Map<String, Future<List<Map<String, Object?>>>> _lookupOptions = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _dao = GenericDao(widget.config);
    for (final field in widget.config.fields) {
      // On add, an omitted key here still gets an explicit value written
      // on save (see _save) -- so a new row's starting value must come
      // from field.defaultValue, not a bare `false`/null/empty, or it
      // silently overrides the column's own SQL DEFAULT.
      final existingValue = widget.isEditing
          ? widget.existing![field.column]
          : field.defaultValue;
      if (field.type == FieldType.boolean) {
        _boolValues[field.column] = existingValue == 1 || existingValue == true;
      } else if (field.isLookup) {
        _lookupValues[field.column] = existingValue as int?;
        _lookupOptions[field.column] = _dao.getLookupOptions(field.lookup!);
      } else {
        _controllers[field.column] =
            TextEditingController(text: existingValue?.toString() ?? '');
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);

    final values = <String, Object?>{};
    for (final field in widget.config.fields) {
      // Computed fields (e.g. subscription_computed's yearly_cost/next_date)
      // aren't real columns on the write target -- nothing to save.
      if (field.readOnly) continue;
      if (field.type == FieldType.boolean) {
        values[field.column] = (_boolValues[field.column] ?? false) ? 1 : 0;
      } else if (field.isLookup) {
        values[field.column] = _lookupValues[field.column];
      } else {
        final text = _controllers[field.column]!.text.trim();
        if (text.isEmpty) {
          values[field.column] = null;
        } else {
          values[field.column] = switch (field.type) {
            FieldType.integer => int.tryParse(text),
            FieldType.real => double.tryParse(text),
            _ => text,
          };
        }
      }
    }

    try {
      if (widget.isEditing) {
        await _dao.update(widget.existing!['id'] as int, values);
      } else {
        await _dao.insert(values);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on DatabaseException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.isEditing ? 'Edit' : 'Add')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // The surrogate PK is database-controlled and never editable,
            // in either view type -- shown read-only here only when
            // editing, since a new/unsaved row has no id yet to show.
            if (widget.isEditing)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: TextFormField(
                  initialValue: '${widget.existing!['id']}',
                  enabled: false,
                  decoration: const InputDecoration(labelText: 'ID'),
                ),
              ),
            for (final field in widget.config.fields) _buildField(field),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildField(FieldConfig field) {
    if (field.readOnly) {
      // Same disabled-TextFormField treatment as the ID field above --
      // shown for context, never editable. Reuses the controller already
      // populated in initState (query-time value from config.readSource
      // when editing, blank on add since the row doesn't exist yet).
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: TextFormField(
          controller: _controllers[field.column],
          enabled: false,
          decoration: InputDecoration(labelText: field.label),
        ),
      );
    }

    if (field.type == FieldType.boolean) {
      return SwitchListTile(
        title: Text(field.label),
        value: _boolValues[field.column] ?? false,
        onChanged: (value) => setState(() => _boolValues[field.column] = value),
      );
    }

    if (field.isLookup) {
      final lookup = field.lookup!;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: FutureBuilder<List<Map<String, Object?>>>(
          future: _lookupOptions[field.column],
          builder: (context, snapshot) {
            final options = snapshot.data ?? const [];
            return DropdownButtonFormField<int>(
              initialValue: _lookupValues[field.column],
              decoration: InputDecoration(labelText: field.label),
              items: [
                if (!field.required)
                  const DropdownMenuItem<int>(child: Text('-')),
                for (final option in options)
                  DropdownMenuItem<int>(
                    value: option[lookup.valueColumn] as int,
                    child: Text('${option[lookup.displayColumn]}'),
                  ),
              ],
              onChanged: (value) => setState(() => _lookupValues[field.column] = value),
              validator: field.required
                  ? (value) => value == null ? '${field.label} is required' : null
                  : null,
            );
          },
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextFormField(
        controller: _controllers[field.column],
        decoration: InputDecoration(labelText: field.label),
        keyboardType: switch (field.type) {
          FieldType.integer => TextInputType.number,
          FieldType.real => const TextInputType.numberWithOptions(decimal: true),
          _ => TextInputType.text,
        },
        validator: field.required
            ? (value) =>
                (value == null || value.trim().isEmpty) ? '${field.label} is required' : null
            : null,
      ),
    );
  }
}
