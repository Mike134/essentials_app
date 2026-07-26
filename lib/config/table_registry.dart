import '../db/orphan_cleanup_service.dart';
import '../db/table_discovery_service.dart';
import '../models/table_config.dart';
import 'table_configs.dart';

/// Startup entry point for CLAUDE.md "Table Discovery phase": runs orphan
/// cleanup once, then returns the effective nav table list for [HomeShell]
/// to build groups from. As of the "Split-Pane Layout" session, every table
/// -- all 21, plus anything added directly in Letos/DBeaver -- resolves
/// through [TableDiscoveryService.buildConfig], with two special cases:
/// [subscriptionTableName] goes through [buildSubscriptionConfig] (the
/// `subscription_computed` read source, the view-only `yearly_cost`/
/// `next_date` columns, and `computePreview`), and [ordersTableName] goes
/// through [buildOrdersConfig] (the split-pane detail view, the
/// items-cascade delete warning). `table_configs.dart` has no hand-written
/// [TableConfig] left at all -- not even these two tables' fields are
/// hand-written, only their small structural exceptions.
///
/// This is also what satisfies Part D's defensive-nav requirement: a
/// table that's been dropped is never looked up at all, because the
/// driving loop is [TableDiscoveryService.discoverTableNames]'s
/// existence-filtered list.
///
/// Nav order is now plain alphabetical (whatever `discoverTableNames`
/// returns) rather than the old batch-1/2/3 declaration order -- only
/// visible for a table that's never been dragged into a `table_group`
/// (the synthetic "Ungrouped" bucket's own internal order falls back to
/// this), since any table with an explicit `group_position` sorts by that
/// instead. Low-risk in practice: real usage has already grouped most
/// tables (see CLAUDE.md "Real-usage findings" Step 4 and its within-group
/// ordering follow-up).
Future<List<TableConfig>> loadEffectiveTables() async {
  final discovery = TableDiscoveryService();
  await OrphanCleanupService(discovery: discovery).cleanupOrphans();

  final liveTableNames = await discovery.discoverTableNames();
  final result = <TableConfig>[];
  for (final name in liveTableNames) {
    result.add(
      await switch (name) {
        subscriptionTableName => buildSubscriptionConfig(discovery),
        ordersTableName => buildOrdersConfig(discovery),
        _ => discovery.buildConfig(name),
      },
    );
  }
  return result;
}
