// Proves Part D of CLAUDE.md's "Table Discovery phase" against the REAL
// essentials.db -- run with `flutter test test/table_deletion_handling_test.dart`.
//
// Deliberately uses throwaway parent/child tables for the RESTRICT/DROP
// proof rather than a real lookup table like `class` -- an unexpected
// result (FK enforcement silently not applying) would mean an actual
// DROP TABLE succeeding against live, Syncthing-synced data, which is
// exactly the kind of hard-to-reverse mistake CLAUDE.md's incident writeup
// (the empty-db-over-Syncthing incident) already warns about. Same SQLite
// mechanism either way -- ON DELETE RESTRICT is enforced identically
// regardless of which table it's declared on -- so this proves the real
// behavior without any risk to real data.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/field_metadata_dao.dart';
import 'package:essentials_app/db/orphan_cleanup_service.dart';
import 'package:essentials_app/db/table_discovery_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

const String _parentTable = 'deletion_test_parent';
const String _childTable = 'deletion_test_child';
const String _lonelyTable = 'deletion_test_lonely';

void main() {
  late Database db;
  final discovery = TableDiscoveryService();
  final fieldMetadata = FieldMetadataDao();

  setUpAll(() async {
    db = await DatabaseHelper.instance.database;
  });

  tearDown(() async {
    // FK-respecting drop order: child before parent. IF EXISTS makes this
    // idempotent regardless of which step in a test actually ran.
    await db.execute('DROP TABLE IF EXISTS $_childTable');
    await db.execute('DROP TABLE IF EXISTS $_parentTable');
    await db.execute('DROP TABLE IF EXISTS $_lonelyTable');
    for (final t in [_parentTable, _childTable, _lonelyTable]) {
      await fieldMetadata.deleteForTable(t);
      await db.delete('table_column_settings', where: 'table_name = ?', whereArgs: [t]);
      await db.delete('table_view_settings', where: 'table_name = ?', whereArgs: [t]);
      await db.delete('table_group', where: 'table_name = ?', whereArgs: [t]);
    }
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  test('PRAGMA foreign_keys is genuinely on for this connection', () async {
    final rows = await db.rawQuery('PRAGMA foreign_keys');
    expect(rows.first.values.first, 1);
  });

  test('DROP TABLE on a RESTRICT-referenced table fails while a child row exists', () async {
    await db.execute('''
      CREATE TABLE $_parentTable (
        id   INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE $_childTable (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        parent_id INTEGER REFERENCES $_parentTable(id) ON DELETE RESTRICT
      )
    ''');
    final parentId = await db.insert(_parentTable, {'name': 'still referenced'});
    await db.insert(_childTable, {'parent_id': parentId});

    // SQLite's documented behavior (CLAUDE.md Part D): an implicit DELETE
    // runs against every row before a DROP TABLE, and a RESTRICT violation
    // during that implicit delete blocks the whole statement -- confirmed
    // directly here, not just trusted from the docs.
    await expectLater(
      () => db.execute('DROP TABLE $_parentTable'),
      throwsA(
        isA<DatabaseException>().having(
          (e) => e.toString().toLowerCase(),
          'message',
          contains('foreign key constraint failed'),
        ),
      ),
    );

    // And the table is genuinely still there, not half-dropped.
    expect(await discovery.tableExists(_parentTable), isTrue);
  });

  test('DROP TABLE on a table nothing references succeeds cleanly', () async {
    await db.execute('CREATE TABLE $_lonelyTable (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)');
    expect(await discovery.tableExists(_lonelyTable), isTrue);

    await db.execute('DROP TABLE $_lonelyTable');

    expect(await discovery.tableExists(_lonelyTable), isFalse);
    expect(await discovery.discoverTableNames(), isNot(contains(_lonelyTable)));
  });

  test('orphan cleanup removes settings rows for a dropped table, leaves live ones alone', () async {
    await db.execute('CREATE TABLE $_lonelyTable (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)');

    // Seed one orphan-to-be row in each of the four settings tables, plus a
    // control row for a table that stays alive (`domain`, a real table
    // that will never be dropped by this test) to prove cleanup doesn't
    // touch anything it shouldn't.
    await db.insert('table_column_settings', {
      'table_name': _lonelyTable,
      'device_id': 'test-device',
      'column_name': 'name',
    });
    await db.insert('table_view_settings', {
      'table_name': _lonelyTable,
      'device_id': 'test-device',
    });
    await db.insert('table_group', {
      'table_name': _lonelyTable,
      'group_name': 'Test Group',
    });
    await fieldMetadata.upsert(tableName: _lonelyTable, fieldName: 'name', displayLabel: 'Orphan Name');

    const controlDeviceId = 'test-device-control';
    await db.insert('table_column_settings', {
      'table_name': 'domain',
      'device_id': controlDeviceId,
      'column_name': 'name',
    });

    await db.execute('DROP TABLE $_lonelyTable');

    final orphaned = await OrphanCleanupService(discovery: discovery).cleanupOrphans();
    expect(orphaned, contains(_lonelyTable));

    for (final settingsTable in [
      'table_column_settings',
      'table_view_settings',
      'table_group',
    ]) {
      final remaining = await db.query(
        settingsTable,
        where: 'table_name = ?',
        whereArgs: [_lonelyTable],
      );
      expect(remaining, isEmpty, reason: '$settingsTable should have no rows left for $_lonelyTable');
    }
    expect((await fieldMetadata.loadForTable(_lonelyTable)), isEmpty);

    // The control row for the still-live `domain` table must survive.
    final domainRows = await db.query(
      'table_column_settings',
      where: 'table_name = ? AND device_id = ?',
      whereArgs: ['domain', controlDeviceId],
    );
    expect(domainRows, hasLength(1));
    await db.delete(
      'table_column_settings',
      where: 'table_name = ? AND device_id = ?',
      whereArgs: ['domain', controlDeviceId],
    );
  });
}
