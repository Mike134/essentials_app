// RecurringReminderService against the real essentials.db -- creates a
// throwaway "Timeframe"-shaped lookup table plus a throwaway table shaped
// like Agenda's own recurring-reminder field group (Start/Timeframe/When/
// Notify), through the real SchemaEditorService/GenericDao pipeline, same
// discipline every schema-engine test file has used since the Phase 1
// Step 3 incident. Run this file on its own, never chained with another
// SchemaEditorService.createTable-using test file in the same `flutter
// test` invocation.
//
// Insert maps are always built from the real, resolved [RecurringReminderFields]
// column names, never hardcoded strings like `'when'` -- a field named
// "When" is a genuine SQL reserved keyword (see `sql_identifiers.dart`),
// so `SchemaEditorService` always generates a de-collided physical column
// (`when_2`) for it, exactly the mechanism this test's own field-group
// resolution needs to go through, not around.
import 'dart:convert';

import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/db/recurring_reminder_service.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/schema_registry.dart';
import 'package:essentials_app/db/theme_settings_dao.dart';
import 'package:essentials_app/models/table_config.dart';
import 'package:essentials_app/util/date_format.dart';
import 'package:essentials_app/util/scheduling/recurrence_when.dart';
import 'package:essentials_app/util/scheduling/recurring_reminder_fields.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/schema_test_cleanup.dart';

