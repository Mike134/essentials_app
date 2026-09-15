import 'package:flutter/widgets.dart';

/// The [TextEditingValue] that results from inserting [insert] at [value]'s
/// current selection (replacing any selected range), with the new
/// selection collapsed immediately after the inserted text -- the same
/// "type a character at the cursor" behavior an IME performs, just
/// triggered manually rather than by the platform's own text input
/// channel.
///
/// Extracted as a small, pure, top-level function (rather than left inline
/// in `GenericFormScreen`) specifically so it's unit-testable without a
/// widget/database harness -- see `GenericFormScreen._handleFieldKeyEvent`'s
/// own doc comment for why a Dart-side workaround like this exists at all:
/// a real, confirmed Windows-desktop bug where Flutter's native Enter-key/
/// newline handling in a multiline `TextField` silently never inserts the
/// character.
///
/// A negative `selection.start`/`.end` (no real selection yet -- e.g. a
/// freshly-focused field whose `TextEditingController` was built with a
/// plain string, not a `TextEditingValue` carrying an explicit selection)
/// is treated as "the very end of the text", the same place a cursor
/// lands by default when a field first receives focus.
TextEditingValue insertAtSelection(TextEditingValue value, String insert) {
  final text = value.text;
  final selection = value.selection;
  final start = selection.start < 0 ? text.length : selection.start;
  final end = selection.end < 0 ? text.length : selection.end;
  return TextEditingValue(
    text: text.replaceRange(start, end, insert),
    selection: TextSelection.collapsed(offset: start + insert.length),
  );
}
