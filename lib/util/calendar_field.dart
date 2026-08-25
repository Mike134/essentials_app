import 'dart:convert';

import '../models/table_config.dart';

/// `table_definitions.calendar_field` -- a per-table setting (same
/// "chosen explicitly, not derived" spirit as `display_field`/`order_by`),
/// picked once per table via `ManageTablesScreen`'s table editor rather
/// than re-asked every time the Calendar view loads. See
/// claude/essentials-v2-phase3-design.md's "Data model" for the two JSON
/// shapes this mirrors exactly.
class CalendarFieldConfig {
  const CalendarFieldConfig.single(this.field) : startField = null, endField = null, isRange = false;

  const CalendarFieldConfig.range(this.startField, this.endField)
    : field = null,
      isRange = true;

  final bool isRange;

  /// Single-date mode's one field.
  final String? field;

  /// Range mode's start/end fields (both date/dateTime format).
  final String? startField;
  final String? endField;

  Map<String, Object?> toJson() => isRange
      ? {'mode': 'range', 'start_field': startField, 'end_field': endField}
      : {'mode': 'single', 'field': field};

  static CalendarFieldConfig? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      if (decoded['mode'] == 'range') {
        final start = decoded['start_field'];
        final end = decoded['end_field'];
        if (start is String && end is String) return CalendarFieldConfig.range(start, end);
        return null;
      }
      final field = decoded['field'];
      if (field is String) return CalendarFieldConfig.single(field);
      return null;
    } catch (_) {
      return null;
    }
  }
}

bool _isDateField(FieldConfig field) => field.type == FieldType.date || field.type == FieldType.dateTime;

/// Every date/dateTime-format field on [config], in position order -- the
/// pool [ManageTablesScreen]'s calendar-field picker offers, and what
/// [defaultCalendarField] falls back to.
List<FieldConfig> eligibleCalendarFields(TableConfig config) =>
    [for (final field in config.fields) if (_isDateField(field)) field];

/// A table is only offered in the Calendar view's "Lists" checklist if this
/// is non-empty -- "eligibility, not error states" per the confirmed
/// design: a table with no date/dateTime field simply never appears there,
/// no dead checkbox.
bool hasEligibleCalendarField(TableConfig config) => eligibleCalendarFields(config).isNotEmpty;

/// Resolves [table]'s *effective* calendar field -- [rawCalendarField]
/// (the raw `table_definitions.calendar_field` JSON) if it's set and still
/// names a real date/dateTime field, otherwise the first eligible field by
/// position, single mode (the documented "never explicitly set" default).
/// `null` only when [table] has no date/dateTime field at all.
CalendarFieldConfig? resolveCalendarField(TableConfig table, String? rawCalendarField) {
  final eligible = eligibleCalendarFields(table);
  if (eligible.isEmpty) return null;

  final columns = {for (final f in eligible) f.column};
  final parsed = CalendarFieldConfig.tryParse(rawCalendarField);
  if (parsed != null) {
    final stillValid = parsed.isRange
        ? columns.contains(parsed.startField) && columns.contains(parsed.endField)
        : columns.contains(parsed.field);
    if (stillValid) return parsed;
  }
  return CalendarFieldConfig.single(eligible.first.column);
}

/// Parses a stored date/dateTime `TEXT` value (`YYYY-MM-DD` or
/// `YYYY-MM-DD HH:MM:SS`, per `lib/util/date_format.dart`'s own writing
/// convention) back into a real [DateTime] -- `null` for anything blank or
/// unparseable, same lenient-on-bad-data posture as every other reader in
/// this app.
DateTime? parseStoredDate(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return null;
  return DateTime.tryParse(raw.trim());
}
