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
/// **This step only builds the field format itself -- no script actually
/// runs yet.** `flutter_js`/the script API/event binding are build order
/// steps 2-5; wiring a real script to this button's tap is step 4's job.
/// Until then the button renders disabled with an explanatory tooltip,
/// same "don't ship a dead-looking live control" instinct as
/// `ManageFieldsScreen`'s "Permanently delete" placeholder before stage-2
/// delete existed.
///
/// **Grid affordance deliberately deferred, per the design doc's own
/// "TBD during build" note.** [buildGridColumn] renders a plain,
/// always-blank read-only column for now -- consistent with `barcode`'s
/// precedent (its scan affordance is form-only too, confirmed as the
/// right call by Mike during Phase 2's real-device pass) rather than
/// guessing at a grid button's interaction model before any script can
/// actually run from it.
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
    return InputDecorator(
      decoration: InputDecoration(labelText: field.label, border: InputBorder.none, contentPadding: EdgeInsets.zero),
      child: Tooltip(
        message: 'Scripts aren\'t wired up yet (Essentials v2 Phase 5 build in progress).',
        child: ElevatedButton(onPressed: null, child: Text(_labelFor(field))),
      ),
    );
  }
}
