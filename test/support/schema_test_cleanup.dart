import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';

/// Real, synced cleanup for a throwaway table created via
/// [SchemaEditorService.createTable] during a test -- never a raw local
/// `DROP TABLE IF EXISTS`.
///
/// [SchemaEditorService.createTable] writes a real `migration_log` entry
/// (that's the whole point of Essentials v2's schema engine -- see
/// claude/essentials-v2-phase1-design.md), which syncs to every other
/// device. A raw local `DROP TABLE IF EXISTS` only ever drops the
/// physical table on whichever device is running the test -- the create
/// migration already reached every other device, and nothing ever tells
/// them to drop it back. This is exactly the pattern that caused a real,
/// serious incident: every v2 test file used a raw local drop for months,
/// silently leaking throwaway tables onto the server's `hub.db` and any
/// connected device forever, until the server's physical table count
/// crossed SQLite's hard 500-term compound-SELECT limit and broke sync
/// for every device -- see CLAUDE.md "Real-device cross-platform
/// verification session" -- Bug 2, for the full incident and recovery.
///
/// Uses the real stage-1/stage-2 pipeline ([SchemaMetadataDao
/// .softDeleteTable] then [SchemaEditorService.dropTable]) so the drop
/// itself is a real, synced `migration_log` entry too -- every other
/// device picks it up the normal way instead of accumulating drift.
///
/// **Checks physical existence first, rather than just swallowing
/// whatever [SchemaEditorService.dropTable] throws -- a real, serious
/// bug found immediately after this file was first written.** Some tests
/// call `dropTable` themselves as the thing under test, leaving nothing
/// for this cleanup to do; the first version of this function just
/// called `dropTable` again unconditionally and swallowed the error,
/// assuming that was harmless. It wasn't: `dropTable` doesn't throw for
/// an already-physically-gone table (its `is_deleted` precondition still
/// passes -- the row was already tombstoned), so it proceeds to author a
/// *second* real `DROP TABLE` migration, which then genuinely fails when
/// applied (`no such table`) and gets recorded as a permanent `'failed'`
/// `migration_status` row for this device. `MigrationService.applyPending`
/// deliberately halts at the first `'failed'` migration for a device and
/// never processes anything after it (no silent auto-retry, by design --
/// see `MigrationService`'s own doc comment) -- so that one poisoned
/// entry silently blocked every *later* test's `createTable`/`addField`
/// from ever actually applying for the rest of that test run, and would
/// have kept blocking real app sync too, since it's the same
/// `essentials.db` and the same halt-on-failure logic. Recovered by
/// retracting the poisoned `migration_log` row (`is_deleted = 1`, the
/// same convention `schema_admin`'s own "retract a failed migration"
/// workflow already uses) -- but the real fix is not attempting the
/// second drop at all.
Future<void> dropTestTable(
  SchemaEditorService editor,
  SchemaMetadataDao metadata,
  String tableName,
) async {
  final crdt = await DatabaseHelper.instance.crdt;
  final physical = await crdt.query(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
    [tableName],
  );
  if (physical.isEmpty) return;

  try {
    await metadata.softDeleteTable(tableName);
    await editor.dropTable(tableName);
  } catch (_) {
    // Refused (e.g. still linked from another table whose own cleanup
    // hasn't run yet -- addTearDown's LIFO order should prevent this in
    // practice, see generic_dao_linked_fields_test.dart) -- nothing safe
    // to do about it here; the table just stays behind as residue.
  }
}
