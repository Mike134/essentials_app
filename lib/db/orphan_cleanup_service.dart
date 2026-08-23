import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'database_helper.dart';
import 'sql_helpers.dart';
import 'table_discovery_service.dart';

/// Startup pass (CLAUDE.md "Table Discovery phase", Part D): deletes rows
/// in the per-table settings tables whose `table_name` no longer refers to
/// a real table in `sqlite_master` -- e.g. Mike drops `class` in Letos,
/// and its now-orphaned `table_column_settings`/`table_view_settings`/
/// `table_group`/`field_metadata` rows would otherwise accumulate forever
/// with nothing to reference them. Runs once per launch, right alongside
/// [TableDiscoveryService]'s own discovery pass (same "at launch, not
/// live" scope), since it needs that pass's live table list anyway.
///
/// `device_settings` is deliberately not included here even though Part D's
/// original checklist named it alongside the other four: every key
/// currently written there (`font_size`, `sidebar_collapsed:<group_name>`)
/// is keyed by device or group name, never by `table_name` -- there is
/// nothing table-scoped in it today to orphan. Revisit this if a future
/// per-table `device_settings` key convention is ever introduced.
class OrphanCleanupService {
  OrphanCleanupService({TableDiscoveryService? discovery})
    : _discovery = discovery ?? TableDiscoveryService();

  final TableDiscoveryService _discovery;

  Future<SqliteCrdt> get _db async => DatabaseHelper.instance.crdt;

  /// Returns the table names actually cleaned up (empty if nothing was
  /// orphaned) -- callers don't have to do anything with this, but it's
  /// useful for a startup debug log rather than cleaning up silently with
  /// no trace.
  Future<Set<String>> cleanupOrphans() async {
    final db = await _db;
    final liveTableNames = (await _discovery.discoverTableNames()).toSet();

    final orphaned = <String>{};
    for (final settingsTable in const [
      'table_column_settings',
      'table_view_settings',
      'table_group',
      // 'field_metadata' deliberately omitted -- gone as of the Essentials
      // v2 Phase 1 wipe (superseded by field_definitions), so this table no
      // longer exists to query. Minimal unblock only -- this whole file is
      // still slated for deletion/rework once SchemaRegistry replaces
      // TableDiscoveryService (claude/essentials-v2-step2-wipe-procedure.md,
      // "Lower priority, but will break loudly"), not touched further here.
    ]) {
      final rows = await db.query(
        'SELECT DISTINCT table_name FROM $settingsTable WHERE is_deleted = 0',
      );
      for (final row in rows) {
        final tableName = row['table_name'] as String;
        if (liveTableNames.contains(tableName)) continue;
        orphaned.add(tableName);
        await db.deleteWhere(settingsTable, {'table_name': tableName});
      }
    }
    return orphaned;
  }
}
