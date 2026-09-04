import 'dart:convert';

import '../../db/event_definitions_dao.dart';

/// Essentials v2 alarm-based scheduling design (see
/// claude/essentials-v2-alarm-scheduling-design.md, "New pure function:
/// nextDueTime") -- computes the single next moment any enabled,
/// non-`app_launch` scheduled binding will next be due, so a background
/// scheduler can arm one exact/inexact alarm for that moment instead of
/// polling every 15 minutes regardless of whether anything is due.
///
/// Deliberately the same logic [BackgroundScheduleService]'s private
/// `_isDue`/`_pastConfiguredTime`/`_matchesConfiguredWeekday` already
/// encode, just reframed from "is it due *right now*" to "when will it
/// next be due" -- kept as its own pure, zero-platform-dependency
/// function (not folded into that class) specifically so it's directly
/// unit-testable with fabricated bindings/timestamps, no device or
/// plugin involved, matching this project's own established pattern for
/// every other pure calculator (`FormulaService`, `LinkedFieldService`,
/// etc.).
///
/// [lastRunTimes] mirrors the `schedule_last_run:<id>` `device_settings`
/// values [BackgroundScheduleService] itself reads, keyed by
/// [EventDefinition.id]; a binding with no entry (or a `null` entry) is
/// treated as never having run. Returns `null` when no enabled,
/// non-`app_launch` binding exists at all -- meaning nothing should be
/// scheduled.
DateTime? nextDueTime(List<EventDefinition> bindings, Map<int, DateTime?> lastRunTimes, DateTime now) {
  DateTime? earliest;
  for (final binding in bindings) {
    if (!binding.enabled) continue;
    if (binding.eventType == 'app_launch') continue;

    final DateTime? candidate;
    switch (binding.eventType) {
      case 'schedule_hourly':
        candidate = _nextHourlyTime(lastRunTimes[binding.id], now);
      case 'schedule_daily':
        candidate = _nextDailyTime(binding.scheduleConfig, now);
      case 'schedule_weekly':
        candidate = _nextWeeklyTime(binding.scheduleConfig, now);
      default:
        candidate = null; // unrecognized event_type -- never contributes
    }
    if (candidate == null) continue;
    if (earliest == null || candidate.isBefore(earliest)) earliest = candidate;
  }
  return earliest;
}

/// `lastRun + 1h`, or `now` if it's never run -- matches
/// `BackgroundScheduleService._isDue`'s own hourly check exactly (due once
/// an hour has genuinely elapsed since the last run). Deliberately not
/// clamped to `now` when the result lands in the past (e.g. a missed
/// alarm) -- a past due time just means "already due," which an alarm
/// scheduler naturally fires immediately for anyway.
DateTime _nextHourlyTime(DateTime? lastRun, DateTime now) =>
    lastRun == null ? now : lastRun.add(const Duration(hours: 1));

/// Today at the configured time if that hasn't passed yet, else tomorrow
/// at that time. An unconfigured/unparseable time falls back to `now`
/// (due immediately) -- the same permissive default
/// `_pastConfiguredTime` already applies for "is it due right now".
DateTime _nextDailyTime(String? scheduleConfig, DateTime now) {
  final timeOfDay = _configuredTimeOfDay(scheduleConfig);
  if (timeOfDay == null) return now;
  var candidate = DateTime(now.year, now.month, now.day, timeOfDay.$1, timeOfDay.$2);
  if (candidate.isBefore(now)) candidate = candidate.add(const Duration(days: 1));
  return candidate;
}

/// The next occurrence of the configured weekday + time, never earlier
/// than `now`. An unconfigured/unparseable day *or* time falls back to
/// `now` (due immediately) -- same reasoning as [_nextDailyTime], applied
/// to both halves of the weekly config since `_matchesConfiguredWeekday`/
/// `_pastConfiguredTime` are each independently permissive when their own
/// half is missing.
DateTime _nextWeeklyTime(String? scheduleConfig, DateTime now) {
  final config = _decodeConfig(scheduleConfig);
  final dayKey = config?['day'] as String?;
  final timeOfDay = _configuredTimeOfDay(scheduleConfig);
  if (dayKey == null || timeOfDay == null) return now;

  final dayIndex = _weekdayKeys.indexOf(dayKey);
  if (dayIndex == -1) return now;
  final targetWeekday = dayIndex + 1; // DateTime.weekday is 1=Monday..7=Sunday, matching _weekdayKeys' order

  final daysUntil = (targetWeekday - now.weekday) % 7;
  var candidate = DateTime(
    now.year,
    now.month,
    now.day,
    timeOfDay.$1,
    timeOfDay.$2,
  ).add(Duration(days: daysUntil));
  // daysUntil > 0 always lands on a later calendar day, so it's already
  // after `now` regardless of the configured time-of-day -- only the
  // "today is the target weekday" case can still need pushing a full
  // week out, when that time has already passed today.
  if (daysUntil == 0 && candidate.isBefore(now)) {
    candidate = candidate.add(const Duration(days: 7));
  }
  return candidate;
}

const _weekdayKeys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

/// Parses `scheduleConfig`'s `"time": "HH:MM"` entry into `(hour,
/// minute)`, or `null` if unconfigured/unparseable -- shared by
/// [_nextDailyTime]/[_nextWeeklyTime] so both fall back identically.
(int, int)? _configuredTimeOfDay(String? scheduleConfig) {
  final config = _decodeConfig(scheduleConfig);
  final timeText = config?['time'] as String?;
  if (timeText == null) return null;
  final parts = timeText.split(':');
  if (parts.length != 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  return (hour, minute);
}

Map<String, Object?>? _decodeConfig(String? scheduleConfig) {
  if (scheduleConfig == null) return null;
  try {
    return jsonDecode(scheduleConfig) as Map<String, Object?>;
  } catch (_) {
    return null;
  }
}
