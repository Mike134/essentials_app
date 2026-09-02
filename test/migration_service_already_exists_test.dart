// Regression test for a real incident (CLAUDE.md "Bug Fixes and
// Improvements" session, 2026-09-02): MIKE-12R's migration_status
// bookkeeping split across two resolved device identities
// (`Settings.Global.DEVICE_NAME` drifted), so the same physical device
// re-attempted a migration it had already physically applied under its
// other identity -- and legitimately collided with "table already exists",
// which MigrationService.applyPending recorded as a permanent 'failed'
// row, halting every later migration for that device until someone
// manually retracted the poisoned migration_log row.
//
// Fix: MigrationService._attempt now treats "already exists"/"duplicate
// column name" as an idempotent no-op per statement (the DDL's goal state
// is already achieved) instead of a fatal failure -- see
// lib/db/migration_service.dart's own doc comment on _isAlreadyExistsError.
// This test proves that directly: force the exact "already applied, but
// this device doesn't know it" state by deleting the local
// migration_status row for an already-applied migration, then re-run
// applyPending and confirm it records 'succeeded' (not 'failed') and the
// pipeline keeps processing later migrations rather than halting.
//
// Same isolation discipline as every other SchemaEditorService.createTable
// -using test file since the Essentials v2 Phase 1 Step 3 incident: run
// this file on its own (`flutter test test/migration_service_already_exists_test.dart`),
// never chained with other schema-engine test files in one invocation.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/migration_service.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/util/device_id.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'support/schema_test_cleanup.dart';

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

  Future<String> createTestTable(String label) async {
    final tableName = await editor.createTable(displayName: '$label $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    return tableName;
  }

  Future<int> latestMigrationId() async {
    final rows = await db.query('SELECT id FROM migration_log ORDER BY id DESC LIMIT 1');
    return rows.first['id'] as int;
  }

  test(
    're-attempting an already-physically-applied CREATE TABLE records succeeded, not failed',
    () async {
      await createTestTable('MSAE Already Applied');
      final migrationId = await latestMigrationId();

      // Confirm the normal, already-succeeded state before forcing the
      // "this device forgot" scenario.
      final before = await db.query(
        'SELECT outcome FROM migration_status WHERE migration_id = ?1 AND device_id = ?2',
        [migrationId, deviceId],
      );
      expect(before.single['outcome'], 'succeeded');

      // Simulate the real incident: this device's own migration_status
      // record for an already-applied migration goes missing (a device
      // identity split, in the real case) -- a real synced tombstone via
      // crdt.execute, not a raw bypass.
      await db.execute(
        'DELETE FROM migration_status WHERE migration_id = ?1 AND device_id = ?2',
        [migrationId, deviceId],
      );
      final cleared = await db.query(
        'SELECT 1 FROM migration_status WHERE migration_id = ?1 AND device_id = ?2 AND is_deleted = 0',
        [migrationId, deviceId],
      );
      expect(cleared, isEmpty);

      // The table is still physically there -- applyPending will
      // re-attempt this migration's CREATE TABLE and hit "already exists".
      await migrations.applyPending();

      final after = await db.query(
        'SELECT outcome, error_message FROM migration_status '
        'WHERE migration_id = ?1 AND device_id = ?2 AND is_deleted = 0',
        [migrationId, deviceId],
      );
      expect(after, hasLength(1));
      expect(after.single['outcome'], 'succeeded');
      expect(after.single['error_message'], isNull);
    },
  );

  test(
    'the pipeline is not halted by an already-exists collision -- later migrations still apply',
    () async {
      final tableName = await createTestTable('MSAE Pipeline Continues');
      final migrationId = await latestMigrationId();

      // Force the same "forgot I already did this" state as above.
      await db.execute(
        'DELETE FROM migration_status WHERE migration_id = ?1 AND device_id = ?2',
        [migrationId, deviceId],
      );

      // Author a genuinely new, later migration (a real ADD COLUMN via
      // addField) *before* running applyPending, so both are pending at
      // once -- exactly the shape that would have infinite-looped/halted
      // under the old halt-on-first-failure behavior.
      await editor.addField(tableName: tableName, displayName: 'Note $runTag', format: 'text');

      await migrations.applyPending();

      final fieldRows = await db.query(
        'SELECT field_name FROM field_definitions '
        'WHERE table_name = ?1 AND display_name = ?2 AND is_deleted = 0',
        [tableName, 'Note $runTag'],
      );
      expect(fieldRows, hasLength(1));
      final fieldName = fieldRows.single['field_name'] as String;

      final columns = await db.query('PRAGMA table_info("$tableName")');
      final columnNames = [for (final c in columns) c['name'] as String];
      expect(columnNames, contains(fieldName));

      final laterMigrationId = await latestMigrationId();
      final laterStatus = await db.query(
        'SELECT outcome FROM migration_status WHERE migration_id = ?1 AND device_id = ?2',
        [laterMigrationId, deviceId],
      );
      expect(laterStatus.single['outcome'], 'succeeded');
    },
  );
}
