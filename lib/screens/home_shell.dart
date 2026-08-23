import 'dart:async';

import 'package:flutter/material.dart';

import '../config/table_registry.dart';
import '../db/migration_service.dart';
import '../db/sidebar_grouping_dao.dart';
import '../db/sync_service.dart';
import '../models/table_config.dart';
import '../theme/theme_controller.dart';
import '../util/device_id.dart';
import '../util/layout.dart';
import 'generic_list_screen.dart';
import 'settings_screen.dart';

/// Synthetic bucket for any table with no `table_group` row yet -- not a
/// real persisted group. Every table starts here; dragging one onto a real
/// group's header calls [SidebarGroupingDao.moveTableToGroup], and dragging
/// one back onto this bucket's header calls [SidebarGroupingDao
/// .removeFromGroup] (deletes the row) rather than creating a group
/// literally named "Ungrouped."
const String _ungroupedGroupName = 'Ungrouped';

/// Responsive nav chrome around the per-table [GenericListScreen]s:
/// [NavigationRail]-style scrollable rail on wide (Windows desktop)
/// layouts, [Drawer] on narrow (Android) layouts -- one [LayoutBuilder]
/// switch, not two separate implementations, per CLAUDE.md's "one
/// codebase, no native control mapping" decision. Every table shares this
/// same nav shell -- [_tables] is resolved once at launch by
/// [loadEffectiveTables] (hand-written configs plus anything discovered
/// via SQLite introspection that isn't already hand-written -- see
/// CLAUDE.md "Table Discovery phase"), so a table added directly in
/// Letos/DBeaver needs no code change to show up here.
///
/// **Sidebar grouping** (see CLAUDE.md "Real-usage findings" -- Step 4):
/// group membership (`table_group`) is shared across devices; which groups
/// are collapsed (`device_settings`) is per-device. Multiple ways to move a
/// table between groups, all calling the same [_showMoveToGroupMenu] /
/// [_moveToGroup]: **right-click a rail item** (Windows/mouse -- the
/// reliable path there, no gesture-timing dependency), **tap the drawer
/// item's trailing icon** (Android/touch equivalent -- no secondary-tap
/// gesture exists on touch, so this is the reliable path there instead),
/// or **long-press-and-drag onto a group header** on either platform
/// (`LongPressDraggable`/`DragTarget` -- the originally-intended
/// click-and-hold-then-drag interaction, confirmed working on both).
/// There's no separate "create an empty group" action either way --
/// `table_group`'s schema (one row per table, no standalone groups table)
/// has no way to represent a group with zero members, so a group only
/// exists once a
/// table's been moved into it.
/// Group *display* order isn't a stored field either -- derived from
/// first-appearance order among [_tables], which keeps every table visible
/// even before it's ever been moved anywhere, and gives a stable,
/// deterministic order without a schema column dedicated to it.
///
/// **Ordering tables within a group** (Mike's follow-up ask once Step 4
/// was otherwise done): every table item is *also* a `DragTarget` now, not
/// just group headers -- dropping one table onto another calls
/// [_reorderTable], which reorders (or, if it wasn't already in that
/// group, precisely positions) within the target's group via
/// [SidebarGroupingDao.setGroupOrder]. Each group header additionally
/// gets a one-click "Sort A-Z" action ([_sortGroupAlphabetically]) for
/// when manual dragging isn't worth it. Neither applies to the synthetic
/// "Ungrouped" bucket -- there's no `table_group` row to set a position
/// on for something that isn't a real group.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  String? _selectedTableName;

  /// Resolved once, at launch -- discovery is deliberately "at launch, not
  /// live" (CLAUDE.md "Table Discovery phase" Part A), so this isn't
  /// re-fetched by [_reloadGroups]/group operations; those only need to
  /// re-read grouping state for the same, already-resolved table list.
  /// Populated as a side effect of [_loadGroups] (same pattern already used
  /// for [_collapsedGroups]) rather than its own separate FutureBuilder, so
  /// [build] has a synchronously-readable list once [_groupsFuture]
  /// resolves.
  List<TableConfig> _tables = const [];

  SidebarGroupingDao? _groupingDao;
  Set<String> _collapsedGroups = {};
  late Future<List<_SidebarGroup>> _groupsFuture;

  StreamSubscription<void>? _schemaChangesSubscription;
  Timer? _schemaChangesDebounce;

  @override
  void initState() {
    super.initState();
    _groupsFuture = _bootstrapAndLoadGroups();
  }

  @override
  void dispose() {
    _schemaChangesSubscription?.cancel();
    _schemaChangesDebounce?.cancel();
    super.dispose();
  }

  /// Applies any pending `migration_log` entries *before* anything else
  /// touches the db this session -- table discovery, sync, everything --
  /// directly motivated by the missing-columns incident (CLAUDE.md
  /// "Debugging session, continued"): data for a new column arriving
  /// before the column exists to hold it is the same class of problem as
  /// this guards against, just inverted. See [MigrationService]'s own doc
  /// comment for the one real gap this can't fully close on its own (why
  /// [MigrationService.applyPending] is also re-run from
  /// [SyncService.connect]'s `onConnect`).
  Future<List<_SidebarGroup>> _bootstrapAndLoadGroups() async {
    final migrations = MigrationService();
    // Applies anything already known locally (from a previous session),
    // then a best-effort HTTP fetch (bypasses crdt_sync entirely -- see
    // MigrationService's doc comment for the real bug this closes) for
    // anything new, applied again immediately -- all before
    // SyncService.connect() below ever risks the schema-dependent merge.
    await migrations.applyPending();
    await migrations.fetchFromServer();
    await migrations.applyPending();

    // Fire-and-forget -- see ThemeController.load's doc comment for why
    // this is the right place to trigger it (first point the db is known
    // reachable on both platforms) and why nothing here needs to await it:
    // ThemeController is a ChangeNotifier main.dart already listens to, so
    // the app-wide theme just updates live once this resolves.
    ThemeController.instance.load();
    // Same reasoning -- SyncService.connect() resolves the server address
    // (compile-time default, or app_settings once this device has synced
    // before) and starts CrdtSyncClient's own connect-with-backoff loop.
    // Nothing here needs the result to keep booting; sync happens in the
    // background for the lifetime of the app. See CLAUDE.md "Syncing at the
    // Record Level". Still worth capturing the instance (once it resolves)
    // to subscribe to its live schema-change notifications below -- see
    // _subscribeToSchemaChanges' doc comment.
    SyncService.connect().then((_) {
      if (mounted) _subscribeToSchemaChanges();
    });

    return _loadGroups();
  }

  /// Live counterpart to [_reloadTables] -- that method only ever fires on
  /// return from Settings; this fires whenever [SyncService.schemaChanges]
  /// reports an incoming `table_definitions`/`field_definitions`/
  /// `migration_log` row, covering the case Settings-return can't: a
  /// rename/create/delete made on a *different* device, arriving while
  /// this one is just sitting on the main table/grid view. Debounced
  /// 500ms, not called straight from the stream event -- [SyncService]'s
  /// own doc comment on `onChangesetReceived` explains why: that callback
  /// fires *before* `crdt.merge()` is actually awaited, so reloading
  /// immediately risks reading pre-merge data. A short delay is cheap
  /// insurance, not a precise wait -- same "cheap to call unconditionally"
  /// reasoning [_reloadTables] already uses, and the debounce also
  /// coalesces a multi-table catch-up batch into one reload instead of
  /// several.
  ///
  /// **Applies pending migrations first, always, before reloading** --
  /// found necessary live: a table *created* on another device while this
  /// one was already connected arrived with correct metadata (plain CRDT
  /// row sync) but its physical `CREATE TABLE` was never actually run
  /// here, since nothing except app launch and `SyncService`'s own
  /// `onConnect` ever called [MigrationService.applyPending] -- neither of
  /// which fires for a migration arriving mid-session over an
  /// already-open connection. Cheap to call unconditionally, same
  /// reasoning as everywhere else `applyPending` is invoked -- it skips
  /// anything already applied.
  void _subscribeToSchemaChanges() {
    _schemaChangesSubscription ??= SyncService.schemaChanges.listen((_) {
      _schemaChangesDebounce?.cancel();
      _schemaChangesDebounce = Timer(const Duration(milliseconds: 500), () async {
        await MigrationService().applyPending();
        if (mounted) _reloadTables();
      });
    });
  }

  Future<List<_SidebarGroup>> _loadGroups() async {
    // loadEffectiveTables() also runs the startup orphan-cleanup pass (see
    // CLAUDE.md Part D) -- deliberately bundled into the one thing that
    // already needs to run once at launch, rather than a separate hook.
    final tables = await loadEffectiveTables();
    _tables = tables;

    final deviceId = await DeviceId.resolve();
    final dao = _groupingDao ??= SidebarGroupingDao(deviceId: deviceId);

    if (_selectedTableName == null) {
      // Per-device (CLAUDE.md governing rule -- "annoyed if it did match
      // across devices" would apply here, since each device's own last-open
      // table is what a user expects to come back to). Falls back to the
      // first table in nav order if the saved one has since been dropped
      // or renamed -- same defensive-nav reasoning as everywhere else in
      // this file.
      final lastActive = await dao.loadLastActiveTable();
      _selectedTableName = (lastActive != null && tables.any((t) => t.tableName == lastActive))
          ? lastActive
          : (tables.isEmpty ? null : tables.first.tableName);
    }

    final membership = await dao.loadMembership();
    _collapsedGroups = await dao.loadCollapsedGroups();
    return _buildGroups(tables, membership);
  }

  /// Only re-derives *grouping* state (membership/collapse), not the table
  /// list itself -- see [_tables]' doc comment.
  void _reloadGroups() {
    setState(() {
      _groupsFuture = _loadGroupingOnly();
    });
  }

  /// Re-derives the table list itself, not just grouping -- unlike
  /// [_reloadGroups]. Called after returning from Settings, since New
  /// Table/Add Field/Manage Fields (Essentials v2 Phase 1's schema engine,
  /// all reached from there) can change which tables/fields exist. Table
  /// discovery is otherwise deliberately "at launch, not live" (CLAUDE.md
  /// "Table Discovery phase" Part A) -- found live, testing Step 7's new
  /// screens: a table created through New Table had no way to ever appear
  /// in nav without a full app restart, defeating the entire point of
  /// `SchemaEditorService.createTable` already applying it locally right
  /// away. Cheap to call unconditionally on every return from Settings
  /// (not just when something demonstrably changed) -- `loadEffectiveTables`
  /// is already exactly what launch itself runs.
  Future<void> _reloadTables() async {
    setState(() {
      _groupsFuture = _loadGroups();
    });
  }

  Future<List<_SidebarGroup>> _loadGroupingOnly() async {
    final dao = _groupingDao;
    if (dao == null) return _loadGroups();
    final membership = await dao.loadMembership();
    _collapsedGroups = await dao.loadCollapsedGroups();
    return _buildGroups(_tables, membership);
  }

  void _select(String tableName) {
    setState(() => _selectedTableName = tableName);
    _groupingDao?.setLastActiveTable(tableName);
  }

  Future<void> _moveToGroup(TableConfig table, String groupName) async {
    final dao = _groupingDao;
    if (dao == null) return;
    if (groupName == _ungroupedGroupName) {
      await dao.removeFromGroup(table.tableName);
    } else {
      await dao.moveTableToGroup(table.tableName, groupName);
    }
    _reloadGroups();
  }

  /// Reorders [target]'s group so [dragged] sits immediately before
  /// [target] -- fired by dropping one table onto another (not a group
  /// header), see `_railItem`/`_drawerItem`. Doubles as a cross-group move
  /// with precise positioning, not just append-at-end: if [dragged] wasn't
  /// already in [target]'s group, it's added there at exactly this spot,
  /// same underlying `setGroupOrder` call either way. No-op onto the
  /// synthetic "Ungrouped" bucket -- there's no `table_group` row to
  /// position anything against there (see [_ungroupedGroupName]'s doc
  /// comment), so precise reordering doesn't apply; use the group header
  /// or move-to-group menu to leave a group instead.
  Future<void> _reorderTable(
    TableConfig dragged,
    TableConfig target,
    List<_SidebarGroup> groups,
  ) async {
    final dao = _groupingDao;
    if (dao == null || dragged.tableName == target.tableName) return;

    final targetGroup = groups.firstWhere(
      (g) => g.tables.any((t) => t.tableName == target.tableName),
    );
    if (targetGroup.name == _ungroupedGroupName) return;

    final newOrder = [
      for (final t in targetGroup.tables)
        if (t.tableName != dragged.tableName) t.tableName,
    ];
    newOrder.insert(newOrder.indexOf(target.tableName), dragged.tableName);

    await dao.setGroupOrder(targetGroup.name, newOrder);
    _reloadGroups();
  }

  Future<void> _sortGroupAlphabetically(_SidebarGroup group) async {
    final dao = _groupingDao;
    if (dao == null || group.name == _ungroupedGroupName) return;

    final sorted = [...group.tables]
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    await dao.setGroupOrder(group.name, [for (final t in sorted) t.tableName]);
    _reloadGroups();
  }

  /// The reliable, guaranteed-to-work path for moving a table between
  /// groups -- see the `_railItem`/`_drawerItem` doc comments for why this
  /// exists alongside (not instead of) the drag-and-drop machinery below.
  Future<void> _showMoveToGroupMenu(
    TableConfig table,
    List<_SidebarGroup> groups,
  ) async {
    const newGroupChoice = '__new_group__';
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Move "${table.displayName}" to group'),
        children: [
          for (final group in groups)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, group.name),
              child: Text(group.name),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, newGroupChoice),
            child: const Text('New group...'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    if (choice == newGroupChoice) {
      await _promptNewGroup(table);
    } else {
      await _moveToGroup(table, choice);
    }
  }

  Future<void> _promptNewGroup(TableConfig table) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New group'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Group name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await _moveToGroup(table, name);
  }

  /// Applied optimistically (immediate [setState], no wait for the db
  /// round-trip) since this is purely a local display toggle -- unlike
  /// group membership, nothing else depends on it being confirmed before
  /// the UI reflects it.
  void _toggleCollapsed(String groupName) {
    final collapsed = !_collapsedGroups.contains(groupName);
    setState(() {
      if (collapsed) {
        _collapsedGroups.add(groupName);
      } else {
        _collapsedGroups.remove(groupName);
      }
    });
    _groupingDao?.setGroupCollapsed(groupName, collapsed);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_SidebarGroup>>(
      future: _groupsFuture,
      builder: (context, snapshot) {
        // Was `if (groups == null) return <spinner>` -- silently identical
        // for "still loading" and "errored," so a thrown exception (e.g.
        // DatabaseHelper's now-loud failure when essentials.db is missing
        // or schema-less -- see CLAUDE.md "Sync architecture" incident)
        // just spun forever with no indication anything was wrong. Exactly
        // what happened on MIKE-12R during the empty-db incident.
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Failed to load: ${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }

        final groups = snapshot.data;
        if (groups == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (_tables.isEmpty) {
          // Every table has been dropped, or discovery genuinely found
          // nothing. Used to degrade to a completely bare message with no
          // drawer/rail at all -- reasonable when this was a rare edge
          // case no v1 install could realistically stay in for long
          // (Settings was always reachable from populated nav). Essentials
          // v2 makes "zero tables" the actual starting state of a fresh
          // database, and New Table lives in Settings -- the old bare
          // message was a real dead end with no way out, found live
          // testing Step 7's new screens (CLAUDE.md "Essentials v2 Phase
          // 1"). Same rail/drawer as the populated branch below, just with
          // an empty-state body instead of GenericListScreen.
          const emptyBody = Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No tables yet. Open Settings to create your first one.',
                textAlign: TextAlign.center,
              ),
            ),
          );
          return LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= wideLayoutBreakpoint;
              if (!isWide) {
                return Scaffold(
                  appBar: AppBar(title: const Text('Essentials')),
                  drawer: _buildDrawer(groups),
                  body: emptyBody,
                );
              }
              return Scaffold(
                body: Row(
                  children: [
                    SizedBox(width: 160, child: ListView(children: _buildRailChildren(groups))),
                    const VerticalDivider(width: 1),
                    const Expanded(child: emptyBody),
                  ],
                ),
              );
            },
          );
        }

        TableConfig selected = _tables.first;
        for (final table in _tables) {
          if (table.tableName == _selectedTableName) {
            selected = table;
            break;
          }
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= wideLayoutBreakpoint;
            final content = GenericListScreen(
              key: ValueKey(selected.tableName),
              config: selected,
              drawer: isWide ? null : _buildDrawer(groups),
            );

            if (!isWide) return content;

            return Scaffold(
              body: Row(
                children: [
                  // Not Flutter's NavigationRail -- it needs bounded height
                  // (uses Expanded internally) and can't be made to scroll,
                  // so it just overflows once there are more destinations
                  // than fit. A plain scrollable ListView is the only
                  // reliable option once every batch-1/2/3 table (plus
                  // group headers) is registered.
                  SizedBox(
                    width: 160,
                    child: ListView(children: _buildRailChildren(groups)),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: content),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ===================== Windows rail =====================

  List<Widget> _buildRailChildren(List<_SidebarGroup> groups) {
    return [
      for (final group in groups) ...[
        _railGroupHeader(group),
        if (!_collapsedGroups.contains(group.name))
          for (final table in group.tables) _railItem(table, groups),
      ],
      const Divider(height: 1),
      _railSettingsItem(),
    ];
  }

  Widget _railSettingsItem() {
    return InkWell(
      onTap: () async {
        await Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
        if (mounted) _reloadTables();
      },
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Column(
          children: [
            Icon(Icons.settings_outlined),
            SizedBox(height: 4),
            Text('Settings', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _railGroupHeader(_SidebarGroup group) {
    final collapsed = _collapsedGroups.contains(group.name);
    return DragTarget<TableConfig>(
      onAcceptWithDetails: (details) => _moveToGroup(details.data, group.name),
      builder: (context, candidateData, rejectedData) {
        return InkWell(
          onTap: () => _toggleCollapsed(group.name),
          child: Container(
            color: candidateData.isNotEmpty
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Icon(
                  collapsed ? Icons.chevron_right : Icons.expand_more,
                  size: 18,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    group.name,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Ungrouped isn't a real persisted group -- see
                // _sortGroupAlphabetically's guard -- so no sort action for
                // it, same reasoning as its group header not being a valid
                // reorder target.
                if (group.name != _ungroupedGroupName)
                  IconButton(
                    icon: const Icon(Icons.sort_by_alpha, size: 16),
                    tooltip: 'Sort A-Z',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _sortGroupAlphabetically(group),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// [groups] is threaded through for right-click -> [_showMoveToGroupMenu]
  /// -- the reliable way to move a table between groups on Windows.
  /// Long-press-drag (`LongPressDraggable` below) is still there too, for
  /// exactly the click-and-hold-then-drag gesture Mike originally wanted;
  /// the earlier small "..." icon button was clutter once right-click
  /// covers the same thing without needing its own tap target.
  Widget _railItem(TableConfig table, List<_SidebarGroup> groups) {
    final selected = table.tableName == _selectedTableName;
    final colorScheme = Theme.of(context).colorScheme;
    final item = InkWell(
      onTap: () => _select(table.tableName),
      onSecondaryTap: () => _showMoveToGroupMenu(table, groups),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        color: selected ? colorScheme.secondaryContainer : null,
        child: Column(
          children: [
            Icon(
              selected ? Icons.table_chart : Icons.table_chart_outlined,
              color: selected ? colorScheme.onSecondaryContainer : null,
            ),
            const SizedBox(height: 4),
            Text(
              table.displayName,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: selected ? colorScheme.onSecondaryContainer : null,
              ),
            ),
          ],
        ),
      ),
    );

    final draggable = LongPressDraggable<TableConfig>(
      // Long-press, not a plain Draggable -- a quick tap still reaches the
      // InkWell above for normal navigation; only a held press starts a
      // drag, so the two gestures don't compete for the same tap.
      data: table,
      feedback: _dragFeedback(table),
      childWhenDragging: Opacity(opacity: 0.3, child: item),
      child: item,
    );

    // Every table item is also a drop target now, not just group headers
    // -- dropping one table onto another reorders within (or moves
    // precisely into) the target's group, see _reorderTable.
    return DragTarget<TableConfig>(
      onAcceptWithDetails: (details) => _reorderTable(details.data, table, groups),
      builder: (context, candidateData, rejectedData) {
        return Container(
          color: candidateData.isNotEmpty
              ? Theme.of(context).colorScheme.primaryContainer
              : null,
          child: draggable,
        );
      },
    );
  }

  // ===================== Android drawer =====================

  Widget _buildDrawer(List<_SidebarGroup> groups) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(child: Text('Essentials')),
          for (final group in groups) ..._drawerGroupChildren(group, groups),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: () async {
              Navigator.pop(context);
              await Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
              if (mounted) _reloadTables();
            },
          ),
        ],
      ),
    );
  }

  List<Widget> _drawerGroupChildren(
    _SidebarGroup group,
    List<_SidebarGroup> groups,
  ) {
    final collapsed = _collapsedGroups.contains(group.name);
    return [
      DragTarget<TableConfig>(
        onAcceptWithDetails: (details) => _moveToGroup(details.data, group.name),
        builder: (context, candidateData, rejectedData) {
          // Material, not a plain colored Container wrapping the ListTile
          // -- Flutter flagged this for real ("ListTile background color
          // or ink splashes may be invisible") the first time this drag
          // highlight actually fired on a real device: ListTile paints its
          // own background/ink splashes on the nearest Material ancestor,
          // so an opaque Container sitting between it and that Material
          // hides both. Material's own `color` paints at the right depth
          // for ListTile's splash to render on top of correctly.
          return Material(
            color: candidateData.isNotEmpty
                ? Theme.of(context).colorScheme.primaryContainer
                : Colors.transparent,
            child: ListTile(
              dense: true,
              leading: Icon(collapsed ? Icons.chevron_right : Icons.expand_more),
              title: Text(
                group.name,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              // See _railGroupHeader -- same guard, Ungrouped has no
              // table_group rows to reorder.
              trailing: group.name == _ungroupedGroupName
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.sort_by_alpha, size: 18),
                      tooltip: 'Sort A-Z',
                      onPressed: () => _sortGroupAlphabetically(group),
                    ),
              onTap: () => _toggleCollapsed(group.name),
            ),
          );
        },
      ),
      if (!collapsed) for (final table in group.tables) _drawerItem(table, groups),
    ];
  }

  /// Trailing icon is the reliable path here, not right-click -- unlike
  /// the rail (mouse-driven, Windows-only), the drawer runs on touch,
  /// where there's no secondary-tap gesture at all. `onSecondaryTap` is
  /// kept too (reaches it if a mouse happens to be connected), but a
  /// touch-only user needs an actual tap target; a full-size `ListTile
  /// .trailing` icon, not the cramped rail-icon Mike already flagged as
  /// fiddly to hit, since the drawer has the room for one.
  Widget _drawerItem(TableConfig table, List<_SidebarGroup> groups) {
    final tile = GestureDetector(
      onSecondaryTap: () => _showMoveToGroupMenu(table, groups),
      child: ListTile(
        leading: const Icon(Icons.table_chart_outlined),
        title: Text(table.displayName),
        selected: table.tableName == _selectedTableName,
        trailing: IconButton(
          icon: const Icon(Icons.more_vert),
          tooltip: 'Move to group',
          onPressed: () => _showMoveToGroupMenu(table, groups),
        ),
        onTap: () {
          _select(table.tableName);
          Navigator.pop(context);
        },
      ),
    );

    final draggable = LongPressDraggable<TableConfig>(
      data: table,
      feedback: _dragFeedback(table),
      childWhenDragging: Opacity(opacity: 0.3, child: tile),
      child: tile,
    );

    // See _railItem -- same reordering-drop-target addition. Material,
    // not Container, for the same reason as the group header above: an
    // opaque Container between a ListTile and its nearest Material hides
    // the ListTile's own background/ink splash (Flutter's own runtime
    // assertion caught this exact mistake once already, see CLAUDE.md).
    return DragTarget<TableConfig>(
      onAcceptWithDetails: (details) => _reorderTable(details.data, table, groups),
      builder: (context, candidateData, rejectedData) {
        return Material(
          color: candidateData.isNotEmpty
              ? Theme.of(context).colorScheme.primaryContainer
              : Colors.transparent,
          child: draggable,
        );
      },
    );
  }

  Widget _dragFeedback(TableConfig table) {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(table.displayName),
      ),
    );
  }
}

class _SidebarGroup {
  const _SidebarGroup(this.name, this.tables);

  final String name;
  final List<TableConfig> tables;
}

/// Buckets [tables] by [membership], in first-appearance order among
/// [tables] itself (see the class doc comment on [HomeShell] for why group
/// order isn't a stored field). Within a group, tables sort by
/// `group_position`, falling back to their original [tables] index for any
/// table that predates that group existing (or was never explicitly
/// positioned) -- keeps ordering stable and deterministic without
/// requiring every row to have an explicit position.
List<_SidebarGroup> _buildGroups(
  List<TableConfig> tables,
  List<TableGroupMembership> membership,
) {
  final membershipByTable = {for (final m in membership) m.tableName: m};

  final order = <String>[];
  final byGroup = <String, List<MapEntry<int, TableConfig>>>{};

  for (var i = 0; i < tables.length; i++) {
    final table = tables[i];
    final groupName = membershipByTable[table.tableName]?.groupName ?? _ungroupedGroupName;
    final bucket = byGroup.putIfAbsent(groupName, () {
      order.add(groupName);
      return [];
    });
    bucket.add(MapEntry(i, table));
  }

  return [
    for (final groupName in order)
      _SidebarGroup(
        groupName,
        (byGroup[groupName]!..sort((a, b) {
              final posA = membershipByTable[a.value.tableName]?.groupPosition ?? a.key;
              final posB = membershipByTable[b.value.tableName]?.groupPosition ?? b.key;
              return posA.compareTo(posB);
            }))
            .map((entry) => entry.value)
            .toList(),
      ),
  ];
}
