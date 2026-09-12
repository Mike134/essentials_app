import 'package:essentials_app/util/display_aware_filters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trina_grid/trina_grid.dart';

TrinaColumn _statusColumn() {
  const idToText = {1: 'working', 2: 'closed', 3: 'none'};
  return TrinaColumn(
    title: 'Status',
    field: 'status',
    type: TrinaColumnType.select<int?>(
      idToText.keys.toList(),
      itemToString: (id) => idToText[id] ?? '',
    ),
  );
}

TrinaColumn _plainTextColumn() {
  return TrinaColumn(title: 'Notes', field: 'notes', type: TrinaColumnType.text());
}

void main() {
  group('resolveFilterDisplayText', () {
    test('resolves a select column\'s raw id to its display text', () {
      final column = _statusColumn();
      expect(resolveFilterDisplayText(column, '2'), 'closed');
      expect(resolveFilterDisplayText(column, '1'), 'working');
    });

    test('an unmatched raw value falls through unchanged, not an error', () {
      final column = _statusColumn();
      expect(resolveFilterDisplayText(column, '999'), '999');
    });

    test('a non-select column is left completely unaffected', () {
      final column = _plainTextColumn();
      expect(resolveFilterDisplayText(column, 'anything'), 'anything');
    });

    test('null passes through as null', () {
      expect(resolveFilterDisplayText(_statusColumn(), null), isNull);
    });
  });

  group('displayAwareFilterTypes', () {
    TrinaFilterType byTitle(String title) =>
        displayAwareFilterTypes.firstWhere((f) => f.title == title);

    test('covers every stock filter type by the same titles', () {
      final titles = displayAwareFilterTypes.map((f) => f.title).toSet();
      for (final original in FilterHelper.defaultFilters) {
        expect(titles, contains(original.title));
      }
      expect(displayAwareFilterTypes.length, FilterHelper.defaultFilters.length);
    });

    test('Regex compares against display text, not the raw id -- the real bug', () {
      final column = _statusColumn();
      final regex = byTitle(TrinaFilterTypeRegex.name);
      // "not equal to closed", written against the raw ids: '1' (working)
      // should pass, '2' (closed) should be excluded.
      const pattern = r'^(?!closed$).*$';
      expect(
        regex.compare(base: '1', search: pattern, column: column),
        isTrue,
        reason: 'working should NOT be excluded',
      );
      expect(
        regex.compare(base: '2', search: pattern, column: column),
        isFalse,
        reason: 'closed SHOULD be excluded',
      );
    });

    test('Equals matches the display text typed by the user, not the raw id', () {
      final column = _statusColumn();
      final equals = byTitle(TrinaFilterTypeEquals.name);
      expect(equals.compare(base: '2', search: 'closed', column: column), isTrue);
      expect(equals.compare(base: '1', search: 'closed', column: column), isFalse);
    });

    test('Contains still works normally for a plain text column (no-op resolution)', () {
      final column = _plainTextColumn();
      final contains = byTitle(TrinaFilterTypeContains.name);
      expect(contains.compare(base: 'hello world', search: 'world', column: column), isTrue);
      expect(contains.compare(base: 'hello world', search: 'xyz', column: column), isFalse);
    });
  });
}
