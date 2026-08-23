// Proves Essentials v2 Phase 1 build order step 7's SchemaMetadataDao --
// the non-DDL rename/reorder/format-change/soft-delete/restore operations
// ManageFieldsScreen needs -- against the REAL essentials.db. Run with
// `flutter test test/schema_metadata_dao_test.dart`.
//
// Every table/field created through the real SchemaEditorService pipeline
// (Step 3). Same per-run-unique-tag/tombstone-only-cleanup discipline as
// every other v2 test file -- see CLAUDE.md "Essentials v2 Phase 1 --
// Step 3" for why.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/schema_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'support/schema_test_cleanup.dart';

void main() {
  final editor = SchemaEditorService();
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
    return tableName;
  }

  test('updateTable replaces display_name/description and preserves other columns', () async {
    final tableName = await createTestTable('SMD Rename Table');
    final before = await metadata.loadTable(tableName);
    expect(before, isNotNull);

    await metadata.updateTable(tableName, displayName: 'A whole new name', description: 'new description');

    final after = await metadata.loadTable(tableName);
    expect(after!['display_name'], 'A whole new name');
    expect(after['description'], 'new description');
    expect(after['table_name'], tableName);
    expect(after['created_at'], before!['created_at']);
  });

  test('updateTable rejects an empty name', () async {
    final tableName = await createTestTable('SMD Rename Rejects Empty');
    expect(() => metadata.updateTable(tableName, displayName: '   '), throwsArgumentError);
  });

  test('updateTable advances hlc/node_id/modified -- a real regression, not just the display_name write', () async {
    // Real bug, found live (see CLAUDE.md "Essentials v2 Phase 1" -- Step 9
    // follow-up): updateTable used to spread the full `existing` row into
    // its upsert, carrying the OLD hlc/node_id/modified along verbatim.
    // sqlite_crdt only auto-stamps a fresh hlc when a write's SQL doesn't
    // mention that column at all -- explicitly supplying the stale one
    // freezes it there permanently, so a rename would update display_name
    // locally but never win the CRDT's last-write-wins comparison on any
    // other device (same-or-lesser hlc, forever) -- a silent, permanent
    // cross-device sync failure with no error anywhere. Confirmed live by
    // pulling a real device's own local db and finding display_name
    // correctly updated but hlc still the row's original creation
    // timestamp.
    final tableName = await createTestTable('SMD Rename Advances Hlc');
    final before = await metadata.loadTable(tableName);
    final beforeHlc = before!['hlc'] as String;

    await metadata.updateTable(tableName, displayName: 'Renamed for hlc check');

    final after = await metadata.loadTable(tableName);
    final afterHlc = after!['hlc'] as String;
    expect(afterHlc, isNot(beforeHlc), reason: 'hlc must advance on every real write, not stay frozen');
    expect(Hlc.parse(afterHlc) > Hlc.parse(beforeHlc), isTrue, reason: 'the new hlc must be strictly later');
  });

  test('updateField replaces every mutable attribute and preserves position', () async {
    final tableName = await createTestTable('SMD Update Field');
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
    final before = (await metadata.loadFields(tableName, includeDeleted: false)).single;
    expect(before.position, 0);

    await metadata.updateField(
      tableName,
      before.fieldName,
      displayName: 'Renamed Notes',
      format: 'integer',
      defaultValue: '42',
      isRequired: true,
    );

    final after = (await metadata.loadFields(tableName, includeDeleted: false)).single;
    expect(after.displayName, 'Renamed Notes');
    expect(after.format, 'integer');
    expect(after.defaultValue, '42');
    expect(after.required, isTrue);
    expect(after.position, 0, reason: 'position is not one of updateField\'s parameters -- must be preserved');
  });

  test('updateField rejects an empty name', () async {
    final tableName = await createTestTable('SMD Update Field Rejects Empty');
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
    final field = (await metadata.loadFields(tableName, includeDeleted: false)).single;

    expect(
      () => metadata.updateField(
        tableName,
        field.fieldName,
        displayName: '  ',
        format: 'text',
        isRequired: false,
      ),
      throwsArgumentError,
    );
  });

  test('reorderFields applies a whole-set position replace', () async {
    final tableName = await createTestTable('SMD Reorder');
    await editor.addField(tableName: tableName, displayName: 'First', format: 'text');
    await editor.addField(tableName: tableName, displayName: 'Second', format: 'text');
    await editor.addField(tableName: tableName, displayName: 'Third', format: 'text');

    await metadata.reorderFields(tableName, ['third', 'first', 'second']);

    final rows = await metadata.loadFields(tableName, includeDeleted: false);
    expect(rows.map((r) => r.fieldName), ['third', 'first', 'second']);
    expect(rows.map((r) => r.position), [0, 1, 2]);
  });

  test('softDeleteField hides a field from the active list, restoreField brings it back', () async {
    final tableName = await createTestTable('SMD Soft Delete Restore');
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
    final field = (await metadata.loadFields(tableName, includeDeleted: false)).single;

    await metadata.softDeleteField(tableName, field.fieldName);
    expect(await metadata.loadFields(tableName, includeDeleted: false), isEmpty);
    final withDeleted = await metadata.loadFields(tableName, includeDeleted: true);
    expect(withDeleted, hasLength(1));
    expect(withDeleted.single.isDeleted, isTrue);

    await metadata.restoreField(tableName, field.fieldName);
    final restored = await metadata.loadFields(tableName, includeDeleted: false);
    expect(restored, hasLength(1));
    expect(restored.single.isDeleted, isFalse);
    // The physical column and its format/default survived the round trip
    // untouched -- soft delete never touches DDL or the field's own data.
    expect(restored.single.fieldName, field.fieldName);
    expect(restored.single.format, field.format);
  });

  test('loadFields orders by position', () async {
    final tableName = await createTestTable('SMD Load Order');
    await editor.addField(tableName: tableName, displayName: 'Alpha', format: 'text');
    await editor.addField(tableName: tableName, displayName: 'Beta', format: 'text');

    final rows = await metadata.loadFields(tableName, includeDeleted: false);
    expect(rows.map((r) => r.fieldName), ['alpha', 'beta']);
  });

  test('softDeleteTable hides a table from SchemaRegistry.discoverTableNames, restoreTable brings it back', () async {
    final tableName = await createTestTable('SMD Soft Delete Table');
    final registry = SchemaRegistry();
    expect(await registry.discoverTableNames(), contains(tableName));

    await metadata.softDeleteTable(tableName);
    expect(await registry.discoverTableNames(), isNot(contains(tableName)));
    expect(await metadata.loadTable(tableName), isNull, reason: 'loadTable defaults to active-only');
    final withDeleted = await metadata.loadTable(tableName, includeDeleted: true);
    expect(withDeleted, isNotNull);

    await metadata.restoreTable(tableName);
    expect(await registry.discoverTableNames(), contains(tableName));
    expect(await metadata.loadTable(tableName), isNotNull);
  });

  test('softDeleteTable does not touch the table\'s own fields', () async {
    final tableName = await createTestTable('SMD Soft Delete Table Keeps Fields');
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');

    await metadata.softDeleteTable(tableName);
    // The field itself was never touched -- still active, still there,
    // physical column and data both untouched (soft-deleting the table is
    // pure table_definitions metadata, no cascade to field_definitions).
    final fields = await metadata.loadFields(tableName, includeDeleted: false);
    expect(fields, hasLength(1));
    expect(fields.single.fieldName, 'notes');
  });

  test('loadAllTables includes both active and soft-deleted tables', () async {
    final tableName = await createTestTable('SMD Load All Tables');
    await metadata.softDeleteTable(tableName);

    final all = await metadata.loadAllTables();
    final match = all.where((t) => t.tableName == tableName);
    expect(match, hasLength(1));
    expect(match.single.isDeleted, isTrue);
  });
}
