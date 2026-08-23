// Proves CSV import's coercion rules end to end through the REAL pipeline --
// SchemaEditorService.createTable/addField -> SchemaRegistry.buildConfig ->
// coerceCsvCell -> GenericDao.insert/getAll -- against the real
// essentials.db, the same way formula_end_to_end_test.dart proves the
// formula field. csv_import_coercion_test.dart already covers every
// per-format rule in isolation (pure Dart, no db); this file's job is only
// to confirm the pieces compose correctly against a real table -- required
// vs. optional NOT NULL enforcement, and that a coerced row round-trips
// through the same GenericDao.insert/getAll path GenericFormScreen and
// GenericListScreen already use.
//
// **Run this file on its own** -- `flutter test test/csv_import_end_to_end_test.dart`
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
import 'package:essentials_app/util/csv_import/csv_import_coercion.dart';
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

  /// A real table shaped like a small contact list -- one plain text field
  /// (required), one currency field, one boolean, and one inline-select --
  /// covering a cross-section of the coercion table, not just one format.
  Future<String> createContactTable(String label) async {
    final tableName = await editor.createTable(displayName: '$label $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(
      tableName: tableName,
      displayName: 'Name',
      format: 'text',
      required: true,
      defaultValue: '(unnamed)',
    );
    await editor.addField(tableName: tableName, displayName: 'Balance', format: 'currency');
    await editor.addField(tableName: tableName, displayName: 'Active', format: 'boolean');
    await editor.addField(
      tableName: tableName,
      displayName: 'Priority',
      format: 'select',
      optionsJson:
          '{"mode": "inline", "options": [{"key": "low", "label": "Low"}, {"key": "high", "label": "High"}]}',
    );
    return tableName;
  }

  test('a clean CSV row imports through the real pipeline', () async {
    final tableName = await createContactTable('CSV Clean');
    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);

    final csvRow = {'name': 'Alice', 'balance': r'$1,234.56', 'active': 'yes', 'priority': 'High'};
    final values = <String, Object?>{};
    for (final field in config.fields) {
      final coercion = coerceCsvCell(field, csvRow[field.column].toString());
      expect(coercion, isA<CsvCellStore>());
      values[field.column] = (coercion as CsvCellStore).value;
    }
    await dao.insert(values);

    final rows = await dao.getAll();
    final row = rows.singleWhere((r) => r['name'] == 'Alice');
    expect(row['balance'], '1234.56');
    // Every v2 column is physically TEXT (SchemaEditorService.addField),
    // so SQLite's own TEXT-affinity conversion stringifies the bound int 1
    // on the way in -- confirmed here directly rather than assumed; not a
    // CSV-import-specific quirk, the same thing happens for a hand-typed
    // form save through GenericFormScreen.
    expect(row['active'], '1');
    expect(row['priority'], 'high');
  });

  test('a required field left empty in the CSV is correctly detected as skip-worthy', () async {
    final tableName = await createContactTable('CSV RequiredMissing');
    final config = await registry.buildConfig(tableName);
    final nameField = config.fields.firstWhere((f) => f.column == 'name');

    final coercion = coerceCsvCell(nameField, '');
    expect(coercion, isA<CsvCellRequiredMissing>());

    // Confirming the *reason* this matters: a required field always has a
    // real SQL DEFAULT (SchemaEditorService.addField enforces this at
    // creation time), so *omitting* the column from an insert wouldn't
    // throw -- it would silently fall back to that default instead. What
    // actually must never happen is passing an explicit `null` for it (the
    // literal value CsvCellRequiredMissing exists to prevent an import row
    // from ever producing) -- that bypasses the DEFAULT and throws a real
    // NOT NULL violation, same as a hand-typed form save skipping
    // validation would. This is why the import screen must skip the whole
    // row instead of attempting the insert.
    final dao = GenericDao(config);
    final valuesWithExplicitNullName = <String, Object?>{
      for (final field in config.fields) field.column: null,
    };
    await expectLater(dao.insert(valuesWithExplicitNullName), throwsA(anything));
  });

  test('a malformed non-required value stores as raw text, visible not silently dropped', () async {
    final tableName = await createContactTable('CSV Malformed');
    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);
    final balanceField = config.fields.firstWhere((f) => f.column == 'balance');

    final coercion = coerceCsvCell(balanceField, 'not a number') as CsvCellStore;
    expect(coercion.warning, isNotNull);

    await dao.insert({
      'name': 'Bob',
      'balance': coercion.value,
      'active': 0,
      'priority': null,
    });

    final rows = await dao.getAll();
    final row = rows.singleWhere((r) => r['name'] == 'Bob');
    // Stored as-is, not silently coerced to null/0 -- same "graceful, not
    // broken" principle every other malformed-value path in this app
    // already follows.
    expect(row['balance'], 'not a number');
  });

  test('an inline-select label with no match stores raw text, not the wrong key', () async {
    final tableName = await createContactTable('CSV BadSelect');
    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);
    final priorityField = config.fields.firstWhere((f) => f.column == 'priority');

    final coercion = coerceCsvCell(priorityField, 'Medium') as CsvCellStore;
    expect(coercion.value, 'Medium');
    expect(coercion.warning, isNotNull);

    await dao.insert({'name': 'Carol', 'balance': null, 'active': 0, 'priority': coercion.value});
    final rows = await dao.getAll();
    final row = rows.singleWhere((r) => r['name'] == 'Carol');
    expect(row['priority'], 'Medium');
  });

  test('coerceCsvCell refuses a linked field -- never a real import target', () async {
    final parentTable = await editor.createTable(displayName: 'CSV Parent $runTag');
    addTearDown(() => dropTestTable(editor, metadata, parentTable));
    final childTable = await editor.createTable(displayName: 'CSV Child $runTag');
    addTearDown(() => dropTestTable(editor, metadata, childTable));
    await editor.addField(
      tableName: childTable,
      displayName: 'Parent',
      format: 'select',
      optionsJson: '{"mode": "linked", "table": "$parentTable", "on_delete": "restrict"}',
    );

    final config = await registry.buildConfig(childTable);
    final parentField = config.fields.firstWhere((f) => f.column == 'parent');
    expect(isCsvImportable(parentField), isFalse);
    expect(() => coerceCsvCell(parentField, 'anything'), throwsArgumentError);
  });
}
