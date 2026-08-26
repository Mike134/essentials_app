// Essentials v2 Phase 5 build order step 3 -- real, permanent regression
// coverage for ScriptApiRuntime's record/table/notify/navigate bridge,
// run against the real essentials.db through the real SchemaEditorService
// pipeline, same discipline as every other v2 schema-engine test file
// since the Step 3 incident (CLAUDE.md "Essentials v2 Phase 1 -- Step 3").
// Run this file on its own, never chained with another
// SchemaEditorService.createTable-using test file in the same `flutter
// test` invocation.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/schema_registry.dart';
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
}
