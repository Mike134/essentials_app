// Confirms the real, live "agenda" table -- Mike's actual TickTick
// replacement, not a throwaway test table -- is genuinely recognized as a
// recurring-reminder table by field-name convention. Read-only: never
// creates/modifies/drops anything, so (unlike every SchemaEditorService
// .createTable-using test file) it's safe to run alongside other test
// files in the same `flutter test` invocation.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/schema_registry.dart';
import 'package:essentials_app/util/scheduling/recurring_reminder_fields.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  test('the real "agenda" table has a recognized Start/Timeframe/When/Notify/Remind group', () async {
    final config = await SchemaRegistry().buildConfig('agenda');
    final fields = recurringReminderFieldsOf(config.fields);
    expect(fields, isNotNull, reason: 'agenda should qualify for recurring reminders');
    expect(fields!.start.label, 'Start');
    expect(fields.timeframe.label, 'Timeframe');
    expect(fields.when.label, 'When');
    expect(fields.notify.label, 'Notify');
    expect(fields.remindMinutes?.label, 'Remind');
    expect(fields.remindUnit?.label, 'Remind Unit');
  });
}
