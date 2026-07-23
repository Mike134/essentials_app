import 'package:flutter/material.dart';

import '../config/table_configs.dart';
import '../db/sidebar_grouping_dao.dart';
import '../models/table_config.dart';
import '../util/device_id.dart';
import '../util/strings.dart';
import 'generic_list_screen.dart';

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
/// codebase, no native control mapping" decision. Every registered table
/// shares this same nav shell -- new tables are just additions to
/// [registeredTables].
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
/// first-appearance order among [registeredTables], which keeps every
/// table visible even before it's ever been moved anywhere, and gives a
/// stable, deterministic order without a schema column dedicated to it.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const double _wideBreakpoint = 600;

  String _selectedTableName = registeredTables.first.tableName;

  SidebarGroupingDao? _groupingDao;
  Set<String> _collapsedGroups = {};
  late Future<List<_SidebarGroup>> _groupsFuture;

  @override
  void initState() {
    super.initState();
    _groupsFuture = _loadGroups();
  }

  Future<List<_SidebarGroup>> _loadGroups() async {
    final deviceId = await DeviceId.resolve();
    final dao = _groupingDao ??= SidebarGroupingDao(deviceId: deviceId);
    final membership = await dao.loadMembership();
    _collapsedGroups = await dao.loadCollapsedGroups();
    return _buildGroups(registeredTables, membership);
  }

  void _reloadGroups() {
    setState(() {
      _groupsFuture = _loadGroups();
    });
  }

  void _select(String tableName) => setState(() => _selectedTableName = tableName);

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
        title: Text('Move "${titleCase(table.tableName)}" to group'),
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

        final selected = registeredTables.firstWhere(
          (t) => t.tableName == _selectedTableName,
          orElse: () => registeredTables.first,
        );

        return LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= _wideBreakpoint;
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
    ];
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
              titleCase(table.tableName),
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

    return LongPressDraggable<TableConfig>(
      // Long-press, not a plain Draggable -- a quick tap still reaches the
      // InkWell above for normal navigation; only a held press starts a
      // drag, so the two gestures don't compete for the same tap.
      data: table,
      feedback: _dragFeedback(table),
      childWhenDragging: Opacity(opacity: 0.3, child: item),
      child: item,
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
        title: Text(titleCase(table.tableName)),
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

    return LongPressDraggable<TableConfig>(
      data: table,
      feedback: _dragFeedback(table),
      childWhenDragging: Opacity(opacity: 0.3, child: tile),
      child: tile,
    );
  }

  Widget _dragFeedback(TableConfig table) {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(titleCase(table.tableName)),
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
