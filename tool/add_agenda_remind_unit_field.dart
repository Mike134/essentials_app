// ignore_for_file: avoid_print
// One-time schema change for the real, live "agenda" table: adds a
// "Remind Unit" inline-select field (Minute(s)/Hour(s)/Day(s)/Month(s)/
// Year(s)) alongside the existing "Remind" integer field, so a reminder
// lead time can be expressed in a practical unit ("1 Week before" -- as
// 7 Day(s)) instead of forcing Mike to convert everything to minutes by
// hand. See RecurringReminderService's own doc comment for how the two
// fields combine into an actual fire time -- Minute/Hour/Day convert to
// an exact Duration; Month/Year subtract real calendar units from the
// occurrence date instead of an approximate day count.
//
// Default value "minute" preserves every existing row's current
// behavior exactly -- a row with no unit chosen yet is still read as
// pure minutes, identical to before this field existed.
//
//   flutter test tool/add_agenda_remind_unit_field.dart
//
// (Not `dart run` -- SchemaEditorService transitively imports
// `package:flutter/widgets.dart` via TableConfig; see
// tool/create_calendar_test_table.dart's own doc comment for the same
// gotcha.)
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/schema_editor_service.dart';

const tableName = 'agenda';

Future<void> main() async {
  final editor = SchemaEditorService();

  print('Adding "Remind Unit" to "$tableName"...');
  await editor.addField(
    tableName: tableName,
    displayName: 'Remind Unit',
    format: 'select',
    optionsJson:
        '{"mode": "inline", "options": '
        '[{"key": "minute", "label": "Minute(s)"}, '
        '{"key": "hour", "label": "Hour(s)"}, '
        '{"key": "day", "label": "Day(s)"}, '
        '{"key": "month", "label": "Month(s)"}, '
        '{"key": "year", "label": "Year(s)"}]}',
    defaultValue: 'minute',
  );

  print('Done.');
  await DatabaseHelper.instance.close();
}
