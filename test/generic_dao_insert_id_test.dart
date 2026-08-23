// Proves GenericDao.insert() returns the real `id` column value under both
// id schemes this app now has live (CLAUDE.md "id convention changed") --
// motivated by converting journal/shipment/subscription to the newer
// timestamp+random scheme this session. Run with
// `flutter test test/generic_dao_insert_id_test.dart`.
//
// Deliberately uses throwaway tables (same reasoning as
// table_deletion_handling_test.dart) rather than inserting real rows into
// journal/shipment/subscription themselves.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/models/table_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

const String _oldSchemeTable = 'insert_id_test_old_scheme';
const String _newSchemeTable = 'insert_id_test_new_scheme';

void main() {
  late SqliteCrdt db;

  setUpAll(() async {
    db = await DatabaseHelper.instance.crdt;
  });

  tearDown(() async {
    await db.execute('DROP TABLE IF EXISTS $_oldSchemeTable');
    await db.execute('DROP TABLE IF EXISTS $_newSchemeTable');
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  test('old scheme (id INTEGER PRIMARY KEY AUTOINCREMENT): insert() returns the real id', () async {
    await db.execute('''
      CREATE TABLE $_oldSchemeTable (
        id   INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
    ''');
    final config = TableConfig(
      tableName: _oldSchemeTable,
      displayName: 'Old Scheme',
      displayColumn: 'name',
      fields: const [FieldConfig(column: 'name', label: 'Name')],
    );
    final dao = GenericDao(config);

    final id = await dao.insert({'name': 'first'});
    final row =
        (await db.query('SELECT * FROM $_oldSchemeTable WHERE name = ?1', ['first'])).single;
    expect(id, row['id']);
  });

  test(
    'new scheme (id INTEGER PRIMARY KEY DEFAULT timestamp+random -- see migrations/005): '
    'insert() returns the real id',
    () async {
      await db.execute('''
        CREATE TABLE $_newSchemeTable (
          id INTEGER PRIMARY KEY DEFAULT (
              CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
              + (abs(random()) % 1000)
          ),
          name TEXT NOT NULL
        )
      ''');
      final config = TableConfig(
        tableName: _newSchemeTable,
        displayName: 'New Scheme',
        displayColumn: 'name',
        fields: const [FieldConfig(column: 'name', label: 'Name')],
      );
      final dao = GenericDao(config);

      // Insert a second, unrelated row first so this table's internal
      // rowid and its DEFAULT-generated id are guaranteed to diverge if
      // insert() were ever wrong about which one it returns -- rowid
      // starts at 1, id is a ~16-digit timestamp, but since id is now a
      // rowid alias (unlike the pre-migrations/005 scheme) they're
      // actually the same value; this still proves insert() reads back
      // the real generated id rather than assuming any particular scheme.
      await dao.insert({'name': 'zeroth'});

      final id = await dao.insert({'name': 'genuinely new'});
      expect(id, greaterThan(1000000000000000), reason: 'should be the large DEFAULT-generated id');

      final row = (await db.query(
        'SELECT * FROM $_newSchemeTable WHERE name = ?1',
        ['genuinely new'],
      )).single;
      expect(id, row['id']);
    },
  );

  test(
    'old scheme, zero explicit field values: insert({}) still works (SQLite auto-assigns id)',
    () async {
      // Real gap found live, Essentials v2 Phase 1 Step 6
      // (generic_dao_linked_fields_test.dart's fieldless parent tables) --
      // no v1 table ever had zero FieldConfig entries, so insert({}) was
      // never actually exercised before. The old string-concatenation
      // build ('id, ' + '' or '' + '') produced invalid SQL
      // ("INSERT INTO t (id, ) VALUES ((expr), )") whenever `values` was
      // empty.
      await db.execute('CREATE TABLE $_oldSchemeTable (id INTEGER PRIMARY KEY AUTOINCREMENT)');
      final config = TableConfig(
        tableName: _oldSchemeTable,
        displayName: 'Old Scheme',
        displayColumn: 'id',
        fields: const [],
      );
      final dao = GenericDao(config);

      final id = await dao.insert({});
      final row = (await db.query('SELECT * FROM $_oldSchemeTable WHERE id = ?1', [id])).single;
      expect(id, row['id']);
    },
  );

  test(
    'new scheme, zero explicit field values: insert({}) still injects the real id DEFAULT',
    () async {
      await db.execute('''
        CREATE TABLE $_newSchemeTable (
          id INTEGER PRIMARY KEY DEFAULT (
              CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
              + (abs(random()) % 1000)
          )
        )
      ''');
      final config = TableConfig(
        tableName: _newSchemeTable,
        displayName: 'New Scheme',
        displayColumn: 'id',
        fields: const [],
      );
      final dao = GenericDao(config);

      final id = await dao.insert({});
      expect(id, greaterThan(1000000000000000), reason: 'should be the large DEFAULT-generated id, not a small rowid');

      final row = (await db.query('SELECT * FROM $_newSchemeTable WHERE id = ?1', [id])).single;
      expect(id, row['id']);
    },
  );
}
