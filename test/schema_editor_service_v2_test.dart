// Proves Essentials v2 Phase 1 build order step 3 --
// SchemaEditorService.createTable/addField -- against the REAL
// essentials.db. Run with
// `flutter test test/schema_editor_service_v2_test.dart`.
//
// Safe against real data for the same reason table_deletion_handling_test
// .dart/generic_dao_insert_id_test.dart are: every table this test creates
// is throwaway, hard-dropped in tearDown, with its table_definitions/
// field_definitions rows tombstoned afterward too. Runs against the real
// db (not a scratch copy) because createTable/addField's whole point is
// writing through the real migration_log/MigrationService.applyPending
// pipeline -- a scratch db wouldn't exercise that.
//
// Every display name gets a per-run-unique tag (see [_runTag]) and every
// test captures the identifier createTable actually returns, rather than
// asserting a hardcoded one -- table_name is deliberately immutable once
// created (design doc), so _generateTableIdentifier treats even a
// *tombstoned* table_definitions row as still reserved forever (no
// stage-2 hard-delete exists yet to free it). A run without the tag would
// only pass on a pristine db, then silently pick up a numeric suffix on
// every later run of this same file -- found live, not theorized: a
// second consecutive run of an earlier version of this file (fixed names,
// no tag) failed exactly this way, because the collision-avoidance loop
// increments off the *original* base name every time, not off whichever
// suffixed candidate a previous call happened to land on -- so two
// createTable calls for the same already-once-collided base name don't
// generally differ by exactly "_2".
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/util/device_id.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'support/schema_test_cleanup.dart';

void main() {
  late SqliteCrdt db;
  final editor = SchemaEditorService();
  final metadata = SchemaMetadataDao();
  // Per-run-unique tag -- see the file header comment for why this matters.
  final runTag = DateTime.now().microsecondsSinceEpoch;

  setUpAll(() async {
    db = await DatabaseHelper.instance.crdt;
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  /// Creates a throwaway table via [SchemaEditorService.createTable] with
  /// [label] tagged to be unique to this test run, and registers cleanup
  /// as this test's own tearDown so it runs regardless of pass/fail --
  /// see [dropTestTable]'s doc comment for why this must be a real,
  /// synced drop, not a raw local `DROP TABLE`.
  Future<String> createTestTable(String label, {String? description, String? icon}) async {
    final tableName = await editor.createTable(
      displayName: '$label $runTag',
      description: description,
      icon: icon,
    );
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    return tableName;
  }

  test('createTable creates a physical table with only id + CRDT columns, never predeclared', () async {
    final tableName = await createTestTable('SETV2 Physical Columns');

    final columns = await db.query('PRAGMA table_info("$tableName")');
    final columnNames = {for (final c in columns) c['name'] as String};
    expect(columnNames, {'id', 'is_deleted', 'hlc', 'node_id', 'modified'});
  });

  test('createTable writes a matching table_definitions row', () async {
    final tableName = await createTestTable(
      'SETV2 Table Definitions Row',
      description: 'a test table',
      icon: 'star',
    );

    final rows = await db.query(
      'SELECT * FROM table_definitions WHERE table_name = ?1 AND is_deleted = 0',
      [tableName],
    );
    expect(rows, hasLength(1));
    expect(rows.first['display_name'], 'SETV2 Table Definitions Row $runTag');
    expect(rows.first['description'], 'a test table');
    expect(rows.first['icon'], 'star');
  });

  test('createTable writes a migration_log row and this device reports it succeeded', () async {
    final tableName = await createTestTable('SETV2 Migration Log Row');
    final deviceId = await DeviceId.resolve();

    final logRows = await db.query(
      'SELECT id, sql_text FROM migration_log WHERE sql_text LIKE ?1 AND is_deleted = 0',
      ['%CREATE TABLE "$tableName"%'],
    );
    expect(logRows, hasLength(1));
    final sqlText = logRows.first['sql_text'] as String;
    // Never predeclares the four CRDT bookkeeping columns -- CLAUDE.md's
    // Essentials v2 wipe write-up: doing so makes the whole CREATE TABLE
    // fail outright, not just duplicate.
    expect(sqlText, isNot(contains('is_deleted')));
    expect(sqlText, isNot(contains('hlc')));

    final statusRows = await db.query(
      'SELECT outcome FROM migration_status WHERE migration_id = ?1 AND device_id = ?2',
      [logRows.first['id'], deviceId],
    );
    expect(statusRows, hasLength(1));
    expect(statusRows.first['outcome'], 'succeeded');
  });

  test('createTable rejects an empty display name', () async {
    expect(() => editor.createTable(displayName: '   '), throwsArgumentError);
  });

  test('createTable de-duplicates a colliding identifier with a numeric suffix', () async {
    final first = await createTestTable('SETV2 Dedup Source');
    final second = await createTestTable('SETV2 Dedup Source');
    expect(second, '${first}_2');
    expect(first, isNot(second));
  });

  test('addField adds a physical TEXT column and a matching field_definitions row', () async {
    final tableName = await createTestTable('SETV2 Add Field Basic');
    await editor.addField(
      tableName: tableName,
      displayName: 'Notes',
      format: 'text',
    );

    final columns = await db.query('PRAGMA table_info("$tableName")');
    final notesColumn = columns.firstWhere((c) => c['name'] == 'notes');
    expect(notesColumn['type'], 'TEXT');

    final fieldRows = await db.query(
      'SELECT * FROM field_definitions WHERE table_name = ?1 AND field_name = ?2 AND is_deleted = 0',
      [tableName, 'notes'],
    );
    expect(fieldRows, hasLength(1));
    expect(fieldRows.first['display_name'], 'Notes');
    expect(fieldRows.first['format'], 'text');
    expect(fieldRows.first['required'], 0);
  });

  test('addField on a required field with no default is rejected before any write happens', () async {
    final tableName = await createTestTable('SETV2 Required No Default');
    await expectLater(
      () => editor.addField(tableName: tableName, displayName: 'Status', format: 'text', required: true),
      throwsArgumentError,
    );

    final columns = await db.query('PRAGMA table_info("$tableName")');
    expect(columns.any((c) => c['name'] == 'status'), isFalse);
  });

  test('addField against a table that does not exist is rejected', () async {
    expect(
      () => editor.addField(tableName: 'no_such_table_at_all', displayName: 'Notes', format: 'text'),
      throwsArgumentError,
    );
  });

  test('addField assigns increasing position values per table', () async {
    final tableName = await createTestTable('SETV2 Field Positions');
    await editor.addField(tableName: tableName, displayName: 'First', format: 'text');
    await editor.addField(tableName: tableName, displayName: 'Second', format: 'text');

    final rows = await db.query(
      'SELECT field_name, position FROM field_definitions WHERE table_name = ?1 ORDER BY position',
      [tableName],
    );
    expect(rows.map((r) => r['field_name']), ['first', 'second']);
    expect(rows.map((r) => r['position']), [0, 1]);
  });
}
