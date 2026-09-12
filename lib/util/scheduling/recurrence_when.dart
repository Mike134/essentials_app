import 'dart:convert';

/// Recognized `Timeframe` keywords (matched case-insensitively against the
/// linked `timeframe` lookup table's own display text, or an inline-select
/// option's label) -- the same six values `timeframe`'s real rows already
/// use (`once`/`hourly`/`daily`/`weekly`/`monthly`/`yearly`). An
/// unrecognized/blank value means "no recurrence can be computed" --
/// [nextOccurrenceAfter] returns `null` for it, same as a genuinely
/// one-off event that's already happened.
const recurrenceTimeframeKeywords = {'once', 'hourly', 'daily', 'weekly', 'monthly', 'yearly'};

/// A monthly recurrence's pattern -- see claude/essentials-v2-agenda
/// -scheduling-design.md's "Monthly patterns" section for why all three
/// exist rather than just a plain day number.
enum MonthlyPatternKind { dayOfMonth, lastDay, nthWeekday }

/// The parsed, decoded form of a "When" field's stored JSON -- only ever
/// meaningful for `weekly`/`monthly` Timeframes (`daily`/`yearly`/`hourly`/
/// `once` ignore it entirely, see [nextOccurrenceAfter]). Stored as a
/// small tagged JSON object in the field's own plain `TEXT` column, e.g.
/// `{"weekday":3}` (weekly) or `{"monthlyKind":"nth_weekday","nth":2,
/// "nthWeekday":2}` (monthly, "2nd Tuesday").
///
/// Deliberately carries every possible field regardless of which
/// recurrence mode is currently active -- lets [RecurrenceWhenField] (the
/// form widget) remember a previously-entered weekly weekday even while
/// Timeframe is switched to Monthly and back, rather than losing it the
/// moment the sibling dropdown changes.
class RecurrenceWhenRule {
  const RecurrenceWhenRule({
    this.weekday,
    this.monthlyKind,
    this.dayOfMonth,
    this.nth,
    this.nthWeekday,
  });

  /// 1 (Monday) .. 7 (Sunday) -- matches [DateTime.weekday] directly, no
  /// conversion needed anywhere this is used.
  final int? weekday;

  final MonthlyPatternKind? monthlyKind;

  /// 1..31, used when [monthlyKind] is [MonthlyPatternKind.dayOfMonth].
  /// Clamped to the real last day of a shorter month at occurrence-compute
  /// time (see [nextOccurrenceAfter]), not here.
  final int? dayOfMonth;

  /// 1..4, or -1 for "last" -- used when [monthlyKind] is
  /// [MonthlyPatternKind.nthWeekday]. Deliberately capped at 4 (never 5):
  /// a weekday occurs 4 or 5 times in a month depending on the month, so a
  /// literal "5th" wouldn't exist in every month -- "Last" already covers
  /// that case reliably (a weekday's *last* occurrence in a month always
  /// exists), so the picker never offers 5.
  final int? nth;

  /// 1..7, the weekday [nth] counts, used alongside [nth].
  final int? nthWeekday;

  static const _kindNames = {
    MonthlyPatternKind.dayOfMonth: 'day_of_month',
    MonthlyPatternKind.lastDay: 'last_day',
    MonthlyPatternKind.nthWeekday: 'nth_weekday',
  };

  String encode() {
    final map = <String, Object?>{};
    if (weekday != null) map['weekday'] = weekday;
    if (monthlyKind != null) map['monthlyKind'] = _kindNames[monthlyKind];
    if (dayOfMonth != null) map['dayOfMonth'] = dayOfMonth;
    if (nth != null) map['nth'] = nth;
    if (nthWeekday != null) map['nthWeekday'] = nthWeekday;
    return jsonEncode(map);
  }

