// Proves insertAtSelection -- the pure helper GenericFormScreen uses to
// manually insert a newline on Enter, working around a real, confirmed
// Windows-desktop bug where Flutter's native Enter-key/newline handling in
// a multiline TextField silently never inserts the character at all (see
// generic_form_screen.dart's `_handleFieldKeyEvent` for the full write-up).
// Pure Dart/Flutter widgets, no database -- run with
// `flutter test test/text_selection_insert_test.dart`.
import 'package:essentials_app/util/text_selection_insert.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('inserts at a collapsed cursor mid-string', () {
    final result = insertAtSelection(
      const TextEditingValue(text: '1. test2. another', selection: TextSelection.collapsed(offset: 7)),
      '\n',
    );
    expect(result.text, '1. test\n2. another');
    expect(result.selection, const TextSelection.collapsed(offset: 8));
  });

  test('inserts at the very end when the cursor is at the end', () {
    final result = insertAtSelection(
      const TextEditingValue(text: '1. test', selection: TextSelection.collapsed(offset: 7)),
      '\n',
    );
    expect(result.text, '1. test\n');
    expect(result.selection, const TextSelection.collapsed(offset: 8));
  });

  test('replaces a real (non-collapsed) selection, not just inserting alongside it', () {
    final result = insertAtSelection(
      const TextEditingValue(text: '1. test', selection: TextSelection(baseOffset: 3, extentOffset: 7)),
      '\n',
    );
    expect(result.text, '1. \n');
    expect(result.selection, const TextSelection.collapsed(offset: 4));
  });

  test('a negative (no real) selection is treated as the end of the text', () {
    // What a TextEditingController built from a plain string (no explicit
    // TextEditingValue) starts with before it's ever been focused --
    // exactly GenericFormScreen's own `TextEditingController(text: ...)`
    // construction in initState.
    final result = insertAtSelection(const TextEditingValue(text: 'existing'), '\n');
    expect(result.text, 'existing\n');
    expect(result.selection, const TextSelection.collapsed(offset: 9));
  });

  test('an empty starting value', () {
    final result = insertAtSelection(const TextEditingValue(), '\n');
    expect(result.text, '\n');
    expect(result.selection, const TextSelection.collapsed(offset: 1));
  });
}
