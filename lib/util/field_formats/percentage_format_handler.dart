import 'package:flutter/material.dart';
import 'package:trina_grid/trina_grid.dart';

import '../../models/table_config.dart';
import 'field_format_handler.dart';

/// `percentage` -- Essentials v2 Phase 2 build order step 2 (see
/// claude/essentials-v2-phase2-design.md's `percentage` entry). Storage:
/// `TEXT` holding the raw fraction as a decimal string (`"0.15"` for
/// 15%), **not** the display integer -- matches how a future `formula`/
/// `rollup` field would want to read it (no hidden ×100/÷100 step
/// depending on which format reads it), and matches trina_grid's own
/// `TrinaColumnType.percentage(decimalInput: false)` convention (its
/// default), which the grid side uses directly. `options`: `{decimals:
/// int (default 0)}`.
///
/// **This is deliberately the one Phase 2 format so far where the
/// displayed text and the stored text are not the same number** -- the
/// grid side gets this for free from `TrinaColumnType.percentage` (it
/// already does the ×100/÷100 conversion internally, confirmed by reading
/// its source: `applyFormat` multiplies by 100 for display,
/// `toNumber` -- called by TrinaGrid's own `castValueByColumnType` on
/// every edit -- divides by 100 going back into storage), so
/// [cellValueFor]/[valueForSave] are plain pass-throughs, same shape as
/// `currency`. The **form** side has no such built-in and needs its own
/// small wrapper widget ([_PercentageFormField]) that keeps a *second*,
/// display-only `TextEditingController` (showing `"15"`) in sync with the
/// shared storage controller [buildFormField] receives (holding
/// `"0.15"`) -- every other Phase 1/2 format's form field binds directly
/// to the shared controller and lets [GenericFormScreen]'s generic
/// `_currentValues()` read it as-is; this is the one exception.
class PercentageFormatHandler implements FieldFormatHandler {
  const PercentageFormatHandler();

  @override
  String get format => 'percentage';

  int decimalsFor(FieldConfig field) {
    final raw = field.options['decimals'];
    if (raw is int) return raw;
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  @override
  TrinaColumn buildGridColumn(FieldConfig field) {
    return TrinaColumn(
      title: field.label,
      field: field.column,
      type: TrinaColumnType.percentage(decimalDigits: decimalsFor(field)),
      width: 110,
      textAlign: TrinaColumnTextAlign.right,
    );
  }

  @override
  Object? cellValueFor(FieldConfig field, Object? raw) => raw;

  @override
  String? valueForSave(FieldConfig field, Object? gridValue) {
    // Already the raw decimal fraction by the time this runs -- TrinaGrid
    // converts percentage-displayed input back to storage form itself
    // (toNumber, called by castValueByColumnType) before onChanged ever
    // fires, same as currency's own valueForSave.
    if (gridValue == null) return null;
    if (gridValue is num) return gridValue.toString();
    final text = gridValue.toString().trim();
    return text.isEmpty ? null : text;
  }

  @override
  Widget buildFormField(BuildContext context, FieldConfig field, TextEditingController controller) {
    return _PercentageFormField(
      field: field,
      storageController: controller,
      decimals: decimalsFor(field),
    );
  }
}

class _PercentageFormField extends StatefulWidget {
  const _PercentageFormField({
    required this.field,
    required this.storageController,
    required this.decimals,
  });

  final FieldConfig field;

  /// The shared controller [GenericFormScreen] reads on save -- always
  /// holds the true stored decimal fraction (`"0.15"`), never the
  /// displayed percentage. This widget writes to it, it never reads a
  /// user's typed input from it directly.
  final TextEditingController storageController;
  final int decimals;

  @override
  State<_PercentageFormField> createState() => _PercentageFormFieldState();
}

class _PercentageFormFieldState extends State<_PercentageFormField> {
  late final TextEditingController _displayController;

  /// Guards against the two controllers' listeners re-triggering each
  /// other -- [_onDisplayChanged] writes to [_PercentageFormField
  /// .storageController], which (being a real `TextEditingController`,
  /// listened to by [_onStorageChanged] for the "something external
  /// changed it" case) would otherwise immediately feed back into
  /// [_displayController], forming a loop.
  bool _updatingFromStorage = false;

  @override
  void initState() {
    super.initState();
    _displayController = TextEditingController(text: _displayTextFor(widget.storageController.text));
    _displayController.addListener(_onDisplayChanged);
    widget.storageController.addListener(_onStorageChanged);
  }

  @override
  void dispose() {
    _displayController.removeListener(_onDisplayChanged);
    widget.storageController.removeListener(_onStorageChanged);
    _displayController.dispose();
    super.dispose();
  }

  String _displayTextFor(String stored) {
    final value = double.tryParse(stored.trim());
    if (value == null) return '';
    final display = value * 100;
    return widget.decimals <= 0 ? display.round().toString() : display.toStringAsFixed(widget.decimals);
  }

  void _onDisplayChanged() {
    if (_updatingFromStorage) return;
    final text = _displayController.text.trim();
    if (text.isEmpty) {
      widget.storageController.text = '';
      return;
    }
    final display = double.tryParse(text);
    widget.storageController.text = display == null ? '' : (display / 100).toString();
  }

  /// Picks up a programmatic change to the shared storage controller made
  /// by something other than this widget's own [_onDisplayChanged] (no
  /// current caller does this for a `percentage` field -- no
  /// `computePreview` targets one yet -- but every other format's form
  /// field binds straight to the shared controller and would pick up such
  /// a change for free; this keeps that same guarantee here instead of
  /// silently only working for direct user typing).
  void _onStorageChanged() {
    final newDisplay = _displayTextFor(widget.storageController.text);
    if (newDisplay == _displayController.text) return;
    _updatingFromStorage = true;
    _displayController.text = newDisplay;
    _updatingFromStorage = false;
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: _displayController,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: widget.field.label, suffixText: '%'),
      validator: widget.field.required
          ? (value) =>
                (value == null || value.trim().isEmpty) ? '${widget.field.label} is required' : null
          : null,
    );
  }
}
