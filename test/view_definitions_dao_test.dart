// Proves Essentials v2 Phase 3 build order step 1's ViewDefinitionsDao
// against the REAL essentials.db. Run with
// `flutter test test/view_definitions_dao_test.dart` -- on its own, never
// chained with other SchemaEditorService.createTable-using test files (see
// CLAUDE.md "Essentials v2 Phase 1 -- Step 3" for why).
//
// view_definitions itself is bootstrapped once, out-of-band, by
// tool/add_view_definitions_table.dart -- this file assumes it already
// exists (same assumption every other v2 DAO test makes about
// table_definitions/field_definitions).
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/view_definitions_dao.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/schema_test_cleanup.dart';

void main() {
  final editor = SchemaEditorService();
  final metadata = SchemaMetadataDao();
  final views = ViewDefinitionsDao();
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

  test('createView returns a real timestamp+random view_id, not a small sequential one', () async {
    final tableName = await createTestTable('VD Create Table');
    final viewId = await views.createView(
      tableName: tableName,
      viewType: 'list',
      displayName: 'My List View',
    );
    addTearDown(() => views.softDeleteView(viewId));

    // Timestamp+random ids from this scheme are always well past a plain
    // small AUTOINCREMENT counter -- the actual regression risk if view_id's
    // own DEFAULT were ever silently bypassed (see GenericDao.insert's own
    // doc comment for the exact failure shape this guards against).
    expect(viewId, greaterThan(1000000000000));
  });

  test('loadViewsForTable returns only active list/kanban views for that table, ordered by position', () async {
    final tableName = await createTestTable('VD Load For Table');
    final id1 = await views.createView(tableName: tableName, viewType: 'list', displayName: 'First');
    final id2 = await views.createView(tableName: tableName, viewType: 'kanban', displayName: 'Second');
    addTearDown(() => views.softDeleteView(id1));
    addTearDown(() => views.softDeleteView(id2));

    final loaded = await views.loadViewsForTable(tableName);
    expect(loaded.map((v) => v.viewId), [id1, id2]);
    expect(loaded[0].displayName, 'First');
    expect(loaded[0].viewType, 'list');
    expect(loaded[1].displayName, 'Second');
    expect(loaded[1].viewType, 'kanban');
  });

  test('loadViewsForTable excludes a soft-deleted view and never returns another table\'s views', () async {
    final tableA = await createTestTable('VD Isolation A');
    final tableB = await createTestTable('VD Isolation B');
    final idA = await views.createView(tableName: tableA, viewType: 'list', displayName: 'A view');
    final idB = await views.createView(tableName: tableB, viewType: 'list', displayName: 'B view');
    addTearDown(() => views.softDeleteView(idB));

    await views.softDeleteView(idA);

    expect(await views.loadViewsForTable(tableA), isEmpty);
    final loadedB = await views.loadViewsForTable(tableB);
    expect(loadedB.map((v) => v.viewId), [idB]);
  });

  test('createView with tableName null + view_type calendar is the aggregate scope', () async {
    final viewId = await views.createView(
      tableName: null,
      viewType: 'calendar',
      displayName: 'Calendar',
      config: {
        'table_ids': ['x', 'y'],
      },
    );
    addTearDown(() => views.softDeleteView(viewId));

    // Verify the created row directly, by its own id -- not via
    // loadCalendarView(), which deliberately returns the first active
    // calendar-scoped row overall (its own doc comment: "reads the first
    // active match rather than assuming exactly one row exists"). Once
    // Phase 3's real CalendarScreen shipped, a real device can genuinely
    // already have created its own "Calendar" row through actual use
    // before this test ever runs, so this test's own row is not
    // guaranteed to be the one loadCalendarView() picks -- confirmed live,
    // this is exactly what broke here once Phase 3 Step 5 landed.
    final db = await DatabaseHelper.instance.crdt;
    final rows = await db.query('SELECT * FROM view_definitions WHERE view_id = ?1', [viewId]);
    expect(rows, hasLength(1));
    final created = ViewDefinition.fromRow(rows.first);
    expect(created.tableName, isNull);
    expect(created.viewType, 'calendar');
    expect(created.config['table_ids'], ['x', 'y']);

    // loadCalendarView() still honors the aggregate-scope contract itself
    // (some real, well-formed calendar-scoped row comes back) -- just not
    // necessarily *this* row, once more than one can legitimately exist.
    final aggregate = await views.loadCalendarView();
    expect(aggregate, isNotNull);
    expect(aggregate!.tableName, isNull);
    expect(aggregate.viewType, 'calendar');
  });

  test('renameView updates display_name only', () async {
    final tableName = await createTestTable('VD Rename');
    final viewId = await views.createView(tableName: tableName, viewType: 'list', displayName: 'Old name');
    addTearDown(() => views.softDeleteView(viewId));

    await views.renameView(viewId, 'New name');

    final loaded = await views.loadViewsForTable(tableName);
    expect(loaded.single.displayName, 'New name');
  });

  test('renameView rejects an empty name', () async {
    final tableName = await createTestTable('VD Rename Rejects Empty');
    final viewId = await views.createView(tableName: tableName, viewType: 'list', displayName: 'Real name');
    addTearDown(() => views.softDeleteView(viewId));

    expect(() => views.renameView(viewId, '   '), throwsArgumentError);
  });

  test('updateViewConfig replaces the stored config JSON', () async {
    final tableName = await createTestTable('VD Update Config');
    final viewId = await views.createView(
      tableName: tableName,
      viewType: 'list',
      displayName: 'Config Test',
      config: {'primary_field': 'title'},
    );
    addTearDown(() => views.softDeleteView(viewId));

    await views.updateViewConfig(viewId, {'primary_field': 'name', 'grouped': true});

    final loaded = await views.loadViewsForTable(tableName);
    expect(loaded.single.config, {'primary_field': 'name', 'grouped': true});
  });

  test('reorderViews replaces position for the given views', () async {
    final tableName = await createTestTable('VD Reorder');
    final id1 = await views.createView(tableName: tableName, viewType: 'list', displayName: 'One');
    final id2 = await views.createView(tableName: tableName, viewType: 'list', displayName: 'Two');
    addTearDown(() => views.softDeleteView(id1));
    addTearDown(() => views.softDeleteView(id2));

    await views.reorderViews(tableName, [id2, id1]);

    final loaded = await views.loadViewsForTable(tableName);
    expect(loaded.map((v) => v.viewId), [id2, id1]);
  });

  test('softDeleteView then restoreView round-trips, preserving config', () async {
    final tableName = await createTestTable('VD Restore');
    final viewId = await views.createView(
      tableName: tableName,
      viewType: 'kanban',
      displayName: 'Restorable',
      config: {'group_field': 'status'},
    );
    addTearDown(() => views.softDeleteView(viewId));

    await views.softDeleteView(viewId);
    expect(await views.loadViewsForTable(tableName), isEmpty);

    await views.restoreView(viewId);
    final loaded = await views.loadViewsForTable(tableName);
    expect(loaded.single.viewId, viewId);
    expect(loaded.single.config, {'group_field': 'status'});
  });

  test('loadAllViewsForTable returns active and soft-deleted views together', () async {
    final tableName = await createTestTable('VD Load All');
    final activeId = await views.createView(tableName: tableName, viewType: 'list', displayName: 'Active');
    final deletedId = await views.createView(tableName: tableName, viewType: 'kanban', displayName: 'Gone');
    addTearDown(() => views.softDeleteView(activeId));

    await views.softDeleteView(deletedId);

    final all = await views.loadAllViewsForTable(tableName);
    expect(all.map((v) => v.viewId), containsAll([activeId, deletedId]));
    expect(all.firstWhere((v) => v.viewId == activeId).isDeleted, isFalse);
    expect(all.firstWhere((v) => v.viewId == deletedId).isDeleted, isTrue);
  });
}
