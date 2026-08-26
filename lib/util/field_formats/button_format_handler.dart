import 'package:flutter/material.dart';
import 'package:trina_grid/trina_grid.dart';

import '../../models/table_config.dart';
import 'field_format_handler.dart';

/// `button` -- Essentials v2 Phase 5 build order step 1 (see
/// claude/essentials-v2-phase5-design.md's "Data model"). Needed so a
/// table can have a "Button clicked" UI event to bind a script to, per
/// the design doc's event list. Storage: `TEXT`, physically present but
/// never written -- same "keep a real column so changing a field's
/// format is metadata-only" reasoning as `formula` (see
/// `FormulaService`'s own doc comment for the fuller argument). `options`:
/// `{label: String}`, default `'Run script'`.
///
/// **The real, clickable form button now lives in `GenericFormScreen
/// ._buildButtonField`, not [buildFormField] below** -- see that
/// method's own doc comment for why: running a real `button_clicked`
/// script needs a table name and record id, which the shared
/// [FieldFormatHandler.buildFormField] interface has no way to pass (no
/// other Phase 2 format needs anything beyond its own field's value).
/// [buildFormField] here is dead code, kept only because the interface
/// requires an implementation -- `GenericFormScreen._buildField`
/// special-cases `field.format == 'button'` before the generic handler
/// dispatch ever reaches it.
///
/// **Grid affordance deliberately deferred, per the design doc's own
/// "TBD during build" note.** [buildGridColumn] renders a plain,
/// always-blank read-only column for now -- consistent with `barcode`'s
/// precedent (its scan affordance is form-only too, confirmed as the
/// right call by Mike during Phase 2's real-device pass) rather than
/// guessing at a grid button's interaction model before any script can
/// actually run from it. This handler stays registered for that grid
/// column alone.
class ButtonFormatHandler implements FieldFormatHandler {
  const ButtonFormatHandler();

  @override
  String get format => 'button';

  String _labelFor(FieldConfig field) {
    final raw = field.options['label'];
    if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    return 'Run script';
  }

  @override
  TrinaColumn buildGridColumn(FieldConfig field) {
    return TrinaColumn(
      title: field.label,
      field: field.column,
      type: TrinaColumnType.text(),
      readOnly: true,
      renderer: (rendererContext) => const SizedBox.shrink(),
    );
  }

  @override
  Object? cellValueFor(FieldConfig field, Object? raw) => '';

  @override
  String? valueForSave(FieldConfig field, Object? gridValue) => null;

  @override
  Widget buildFormField(BuildContext context, FieldConfig field, TextEditingController controller) {
    // Unreachable in practice -- see this class's own doc comment.
    // Kept functional (not a throw) purely as a safe fallback in case
    // some future caller other than GenericFormScreen ever queries the
    // registry directly for a `button` field.
    return ElevatedButton(onPressed: null, child: Text(_labelFor(field)));
  }
}
