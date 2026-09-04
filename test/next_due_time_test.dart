// Proves nextDueTime -- the pure "when will this next be due" calculator
// for the alarm-based scheduling design (see
// claude/essentials-v2-alarm-scheduling-design.md). Reframes
// BackgroundScheduleService's own private _isDue/_pastConfiguredTime/
// _matchesConfiguredWeekday boolean checks as "when next", so this test
// file mirrors that logic's own edge cases (unconfigured time/day,
// already-passed-today, weekday wraparound) rather than re-deriving them
// from scratch. Run with `flutter test test/next_due_time_test.dart`.
import 'dart:convert';

import 'package:essentials_app/db/event_definitions_dao.dart';
import 'package:essentials_app/util/scripting/next_due_time.dart';
import 'package:flutter_test/flutter_test.dart';

EventDefinition _binding({
  int id = 1,
  String eventType = 'schedule_hourly',
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

  group('schedule_hourly', () {
    test('never run -> due now', () {
      final result = nextDueTime([_binding()], {}, now);
      expect(result, now);
    });

    test('ran less than an hour ago -> due exactly one hour after that run', () {
      final lastRun = now.subtract(const Duration(minutes: 20));
      final result = nextDueTime([_binding(id: 5)], {5: lastRun}, now);
      expect(result, lastRun.add(const Duration(hours: 1)));
    });

    test('overdue (last run more than an hour ago) -> a past due time, not clamped to now', () {
      final lastRun = now.subtract(const Duration(hours: 3));
      final result = nextDueTime([_binding(id: 5)], {5: lastRun}, now);
      expect(result, lastRun.add(const Duration(hours: 1)));
      expect(result!.isBefore(now), isTrue);
    });
  });

  group('schedule_daily', () {
    test('configured time later today -> today at that time', () {
      final result = nextDueTime([
        _binding(eventType: 'schedule_daily', config: {'time': '14:30'}),
      ], {}, now);
      expect(result, DateTime(2026, 9, 4, 14, 30));
    });

    test('configured time already passed today -> tomorrow at that time', () {
      final result = nextDueTime([
        _binding(eventType: 'schedule_daily', config: {'time': '08:00'}),
      ], {}, now);
      expect(result, DateTime(2026, 9, 5, 8, 0));
    });

    test('configured time exactly now -> today (not pushed to tomorrow)', () {
      final result = nextDueTime([
        _binding(eventType: 'schedule_daily', config: {'time': '10:00'}),
      ], {}, now);
      expect(result, DateTime(2026, 9, 4, 10, 0));
    });

    test('unconfigured time -> due now', () {
      final result = nextDueTime([_binding(eventType: 'schedule_daily')], {}, now);
      expect(result, now);
    });

    test('unparseable time -> due now', () {
      final result = nextDueTime([
        _binding(eventType: 'schedule_daily', config: {'time': 'garbage'}),
      ], {}, now);
      expect(result, now);
    });
  });

  group('schedule_weekly', () {
    test('configured day later this week, any time -> that day at that time', () {
      // now is Friday 2026-09-04; Monday 2026-09-07 is next week's Monday.
      final result = nextDueTime([
        _binding(eventType: 'schedule_weekly', config: {'day': 'mon', 'time': '09:00'}),
      ], {}, now);
      expect(result, DateTime(2026, 9, 7, 9, 0));
    });

    test('configured day is today, time later today -> today at that time', () {
      final result = nextDueTime([
        _binding(eventType: 'schedule_weekly', config: {'day': 'fri', 'time': '18:00'}),
      ], {}, now);
      expect(result, DateTime(2026, 9, 4, 18, 0));
    });

    test('configured day is today, time already passed -> next week, same day/time', () {
      final result = nextDueTime([
        _binding(eventType: 'schedule_weekly', config: {'day': 'fri', 'time': '08:00'}),
      ], {}, now);
      expect(result, DateTime(2026, 9, 11, 8, 0));
    });

    test('unconfigured day -> due now', () {
      final result = nextDueTime([
        _binding(eventType: 'schedule_weekly', config: {'time': '09:00'}),
      ], {}, now);
      expect(result, now);
    });

    test('unconfigured time -> due now', () {
      final result = nextDueTime([
        _binding(eventType: 'schedule_weekly', config: {'day': 'mon'}),
      ], {}, now);
      expect(result, now);
    });

    test('unrecognized day key -> due now', () {
      final result = nextDueTime([
        _binding(eventType: 'schedule_weekly', config: {'day': 'someday', 'time': '09:00'}),
      ], {}, now);
      expect(result, now);
    });
  });

  group('binding selection', () {
    test('app_launch bindings never contribute', () {
      final result = nextDueTime([_binding(eventType: 'app_launch')], {}, now);
      expect(result, isNull);
    });

    test('disabled bindings never contribute', () {
      final result = nextDueTime([_binding(enabled: false)], {}, now);
      expect(result, isNull);
    });

    test('no bindings at all -> null', () {
      expect(nextDueTime([], {}, now), isNull);
    });

    test('returns the minimum across every enabled, non-app_launch binding', () {
      final result = nextDueTime([
        _binding(id: 1, eventType: 'schedule_daily', config: {'time': '23:00'}),
        _binding(id: 2, eventType: 'schedule_hourly'), // due `now` -- the soonest
        _binding(id: 3, eventType: 'schedule_weekly', config: {'day': 'mon', 'time': '09:00'}),
        _binding(id: 4, eventType: 'app_launch'),
        _binding(id: 5, eventType: 'schedule_daily', config: {'time': '08:00'}, enabled: false),
      ], {}, now);
      expect(result, now);
    });

    test('an unrecognized event_type never contributes', () {
      final result = nextDueTime([_binding(eventType: 'record_created')], {}, now);
      expect(result, isNull);
    });
  });
}
