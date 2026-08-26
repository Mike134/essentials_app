// Essentials v2 Phase 5 build order step 4 -- EventDispatchService.dispatch
// against the real essentials.db. Only the non-UI half (dispatch --
// finding bindings, running the right script) is covered here;
// dispatchAndApplyEffects's SnackBar/Navigator half needs a real widget
// tree and is exercised via GenericFormScreen/GenericListScreen's own
// build-verified wiring instead (see claude/essentials-v2-phase5-design.md
// step 4's write-up). Run this file on its own, never chained with another
// SchemaEditorService.createTable-using test file in the same `flutter
// test` invocation.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/event_dispatch_service.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'support/schema_test_cleanup.dart';

void main() {
  late SqliteCrdt db;
  final editor = SchemaEditorService();
  final metadata = SchemaMetadataDao();
  final runTag = DateTime.now().microsecondsSinceEpoch;

  setUpAll(() async {
    db = await DatabaseHelper.instance.crdt;
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  Future<String> createTestTable(String label) async {
    final tableName = await editor.createTable(displayName: '$label $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    return tableName;
  }

  /// Directly inserts real `script_definitions`/`event_definitions` rows
  /// -- no UI to do this through exists yet (build order step 5), same
  /// "insert real rows for what a later step's UI will eventually create"
  /// approach every other v2 test file already uses. **Registers real,
  /// synced tombstone cleanup for both rows via `addTearDown`** -- these
  /// two tables are just as `sqlite_crdt`-tracked as any other, and a
  /// bare `INSERT` with no matching cleanup at all (this helper's own
  /// first version) leaks a permanently-live row into the real
  /// production `essentials.db`, not just inert test residue -- caught
  /// and fixed same session, see claude/essentials-v2-phase5-design.md's
  /// step 4 write-up.
  Future<void> bindScript(
    SqliteCrdt db, {
    required String code,
    required String? tableName,
    required String eventType,
    String? fieldName,
    bool enabled = true,
  }) async {
    await db.execute(
      'INSERT INTO script_definitions (name, code, description) VALUES (?1, ?2, ?3)',
      ['test-$runTag', code, null],
    );
    final scriptRows = await db.query(
      'SELECT id FROM script_definitions WHERE name = ?1 ORDER BY id DESC LIMIT 1',
      ['test-$runTag'],
    );
    final scriptId = scriptRows.first['id'] as int;
    await db.execute(
      'INSERT INTO event_definitions '
      '(script_id, event_type, table_name, field_name, enabled) '
      'VALUES (?1, ?2, ?3, ?4, ?5)',
      [scriptId, eventType, tableName, fieldName, enabled ? 1 : 0],
    );
    final eventRows = await db.query(
      'SELECT id FROM event_definitions WHERE script_id = ?1 ORDER BY id DESC LIMIT 1',
      [scriptId],
    );
    final eventId = eventRows.first['id'] as int;
    addTearDown(() async {
      await db.execute('UPDATE event_definitions SET is_deleted = 1 WHERE id = ?1', [eventId]);
      await db.execute('UPDATE script_definitions SET is_deleted = 1 WHERE id = ?1', [scriptId]);
    });
  }

  test('dispatch runs a bound, enabled script and returns its outcome', () async {
    final tableName = await createTestTable('Dispatch Basic');
    await bindScript(db, code: "notify('ran');", tableName: tableName, eventType: 'record_created');

    final results = await EventDispatchService().dispatch(
      tableName: tableName,
      eventType: 'record_created',
      recordId: 1,
    );

    expect(results, hasLength(1));
    expect(results.single.outcome.succeeded, isTrue);
    expect(results.single.effects.notifications, ['ran']);
  });

  test('dispatch finds nothing when no binding exists for this event', () async {
    final tableName = await createTestTable('Dispatch None');
    final results = await EventDispatchService().dispatch(
      tableName: tableName,
      eventType: 'record_created',
      recordId: 1,
    );
    expect(results, isEmpty);
  });

  test('a disabled binding is not run', () async {
    final tableName = await createTestTable('Dispatch Disabled');
    await bindScript(
      db,
      code: "notify('should not run');",
      tableName: tableName,
      eventType: 'record_created',
      enabled: false,
    );

    final results = await EventDispatchService().dispatch(
      tableName: tableName,
      eventType: 'record_created',
      recordId: 1,
    );
    expect(results, isEmpty);
  });

  test('field_changed only matches its own field name', () async {
    final tableName = await createTestTable('Dispatch Field');
    await bindScript(
      db,
      code: "notify('status changed');",
      tableName: tableName,
      eventType: 'field_changed',
      fieldName: 'status',
    );

    final matching = await EventDispatchService().dispatch(
      tableName: tableName,
      eventType: 'field_changed',
      fieldName: 'status',
      recordId: 1,
    );
    expect(matching, hasLength(1));

    final nonMatching = await EventDispatchService().dispatch(
      tableName: tableName,
      eventType: 'field_changed',
      fieldName: 'other_field',
      recordId: 1,
    );
    expect(nonMatching, isEmpty);
  });

  test('a script with a real database write actually persists it', () async {
    final tableName = await createTestTable('Dispatch Write');
    await editor.addField(tableName: tableName, displayName: 'Label', format: 'text');
    final fields = await metadata.loadFields(tableName, includeDeleted: false);
    final labelField = fields.single.fieldName;
    await bindScript(
      db,
      code: "table('$tableName').create({$labelField: 'from dispatched script'});",
      tableName: tableName,
      eventType: 'record_created',
    );

    final results = await EventDispatchService().dispatch(tableName: tableName, eventType: 'record_created');
    expect(results, hasLength(1));
    expect(results.single.outcome.succeeded, isTrue);

    final rows = await db.query('SELECT "$labelField" AS v FROM "$tableName" WHERE is_deleted = 0');
    expect(rows, hasLength(1));
    expect(rows.single['v'], 'from dispatched script');
  });

  test('dispatch with a null tableName matches an app_launch (scheduled) binding', () async {
    // Asserts against this test's own uniquely-tagged notification, not
    // the total result count -- a real app_launch binding of Mike's own
    // now legitimately exists on the live db (from his interactive
    // testing of build order step 6), same "don't assume you're the
    // only row of this shape" lesson already learned once for
    // view_definitions_dao_test.dart once real Calendar UI existed. Note
    // this also means dispatch() genuinely re-runs Mike's own real
    // app_launch script(s) as a side effect of running this test --
    // harmless today (his only one is `x=1;`), but worth remembering if
    // a future real app_launch script ever has a visible side effect.
    await bindScript(db, code: "notify('launched $runTag');", tableName: null, eventType: 'app_launch');

    final results = await EventDispatchService().dispatch(tableName: null, eventType: 'app_launch');
    final matchingMessages = [
      for (final r in results)
        for (final m in r.effects.notifications)
          if (m == 'launched $runTag') m,
    ];
    expect(matchingMessages, ['launched $runTag']);

    // A table-scoped event never matches a null-table binding, or vice
    // versa -- confirms the `IS` comparison isn't accidentally treating
    // null as a wildcard. A nonexistent table name is used deliberately
    // so this can never coincidentally match one of Mike's own real
    // per-table bindings.
    final scoped = await EventDispatchService().dispatch(
      tableName: 'no_such_table_$runTag',
      eventType: 'app_launch',
    );
    expect(scoped, isEmpty);
  });
}
