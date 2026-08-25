import 'package:flutter/material.dart';

import '../db/view_definitions_dao.dart';

/// Essentials v2 Phase 3, build order step 4 -- view management polish:
/// drag-to-reorder the tabs [ViewSwitcherBar] shows, plus rename/delete/
/// restore in one place rather than only per-tab (rename/delete already
/// existed on the tab's own long-press menu since Step 2; this screen adds
/// reorder and, for delete, a real place to actually restore from --
/// [ViewSwitcherBar]'s own delete-confirmation dialog has said "This view
/// can be restored later from Manage Views" since Step 2, before this
/// screen existed to make that true).
///
/// Scoped to one table's List/Kanban views (never Grid, which isn't a real
/// `view_definitions` row) -- matches [ViewSwitcherBar]'s own per-table
/// scope. Reached from that bar's own "Manage views" icon.
///
/// [currentViewId]/[onViewSelected] mirror [ViewSwitcherBar]'s own --
/// renaming or deleting the *currently open* view from in here needs the
/// identical explicit propagation up to the screen showing it that
/// [ViewSwitcherBar._renameView]/`_deleteView` already established (a
/// local write never reaches `SyncService.dataChanges` -- that's the
/// incoming-changeset hook, not a general local-write signal -- see
/// `ListViewScreen._view`'s own doc comment for the full reasoning).
class ManageViewsScreen extends StatefulWidget {
  const ManageViewsScreen({
    super.key,
    required this.tableName,
    required this.currentViewId,
    required this.onViewSelected,
  });

  final String tableName;
  final int? currentViewId;
  final ValueChanged<ViewDefinition?> onViewSelected;

  @override
  State<ManageViewsScreen> createState() => _ManageViewsScreenState();
}

class _ViewsData {
  _ViewsData({required this.active, required this.deleted});

  final List<ViewDefinition> active;
  final List<ViewDefinition> deleted;
}

class _ManageViewsScreenState extends State<ManageViewsScreen> {
  final _dao = ViewDefinitionsDao();
  late Future<_ViewsData> _viewsFuture;
  bool _deletedExpanded = false;

  @override
  void initState() {
    super.initState();
    _viewsFuture = _load();
  }

  Future<_ViewsData> _load() async {
    final all = await _dao.loadAllViewsForTable(widget.tableName);
    return _ViewsData(
      active: [for (final v in all) if (!v.isDeleted) v],
      deleted: [for (final v in all) if (v.isDeleted) v],
    );
  }

  void _reload() {
    setState(() {
      _viewsFuture = _load();
    });
  }

  Future<void> _reorder(List<ViewDefinition> active, int oldIndex, int newIndex) async {
    // `onReorderItem` (not the deprecated `onReorder`) already pre-adjusts
    // `newIndex` for the removed item -- same convention ManageFieldsScreen
    // already established, see that screen's own doc comment.
    final reordered = [...active];
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    await _dao.reorderViews(widget.tableName, [for (final v in reordered) v.viewId]);
    _reload();
  }

  Future<void> _rename(ViewDefinition view) async {
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
    if (widget.currentViewId == view.viewId) {
      final all = await _dao.loadAllViewsForTable(widget.tableName);
      for (final updated in all) {
        if (updated.viewId == view.viewId) {
          widget.onViewSelected(updated);
          break;
        }
      }
    }
  }

  Future<void> _delete(ViewDefinition view) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${view.displayName}"?'),
        content: const Text('This can be undone from the Deleted section below.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _dao.softDeleteView(view.viewId);
    _reload();
    if (widget.currentViewId == view.viewId) {
      widget.onViewSelected(null);
    }
  }

  Future<void> _restore(ViewDefinition view) async {
    await _dao.restoreView(view.viewId);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Views')),
      body: FutureBuilder<_ViewsData>(
        future: _viewsFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Failed to load: ${snapshot.error}'));
          }
          final data = snapshot.data;
          if (data == null) return const Center(child: CircularProgressIndicator());

          final active = data.active;
          final deleted = data.deleted;

          return ListView(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
            children: [
              if (active.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('No saved views for this table yet -- create one from the "+" tab.'),
                )
              else
                // Keyed by membership (view ids joined), not just length --
                // same reasoning as ManageFieldsScreen's own identically-
                // shaped ReorderableListView key: forces a full remount
                // (fresh internal drag state) whenever active membership
                // changes for a reason other than this widget's own drag
                // gesture (e.g. a delete), rather than the reorder list's
                // own internal bookkeeping going stale.
                ReorderableListView(
                  key: ValueKey(active.map((v) => v.viewId).join(',')),
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  onReorderItem: (oldIndex, newIndex) => _reorder(active, oldIndex, newIndex),
                  children: [
                    for (final view in active)
                      ListTile(
                        key: ValueKey(view.viewId),
                        leading: Icon(view.viewType == 'kanban' ? Icons.view_column_outlined : Icons.view_list_outlined),
                        title: Text(view.displayName),
                        subtitle: Text(view.viewType == 'kanban' ? 'Kanban' : 'List'),
                        onTap: () => _rename(view),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Delete view',
                          onPressed: () => _delete(view),
                        ),
                      ),
                  ],
                ),
              if (deleted.isNotEmpty) ...[
                const SizedBox(height: 8),
                ExpansionTile(
                  title: Text('Deleted (${deleted.length})'),
                  initiallyExpanded: _deletedExpanded,
                  onExpansionChanged: (v) => setState(() => _deletedExpanded = v),
                  children: [
                    for (final view in deleted)
                      ListTile(
                        title: Text(view.displayName),
                        subtitle: Text(view.viewType == 'kanban' ? 'Kanban' : 'List'),
                        trailing: TextButton(
                          onPressed: () => _restore(view),
                          child: const Text('Restore'),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
