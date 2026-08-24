// Proves SearchIndexService end to end through the REAL pipeline --
// SchemaEditorService.createTable/addField -> SchemaRegistry.buildConfig
// -> GenericDao.insert/update/delete (which themselves call into
// SearchIndexService, per Essentials v2 Phase 6's build order step 4) ->
// SearchIndexService.search -- against the real essentials.db and its
// sibling search_index.db (see DatabaseHelper.resolveSearchIndexDatabasePath
// for why search_index lives in its own separate file, not a table inside
// essentials.db).
//
// **Run this file on its own** -- `flutter test test/search_index_service_test.dart`
// -- never chained with other schema-engine test files. See CLAUDE.md
// "Essentials v2 Phase 1 -- Step 3"/the real-device verification session
// for why (chained invocations silently fail cleanup, leaking physical
// tables to every device; and widget_test.dart opens a real sync
// connection).
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/schema_registry.dart';
import 'package:essentials_app/db/search_index_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

import 'support/schema_test_cleanup.dart';

void main() {
  late ffi.Database indexDb;
  final editor = SchemaEditorService();
  final registry = SchemaRegistry();
  final metadata = SchemaMetadataDao();
  final search = SearchIndexService();
  final runTag = DateTime.now().microsecondsSinceEpoch;

  setUpAll(() async {
    await DatabaseHelper.instance.crdt; // ensures essentials.db opens cleanly before anything else.
    await search.ensureIndexTable();
    // A second, independent plain connection to search_index's own file --
    // used only to make raw assertions the public SearchIndexService API
    // doesn't otherwise expose (row counts, physical existence).
    final path = await DatabaseHelper.instance.resolveSearchIndexDatabasePath();
    indexDb = await ffi.databaseFactoryFfi.openDatabase(path);
  });

  tearDownAll(() async {
    await indexDb.close();
    await DatabaseHelper.instance.close();
  });

  test('ensureIndexTable is idempotent -- safe to call repeatedly', () async {
    await search.ensureIndexTable();
    await search.ensureIndexTable();
    final rows = await indexDb.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'search_index'",
    );
    expect(rows, hasLength(1));
  });

  test('GenericDao.insert indexes a mixed-format table with only the eligible fields', () async {
    final tableName = await editor.createTable(displayName: 'Search Mixed $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Name', format: 'text');
    await editor.addField(tableName: tableName, displayName: 'Cost', format: 'currency');
    await editor.addField(
      tableName: tableName,
      displayName: 'Site',
      format: 'text',
      optionsJson: '{"isLink": true}',
    );

    final config = await registry.buildConfig(tableName);
    await GenericDao(config).insert({
      'name': 'Acme Rope Company',
      'cost': '19.99',
      'site': 'https://acme.example',
    });

    final results = await search.search('Acme');
    expect(results, hasLength(1));
    expect(results.single.tableName, tableName);
    // The currency field's raw value ("19.99") must NOT have leaked into
    // the index -- confirmed by searching for it and finding nothing.
    final costResults = await search.search('19.99');
    expect(costResults, isEmpty);
    // The url field IS eligible and should be searchable.
    final siteResults = await search.search('acme.example');
    expect(siteResults, hasLength(1));
  });

  test('reindexRecord is idempotent -- no duplicate rows on a second call', () async {
    final tableName = await editor.createTable(displayName: 'Search Idempotent $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
    final config = await registry.buildConfig(tableName);
    final id = await GenericDao(config).insert({'notes': 'Widget Traders Inc'});

    await search.reindexRecord(tableName, id);
    await search.reindexRecord(tableName, id);

    final rows = await indexDb.rawQuery(
      'SELECT COUNT(*) AS c FROM search_index WHERE table_name = ? AND record_id = ?',
      [tableName, id],
    );
    expect(rows.single['c'], 1);
  });

  test('update re-indexes the new content and drops the old', () async {
    final tableName = await editor.createTable(displayName: 'Search Update $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);
    final id = await dao.insert({'notes': 'original phrasing'});
    expect(await search.search('original'), hasLength(1));

    await dao.update(id, {'notes': 'revised phrasing'});

    expect(await search.search('original'), isEmpty);
    expect(await search.search('revised'), hasLength(1));
  });

  test('delete removes the record from the index', () async {
    final tableName = await editor.createTable(displayName: 'Search Delete $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);
    final id = await dao.insert({'notes': 'ephemeral record'});
    expect(await search.search('ephemeral'), hasLength(1));

    await dao.delete(id);

    expect(await search.search('ephemeral'), isEmpty);
  });

  test('reindexTable rebuilds a whole table from scratch', () async {
    final tableName = await editor.createTable(displayName: 'Search Reindex Table $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);
    await dao.insert({'notes': 'first row'});
    await dao.insert({'notes': 'second row'});

    await search.reindexTable(tableName);

    final rows = await indexDb.rawQuery(
      'SELECT COUNT(*) AS c FROM search_index WHERE table_name = ?',
      [tableName],
    );
    expect(rows.single['c'], 2);
  });

  test('reindexAll rebuilds every table\'s index', () async {
    final tableName = await editor.createTable(displayName: 'Search Reindex All $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
    final config = await registry.buildConfig(tableName);
    await GenericDao(config).insert({'notes': 'reachable via reindexAll'});

    await search.reindexAll();

    final results = await search.search('reachable');
    expect(results, hasLength(1));
    expect(results.single.tableName, tableName);
  });

  test('an empty or whitespace-only query returns nothing', () async {
    expect(await search.search(''), isEmpty);
    expect(await search.search('   '), isEmpty);
  });

  test('search returns a real snippet with match markers', () async {
    final tableName = await editor.createTable(displayName: 'Search Snippet $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
    final config = await registry.buildConfig(tableName);
    await GenericDao(config).insert({'notes': 'a distinctive phrase here'});

    final results = await search.search('distinctive');
    expect(results, hasLength(1));
    expect(results.single.snippet, contains('**distinctive**'));
  });

  test('a query containing special FTS5 characters is treated as literal text', () async {
    final tableName = await editor.createTable(displayName: 'Search Special Chars $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
    final config = await registry.buildConfig(tableName);
    await GenericDao(config).insert({'notes': 'contact-me@example.com'});

    // A bare leading "-" is FTS5's NOT operator if left unquoted -- this
    // must not throw or silently match nothing.
    final results = await search.search('contact-me@example.com');
    expect(results, hasLength(1));
  });

  test('cleanupOrphans removes rows for a table that has been permanently dropped', () async {
    final tableName = await editor.createTable(displayName: 'Search Orphan $runTag');
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
    final config = await registry.buildConfig(tableName);
    await GenericDao(config).insert({'notes': 'orphaned by a real drop'});
    expect(await search.search('orphaned'), hasLength(1));

    // Dropped for real, mid-test -- not via addTearDown, since the whole
    // point is exercising cleanupOrphans against a table that's actually
    // gone by the time it runs.
    await metadata.softDeleteTable(tableName);
    await editor.dropTable(tableName);

    final orphaned = await search.cleanupOrphans();
    expect(orphaned, contains(tableName));

    final rows = await indexDb.rawQuery(
      'SELECT COUNT(*) AS c FROM search_index WHERE table_name = ?',
      [tableName],
    );
    expect(rows.single['c'], 0);
  });

  test('cleanupOrphans leaves a live table\'s rows untouched', () async {
    final tableName = await editor.createTable(displayName: 'Search Not Orphan $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
    final config = await registry.buildConfig(tableName);
    await GenericDao(config).insert({'notes': 'still very much alive'});

    final orphaned = await search.cleanupOrphans();
    expect(orphaned, isNot(contains(tableName)));
    expect(await search.search('alive'), hasLength(1));
  });

  test(
    'cleanupOrphans leaves a stage-1 soft-deleted (but not yet permanently dropped) '
    'table\'s rows untouched',
    () async {
      final tableName = await editor.createTable(displayName: 'Search Soft Deleted $runTag');
      addTearDown(() => dropTestTable(editor, metadata, tableName));
      await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
      final config = await registry.buildConfig(tableName);
      await GenericDao(config).insert({'notes': 'recoverable, not gone'});

      // Stage 1 only -- SchemaRegistry.discoverTableNames excludes it (same
      // as real nav would), but the physical table/data is still there and
      // fully restorable.
      await metadata.softDeleteTable(tableName);

      final orphaned = await search.cleanupOrphans();
      expect(orphaned, isNot(contains(tableName)));

      final rows = await indexDb.rawQuery(
        'SELECT COUNT(*) AS c FROM search_index WHERE table_name = ?',
        [tableName],
      );
      expect(rows.single['c'], 1, reason: 'a merely-soft-deleted table is not an orphan');

      // Restore so this test's own addTearDown (a real dropTestTable call)
      // can find it stage-1-eligible again, matching that helper's own
      // expectations.
      await metadata.restoreTable(tableName);
    },
  );

  test('search_index.db is a genuinely separate file from essentials.db', () async {
    final essentialsPath = await DatabaseHelper.instance.resolveDatabasePath();
    final searchIndexPath = await DatabaseHelper.instance.resolveSearchIndexDatabasePath();
    expect(searchIndexPath, isNot(essentialsPath));

    // essentials.db's own sqlite_master must never contain search_index --
    // the whole point of the separate-file design (see this file's own
    // header comment for the real incident that made this non-negotiable).
    final crdt = await DatabaseHelper.instance.crdt;
    final rows = await crdt.query(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'search_index%'",
    );
    expect(rows, isEmpty);
  });
}
