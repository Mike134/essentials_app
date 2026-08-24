// Proves Essentials v2 Phase 4 build order step 2 -- LinkedFieldService
// resolving `lookup`/`rollup` values against a real target table -- through
// the REAL pipeline against the REAL essentials.db: every table/field
// created via SchemaEditorService.createTable/addField, every config built
// via SchemaRegistry.buildConfig, every value read via GenericDao.getAll,
// exactly as GenericListScreen would.
//
// **Run this file on its own** (`flutter test
// test/linked_field_service_end_to_end_test.dart`), never chained with
// another SchemaEditorService.createTable-using test file -- see CLAUDE.md
// "Essentials v2 Phase 1 -- Step 3" and the "Follow-up" note in the
// real-device verification session for the reproduced cleanup failure that
// chaining causes. Cleanup goes through the real synced drop
// (support/schema_test_cleanup.dart), never a raw local DROP TABLE.
import 'dart:convert';

import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/schema_registry.dart';
import 'package:essentials_app/models/table_config.dart';
import 'package:essentials_app/util/link_record.dart';
import 'package:essentials_app/util/linked_field/linked_field_service.dart';
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

  Future<String> createTestTable(String label) async {
    final tableName = await editor.createTable(displayName: 'LFS $label $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    return tableName;
  }

  /// A target table with a text `label` and a numeric `amount` column, plus
  /// a source table holding a multi-valued `link_record` field pointing at
  /// it. Registered in that order so addTearDown's LIFO ordering drops the
  /// *source* first -- the target's own drop-safety check refuses while a
  /// live link field still points at it.
  Future<({String target, String source, String linkField})> createLinkedPair(
    String label,
  ) async {
    final target = await createTestTable('$label Target');
    await editor.addField(tableName: target, displayName: 'Label', format: 'text');
    await editor.addField(tableName: target, displayName: 'Amount', format: 'real');

    final source = await createTestTable('$label Source');
    await editor.addField(
      tableName: source,
      displayName: 'Links',
      format: 'link_record',
      optionsJson: jsonEncode({
        'table': target,
        'displayField': 'label',
        'multiple': true,
      }),
    );
    return (target: target, source: source, linkField: 'links');
  }

  Future<int> insertRow(String tableName, [Map<String, Object?> values = const {}]) async {
    final config = await registry.buildConfig(tableName);
    return GenericDao(config).insert(values);
  }

  Future<Map<String, Object?>> readOnlyRow(String tableName) async {
    final config = await registry.buildConfig(tableName);
    final rows = await GenericDao(config).getAll();
    expect(rows, hasLength(1), reason: 'each test uses its own freshly created table');
    return rows.single;
  }

  // =====================================================================
  // lookup
  // =====================================================================

  test('lookup resolves a single linked record\'s source field', () async {
    final pair = await createLinkedPair('Lookup Single');
    final targetId = await insertRow(pair.target, {'label': 'Alice', 'amount': 10});
    await editor.addField(
      tableName: pair.source,
      displayName: 'Linked Name',
      format: 'lookup',
      optionsJson: jsonEncode({'link_field': pair.linkField, 'source_field': 'label'}),
    );
    await insertRow(pair.source, {pair.linkField: encodeLinkedIds([targetId])});

    final row = await readOnlyRow(pair.source);
    expect(row['linked_name'], 'Alice');
  });

  test('lookup joins several linked records with ", " in link-array order', () async {
    final pair = await createLinkedPair('Lookup Multi');
    final alice = await insertRow(pair.target, {'label': 'Alice'});
    final bob = await insertRow(pair.target, {'label': 'Bob'});
    final cara = await insertRow(pair.target, {'label': 'Cara'});
    await editor.addField(
      tableName: pair.source,
      displayName: 'Linked Names',
      format: 'lookup',
      optionsJson: jsonEncode({'link_field': pair.linkField, 'source_field': 'label'}),
    );
    // Deliberately NOT id order -- the design doc requires the stored
    // array's own order, not the target table's.
    await insertRow(pair.source, {pair.linkField: encodeLinkedIds([cara, alice, bob])});

    final row = await readOnlyRow(pair.source);
    expect(row['linked_names'], 'Cara, Alice, Bob');
  });

  test('lookup is null when nothing is linked, and when every linked value is blank', () async {
    final pair = await createLinkedPair('Lookup Empty');
    final blank = await insertRow(pair.target, {'label': ''});
    await editor.addField(
      tableName: pair.source,
      displayName: 'Linked Names',
      format: 'lookup',
      optionsJson: jsonEncode({'link_field': pair.linkField, 'source_field': 'label'}),
    );
    final emptyId = await insertRow(pair.source, {pair.linkField: encodeLinkedIds([])});
    final blankId = await insertRow(pair.source, {
      pair.linkField: encodeLinkedIds([blank]),
    });

    final config = await registry.buildConfig(pair.source);
    final rows = await GenericDao(config).getAll();
    final byId = {for (final row in rows) row['id'] as int: row};
    expect(byId[emptyId]!['linked_names'], isNull);
    expect(byId[blankId]!['linked_names'], isNull);
  });

  test('lookup excludes a soft-deleted linked record', () async {
    final pair = await createLinkedPair('Lookup Soft Deleted');
    final alice = await insertRow(pair.target, {'label': 'Alice'});
    final bob = await insertRow(pair.target, {'label': 'Bob'});
    await editor.addField(
      tableName: pair.source,
      displayName: 'Linked Names',
      format: 'lookup',
      optionsJson: jsonEncode({'link_field': pair.linkField, 'source_field': 'label'}),
    );
    await insertRow(pair.source, {pair.linkField: encodeLinkedIds([alice, bob])});

    expect((await readOnlyRow(pair.source))['linked_names'], 'Alice, Bob');

    final targetConfig = await registry.buildConfig(pair.target);
    await GenericDao(targetConfig).delete(alice);

    // The stored array still holds Alice's id -- a soft-deleted linked row
    // simply drops out of the resolution, no data rewrite involved.
    final row = await readOnlyRow(pair.source);
    expect(row[pair.linkField], contains('$alice'));
    expect(row['linked_names'], 'Bob');
  });

  // =====================================================================
  // rollup -- all five aggregates against one shared fixture
  // =====================================================================

  test('every aggregate resolves over the same linked set', () async {
    final pair = await createLinkedPair('Rollup Aggregates');
    final ids = <int>[
      await insertRow(pair.target, {'label': 'a', 'amount': 10}),
      await insertRow(pair.target, {'label': 'b', 'amount': 20}),
      await insertRow(pair.target, {'label': 'c', 'amount': 30}),
    ];
    for (final aggregate in LinkedFieldService.aggregates) {
      await editor.addField(
        tableName: pair.source,
        displayName: 'Agg $aggregate',
        format: 'rollup',
        optionsJson: jsonEncode({
          'link_field': pair.linkField,
          'source_field': 'amount',
          'aggregate': aggregate,
        }),
      );
    }
    await insertRow(pair.source, {pair.linkField: encodeLinkedIds(ids)});

    final row = await readOnlyRow(pair.source);
    expect(row['agg_sum'], 60);
    expect(row['agg_avg'], 20);
    expect(row['agg_min'], 10);
    expect(row['agg_max'], 30);
    expect(row['agg_count'], 3);
  });

  test('count ignores source_field entirely and works with none set', () async {
    final pair = await createLinkedPair('Rollup Count No Source');
    final ids = <int>[
      await insertRow(pair.target, {'label': 'a'}),
      await insertRow(pair.target, {'label': 'b'}),
    ];
    await editor.addField(
      tableName: pair.source,
      displayName: 'Link Count',
      format: 'rollup',
      // No source_field at all -- the design doc's "useful even when
      // nothing numeric is being summed" case.
      optionsJson: jsonEncode({'link_field': pair.linkField, 'aggregate': 'count'}),
    );
    await insertRow(pair.source, {pair.linkField: encodeLinkedIds(ids)});

    expect((await readOnlyRow(pair.source))['link_count'], 2);
  });

  test('count excludes a soft-deleted linked record', () async {
    final pair = await createLinkedPair('Rollup Count Soft Deleted');
    final keep = await insertRow(pair.target, {'label': 'keep'});
    final gone = await insertRow(pair.target, {'label': 'gone'});
    await editor.addField(
      tableName: pair.source,
      displayName: 'Link Count',
      format: 'rollup',
      optionsJson: jsonEncode({'link_field': pair.linkField, 'aggregate': 'count'}),
    );
    await insertRow(pair.source, {pair.linkField: encodeLinkedIds([keep, gone])});

    expect((await readOnlyRow(pair.source))['link_count'], 2);
    await GenericDao(await registry.buildConfig(pair.target)).delete(gone);
    expect((await readOnlyRow(pair.source))['link_count'], 1);
  });

  test('sum/avg skip a non-numeric or missing value rather than crashing or zeroing', () async {
    final pair = await createLinkedPair('Rollup Skip Non Numeric');
    final ids = <int>[
      await insertRow(pair.target, {'label': 'good', 'amount': 10}),
      // Genuinely non-numeric text sitting in a numeric-format column --
      // real data can look like this (a CSV import, a hand edit).
      await insertRow(pair.target, {'label': 'junk', 'amount': 'not a number'}),
      // Missing entirely.
      await insertRow(pair.target, {'label': 'blank'}),
    ];
    for (final aggregate in const ['sum', 'avg', 'count']) {
      await editor.addField(
        tableName: pair.source,
        displayName: 'Agg $aggregate',
        format: 'rollup',
        optionsJson: jsonEncode({
          'link_field': pair.linkField,
          'source_field': 'amount',
          'aggregate': aggregate,
        }),
      );
    }
    await insertRow(pair.source, {pair.linkField: encodeLinkedIds(ids)});

    final row = await readOnlyRow(pair.source);
    // Only the one real number contributed -- NOT treated as 10/3.
    expect(row['agg_sum'], 10);
    expect(row['agg_avg'], 10);
    // count is about linked *records*, not contributed values.
    expect(row['agg_count'], 3);
  });

  test('a rollup pointed at a genuinely text field aggregates nothing (null, not 0)', () async {
    final pair = await createLinkedPair('Rollup Text Source');
    final ids = <int>[
      await insertRow(pair.target, {'label': 'Alice'}),
      await insertRow(pair.target, {'label': 'Bob'}),
    ];
    await editor.addField(
      tableName: pair.source,
      displayName: 'Bad Sum',
      format: 'rollup',
      optionsJson: jsonEncode({
        'link_field': pair.linkField,
        'source_field': 'label',
        'aggregate': 'sum',
      }),
    );
    await insertRow(pair.source, {pair.linkField: encodeLinkedIds(ids)});

    expect((await readOnlyRow(pair.source))['bad_sum'], isNull);
  });

  test('an empty link array yields null for sum, and 0 for count', () async {
    final pair = await createLinkedPair('Rollup Nothing Linked');
    for (final aggregate in const ['sum', 'count']) {
      await editor.addField(
        tableName: pair.source,
        displayName: 'Agg $aggregate',
        format: 'rollup',
        optionsJson: jsonEncode({
          'link_field': pair.linkField,
          'source_field': 'amount',
          'aggregate': aggregate,
        }),
      );
    }
    await insertRow(pair.source, {pair.linkField: encodeLinkedIds([])});

    final row = await readOnlyRow(pair.source);
    expect(row['agg_sum'], isNull);
    expect(row['agg_count'], 0);
  });

  test('an unrecognized aggregate falls back to sum rather than blanking', () async {
    final pair = await createLinkedPair('Rollup Bad Aggregate');
    final ids = <int>[
      await insertRow(pair.target, {'label': 'a', 'amount': 5}),
      await insertRow(pair.target, {'label': 'b', 'amount': 7}),
    ];
    await editor.addField(
      tableName: pair.source,
      displayName: 'Odd Agg',
      format: 'rollup',
      optionsJson: jsonEncode({
        'link_field': pair.linkField,
        'source_field': 'amount',
        'aggregate': 'median',
      }),
    );
    await insertRow(pair.source, {pair.linkField: encodeLinkedIds(ids)});

    expect((await readOnlyRow(pair.source))['odd_agg'], 12);
  });

  // =====================================================================
  // Bad metadata never crashes a read
  // =====================================================================

  test('unresolvable metadata degrades to null, never an exception', () async {
    final pair = await createLinkedPair('Bad Metadata');
    final targetId = await insertRow(pair.target, {'label': 'Alice', 'amount': 1});

    // No link_field at all.
    await editor.addField(
      tableName: pair.source,
      displayName: 'No Link Field',
      format: 'lookup',
      optionsJson: jsonEncode({'source_field': 'label'}),
    );
    // link_field naming a column that isn't a link_record field.
    await editor.addField(
      tableName: pair.source,
      displayName: 'Wrong Link Field',
      format: 'lookup',
      optionsJson: jsonEncode({'link_field': 'no_link_field', 'source_field': 'label'}),
    );
    // source_field naming a column that doesn't exist on the target.
    await editor.addField(
      tableName: pair.source,
      displayName: 'Ghost Source',
      format: 'lookup',
      optionsJson: jsonEncode({'link_field': pair.linkField, 'source_field': 'nope'}),
    );
    // A rollup with no source_field and a non-count aggregate.
    await editor.addField(
      tableName: pair.source,
      displayName: 'Sum No Source',
      format: 'rollup',
      optionsJson: jsonEncode({'link_field': pair.linkField, 'aggregate': 'sum'}),
    );
    // A genuinely resolvable field alongside them, to prove one bad
    // definition doesn't take the whole table's computation down with it.
    await editor.addField(
      tableName: pair.source,
      displayName: 'Good Lookup',
      format: 'lookup',
      optionsJson: jsonEncode({'link_field': pair.linkField, 'source_field': 'label'}),
    );
    await insertRow(pair.source, {pair.linkField: encodeLinkedIds([targetId])});

    final row = await readOnlyRow(pair.source);
    expect(row['no_link_field'], isNull);
    expect(row['wrong_link_field'], isNull);
    expect(row['ghost_source'], isNull);
    expect(row['sum_no_source'], isNull);
    expect(row['good_lookup'], 'Alice');
  });

  test('a malformed link array parses to nothing linked, not an exception', () async {
    final pair = await createLinkedPair('Malformed Array');
    await editor.addField(
      tableName: pair.source,
      displayName: 'Linked Names',
      format: 'lookup',
      optionsJson: jsonEncode({'link_field': pair.linkField, 'source_field': 'label'}),
    );
    await insertRow(pair.source, {pair.linkField: 'not json at all'});

    expect((await readOnlyRow(pair.source))['linked_names'], isNull);
  });

  // =====================================================================
  // Live form preview (TableConfig.computePreview)
  // =====================================================================

  test('computePreview is wired up and recomputes from unsaved form values', () async {
    final pair = await createLinkedPair('Compute Preview');
    final alice = await insertRow(pair.target, {'label': 'Alice', 'amount': 10});
    final bob = await insertRow(pair.target, {'label': 'Bob', 'amount': 20});
    await editor.addField(
      tableName: pair.source,
      displayName: 'Linked Names',
      format: 'lookup',
      optionsJson: jsonEncode({'link_field': pair.linkField, 'source_field': 'label'}),
    );
    await editor.addField(
      tableName: pair.source,
      displayName: 'Total',
      format: 'rollup',
      optionsJson: jsonEncode({
        'link_field': pair.linkField,
        'source_field': 'amount',
        'aggregate': 'sum',
      }),
    );

    final config = await registry.buildConfig(pair.source);
    expect(
      config.computePreview,
      isNotNull,
      reason: 'a table with lookup/rollup fields must get the live-preview hook',
    );

    // No row saved at all -- exactly the Add-form case.
    final preview = await config.computePreview!({
      pair.linkField: encodeLinkedIds([alice, bob]),
    });
    expect(preview['linked_names'], 'Alice, Bob');
    // Display text, formatted to the field's own decimals, so the form
    // reads identically to the grid cell.
    expect(preview['total'], '30.00');
  });

  test('computePreview stays null for a table with no computed fields', () async {
    final plain = await createTestTable('No Computed Fields');
    await editor.addField(tableName: plain, displayName: 'Name', format: 'text');
    expect((await registry.buildConfig(plain)).computePreview, isNull);
  });

  // =====================================================================
  // FieldType / readOnly semantics driven by resultType
  // =====================================================================

  test('lookup defaults to a text column, rollup to a real one, both readOnly', () async {
    final pair = await createLinkedPair('Field Types');
    await editor.addField(
      tableName: pair.source,
      displayName: 'Names',
      format: 'lookup',
      optionsJson: jsonEncode({'link_field': pair.linkField, 'source_field': 'label'}),
    );
    await editor.addField(
      tableName: pair.source,
      displayName: 'Total',
      format: 'rollup',
      optionsJson: jsonEncode({
        'link_field': pair.linkField,
        'source_field': 'amount',
        'aggregate': 'sum',
      }),
    );

    final config = await registry.buildConfig(pair.source);
    final byColumn = {for (final f in config.fields) f.column: f};

    expect(byColumn['names']!.type, FieldType.text);
    expect(byColumn['names']!.readOnly, isTrue);
    expect(byColumn['names']!.isFieldLookup, isTrue);

    expect(byColumn['total']!.type, FieldType.real);
    expect(byColumn['total']!.readOnly, isTrue);
    expect(byColumn['total']!.isRollup, isTrue);
  });

  test('the physical lookup/rollup column stays NULL -- the value is genuinely computed', () async {
    final pair = await createLinkedPair('Never Written');
    final targetId = await insertRow(pair.target, {'label': 'Alice', 'amount': 42});
    await editor.addField(
      tableName: pair.source,
      displayName: 'Total',
      format: 'rollup',
      optionsJson: jsonEncode({
        'link_field': pair.linkField,
        'source_field': 'amount',
        'aggregate': 'sum',
      }),
    );
    final sourceId = await insertRow(pair.source, {
      pair.linkField: encodeLinkedIds([targetId]),
    });

    expect((await readOnlyRow(pair.source))['total'], 42);

    // Raw SQL, bypassing GenericDao.getAll entirely.
    final raw = await db.query('SELECT total FROM "${pair.source}" WHERE id = ?1', [sourceId]);
    expect(
      raw.single['total'],
      isNull,
      reason: 'a rollup column is deliberately never written -- see FormulaService\'s doc comment',
    );
  });
}
