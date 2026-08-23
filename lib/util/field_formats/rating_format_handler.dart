import 'package:flutter/material.dart';
import 'package:trina_grid/trina_grid.dart';

import '../../models/table_config.dart';
import 'field_format_handler.dart';

/// `rating` -- Essentials v2 Phase 2 build order step 5 (see
/// claude/essentials-v2-phase2-design.md's `rating` entry). Storage:
/// `TEXT` holding a plain integer string (`"4"`). `options`: `{max: int
/// (default 5)}`.
///
/// **Grid interactivity, not just display** -- the design doc left this
/// open ("read-only star rendering... or a plain '4/5' text cell, low
/// risk either way"). Chosen: tappable stars directly in the grid cell,
/// same `readOnly: true` column + a renderer that calls
/// `changeCellValue(..., force: true)` pattern this app already
/// established twice (the boolean checkbox column, the color-field
/// swatch) -- not a new interaction model, reusing a proven one. Tapping
/// the currently-set star again clears the rating (common rating-widget
/// convention: the only way to get back to "no rating" once one is set).
///
/// The **form** side needs a small [FormField]-based wrapper (not a bare
/// `TextFormField` the way `currency`/`link_file` get away with) since
/// this isn't text input at all -- but unlike `percentage`'s wrapper
/// (which needs bidirectional controller syncing because displayed and
/// stored numbers genuinely differ), rating's displayed and stored
/// numbers are the same integer, so a plain `FormField<int>` that mirrors
/// its own state into the shared [TextEditingController] on every tap is
/// enough -- no external-change listener needed (no current caller writes
/// to a rating field's controller from outside this widget, unlike a
/// `computePreview`-fed field).
class RatingFormatHandler implements FieldFormatHandler {
  const RatingFormatHandler();

  @override
  String get format => 'rating';

  int _maxFor(FieldConfig field) {
    final raw = field.options['max'];
    if (raw is int) return raw;
    return int.tryParse(raw?.toString() ?? '') ?? 5;
  }

  static const double _starSize = 18;

  @override
  TrinaColumn buildGridColumn(FieldConfig field) {
    final max = _maxFor(field);
    return TrinaColumn(
      title: field.label,
      field: field.column,
      type: TrinaColumnType.number(),
      // Never enters TrinaGrid's own text/number editor -- the star row
      // below *is* the editor, same "readOnly so TrinaGrid's own editor
      // shouldn't open, not so this cell can never change" reasoning as
      // the boolean checkbox column.
      readOnly: true,
      width: max * (_starSize + 4) + 24,
      renderer: (rendererContext) {
        if (rendererContext.row.type.isGroup) return const SizedBox.shrink();
        final value = rendererContext.cell.value as int?;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 1; i <= max; i++)
              GestureDetector(
                onTap: () {
                  final next = value == i ? null : i;
                  rendererContext.stateManager.changeCellValue(rendererContext.cell, next, force: true);
                },
                child: Icon(
                  value != null && i <= value ? Icons.star : Icons.star_border,
                  size: _starSize,
                  color: Colors.amber,
                ),
              ),
          ],
        );
      },
    );
  }

  @override
  Object? cellValueFor(FieldConfig field, Object? raw) {
    if (raw == null) return null;
    return int.tryParse(raw.toString());
  }

  @override
  String? valueForSave(FieldConfig field, Object? gridValue) {
    // Already a real int (or null) -- this handler's own grid renderer is
    // the only thing that ever calls changeCellValue for this column,
    // and it always passes an int or null, never a string TrinaGrid's
    // text editor would hand back (that editor never opens -- see
    // buildGridColumn's readOnly reasoning).
    return gridValue?.toString();
  }

  @override
  Widget buildFormField(BuildContext context, FieldConfig field, TextEditingController controller) {
    final max = _maxFor(field);
    return FormField<int>(
      initialValue: int.tryParse(controller.text.trim()),
      validator: field.required
          ? (value) => value == null ? '${field.label} is required' : null
          : null,
      builder: (state) {
        final value = state.value;
        return InputDecorator(
          decoration: InputDecoration(
            labelText: field.label,
            errorText: state.errorText,
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 1; i <= max; i++)
                IconButton(
                  icon: Icon(
                    value != null && i <= value ? Icons.star : Icons.star_border,
                    color: Colors.amber,
                  ),
                  onPressed: () {
                    final next = value == i ? null : i;
                    controller.text = next?.toString() ?? '';
                    state.didChange(next);
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}
