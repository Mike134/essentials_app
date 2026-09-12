/// ISO8601 date/datetime formatting matching schema.sql's stored TEXT
/// convention (`YYYY-MM-DD` / `YYYY-MM-DD HH:MM:SS`) -- shared by
/// `GenericListScreen` (grid date/dateTime columns) and `GenericFormScreen`
/// (date/dateTime picker fields) so both write the exact same string shape
/// SQLite already has for these columns.
String isoDate(DateTime date) {
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

String isoDateTime(DateTime dateTime) {
  return '${isoDate(dateTime)} '
      '${dateTime.hour.toString().padLeft(2, '0')}:'
      '${dateTime.minute.toString().padLeft(2, '0')}:'
      '${dateTime.second.toString().padLeft(2, '0')}';
}

/// Same as [isoDateTime] but drops the seconds component -- no dateTime
/// field in this app has ever had a workflow that relies on second-level
/// precision (neither native date/time picker even lets seconds be typed;
/// see `GenericFormScreen._pickDateTimeForField`'s own doc comment), so the
/// grid/form UI shows and writes minute precision only. Storage otherwise
/// stays a plain `YYYY-MM-DD HH:MM` string -- still parseable by
/// [DateTime.tryParse] like any other ISO8601 value already in this app.
String isoDateTimeMinutes(DateTime dateTime) {
  return '${isoDate(dateTime)} '
      '${dateTime.hour.toString().padLeft(2, '0')}:'
      '${dateTime.minute.toString().padLeft(2, '0')}';
}
