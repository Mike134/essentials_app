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
import 'package:sqflite/sqflite.dart';

const String _oldSchemeTable = 'insert_id_test_old_scheme';
const String _newSchemeTable = 'insert_id_test_new_scheme';

void main() {
  late Database db;

  setUpAll(() async {
    db = await DatabaseHelper.instance.database;
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
      displayColumn: 'name',
      fields: const [FieldConfig(column: 'name', label: 'Name')],
    );
    final dao = GenericDao(config);

    final id = await dao.insert({'name': 'first'});
    final row = (await db.query(_oldSchemeTable, where: 'name = ?', whereArgs: ['first'])).single;
    expect(id, row['id']);
  });

  test(
    'new scheme (id INTEGER UNIQUE NOT NULL DEFAULT timestamp+random, not PRIMARY KEY): '
    'insert() returns the real id, not the internal rowid',
    () async {
      await db.execute('''
        CREATE TABLE $_newSchemeTable (
          id INTEGER UNIQUE NOT NULL DEFAULT (
              CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
              + (abs(random()) % 1000)
          ),
          name TEXT NOT NULL
        )
      ''');
      final config = TableConfig(
        tableName: _newSchemeTable,
        displayColumn: 'name',
        fields: const [FieldConfig(column: 'name', label: 'Name')],
      );
      final dao = GenericDao(config);

      // Insert a second, unrelated row first so this table's internal
      // rowid and its DEFAULT-generated id are guaranteed to diverge
      // (rowid starts at 1, id is a ~16-digit timestamp) -- if insert()
      // were still returning Database.insert()'s raw rowid, this would
      // fail obviously rather than by coincidence matching.
      await dao.insert({'name': 'zeroth'});

      final id = await dao.insert({'name': 'genuinely new'});
      expect(id, greaterThan(1000000000000000), reason: 'should be the large DEFAULT-generated id, not a small rowid');

      final row = (await db.query(
        _newSchemeTable,
        where: 'name = ?',
        whereArgs: ['genuinely new'],
      )).single;
      expect(id, row['id']);
    },
  );
}
