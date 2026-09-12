import '../../models/table_config.dart';

/// A table's recurring-reminder field group, detected purely by field
/// display-name match (case-insensitive) -- the same "detect by name, not
/// a stored flag" convention this app already uses for Geo Location (see
/// `lib/util/geo_location.dart`), not a new schema-level concept. Any
/// table with all four required fields present qualifies, regardless of
/// its own table name -- Agenda is simply the first (and, so far, only)
/// real table shaped this way.
///
/// See claude/essentials-v2-agenda-scheduling-design.md for the full
/// design -- this class only identifies the fields; the actual recurrence
/// math lives in `recurrence_when.dart` and the background firing logic in
/// `lib/db/recurring_reminder_service.dart`.
class RecurringReminderFields {
  const RecurringReminderFields({
    required this.start,
    required this.timeframe,
    required this.when,
    required this.notify,
    this.remindMinutes,
    this.remindUnit,
  });

  /// A `dateTime`-typed field named "Start" -- the recurrence anchor.
  final FieldConfig start;

  /// A linked-lookup or inline-`select` field named "Timeframe" whose
  /// resolved display text is matched against
  /// [recurrenceTimeframeKeywords] (`recurrence_when.dart`) -- an
  /// unrecognized value (or one of `daily`/`yearly`/`hourly`/`once`, which
  /// ignore [when] entirely) is handled gracefully, not an error.
  final FieldConfig timeframe;

  /// A plain `text`-format field named "When" -- holds a
  /// [RecurrenceWhenRule]-shaped JSON string, meaningful only for
  /// `weekly`/`monthly` timeframes (see that class's own doc comment).
  final FieldConfig when;

  /// A `boolean`-format field named "Notify" -- real recurring
  /// notifications only ever fire for a row where this is `true`
  /// (Mike's explicit ask: "if and only if").
  final FieldConfig notify;

  /// An `integer`-format field named "Remind" -- how long before each
  /// computed occurrence the notification should fire, in whatever unit
  /// [remindUnit] resolves to (plain minutes if [remindUnit] is absent or
  /// unset -- see [RecurringReminderService]'s own doc comment for the
  /// full combination logic). Optional: a table with the other four
  /// fields but not this one just treats every row as a 0-minute lead
  /// time (fire exactly at the occurrence), same as a row where this
  /// field is blank.
  final FieldConfig? remindMinutes;

  /// An inline-`select` field named "Remind Unit" (Minute(s)/Hour(s)/
  /// Day(s)/Month(s)/Year(s)) -- lets [remindMinutes]'s value be expressed
  /// in a practical unit instead of forcing a manual multiply-to-minutes
  /// conversion (Mike's own real complaint: "not everyone would know to
  /// multiply 1440 x 7" for a week). Optional, independently of
  /// [remindMinutes] -- a table with no "Remind Unit" field (or a row
  /// whose stored key doesn't match a real unit) is read as plain minutes,
  /// identical to this feature's original, unit-less behavior. Only ever
  /// meaningful together with [remindMinutes]; carries no meaning on its
  /// own.
  final FieldConfig? remindUnit;
}

const String recurringReminderStartLabel = 'Start';
const String recurringReminderTimeframeLabel = 'Timeframe';
const String recurringReminderWhenLabel = 'When';
const String recurringReminderNotifyLabel = 'Notify';
const String recurringReminderRemindMinutesLabel = 'Remind';
const String recurringReminderRemindUnitLabel = 'Remind Unit';

/// `null` if [fields] is missing any of Start/Timeframe/When/Notify --
/// same "just doesn't get the feature, no error" posture as
/// `geoLocationFieldsOf`.
RecurringReminderFields? recurringReminderFieldsOf(List<FieldConfig> fields) {
  FieldConfig? find(String label) {
    for (final f in fields) {
      if (f.label.trim().toLowerCase() == label.toLowerCase()) return f;
    }
    return null;
  }

  final start = find(recurringReminderStartLabel);
  final timeframe = find(recurringReminderTimeframeLabel);
  final when = find(recurringReminderWhenLabel);
  final notify = find(recurringReminderNotifyLabel);
  if (start == null || timeframe == null || when == null || notify == null) return null;
  if (start.type != FieldType.dateTime) return null;

  return RecurringReminderFields(
    start: start,
    timeframe: timeframe,
    when: when,
    notify: notify,
    remindMinutes: find(recurringReminderRemindMinutesLabel),
    remindUnit: find(recurringReminderRemindUnitLabel),
  );
}
