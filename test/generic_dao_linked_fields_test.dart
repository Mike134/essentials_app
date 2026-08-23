// Proves Essentials v2 Phase 1 build order step 6 -- GenericDao
// .findBlockingReferences/.delete reading field_definitions instead of
// PRAGMA foreign_key_list -- against the REAL essentials.db. Run with
// `flutter test test/generic_dao_linked_fields_test.dart`.
//
// Every table created through the real SchemaEditorService.createTable/
// addField pipeline; every parent/child config built through the real
// SchemaRegistry.buildConfig, exactly as GenericListScreen would. Same
// per-run-unique-tag/tombstone-only-cleanup discipline as the other v2
// test files -- see CLAUDE.md "Essentials v2 Phase 1 -- Step 3" for why.
import 'dart:convert';

import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/schema_registry.dart';
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

  /// Registers cleanup as this test's own tearDown -- see [dropTestTable]'s
  /// doc comment for why this must be a real, synced drop, not a raw local
  /// `DROP TABLE`. `addTearDown` runs LIFO (last registered, first run),
  /// so for [createLinkedPair] below, the *child* (registered second)
  /// always drops before the *parent* -- exactly the order
  /// [SchemaEditorService.dropTable]'s own blocking-reference check needs:
  /// the child's linked field is gone before the parent's drop ever checks
  /// for one.
  Future<String> createTestTable(String label) async {
    final tableName = await editor.createTable(displayName: '$label $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    return tableName;
  }

  /// Creates a parent table and a child table with a `select`/linked field
  /// on the child pointing at the parent, with the given [onDelete]
  /// (`null` leaves it unset, exercising the RESTRICT-by-default path).
  Future<({String parent, String child, String linkField})> createLinkedPair(
    String label, {
    String? onDelete,
  }) async {
    final parent = await createTestTable('$label Parent');
    final child = await createTestTable('$label Child');
    final options = {'mode': 'linked', 'table': parent, 'on_delete': ?onDelete};
    await editor.addField(
      tableName: child,
      displayName: 'Parent Ref',
      format: 'select',
      optionsJson: jsonEncode(options),
    );
    return (parent: parent, child: child, linkField: 'parent_ref');
  }

  Future<int> insertRow(String tableName, [Map<String, Object?> values = const {}]) async {
    final config = await registry.buildConfig(tableName);
    return GenericDao(config).insert(values);
  }

  test('findBlockingReferences blocks when a live child references it, RESTRICT by default', () async {
    final pair = await createLinkedPair('GDL Restrict Default');
    final parentId = await insertRow(pair.parent);
    await insertRow(pair.child, {pair.linkField: parentId});

    final parentConfig = await registry.buildConfig(pair.parent);
    final blockers = await GenericDao(parentConfig).findBlockingReferences(parentId);
    expect(blockers, [pair.child]);
  });

  test('findBlockingReferences does not block when no live child references it', () async {
    final pair = await createLinkedPair('GDL No Live Refs');
    final parentId = await insertRow(pair.parent);
    // A child row exists but points at nothing (or a different id) -- no
    // live reference to this specific parent row.
    await insertRow(pair.child, {pair.linkField: null});

    final parentConfig = await registry.buildConfig(pair.parent);
    final blockers = await GenericDao(parentConfig).findBlockingReferences(parentId);
    expect(blockers, isEmpty);
  });

  test('a soft-deleted child no longer blocks', () async {
    final pair = await createLinkedPair('GDL Soft Deleted Child');
    final parentId = await insertRow(pair.parent);
    final childId = await insertRow(pair.child, {pair.linkField: parentId});

    final parentConfig = await registry.buildConfig(pair.parent);
    expect(await GenericDao(parentConfig).findBlockingReferences(parentId), [pair.child]);

    final childConfig = await registry.buildConfig(pair.child);
    await GenericDao(childConfig).delete(childId);

    expect(await GenericDao(parentConfig).findBlockingReferences(parentId), isEmpty);
  });

  test('CASCADE: findBlockingReferences does not block, and delete removes the child', () async {
    final pair = await createLinkedPair('GDL Cascade', onDelete: 'cascade');
    final parentId = await insertRow(pair.parent);
    final childId = await insertRow(pair.child, {pair.linkField: parentId});

    final parentConfig = await registry.buildConfig(pair.parent);
    expect(await GenericDao(parentConfig).findBlockingReferences(parentId), isEmpty);

    await GenericDao(parentConfig).delete(parentId);

    final childRows = await db.query('SELECT * FROM ${pair.child} WHERE id = ?1 AND is_deleted = 0', [childId]);
    expect(childRows, isEmpty, reason: 'CASCADE should have soft-deleted the child row too');
  });

  test('IGNORE: findBlockingReferences does not block, and delete leaves the child untouched', () async {
    final pair = await createLinkedPair('GDL Ignore', onDelete: 'ignore');
    final parentId = await insertRow(pair.parent);
    final childId = await insertRow(pair.child, {pair.linkField: parentId});

    final parentConfig = await registry.buildConfig(pair.parent);
    expect(await GenericDao(parentConfig).findBlockingReferences(parentId), isEmpty);

    await GenericDao(parentConfig).delete(parentId);

    final childRows = await db.query('SELECT * FROM ${pair.child} WHERE id = ?1 AND is_deleted = 0', [childId]);
    expect(childRows, hasLength(1), reason: 'IGNORE should leave the child row alone, dangling reference and all');
  });

  test('a RESTRICT-blocked delete is not actually prevented by delete() itself -- no real SQL FK exists in v2', () async {
    // Matches the documented v1 behavior this replaces: SQLite's own FK
    // enforcement never fires through sqlite_crdt's soft-delete rewrite,
    // so findBlockingReferences (checked by the caller/UI) is the real
    // enforcement, not delete() itself. Confirms that hasn't regressed.
    final pair = await createLinkedPair('GDL Restrict Not Enforced By Delete');
    final parentId = await insertRow(pair.parent);
    await insertRow(pair.child, {pair.linkField: parentId});

    final parentConfig = await registry.buildConfig(pair.parent);
    await GenericDao(parentConfig).delete(parentId); // must not throw

    final parentRows = await db.query('SELECT * FROM ${pair.parent} WHERE id = ?1 AND is_deleted = 0', [parentId]);
    expect(parentRows, isEmpty);
  });
}
