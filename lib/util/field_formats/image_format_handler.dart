import 'package:flutter/material.dart';
import 'package:trina_grid/trina_grid.dart';

import '../../models/table_config.dart';
import 'field_format_handler.dart';

/// `image` -- build order step 3 of the image field design (see
/// claude/essentials-v2-image-field-ui-design.md). Storage: `TEXT`
/// holding a relative key (`{table}/{record_id}/{field_name}/{filename}`),
/// resolved to a local file path per-device -- see
/// claude/essentials-v2-image-field-design.md. `options`: always `{}`,
/// nothing configurable in v1 (this is a single-image field, not a
/// gallery).
///
/// **The real capture/drag-drop/preview widget lives in
/// `GenericFormScreen._buildImageField`, not [buildFormField] below** --
/// same reasoning as `ButtonFormatHandler`: building the relative storage
/// key needs a table name and record id, which the shared
/// [FieldFormatHandler.buildFormField] interface has no way to pass (no
/// other format needs anything beyond its own field's value).
/// [buildFormField] here is dead code, kept only because the interface
/// requires an implementation -- `GenericFormScreen._buildField`
/// special-cases `field.format == 'image'` before the generic handler
/// dispatch ever reaches it.
///
/// **Grid column deliberately blank, by design, not deferred.** Unlike
/// `button` (whose grid affordance was left open for a future decision),
/// this field is Form-view-only per the storage design doc's explicit
/// "Preview" scope -- no grid/list thumbnail column exists in this
/// design at all. [buildGridColumn] is a plain, always-blank read-only
/// column, same shape `ButtonFormatHandler.buildGridColumn` already
/// established, purely so this format has *some* grid column (every
/// registered format needs one) without implying a thumbnail feature
/// that isn't part of the design.
class ImageFormatHandler implements FieldFormatHandler {
  const ImageFormatHandler();

  @override
  String get format => 'image';

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
    // Unreachable in practice -- see this class's own doc comment. Kept
    // functional (not a throw) purely as a safe fallback in case some
    // future caller other than GenericFormScreen ever queries the
    // registry directly for an `image` field.
    return TextFormField(controller: controller, enabled: false, decoration: InputDecoration(labelText: field.label));
  }
}
