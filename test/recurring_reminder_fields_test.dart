import 'package:essentials_app/models/table_config.dart';
import 'package:essentials_app/util/scheduling/recurring_reminder_fields.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const start = FieldConfig(column: 'start', label: 'Start', type: FieldType.dateTime);
  const timeframe = FieldConfig(
    column: 'timeframe',
    label: 'Timeframe',
    lookup: LookupConfig(table: 'timeframe', displayColumn: 'timeframe'),
  );
  const when = FieldConfig(column: 'period', label: 'When');
  const notify = FieldConfig(column: 'notify', label: 'Notify', type: FieldType.boolean);
  const remind = FieldConfig(column: 'remind_minutes', label: 'Remind (Minutes Before)', type: FieldType.integer);

  test('detects the full group, including the optional remind field', () {
    final fields = recurringReminderFieldsOf([start, timeframe, when, notify, remind]);
    expect(fields, isNotNull);
    expect(fields!.start.column, 'start');
    expect(fields.timeframe.column, 'timeframe');
    expect(fields.when.column, 'period');
    expect(fields.notify.column, 'notify');
    expect(fields.remindMinutes?.column, 'remind_minutes');
  });

  test('detects the group without the optional remind field', () {
    final fields = recurringReminderFieldsOf([start, timeframe, when, notify]);
    expect(fields, isNotNull);
    expect(fields!.remindMinutes, isNull);
  });

  test('label match is case-insensitive and trims whitespace', () {
    const messyStart = FieldConfig(column: 'start', label: ' START ', type: FieldType.dateTime);
    const messyTimeframe = FieldConfig(column: 'timeframe', label: 'timeFRAME');
    const messyWhen = FieldConfig(column: 'period', label: 'when');
    const messyNotify = FieldConfig(column: 'notify', label: 'NOTIFY', type: FieldType.boolean);
    final fields = recurringReminderFieldsOf([messyStart, messyTimeframe, messyWhen, messyNotify]);
    expect(fields, isNotNull);
  });

  test('null when any required field is missing', () {
    expect(recurringReminderFieldsOf([timeframe, when, notify]), isNull); // no Start
    expect(recurringReminderFieldsOf([start, when, notify]), isNull); // no Timeframe
    expect(recurringReminderFieldsOf([start, timeframe, notify]), isNull); // no When
    expect(recurringReminderFieldsOf([start, timeframe, when]), isNull); // no Notify
  });

  test('null when Start is not a real dateTime field, even if named "Start"', () {
    const textStart = FieldConfig(column: 'start', label: 'Start');
    final fields = recurringReminderFieldsOf([textStart, timeframe, when, notify]);
    expect(fields, isNull);
  });

  test('null for an empty field list', () {
    expect(recurringReminderFieldsOf(const []), isNull);
  });
}
