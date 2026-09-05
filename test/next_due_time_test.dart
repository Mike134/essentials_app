// Proves nextDueTime -- the pure "when will this next be due" calculator
// for the alarm-based scheduling design (see
// claude/essentials-v2-alarm-scheduling-design.md). Reframes
// BackgroundScheduleService's own private _isDue as "when next", built on
// the shared recurrence.dart primitives -- see
// claude/essentials-v2-recurring-schedule-design.md for the generic
// schedule_interval type that replaced schedule_hourly/schedule_daily/
// schedule_weekly. Run with `flutter test test/next_due_time_test.dart`.
import 'dart:convert';

import 'package:essentials_app/db/event_definitions_dao.dart';
import 'package:essentials_app/util/scripting/next_due_time.dart';
import 'package:flutter_test/flutter_test.dart';

EventDefinition _binding({
  int id = 1,
  String eventType = 'schedule_interval',
  Map<String, Object?>? config,
  bool enabled = true,
}) => EventDefinition(
  id: id,
  scriptId: 1,
  eventType: eventType,
  tableName: null,
  fieldName: null,
  scheduleConfig: config == null ? null : jsonEncode(config),
  enabled: enabled,
);

void main() {
  final now = DateTime(2026, 9, 4, 10, 0); // a Friday, 10:00am

  group('schedule_interval, unanchored', () {
    test('never run -> due now', () {
      final result = nextDueTime([
        _binding(config: {'interval': 1, 'unit': 'hours'}),
      ], {}, now);
      expect(result, now);
    });

    test('ran less than an interval ago -> due exactly one interval after that run', () {
      final lastRun = now.subtract(const Duration(minutes: 20));
      final result = nextDueTime([
        _binding(id: 5, config: {'interval': 1, 'unit': 'hours'}),
      ], {5: lastRun}, now);
      expect(result, lastRun.add(const Duration(hours: 1)));
    });

    test('overdue -> a past due time, not clamped to now', () {
      final lastRun = now.subtract(const Duration(hours: 3));
      final result = nextDueTime([
        _binding(id: 5, config: {'interval': 1, 'unit': 'hours'}),
      ], {5: lastRun}, now);
      expect(result, lastRun.add(const Duration(hours: 1)));
      expect(result!.isBefore(now), isTrue);
    });

    test('minute-granularity interval works', () {
      final lastRun = now.subtract(const Duration(minutes: 3));
      final result = nextDueTime([
        _binding(config: {'interval': 10, 'unit': 'minutes'}),
      ], {1: lastRun}, now);
      expect(result, lastRun.add(const Duration(minutes: 10)));
    });

    test('day/week units work', () {
      final lastRun = now.subtract(const Duration(days: 1));
      final result = nextDueTime([
        _binding(config: {'interval': 3, 'unit': 'days'}),
      ], {1: lastRun}, now);
      expect(result, lastRun.add(const Duration(days: 3)));

      final weeklyResult = nextDueTime([
        _binding(config: {'interval': 2, 'unit': 'weeks'}),
      ], {1: lastRun}, now);
      expect(weeklyResult, lastRun.add(const Duration(days: 14)));
    });

    test('below the 5-minute floor is clamped up to 5 minutes', () {
      final lastRun = now.subtract(const Duration(minutes: 1));
      final result = nextDueTime([
        _binding(config: {'interval': 1, 'unit': 'minutes'}),
      ], {1: lastRun}, now);
      expect(result, lastRun.add(const Duration(minutes: 5)));
    });

    test('unconfigured/malformed config -> due now', () {
      expect(nextDueTime([_binding()], {}, now), now);
      expect(nextDueTime([_binding(config: {'interval': 'garbage', 'unit': 'hours'})], {}, now), now);
      expect(nextDueTime([_binding(config: {'interval': 1, 'unit': 'fortnights'})], {}, now), now);
    });
  });

  group('schedule_interval, anchored', () {
    test('anchor in the future, never run -> due exactly at the anchor', () {
      final anchor = now.add(const Duration(hours: 4));
      final result = nextDueTime([
        _binding(config: {'interval': 4, 'unit': 'hours', 'anchor': anchor.toIso8601String()}),
      ], {}, now);
      expect(result, anchor);
    });

    test('anchor in the past, never run -> the most recent slot (overdue, fires ASAP)', () {
      final anchor = DateTime(2026, 9, 4, 8, 0); // 2 hours before `now`
      final result = nextDueTime([
        _binding(config: {'interval': 4, 'unit': 'hours', 'anchor': anchor.toIso8601String()}),
      ], {}, now);
      expect(result, anchor); // 08:00 slot -- still the most recent one at 10:00, not yet 4h elapsed
    });

    test('current slot already serviced -> next due is the following slot, not lastRun-relative', () {
      final anchor = DateTime(2026, 9, 4, 8, 0);
      final lastRun = DateTime(2026, 9, 4, 8, 5); // serviced the 08:00 slot
      final result = nextDueTime([
        _binding(config: {'interval': 4, 'unit': 'hours', 'anchor': anchor.toIso8601String()}),
      ], {1: lastRun}, now); // now = 10:00, still within the 08:00-12:00 slot
      expect(result, DateTime(2026, 9, 4, 12, 0));
    });

    test('badly overdue -> jumps straight to the current slot, not lastRun + interval', () {
      final anchor = DateTime(2026, 9, 4, 8, 0);
      final lastRun = DateTime(2026, 9, 4, 8, 5); // serviced the 08:00 slot
      final farNow = DateTime(2026, 9, 4, 20, 0); // 3 whole slots later (12:00, 16:00, 20:00)
      final result = nextDueTime([
        _binding(config: {'interval': 4, 'unit': 'hours', 'anchor': anchor.toIso8601String()}),
      ], {1: lastRun}, farNow);
      // Not lastRun + interval (12:00) -- the current slot (20:00), skipping the
      // missed 12:00/16:00 slots entirely, per the design doc's own
      // "why not catch up on every missed slot" reasoning.
      expect(result, DateTime(2026, 9, 4, 20, 0));
    });

    test('anchored daily-equivalent (interval=1 day, anchor sets the time-of-day)', () {
      final anchor = DateTime(2026, 9, 1, 14, 30); // any past date, 14:30 sets the phase
      final result = nextDueTime([
        _binding(config: {'interval': 1, 'unit': 'days', 'anchor': anchor.toIso8601String()}),
      ], {}, now); // now = 2026-09-04 10:00, before today's 14:30 slot
      // Never run + anchor in the past -> the most recent slot at or before
      // now, same "overdue fires ASAP" convention as every other case here.
      // Today's 14:30 slot hasn't arrived yet at 10:00, so the most recent
      // one is yesterday's.
      expect(result, DateTime(2026, 9, 3, 14, 30));
    });
  });

  group('binding selection', () {
    test('app_launch bindings never contribute', () {
      final result = nextDueTime([_binding(eventType: 'app_launch')], {}, now);
      expect(result, isNull);
    });

    test('disabled bindings never contribute', () {
      final result = nextDueTime([_binding(enabled: false, config: {'interval': 1, 'unit': 'hours'})], {}, now);
      expect(result, isNull);
    });

    test('no bindings at all -> null', () {
      expect(nextDueTime([], {}, now), isNull);
    });

    test('returns the minimum across every enabled, non-app_launch binding', () {
      final result = nextDueTime([
        _binding(id: 1, config: {'interval': 1, 'unit': 'days', 'anchor': DateTime(2026, 9, 4, 23, 0).toIso8601String()}),
        _binding(id: 2, config: {'interval': 1, 'unit': 'hours'}), // due `now` -- the soonest
        _binding(id: 3, config: {'interval': 1, 'unit': 'weeks', 'anchor': DateTime(2026, 9, 7, 9, 0).toIso8601String()}),
        _binding(id: 4, eventType: 'app_launch'),
        _binding(
          id: 5,
          config: {'interval': 1, 'unit': 'days', 'anchor': DateTime(2026, 9, 4, 8, 0).toIso8601String()},
          enabled: false,
        ),
      ], {}, now);
      expect(result, now);
    });

    test('an unrecognized event_type never contributes', () {
      final result = nextDueTime([_binding(eventType: 'record_created')], {}, now);
      expect(result, isNull);
    });
  });
}
