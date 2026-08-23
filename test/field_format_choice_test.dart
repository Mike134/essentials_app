// Proves FieldFormatChoice.resolve -- Essentials v2 Phase 2 build order
// steps 3 (see claude/essentials-v2-phase2-design.md's `url` entry) and 4
// (`inlineSelect` -- the "Inline select" entry). Both `url`/`text` and
// `inlineSelect`/`select` are pairs that deliberately share a stored
// `value`, so .fromValue alone can never tell either pair apart --
// .resolve is the fix, checking options.isLink/options.mode too. Pure
// Dart, no DatabaseHelper involved -- run with
// `flutter test test/field_format_choice_test.dart`.
import 'package:essentials_app/util/field_format_choice.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FieldFormatChoice.fromValue', () {
    test('resolves a plain format string to its matching choice', () {
      expect(FieldFormatChoice.fromValue('integer'), FieldFormatChoice.integer);
      expect(FieldFormatChoice.fromValue('currency'), FieldFormatChoice.currency);
      expect(FieldFormatChoice.fromValue('link_file'), FieldFormatChoice.linkFile);
    });

    test('cannot distinguish a url field from a plain text field -- always returns text', () {
      // Documents the exact limitation FieldFormatChoice.url's doc
      // comment describes -- both share value 'text', and firstWhere
      // always returns whichever is declared first (text).
      expect(FieldFormatChoice.fromValue('text'), FieldFormatChoice.text);
    });

    test('falls back to text for a genuinely unrecognized format', () {
      // Not 'barcode' -- that was a real unrecognized-format example when
      // this test was first written, and became a false negative for
      // this exact assertion the moment step 7 gave it a real handler.
      expect(FieldFormatChoice.fromValue('never_a_real_format'), FieldFormatChoice.text);
    });
  });

  group('FieldFormatChoice.resolve', () {
    test('resolves format text + options.isLink true to url', () {
      expect(FieldFormatChoice.resolve('text', {'isLink': true}), FieldFormatChoice.url);
    });

    test('resolves format text + no isLink option to plain text', () {
      expect(FieldFormatChoice.resolve('text', const {}), FieldFormatChoice.text);
      expect(FieldFormatChoice.resolve('text', {'isColor': true}), FieldFormatChoice.text);
    });

    test('isLink on a non-text format is ignored -- resolves normally', () {
      // isLink only means "url" in combination with the plain text
      // format; a currency field with a stray isLink key (shouldn't
      // happen in practice) stays currency.
      expect(FieldFormatChoice.resolve('currency', {'isLink': true}), FieldFormatChoice.currency);
    });

    test('resolves format select + options.mode inline to inlineSelect', () {
      expect(
        FieldFormatChoice.resolve('select', {'mode': 'inline'}),
        FieldFormatChoice.inlineSelect,
      );
    });

    test('resolves format select + options.mode linked (or unset) to plain select', () {
      expect(FieldFormatChoice.resolve('select', {'mode': 'linked'}), FieldFormatChoice.select);
      expect(FieldFormatChoice.resolve('select', const {}), FieldFormatChoice.select);
    });

    test('mode inline on a non-select format is ignored -- resolves normally', () {
      expect(FieldFormatChoice.resolve('text', {'mode': 'inline'}), FieldFormatChoice.text);
    });

    test('matches fromValue for every other format', () {
      for (final choice in FieldFormatChoice.values) {
        if (choice == FieldFormatChoice.url || choice == FieldFormatChoice.inlineSelect) continue;
        expect(FieldFormatChoice.resolve(choice.value, const {}), choice);
      }
    });
  });

  test('url shares its stored format string with text, by design', () {
    expect(FieldFormatChoice.url.value, FieldFormatChoice.text.value);
  });

  test('inlineSelect shares its stored format string with select, by design', () {
    expect(FieldFormatChoice.inlineSelect.value, FieldFormatChoice.select.value);
  });
}
