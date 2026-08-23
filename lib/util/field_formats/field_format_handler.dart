import 'package:flutter/material.dart';
import 'package:trina_grid/trina_grid.dart';

import '../../models/table_config.dart';

/// One implementation per Phase-2-and-later field [format] -- see
/// claude/essentials-v2-phase2-design.md's "Key decision" for the full
/// rationale. Phase 1's 6 formats (text/integer/real/boolean/date/
/// dateTime, plus `select`'s linked-lookup mode) are baked directly into
/// [GenericListScreen]/[GenericFormScreen]'s existing `FieldType`-based
/// branches (roughly 15-20 call sites across the two screens) --
/// extending that same pattern for Phase 2's ~9 new formats would
/// roughly triple the branch count in two files that are already 1780
/// and 470 lines. A handler is registered by [format] string in
/// [FieldFormatRegistry] and looked up once at the top of each screen's
/// existing per-field methods: "if there's a handler for this format,
/// delegate; otherwise fall through to the existing `FieldType` switch,"
/// not a parallel rewrite. Phase 1's 6 formats never get a handler
/// registered for them, so they keep their existing code paths
/// completely untouched -- no regression risk to code already verified
/// on real hardware.
///
/// Every v2 field is physically `TEXT` regardless of format
/// (`SchemaEditorService.addField`) -- a handler's job is presentation
/// and parsing/serializing that `TEXT`, never a different physical
/// column type.
abstract class FieldFormatHandler {
  /// Matches `field_definitions.format` / `FieldFormatChoice.value`.
  String get format;

  /// Grid column for this field. Width/type/renderer are entirely this
  /// handler's call -- [GenericListScreen] still layers a saved
  /// `ColumnSetting` (width/hide/frozen) on top afterward, exactly like
  /// every other branch in `_buildFieldColumn`, so don't set those here.
  TrinaColumn buildGridColumn(FieldConfig field);

  /// Raw stored/db value (from a loaded row) -> whatever this handler's
  /// own [buildGridColumn] column type expects as a cell value. The
  /// handler equivalent of `GenericListScreen._cellValueFor`'s per-format
  /// branches.
  Object? cellValueFor(FieldConfig field, Object? raw);

  /// Whatever TrinaGrid hands back on an inline edit -> the plain `TEXT`
  /// that gets written to the column. The handler equivalent of
  /// `GenericListScreen._onGridChanged`'s per-format branches.
  String? valueForSave(FieldConfig field, Object? gridValue);

  /// Form input widget. [controller] is the same plain
  /// `TextEditingController` [GenericFormScreen] already keeps for every
  /// non-boolean/non-lookup field (its `.text` is what gets read back on
  /// save, via the existing `FieldType.text` fallback every unrecognized
  /// format already gets) -- a handler customizes the surrounding
  /// decoration/actions around that same controller, it doesn't replace
  /// the underlying "one text controller per field" storage model. Most
  /// Phase 2 formats are `TEXT`-backed the same way `text`/link/color
  /// fields already are, so this fits without a parallel state-management
  /// path.
  Widget buildFormField(BuildContext context, FieldConfig field, TextEditingController controller);
}

/// Flat, built-once registry of every [FieldFormatHandler] -- deliberately
/// not a bigger refactor (see the interface doc comment above). A single
/// app-wide instance, populated in `main.dart` alongside the existing
/// theme/DB setup; [instance] starts empty so any code that runs before
/// `main()` populates it (tests, mainly) sees "no handler for anything"
/// rather than a null-reference failure.
class FieldFormatRegistry {
  FieldFormatRegistry(Iterable<FieldFormatHandler> handlers)
    : _byFormat = {for (final h in handlers) h.format: h};

  static FieldFormatRegistry instance = FieldFormatRegistry(const []);

  final Map<String, FieldFormatHandler> _byFormat;

  /// `null` for any format with no registered handler -- every Phase 1
  /// format, always, plus any future format not yet built. Callers treat
  /// `null` as "fall through to the existing type-based rendering."
  FieldFormatHandler? handlerFor(String? format) => format == null ? null : _byFormat[format];
}