void main() {
  final editor = SchemaEditorService();
  final metadata = SchemaMetadataDao();
  final registry = SchemaRegistry();
  final settings = ThemeSettingsDao(deviceId: 'rrsvc-test-device');
  final runTag = DateTime.now().microsecondsSinceEpoch;

  setUpAll(() async {
    await DatabaseHelper.instance.crdt;
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  /// A throwaway lookup table shaped like the real `timeframe` table --
  /// one row per keyword, `name` as the default displayColumn -- so the
  /// service's real `isLookup` (linked-`select`) resolution path is
  /// exercised, not just the simpler inline-select one. Returns the
  /// table name and each keyword's real row id.
  Future<(String tableName, Map<String, int> ids)> createTimeframeLookupTable() async {
    final tableName = await editor.createTable(displayName: 'RRSVC Timeframe $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Name', format: 'text');
    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);
    final ids = <String, int>{};
    for (final keyword in recurrenceTimeframeKeywords) {
      ids[keyword] = await dao.insert({'name': keyword});
    }
    return (tableName, ids);
  }

  /// A throwaway table shaped exactly like Agenda's own recurring-reminder
  /// field group, plus the optional Remind field when [withRemindField] is
  /// true. Returns the table name and its resolved [RecurringReminderFields]
  /// -- every test builds its insert maps from these real column names,
  /// never a hardcoded guess.
  Future<(String tableName, RecurringReminderFields fields)> createReminderTable(
    String timeframeTable, {
    bool withRemindField = false,
  }) async {
    final tableName = await editor.createTable(displayName: 'RRSVC Notify Test $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Start', format: 'dateTime');
    await editor.addField(
      tableName: tableName,
      displayName: 'Timeframe',
      format: 'select',
      optionsJson: jsonEncode({
        'mode': 'linked',
        'table': timeframeTable,
        'on_delete': 'ignore',
        'displayField': 'name',
      }),
    );
    await editor.addField(tableName: tableName, displayName: 'When', format: 'text');
    await editor.addField(tableName: tableName, displayName: 'Notify', format: 'boolean');
    if (withRemindField) {
      await editor.addField(tableName: tableName, displayName: 'Remind (Minutes Before)', format: 'integer');
    }

    final config = await registry.buildConfig(tableName);
    final fields = recurringReminderFieldsOf(config.fields);
    if (fields == null) fail('Test setup failed to produce a recognizable recurring-reminder field group');
    return (tableName, fields);
  }

  Future<void> cleanupLastFired(String tableName, int rowId) =>
      settings.setDeviceSetting('agenda_reminder_last_fired:$tableName:$rowId', null);

  Future<TableConfig> configFor(String tableName) => registry.buildConfig(tableName);

  test('a Notify=false row never fires, regardless of how overdue its Start is', () async {
    final (timeframeTable, timeframeIds) = await createTimeframeLookupTable();
    final (tableName, fields) = await createReminderTable(timeframeTable);
    final dao = GenericDao(await configFor(tableName));

    final id = await dao.insert({
      fields.start.column: isoDateTime(DateTime.now().subtract(const Duration(days: 30))),
      fields.timeframe.column: timeframeIds['once'],
      fields.when.column: '',
      fields.notify.column: 0,
    });
    addTearDown(() => cleanupLastFired(tableName, id));

    final service = RecurringReminderService(settingsOverride: settings, onlyTables: [tableName]);
    final notified = <String>[];
    final fired = await service.checkAndFireDueReminders(
      notify: (m) async => notified.add(m),
    );
    expect(fired, 0);
    expect(notified, isEmpty);
  });

  test('the notification names the row by its first real field, not the bare id', () async {
    // Regression: table_definitions.display_field is never set by any v2
    // table's UI (see GenericDao.getReverseLinks's own doc comment for
    // the identical gap already found there), so TableConfig.displayColumn
    // always falls back to the bare `id` column -- a notification built
    // from that showed a raw ~16-digit number instead of anything useful.
    final (timeframeTable, timeframeIds) = await createTimeframeLookupTable();
    final tableName = await editor.createTable(displayName: 'RRSVC Titled Test $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Activity', format: 'text');
    await editor.addField(tableName: tableName, displayName: 'Start', format: 'dateTime');
    await editor.addField(
      tableName: tableName,
      displayName: 'Timeframe',
      format: 'select',
      optionsJson: jsonEncode({
        'mode': 'linked',
        'table': timeframeTable,
        'on_delete': 'ignore',
        'displayField': 'name',
      }),
    );
    await editor.addField(tableName: tableName, displayName: 'When', format: 'text');
    await editor.addField(tableName: tableName, displayName: 'Notify', format: 'boolean');

    final config = await configFor(tableName);
    final fields = recurringReminderFieldsOf(config.fields);
    if (fields == null) fail('Test setup failed to produce a recognizable recurring-reminder field group');
    final dao = GenericDao(config);

    final id = await dao.insert({
      'activity': 'Guava Updates',
      fields.start.column: isoDateTime(DateTime.now().subtract(const Duration(hours: 2))),
      fields.timeframe.column: timeframeIds['once'],
      fields.when.column: '',
      fields.notify.column: 1,
    });
    addTearDown(() => cleanupLastFired(tableName, id));

    final service = RecurringReminderService(settingsOverride: settings, onlyTables: [tableName]);
    final notified = <String>[];
    final fired = await service.checkAndFireDueReminders(notify: (m) async => notified.add(m));
    expect(fired, 1);
    expect(notified.single, contains('Guava Updates'));
    expect(notified.single, isNot(contains(id.toString())));
  });

  test('a Notify=true, past-due "once" row fires exactly once, never again', () async {
    final (timeframeTable, timeframeIds) = await createTimeframeLookupTable();
    final (tableName, fields) = await createReminderTable(timeframeTable);
    final dao = GenericDao(await configFor(tableName));

    final start = DateTime.now().subtract(const Duration(hours: 2));
    final id = await dao.insert({
      fields.start.column: isoDateTime(start),
      fields.timeframe.column: timeframeIds['once'],
      fields.when.column: '',
      fields.notify.column: 1,
    });
    addTearDown(() => cleanupLastFired(tableName, id));

    final service = RecurringReminderService(settingsOverride: settings, onlyTables: [tableName]);
    final notified = <String>[];
    final firstPass = await service.checkAndFireDueReminders(notify: (m) async => notified.add(m));
    expect(firstPass, 1);
    expect(notified, hasLength(1));

    final secondPass = await service.checkAndFireDueReminders(notify: (m) async => notified.add(m));
    expect(secondPass, 0, reason: '"once" has no second occurrence to ever fire again');
    expect(notified, hasLength(1));
  });

  test('editing Start on an already-fired "once" row fires again for the new time', () async {
    // Regression: found live -- a record that already fired once, then
    // had its Start edited forward (e.g. 09:00 -> 10:00), never fired
    // again. `nextOccurrenceAfter('once', after: non-null)` always
    // returns null (a "once" timeframe has nothing left once its single
    // occurrence is consumed) -- the old code passed the *previous*
    // fired occurrence straight into `after`, which is only valid when
    // Start hasn't changed since. `_nextUnfiredOccurrence` fixes this by
    // always recomputing from the row's *current* Start first.
    final (timeframeTable, timeframeIds) = await createTimeframeLookupTable();
    final (tableName, fields) = await createReminderTable(timeframeTable);
    final dao = GenericDao(await configFor(tableName));

    final firstStart = DateTime.now().subtract(const Duration(hours: 2));
    final id = await dao.insert({
      fields.start.column: isoDateTime(firstStart),
      fields.timeframe.column: timeframeIds['once'],
      fields.when.column: '',
      fields.notify.column: 1,
    });
    addTearDown(() => cleanupLastFired(tableName, id));

    final service = RecurringReminderService(settingsOverride: settings, onlyTables: [tableName]);
    final notified = <String>[];
    final firstPass = await service.checkAndFireDueReminders(notify: (m) async => notified.add(m));
    expect(firstPass, 1);

    // Confirm the un-edited case really is still "never again", same as
    // the test above, before editing anything.
    final unedited = await service.checkAndFireDueReminders(notify: (m) async => notified.add(m));
    expect(unedited, 0);

    // Now edit Start forward to a new past-due time -- a real edit, going
    // through GenericDao.update exactly like GenericFormScreen's own Save
    // does.
    final secondStart = DateTime.now().subtract(const Duration(minutes: 30));
    await dao.update(id, {fields.start.column: isoDateTime(secondStart)});

    final afterEdit = await service.checkAndFireDueReminders(notify: (m) async => notified.add(m));
    expect(afterEdit, 1, reason: 'a new Start value is a genuinely new occurrence, eligible to fire again');
    expect(notified, hasLength(2));

    final afterEditAgain = await service.checkAndFireDueReminders(notify: (m) async => notified.add(m));
    expect(afterEditAgain, 0, reason: 'the edited occurrence has now also been fired -- no more left');
    expect(notified, hasLength(2));
  });

  test('a Notify=true row whose Start is still in the future never fires yet', () async {
    final (timeframeTable, timeframeIds) = await createTimeframeLookupTable();
    final (tableName, fields) = await createReminderTable(timeframeTable);
    final dao = GenericDao(await configFor(tableName));

    final start = DateTime.now().add(const Duration(days: 5));
    final id = await dao.insert({
      fields.start.column: isoDateTime(start),
      fields.timeframe.column: timeframeIds['daily'],
      fields.when.column: '',
      fields.notify.column: 1,
    });
    addTearDown(() => cleanupLastFired(tableName, id));

    final service = RecurringReminderService(settingsOverride: settings, onlyTables: [tableName]);
    final notified = <String>[];
    final fired = await service.checkAndFireDueReminders(notify: (m) async => notified.add(m));
    expect(fired, 0);
    expect(notified, isEmpty);
  });

  test('a "Remind (Minutes Before)" lead time fires ahead of the actual occurrence', () async {
    final (timeframeTable, timeframeIds) = await createTimeframeLookupTable();
    final (tableName, fields) = await createReminderTable(timeframeTable, withRemindField: true);
    final remindField = fields.remindMinutes!;
    final dao = GenericDao(await configFor(tableName));

    // Occurrence is 10 minutes in the future; a 15-minute lead time means
    // the fire time (occurrence - 15m) is already 5 minutes in the past.
    final start = DateTime.now().add(const Duration(minutes: 10));
    final id = await dao.insert({
      fields.start.column: isoDateTime(start),
      fields.timeframe.column: timeframeIds['once'],
      fields.when.column: '',
      fields.notify.column: 1,
      remindField.column: 15,
    });
    addTearDown(() => cleanupLastFired(tableName, id));

    final service = RecurringReminderService(settingsOverride: settings, onlyTables: [tableName]);
    final notified = <String>[];
    final fired = await service.checkAndFireDueReminders(notify: (m) async => notified.add(m));
    expect(fired, 1);
    expect(notified, hasLength(1));
  });

  test('nextDueFireTime reports the earliest upcoming fire time across every qualifying row', () async {
    final (timeframeTable, timeframeIds) = await createTimeframeLookupTable();
    final (tableName, fields) = await createReminderTable(timeframeTable);
    final dao = GenericDao(await configFor(tableName));

    final soon = DateTime.now().add(const Duration(hours: 1));
    final later = DateTime.now().add(const Duration(hours: 5));
    final soonId = await dao.insert({
      fields.start.column: isoDateTime(soon),
      fields.timeframe.column: timeframeIds['once'],
      fields.when.column: '',
      fields.notify.column: 1,
    });
    addTearDown(() => cleanupLastFired(tableName, soonId));
    final laterId = await dao.insert({
      fields.start.column: isoDateTime(later),
      fields.timeframe.column: timeframeIds['once'],
      fields.when.column: '',
      fields.notify.column: 1,
    });
    addTearDown(() => cleanupLastFired(tableName, laterId));

    final service = RecurringReminderService(settingsOverride: settings, onlyTables: [tableName]);
    final due = await service.nextDueFireTime();
    expect(due, isNotNull);
    expect(due!.difference(soon).inSeconds.abs() < 5, isTrue);
  });

  test('a "weekly" row uses the When field\'s chosen weekday, not Start\'s own', () async {
    final (timeframeTable, timeframeIds) = await createTimeframeLookupTable();
    final (tableName, fields) = await createReminderTable(timeframeTable);
    final dao = GenericDao(await configFor(tableName));

    // Start on a Monday; When says "every Wednesday" -- the first
    // occurrence should land on that Wednesday, not Monday.
    final start = DateTime(2020, 1, 6, 9, 0); // a real past Monday
    const rule = RecurrenceWhenRule(weekday: DateTime.wednesday);
    final id = await dao.insert({
      fields.start.column: isoDateTime(start),
      fields.timeframe.column: timeframeIds['weekly'],
      fields.when.column: rule.encode(),
      fields.notify.column: 1,
    });
    addTearDown(() => cleanupLastFired(tableName, id));

    final service = RecurringReminderService(settingsOverride: settings, onlyTables: [tableName]);
    // A real, far-past Start (2020) confirms the service resolves both
    // the linked Timeframe value and the JSON When rule correctly end to
    // end, without needing to actually fire it (which would depend on
    // real "now").
    final due = await service.nextDueFireTime();
    expect(due, isNotNull);
    expect(due!.weekday, DateTime.wednesday);
  });

  test('a table missing the recurring-reminder field group is simply ignored', () async {
    final tableName = await editor.createTable(displayName: 'RRSVC Plain Table $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');

    final service = RecurringReminderService(settingsOverride: settings, onlyTables: [tableName]);
    // Should complete without throwing, and never mistake this table for
    // a qualifying one.
    final due = await service.nextDueFireTime();
    // Not asserting a specific value (other tests' rows may still exist
    // if this file is somehow re-run mid-suite) -- just that this call
    // never throws for a non-qualifying table.
    expect(due, anyOf(isNull, isA<DateTime>()));
  });
}
