import '../../db/event_definitions_dao.dart';
import 'recurrence.dart';

/// Essentials v2 alarm-based scheduling design (see
/// claude/essentials-v2-alarm-scheduling-design.md, "New pure function:
/// nextDueTime") -- computes the single next moment any enabled,
/// non-`app_launch` scheduled binding will next be due, so a background
/// scheduler can arm one exact/inexact alarm for that moment instead of
/// polling every 15 minutes regardless of whether anything is due.
///
/// Deliberately the same logic [BackgroundScheduleService]'s private
/// `_isDue` already encodes, just reframed from "is it due *right now*"
/// to "when will it next be due" -- kept as its own pure, zero-platform
/// -dependency function (not folded into that class) specifically so
/// it's directly unit-testable with fabricated bindings/timestamps, no
/// device or plugin involved, matching this project's own established
/// pattern for every other pure calculator (`FormulaService`,
/// `LinkedFieldService`, etc.). Both this function and `_isDue` share
/// their actual recurrence math via `recurrence.dart` now -- see
/// claude/essentials-v2-recurring-schedule-design.md for why
/// `schedule_hourly`/`schedule_daily`/`schedule_weekly`'s old duplicated
/// three-way logic was retired in favor of one generic
/// `schedule_interval` type.
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
      case 'schedule_interval':
        candidate = _nextIntervalTime(lastRunTimes[binding.id], binding.scheduleConfig, now);
      default:
        candidate = null; // unrecognized event_type -- never contributes
    }
    if (candidate == null) continue;
    if (earliest == null || candidate.isBefore(earliest)) earliest = candidate;
  }
  return earliest;
}

/// Unconfigured/unparseable `schedule_config` falls back to `now` (due
/// immediately) -- the same permissive default every schedule type in
/// this app has always applied for a missing/bad config, so a binding
/// never gets silently stuck because of a malformed value.
DateTime _nextIntervalTime(DateTime? lastRun, String? scheduleConfig, DateTime now) {
  final recurrence = parseRecurrenceConfig(scheduleConfig);
  if (recurrence == null) return now;

  final anchor = recurrence.anchor;
  if (anchor == null) {
    // Unanchored -- pure elapsed-time-since-last-run, generalizing the
    // old schedule_hourly behavior to any interval. Deliberately not
    // clamped to `now` when the result lands in the past (e.g. a missed
    // alarm) -- a past due time just means "already due," which an alarm
    // scheduler naturally fires immediately for anyway.
    return lastRun == null ? now : lastRun.add(recurrence.interval);
  }

  if (now.isBefore(anchor)) return anchor; // hasn't started yet

  final currentSlot = anchorAlignedSlotAtOrBefore(anchor, recurrence.interval, now);
  if (lastRun != null && !lastRun.isBefore(currentSlot)) {
    // The current slot's already been serviced -- next due is the
    // following one, not this one again.
    return currentSlot.add(recurrence.interval);
  }
  // The current slot hasn't been serviced yet -- already due (possibly
  // slightly overdue, which is fine; see this file's own "past due" note
  // above).
  return currentSlot;
}
