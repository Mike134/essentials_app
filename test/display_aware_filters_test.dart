import 'package:essentials_app/util/date_format.dart';
import 'package:essentials_app/util/display_aware_filters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trina_grid/trina_grid.dart';

TrinaColumn _dateColumn() =>
    TrinaColumn(title: 'Start', field: 'start', type: TrinaColumnType.date(format: 'yyyy-MM-dd'));

TrinaColumn _dateTimeColumn() =>
    TrinaColumn(title: 'Start', field: 'start', type: TrinaColumnType.dateTime(format: 'yyyy-MM-dd HH:mm'));

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

  group('date keyword filters (Today / Tomorrow / This week)', () {
    TrinaFilterType byTitle(String title) =>
        displayAwareFilterTypes.firstWhere((f) => f.title == title);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final tomorrow = today.add(const Duration(days: 1));
    final weekStart = today.subtract(Duration(days: today.weekday - 1));
    final lastWeek = weekStart.subtract(const Duration(days: 1));
    final nextWeek = weekStart.add(const Duration(days: 7));

    test('Equals "Today" matches any time on today, on a dateTime column', () {
      final column = _dateTimeColumn();
      final equals = byTitle(TrinaFilterTypeEquals.name);
      expect(
        equals.compare(base: isoDateTimeMinutes(today.add(const Duration(hours: 8, minutes: 30))), search: 'Today', column: column),
        isTrue,
      );
      expect(
        equals.compare(base: isoDateTimeMinutes(tomorrow), search: 'today', column: column),
        isFalse,
        reason: 'case-insensitive keyword, but still the wrong day',
      );
    });

    test('Equals "Tomorrow" on a plain date column', () {
      final column = _dateColumn();
      final equals = byTitle(TrinaFilterTypeEquals.name);
      expect(equals.compare(base: isoDate(tomorrow), search: 'Tomorrow', column: column), isTrue);
      expect(equals.compare(base: isoDate(today), search: 'Tomorrow', column: column), isFalse);
    });

    test('Equals "This week" is Monday-start, matching Calendar\'s own convention', () {
      final column = _dateColumn();
      final equals = byTitle(TrinaFilterTypeEquals.name);
      expect(equals.compare(base: isoDate(weekStart), search: 'This Week', column: column), isTrue);
      expect(equals.compare(base: isoDate(weekStart.add(const Duration(days: 6))), search: 'this week', column: column), isTrue);
      expect(equals.compare(base: isoDate(lastWeek), search: 'This Week', column: column), isFalse);
      expect(equals.compare(base: isoDate(nextWeek), search: 'This Week', column: column), isFalse);
    });

    test('Greater than / Less than treat the keyword as a bound, not a single day', () {
      final column = _dateColumn();
      final greaterThan = byTitle(TrinaFilterTypeGreaterThan.name);
      final lessThan = byTitle(TrinaFilterTypeLessThan.name);
      expect(greaterThan.compare(base: isoDate(tomorrow), search: 'Today', column: column), isTrue);
      expect(greaterThan.compare(base: isoDate(today), search: 'Today', column: column), isFalse);
      expect(lessThan.compare(base: isoDate(yesterday), search: 'Today', column: column), isTrue);
      expect(lessThan.compare(base: isoDate(today), search: 'Today', column: column), isFalse);
    });

    test('Greater/less than or equal to include the boundary day', () {
      final column = _dateColumn();
      final gte = byTitle(TrinaFilterTypeGreaterThanOrEqualTo.name);
      final lte = byTitle(TrinaFilterTypeLessThanOrEqualTo.name);
      expect(gte.compare(base: isoDate(today), search: 'Today', column: column), isTrue);
      expect(gte.compare(base: isoDate(yesterday), search: 'Today', column: column), isFalse);
      expect(lte.compare(base: isoDate(today), search: 'Today', column: column), isTrue);
      expect(lte.compare(base: isoDate(tomorrow), search: 'Today', column: column), isFalse);
    });

    test('a non-keyword value still behaves like an ordinary literal comparison', () {
      final column = _dateColumn();
      final equals = byTitle(TrinaFilterTypeEquals.name);
      expect(equals.compare(base: isoDate(today), search: isoDate(today), column: column), isTrue);
      expect(equals.compare(base: isoDate(today), search: isoDate(tomorrow), column: column), isFalse);
    });

    test('a keyword is a no-op on a non-date column -- falls through to literal text', () {
      final column = _plainTextColumn();
      final equals = byTitle(TrinaFilterTypeEquals.name);
      expect(equals.compare(base: 'today', search: 'Today', column: column), isTrue);
      expect(equals.compare(base: 'something else', search: 'Today', column: column), isFalse);
    });

    test('an unparseable base value on a date column never matches a keyword', () {
      final column = _dateColumn();
      final equals = byTitle(TrinaFilterTypeEquals.name);
      expect(equals.compare(base: 'not a date', search: 'Today', column: column), isFalse);
    });
  });
}
