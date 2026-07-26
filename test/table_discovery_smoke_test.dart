// Proves the table discovery mechanism (CLAUDE.md "Table Discovery phase",
// Part A/B) against the REAL essentials.db -- run with `flutter test
// test/table_discovery_smoke_test.dart`.
//
// Deliberately NOT a mocked/isolated unit test: creates a genuinely new
// table directly via SQL (same as Letos/DBeaver would), confirms
// TableDiscoveryService introspects it into a sensible TableConfig with
// zero hand-written config, confirms a field_metadata override row changes
// the derived result, then drops the table and confirms discovery and
// field_metadata cleanup both notice. Runs under `flutter test` rather than
// plain `dart run` (see tool/smoke_test.dart for that lighter pattern)
// because TableDiscoveryService pulls in DatabaseHelper, which pulls in
// permission_handler -> package:flutter -> dart:ui -- unavailable outside a
// Flutter test/app host. Everything this test creates is removed in
// tearDown, including on assertion failure, so a failed run never leaves
// debris in the real db.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/field_metadata_dao.dart';
import 'package:essentials_app/db/table_discovery_service.dart';
import 'package:essentials_app/models/table_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

const String _testTable = 'discovery_smoke_test_widget';
const String _uniqueTestTable = 'discovery_smoke_test_unique';

void main() {
  late Database db;
  final discovery = TableDiscoveryService();
  final fieldMetadata = FieldMetadataDao();

  setUpAll(() async {
    db = await DatabaseHelper.instance.database;
  });

  tearDown(() async {
    // Idempotent -- safe even if a test already dropped/deleted these.
    await db.execute('DROP TABLE IF EXISTS $_testTable');
    await fieldMetadata.deleteForTable(_testTable);
    await db.execute('DROP TABLE IF EXISTS $_uniqueTestTable');
    await fieldMetadata.deleteForTable(_uniqueTestTable);
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  test('discovery finds a new table and excludes infra tables', () async {
    await _createTestTable(db);

    final tables = await discovery.discoverTableNames();
    expect(tables, contains(_testTable));
    for (final infra in infraTables) {
      expect(tables, isNot(contains(infra)), reason: 'infra table $infra must never be discovered');
    }
  });

  test('zero-config introspection derives a sensible TableConfig', () async {
    await _createTestTable(db);

    final config = await discovery.buildConfig(_testTable);
    expect(config.displayColumn, 'name');
    expect(config.orderBy, 'position, name', reason: 'has a position column, so it should drive orderBy');

    final byColumn = {for (final f in config.fields) f.column: f};
    expect(byColumn.containsKey('id'), isFalse, reason: 'id must never become a FieldConfig');

    expect(byColumn['name']!.required, isTrue, reason: 'NOT NULL, no default -> required');
    expect(byColumn['name']!.label, 'Name');

    expect(byColumn['active']!.type, FieldType.boolean, reason: 'INTEGER NOT NULL DEFAULT 1');
    expect(byColumn['active']!.defaultValue, true);

    expect(byColumn['color']!.isColor, isTrue);
    expect(byColumn['hyperlink']!.isLink, isTrue);
    expect(byColumn['created_date']!.type, FieldType.date);
    expect(byColumn['checkin_time']!.type, FieldType.dateTime);

    final statusId = byColumn['status_id']!;
    expect(statusId.isLookup, isTrue, reason: 'PRAGMA foreign_key_list should surface this');
    expect(statusId.lookup!.table, 'status');
    expect(statusId.lookup!.displayColumn, 'name', reason: 'status has its own name column');
    expect(statusId.label, 'Status', reason: 'FK label should strip the trailing _id');
  });

  test('field_metadata overrides win, and cleanly fall back once removed', () async {
    await _createTestTable(db);

    await fieldMetadata.upsert(
      tableName: _testTable,
      fieldName: 'description',
      displayLabel: 'Notes (overridden)',
      defaultValue: 'default note text',
    );

    final overridden = await discovery.buildConfig(_testTable);
    final description = overridden.fields.firstWhere((f) => f.column == 'description');
    expect(description.label, 'Notes (overridden)');
    expect(description.defaultValue, 'default note text');

    await fieldMetadata.deleteForTable(_testTable);
    final fallenBack = await discovery.buildConfig(_testTable);
    final descriptionAfter = fallenBack.fields.firstWhere((f) => f.column == 'description');
    expect(descriptionAfter.label, 'Description', reason: 'removing the override should restore the heuristic');
  });

  test('a single-column UNIQUE text field wins the displayColumn heuristic over the bare id', () async {
    await db.execute('DROP TABLE IF EXISTS $_uniqueTestTable');
    await db.execute('''
      CREATE TABLE $_uniqueTestTable (
        id            INTEGER UNIQUE NOT NULL DEFAULT (
          CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
          + (abs(random()) % 1000)
        ),
        code          TEXT UNIQUE,
        description   TEXT
      )
    ''');
    // No `name` column and no `NOT NULL` column at all (both `code` and
    // `description` are nullable) -- same shape `orders`/`order_items`
    // actually hit this session. Before this heuristic existed, this would
    // fall all the way through to the bare `id`.
    final config = await discovery.buildConfig(_uniqueTestTable);
    expect(config.displayColumn, 'code');
    expect(
      config.fields.any((f) => f.column == 'id'),
      isFalse,
      reason: 'id must never become a FieldConfig, even with the new id-by-name pk fallback',
    );
  });

  test('dropping the table removes it from discovery; field_metadata is left orphaned for cleanup', () async {
    await _createTestTable(db);
    await fieldMetadata.upsert(tableName: _testTable, fieldName: 'description');

    await db.execute('DROP TABLE $_testTable');

    expect(await discovery.tableExists(_testTable), isFalse);
    expect(await discovery.discoverTableNames(), isNot(contains(_testTable)));

    // SQLite doesn't cascade-clean field_metadata for us (it's this app's
    // own table, not FK-linked to sqlite_master) -- confirms the orphan is
    // genuinely there, which is exactly what the startup orphan-cleanup
    // pass (CLAUDE.md Part D) is meant to find and delete.
    expect(await fieldMetadata.allTableNames(), contains(_testTable));
  });
}

Future<void> _createTestTable(Database db) async {
  await db.execute('DROP TABLE IF EXISTS $_testTable');
  await db.execute('''
    CREATE TABLE $_testTable (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      name          TEXT NOT NULL UNIQUE,
      description   TEXT,
      active        INTEGER NOT NULL DEFAULT 1,
      position      INTEGER,
      color         TEXT,
      status_id     INTEGER REFERENCES status(id) ON DELETE RESTRICT,
      created_date  TEXT,
      checkin_time  TEXT,
      hyperlink     TEXT
    )
  ''');
  await db.insert(_testTable, {
    'name': 'Test Row',
    'description': 'created by table_discovery_smoke_test.dart',
    'status_id': null,
  });
}
