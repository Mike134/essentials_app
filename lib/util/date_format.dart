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
