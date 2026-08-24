// Proves Essentials v2 Phase 4 build order step 3 -- GenericDao's
// referential integrity (findBlockingReferences / delete's cascade pass)
// and SchemaEditorService's drop-safety check both understanding
// `link_record`'s JSON-array storage, alongside the existing
// `select`/linked scalar shape -- against the REAL essentials.db.
//
// The sibling file test/generic_dao_linked_fields_test.dart covers the
// same behaviours for `select`/linked and must keep passing unchanged;
// this file is the array-membership half plus the "both formats pointing
// at one target, side by side" case.
//
// **Run this file on its own** (`flutter test
// test/generic_dao_link_record_refs_test.dart`), never chained with
// another SchemaEditorService.createTable-using test file -- see CLAUDE.md
// "Essentials v2 Phase 1 -- Step 3". Cleanup goes through the real synced
// drop (support/schema_test_cleanup.dart), never a raw local DROP TABLE.
import 'dart:convert';

import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/schema_registry.dart';
import 'package:essentials_app/util/link_record.dart';
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
    final tableName = await editor.createTable(displayName: 'LRR $label $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    return tableName;
  }

  /// A target table plus a source table carrying a multi-valued
  /// `link_record` field pointing at it, with the given [onDelete] (`null`
  /// leaves it unset, exercising the RESTRICT-by-default path). Target
  /// registered first so addTearDown's LIFO order drops the *source* first
  /// -- the target's own drop-safety check refuses while a live link field
  /// still points at it.
  Future<({String target, String source, String linkField})> createLinkedPair(
    String label, {
    String? onDelete,
    bool multiple = true,
  }) async {
    final target = await createTestTable('$label Target');
    final source = await createTestTable('$label Source');
    await editor.addField(
      tableName: source,
      displayName: 'Links',
      format: 'link_record',
      optionsJson: jsonEncode({
        'table': target,
        'displayField': 'name',
        'multiple': multiple,
        'on_delete': ?onDelete,
      }),
    );
    return (target: target, source: source, linkField: 'links');
  }

  Future<int> insertRow(String tableName, [Map<String, Object?> values = const {}]) async {
    final config = await registry.buildConfig(tableName);
    return GenericDao(config).insert(values);
  }

  Future<List<String>> blockersFor(String tableName, int id) async =>
      GenericDao(await registry.buildConfig(tableName)).findBlockingReferences(id);

  Future<bool> rowIsLive(String tableName, int id) async {
    final rows = await db.query(
      'SELECT 1 FROM "$tableName" WHERE id = ?1 AND is_deleted = 0',
      [id],
    );
    return rows.isNotEmpty;
  }

  // =====================================================================
  // RESTRICT -- the default
  // =====================================================================

  test('RESTRICT by default: a link_record array containing the id blocks', () async {
    final pair = await createLinkedPair('Restrict Default');
    final targetA = await insertRow(pair.target);
    final targetB = await insertRow(pair.target);
    await insertRow(pair.source, {pair.linkField: encodeLinkedIds([targetA, targetB])});

    // Both ids block -- array *membership*, not just the first element.
    expect(await blockersFor(pair.target, targetA), [pair.source]);
    expect(await blockersFor(pair.target, targetB), [pair.source]);
  });

  test('an id not present in any array does not block', () async {
    final pair = await createLinkedPair('Restrict Unreferenced');
    final linked = await insertRow(pair.target);
    final unlinked = await insertRow(pair.target);
    await insertRow(pair.source, {pair.linkField: encodeLinkedIds([linked])});

    expect(await blockersFor(pair.target, unlinked), isEmpty);
  });

  test('an empty array, a NULL column and malformed JSON all block nothing', () async {
    final pair = await createLinkedPair('Restrict No Refs');
    final targetId = await insertRow(pair.target);
    await insertRow(pair.source, {pair.linkField: encodeLinkedIds([])});
    await insertRow(pair.source, {pair.linkField: null});
    await insertRow(pair.source, {pair.linkField: 'not json'});

    expect(await blockersFor(pair.target, targetId), isEmpty);
  });

  test('one malformed-JSON row does not silently disable blocking for every other row', () async {
    // The regression test for a real bug caught while writing these:
    // `json_each` on a value that isn't valid JSON raises `malformed JSON`
    // for the WHOLE statement, and findBlockingReferences catches a
    // DatabaseException as "this table is gone" -> no blockers. So without
    // the CASE WHEN json_valid guard in _referenceMatchSql, a single junk
    // row anywhere in the referencing table silently turns RESTRICT off
    // for every genuinely-referenced row in it.
    final pair = await createLinkedPair('Restrict Malformed Neighbour');
    final targetId = await insertRow(pair.target);
    await insertRow(pair.source, {pair.linkField: 'not json at all'});
    await insertRow(pair.source, {pair.linkField: '[unclosed'});
    await insertRow(pair.source, {pair.linkField: encodeLinkedIds([targetId])});

    expect(await blockersFor(pair.target, targetId), [pair.source]);
  });

  test('a malformed-JSON row is not itself cascade-deleted by an unrelated id', () async {
    final pair = await createLinkedPair('Cascade Malformed Neighbour', onDelete: 'cascade');
    final targetId = await insertRow(pair.target);
    final junkId = await insertRow(pair.source, {pair.linkField: 'not json at all'});
    final realId = await insertRow(pair.source, {
      pair.linkField: encodeLinkedIds([targetId]),
    });

    await GenericDao(await registry.buildConfig(pair.target)).delete(targetId);

    expect(await rowIsLive(pair.source, realId), isFalse);
    expect(
      await rowIsLive(pair.source, junkId),
      isTrue,
      reason: 'an unparseable link value links to nothing -- it must not be swept up',
    );
  });

  test('a soft-deleted referencing row no longer blocks', () async {
    final pair = await createLinkedPair('Restrict Soft Deleted Source');
    final targetId = await insertRow(pair.target);
    final sourceId = await insertRow(pair.source, {
      pair.linkField: encodeLinkedIds([targetId]),
    });

    expect(await blockersFor(pair.target, targetId), [pair.source]);

    await GenericDao(await registry.buildConfig(pair.source)).delete(sourceId);

    expect(await blockersFor(pair.target, targetId), isEmpty);
  });

  test('a single-valued link_record blocks the same way -- storage is an array either way', () async {
    final pair = await createLinkedPair('Restrict Single Valued', multiple: false);
    final targetId = await insertRow(pair.target);
    await insertRow(pair.source, {pair.linkField: encodeLinkedIds([targetId])});

    expect(await blockersFor(pair.target, targetId), [pair.source]);
  });

  test('an id repeated in one array reports its table once, not twice', () async {
    final pair = await createLinkedPair('Restrict Duplicate Id');
    final targetId = await insertRow(pair.target);
    // Shouldn't happen through the picker, but a hand-edited/imported
    // array can look like this -- the EXISTS form must not double-count.
    await insertRow(pair.source, {
      pair.linkField: encodeLinkedIds([targetId, targetId]),
    });

    expect(await blockersFor(pair.target, targetId), [pair.source]);
  });

  test('a string-encoded id in the array still matches -- CAST, not a bare =', () async {
    final pair = await createLinkedPair('Restrict String Id');
    final targetId = await insertRow(pair.target);
    // parseLinkedIds is deliberately lenient about string entries, so the
    // matching side has to be too -- otherwise the two halves of the same
    // feature disagree about whether a row is linked.
    await insertRow(pair.source, {pair.linkField: '["$targetId"]'});

    expect(await blockersFor(pair.target, targetId), [pair.source]);
  });

  // =====================================================================
  // CASCADE
  // =====================================================================

  test('CASCADE deletes the WHOLE referencing row, not just that id from the array', () async {
    final pair = await createLinkedPair('Cascade', onDelete: 'cascade');
    final targetA = await insertRow(pair.target);
    final targetB = await insertRow(pair.target);
    final sourceId = await insertRow(pair.source, {
      pair.linkField: encodeLinkedIds([targetA, targetB]),
    });

    // CASCADE never blocks -- it's expected to cascade instead.
    expect(await blockersFor(pair.target, targetA), isEmpty);

    await GenericDao(await registry.buildConfig(pair.target)).delete(targetA);

    expect(
      await rowIsLive(pair.source, sourceId),
      isFalse,
      reason: 'per the design doc, ANY ONE matching id deletes the whole referencing row',
    );
    // And explicitly NOT a partial prune: the stored array is untouched,
    // the row is simply tombstoned.
    final raw = await db.query(
      'SELECT "${pair.linkField}" AS links FROM "${pair.source}" WHERE id = ?1',
      [sourceId],
    );
    expect(parseLinkedIds(raw.single['links']), [targetA, targetB]);
  });

  test('CASCADE deletes every matching row, and leaves non-matching rows alone', () async {
    final pair = await createLinkedPair('Cascade Many', onDelete: 'cascade');
    final doomed = await insertRow(pair.target);
    final spared = await insertRow(pair.target);
    final matchA = await insertRow(pair.source, {
      pair.linkField: encodeLinkedIds([doomed]),
    });
    final matchB = await insertRow(pair.source, {
      pair.linkField: encodeLinkedIds([spared, doomed]),
    });
    final untouched = await insertRow(pair.source, {
      pair.linkField: encodeLinkedIds([spared]),
    });

    await GenericDao(await registry.buildConfig(pair.target)).delete(doomed);

    expect(await rowIsLive(pair.source, matchA), isFalse);
    expect(await rowIsLive(pair.source, matchB), isFalse);
    expect(await rowIsLive(pair.source, untouched), isTrue);
  });

  // =====================================================================
  // IGNORE
  // =====================================================================

  test('IGNORE neither blocks nor cascades -- the reference is left dangling', () async {
    final pair = await createLinkedPair('Ignore', onDelete: 'ignore');
    final targetId = await insertRow(pair.target);
    final sourceId = await insertRow(pair.source, {
      pair.linkField: encodeLinkedIds([targetId]),
    });

    expect(await blockersFor(pair.target, targetId), isEmpty);

    await GenericDao(await registry.buildConfig(pair.target)).delete(targetId);

    expect(await rowIsLive(pair.source, sourceId), isTrue);
  });

  // =====================================================================
  // Both formats side by side -- the regression case for step 3
  // =====================================================================

  test('a select/linked and a link_record reference to the SAME target both work', () async {
    final target = await createTestTable('Both Formats Target');
    final scalarSource = await createTestTable('Both Formats Scalar');
    final arraySource = await createTestTable('Both Formats Array');
    await editor.addField(
      tableName: scalarSource,
      displayName: 'Target Ref',
      format: 'select',
      optionsJson: jsonEncode({'mode': 'linked', 'table': target}),
    );
    await editor.addField(
      tableName: arraySource,
      displayName: 'Links',
      format: 'link_record',
      optionsJson: jsonEncode({'table': target, 'multiple': true}),
    );

    final scalarOnly = await insertRow(target);
    final arrayOnly = await insertRow(target);
    final both = await insertRow(target);

    await insertRow(scalarSource, {'target_ref': scalarOnly});
    await insertRow(arraySource, {'links': encodeLinkedIds([arrayOnly])});
    await insertRow(scalarSource, {'target_ref': both});
    await insertRow(arraySource, {'links': encodeLinkedIds([both])});

    expect(await blockersFor(target, scalarOnly), [scalarSource]);
    expect(await blockersFor(target, arrayOnly), [arraySource]);
    // Both blockers reported, sorted -- neither format's match shadows the
    // other, and each uses the right matching SQL for its own storage.
    expect(
      await blockersFor(target, both),
      ([arraySource, scalarSource]..sort()),
    );
  });

  test('a mixed CASCADE pass deletes through both storage shapes in one delete', () async {
    final target = await createTestTable('Mixed Cascade Target');
    final scalarSource = await createTestTable('Mixed Cascade Scalar');
    final arraySource = await createTestTable('Mixed Cascade Array');
    await editor.addField(
      tableName: scalarSource,
      displayName: 'Target Ref',
      format: 'select',
      optionsJson: jsonEncode({
        'mode': 'linked',
        'table': target,
        'on_delete': 'cascade',
      }),
    );
    await editor.addField(
      tableName: arraySource,
      displayName: 'Links',
      format: 'link_record',
      optionsJson: jsonEncode({
        'table': target,
        'multiple': true,
        'on_delete': 'cascade',
      }),
    );

    final targetId = await insertRow(target);
    final scalarChild = await insertRow(scalarSource, {'target_ref': targetId});
    final arrayChild = await insertRow(arraySource, {
      'links': encodeLinkedIds([targetId]),
    });

    await GenericDao(await registry.buildConfig(target)).delete(targetId);

    expect(await rowIsLive(scalarSource, scalarChild), isFalse);
    expect(await rowIsLive(arraySource, arrayChild), isFalse);
  });

  // =====================================================================
  // Schema-level drop safety
  // =====================================================================

  test('dropTable refuses while a live link_record field still points at the table', () async {
    final pair = await createLinkedPair('Drop Safety');

    await metadata.softDeleteTable(pair.target);
    await expectLater(
      editor.dropTable(pair.target),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains(pair.source)),
      ),
    );

    // Still physically there -- the refusal was real, not cosmetic.
    final physical = await db.query(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
      [pair.target],
    );
    expect(physical, hasLength(1));

    // Restore so this test's own soft-delete doesn't confuse cleanup
    // ordering -- dropTestTable soft-deletes again itself.
    await metadata.restoreTable(pair.target);
  });
}
