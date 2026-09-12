import 'package:essentials_app/util/scheduling/recurrence_when.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime _bruteForceNthWeekdayOfMonth(int year, int month, int weekday, int nth) {
  final daysInMonth = DateTime(year, month + 1, 0).day;
  final matches = <int>[];
  for (var d = 1; d <= daysInMonth; d++) {
    if (DateTime(year, month, d).weekday == weekday) matches.add(d);
  }
  final day = nth == -1 ? matches.last : matches[nth - 1];
  return DateTime(year, month, day);
}

void main() {
  group('RecurrenceWhenRule encode/decode', () {
    test('round-trips a weekly rule', () {
      const rule = RecurrenceWhenRule(weekday: 3);
      final decoded = RecurrenceWhenRule.decode(rule.encode());
      expect(decoded!.weekday, 3);
    });

    test('round-trips every monthly pattern', () {
      const dayOfMonth = RecurrenceWhenRule(monthlyKind: MonthlyPatternKind.dayOfMonth, dayOfMonth: 15);
      expect(RecurrenceWhenRule.decode(dayOfMonth.encode())!.dayOfMonth, 15);

      const lastDay = RecurrenceWhenRule(monthlyKind: MonthlyPatternKind.lastDay);
      expect(RecurrenceWhenRule.decode(lastDay.encode())!.monthlyKind, MonthlyPatternKind.lastDay);

      const nthWeekday = RecurrenceWhenRule(monthlyKind: MonthlyPatternKind.nthWeekday, nth: 2, nthWeekday: 2);
      final decoded = RecurrenceWhenRule.decode(nthWeekday.encode())!;
      expect(decoded.nth, 2);
      expect(decoded.nthWeekday, 2);
    });

    test('blank/malformed text decodes to null, not a throw', () {
      expect(RecurrenceWhenRule.decode(null), isNull);
      expect(RecurrenceWhenRule.decode(''), isNull);
      expect(RecurrenceWhenRule.decode('not json'), isNull);
      expect(RecurrenceWhenRule.decode('[1,2,3]'), isNull);
    });
  });

  group('nextOccurrenceAfter -- once', () {
    test('first occurrence is Start itself, and there is never a second one', () {
      final start = DateTime(2026, 9, 12, 9, 0);
      expect(
        nextOccurrenceAfter(start: start, timeframeKeyword: 'once', after: null),
        start,
      );
      expect(
        nextOccurrenceAfter(start: start, timeframeKeyword: 'once', after: start),
        isNull,
      );
    });
  });

  group('nextOccurrenceAfter -- hourly/daily', () {
    test('hourly advances by exactly one hour each time', () {
      final start = DateTime(2026, 9, 12, 9, 0);
      final first = nextOccurrenceAfter(start: start, timeframeKeyword: 'hourly', after: null);
      expect(first, start);
      final second = nextOccurrenceAfter(start: start, timeframeKeyword: 'hourly', after: first);
      expect(second, start.add(const Duration(hours: 1)));
    });

    test('daily advances by exactly one day each time', () {
      final start = DateTime(2026, 9, 12, 9, 0);
      final first = nextOccurrenceAfter(start: start, timeframeKeyword: 'daily', after: null);
      expect(first, start);
      final second = nextOccurrenceAfter(start: start, timeframeKeyword: 'daily', after: first);
      expect(second, start.add(const Duration(days: 1)));
    });
  });

  group('nextOccurrenceAfter -- weekly', () {
    test('start already on the target weekday -> first occurrence is Start itself', () {
      final start = DateTime(2026, 9, 14, 9, 0); // a Monday
      expect(start.weekday, DateTime.monday);
      final occurrence = nextOccurrenceAfter(
        start: start,
        timeframeKeyword: 'weekly',
        rule: const RecurrenceWhenRule(weekday: DateTime.monday),
        after: null,
      );
      expect(occurrence, start);
    });

    test('target weekday later in the same week', () {
      final start = DateTime(2026, 9, 14, 9, 0); // Monday
      final occurrence = nextOccurrenceAfter(
        start: start,
        timeframeKeyword: 'weekly',
        rule: const RecurrenceWhenRule(weekday: DateTime.wednesday),
        after: null,
      );
      expect(occurrence, DateTime(2026, 9, 16, 9, 0));
    });

    test('target weekday already passed this week rolls to next week', () {
      final start = DateTime(2026, 9, 17, 9, 0); // Thursday
      expect(start.weekday, DateTime.thursday);
      final occurrence = nextOccurrenceAfter(
        start: start,
        timeframeKeyword: 'weekly',
        rule: const RecurrenceWhenRule(weekday: DateTime.wednesday),
        after: null,
      );
      // The next Wednesday after a Thursday is 6 days later, in the
      // following week -- not "in the past" relative to start.
      expect(occurrence, DateTime(2026, 9, 23, 9, 0));
      expect(occurrence!.isAfter(start), isTrue);
    });

    test('subsequent occurrences are always exactly 7 days apart', () {
      final start = DateTime(2026, 9, 14, 9, 0);
      const rule = RecurrenceWhenRule(weekday: DateTime.wednesday);
      final first = nextOccurrenceAfter(start: start, timeframeKeyword: 'weekly', rule: rule, after: null);
      final second = nextOccurrenceAfter(start: start, timeframeKeyword: 'weekly', rule: rule, after: first);
      final third = nextOccurrenceAfter(start: start, timeframeKeyword: 'weekly', rule: rule, after: second);
      expect(second!.difference(first!), const Duration(days: 7));
      expect(third!.difference(second), const Duration(days: 7));
    });

    test('no rule -- falls back to Start\'s own weekday', () {
      final start = DateTime(2026, 9, 16, 9, 0); // Wednesday
      final occurrence = nextOccurrenceAfter(start: start, timeframeKeyword: 'weekly', rule: null, after: null);
      expect(occurrence, start);
    });
  });

  group('nextOccurrenceAfter -- monthly day_of_month', () {
    test('day already passed this month rolls to next month', () {
      final start = DateTime(2026, 9, 20, 9, 0);
      const rule = RecurrenceWhenRule(monthlyKind: MonthlyPatternKind.dayOfMonth, dayOfMonth: 5);
      final occurrence = nextOccurrenceAfter(start: start, timeframeKeyword: 'monthly', rule: rule, after: null);
      expect(occurrence, DateTime(2026, 10, 5, 9, 0));
    });

    test('day still upcoming this month -> this month', () {
      final start = DateTime(2026, 9, 1, 9, 0);
      const rule = RecurrenceWhenRule(monthlyKind: MonthlyPatternKind.dayOfMonth, dayOfMonth: 20);
      final occurrence = nextOccurrenceAfter(start: start, timeframeKeyword: 'monthly', rule: rule, after: null);
      expect(occurrence, DateTime(2026, 9, 20, 9, 0));
    });

    test('day 31 clamps to the real last day of a shorter month', () {
      final start = DateTime(2026, 1, 31, 9, 0);
      const rule = RecurrenceWhenRule(monthlyKind: MonthlyPatternKind.dayOfMonth, dayOfMonth: 31);
      final first = nextOccurrenceAfter(start: start, timeframeKeyword: 'monthly', rule: rule, after: null);
      expect(first, DateTime(2026, 1, 31, 9, 0));
      final next = nextOccurrenceAfter(start: start, timeframeKeyword: 'monthly', rule: rule, after: first);
      // February 2026 -- not a leap year -- has 28 days.
      expect(next, DateTime(2026, 2, 28, 9, 0));
      final third = nextOccurrenceAfter(start: start, timeframeKeyword: 'monthly', rule: rule, after: next);
      expect(third, DateTime(2026, 3, 31, 9, 0));
    });
  });

  group('nextOccurrenceAfter -- monthly last_day', () {
    test('always lands on the real final day of each month', () {
      final start = DateTime(2026, 1, 15, 9, 0);
      const rule = RecurrenceWhenRule(monthlyKind: MonthlyPatternKind.lastDay);
      final first = nextOccurrenceAfter(start: start, timeframeKeyword: 'monthly', rule: rule, after: null);
      expect(first, DateTime(2026, 1, 31, 9, 0));
      final second = nextOccurrenceAfter(start: start, timeframeKeyword: 'monthly', rule: rule, after: first);
      expect(second, DateTime(2026, 2, 28, 9, 0));
    });
  });

  group('nextOccurrenceAfter -- monthly nth_weekday', () {
    test('matches a brute-force scan for every nth 1-4 and Last, across several months', () {
      for (final month in [1, 2, 3, 9, 12]) {
        for (final nth in [1, 2, 3, 4, -1]) {
          for (final weekday in [DateTime.monday, DateTime.wednesday, DateTime.sunday]) {
            final expected = _bruteForceNthWeekdayOfMonth(2026, month, weekday, nth);
            final start = DateTime(2026, month, 1, 8, 30);
            final rule = RecurrenceWhenRule(
              monthlyKind: MonthlyPatternKind.nthWeekday,
              nth: nth,
              nthWeekday: weekday,
            );
            final occurrence = nextOccurrenceAfter(
              start: start,
              timeframeKeyword: 'monthly',
              rule: rule,
              after: null,
            );
            expect(
              occurrence,
              DateTime(expected.year, expected.month, expected.day, 8, 30),
              reason: 'month=$month nth=$nth weekday=$weekday',
            );
          }
        }
      }
    });

    test("2nd Tuesday example advances correctly across months", () {
      final start = DateTime(2026, 1, 1, 9, 0);
      const rule = RecurrenceWhenRule(monthlyKind: MonthlyPatternKind.nthWeekday, nth: 2, nthWeekday: DateTime.tuesday);
      final first = nextOccurrenceAfter(start: start, timeframeKeyword: 'monthly', rule: rule, after: null);
      expect(first!.weekday, DateTime.tuesday);
      expect(first.month, 1);
      final second = nextOccurrenceAfter(start: start, timeframeKeyword: 'monthly', rule: rule, after: first);
      expect(second!.weekday, DateTime.tuesday);
      expect(second.month, 2);
      expect(second.isAfter(first), isTrue);
    });
  });

  group('nextOccurrenceAfter -- yearly', () {
    test('same month/day every year', () {
      final start = DateTime(2026, 6, 15, 9, 0);
      final first = nextOccurrenceAfter(start: start, timeframeKeyword: 'yearly', after: null);
      expect(first, start);
      final second = nextOccurrenceAfter(start: start, timeframeKeyword: 'yearly', after: first);
      expect(second, DateTime(2027, 6, 15, 9, 0));
    });

    test('Feb 29 clamps in a non-leap year and un-clamps again in the next leap year', () {
      final start = DateTime(2024, 2, 29, 9, 0); // 2024 is a leap year
      final first = nextOccurrenceAfter(start: start, timeframeKeyword: 'yearly', after: null);
      expect(first, start);
      final y2025 = nextOccurrenceAfter(start: start, timeframeKeyword: 'yearly', after: first);
      expect(y2025, DateTime(2025, 2, 28, 9, 0));
      final y2026 = nextOccurrenceAfter(start: start, timeframeKeyword: 'yearly', after: y2025);
      expect(y2026, DateTime(2026, 2, 28, 9, 0));
      final y2027 = nextOccurrenceAfter(start: start, timeframeKeyword: 'yearly', after: y2026);
      expect(y2027, DateTime(2027, 2, 28, 9, 0));
      final y2028 = nextOccurrenceAfter(start: start, timeframeKeyword: 'yearly', after: y2027);
      expect(y2028, DateTime(2028, 2, 29, 9, 0)); // 2028 is a leap year again
    });
  });

  group('nextOccurrenceAfter -- unrecognized/blank timeframe', () {
    test('returns null, not a guess', () {
      final start = DateTime(2026, 9, 12, 9, 0);
      expect(nextOccurrenceAfter(start: start, timeframeKeyword: null, after: null), isNull);
      expect(nextOccurrenceAfter(start: start, timeframeKeyword: '', after: null), isNull);
      expect(nextOccurrenceAfter(start: start, timeframeKeyword: 'fortnightly', after: null), isNull);
    });
  });
}
