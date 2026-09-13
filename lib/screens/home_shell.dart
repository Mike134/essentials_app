import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../config/table_registry.dart';
import '../db/event_dispatch_service.dart';
import '../db/migration_service.dart';
import '../db/search_index_service.dart';
import '../db/sidebar_grouping_dao.dart';
import '../db/sync_service.dart';
import '../db/theme_settings_dao.dart';
import '../db/view_definitions_dao.dart';
import '../models/table_config.dart';
import '../theme/theme_controller.dart';
import '../util/device_id.dart';
import '../util/layout.dart';
import '../util/scripting/alarm_schedule_service.dart';
import '../util/table_icon_widget.dart';
import 'calendar_screen.dart';
import 'generic_list_screen.dart';
import 'kanban_view_screen.dart';
import 'list_view_screen.dart';
import 'script_editor_screen.dart';
import 'search_screen.dart';
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
/// Group *display* order (which group appears first, second, ...) is a
/// separate, real, stored field -- `table_group_order`, keyed purely by
/// group name (see schema.sql's own doc comment on that table). A group
/// with no explicit entry there falls back to first-appearance order among
/// [_tables], the same deterministic default every group had before that
/// table existed -- see [_buildGroups].
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
///
/// **Ordering the groups themselves** (a later follow-up, same shape):
/// each group header is now *also* a `LongPressDraggable`/`DragTarget`
/// pair (see [_railGroupHeader]/[_drawerGroupChildren]) -- dropping one
/// group onto another calls [_reorderGroup], which reorders via
/// [SidebarGroupingDao.setGroupDisplayOrder]. A "Sort groups A-Z" action
/// ([_sortGroupsAlphabetically]) sits above the group list in both the
/// rail and the drawer. Unlike per-table ordering, this *does* apply to
/// "Ungrouped" -- `table_group_order` has no concept of a synthetic
/// bucket, it's just another `group_name` string, so there's nothing to
/// special-case here.
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

  /// The sidebar's own group-level display order (`table_group_order`),
  /// keyed by `group_name` -- shared across devices, same sync scope as
  /// [_reloadGroups]' membership reload, not per-device like
  /// [_collapsedGroups]. A group with no entry here falls back to
  /// first-appearance order among [_tables] in [_buildGroups].
  Map<String, int> _groupOrder = {};
  late Future<List<_SidebarGroup>> _groupsFuture;

  /// Essentials v2 Phase 3 -- which saved view (if any) is currently active
  /// per table, keyed by `table_name`. `null` (present but mapped to
  /// `null`) means the implicit Grid tab; an absent key means "not loaded
  /// yet" (see [_ensureSelectedViewLoaded]). Per-device (`device_settings`
  /// key `selected_view:{table_name}`), same reasoning as
  /// `last_active_table` -- Mike picking "List" for one table on this
  /// device is a standing preference worth remembering across restarts,
  /// same governing rule as everything else in [SidebarGroupingDao].
  final Map<String, ViewDefinition?> _selectedViews = {};

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

    // Essentials v2 Phase 6 (Global Search) -- creates search_index on
    // this device if it doesn't exist yet (cheap no-op every call after
    // the first, see SearchIndexService.ensureIndexTable's own doc
    // comment). Awaited, unlike the two fire-and-forget calls below: every
    // GenericDao.insert/update/delete this session calls into
    // SearchIndexService, and those calls should never race the table's
    // own creation.
    await SearchIndexService().ensureIndexTable();
    // Reclaims search_index rows left behind by a table that's been
    // permanently dropped since the last launch -- see
    // SearchIndexService.cleanupOrphans' own doc comment. Fire-and-forget,
    // same reasoning as ensureIndexTable's own first-run backfill: cheap
    // startup maintenance, nothing else needs to wait on it.
    unawaited(SearchIndexService().cleanupOrphans());
    // Subscribes (once, process-wide) to SyncService.dataChanges so a
    // record synced in from another device becomes searchable here too --
    // the remote-write half of Phase 6's two reindex hooks (the local-write
    // half is wired directly into GenericDao itself). Safe to call before
    // SyncService.connect() below resolves -- it subscribes to the stream,
    // not the connection.
    SearchIndexService.listenForRemoteChanges();

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

    // Essentials v2 Phase 5 build order step 6 -- runs once per real app
    // process start, after migrations are applied (so a script can safely
    // reference current-session schema) but fire-and-forget, same
    // reasoning as ThemeController.load() just above: nothing here needs
    // to block the nav from rendering. `tableName: null` matches every
    // `event_definitions` row with `table_name IS NULL` and
    // `event_type = 'app_launch'` -- the design doc's own schema
    // convention for a scheduled/app-launch binding. This is the only
    // scheduled event type that actually fires yet -- hourly/daily/weekly
    // need real background execution (steps 7-8), still pending.
    if (mounted) {
      EventDispatchService().dispatchAndApplyEffects(context, tableName: null, eventType: 'app_launch');
    }

    // Essentials v2 alarm-based scheduling, build order step 6 (see
    // claude/essentials-v2-alarm-scheduling-design.md) -- registers the
    // low-frequency `workmanager` safety-net task and cancels the old
    // 15-minute polling task if it's still registered on this device, so
    // the two mechanisms never run side-by-side. Idempotent
    // (`ExistingPeriodicWorkPolicy.keep`), so a call on every launch is
    // cheap and safe, not just tolerated. Android only -- Windows
    // background firing is a separate mechanism (its own build order
    // step 8, already done). Fire-and-forget, same reasoning as every
    // other bootstrap call here: nothing blocks the nav from rendering on
    // this.
    if (Platform.isAndroid) {
      unawaited(registerAlarmSafetyNetTask());
    }

    // Requests SCHEDULE_EXACT_ALARM once per device -- see
    // alarm_schedule_service.dart's own manifest/doc comments for why
    // exact timing is now wanted (ColorOS was batching inexact alarms by
    // several minutes, a real problem for short schedule_interval
    // bindings). A no-op once already granted; opens the system "Alarms &
    // reminders" settings screen the first time it isn't. Fire-and-forget,
    // same as every other bootstrap permission/scheduling call here --
    // rescheduleNextAlarm below checks the real granted status itself
    // rather than assuming this call finished first.
    if (Platform.isAndroid) {
      unawaited(ensureExactAlarmPermission());
    }

    // Essentials v2 alarm-based scheduling, build order step 4 (see
    // claude/essentials-v2-alarm-scheduling-design.md) -- app launch is
    // one of the trigger points that (re)arms the exact-time alarm chain,
    // alongside `ScheduledEventsScreen`'s own create/edit/delete/enable/
    // disable actions. Android only, same reasoning as the call above
    // (`android_alarm_manager_plus` has no Windows implementation).
    if (Platform.isAndroid) {
      unawaited(rescheduleNextAlarm());
    }

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
    if (_selectedTableName != null) {
      await _ensureSelectedViewLoaded(_selectedTableName!);
    }

    final membership = await dao.loadMembership();
    _collapsedGroups = await dao.loadCollapsedGroups();
    _groupOrder = await dao.loadGroupOrder();
    return _buildGroups(tables, membership, _groupOrder);
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
    _groupOrder = await dao.loadGroupOrder();
    return _buildGroups(_tables, membership, _groupOrder);
  }

  void _select(String tableName) {
    setState(() => _selectedTableName = tableName);
    _groupingDao?.setLastActiveTable(tableName);
    if (!_selectedViews.containsKey(tableName)) {
      _ensureSelectedViewLoaded(tableName).then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  /// Populates [_selectedViews] for [tableName] from its saved
  /// `selected_view:{table_name}` device setting, resolving the stored
  /// `view_id` against that table's *currently active* views -- self-heals
  /// to Grid if the saved id no longer resolves (the view was deleted, or
  /// the setting is stale/malformed) rather than crashing. No-op if
  /// already cached (see [_selectedViews]'s own doc comment).
  Future<void> _ensureSelectedViewLoaded(String tableName) async {
    if (_selectedViews.containsKey(tableName)) return;
    final deviceId = await DeviceId.resolve();
    final settingsDao = ThemeSettingsDao(deviceId: deviceId);
    final raw = await settingsDao.loadDeviceSetting('selected_view:$tableName');
    ViewDefinition? resolved;
    final viewId = raw == null || raw == 'grid' ? null : int.tryParse(raw);
    if (viewId != null) {
      final views = await ViewDefinitionsDao().loadViewsForTable(tableName);
      for (final view in views) {
        if (view.viewId == viewId) {
          resolved = view;
          break;
        }
      }
    }
    _selectedViews[tableName] = resolved;
  }

  /// Fired by a table's [ViewSwitcherBar] (embedded in whichever screen is
  /// currently shown -- [GenericListScreen]/[ListViewScreen]) -- this is the
  /// one place that decides which screen class to show next, per
  /// claude/essentials-v2-phase3-design.md's "Nav / UI integration".
  Future<void> _onViewSelected(String tableName, ViewDefinition? view) async {
    setState(() => _selectedViews[tableName] = view);
    final deviceId = await DeviceId.resolve();
    final settingsDao = ThemeSettingsDao(deviceId: deviceId);
    await settingsDao.setDeviceSetting(
      'selected_view:$tableName',
      view == null ? 'grid' : '${view.viewId}',
    );
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

  /// Reorders the sidebar's *groups* (not the tables within one -- see
  /// [_reorderTable]/[_sortGroupAlphabetically] for that) so [dragged] sits
  /// immediately before [target], via [SidebarGroupingDao
  /// .setGroupDisplayOrder]. Unlike table-within-group reordering, this
  /// applies uniformly to every group name, "Ungrouped" included --
  /// `table_group_order` has no concept of a synthetic bucket, it's just a
  /// string key, so there's no reason to special-case it here the way
  /// [_sortGroupAlphabetically]/[_reorderTable] still correctly do for
  /// per-table positioning within it (which genuinely has no `table_group`
  /// row to write to for that bucket).
  Future<void> _reorderGroup(
    String draggedGroupName,
    String targetGroupName,
    List<_SidebarGroup> groups,
  ) async {
    final dao = _groupingDao;
    if (dao == null || draggedGroupName == targetGroupName) return;

    final newOrder = [
      for (final g in groups)
        if (g.name != draggedGroupName) g.name,
    ];
    newOrder.insert(newOrder.indexOf(targetGroupName), draggedGroupName);

    await dao.setGroupDisplayOrder(newOrder);
    _reloadGroups();
  }

  /// One-click alphabetical sort for the groups themselves -- the
  /// group-level counterpart to each group header's own "Sort A-Z" (which
  /// only ever sorts the tables *within* one group). "Ungrouped" sorts
  /// alongside every real group here, same reasoning as [_reorderGroup].
  Future<void> _sortGroupsAlphabetically(List<_SidebarGroup> groups) async {
    final dao = _groupingDao;
    if (dao == null) return;

    final sorted = [...groups]..sort((a, b) => a.name.compareTo(b.name));
    await dao.setGroupDisplayOrder([for (final g in sorted) g.name]);
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
            // A stored view of a type this build doesn't know how to render
            // (there is none right now -- List and Kanban both have real
            // screens as of Step 3) falls back to Grid defensively rather
            // than crashing, same defensive-nav posture as everywhere else.
            final rawSelectedView = _selectedViews[selected.tableName];
            final selectedViewType = rawSelectedView?.viewType;
            final selectedView =
                (selectedViewType == 'list' || selectedViewType == 'kanban') ? rawSelectedView : null;
            final drawer = isWide ? null : _buildDrawer(groups);
            void onViewSelected(ViewDefinition? view) => _onViewSelected(selected.tableName, view);
            final Widget content;
            if (selectedView == null) {
              content = GenericListScreen(
                key: ValueKey(selected.tableName),
                config: selected,
                drawer: drawer,
                onViewSelected: onViewSelected,
              );
            } else if (selectedView.viewType == 'kanban') {
              content = KanbanViewScreen(
                key: ValueKey('${selected.tableName}:${selectedView.viewId}'),
                config: selected,
                view: selectedView,
                drawer: drawer,
                onViewSelected: onViewSelected,
              );
            } else {
              content = ListViewScreen(
                key: ValueKey('${selected.tableName}:${selectedView.viewId}'),
                config: selected,
                view: selectedView,
                drawer: drawer,
                onViewSelected: onViewSelected,
              );
            }

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
      if (groups.isNotEmpty) _railSortGroupsHeader(groups),
      for (final group in groups) ...[
        _railGroupHeader(group, groups),
        if (!_collapsedGroups.contains(group.name))
          for (final table in group.tables) _railItem(table, groups),
      ],
      const Divider(height: 16, thickness: 11),
      _railSearchItem(),
      _railCalendarItem(),
      _railScriptsItem(),
      _railSettingsItem(),
    ];
  }

  Widget _railScriptsItem() {
    return InkWell(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const ScriptEditorScreen())),
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Column(
          children: [
            Icon(Icons.code),
            SizedBox(height: 4),
            Text('Scripts', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _railSearchItem() {
    return InkWell(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const SearchScreen())),
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Column(
          children: [
            Icon(Icons.search),
            SizedBox(height: 4),
            Text('Search', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _railCalendarItem() {
    return InkWell(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const CalendarScreen())),
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Column(
          children: [
            Icon(Icons.calendar_month_outlined),
            SizedBox(height: 4),
            Text('Calendar', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
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

  /// One-click "Sort groups A-Z", the group-level counterpart to each
  /// group header's own per-table "Sort A-Z" icon.
  Widget _railSortGroupsHeader(List<_SidebarGroup> groups) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Align(
        alignment: Alignment.centerRight,
        child: IconButton(
          icon: const Icon(Icons.sort_by_alpha, size: 16),
          tooltip: 'Sort groups A-Z',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          visualDensity: VisualDensity.compact,
          onPressed: () => _sortGroupsAlphabetically(groups),
        ),
      ),
    );
  }

  /// [groups] is threaded through for group-level drag-reordering
  /// ([_reorderGroup]) -- same reasoning [_railItem] already has for
  /// per-table reordering. The header is now both a
  /// `LongPressDraggable<_GroupDragPayload>` (drag this group elsewhere)
  /// and a `DragTarget<_GroupDragPayload>` (drop another group onto this
  /// one to reorder), nested around the existing `DragTarget<TableConfig>`
  /// (drop a table here to move it into this group) -- Flutter dispatches a
  /// drag only to targets whose generic type matches what's being dragged,
  /// so the two drop behaviors never conflict at the same screen position.
  Widget _railGroupHeader(_SidebarGroup group, List<_SidebarGroup> groups) {
    final collapsed = _collapsedGroups.contains(group.name);
    final tableDropTarget = DragTarget<TableConfig>(
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
                // Ungrouped isn't a real persisted group in `table_group` --
                // see _sortGroupAlphabetically's guard -- so no per-table
                // sort action for it. Group-*level* reordering (this
                // header's own drag/drop and the "Sort groups A-Z" button
                // above) applies to it fine, since table_group_order has no
                // such restriction -- see _reorderGroup's own doc comment.
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

    final draggableHeader = LongPressDraggable<_GroupDragPayload>(
      data: _GroupDragPayload(group.name),
      feedback: _groupDragFeedback(group.name),
      childWhenDragging: Opacity(opacity: 0.3, child: tableDropTarget),
      child: tableDropTarget,
    );

    return DragTarget<_GroupDragPayload>(
      onAcceptWithDetails: (details) => _reorderGroup(details.data.groupName, group.name, groups),
      builder: (context, candidateData, rejectedData) {
        return Container(
          color: candidateData.isNotEmpty
              ? Theme.of(context).colorScheme.secondaryContainer
              : null,
          child: draggableHeader,
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
            TableIconWidget(
              icon: table.icon,
              color: selected ? colorScheme.onSecondaryContainer : null,
              fallback: selected ? Icons.table_chart : Icons.table_chart_outlined,
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
        // Bottom-only inset for the system nav bar -- without it, the
        // last item (Settings) sits partly underneath a 3-button nav
        // bar on devices that have one (confirmed live on MIKE-12R: a
        // tap low enough on "Settings" landed on the system bar instead
        // of the app, triggering an unrelated Android overlay). Same
        // `MediaQuery.paddingOf(context).bottom` fix already used on
        // every other screen this app has hit this on (Settings, Manage
        // Tables/Fields, New Table, Add Field, GenericFormScreen).
        padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
        children: [
          const DrawerHeader(child: Text('Essentials')),
          if (groups.isNotEmpty)
            ListTile(
              dense: true,
              leading: const Icon(Icons.sort_by_alpha, size: 18),
              title: const Text('Sort groups A-Z'),
              onTap: () => _sortGroupsAlphabetically(groups),
            ),
          for (final group in groups) ..._drawerGroupChildren(group, groups),
          const Divider(height: 16, thickness: 11),
          ListTile(
            leading: const Icon(Icons.search),
            title: const Text('Search'),
            onTap: () {
              Navigator.pop(context);
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SearchScreen()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.calendar_month_outlined),
            title: const Text('Calendar'),
            onTap: () {
              Navigator.pop(context);
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const CalendarScreen()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: const Text('Scripts'),
            onTap: () {
              Navigator.pop(context);
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const ScriptEditorScreen()));
            },
          ),
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

  /// See [_railGroupHeader]'s doc comment for the nested-DragTarget
  /// reasoning -- identical shape here, just wrapped around a `ListTile`
  /// instead of the rail's compact icon column. `LongPressDraggable` is the
  /// only path to reorder groups on touch, same as it already is for
  /// tables within a group -- there's no secondary-tap gesture to fall back
  /// to on Android the way the rail has right-click on Windows.
  List<Widget> _drawerGroupChildren(
    _SidebarGroup group,
    List<_SidebarGroup> groups,
  ) {
    final collapsed = _collapsedGroups.contains(group.name);
    final tableDropTarget = DragTarget<TableConfig>(
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
            // table_group rows to reorder tables within it. Group-level
            // reordering (the long-press drag below) still applies to it.
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
    );

    final draggableHeader = LongPressDraggable<_GroupDragPayload>(
      data: _GroupDragPayload(group.name),
      feedback: _groupDragFeedback(group.name),
      childWhenDragging: Opacity(opacity: 0.3, child: tableDropTarget),
      child: tableDropTarget,
    );

    return [
      DragTarget<_GroupDragPayload>(
        onAcceptWithDetails: (details) => _reorderGroup(details.data.groupName, group.name, groups),
        builder: (context, candidateData, rejectedData) {
          return Material(
            color: candidateData.isNotEmpty
                ? Theme.of(context).colorScheme.secondaryContainer
                : Colors.transparent,
            child: draggableHeader,
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
        leading: TableIconWidget(icon: table.icon),
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

  Widget _groupDragFeedback(String groupName) {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(groupName, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }
}

class _SidebarGroup {
  const _SidebarGroup(this.name, this.tables);

  final String name;
  final List<TableConfig> tables;
}

/// The payload a group header's own `LongPressDraggable`/`DragTarget` pair
/// carries -- just the group's name, distinct from [TableConfig] so
/// Flutter's generic-typed drag-and-drop never confuses "drag a table onto
/// a group" with "drag a group onto another group" at the same screen
/// position (see [HomeShell._railGroupHeader]'s own doc comment).
class _GroupDragPayload {
  const _GroupDragPayload(this.groupName);

  final String groupName;
}

/// Buckets [tables] by [membership], then orders the resulting groups by
/// [groupOrder] (`table_group_order`, keyed by group name) -- falling back
/// to first-appearance order among [tables] itself for any group with no
/// explicit entry there, exactly the behavior every group had before that
/// table existed. Within a group, tables sort by `group_position`, falling
/// back to their original [tables] index for any table that predates that
/// group existing (or was never explicitly positioned) -- keeps ordering
/// stable and deterministic without requiring every row to have an
/// explicit position, same fallback shape [groupOrder] itself now uses one
/// level up.
List<_SidebarGroup> _buildGroups(
  List<TableConfig> tables,
  List<TableGroupMembership> membership,
  Map<String, int> groupOrder,
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

  // Captured before sorting `order` in place -- the fallback position for a
  // never-explicitly-ordered group is its original first-appearance index,
  // which would otherwise become self-referential once `order` itself is
  // reordered below.
  final fallbackGroupPosition = {for (var i = 0; i < order.length; i++) order[i]: i};
  order.sort((a, b) {
    final posA = groupOrder[a] ?? fallbackGroupPosition[a]!;
    final posB = groupOrder[b] ?? fallbackGroupPosition[b]!;
    return posA.compareTo(posB);
  });

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
