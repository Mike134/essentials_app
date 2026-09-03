import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' show dirname, extension;
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';

import '../db/event_dispatch_service.dart';
import '../db/file_sync_service.dart';
import '../db/generic_dao.dart';
import '../db/schema_registry.dart';
import '../models/table_config.dart';
import '../theme/theme_controller.dart';
import '../util/color_picker.dart';
import '../util/bool_value.dart';
import '../util/column_autocomplete.dart';
import '../util/date_format.dart';
import '../util/field_formats/field_format_handler.dart';
import '../util/geo_location.dart';
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

  /// This table's Geo Location group (`null` if it doesn't have all four
  /// fields) and its optional Map Location field -- computed once, since
  /// [widget.config] never changes for this screen's lifetime (a fresh
  /// push per record, never re-pointed at a different table). See
  /// `lib/util/geo_location.dart`'s own doc comment for why these are
  /// detected by field label, not a stored flag.
  late final GeoLocationFields? _geoLocationFields = geoLocationFieldsOf(widget.config.fields);
  late final FieldConfig? _mapLocationField = mapLocationFieldOf(widget.config.fields);
  bool _capturingLocation = false;

  /// Image field support -- see claude/essentials-v2-image-field-ui-design.md.
  /// `_capturingImage` is keyed by `field.column`, same per-field-flag shape
  /// as everything else in this screen (a form can have more than one image
  /// field). `_imagePreviewFutures` caches each field's resolved preview
  /// [File] by the stored relative-key value itself -- already globally
  /// unique (it embeds table/record/field/filename), so no need to also key
  /// on `field.column`. Keying on the *value* rather than the field means a
  /// fresh capture (a new stored value) always gets a fresh resolution
  /// instead of reusing a stale cached Future for the old value. See
  /// [_resolveImageFile]/[_ingestPickedImage] for why this still isn't
  /// enough on its own to avoid a stale *image*, not just a stale Future,
  /// when a recapture reuses the same filename.
  final _fileSync = FileSyncService();
  final Map<String, bool> _capturingImage = {};
  final Map<String, Future<File?>> _imagePreviewFutures = {};
  final Map<String, bool> _imageDragHovering = {};

  /// Same extension set as the hub's own `_imageContentTypes` map (see
  /// claude/essentials-v2-file-transfer-endpoint-design.md) -- a dropped or
  /// browsed file outside this list is rejected before ever being ingested,
  /// same "don't silently accept something the rest of the pipeline can't
  /// serve a sane content-type for" reasoning.
  static const _recognizedImageExtensions = {'.jpg', '.jpeg', '.png', '.heic', '.webp', '.gif'};

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

    // Essentials v2 Phase 5 build order step 4 -- fire-and-forget, same
    // reasoning as ThemeController.load()'s own initState call: nothing
    // here needs to block the form from rendering, and this screen has
    // no meaningful "loading" state to show while it runs. Cheap to call
    // unconditionally -- EventDispatchService.dispatch is a no-op query
    // when nothing's bound (true for every table today, since the UI to
    // create an event_definitions row doesn't exist yet -- step 5).
    EventDispatchService().dispatchAndApplyEffects(
      context,
      tableName: widget.config.tableName,
      eventType: 'form_opened',
      recordId: widget.isEditing ? widget.existing!['id'] as int : null,
    );
  }

  @override
  void dispose() {
    // Fire-and-forget, and deliberately not `dispatchAndApplyEffects` --
    // this screen is being torn down right now, so there's no context
    // left to show a SnackBar/push a Navigator route into by the time a
    // script would finish; a `notify`/`navigate` effect from a
    // form_closed script is silently dropped rather than attempted
    // against a dead widget. The script's own database writes still
    // happen normally regardless (see EventDispatchService.dispatch,
    // which never touches BuildContext).
    EventDispatchService().dispatch(
      tableName: widget.config.tableName,
      eventType: 'form_closed',
      recordId: widget.isEditing ? widget.existing!['id'] as int : null,
    );
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

  /// Sets a date/dateTime field to the current moment directly, without
  /// going through the picker dialog -- Mike's ask: a quick "Now" button
  /// alongside the existing picker icon for the common "just stamp it with
  /// right now" case (e.g. a journal entry's timestamp), rather than always
  /// having to pick today's date and the current time by hand.
  void _setFieldToNow(FieldConfig field) {
    final controller = _controllers[field.column]!;
    final now = DateTime.now();
    controller.text = field.type == FieldType.dateTime ? isoDateTime(now) : isoDate(now);
    _recomputePreview();
  }

  /// One button fills the whole Geo Location group, and -- if a Map
  /// Location field is also present -- reverse-geocodes into it too, per
  /// Mike's explicit ask ("If there is a Map Location field, it fills that
  /// in too. Otherwise it just does not call geocoding."). Never called
  /// with [geoLocationCaptureSupported] false (the button is disabled
  /// there, not hidden -- see [_buildGeoLocationCaptureButton]).
  Future<void> _captureLocation() async {
    final geo = _geoLocationFields!;
    setState(() => _capturingLocation = true);
    try {
      final position = await captureCurrentPosition();
      _controllers[geo.latitude.column]!.text = position.latitude.toString();
      _controllers[geo.longitude.column]!.text = position.longitude.toString();
      _controllers[geo.altitude.column]!.text = position.altitude.toString();
      _controllers[geo.accuracy.column]!.text = position.accuracy.toString();

      final mapField = _mapLocationField;
      if (mapField != null) {
        final address = await reverseGeocodeToText(position.latitude, position.longitude);
        if (address != null) _controllers[mapField.column]!.text = address;
      }
      _recomputePreview();
    } on GeoLocationCaptureException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not get location: $e')));
    } finally {
      if (mounted) setState(() => _capturingLocation = false);
    }
  }

  /// Visible but disabled on Windows (no GPS hardware), per Mike's explicit
  /// ask -- not hidden, same "don't ship a dead-looking live control, show
  /// why it's off" instinct already established elsewhere in this app
  /// (`ManageFieldsScreen`'s "Permanently delete" placeholder,
  /// `BarcodeFormatHandler`'s Android-only scan icon takes the opposite,
  /// "just don't render it" approach instead -- this one Mike specifically
  /// wants visible everywhere).
  Widget _buildGeoLocationCaptureButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Tooltip(
        message: geoLocationCaptureSupported
            ? 'Fill Latitude/Longitude/Altitude/Accuracy from this device\'s current location.'
            : 'Only available on Android -- this device has no GPS hardware.',
        child: OutlinedButton.icon(
          onPressed: (geoLocationCaptureSupported && !_capturingLocation) ? _captureLocation : null,
          icon: _capturingLocation
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.my_location_outlined),
          label: const Text('Capture current location'),
        ),
      ),
    );
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
      final int id;
      if (widget.isEditing) {
        id = widget.existing!['id'] as int;
        await _dao.update(id, values);
      } else {
        id = await _dao.insert(values);
      }

      // Essentials v2 Phase 5 build order step 4 -- dispatched (and any
      // notify/navigate effects applied) *before* popping, while `context`
      // is still guaranteed to be this screen's own mounted context, not
      // whatever screen a pop already returned to.
      final dispatcher = EventDispatchService();
      if (!mounted) return;
      if (widget.isEditing) {
        await dispatcher.dispatchAndApplyEffects(
          context,
          tableName: widget.config.tableName,
          eventType: 'record_updated',
          recordId: id,
        );
        for (final field in widget.config.fields) {
          if (!mounted) return;
          final before = widget.existing![field.column]?.toString();
          final after = values[field.column]?.toString();
          if (before == after) continue;
          await dispatcher.dispatchAndApplyEffects(
            context,
            tableName: widget.config.tableName,
            eventType: 'field_changed',
            fieldName: field.column,
            recordId: id,
          );
        }
      } else {
        if (!mounted) return;
        await dispatcher.dispatchAndApplyEffects(
          context,
          tableName: widget.config.tableName,
          eventType: 'record_created',
          recordId: id,
        );
      }
      if (!mounted) return;
      await dispatcher.dispatchAndApplyEffects(
        context,
        tableName: widget.config.tableName,
        eventType: 'record_saved',
        recordId: id,
      );

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
        // Save lives here, not at the bottom of the form -- Mike's ask:
        // reachable without scrolling through a long form first. Directly
        // right of the title, before any other appBarActions (e.g. the
        // split-pane order screen's "Items" button) so it's the first
        // thing reached tabbing/scanning right from the title.
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
          ...?widget.appBarActions,
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          // Same system-nav-bar overlap fix as SettingsScreen/
          // ManageTablesScreen/ManageFieldsScreen/NewTableScreen/
          // AddFieldScreen (see CLAUDE.md's real-device verification
          // session) -- originally added because Save sat at the very
          // bottom of this ListView and landed under MIKE-12R's
          // three-button nav bar. Save has since moved into the AppBar
          // (Mike's ask: reachable without scrolling a long form), but
          // kept here regardless -- the reverse-links section can still be
          // the last thing on screen, and this padding costs nothing when
          // there's no nav bar to avoid (Windows: `MediaQuery.paddingOf
          // (context).bottom` is just 0).
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
            for (final entry in widget.config.fields.asMap().entries) ...[
              _buildField(entry.value),
              if (_geoLocationFields != null &&
                  entry.key == _geoLocationFields.lastPosition(widget.config.fields))
                _buildGeoLocationCaptureButton(),
            ],
            if (widget.isEditing) _buildReverseLinksSection(),
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

  /// `button` is deliberately handled here, before the generic
  /// [FieldFormatHandler] dispatch below, rather than through
  /// `ButtonFormatHandler.buildFormField` -- that shared interface has no
  /// way to pass a table name or record id, which running a real
  /// `button_clicked` script genuinely needs (unlike every other Phase 2
  /// format, none of which need anything beyond their own field's value).
  /// `ButtonFormatHandler` stays registered for [GenericListScreen]'s
  /// grid column only, where no click-dispatch happens at all (see that
  /// handler's own doc comment).
  Widget _buildButtonField(FieldConfig field) {
    final label = field.options['label'] as String? ?? 'Run script';
    final id = widget.isEditing ? widget.existing!['id'] as int : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ElevatedButton(
        // Disabled until the record actually exists -- a button_clicked
        // script's ambient `record` needs a real row id to bind to, same
        // reasoning TableConfig.openRowDetail's own doc comment gives for
        // why the reverse-relation panel is Add-flow-only unavailable too.
        onPressed: id == null
            ? null
            : () => EventDispatchService().dispatchAndApplyEffects(
                context,
                tableName: widget.config.tableName,
                eventType: 'button_clicked',
                fieldName: field.column,
                recordId: id,
              ),
        child: Text(label),
      ),
    );
  }

  static const _imagePreviewSize = 160.0;

  /// `image` -- see claude/essentials-v2-image-field-ui-design.md.
  /// Special-cased the same way `_buildButtonField` is, before the generic
  /// [FieldFormatHandler] dispatch: building the relative storage key needs
  /// a table name and record id, which that shared interface has no way to
  /// pass. [ImageFormatHandler.buildFormField] is unreachable dead code.
  Widget _buildImageField(FieldConfig field) {
    final controller = _controllers[field.column]!;
    final value = controller.text;
    // Same "disabled until the record actually exists" gate as
    // _buildButtonField -- the relative key needs a real record id, and
    // there isn't one on Add. See the UI design doc's "record doesn't
    // exist yet" section for the alternative considered (pre-generating
    // the id) and why it wasn't chosen.
    final id = widget.isEditing ? widget.existing!['id'] as int : null;
    final capturing = _capturingImage[field.column] ?? false;

    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (value.isNotEmpty) ...[_buildImagePreview(value), const SizedBox(height: 8)],
        _buildImageActionsRow(field, id: id, capturing: capturing, value: value),
      ],
    );

    // Windows drag-and-drop target -- build order step 5. No Android
    // counterpart (touch devices don't have an OS-level file-drag
    // gesture); Android's two entry points are the Camera/Choose Photo
    // buttons in _buildImageActionsRow instead. Wraps the whole field
    // (label included), same "drop anywhere in the field's area, not just
    // a small target box" ergonomics a real file-drop affordance wants.
    //
    // **Real bug, found live (Mike's own real-device pass, not
    // theorized): a `DropTarget` with no resting-state visual cue is
    // functionally invisible.** The original version only drew a border
    // while `hovering` was already true -- which means a user has to
    // already be mid-drag over the exact right spot before getting any
    // sign a drop zone exists at all. Reads as "there is no drag and
    // drop," not "there's a drop zone I haven't found yet." Fixed with a
    // permanently visible outlined hint box (below), not just a
    // hover-triggered one -- discoverability, not just correctness.
    if (Platform.isWindows) {
      final hovering = _imageDragHovering[field.column] ?? false;
      final enabled = id != null && !capturing;
      content = DropTarget(
        enable: enabled,
        onDragEntered: (_) => setState(() => _imageDragHovering[field.column] = true),
        onDragExited: (_) => setState(() => _imageDragHovering[field.column] = false),
        onDragDone: (details) => _handleImageDrop(field, id: id, details: details),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            content,
            const SizedBox(height: 8),
            _buildImageDropHint(hovering: hovering, enabled: enabled),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: field.label,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
        child: content,
      ),
    );
  }

  /// Permanently visible (not just while `hovering`) outlined hint box --
  /// the actual fix for the discoverability bug described on
  /// [_buildImageField]'s own doc comment. Brightens (thicker border,
  /// tinted background) while a drag is actively over the field;
  /// otherwise stays a quiet, low-contrast outline so it doesn't compete
  /// visually with the preview/buttons above it, but is still
  /// unmistakably "a place you can drop something." Plain solid border,
  /// not a dashed one -- Flutter's `Border` has no built-in dashed style
  /// without a custom painter or an extra package, not worth it here.
  Widget _buildImageDropHint({required bool hovering, required bool enabled}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        color: hovering ? scheme.primaryContainer : null,
        border: Border.fromBorderSide(
          BorderSide(
            color: !enabled
                ? scheme.outlineVariant
                : hovering
                ? scheme.primary
                : scheme.outline,
            width: hovering ? 2 : 1,
            style: BorderStyle.solid,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.file_download_outlined,
            size: 18,
            color: enabled ? scheme.onSurfaceVariant : scheme.outlineVariant,
          ),
          const SizedBox(width: 8),
          Text(
            enabled ? 'Drag and drop an image here' : 'Save the record first to enable drag and drop',
            style: TextStyle(color: enabled ? scheme.onSurfaceVariant : scheme.outlineVariant),
          ),
        ],
      ),
    );
  }

  /// Resolves a stored relative key (`{table}/{record_id}/{field_name}/
  /// {filename}`) to a local [File] via [FileSyncService.fetch] --
  /// deliberately parsed straight out of the key itself, not rebuilt from
  /// `widget.config.tableName`/the current record's id. **Real bug, caught
  /// before it shipped:** a "Copy" flow seeds this field's controller from
  /// `copyFrom` before any new record id exists (`widget.existing` is
  /// `null` in that state -- see [GenericFormScreen.copyFrom]'s own doc
  /// comment), so reconstructing the key from `widget.existing!['id']`
  /// would throw on a copied row with an image value. Parsing the four
  /// segments already present in the stored value itself needs no id at
  /// all, and correctly resolves to the *original* record's file --
  /// exactly right, since a fresh copy doesn't yet have its own image
  /// bytes, only a value pointing at where the source record's still live.
  Future<File?> _resolveImageFile(String relativeKey) {
    final segments = relativeKey.split('/');
    if (segments.length != 4) return Future.value(null);
    final [table, recordId, fieldName, filename] = segments;
    return _fileSync.fetch(table: table, recordId: recordId, fieldName: fieldName, filename: filename);
  }

  Widget _buildImagePreview(String value) {
    final future = _imagePreviewFutures.putIfAbsent(value, () => _resolveImageFile(value));
    return FutureBuilder<File?>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            width: _imagePreviewSize,
            height: _imagePreviewSize,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final file = snapshot.data;
        if (file == null) {
          // Genuinely expected, not an error -- see FileSyncService.fetch's
          // own doc comment ("404 is an ordinary, expected outcome").
          return SizedBox(
            width: _imagePreviewSize,
            height: _imagePreviewSize,
            child: Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: const Icon(Icons.broken_image_outlined),
            ),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.file(file, width: _imagePreviewSize, height: _imagePreviewSize, fit: BoxFit.cover),
        );
      },
    );
  }

  /// Android gets Camera + Choose Photo via `image_picker`; Windows gets
  /// Browse via the already-used `file_picker` (the drag-and-drop target
  /// itself is wired in [_buildImageField], not here) -- see the UI design
  /// doc's platform split. No third, generic fallback for any other
  /// platform, same "this app only targets Windows desktop and Android"
  /// posture `DatabaseHelper` already enforces elsewhere.
  Widget _buildImageActionsRow(
    FieldConfig field, {
    required int? id,
    required bool capturing,
    required String value,
  }) {
    final enabled = id != null && !capturing;
    final hasValue = value.isNotEmpty;
    final spinner = const SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
    return Tooltip(
      message: id == null ? 'Save the record first, then add an image.' : '',
      child: Wrap(
        spacing: 8,
        children: [
          if (Platform.isAndroid) ...[
            OutlinedButton.icon(
              onPressed: enabled ? () => _captureOrPickImage(field, fromCamera: true) : null,
              icon: capturing ? spinner : const Icon(Icons.camera_alt_outlined),
              label: const Text('Camera'),
            ),
            OutlinedButton.icon(
              onPressed: enabled ? () => _captureOrPickImage(field, fromCamera: false) : null,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Choose photo'),
            ),
          ],
          if (Platform.isWindows)
            OutlinedButton.icon(
              onPressed: enabled ? () => _browseForImage(field, id: id) : null,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('Browse...'),
            ),
          // Save-to-device -- deliberately available whenever there's a
          // value, not gated on `enabled`/`id != null` the way every other
          // button here is. Real reasoning, not an oversight: it's a pure
          // read (never touches the record), and it exists specifically
          // as the safety net before an irreversible Remove/record-delete
          // (see FileSyncService.delete's own doc comment) -- gating it
          // behind the same "record must be saved" rule the *write*
          // actions need would be backwards for a button whose whole
          // purpose is "get a copy out before it's gone."
          if (hasValue)
            OutlinedButton.icon(
              onPressed: capturing ? null : () => _saveImageToDevice(field, value),
              icon: const Icon(Icons.download_outlined),
              label: const Text('Save...'),
            ),
          if (hasValue)
            OutlinedButton.icon(
              onPressed: enabled ? () => _clearImageField(field) : null,
              icon: const Icon(Icons.close),
              label: const Text('Remove'),
            ),
        ],
      ),
    );
  }

  Future<void> _captureOrPickImage(FieldConfig field, {required bool fromCamera}) async {
    final id = widget.existing!['id'] as int;
    setState(() => _capturingImage[field.column] = true);
    try {
      if (fromCamera) {
        final status = await Permission.camera.request();
        if (!status.isGranted) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Camera permission is needed to take a photo.')));
          return;
        }
      }
      final picked = await ImagePicker().pickImage(
        source: fromCamera ? ImageSource.camera : ImageSource.gallery,
      );
      if (picked == null) return; // user cancelled
      await _ingestPickedImage(field, id: id, sourcePath: picked.path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not add image: $e')));
    } finally {
      if (mounted) setState(() => _capturingImage[field.column] = false);
    }
  }

  /// "Save..." -- lets the user get a copy of the image out to the
  /// device's own regular storage before an irreversible Remove or record
  /// delete (see [FileSyncService.delete]'s own doc comment for why
  /// those are now real, permanent deletes, not a tombstone). Both
  /// platforms, via the same `file_picker` `saveFile` call
  /// `GenericListScreen._exportCsv` already uses and has already proven
  /// working cross-platform -- no new package, no new pattern.
  Future<void> _saveImageToDevice(FieldConfig field, String value) async {
    final file = await _resolveImageFile(value);
    if (file == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Couldn't reach the image to save it.")));
      return;
    }
    final filename = value.split('/').last;
    final bytes = await file.readAsBytes();
    final savedPath = await FilePicker.saveFile(
      dialogTitle: 'Save ${field.label}',
      fileName: filename,
      bytes: bytes,
    );
    if (savedPath == null || !mounted) return; // user cancelled
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved to $savedPath')));
  }

  /// Windows "Browse..." -- the `file_picker` counterpart to Android's
  /// Choose Photo, using the exact same package `LinkFileFormatHandler`
  /// already depends on for its own file-browse button (no new package
  /// needed for this entry point, only for the drag-and-drop one).
  Future<void> _browseForImage(FieldConfig field, {required int id}) async {
    setState(() => _capturingImage[field.column] = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [for (final ext in _recognizedImageExtensions) ext.substring(1)],
      );
      final path = result?.files.single.path;
      if (path == null) return; // user cancelled
      await _ingestValidatedImage(field, id: id, sourcePath: path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not add image: $e')));
    } finally {
      if (mounted) setState(() => _capturingImage[field.column] = false);
    }
  }

  /// Windows drag-and-drop -- see [_buildImageField]'s `DropTarget`. Only
  /// the first dropped file is used (this is a single-image field, not a
  /// gallery -- see the storage design doc); anything past it is silently
  /// ignored rather than rejected, same "just do the reasonable thing"
  /// choice as taking the first of a multi-select elsewhere in this app.
  Future<void> _handleImageDrop(FieldConfig field, {required int? id, required DropDoneDetails details}) async {
    if (id == null || details.files.isEmpty) return;
    await _ingestValidatedImage(field, id: id, sourcePath: details.files.first.path);
  }

  /// Shared by both Windows entry points -- rejects (with a SnackBar, not
  /// a silent no-op) anything outside [_recognizedImageExtensions] before
  /// ever touching the filesystem, then hands off to [_ingestPickedImage].
  /// Android's two entry points don't need this: `image_picker`'s camera
  /// always produces a real photo, and its gallery picker can be scoped to
  /// images only at the OS level, so there's no equivalent "arbitrary file
  /// the user dragged in" case to validate there.
  Future<void> _ingestValidatedImage(FieldConfig field, {required int id, required String sourcePath}) async {
    if (!_recognizedImageExtensions.contains(extension(sourcePath).toLowerCase())) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${extension(sourcePath)}" isn\'t a recognized image type.')),
      );
      return;
    }
    await _ingestPickedImage(field, id: id, sourcePath: sourcePath);
  }

  /// The local-write-then-upload step -- see the UI design doc's "What
  /// happens on capture/drop" section. Single image per field: any
  /// existing file(s) already in that field's directory are deleted first,
  /// not accumulated, so recapturing/replacing never leaves an orphan on
  /// *this* device (the hub/other-devices' copy of the old file is a
  /// separate, already-flagged open item, unchanged by this).
  Future<void> _ingestPickedImage(FieldConfig field, {required int id, required String sourcePath}) async {
    final table = widget.config.tableName;
    final recordId = id.toString();
    final sourceExt = sourcePath.contains('.') ? sourcePath.split('.').last.toLowerCase() : 'jpg';
    final filename = 'image.$sourceExt';

    final localPath = await _fileSync.localPathFor(
      table: table,
      recordId: recordId,
      fieldName: field.column,
      filename: filename,
    );
    final dir = Directory(dirname(localPath));
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is File) await entity.delete();
      }
    } else {
      await dir.create(recursive: true);
    }
    await File(sourcePath).copy(localPath);

    // Flutter's own Image widget cache is keyed by file path, not content
    // -- recapturing to the same fixed filename (the common case: the
    // camera always produces .jpg) would silently keep showing the old
    // bytes without this. Found while building this, not theorized.
    await FileImage(File(localPath)).evict();

    final relativeKey = '$table/$recordId/${field.column}/$filename';
    _imagePreviewFutures.remove(relativeKey);
    setState(() => _controllers[field.column]!.text = relativeKey);

    // Fire-and-forget -- this device's own preview already has the bytes
    // (the local write above), so nothing about this device's UI depends
    // on the upload succeeding. See FileSyncService.upload's own doc
    // comment for the accepted no-retry-in-v1 gap this leaves.
    unawaited(
      _fileSync.upload(
        table: table,
        recordId: recordId,
        fieldName: field.column,
        filename: filename,
        localFile: File(localPath),
      ),
    );
  }

  /// Now actually deletes the file (local + hub), not just the field's
  /// value -- the resolution to the storage design doc's originally-open
  /// "delete behavior" item. See [FileSyncService.delete]'s own doc
  /// comment for the two-caller reasoning and the fire-and-forget hub
  /// side.
  void _clearImageField(FieldConfig field) {
    final value = _controllers[field.column]!.text;
    if (value.isNotEmpty) {
      _imagePreviewFutures.remove(value);
      unawaited(_fileSync.deleteByRelativeKey(value));
    }
    setState(() => _controllers[field.column]!.text = '');
  }

  Widget _buildField(FieldConfig field) {
    if (field.format == 'button') return _buildButtonField(field);
    if (field.format == 'image') return _buildImageField(field);

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
      //
      // **A stored value that doesn't match any configured option needs
      // its own ad-hoc item, not just an "isn't there" gap.**
      // `DropdownButtonFormField` asserts (debug builds only, same known
      // pitfall as the isLookup dropdown's own doc comment above) that
      // exactly one item matches its value unless the value is `null` --
      // found live, real-device verification: opening a record whose
      // Status held "blocked" (not one of the field's three configured
      // options) crashed on MIKE-12R's debug build with exactly that
      // assertion; CU's *release* build never showed it, since Dart strips
      // `assert()` there (same asymmetry the isLookup dropdown's own bug
      // once had). Every v2 format is a presentation hint over raw TEXT,
      // never a hard constraint (a deleted option, a stray CSV-imported
      // value), so the fix mirrors KanbanViewScreen's own "never hide the
      // record" posture for the identical scenario: an unmatched value
      // gets its own ad-hoc item, labeled with the literal stored value,
      // rather than silently disappearing from the dropdown (which would
      // also have silently blanked it out on the next save).
      final currentValue = _inlineSelectValues[field.column];
      final hasCurrentValue =
          currentValue == null || field.inlineOptions!.any((o) => o.key == currentValue);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: DropdownButtonFormField<String>(
          initialValue: currentValue,
          decoration: InputDecoration(labelText: field.label),
          items: [
            if (!field.required) const DropdownMenuItem<String>(child: Text('-')),
            for (final option in field.inlineOptions!)
              DropdownMenuItem<String>(value: option.key, child: Text(option.label)),
            if (!hasCurrentValue)
              DropdownMenuItem<String>(value: currentValue, child: Text('$currentValue (not a listed option)')),
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

    // The recognized Map Location field is exempt from autocomplete
    // regardless of its own stored options -- a real bug found live: a
    // plain text field defaults to autocomplete ON unless explicitly
    // unchecked, and _buildAutocompleteField deliberately hardcodes
    // maxLines: 1 (keyboard highlight-navigation needs a single-line
    // field, see that method's own doc comment). Map Location is meant to
    // hold a multi-line street/city/state/zip block -- the full value was
    // always saved correctly underneath, but this silently truncated it to
    // one visible line the moment autocomplete was left on, which it is
    // by default for any newly-added text field.
    if (field != _mapLocationField && field.isAutocompleteText) {
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
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.today_outlined),
                      tooltip: 'Set to today',
                      onPressed: () => _setFieldToNow(field),
                    ),
                    IconButton(
                      icon: const Icon(Icons.calendar_today_outlined),
                      tooltip: 'Pick a date',
                      onPressed: () => _pickDateForField(field),
                    ),
                  ],
                )
              : field.type == FieldType.dateTime
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.schedule_outlined),
                      tooltip: 'Set to now',
                      onPressed: () => _setFieldToNow(field),
                    ),
                    IconButton(
                      icon: const Icon(Icons.event_outlined),
                      tooltip: 'Pick a date and time',
                      onPressed: () => _pickDateTimeForField(field),
                    ),
                  ],
                )
              : null,
          // Unconstrained rather than the default fixed-width box -- the
          // date/dateTime cases above pack two IconButtons into this slot
          // (the new "Now" button alongside the existing picker icon),
          // which would otherwise get clipped to a single icon's width.
          suffixIconConstraints: (field.type == FieldType.date || field.type == FieldType.dateTime)
              ? const BoxConstraints()
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
