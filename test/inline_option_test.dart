// Proves InlineOption.parseList/toJson -- Essentials v2 Phase 2 build
// order step 4 (see claude/essentials-v2-phase2-design.md's "Inline
// select" entry). Shared parsing logic used by both SchemaRegistry and
// ManageFieldsScreen's field editor -- both must agree on the same
// lenient rules. Pure Dart, no DatabaseHelper involved -- run with
// `flutter test test/inline_option_test.dart`.
import 'package:essentials_app/models/table_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InlineOption.parseList', () {
    test('parses a well-formed list', () {
      final result = InlineOption.parseList([
        {'key': 'low', 'label': 'Low'},
        {'key': 'high', 'label': 'High'},
      ]);
      expect(result, hasLength(2));
      expect(result[0].key, 'low');
      expect(result[0].label, 'Low');
      expect(result[1].key, 'high');
      expect(result[1].label, 'High');
    });

    test('returns an empty list for null', () {
      expect(InlineOption.parseList(null), isEmpty);
    });

    test('returns an empty list for a non-list value', () {
      expect(InlineOption.parseList('not a list'), isEmpty);
      expect(InlineOption.parseList({'key': 'low', 'label': 'Low'}), isEmpty);
    });

    test('returns an empty list for an empty list', () {
      expect(InlineOption.parseList(<Object?>[]), isEmpty);
    });

    test('skips a malformed entry rather than throwing', () {
      final result = InlineOption.parseList([
        {'key': 'low', 'label': 'Low'},
        'not a map',
        {'key': 'missing_label'},
        {'label': 'missing_key'},
        {'key': 1, 'label': 'non-string key'},
        {'key': 'high', 'label': 'High'},
      ]);
      expect(result, hasLength(2));
      expect(result[0].key, 'low');
      expect(result[1].key, 'high');
    });
  });

  test('toJson round-trips through parseList', () {
    const option = InlineOption(key: 'med', label: 'Medium');
    final parsed = InlineOption.parseList([option.toJson()]);
    expect(parsed.single.key, 'med');
    expect(parsed.single.label, 'Medium');
  });
}
