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
//
// Note: this proves RESTRICT still fires for a genuine DROP TABLE (which
// SQLite implements as an implicit DELETE of every row, a real DELETE
// statement, unlike crdt.execute()'s soft-delete rewrite for a plain
// DELETE -- see CLAUDE.md "Syncing at the Record Level"). It intentionally
// uses db.execute() directly for DROP TABLE, not GenericDao.delete(), since
// DROP TABLE isn't something GenericDao ever does.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/field_metadata_dao.dart';
import 'package:essentials_app/db/orphan_cleanup_service.dart';
import 'package:essentials_app/db/sql_helpers.dart';
import 'package:essentials_app/db/table_discovery_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

const String _parentTable = 'deletion_test_parent';
const String _childTable = 'deletion_test_child';
const String _lonelyTable = 'deletion_test_lonely';

void main() {
  late SqliteCrdt db;
  final discovery = TableDiscoveryService();
  final fieldMetadata = FieldMetadataDao();

  setUpAll(() async {
    db = await DatabaseHelper.instance.crdt;
  });

  tearDown(() async {
    // FK-respecting drop order: child before parent. IF EXISTS makes this
    // idempotent regardless of which step in a test actually ran.
    await db.execute('DROP TABLE IF EXISTS $_childTable');
    await db.execute('DROP TABLE IF EXISTS $_parentTable');
    await db.execute('DROP TABLE IF EXISTS $_lonelyTable');
    for (final t in [_parentTable, _childTable, _lonelyTable]) {
      await fieldMetadata.deleteForTable(t);
      await db.deleteWhere('table_column_settings', {'table_name': t});
      await db.deleteWhere('table_view_settings', {'table_name': t});
      await db.deleteWhere('table_group', {'table_name': t});
    }
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  test('PRAGMA foreign_keys is genuinely on for this connection', () async {
    final rows = await db.query('PRAGMA foreign_keys');
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
    final parentId = await db.insertGetId(_parentTable, {'name': 'still referenced'});
    await db.insertGetId(_childTable, {'parent_id': parentId});

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
    //
    // Uses upsert (matching how TableViewSettingsDao/SidebarGroupingDao
    // actually write these tables in production), not a plain insert --
    // deleteWhere() only soft-deletes (see CLAUDE.md "Syncing at the
    // Record Level"), so a tombstoned row from a previous run of this same
    // test would still occupy its UNIQUE slot and a plain INSERT would
    // fail with a UNIQUE constraint violation on a re-run.
    await db.upsert('table_column_settings', {
      'table_name': _lonelyTable,
      'device_id': 'test-device',
      'column_name': 'name',
    });
    await db.upsert('table_view_settings', {
      'table_name': _lonelyTable,
      'device_id': 'test-device',
    });
    await db.upsert('table_group', {
      'table_name': _lonelyTable,
      'group_name': 'Test Group',
    });
    await fieldMetadata.upsert(tableName: _lonelyTable, fieldName: 'name', displayLabel: 'Orphan Name');

    const controlDeviceId = 'test-device-control';
    await db.upsert('table_column_settings', {
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
        'SELECT * FROM $settingsTable WHERE table_name = ?1 AND is_deleted = 0',
        [_lonelyTable],
      );
      expect(remaining, isEmpty, reason: '$settingsTable should have no rows left for $_lonelyTable');
    }
    expect((await fieldMetadata.loadForTable(_lonelyTable)), isEmpty);

    // The control row for the still-live `domain` table must survive.
    final domainRows = await db.query(
      'SELECT * FROM table_column_settings WHERE table_name = ?1 AND device_id = ?2 AND is_deleted = 0',
      ['domain', controlDeviceId],
    );
    expect(domainRows, hasLength(1));
    await db.deleteWhere('table_column_settings', {'table_name': 'domain', 'device_id': controlDeviceId});
  });
}
