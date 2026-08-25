import 'dart:async';

import 'package:flutter/material.dart';

import '../db/sync_service.dart';
import '../db/view_definitions_dao.dart';
import 'manage_views_screen.dart';

/// Shared chrome rendered as each per-table screen's own `AppBar.bottom`
/// (`GenericListScreen`/`ListViewScreen`/eventually `KanbanViewScreen`) --
/// per claude/essentials-v2-phase3-design.md's "Nav / UI integration":
/// deliberately *not* owned by `HomeShell`'s outer chrome, since every
/// screen already owns its own `Scaffold`/`AppBar` and none of them give
/// that chrome up to a shared parent.
///
/// Renders the always-present implicit "Grid" tab first (never a
/// `view_definitions` row, never renameable/deletable), then every active
/// List/Kanban `view_definitions` row for [tableName], as a horizontal
/// row of choice chips, plus a trailing "+" to create a new view.
/// [currentViewId] is `null` when Grid is the active tab.
///
/// Selecting a tab calls [onViewSelected] with the chosen [ViewDefinition]
/// (`null` for Grid) -- the actual "which screen class to show" decision
/// lives in `HomeShell`, one layer up; this widget only reports the choice.
class ViewSwitcherBar extends StatefulWidget implements PreferredSizeWidget {
  const ViewSwitcherBar({
    super.key,
    required this.tableName,
    required this.currentViewId,
    required this.onViewSelected,
  });

  final String tableName;
  final int? currentViewId;
  final ValueChanged<ViewDefinition?> onViewSelected;

  @override
  Size get preferredSize => const Size.fromHeight(48);

  @override
  State<ViewSwitcherBar> createState() => _ViewSwitcherBarState();
}

class _ViewSwitcherBarState extends State<ViewSwitcherBar> {
  final _dao = ViewDefinitionsDao();
  late Future<List<ViewDefinition>> _viewsFuture;

  /// Live-refresh subscription -- same shape/reasoning as [GenericListScreen
  /// ._dataChangeSubscription]: a view created/renamed/deleted on *another*
  /// device (or even this one, via a route this widget doesn't directly
  /// own -- see [ListViewScreen]'s own identical subscription) previously
  /// only ever showed up here after this widget happened to rebuild for an
  /// unrelated reason. Debounced for the same before-the-merge-completes
  /// reason [SyncService.dataChanges] itself documents.
  StreamSubscription<Set<String>>? _dataChangeSubscription;
  Timer? _dataChangeDebounce;

  @override
  void initState() {
    super.initState();
    _viewsFuture = _dao.loadViewsForTable(widget.tableName);
    _dataChangeSubscription = SyncService.dataChanges.listen(_onDataChanged);
  }

  @override
  void dispose() {
    _dataChangeSubscription?.cancel();
    _dataChangeDebounce?.cancel();
    super.dispose();
  }

