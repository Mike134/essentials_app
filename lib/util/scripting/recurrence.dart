import 'dart:convert';

/// Shared recurrence math for `schedule_interval` bindings -- see
/// claude/essentials-v2-recurring-schedule-design.md. Used by both
/// `next_due_time.dart` (arms the next alarm) and
/// `background_schedule_service.dart` (the real due-check inside a
/// dispatch pass), so the one recurrence formula only exists once --
/// `schedule_hourly`/`schedule_daily`/`schedule_weekly` used to duplicate
/// this logic across both files independently; `schedule_interval`
/// doesn't repeat that.
///
/// `schedule_config` shape: `{"interval": 4, "unit": "hours", "anchor":
/// "2026-09-05T10:20:00"}` -- `unit` is one of minutes/hours/days/weeks,
/// `anchor` is optional and, when present, local wall-clock (no timezone
/// offset), matching every other `schedule_config` time value in this
/// app.
const minRecurrenceInterval = Duration(minutes: 5);

/// A parsed, validated `schedule_config` for a `schedule_interval`
/// binding. [interval] is always clamped to at least
/// [minRecurrenceInterval] -- see that constant's own doc comment for why
/// 5 minutes is the real ceiling on this mechanism's precision, not an
/// arbitrary restriction.
class RecurrenceConfig {
  const RecurrenceConfig({required this.interval, this.anchor});

  final Duration interval;

  /// `null` means unanchored -- pure elapsed-time-since-last-run, the
  /// simple case. Non-null means phase-locked to a fixed sequence of
  /// slots (`anchor`, `anchor + interval`, `anchor + 2*interval`, ...)
  /// independent of exactly when the binding actually last ran.
  final DateTime? anchor;
}

/// Parses [scheduleConfig] into a [RecurrenceConfig], or `null` if it's
/// missing, malformed, or missing a recognized `unit` -- callers treat a
/// `null` result as "unconfigured," same permissive fallback every other
/// schedule type in this app already uses for a missing/bad config.
RecurrenceConfig? parseRecurrenceConfig(String? scheduleConfig) {
  if (scheduleConfig == null) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(scheduleConfig);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;

  final intervalValue = decoded['interval'];
  final unit = decoded['unit'];
  if (intervalValue is! num || unit is! String) return null;
  final unitDuration = _unitToDuration(unit);
  if (unitDuration == null) return null;

  var interval = unitDuration * intervalValue.round();
  if (interval < minRecurrenceInterval) interval = minRecurrenceInterval;

  final anchorText = decoded['anchor'];
  final anchor = anchorText is String ? DateTime.tryParse(anchorText) : null;

  return RecurrenceConfig(interval: interval, anchor: anchor);
}

Duration? _unitToDuration(String unit) => switch (unit) {
  'minutes' => const Duration(minutes: 1),
  'hours' => const Duration(hours: 1),
  'days' => const Duration(days: 1),
  'weeks' => const Duration(days: 7),
  _ => null,
};

/// The most recent anchor-aligned slot at or before [reference] --
/// [anchor] itself if [reference] hasn't reached the anchor yet (the
/// schedule hasn't "started"). Every real slot is `anchor + n*interval`
/// for some non-negative integer `n`; this is the one shared primitive
/// both the "what's the next due time" and "is the current slot already
/// serviced" questions are built from.
DateTime anchorAlignedSlotAtOrBefore(DateTime anchor, Duration interval, DateTime reference) {
  if (!reference.isAfter(anchor)) return anchor;
  final elapsed = reference.difference(anchor);
  final periods = elapsed.inMicroseconds ~/ interval.inMicroseconds;
  return anchor.add(interval * periods);
}

/// How many whole occurrences were silently skipped between the slot
/// [lastRun] serviced and the slot at or before [now] -- `0` for normal
/// progression (the very next slot after the one [lastRun] serviced) or
/// for "not due again yet" (still within the slot [lastRun] already
/// serviced). A positive result means the schedule fell behind by more
/// than one slot -- e.g. the app was closed/force-stopped for a while --
/// and the caller jumped straight to the current slot rather than
/// chain-firing through everything missed in between (see the design
/// doc's own "why not catch up on every missed slot" section). Only
/// meaningful for an anchored config -- an unanchored schedule has no
/// fixed slots to miss, since "next" is always defined relative to
/// whenever it last actually ran.
int missedOccurrenceCount(DateTime anchor, Duration interval, DateTime lastRun, DateTime now) {
  final lastRunSlot = anchorAlignedSlotAtOrBefore(anchor, interval, lastRun);
  final currentSlot = anchorAlignedSlotAtOrBefore(anchor, interval, now);
  final slotsElapsed = currentSlot.difference(lastRunSlot).inMicroseconds ~/ interval.inMicroseconds;
  return slotsElapsed > 1 ? slotsElapsed - 1 : 0;
}
