// Essentials v2 Phase 5 build order step 3 -- real, permanent regression
// coverage for ScriptApiRuntime's record/table/notify/navigate bridge,
// run against the real essentials.db through the real SchemaEditorService
// pipeline, same discipline as every other v2 schema-engine test file
// since the Step 3 incident (CLAUDE.md "Essentials v2 Phase 1 -- Step 3").
// Run this file on its own, never chained with another
// SchemaEditorService.createTable-using test file in the same `flutter
// test` invocation.
import 'dart:convert';

import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/schema_registry.dart';
import 'package:essentials_app/util/scheduling/recurrence_when.dart';
import 'package:essentials_app/util/scripting/script_api_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'support/schema_test_cleanup.dart';

void main() {
  late SqliteCrdt db;
  late String databasePath;
  final editor = SchemaEditorService();
  final registry = SchemaRegistry();
  final metadata = SchemaMetadataDao();
  final runTag = DateTime.now().microsecondsSinceEpoch;

  setUpAll(() async {
    db = await DatabaseHelper.instance.crdt;
    databasePath = await DatabaseHelper.instance.resolveDatabasePath();
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  Future<String> createTestTable(String label) async {
    final tableName = await editor.createTable(displayName: '$label $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    return tableName;
  }

  Future<String> physicalFieldName(String tableName, String displayName) async {
    final fields = await metadata.loadFields(tableName, includeDeleted: false);
    return fields.firstWhere((f) => f.displayName == displayName).fieldName;
  }

  test('record.set + record.save writes a real, re-readable value', () async {
    final tableName = await createTestTable('Script Record');
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
    final notesField = await physicalFieldName(tableName, 'Notes');

    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);
    final id = await dao.insert({notesField: 'original'});

    final runtime = ScriptApiRuntime();
    final result = await runtime.run(
      "record.set('$notesField', 'from script'); record.save();",
      databasePath: databasePath,
      context: ScriptRunContext(recordTable: tableName, recordId: id),
    );

    expect(result.outcome.succeeded, isTrue);
    final rows = await db.query('SELECT "$notesField" AS v FROM "$tableName" WHERE id = ?1', [id]);
    expect(rows.single['v'], 'from script');
    expect(result.touchedTables, {tableName});
  });

  test('record.delete soft-deletes the real row', () async {
    final tableName = await createTestTable('Script Delete');
    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);
    final id = await dao.insert({});

    final runtime = ScriptApiRuntime();
    final result = await runtime.run(
      'record.delete();',
      databasePath: databasePath,
      context: ScriptRunContext(recordTable: tableName, recordId: id),
    );

    expect(result.outcome.succeeded, isTrue);
    final rows = await db.query('SELECT is_deleted FROM "$tableName" WHERE id = ?1', [id]);
    expect(rows.single['is_deleted'], 1);
    expect(result.touchedTables, {tableName});
  });

  test('table(x).all()/.find() see real, currently-committed rows', () async {
    final tableName = await createTestTable('Script Table Read');
    await editor.addField(tableName: tableName, displayName: 'Status', format: 'text');
    final statusField = await physicalFieldName(tableName, 'Status');
    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);
    await dao.insert({statusField: 'open'});
    await dao.insert({statusField: 'closed'});
    await dao.insert({statusField: 'open'});

    final runtime = ScriptApiRuntime();
    final result = await runtime.run(
      "notify('all=' + table('$tableName').all().length); "
      "notify('open=' + table('$tableName').find({$statusField: 'open'}).length);",
      databasePath: databasePath,
    );

    expect(result.outcome.succeeded, isTrue);
    expect(result.effects.notifications, ['all=3', 'open=2']);
  });

  test('table() also accepts the display name shown everywhere else in the app', () async {
    // Real bug, found live: a table's *display* name is the only name a
    // script author ever sees (nav, pickers, screen titles) -- the first
    // version of this bridge required the raw physical identifier
    // instead and threw when Mike typed the display name shown in the
    // nav. `displayName` here deliberately includes a space and mixed
    // case, exactly like a real display name and exactly what would
    // fail `assertSafeSqlIdentifier` if resolution didn't happen first.
    final displayName = 'Script Display Name Test $runTag';
    final tableName = await editor.createTable(displayName: displayName);
    addTearDown(() => dropTestTable(editor, metadata, tableName));

    final runtime = ScriptApiRuntime();
    final result = await runtime.run(
      "notify('count=' + table('${displayName.toUpperCase()}').all().length);",
      databasePath: databasePath,
    );

    expect(result.outcome.succeeded, isTrue);
    expect(result.effects.notifications, ['count=0']);
  });

  test('table() with an unknown name fails clearly, not with a raw SQL error', () async {
    final runtime = ScriptApiRuntime();
    final result = await runtime.run("table('Not A Real Table').all();", databasePath: databasePath);

    expect(result.outcome.succeeded, isFalse);
    expect(result.outcome.error, contains('No table named'));
  });

  test('table(x).create() queues a real row, applied after the script finishes', () async {
    final tableName = await createTestTable('Script Table Create');
    await editor.addField(tableName: tableName, displayName: 'Label', format: 'text');
    final labelField = await physicalFieldName(tableName, 'Label');

    final runtime = ScriptApiRuntime();
    final result = await runtime.run(
      "table('$tableName').create({$labelField: 'created by script'});",
      databasePath: databasePath,
    );

    expect(result.outcome.succeeded, isTrue);
    final rows = await db.query('SELECT "$labelField" AS v FROM "$tableName" WHERE is_deleted = 0');
    expect(rows, hasLength(1));
    expect(rows.single['v'], 'created by script');
    expect(result.touchedTables, {tableName});
  });

  test('touchedTables is empty when a script makes no writes at all', () async {
    final runtime = ScriptApiRuntime();
    final result = await runtime.run("notify('hi');", databasePath: databasePath);

    expect(result.outcome.succeeded, isTrue);
    expect(result.touchedTables, isEmpty);
  });

  test('touchedTables covers every distinct table a script writes to, not just the bound record\'s own', () async {
    // The real motivating case: EventDispatchService.dispatchAndApplyEffects
    // uses this to tell an already-open Grid to reload -- found live, Mike's
    // own "Next" button test: a script bound to one table's button field
    // created a row in that same table via table().create(), and the Grid
    // behind the still-open form never refreshed until leaving and
    // returning. Covers both the bound-record write path (record.save) and
    // the table().create() path in one script, on two different tables.
    final boundTable = await createTestTable('Script Touched Bound');
    final otherTable = await createTestTable('Script Touched Other');
    await editor.addField(tableName: boundTable, displayName: 'Notes', format: 'text');
    final notesField = await physicalFieldName(boundTable, 'Notes');
    final config = await registry.buildConfig(boundTable);
    final id = await GenericDao(config).insert({notesField: 'original'});

    final runtime = ScriptApiRuntime();
    final result = await runtime.run(
      "record.set('$notesField', 'changed'); record.save(); table('$otherTable').create({});",
      databasePath: databasePath,
      context: ScriptRunContext(recordTable: boundTable, recordId: id),
    );

    expect(result.outcome.succeeded, isTrue);
    expect(result.touchedTables, {boundTable, otherTable});
  });

  test('notify/navigate calls are captured as effects, not dispatched', () async {
    final tableName = await createTestTable('Script Effects');
    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);
    final id = await dao.insert({});

    final runtime = ScriptApiRuntime();
    final result = await runtime.run(
      "notify('hello'); navigate.to('$tableName'); navigate.toRecord(record);",
      databasePath: databasePath,
      context: ScriptRunContext(recordTable: tableName, recordId: id),
    );

    expect(result.outcome.succeeded, isTrue);
    expect(result.effects.notifications, ['hello']);
    expect(result.effects.navigations, hasLength(2));
    expect(result.effects.navigations[0].toString(), 'toTable($tableName)');
    expect(result.effects.navigations[1].toString(), 'toRecord($tableName, $id)');
  });

  test('a scheduled-style run with no bound record sees record === null', () async {
    final runtime = ScriptApiRuntime();
    final result = await runtime.run(
      "notify(String(record));",
      databasePath: databasePath,
    );

    expect(result.outcome.succeeded, isTrue);
    expect(result.effects.notifications, ['null']);
  });

  test('record.save() with no bound record fails clearly, not silently', () async {
    final runtime = ScriptApiRuntime();
    final result = await runtime.run('record.save();', databasePath: databasePath);

    expect(result.outcome.succeeded, isFalse);
    expect(result.outcome.timedOut, isFalse);
    expect(result.outcome.error, isNotNull);
  });

  test('record.fields() returns every real field, id included, minus the CRDT bookkeeping columns', () async {
    final tableName = await createTestTable('Script Record Fields');
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
    final notesField = await physicalFieldName(tableName, 'Notes');
    final config = await registry.buildConfig(tableName);
    final id = await GenericDao(config).insert({notesField: 'hi'});

    final runtime = ScriptApiRuntime();
    final result = await runtime.run(
      "var f = record.fields(); notify(JSON.stringify(Object.keys(f).sort()));",
      databasePath: databasePath,
      context: ScriptRunContext(recordTable: tableName, recordId: id),
    );

    expect(result.outcome.succeeded, isTrue);
    final keys = jsonDecode(result.effects.notifications.single) as List;
    expect(keys, contains('id'));
    expect(keys, contains(notesField));
    for (final bookkeeping in ['is_deleted', 'hlc', 'node_id', 'modified']) {
      expect(keys, isNot(contains(bookkeeping)), reason: '$bookkeeping should never reach a script');
    }
  });

  /// A throwaway table shaped like Agenda's own recurring-reminder group
  /// (Start/Timeframe/When, plus an optional End) -- mirrors
  /// `recurring_reminder_service_test.dart`'s own `createReminderTable`
  /// helper, kept local to this file rather than shared/imported since
  /// each schema-engine test file stays self-contained per this project's
  /// established convention.
  Future<(String table, String startField, String timeframeField, String whenField, String? endField)>
  createRecurrenceShapedTable({
    required String timeframeTable,
    bool withEnd = false,
    bool inlineTimeframe = false,
  }) async {
    final tableName = await editor.createTable(displayName: 'Script Recurrence $runTag ${DateTime.now().microsecondsSinceEpoch}');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Start', format: 'dateTime');
    if (withEnd) {
      await editor.addField(tableName: tableName, displayName: 'End', format: 'dateTime');
    }
    await editor.addField(
      tableName: tableName,
      displayName: 'Timeframe',
      format: 'select',
      optionsJson: inlineTimeframe
          ? jsonEncode({
              'mode': 'inline',
              'options': [
                for (final keyword in recurrenceTimeframeKeywords) {'key': keyword, 'label': keyword},
              ],
            })
          : jsonEncode({'mode': 'linked', 'table': timeframeTable, 'displayField': 'name'}),
    );
    await editor.addField(tableName: tableName, displayName: 'When', format: 'text');

    return (
      tableName,
      await physicalFieldName(tableName, 'Start'),
      await physicalFieldName(tableName, 'Timeframe'),
      await physicalFieldName(tableName, 'When'),
      withEnd ? await physicalFieldName(tableName, 'End') : null,
    );
  }

  Future<(String table, Map<String, int> ids)> createTimeframeLookupTable() async {
    final tableName = await editor.createTable(displayName: 'Script Timeframe $runTag');
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

  test('record.nextOccurrence advances Start by one day for a daily timeframe', () async {
    final (timeframeTable, ids) = await createTimeframeLookupTable();
    final (tableName, startField, timeframeField, whenField, _) =
        await createRecurrenceShapedTable(timeframeTable: timeframeTable);
    final config = await registry.buildConfig(tableName);
    final id = await GenericDao(config).insert({
      startField: '2026-09-14 09:00',
      timeframeField: ids['daily'],
    });

    final runtime = ScriptApiRuntime();
    final result = await runtime.run(
      "var n = record.nextOccurrence('$startField', '$timeframeField', '$whenField'); notify(JSON.stringify(n));",
      databasePath: databasePath,
      context: ScriptRunContext(recordTable: tableName, recordId: id),
    );

    expect(result.outcome.succeeded, isTrue);
    final decoded = jsonDecode(result.effects.notifications.single) as Map;
    expect(decoded['start'], '2026-09-15 09:00');
    expect(decoded['end'], isNull);
  });

  test('record.nextOccurrence shifts End by the same delta as Start, preserving duration', () async {
    // The exact case the original "current End + (End - Start)" proposal
    // would have gotten wrong -- a 1-hour appointment must stay 1 hour,
    // not grow, after advancing.
    final (timeframeTable, ids) = await createTimeframeLookupTable();
    final (tableName, startField, timeframeField, whenField, endField) =
        await createRecurrenceShapedTable(timeframeTable: timeframeTable, withEnd: true);
    final config = await registry.buildConfig(tableName);
    final id = await GenericDao(config).insert({
      startField: '2026-09-15 09:00',
      endField!: '2026-09-15 10:00',
      timeframeField: ids['weekly'],
    });

    final runtime = ScriptApiRuntime();
    final result = await runtime.run(
      "var n = record.nextOccurrence('$startField', '$timeframeField', '$whenField', '$endField'); "
      "notify(JSON.stringify(n));",
      databasePath: databasePath,
      context: ScriptRunContext(recordTable: tableName, recordId: id),
    );

    expect(result.outcome.succeeded, isTrue);
    final decoded = jsonDecode(result.effects.notifications.single) as Map;
    expect(decoded['start'], '2026-09-22 09:00');
    expect(decoded['end'], '2026-09-22 10:00');
  });

  test('record.nextOccurrence returns null once a Once timeframe has already occurred', () async {
    final (timeframeTable, ids) = await createTimeframeLookupTable();
    final (tableName, startField, timeframeField, whenField, _) =
        await createRecurrenceShapedTable(timeframeTable: timeframeTable);
    final config = await registry.buildConfig(tableName);
    final id = await GenericDao(config).insert({
      startField: '2026-09-15 09:00',
      timeframeField: ids['once'],
    });

    final runtime = ScriptApiRuntime();
    final result = await runtime.run(
      "notify(String(record.nextOccurrence('$startField', '$timeframeField', '$whenField')));",
      databasePath: databasePath,
      context: ScriptRunContext(recordTable: tableName, recordId: id),
    );

    expect(result.outcome.succeeded, isTrue);
    expect(result.effects.notifications, ['null']);
  });

  test('record.nextOccurrence resolves an inline-select Timeframe field too, not just a linked one', () async {
    final (tableName, startField, timeframeField, whenField, _) = await createRecurrenceShapedTable(
      timeframeTable: '', // unused for inline mode
      inlineTimeframe: true,
    );
    final config = await registry.buildConfig(tableName);
    final id = await GenericDao(config).insert({
      startField: '2026-09-14 09:00',
      timeframeField: 'daily',
    });

    final runtime = ScriptApiRuntime();
    final result = await runtime.run(
      "notify(record.nextOccurrence('$startField', '$timeframeField', '$whenField').start);",
      databasePath: databasePath,
      context: ScriptRunContext(recordTable: tableName, recordId: id),
    );

    expect(result.outcome.succeeded, isTrue);
    expect(result.effects.notifications, ['2026-09-15 09:00']);
  });

  test('a real "Next" button-style script copies the record forward, leaving the original untouched', () async {
    // End-to-end proof of the actual planned Agenda usage: read the
    // current record, compute the next occurrence, copy every field
    // (minus id) into a brand-new row with Start/End advanced -- all
    // through the real bridge, not a hand-simplified version of it.
    final (timeframeTable, ids) = await createTimeframeLookupTable();
    final (tableName, startField, timeframeField, whenField, endField) =
        await createRecurrenceShapedTable(timeframeTable: timeframeTable, withEnd: true);
    await editor.addField(tableName: tableName, displayName: 'Activity', format: 'text');
    final activityField = await physicalFieldName(tableName, 'Activity');

    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);
    final id = await dao.insert({
      startField: '2026-09-14 09:00',
      endField!: '2026-09-14 09:30',
      timeframeField: ids['weekly'],
      activityField: 'Guava Updates',
    });

    final runtime = ScriptApiRuntime();
    final result = await runtime.run(
      '''
      var next = record.nextOccurrence('$startField', '$timeframeField', '$whenField', '$endField');
      if (next === null) {
        notify('no more occurrences');
      } else {
        var copy = record.fields();
        delete copy.id;
        copy.$startField = next.start;
        copy.$endField = next.end;
        table('$tableName').create(copy);
        notify('created: ' + next.start);
      }
      ''',
      databasePath: databasePath,
      context: ScriptRunContext(recordTable: tableName, recordId: id),
    );

    expect(result.outcome.succeeded, isTrue);
    expect(result.effects.notifications, ['created: 2026-09-21 09:00']);

    final rows = await db.query(
      'SELECT "$startField" AS start, "$endField" AS end, "$activityField" AS activity '
      'FROM "$tableName" WHERE is_deleted = 0 ORDER BY "$startField"',
    );
    expect(rows, hasLength(2), reason: 'the original row must survive untouched, alongside the new one');
    expect(rows[0]['start'], '2026-09-14 09:00');
    expect(rows[0]['end'], '2026-09-14 09:30');
    expect(rows[0]['activity'], 'Guava Updates');
    expect(rows[1]['start'], '2026-09-21 09:00');
    expect(rows[1]['end'], '2026-09-21 09:30');
    expect(rows[1]['activity'], 'Guava Updates');
  });
}