  void _onDataChanged(Set<String> tables) {
    if (!tables.contains('view_definitions')) return;
    _dataChangeDebounce?.cancel();
    _dataChangeDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _reload();
    });
  }

  // Block-bodied setState -- not `() => _viewsFuture = _dao
  // .loadViewsForTable(...)`. An arrow closure whose body is that
  // Future-returning assignment infers a Future return type itself, which
  // trips setState's own debug-mode "callback argument returned a Future"
  // check -- the identical landmine found live in ListViewScreen this same
  // session (see CLAUDE.md's setState-arrow-closure note), caught here by
  // grepping for the pattern rather than waiting to hit it too.
  void _reload() {
    setState(() {
      _viewsFuture = _dao.loadViewsForTable(widget.tableName);
    });
  }

  Future<void> _createView() async {
    // Per the design doc's own "New View dialog: pick type -- List or
    // Kanban" description -- both have real screens as of build order
    // step 3.
    final choice = await showDialog<_NewViewChoice>(
      context: context,
      builder: (context) => const _NewViewDialog(),
    );
    if (choice == null) return;

    final viewId = await _dao.createView(
      tableName: widget.tableName,
      viewType: choice.viewType,
      displayName: choice.name,
    );
    final views = await _dao.loadViewsForTable(widget.tableName);
    final created = views.firstWhere((v) => v.viewId == viewId);
    if (!mounted) return;
    setState(() {
      _viewsFuture = Future.value(views);
    });
    widget.onViewSelected(created);
  }

  Future<void> _renameView(ViewDefinition view) async {
    final controller = TextEditingController(text: view.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename view'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == view.displayName) return;
    await _dao.renameView(view.viewId, name);
    _reload();
    // Renaming the tab this device currently has *open* doesn't otherwise
    // reach the screen showing it -- `HomeShell` only refreshes its own
    // cached `ViewDefinition` when a genuinely different view is selected,
    // not when the active one's own metadata changes. `ListViewScreen`'s
    // own [SyncService.dataChanges] subscription covers a *remote* rename
    // arriving later, but a local write like this one never goes through
    // that (it's crdt_sync's incoming-changeset hook, not a general
    // local-write signal) -- so the local case needs this explicit nudge.
    // Found live: renaming the open "Test 4" view to "Test 5" left the
    // AppBar title stuck on the old name until switching views and back.
    if (widget.currentViewId == view.viewId) {
      final views = await _dao.loadViewsForTable(widget.tableName);
      for (final updated in views) {
        if (updated.viewId == view.viewId) {
          widget.onViewSelected(updated);
          break;
        }
      }
    }
  }

  Future<void> _deleteView(ViewDefinition view) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${view.displayName}"?'),
        content: const Text('This view can be restored later from Manage Views.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _dao.softDeleteView(view.viewId);
    // Deleting the tab that's currently active falls back to Grid --
    // otherwise HomeShell would keep trying to show a view that no longer
    // resolves.
    if (widget.currentViewId == view.viewId) widget.onViewSelected(null);
    _reload();
  }

  Future<void> _showViewMenu(ViewDefinition view) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'rename') await _renameView(view);
    if (choice == 'delete') await _deleteView(view);
  }

  /// Build order step 4 -- drag-to-reorder plus a real place to restore a
  /// soft-deleted view from (see [ManageViewsScreen]'s own doc comment for
  /// why the earlier delete-confirmation dialog's "restored later from
  /// Manage Views" line needed this screen to actually exist). Reloads
  /// unconditionally on return, same "cheap, and covers rename/delete/
  /// reorder alike" reasoning `HomeShell._reloadTables` already uses for
  /// its own return-from-Settings reload.
  Future<void> _openManageViews() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ManageViewsScreen(
          tableName: widget.tableName,
          currentViewId: widget.currentViewId,
          onViewSelected: widget.onViewSelected,
        ),
      ),
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return PreferredSize(
      preferredSize: widget.preferredSize,
      child: FutureBuilder<List<ViewDefinition>>(
        future: _viewsFuture,
        builder: (context, snapshot) {
          final views = snapshot.data ?? const [];
          return SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: ChoiceChip(
                    label: const Text('Grid'),
                    selected: widget.currentViewId == null,
                    onSelected: (_) => widget.onViewSelected(null),
                  ),
                ),
                for (final view in views)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    child: GestureDetector(
                      onLongPress: () => _showViewMenu(view),
                      onSecondaryTap: () => _showViewMenu(view),
                      child: ChoiceChip(
                        label: Text(view.displayName),
                        selected: widget.currentViewId == view.viewId,
                        onSelected: (_) => widget.onViewSelected(view),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'New view',
                    onPressed: _createView,
                  ),
                ),
                if (views.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    child: IconButton(
                      icon: const Icon(Icons.reorder),
                      tooltip: 'Manage views',
                      onPressed: _openManageViews,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _NewViewChoice {
  const _NewViewChoice({required this.viewType, required this.name});

  final String viewType;
  final String name;
}

/// Type (List/Kanban) + name picker for [_ViewSwitcherBarState._createView].
/// A separate stateful widget rather than inline in that method -- the type
/// choice needs its own [setState] to drive the dialog's "Create" button
/// enablement (a name alone isn't enough; both fields are required).
class _NewViewDialog extends StatefulWidget {
  const _NewViewDialog();

  @override
  State<_NewViewDialog> createState() => _NewViewDialogState();
}

class _NewViewDialogState extends State<_NewViewDialog> {
  String _viewType = 'list';
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New view'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'list', label: Text('List'), icon: Icon(Icons.view_list_outlined)),
              ButtonSegment(value: 'kanban', label: Text('Kanban'), icon: Icon(Icons.view_column_outlined)),
            ],
            selected: {_viewType},
            onSelectionChanged: (selection) => setState(() => _viewType = selection.first),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'View name'),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          onPressed: () {
            final name = _controller.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(context, _NewViewChoice(viewType: _viewType, name: name));
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}
