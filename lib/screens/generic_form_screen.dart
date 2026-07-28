import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../db/generic_dao.dart';
import '../models/table_config.dart';
import '../theme/theme_controller.dart';
import '../util/color_picker.dart';
import '../util/date_format.dart';
import '../util/links.dart';

/// Add/edit form for a single row, entirely driven by [config]. Renders
/// text/number/boolean fields directly, lookup fields (batch 2+) as a
/// dropdown populated from the referenced table, and date/dateTime fields
/// as a plain text box (still directly editable, same as color/link) plus
/// a calendar icon that opens the native date/time picker.
class GenericFormScreen extends StatefulWidget {
  const GenericFormScreen({
    super.key,
    required this.config,
    this.existing,
    this.extraValues,
    this.popOnSave = true,
    this.onSaved,
    this.appBarActions,
  });

  final TableConfig config;

  /// The row being edited, or null when adding a new row.
  final Map<String, Object?>? existing;

  /// Merged into the write on save, on top of whatever the form's own
  /// fields collected -- for a value that's real on the table but
  /// deliberately not a [TableConfig.fields] entry here, so the user never
  /// sees or edits it directly. Only current use: the embedded `order_items`
  /// form inside [OrderSplitPaneScreen] silently writes `order_id` from the
  /// currently-open parent order, never shown as a field (CLAUDE.md's Part
  /// B requirement -- the standalone `order_items` screen's generic FK
  /// dropdown for `order_id` is for direct nav only).
  final Map<String, Object?>? extraValues;

  /// `false` for the order form embedded in [OrderSplitPaneScreen]'s wide
  /// layout -- Save there should write and stay in place (both panes stay
  /// live side-by-side, "no navigation between them" per CLAUDE.md), not
  /// pop back to whatever pushed this screen. Every other caller keeps the
  /// default `true` (Save returns to the previous screen, same as always).
  final bool popOnSave;

  /// Fires after a successful save when [popOnSave] is `false`, since
  /// there's no pop for a caller to await instead.
  final VoidCallback? onSaved;

