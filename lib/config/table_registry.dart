import '../db/orphan_cleanup_service.dart';
import '../db/schema_registry.dart';
import '../db/table_discovery_service.dart';
import '../models/table_config.dart';

/// Startup entry point: runs orphan cleanup once, then returns the
/// effective nav table list for [HomeShell] to build groups from.
///
/// Essentials v2 Phase 1, build order step 5 -- every table now resolves
/// through [SchemaRegistry.buildConfig] (`table_definitions`/
/// `field_definitions`), not [TableDiscoveryService.buildConfig]'s old
/// `PRAGMA`-heuristic path. That old path is permanently broken now, for
/// every table, not just new ones -- it unconditionally queries
/// `field_metadata`, which the v2 wipe removed for good (superseded by
/// `field_definitions`; see CLAUDE.md "Essentials v2 Phase 1"). The old
/// `subscription`/`orders` special-casing (`table_configs.dart`'s
/// `buildSubscriptionConfig`/`buildOrdersConfig`) is gone from this file
/// too -- neither table exists post-wipe, and per the clean-slate
/// directive, if Mike ever recreates either one, it goes through this
/// exact same path like any table he'd never had before, no special
/// status. `table_configs.dart` itself is deliberately left in place,
/// unreferenced from here -- `lib/screens/order_split_pane_screen.dart`
/// still imports it, and the wipe procedure doc explicitly says to keep
/// that screen (unwired, not deleted) for whenever `orders`/`order_items`
/// come back.
///
/// [SchemaRegistry.discoverTableNames] drives the loop (`table_definitions`,
/// not `sqlite_master`) -- a table created directly in Letos/DBeaver
/// without going through [SchemaEditorService.createTable] has no
/// `table_definitions` row and is silently absent from nav, not crashed on
/// or force-registered. That's a deliberate consequence of v2 schema
/// creation now living exclusively in the app, not a bug: the whole point
/// of routing `CREATE TABLE` through `migration_log` is that every device
/// learns about a new table the same way, and a table only Letos knows
/// about on one device has no such record to propagate.
///
/// [TableDiscoveryService.discoverTableNames] (`sqlite_master`-based) is
/// still used for [OrphanCleanupService] -- physical existence, not
/// metadata soft-deletion, is the right check for "does this settings row
/// still point at something real": a stage-1-soft-deleted table (still
/// physically present, still fully recoverable) should keep its settings
/// rows exactly as before, not have them cleaned up as if the table were
/// really gone.
///
/// A single table whose [SchemaRegistry.buildConfig] throws
/// [SchemaValidationException] (metadata/physical-schema drift -- a
/// migration that failed, or hasn't arrived on this device yet) is
/// skipped from nav rather than taking down the whole app -- logged
/// loudly to the debug console so it isn't silently invisible, but every
/// other table stays usable. Any other, unexpected exception still
/// propagates and crashes loudly, same as before this step.
///
/// This also satisfies the same defensive-nav requirement the old comment
/// here described: a table that's been dropped (or never had metadata
/// synced) is never looked up at all, because the driving loop is
/// [SchemaRegistry.discoverTableNames]'s existence-filtered list.
///
/// Nav order is whatever [SchemaRegistry.discoverTableNames] returns
/// (`table_definitions.position`, nulls last, then `table_name`) --
/// visible only for a table never dragged into a `table_group` (the
/// synthetic "Ungrouped" bucket's own internal order falls back to this),
/// since any table with an explicit `group_position` sorts by that
/// instead, same as before this step.
Future<List<TableConfig>> loadEffectiveTables() async {
  final discovery = TableDiscoveryService();
  await OrphanCleanupService(discovery: discovery).cleanupOrphans();

  final registry = SchemaRegistry();
  final liveTableNames = await registry.discoverTableNames();
  final result = <TableConfig>[];
  for (final name in liveTableNames) {
    try {
      result.add(await registry.buildConfig(name));
    } on SchemaValidationException catch (e) {
      // ignore: avoid_print
      print('[loadEffectiveTables] skipping "$name" -- schema drift: $e');
    }
  }
  return result;
}
