// Proves GenericDao.getDistinctColumnValues -- the column-autocomplete
// suggestion source, see claude/essentials-v2-column-autocomplete-design.md
// -- against the REAL essentials.db. Run with `flutter test
// test/generic_dao_autocomplete_test.dart`.
//
// Every table created through the real SchemaEditorService.createTable/
// addField pipeline; every config built through the real SchemaRegistry
// .buildConfig, exactly as GenericFormScreen/GenericListScreen would. Same
// per-run-unique-tag/tombstone-only-cleanup discipline as the other v2 test
// files -- see CLAUDE.md "Essentials v2 Phase 1 -- Step 3" for why.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/schema_registry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/schema_test_cleanup.dart';

void main() {
  final editor = SchemaEditorService();
  final registry = SchemaRegistry();
  final metadata = SchemaMetadataDao();
  final runTag = DateTime.now().microsecondsSinceEpoch;

  setUpAll(() async {
    await DatabaseHelper.instance.crdt;
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  Future<String> createTestTable(String label) async {
    final tableName = await editor.createTable(displayName: '$label $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'City', format: 'text');
    return tableName;
  }

  Future<GenericDao> daoFor(String tableName) async {
    final config = await registry.buildConfig(tableName);
    return GenericDao(config);
  }

  test('empty table returns no suggestions', () async {
    final table = await createTestTable('GDA Empty');
    final dao = await daoFor(table);
    final values = await dao.getDistinctColumnValues(table, 'city');
    expect(values, isEmpty);
  });

  test('prefix match, case-insensitive, alphabetical, distinct', () async {
    final table = await createTestTable('GDA Prefix');
    final dao = await daoFor(table);
    for (final city in ['Seattle', 'seattle', 'San Diego', 'Portland']) {
      await dao.insert({'city': city});
    }

    final values = await dao.getDistinctColumnValues(table, 'city', prefix: 'se');
    expect(values, ['Seattle', 'seattle']);

    final none = await dao.getDistinctColumnValues(table, 'city', prefix: 'zz');
    expect(none, isEmpty);
  });

  test('excludes values that only exist on soft-deleted rows', () async {
    final table = await createTestTable('GDA SoftDeleted');
    final dao = await daoFor(table);
    final id = await dao.insert({'city': 'Denver'});
    await dao.delete(id);

    final values = await dao.getDistinctColumnValues(table, 'city', prefix: 'den');
    expect(values, isEmpty);
  });

  test('a value still live on another row is unaffected by an unrelated soft-delete', () async {
    final table = await createTestTable('GDA SoftDeleted Other Row');
    final dao = await daoFor(table);
    await dao.insert({'city': 'Denver'});
    final secondId = await dao.insert({'city': 'Denver'});
    await dao.delete(secondId);

    final values = await dao.getDistinctColumnValues(table, 'city', prefix: 'den');
    expect(values, ['Denver']);
  });

  test('respects excludeValue -- the value already in the cell is not suggested back', () async {
    final table = await createTestTable('GDA ExcludeValue');
    final dao = await daoFor(table);
    await dao.insert({'city': 'Austin'});
    await dao.insert({'city': 'Atlanta'});

    final withExclude = await dao.getDistinctColumnValues(
      table,
      'city',
      prefix: 'a',
      excludeValue: 'Austin',
    );
    expect(withExclude, ['Atlanta']);

    final withoutExclude = await dao.getDistinctColumnValues(table, 'city', prefix: 'a');
    expect(withoutExclude, ['Atlanta', 'Austin']);
  });

  test('respects limit', () async {
    final table = await createTestTable('GDA Limit');
    final dao = await daoFor(table);
    for (final city in ['Alpha', 'Bravo', 'Charlie', 'Delta']) {
      await dao.insert({'city': city});
    }

    final values = await dao.getDistinctColumnValues(table, 'city', limit: 2);
    expect(values, hasLength(2));
  });

  test('blank/null values are never suggested', () async {
    final table = await createTestTable('GDA Blank');
    final dao = await daoFor(table);
    await dao.insert({'city': ''});
    await dao.insert({'city': null});
    await dao.insert({'city': 'Miami'});

    final values = await dao.getDistinctColumnValues(table, 'city');
    expect(values, ['Miami']);
  });
}
