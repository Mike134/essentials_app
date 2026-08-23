// Proves Essentials v2 Phase 1 build order step 5's wiring --
// table_registry.dart's loadEffectiveTables() now sourcing from
// SchemaRegistry -- against the REAL essentials.db. Run with
// `flutter test test/table_registry_v2_test.dart`.
//
// Deliberately calls loadEffectiveTables() directly rather than going
// through widget_test.dart's full app render -- that file opens a real
// SyncService connection to whatever server is reachable, which is
// exactly the mechanism that caused the Step 3 incident (see CLAUDE.md
// "Essentials v2 Phase 1 -- Step 3"). This test never touches
// SyncService, so it's safe to run even with the tray-hosted server up.
//
// Same per-run-unique-tag/tombstone-only-cleanup discipline as the other
// v2 test files.
import 'package:essentials_app/config/table_registry.dart';
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/sql_helpers.dart';
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

  test('loadEffectiveTables includes a table created through SchemaEditorService', () async {
    final tableName = await createTestTable('TR Wiring Check');
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');

    final configs = await loadEffectiveTables();
    final match = configs.where((c) => c.tableName == tableName);
    expect(match, hasLength(1));
    expect(match.first.fields.map((f) => f.column), contains('notes'));
  });

  test('loadEffectiveTables never includes an infra table', () async {
    final configs = await loadEffectiveTables();
    final names = configs.map((c) => c.tableName).toSet();
    for (final infra in const [
      'table_definitions',
      'field_definitions',
      'migration_log',
      'migration_status',
      'table_column_settings',
      'table_view_settings',
      'app_settings',
      'device_settings',
      'table_group',
      'android_metadata',
    ]) {
      expect(names, isNot(contains(infra)));
    }
  });

  test('loadEffectiveTables skips a table with schema drift instead of crashing', () async {
    final tableName = await createTestTable('TR Drift Skip');
    // Simulate a migration that landed metadata but never actually
    // applied on this device -- via the real crdt-tracked upsert path,
    // not a raw SQL bypass (see CLAUDE.md Step 3's lesson).
    await db.upsert('field_definitions', {
      'table_name': tableName,
      'field_name': 'never_actually_created',
      'display_name': 'Never Actually Created',
      'format': 'text',
      'required': 0,
      'position': 0,
    });

    // Must not throw -- the one bad table is skipped, everything else
    // still loads.
    final configs = await loadEffectiveTables();
    expect(configs.map((c) => c.tableName), isNot(contains(tableName)));
  });
}
