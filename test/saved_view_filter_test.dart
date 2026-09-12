// Proves the standalone Calendar Filter Set evaluator
// (lib/util/saved_view_filter.dart) against the REAL essentials.db --
// every table/field created through the real SchemaEditorService
// pipeline, exactly like every other v2 schema-engine test file. Run with
// `flutter test test/saved_view_filter_test.dart` -- never chained with
// another SchemaEditorService.createTable-using test file in the same
// invocation, per the standing rule from the Step 3 incident (see
// CLAUDE.md "Essentials v2 Phase 1 -- Step 3").
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/schema_registry.dart';
import 'package:essentials_app/models/table_config.dart';
import 'package:essentials_app/util/saved_view_data.dart';
import 'package:essentials_app/util/saved_view_filter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trina_grid/trina_grid.dart';

import 'support/schema_test_cleanup.dart';

void main() {
  final editor = SchemaEditorService();
  final registry = SchemaRegistry();
  final metadata = SchemaMetadataDao();
  final runTag = DateTime.now().microsecondsSinceEpoch;

  late TableConfig config;
  late SavedViewData data;
  late Map<String, Object?> openRowLowScore;
  late Map<String, Object?> openRowHighScore;
  late Map<String, Object?> closedRow;

  setUpAll(() async {
    final statusTable = await editor.createTable(displayName: 'SVF Status $runTag');
    addTearDown(() => dropTestTable(editor, metadata, statusTable));
    await editor.addField(tableName: statusTable, displayName: 'Name', format: 'text');
    final statusConfig = await registry.buildConfig(statusTable);
    final statusDao = GenericDao(statusConfig);
    final openId = await statusDao.insert({'name': 'Open'});
    final closedId = await statusDao.insert({'name': 'Closed'});

    final itemsTable = await editor.createTable(displayName: 'SVF Items $runTag');
    addTearDown(() => dropTestTable(editor, metadata, itemsTable));
    await editor.addField(tableName: itemsTable, displayName: 'Description', format: 'text');
    await editor.addField(tableName: itemsTable, displayName: 'Score', format: 'integer');
    await editor.addField(
      tableName: itemsTable,
      displayName: 'Status',
      format: 'select',
      optionsJson: '{"mode":"linked","table":"$statusTable"}',
    );

    config = await registry.buildConfig(itemsTable);
    final dao = GenericDao(config);
    await dao.insert({'description': 'A foo widget', 'score': 3, 'status': openId});
    await dao.insert({'description': 'A bar widget', 'score': 9, 'status': openId});
    await dao.insert({'description': 'A foo gadget', 'score': 7, 'status': closedId});

    data = await loadSavedViewData(dao, config);
    openRowLowScore = data.rows.firstWhere((r) => r['description'] == 'A foo widget');
    openRowHighScore = data.rows.firstWhere((r) => r['description'] == 'A bar widget');
    closedRow = data.rows.firstWhere((r) => r['description'] == 'A foo gadget');
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  test('no conditions matches every row', () {
    expect(rowMatchesFilterSet(config, data, openRowLowScore, const []), isTrue);
    expect(rowMatchesFilterSet(config, data, closedRow, const []), isTrue);
  });

  test('a plain-text Contains condition matches on the field\'s own value', () {
    final rows = [
      {'column': 'description', 'type': TrinaFilterTypeContains.name, 'value': 'foo'},
    ];
    expect(rowMatchesFilterSet(config, data, openRowLowScore, rows), isTrue);
    expect(rowMatchesFilterSet(config, data, openRowHighScore, rows), isFalse);
  });

  test('a linked-lookup Equals condition compares DISPLAY TEXT, not the raw id', () {
    final rows = [
      {'column': 'status', 'type': TrinaFilterTypeEquals.name, 'value': 'Open'},
    ];
    expect(rowMatchesFilterSet(config, data, openRowLowScore, rows), isTrue);
    expect(rowMatchesFilterSet(config, data, openRowHighScore, rows), isTrue);
    expect(rowMatchesFilterSet(config, data, closedRow, rows), isFalse);
  });

  test('a numeric Greater than condition is numeric-aware, not a string compare', () {
    final rows = [
      {'column': 'score', 'type': TrinaFilterTypeGreaterThan.name, 'value': '5'},
    ];
    // A plain string compare would put "3" > "5" lexicographically wrong in
    // the other direction for some values -- this asserts real numeric
    // ordering, not just "any answer that happens to look right."
    expect(rowMatchesFilterSet(config, data, openRowLowScore, rows), isFalse); // 3
    expect(rowMatchesFilterSet(config, data, openRowHighScore, rows), isTrue); // 9
    expect(rowMatchesFilterSet(config, data, closedRow, rows), isTrue); // 7
  });

  test('multiple conditions are ANDed together', () {
    final rows = [
      {'column': 'status', 'type': TrinaFilterTypeEquals.name, 'value': 'Open'},
      {'column': 'score', 'type': TrinaFilterTypeGreaterThan.name, 'value': '5'},
    ];
    expect(rowMatchesFilterSet(config, data, openRowLowScore, rows), isFalse); // Open, but score 3
    expect(rowMatchesFilterSet(config, data, openRowHighScore, rows), isTrue); // Open, score 9
    expect(rowMatchesFilterSet(config, data, closedRow, rows), isFalse); // score 7, but Closed
  });

  test('a stale/unknown column reference is skipped, not a hard failure', () {
    final rows = [
      {'column': 'no_such_column', 'type': TrinaFilterTypeEquals.name, 'value': 'anything'},
    ];
    expect(rowMatchesFilterSet(config, data, openRowLowScore, rows), isTrue);
  });

  test('an unrecognized filter type falls back to Contains, matching _filterTypesByName\'s own default', () {
    final rows = [
      {'column': 'description', 'type': 'Some Future Filter Type', 'value': 'foo'},
    ];
    expect(rowMatchesFilterSet(config, data, openRowLowScore, rows), isTrue);
    expect(rowMatchesFilterSet(config, data, openRowHighScore, rows), isFalse);
  });
}
