// Proves a `formula` field end to end through the REAL pipeline --
// SchemaEditorService.createTable/addField -> SchemaRegistry.buildConfig
// -> GenericDao.insert/getAll -- against the real essentials.db.
// Essentials v2 Phase 2 build order step 6, and specifically the design
// doc's own ask to "verify against a real recreated subscription-style
// table": the `{cost} * {quantity}` table below is exactly the shape v1's
// hand-written `subscription_computed` SQL view used to cover.
//
// **Run this file on its own** -- `flutter test test/formula_end_to_end_test.dart`
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
import 'package:essentials_app/models/table_config.dart';
import 'package:essentials_app/util/formula/formula_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'support/schema_test_cleanup.dart';

void main() {
  late SqliteCrdt db;
  final editor = SchemaEditorService();
  final registry = SchemaRegistry();
  final metadata = SchemaMetadataDao();
  final runTag = DateTime.now().microsecondsSinceEpoch;

  setUpAll(() async {
    db = await DatabaseHelper.instance.crdt;
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  /// A real table with `cost` (real), `quantity` (integer) and a
  /// `total` formula over both -- created through the real schema engine,
  /// cleaned up through the real synced drop.
  Future<String> createLineItemTable(String label) async {
    final tableName = await editor.createTable(displayName: '$label $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Cost', format: 'real');
    await editor.addField(tableName: tableName, displayName: 'Quantity', format: 'integer');
    await editor.addField(
      tableName: tableName,
      displayName: 'Total',
      format: FormulaService.formatName,
      optionsJson: '{"expression": "{cost} * {quantity}", "resultType": "number"}',
    );
    return tableName;
  }

  test('SchemaRegistry builds a formula field as a readOnly numeric column', () async {
    final tableName = await createLineItemTable('FML Config');
    final config = await registry.buildConfig(tableName);

    final total = config.fields.firstWhere((f) => f.column == 'total');
    expect(total.format, FormulaService.formatName);
    // readOnly is what keeps both write paths from ever touching the
    // column -- see FormulaService's doc comment.
    expect(total.readOnly, isTrue);
    // FieldType.real is what gives the grid right-alignment, decimal
    // formatting and footer-aggregate eligibility.
    expect(total.type, FieldType.real);
    expect(total.required, isFalse);

    // A table with formula fields gets the live-preview hook the form
    // already knows how to call; one without stays null.
    expect(config.computePreview, isNotNull);
  });

  test('a text-result formula gets FieldType.text instead', () async {
    final tableName = await editor.createTable(displayName: 'FML Text Result $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Code', format: 'text');
    await editor.addField(
      tableName: tableName,
      displayName: 'Tag',
      format: FormulaService.formatName,
      optionsJson: '{"expression": "\'#\' || {code}", "resultType": "text"}',
    );

    final config = await registry.buildConfig(tableName);
    final tag = config.fields.firstWhere((f) => f.column == 'tag');
    expect(tag.type, FieldType.text);
    expect(tag.readOnly, isTrue);
  });

  test('a table with no formula fields still has a null computePreview', () async {
    final tableName = await editor.createTable(displayName: 'FML No Formula $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');

    final config = await registry.buildConfig(tableName);
    expect(config.computePreview, isNull);
  });

  test('getAll computes the formula from a really-inserted row', () async {
    final tableName = await createLineItemTable('FML Read');
    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);

    // Exactly what GenericFormScreen would write: every non-readOnly
    // field, and nothing for the formula column.
    await dao.insert({'cost': '4.50', 'quantity': '3'});

    final rows = await dao.getAll();
    expect(rows, hasLength(1));
    expect(rows.single['total'], 13.5);
  });

  test('the physical column stays NULL -- the value really is computed, not stored', () async {
    final tableName = await createLineItemTable('FML Not Stored');
    final config = await registry.buildConfig(tableName);
    await GenericDao(config).insert({'cost': '4.50', 'quantity': '3'});

    // Raw SQL, bypassing GenericDao entirely.
    final raw = await db.query('SELECT total FROM "$tableName" WHERE is_deleted = 0');
    expect(raw.single['total'], isNull);
  });

  test('a formula recomputes after the underlying values change', () async {
    final tableName = await createLineItemTable('FML Recompute');
    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);

    final id = await dao.insert({'cost': '10', 'quantity': '2'});
    expect((await dao.getAll()).single['total'], 20);

    await dao.update(id, {'cost': '10', 'quantity': '5'});
    expect((await dao.getAll()).single['total'], 50);
  });

  test('a row missing an input yields null rather than a wrong number', () async {
    final tableName = await createLineItemTable('FML Null Input');
    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);

    await dao.insert({'cost': '10', 'quantity': null});
    expect((await dao.getAll()).single['total'], isNull);
  });

  test('computePreview formats the same value the grid would show', () async {
    final tableName = await createLineItemTable('FML Preview');
    final config = await registry.buildConfig(tableName);

    // The in-progress form values, before anything is saved.
    final preview = await config.computePreview!({'cost': '4.50', 'quantity': '3'});
    // "13.50", not "13.5" -- the grid renders this column with 2 decimals,
    // so the form preview has to agree.
    expect(preview['total'], '13.50');
  });

  test('a formula referencing another formula resolves through the real pipeline', () async {
    final tableName = await createLineItemTable('FML Chained');
    await editor.addField(
      tableName: tableName,
      displayName: 'With Tax',
      format: FormulaService.formatName,
      optionsJson: '{"expression": "ROUND({total} * 1.1, 2)", "resultType": "number"}',
    );

    final config = await registry.buildConfig(tableName);
    await GenericDao(config).insert({'cost': '10', 'quantity': '2'});

    final row = (await GenericDao(config).getAll()).single;
    expect(row['total'], 20);
    expect(row['with_tax'], 22.0);
  });
}
