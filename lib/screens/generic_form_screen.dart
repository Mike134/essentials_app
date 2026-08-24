import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../db/generic_dao.dart';
import '../db/schema_registry.dart';
import '../models/table_config.dart';
import '../theme/theme_controller.dart';
import '../util/color_picker.dart';
import '../util/bool_value.dart';
import '../util/column_autocomplete.dart';
import '../util/date_format.dart';
import '../util/field_formats/field_format_handler.dart';
import '../util/link_record.dart';
import '../util/links.dart';
import '../util/lookup_value.dart';

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
    this.copyFrom,
    this.extraValues,
    this.popOnSave = true,
    this.onSaved,
    this.appBarActions,
  }) : assert(
         existing == null || copyFrom == null,
         'existing and copyFrom are mutually exclusive -- a row is either '
         'being edited in place or copied into a new one, never both',
       );

  final TableConfig config;

  /// The row being edited, or null when adding a new row.
  final Map<String, Object?>? existing;

  /// The row to seed a *new* record's fields from, `id` excluded -- set by
  /// [GenericListScreen]'s "Copy" button. Unlike [existing], this doesn't
  /// make [isEditing] true: saving still inserts, it just starts prefilled
  /// instead of blank/defaulted.
  final Map<String, Object?>? copyFrom;

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
  final Map<String, String?> _inlineSelectValues = {};
  final Map<String, FocusNode> _focusNodes = {};

  /// Essentials v2 Phase 4 -- `link_record` fields' in-progress selection
  /// (parsed from the stored JSON array) and their target-table option
  /// list, same shape/purpose as [_lookupValues]/[_lookupOptions] but keyed
  /// off [FieldConfig.linkRecord] instead of [FieldConfig.lookup].
  final Map<String, List<int>> _linkRecordValues = {};
  final Map<String, Future<List<Map<String, Object?>>>> _linkRecordOptions = {};

  /// The reverse-relation panel's data -- every other-table record whose
  /// own `link_record` field points back at this row. `null` when adding a
  /// new row (there's no `id` yet to reverse-look-up against) or when the
  /// table has no such thing to load yet.
  Future<List<ReverseLink>>? _reverseLinksFuture;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _dao = GenericDao(widget.config);
    for (final field in widget.config.fields) {
      // On add, an omitted key here still gets an explicit value written
      // on save (see _save) -- so a new row's starting value must come
      // from field.defaultValue, not a bare `false`/null/empty, or it
      // silently overrides the column's own SQL DEFAULT. A copy takes
      // every field's value straight from copyFrom instead (id is simply
      // never one of widget.config.fields, so it's excluded automatically,
      // not via any special-case here).
      final existingValue = widget.isEditing
          ? widget.existing![field.column]
          : widget.copyFrom != null
          ? widget.copyFrom![field.column]
          : field.defaultValue;
      if (field.type == FieldType.boolean) {
        _boolValues[field.column] = coerceBoolValue(existingValue);
      } else if (field.isLookup) {
        // Real crash, found live: a v2 linked field's own column is
        // always physically TEXT (see parseLookupValue's doc comment),
        // so `existingValue` here is a String, not the int a bare `as
        // int?` cast assumed -- release-mode Flutter renders that as a
        // blank grey screen (its default error widget), not a visible
        // exception, the moment an existing record was opened for
        // editing.
        _lookupValues[field.column] = parseLookupValue(existingValue);
        _lookupOptions[field.column] = _dao.getLookupOptions(field.lookup!);
      } else if (field.isInlineSelect) {
        // No async fetch needed -- field.inlineOptions is already the
        // complete answer, unlike isLookup above. Blank -> null, same
        // "no selection" convention as everywhere else.
        final key = existingValue as String?;
        _inlineSelectValues[field.column] = (key == null || key.isEmpty) ? null : key;
      } else if (field.isLinkRecord) {
        // Essentials v2 Phase 4 -- parseLinkedIds tolerates null/blank/
        // malformed JSON (-> []), same lenient parsing every other reader
        // of a link_record column already relies on.
        _linkRecordValues[field.column] = parseLinkedIds(existingValue);
        _linkRecordOptions[field.column] = _dao.getLinkedRecordOptions(field.linkRecord!);
      } else {
        _controllers[field.column] =
            TextEditingController(text: existingValue?.toString() ?? '');
        // Recompute readOnly fields (e.g. yearly_cost) when the user tabs
        // off an editable field that might feed them -- only wired up when
        // this config actually has a preview formula (see computePreview's
        // doc comment), and never for readOnly fields themselves (those are
        // outputs, not inputs). Also allocated for an autocomplete-eligible
        // field regardless of computePreview -- Autocomplete requires its
        // own FocusNode paired with the TextEditingController it's given
        // (see _buildAutocompleteField); the listener itself stays a safe
        // no-op when computePreview is null (_recomputePreview's own early
        // return).
        if (!field.readOnly && (widget.config.computePreview != null || field.isAutocompleteText)) {
          final focusNode = FocusNode();
          focusNode.addListener(() {
            if (!focusNode.hasFocus) _recomputePreview();
          });
          _focusNodes[field.column] = focusNode;
        }
      }
    }

    // Essentials v2 Phase 4's reverse-relation panel -- only for an
    // existing row (no `id` yet on Add, same reasoning
    // [TableConfig.openRowDetail]'s own doc comment already gives for why
    // it's "never consulted for the Add flow").
    if (widget.isEditing) {
      _reverseLinksFuture = _dao.getReverseLinks(widget.existing!['id'] as int);
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
      } else if (field.isInlineSelect) {
        values[field.column] = _inlineSelectValues[field.column];
      } else if (field.isLinkRecord) {
        values[field.column] = encodeLinkedIds(_linkRecordValues[field.column] ?? const []);
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
          // Same system-nav-bar overlap fix as SettingsScreen/
          // ManageTablesScreen/ManageFieldsScreen/NewTableScreen/
          // AddFieldScreen (see CLAUDE.md's real-device verification
          // session) -- this screen just never got it at the time, since
          // it predates that pass and wasn't one of the four screens
          // checked. Found live on MIKE-12R: the Save button sat under
          // the three-button nav bar, tappable-looking but not actually
          // reachable at the very bottom edge.
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
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
            if (widget.isEditing) _buildReverseLinksSection(),
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

  /// Essentials v2 Phase 2 -- see claude/essentials-v2-phase2-design.md's
  /// "Key decision". `null` for every Phase 1 format, always (nothing is
  /// registered for them), in which case [_buildField] falls through to
  /// the existing [FieldType]-based branches completely unchanged.
  FieldFormatHandler? _formatHandlerFor(FieldConfig field) =>
      FieldFormatRegistry.instance.handlerFor(field.format);

  Widget _buildField(FieldConfig field) {
    final handler = _formatHandlerFor(field);
    if (handler != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: handler.buildFormField(context, field, _controllers[field.column]!),
      );
    }

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

    if (field.isLinkRecord) {
      return _buildLinkRecordField(field);
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

    if (field.isInlineSelect) {
      // No FutureBuilder needed -- field.inlineOptions is already the
      // complete option list, unlike isLookup above (Essentials v2 Phase
      // 2 build order step 4).
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: DropdownButtonFormField<String>(
          initialValue: _inlineSelectValues[field.column],
          decoration: InputDecoration(labelText: field.label),
          items: [
            if (!field.required) const DropdownMenuItem<String>(child: Text('-')),
            for (final option in field.inlineOptions!)
              DropdownMenuItem<String>(value: option.key, child: Text(option.label)),
          ],
          onChanged: (value) {
            setState(() => _inlineSelectValues[field.column] = value);
            _recomputePreview();
          },
          validator: field.required
              ? (value) => value == null ? '${field.label} is required' : null
              : null,
        ),
      );
    }

    if (field.isAutocompleteText) {
      return _buildAutocompleteField(field);
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

  /// Essentials v2 Phase 4's `link_record` form field -- a
  /// [DropdownButtonFormField] (mirroring [FieldConfig.isLookup]'s own
  /// dropdown almost exactly) when [LinkRecordConfig.multiple] is `false`,
  /// or a [CheckboxListTile] per option when it's `true`, per
  /// claude/essentials-v2-phase4-design.md's "Form rendering" section.
  Widget _buildLinkRecordField(FieldConfig field) {
    final linkRecord = field.linkRecord!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: FutureBuilder<List<Map<String, Object?>>>(
        future: _linkRecordOptions[field.column],
        builder: (context, snapshot) {
          final options = snapshot.data ?? const [];
          final selected = _linkRecordValues[field.column] ?? const <int>[];

          if (!linkRecord.multiple) {
            final currentValue = selected.isEmpty ? null : selected.first;
            // Same "don't offer a value the not-yet-loaded items list
            // doesn't contain yet" guard field.isLookup's own dropdown
            // above already uses, and for the identical reason (a debug
            // -build-only DropdownButtonFormField assert).
            final hasCurrentValue = options.any((o) => o['id'] == currentValue);
            return DropdownButtonFormField<int>(
              initialValue: hasCurrentValue ? currentValue : null,
              decoration: InputDecoration(labelText: field.label),
              items: [
                if (!field.required) const DropdownMenuItem<int>(child: Text('-')),
                for (final option in options)
                  DropdownMenuItem<int>(
                    value: option['id'] as int,
                    child: Text('${option[linkRecord.displayColumn]}'),
                  ),
              ],
              onChanged: (value) {
                setState(() {
                  _linkRecordValues[field.column] = value == null ? const [] : [value];
                });
                _recomputePreview();
              },
              validator: field.required
                  ? (value) => value == null ? '${field.label} is required' : null
                  : null,
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(field.label, style: Theme.of(context).textTheme.bodySmall),
              ),
              if (options.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    'Nothing to link to yet.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              for (final option in options)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text('${option[linkRecord.displayColumn]}'),
                  value: selected.contains(option['id']),
                  onChanged: (checked) {
                    setState(() {
                      final ids = [...selected];
                      final id = option['id'] as int;
                      if (checked ?? false) {
                        if (!ids.contains(id)) ids.add(id);
                      } else {
                        ids.remove(id);
                      }
                      _linkRecordValues[field.column] = ids;
                    });
                    _recomputePreview();
                  },
                ),
            ],
          );
        },
      ),
    );
  }

  /// Essentials v2 Phase 4's reverse-relation panel, per
  /// claude/essentials-v2-phase4-design.md's "New: the reverse-relation
  /// panel" section -- every other-table record whose own `link_record`
  /// field points back at this row, grouped by referencing table,
  /// read-only (tap a row to open its own form; removing/changing a link
  /// stays that record's own field). `null` future (see
  /// [_reverseLinksFuture]'s doc comment) collapses to nothing shown, same
  /// as an empty result.
  Widget _buildReverseLinksSection() {
    final future = _reverseLinksFuture;
    if (future == null) return const SizedBox.shrink();
    return FutureBuilder<List<ReverseLink>>(
      future: future,
      builder: (context, snapshot) {
        final groups = snapshot.data ?? const [];
        if (groups.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            const Divider(),
            for (final group in groups)
              ExpansionTile(
                title: Text('${group.displayName} (${group.rows.length})'),
                subtitle: Text('via ${group.fieldDisplayName}'),
                children: [
                  for (final row in group.rows)
                    ListTile(
                      dense: true,
                      // Shows both the id and the first user-entered
                      // column, not one or the other -- with more than one
                      // linked record, "click and see" was the only way
                      // to tell them apart otherwise (Mike's own real
                      // testing feedback). group.displayColumn is `null`
                      // only for a referencing table with no fields at
                      // all, in which case there's nothing else to show.
                      title: Text(
                        group.displayColumn == null
                            ? '${row['id']}'
                            : '${row['id']} — ${row[group.displayColumn] ?? ''}',
                      ),
                      onTap: () => _openReverseLinkRow(group.tableName, row),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }

  /// Opens [row] (from another table, per the reverse-relation panel) in
  /// its own [GenericFormScreen] -- building that table's [TableConfig]
  /// fresh via [SchemaRegistry] rather than a lightweight partial view,
  /// same "the destination screen is a real, fully-capable form" reasoning
  /// [GenericListScreen]'s own row-tap navigation already follows.
  Future<void> _openReverseLinkRow(String tableName, Map<String, Object?> row) async {
    try {
      final config = await SchemaRegistry().buildConfig(tableName);
      if (!mounted) return;
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => GenericFormScreen(config: config, existing: row)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't open record: $e")));
    }
  }

  /// See claude/essentials-v2-column-autocomplete-design.md. A plain
  /// [Autocomplete] rather than a hand-rolled overlay -- it already ships
  /// exactly what the design doc asks for (async `optionsBuilder`, arrow
  /// keys to move the highlight, Enter/Tab to accept, Escape to dismiss)
  /// as long as its field is single-line. That last part is a deliberate,
  /// narrow exception to this screen's general "every field auto-wraps"
  /// convention (`maxLines: null` everywhere else, see the plain-text
  /// branch above and CLAUDE.md's "Debugging session"): confirmed by
  /// reading the Flutter SDK's own `Autocomplete` source that its default
  /// field is single-line, because a multi-line `EditableText` consumes
  /// vertical-arrow key events for its own caret movement before they can
  /// ever bubble up to `RawAutocomplete`'s `Shortcuts` wrapper -- a
  /// wrapped field would silently lose arrow-key highlight navigation.
  /// Reasonable to give up multi-line growth here specifically: an
  /// autocomplete-eligible field is, per the design doc's own framing, a
  /// short recurring value (a city, a category, a name) -- not a notes
  /// field, which is exactly the kind of field this whole feature was
  /// scoped to exclude in the first place.
  Widget _buildAutocompleteField(FieldConfig field) {
    final controller = _controllers[field.column]!;
    final source = ColumnAutocompleteSource(
      dao: _dao,
      field: field,
      excludeValue: () => controller.text,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Autocomplete<String>(
        optionsBuilder: source.call,
        focusNode: _focusNodes[field.column]!,
        textEditingController: controller,
        onSelected: (_) => _recomputePreview(),
        fieldViewBuilder: (context, fieldController, fieldFocusNode, onFieldSubmitted) {
          return TextFormField(
            controller: fieldController,
            focusNode: fieldFocusNode,
            decoration: InputDecoration(labelText: field.label),
            keyboardType: TextInputType.text,
            onFieldSubmitted: (_) => onFieldSubmitted(),
            validator: field.required
                ? (value) =>
                    (value == null || value.trim().isEmpty) ? '${field.label} is required' : null
                : null,
          );
        },
      ),
    );
  }
}
