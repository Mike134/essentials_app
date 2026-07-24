import '../db/orphan_cleanup_service.dart';
import '../db/table_discovery_service.dart';
import '../models/table_config.dart';
import 'table_configs.dart';

/// Startup entry point tying discovery (CLAUDE.md "Table Discovery phase")
/// together with the pre-existing hand-written [registeredTables]: runs
/// orphan cleanup once, then returns the effective nav table list for
/// [HomeShell] to build groups from.
///
/// **Ordering, and how this behaves as Part E's batch conversion
/// proceeds:** every name in [TableDiscoveryService.discoverTableNames]
/// (i.e. every real, non-infra table that currently exists) is resolved to
/// a [TableConfig] one of two ways -- if [registeredTables] still has a
/// hand-written config for that name, that hand-written config wins
/// (preserves today's exact behavior, including `subscription`'s two
/// genuine exceptions); otherwise it's built fresh via
/// [TableDiscoveryService.buildConfig]. As Part E retires a table's
/// hand-written config, that table starts resolving through the discovery
/// branch instead -- with a seeded `field_metadata` row standing in for
/// whatever was hand-tuned before -- with **no change needed here**. This
/// is also what satisfies Part D's defensive-nav requirement for free: a
/// hand-written config whose underlying table has been dropped is never
/// looked up at all, because the driving loop is
/// [TableDiscoveryService.discoverTableNames]'s existence-filtered list,
/// not [registeredTables] itself.
///
/// Nav order: hand-coded tables keep [registeredTables]' existing order
/// (matches CLAUDE.md's batch-1/2/3 ordering exactly, and is what
/// `HomeShell._buildGroups`' "first-appearance order" fallback was written
/// against); genuinely new discovered tables are appended after, in
/// alphabetical order -- they have no established position convention yet,
/// and `table_group`/within-group ordering (once Mike drags one into a
/// group) takes over from there the same as for any other table.
Future<List<TableConfig>> loadEffectiveTables() async {
  final discovery = TableDiscoveryService();
  await OrphanCleanupService(discovery: discovery).cleanupOrphans();

  final liveTableNames = await discovery.discoverTableNames();
  final handWrittenByName = {for (final t in registeredTables) t.tableName: t};

  final result = <TableConfig>[];
  for (final table in registeredTables) {
    if (liveTableNames.contains(table.tableName)) result.add(table);
  }
  for (final name in liveTableNames) {
    if (handWrittenByName.containsKey(name)) continue;
    result.add(await discovery.buildConfig(name));
  }
  return result;
}