  /// Extra `AppBar.actions` -- only current use: the narrow-layout order
  /// form's "Items" button in [OrderSplitPaneScreen], pushing the full-screen
  /// `order_items` list. `null` for every other table, same bare AppBar as
  /// before this existed.
  final List<Widget>? appBarActions;

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
  final Map<String, FocusNode> _focusNodes = {};
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
        // Recompute readOnly fields (e.g. yearly_cost) when the user tabs
        // off an editable field that might feed them -- only wired up when
        // this config actually has a preview formula (see computePreview's
        // doc comment), and never for readOnly fields themselves (those are
        // outputs, not inputs).
        if (!field.readOnly && widget.config.computePreview != null) {
          final focusNode = FocusNode();
          focusNode.addListener(() {
            if (!focusNode.hasFocus) _recomputePreview();
          });
          _focusNodes[field.column] = focusNode;
        }
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final focusNode in _focusNodes.values) {
      focusNode.dispose();
    }
    super.dispose();
  }

  /// The in-progress field values a save would write, keyed by column --
  /// also what [TableConfig.computePreview] recomputes readOnly fields
  /// from, so unlike [_save] this must be callable without validating or
  /// actually writing anything.
  Map<String, Object?> _currentValues() {
    final values = <String, Object?>{};
    for (final field in widget.config.fields) {
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
    return values;
  }

  Future<void> _pickColorForField(FieldConfig field) async {
    final controller = _controllers[field.column]!;
    final current = ThemeController.parseHexColor(controller.text) ?? Colors.white;
    final picked = await pickColor(context, initial: current);
    if (picked == null) return;
    setState(() => controller.text = ThemeController.colorToHex(picked));
    _recomputePreview();
  }

  /// Date-only field (schema.sql's `order_date`/`start_date`/etc.) --
  /// [DateTime.tryParse] happily parses the field's own `yyyy-MM-dd` text
  /// back for [initialDate], so re-opening the picker on an already-filled
  /// field starts on the right day rather than always today.
  Future<void> _pickDateForField(FieldConfig field) async {
    final controller = _controllers[field.column]!;
    final current = DateTime.tryParse(controller.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() => controller.text = isoDate(picked));
    _recomputePreview();
  }

  /// Combined date+time field (schema.sql's `journal.entry_time`, the only
  /// one so far) -- date first, then time, matching how Android/iOS's own
  /// native pickers sequence the two rather than a single custom combined
  /// widget. Seconds aren't user-editable through either native picker, so
  /// they're carried over from whatever [current] already had (0 for a
  /// brand-new row) rather than always reset to 0 on every edit.
  Future<void> _pickDateTimeForField(FieldConfig field) async {
    final controller = _controllers[field.column]!;
    final current = DateTime.tryParse(controller.text) ?? DateTime.now();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (pickedDate == null) return;
    if (!mounted) return;
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    final combined = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime?.hour ?? current.hour,
      pickedTime?.minute ?? current.minute,
      current.second,
    );
    setState(() => controller.text = isoDateTime(combined));
    _recomputePreview();
  }

  Future<void> _recomputePreview() async {
    final compute = widget.config.computePreview;
    if (compute == null) return;
    final updates = await compute(_currentValues());
    if (!mounted) return;
    setState(() {
      for (final entry in updates.entries) {
        _controllers[entry.key]?.text = entry.value?.toString() ?? '';
      }
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);

    final values = {..._currentValues(), ...?widget.extraValues};

    try {
      if (widget.isEditing) {
        await _dao.update(widget.existing!['id'] as int, values);
      } else {
        await _dao.insert(values);
      }
      if (!mounted) return;
      if (widget.popOnSave) {
        Navigator.of(context).pop(true);
      } else {
        setState(() => _saving = false);
        widget.onSaved?.call();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
      }
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
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Edit' : 'Add'),
        actions: widget.appBarActions,
      ),
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
                  maxLines: null,
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
          maxLines: null,
          decoration: InputDecoration(labelText: field.label),
        ),
      );
    }

    if (field.type == FieldType.boolean) {
      return SwitchListTile(
        title: Text(field.label),
        value: _boolValues[field.column] ?? false,
        onChanged: (value) {
          setState(() => _boolValues[field.column] = value);
          _recomputePreview();
        },
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
            final currentValue = _lookupValues[field.column];
            // While options are still loading, `items` below doesn't yet
            // contain currentValue -- DropdownButtonFormField asserts (in
            // debug builds only, which is why this was only ever visible
            // via `flutter run`/F5, never the release APK) that its value
            // matches exactly one item unless items is empty or the value
            // is null. A required field's items list actually starts empty
            // (no blank placeholder item), which happens to dodge this; an
            // optional one always has that placeholder, so it doesn't.
            // Falling back to null here is safe either way: once options
            // load, DropdownButtonFormField's own state picks up the
            // now-valid initialValue via didUpdateWidget.
            final hasCurrentValue = options.any(
              (option) => option[lookup.valueColumn] == currentValue,
            );
            return DropdownButtonFormField<int>(
              initialValue: hasCurrentValue ? currentValue : null,
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
              onChanged: (value) {
                setState(() => _lookupValues[field.column] = value);
                _recomputePreview();
              },
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
        focusNode: _focusNodes[field.column],
        maxLines: null,
        // Same blue-underline treatment as the grid's link renderer, so a
        // link field reads as a link here too, not just via the icon.
        style: field.isLink
            ? const TextStyle(color: Colors.blue, decoration: TextDecoration.underline)
            : null,
        decoration: InputDecoration(
          labelText: field.label,
          prefixIcon: field.isColor
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: AnimatedBuilder(
                    // Repaints the swatch as the user types a hex value
                    // directly, not just after picking one.
                    animation: _controllers[field.column]!,
                    builder: (context, _) => Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: ThemeController.parseHexColor(
                          _controllers[field.column]!.text,
                        ),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.grey),
                      ),
                    ),
                  ),
                )
              : null,
          suffixIcon: field.isLink
              ? IconButton(
                  icon: const Icon(Icons.open_in_new),
                  tooltip: 'Open link',
                  onPressed: () => openLink(_controllers[field.column]!.text),
                )
              : field.isColor
              ? IconButton(
                  icon: const Icon(Icons.palette_outlined),
                  tooltip: 'Pick a color',
                  onPressed: () => _pickColorForField(field),
                )
              : field.type == FieldType.date
              ? IconButton(
                  icon: const Icon(Icons.calendar_today_outlined),
                  tooltip: 'Pick a date',
                  onPressed: () => _pickDateForField(field),
                )
              : field.type == FieldType.dateTime
              ? IconButton(
                  icon: const Icon(Icons.event_outlined),
                  tooltip: 'Pick a date and time',
                  onPressed: () => _pickDateTimeForField(field),
                )
              : null,
        ),
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
