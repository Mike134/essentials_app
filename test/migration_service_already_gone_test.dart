// Regression test for a real stuck orphan: migration_log id
// 1787789550490409 ("DROP TABLE script_delete_1787789549921449") failed
// with "no such table" on device MIKE-CU because a prior sync had already
// removed the table through a different path, and MigrationService.applyPending
// recorded that as a permanent 'failed' row -- halting every later migration
// for that device until someone manually retracted the migration_log row.
// Retracting stopped it from ever reaching hub.db too, where the table was
// still physically present, leaving an orphaned empty physical table there.
//
// Fix: MigrationService._attempt now treats "no such table"/"no such column"
// (the mirror image of "already exists"/"duplicate column name") as an
// idempotent no-op per statement -- a DROP-type statement failing this way
// has also already achieved its goal state -- instead of a fatal failure.
// See lib/db/migration_service.dart's own doc comment on
// _isAlreadyGoneError. This test proves that directly: force the exact
// "already physically dropped, but this device doesn't know it" state by
// deleting the local migration_status row for an already-applied DROP TABLE
// migration, then re-run applyPending and confirm it records 'succeeded'
// (not 'failed') and the pipeline keeps processing later migrations rather
// than halting.
//
// Same isolation discipline as every other SchemaEditorService-using test
// file since the Essentials v2 Phase 1 Step 3 incident: run this file on its
// own (`flutter test test/migration_service_already_gone_test.dart`), never
// chained with other schema-engine test files in one invocation.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/migration_service.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/util/device_id.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

void main() {
  late SqliteCrdt db;
  late String deviceId;
  final editor = SchemaEditorService();
  final metadata = SchemaMetadataDao();
  final migrations = MigrationService();
  final runTag = DateTime.now().microsecondsSinceEpoch;

  setUpAll(() async {
    db = await DatabaseHelper.instance.crdt;
    deviceId = await DeviceId.resolve();
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  Future<int> latestMigrationId() async {
    final rows = await db.query('SELECT id FROM migration_log ORDER BY id DESC LIMIT 1');
    return rows.first['id'] as int;
  }

  test(
    're-attempting an already-physically-gone DROP TABLE records succeeded, not failed',
    () async {
      final tableName = await editor.createTable(displayName: 'MSAG Already Gone $runTag');

      // Real two-stage delete: stage 1 (soft-delete) then stage 2
      // (dropTable), which authors and applies a real DROP TABLE migration.
      await metadata.softDeleteTable(tableName);
      await editor.dropTable(tableName);
      final dropMigrationId = await latestMigrationId();

      final physicalBefore = await db.query(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [tableName],
      );
      expect(physicalBefore, isEmpty);

      final before = await db.query(
        'SELECT outcome FROM migration_status WHERE migration_id = ?1 AND device_id = ?2',
        [dropMigrationId, deviceId],
      );
      expect(before.single['outcome'], 'succeeded');

      // Simulate the real incident: this device's own migration_status
      // record for the already-applied DROP TABLE goes missing (a prior
      // sync/race in the real case) -- a real synced tombstone via
      // crdt.execute, not a raw bypass.
      await db.execute(
        'DELETE FROM migration_status WHERE migration_id = ?1 AND device_id = ?2',
        [dropMigrationId, deviceId],
      );
      final cleared = await db.query(
        'SELECT 1 FROM migration_status WHERE migration_id = ?1 AND device_id = ?2 AND is_deleted = 0',
        [dropMigrationId, deviceId],
      );
      expect(cleared, isEmpty);

      // The table is already physically gone -- applyPending will
      // re-attempt this migration's DROP TABLE and hit "no such table".
      await migrations.applyPending();

      final after = await db.query(
        'SELECT outcome, error_message FROM migration_status '
        'WHERE migration_id = ?1 AND device_id = ?2 AND is_deleted = 0',
        [dropMigrationId, deviceId],
      );
      expect(after, hasLength(1));
      expect(after.single['outcome'], 'succeeded');
      expect(after.single['error_message'], isNull);
    },
  );

  test(
    'the pipeline is not halted by an already-gone collision -- later migrations still apply',
    () async {
      final tableName = await editor.createTable(displayName: 'MSAG Pipeline Continues $runTag');
      await metadata.softDeleteTable(tableName);
      await editor.dropTable(tableName);
      final dropMigrationId = await latestMigrationId();

      // Force the same "forgot I already dropped this" state as above.
      await db.execute(
        'DELETE FROM migration_status WHERE migration_id = ?1 AND device_id = ?2',
        [dropMigrationId, deviceId],
      );

      // Author a genuinely new, later migration (a real CREATE TABLE via
      // createTable) *before* running applyPending, so both are pending at
      // once -- exactly the shape that would have permanently halted this
      // device's pipeline under the old halt-on-first-failure behavior.
      final laterTableName = await editor.createTable(displayName: 'MSAG Later $runTag');
      await metadata.softDeleteTable(laterTableName);
      await editor.dropTable(laterTableName);
      final laterMigrationId = await latestMigrationId();

      await migrations.applyPending();

      final dropStatus = await db.query(
        'SELECT outcome FROM migration_status WHERE migration_id = ?1 AND device_id = ?2',
        [dropMigrationId, deviceId],
      );
      expect(dropStatus.single['outcome'], 'succeeded');

      final laterStatus = await db.query(
        'SELECT outcome FROM migration_status WHERE migration_id = ?1 AND device_id = ?2',
        [laterMigrationId, deviceId],
      );
      expect(laterStatus.single['outcome'], 'succeeded');
    },
  );
}
