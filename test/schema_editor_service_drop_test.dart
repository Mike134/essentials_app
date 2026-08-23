// Proves Essentials v2 Phase 1 build order step 9 --
// SchemaEditorService.dropTable/dropField, stage-2 permanent delete -- and
// the SyncService.lastConnectedAt-based gating in
// lib/util/permanent_delete_gate.dart. Run with
// `flutter test test/schema_editor_service_drop_test.dart`.
//
// Same safety discipline as schema_editor_service_v2_test.dart: every
// table/field this test creates is throwaway, tagged with a per-run-unique
// suffix, and cleaned up via tombstone-only writes (never a raw hard
// DELETE against a sqlite_crdt-managed table -- see CLAUDE.md's Essentials
// v2 Phase 1 -- Step 3 incident write-up for why that's a hard rule, not a
// style preference). Runs against the real db, not a scratch copy, since
// dropTable/dropField's whole point is exercising the real
// migration_log/MigrationService.applyPending pipeline.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/sql_helpers.dart';
import 'package:essentials_app/util/device_id.dart';
import 'package:essentials_app/util/permanent_delete_gate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'support/schema_test_cleanup.dart';

void main() {
  late SqliteCrdt db;
  final editor = SchemaEditorService();
  final metadata = SchemaMetadataDao();
  // Per-run-unique tag -- see schema_editor_service_v2_test.dart's file
  // header for why this matters (table_name/field_name stay reserved
  // forever once used, even tombstoned, unless stage-2 actually drops
  // them -- and several tests below deliberately don't reach stage 2).
  final runTag = DateTime.now().microsecondsSinceEpoch;

  setUpAll(() async {
    db = await DatabaseHelper.instance.crdt;
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  /// Registers cleanup as this test's own tearDown -- see [dropTestTable]'s
  /// doc comment for why this must be a real, synced drop, not a raw local
  /// `DROP TABLE`. Safe even for a test whose own body already fully
  /// dropped the table ([dropTestTable] swallows the resulting no-op), and
  /// for a linked pair whose parent's own drop was refused mid-test -- see
  /// generic_dao_linked_fields_test.dart's `createTestTable` doc comment
  /// for why `addTearDown`'s LIFO ordering (child before parent) makes
  /// that safe here too.
  Future<String> createTestTable(String label) async {
    final tableName = await editor.createTable(displayName: '$label $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    return tableName;
  }

  group('dropTable', () {
    test('refuses a table that is not stage-1 soft-deleted', () async {
      final tableName = await createTestTable('SETV2 Drop Not Soft Deleted');
      expect(() => editor.dropTable(tableName), throwsStateError);

      // Still physically there -- refusal didn't half-apply anything.
      final tables = await db.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [tableName],
      );
      expect(tables, hasLength(1));
    });

    test(
      'drops the physical table and tombstones its table_definitions/field_definitions/'
      'table_column_settings/table_view_settings rows',
      () async {
        final tableName = await createTestTable('SETV2 Drop Table Full');
        await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
        final deviceId = await DeviceId.resolve();
        await db.upsert('table_column_settings', {
          'table_name': tableName,
          'device_id': deviceId,
          'column_name': 'notes',
          'width': 120.0,
          'display_order': 0,
          'visible': 1,
        });
        await db.upsert('table_view_settings', {
          'table_name': tableName,
          'device_id': deviceId,
          'sort_column': 'notes',
          'sort_direction': 'asc',
        });

        await metadata.softDeleteTable(tableName);
        await editor.dropTable(tableName);

        final tables = await db.query(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?1",
          [tableName],
        );
        expect(tables, isEmpty, reason: 'physical table should be genuinely gone');

        final tableDefRows = await db.query(
          'SELECT is_deleted FROM table_definitions WHERE table_name = ?1',
          [tableName],
        );
        expect(tableDefRows.single['is_deleted'], 1);

        final fieldDefRows = await db.query(
          'SELECT is_deleted FROM field_definitions WHERE table_name = ?1',
          [tableName],
        );
        expect(fieldDefRows.single['is_deleted'], 1);

        final columnSettingsRows = await db.query(
          'SELECT is_deleted FROM table_column_settings WHERE table_name = ?1',
          [tableName],
        );
        expect(columnSettingsRows.single['is_deleted'], 1);

        final viewSettingsRows = await db.query(
          'SELECT is_deleted FROM table_view_settings WHERE table_name = ?1',
          [tableName],
        );
        expect(viewSettingsRows.single['is_deleted'], 1);

        final logRows = await db.query(
          'SELECT id FROM migration_log WHERE sql_text = ?1 AND is_deleted = 0',
          ['DROP TABLE "$tableName"'],
        );
        expect(logRows, hasLength(1));
        final statusRows = await db.query(
          'SELECT outcome FROM migration_status WHERE migration_id = ?1 AND device_id = ?2',
          [logRows.first['id'], deviceId],
        );
        expect(statusRows.single['outcome'], 'succeeded');
      },
    );

    test('refuses a table still linked to by another table\'s live field', () async {
      final target = await createTestTable('SETV2 Drop Linked Target');
      final source = await createTestTable('SETV2 Drop Linked Source');
      await editor.addField(
        tableName: source,
        displayName: 'Target',
        format: 'select',
        optionsJson: '{"mode":"linked","table":"$target","on_delete":"restrict"}',
      );

      await metadata.softDeleteTable(target);
      await expectLater(() => editor.dropTable(target), throwsStateError);

      // Still physically there -- the refusal actually blocked the drop.
      final tables = await db.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [target],
      );
      expect(tables, hasLength(1));
    });

    test('frees the display name for reuse once the table is actually dropped', () async {
      final label = 'SETV2 Drop Name Reuse $runTag';
      final first = await editor.createTable(displayName: label);
      addTearDown(() => dropTestTable(editor, metadata, first));

      await metadata.softDeleteTable(first);
      await editor.dropTable(first);

      final second = await editor.createTable(displayName: label);
      addTearDown(() => dropTestTable(editor, metadata, second));

      expect(second, first, reason: 'the physical name is genuinely free again after stage 2');
    });
  });

  group('dropField', () {
    test('refuses a field that is not stage-1 soft-deleted', () async {
      final tableName = await createTestTable('SETV2 Drop Field Not Soft Deleted');
      await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
      expect(() => editor.dropField(tableName, 'notes'), throwsStateError);

      final columns = await db.query('PRAGMA table_info("$tableName")');
      expect(columns.any((c) => c['name'] == 'notes'), isTrue);
    });

    test('drops the physical column and tombstones field_definitions/table_column_settings', () async {
      final tableName = await createTestTable('SETV2 Drop Field Full');
      await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
      final deviceId = await DeviceId.resolve();
      await db.upsert('table_column_settings', {
        'table_name': tableName,
        'device_id': deviceId,
        'column_name': 'notes',
        'width': 120.0,
        'display_order': 0,
        'visible': 1,
      });

      await metadata.softDeleteField(tableName, 'notes');
      await editor.dropField(tableName, 'notes');

      final columns = await db.query('PRAGMA table_info("$tableName")');
      expect(columns.any((c) => c['name'] == 'notes'), isFalse);

      final fieldRows = await db.query(
        'SELECT is_deleted FROM field_definitions WHERE table_name = ?1 AND field_name = ?2',
        [tableName, 'notes'],
      );
      expect(fieldRows.single['is_deleted'], 1);

      final columnSettingsRows = await db.query(
        'SELECT is_deleted FROM table_column_settings WHERE table_name = ?1 AND column_name = ?2',
        [tableName, 'notes'],
      );
      expect(columnSettingsRows.single['is_deleted'], 1);

      final logRows = await db.query(
        'SELECT outcome FROM migration_log ml '
        'JOIN migration_status ms ON ms.migration_id = ml.id '
        'WHERE ml.sql_text = ?1 AND ml.is_deleted = 0',
        ['ALTER TABLE "$tableName" DROP COLUMN "notes"'],
      );
      expect(logRows.single['outcome'], 'succeeded');
    });

    test('frees the field name for reuse once the field is actually dropped', () async {
      final tableName = await createTestTable('SETV2 Drop Field Name Reuse');
      await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
      await metadata.softDeleteField(tableName, 'notes');
      await editor.dropField(tableName, 'notes');

      final regenerated = await editor.previewFieldIdentifier(tableName, 'Notes');
      expect(regenerated, 'notes', reason: 'the physical column name is genuinely free again');
    });
  });

  group('permanent_delete_gate', () {
    // SyncService.lastConnectedAt only ever becomes non-null via a real
    // onConnect callback from a live server connection -- none of these
    // tests call SyncService.connect(), so it's guaranteed null here,
    // exactly matching this app's real cold-start state before the first
    // successful connect of a session. That's exactly the safe-default
    // case worth proving: nothing should ever look "confirmed synced"
    // before this device has connected to the server at all.
    test('never looks synced before this device has connected to the server this session', () {
      final now = Hlc.now('test-node').toString();
      expect(tombstoneLikelySynced(now), isFalse);
      expect(permanentDeleteDisabledReason(now), isNotNull);
    });
  });
}