  /// Lenient, same posture as every other JSON-in-a-TEXT-column parse in
  /// this app (`parseFieldOptions`, `InlineOption.parseList`, ...) --
  /// blank/malformed input decodes to `null` (equivalent to "no rule
  /// chosen yet"), never throws.
  static RecurrenceWhenRule? decode(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final kindName = decoded['monthlyKind'];
      MonthlyPatternKind? kind;
      for (final entry in _kindNames.entries) {
        if (entry.value == kindName) kind = entry.key;
      }
      return RecurrenceWhenRule(
        weekday: (decoded['weekday'] as num?)?.toInt(),
        monthlyKind: kind,
        dayOfMonth: (decoded['dayOfMonth'] as num?)?.toInt(),
        nth: (decoded['nth'] as num?)?.toInt(),
        nthWeekday: (decoded['nthWeekday'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  RecurrenceWhenRule copyWith({
    int? weekday,
    MonthlyPatternKind? monthlyKind,
    int? dayOfMonth,
    int? nth,
    int? nthWeekday,
  }) {
    return RecurrenceWhenRule(
      weekday: weekday ?? this.weekday,
      monthlyKind: monthlyKind ?? this.monthlyKind,
      dayOfMonth: dayOfMonth ?? this.dayOfMonth,
      nth: nth ?? this.nth,
      nthWeekday: nthWeekday ?? this.nthWeekday,
    );
  }
}

int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// (year, month) `delta` months from now, months rolling over into a new
/// year correctly in either direction.
(int, int) _addMonths(int year, int month, int delta) {
  final total = year * 12 + (month - 1) + delta;
  final newYear = total ~/ 12;
  final newMonth = total % 12 + 1;
  return (newYear, newMonth);
}

/// The `nth` (1-based; `-1` means "last") occurrence of [weekday] within
/// [year]/[month] -- always exists for `nth` in `1..4` or `-1` (never for
/// a literal `5`, deliberately not offered -- see
/// [RecurrenceWhenRule.nth]'s own doc comment).
DateTime _nthWeekdayOfMonth(int year, int month, int weekday, int nth, int hour, int minute) {
  if (nth == -1) {
    final lastDay = _daysInMonth(year, month);
    final lastDate = DateTime(year, month, lastDay);
    final back = (lastDate.weekday - weekday) % 7;
    final normalizedBack = back < 0 ? back + 7 : back;
    return DateTime(year, month, lastDay - normalizedBack, hour, minute);
  }
  final first = DateTime(year, month, 1);
  final forward = (weekday - first.weekday) % 7;
  final normalizedForward = forward < 0 ? forward + 7 : forward;
  final firstOccurrenceDay = 1 + normalizedForward;
  return DateTime(year, month, firstOccurrenceDay + (nth - 1) * 7, hour, minute);
}

DateTime _weeklyOccurrenceForWeek(DateTime anchorWeekStart, int weekday, int hour, int minute) {
  final forward = (weekday - anchorWeekStart.weekday) % 7;
  final normalizedForward = forward < 0 ? forward + 7 : forward;
  return DateTime(
    anchorWeekStart.year,
    anchorWeekStart.month,
    anchorWeekStart.day + normalizedForward,
    hour,
    minute,
  );
}

DateTime _monthlyOccurrenceForMonth(DateTime start, RecurrenceWhenRule? rule, int year, int month) {
  switch (rule?.monthlyKind) {
    case MonthlyPatternKind.lastDay:
      return DateTime(year, month, _daysInMonth(year, month), start.hour, start.minute);
    case MonthlyPatternKind.nthWeekday:
      final weekday = rule!.nthWeekday ?? start.weekday;
      final nth = rule.nth ?? 1;
      return _nthWeekdayOfMonth(year, month, weekday, nth, start.hour, start.minute);
    case MonthlyPatternKind.dayOfMonth:
    case null:
      final day = rule?.dayOfMonth ?? start.day;
      final clampedDay = day.clamp(1, _daysInMonth(year, month));
      return DateTime(year, month, clampedDay, start.hour, start.minute);
  }
}

DateTime _yearlyOccurrenceForYear(DateTime start, int year) {
  final day = start.day.clamp(1, _daysInMonth(year, start.month));
  return DateTime(year, start.month, day, start.hour, start.minute);
}

/// The next valid occurrence of a recurring [start]/[timeframeKeyword]/
/// [rule] combination -- `null` for [after] returns the very first
/// occurrence (at or after [start] itself); a non-null [after] returns the
/// next one following it (assumed to already be a real occurrence this
/// function itself once returned -- never re-validated against [rule]).
///
/// Returns `null` when there is no next occurrence at all: `once` past its
/// single occurrence, or an unrecognized/blank [timeframeKeyword].
/// `daily`/`hourly`/`weekly`/`monthly`/`yearly` all recur forever, so they
/// never return `null` once a first occurrence exists.
///
/// Every occurrence keeps [start]'s own hour/minute -- schema.sql's
/// dateTime convention has no separate "time of day" field to draw from,
/// and TickTick-style recurrence always keeps the anchor's original time.
DateTime? nextOccurrenceAfter({
  required DateTime start,
  required String? timeframeKeyword,
  RecurrenceWhenRule? rule,
  DateTime? after,
}) {
  final keyword = (timeframeKeyword ?? '').trim().toLowerCase();
  switch (keyword) {
    case 'once':
      return after == null ? start : null;
    case 'hourly':
      return after == null ? start : after.add(const Duration(hours: 1));
    case 'daily':
      return after == null ? start : after.add(const Duration(days: 1));
    case 'weekly':
      final weekday = (rule?.weekday != null && rule!.weekday! >= 1 && rule.weekday! <= 7)
          ? rule.weekday!
          : start.weekday;
      if (after != null) return after.add(const Duration(days: 7));
      final startDateOnly = DateTime(start.year, start.month, start.day);
      return _weeklyOccurrenceForWeek(startDateOnly, weekday, start.hour, start.minute);
    case 'monthly':
      if (after == null) {
        final thisMonth = _monthlyOccurrenceForMonth(start, rule, start.year, start.month);
        if (!thisMonth.isBefore(start)) return thisMonth;
        final (y, m) = _addMonths(start.year, start.month, 1);
        return _monthlyOccurrenceForMonth(start, rule, y, m);
      }
      final (y, m) = _addMonths(after.year, after.month, 1);
      return _monthlyOccurrenceForMonth(start, rule, y, m);
    case 'yearly':
      if (after == null) {
        final thisYear = _yearlyOccurrenceForYear(start, start.year);
        return !thisYear.isBefore(start) ? thisYear : _yearlyOccurrenceForYear(start, start.year + 1);
      }
      return _yearlyOccurrenceForYear(start, after.year + 1);
    default:
      return null;
  }
}
