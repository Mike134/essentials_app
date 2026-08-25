import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';

import '../db/generic_dao.dart';
import '../db/sync_service.dart';
import '../db/theme_settings_dao.dart';
import '../db/view_definitions_dao.dart';
import '../models/table_config.dart';
import '../util/device_id.dart';
import '../util/saved_view_data.dart';
import 'generic_form_screen.dart';
import 'view_switcher_bar.dart';

/// Essentials v2 Phase 3, build order step 2 -- a saved List view: compact
/// rows (bold title + gray metadata line), optionally grouped by the
/// primary field into collapsible sections. See
/// claude/essentials-v2-phase3-design.md's "list" `config` JSON shape and
/// the architecture doc's "List view" write-up (worked out from a real
/// Memento Database Pro screenshot).
///
/// Sibling of [GenericListScreen]/(eventually) `KanbanViewScreen` -- same
/// constructor contract (`config`, `drawer`), own top-level [Scaffold], own
/// [ViewSwitcherBar] in `AppBar.bottom`. [view] is this screen's own
/// `view_definitions` row; [onViewSelected] bubbles a tab change on that bar
/// straight up to `HomeShell`, which owns the "which screen class to show"
/// decision (see [ViewSwitcherBar]'s own doc comment for why it doesn't
/// decide that itself).
class ListViewScreen extends StatefulWidget {
  const ListViewScreen({
    super.key,
    required this.config,
    required this.view,
    this.drawer,
    required this.onViewSelected,
  });

  final TableConfig config;
  final ViewDefinition view;
  final Widget? drawer;
  final ValueChanged<ViewDefinition?> onViewSelected;

  @override
  State<ListViewScreen> createState() => _ListViewScreenState();
}

class _ListGroup {
  _ListGroup(this.key) : rows = [];

  final String key;
  final List<Map<String, Object?>> rows;
}

class _ListViewScreenState extends State<ListViewScreen> {
  late GenericDao _dao;
  late Future<SavedViewData> _dataFuture;
  final _viewsDao = ViewDefinitionsDao();
  ThemeSettingsDao? _settingsDao;

  /// This screen's own live copy of [widget.view] -- deliberately not read
  /// straight off `widget.view` everywhere (see the AppBar title/config
  /// below), since renaming or reconfiguring the *currently open* view
  /// (via [ViewSwitcherBar]'s own rename dialog, or [_editConfig]) doesn't
  /// otherwise reach this object: `HomeShell` only updates its own cached
  /// `ViewDefinition` when [widget.onViewSelected] fires with a genuinely
  /// *different* view, not when the active one's own metadata changes.
  /// Found live: renaming "Test 4" to "Test 5" left this screen's AppBar
  /// stuck on the old name -- on both the renaming device and, separately,
  /// a second device that already had the same view open -- until
  /// switching views and back forced a fresh [ViewDefinition] through.
  late ViewDefinition _view;

  late Map<String, Object?> _config;
  Set<String> _collapsedGroups = {};

  /// See [GenericListScreen]'s identically-shaped `_dataChangeSubscription`
  /// -- sync itself already propagates a remote rename/config change
  /// correctly; this is what makes this screen's own display reactive to
  /// it, the same "found live: a device already showing this view didn't
  /// notice" gap that subscription was built to close for row data.
  StreamSubscription<Set<String>>? _dataChangeSubscription;
  Timer? _dataChangeDebounce;

  String get _collapsedKey => 'list_collapsed_groups:${_view.viewId}';

  @override
  void initState() {
    super.initState();
    _dao = GenericDao(widget.config);
    _view = widget.view;
    _config = _view.config;
    _dataFuture = _load();
    _dataChangeSubscription = SyncService.dataChanges.listen(_onDataChanged);
  }

  @override
  void didUpdateWidget(covariant ListViewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.view.viewId != widget.view.viewId || !identical(oldWidget.config, widget.config)) {
      _dao = GenericDao(widget.config);
      _view = widget.view;
      _config = _view.config;
      // Block-bodied, not `() => _dataFuture = _load()` -- an arrow closure
      // whose expression is itself the `Future<SavedViewData>`-returning
      // assignment infers that same Future return type, and setState's own
      // runtime check (debug builds) throws on exactly that ("setState()
      // callback argument returned a Future") -- found live on MIKE-12R
      // switching between List views. A block body's inferred return type
      // is always void regardless of what the last statement evaluates to.
      setState(() {
        _dataFuture = _load();
      });
    } else if (!identical(oldWidget.view, widget.view)) {
      // Same view id, but `HomeShell` handed down a genuinely new
      // `ViewDefinition` object -- e.g. `ViewSwitcherBar._renameView`
      // updating its cache after renaming the view this screen has open.
      // `HomeShell` keys this screen by `tableName:viewId`, so an unchanged
      // id means Flutter updates this same State rather than recreating
      // it -- without this branch, the rename would sync correctly but
      // this screen's own `_view` (and its AppBar title) would stay stuck
      // on the stale object. No data reload needed, just the metadata.
      setState(() {
        _view = widget.view;
        _config = widget.view.config;
      });
    }
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
      if (mounted) _refreshViewMetadata();
    });
  }

  /// Re-reads just this screen's own `view_definitions` row -- not a full
  /// [_reload] of the table's row data, which is unaffected by a view
  /// rename/reconfigure. Falls back to Grid (mirrors [ViewSwitcherBar
  /// ._deleteView]'s own behavior deleting the active view) if the view no
  /// longer resolves -- soft-deleted, here or elsewhere, since the last
  /// load.
  Future<void> _refreshViewMetadata() async {
    final views = await _viewsDao.loadViewsForTable(widget.config.tableName);
    ViewDefinition? updated;
    for (final view in views) {
      if (view.viewId == _view.viewId) {
        updated = view;
        break;
      }
    }
    if (!mounted) return;
    if (updated == null) {
      widget.onViewSelected(null);
      return;
    }
    if (updated.displayName == _view.displayName && mapEquals(updated.config, _config)) {
      return;
    }
    setState(() {
      _view = updated!;
      _config = updated.config;
    });
  }

  Future<SavedViewData> _load() async {
    final deviceId = await DeviceId.resolve();
    final settingsDao = _settingsDao ??= ThemeSettingsDao(deviceId: deviceId);

    final data = await loadSavedViewData(_dao, widget.config);

    final collapsedRaw = await settingsDao.loadDeviceSetting(_collapsedKey);
    final collapsed = <String>{};
    if (collapsedRaw != null) {
      try {
        final decoded = jsonDecode(collapsedRaw);
        if (decoded is List) collapsed.addAll(decoded.map((e) => '$e'));
      } catch (_) {
        // Malformed persisted state -- treat as "nothing collapsed" rather
        // than crash the whole view over stale device_settings JSON.
      }
    }
    _collapsedGroups = collapsed;

    return data;
  }

  // Block-bodied setState, same reasoning as didUpdateWidget's own -- see
  // that fix's doc comment.
  void _reload() => setState(() {
    _dataFuture = _load();
  });

  List<Map<String, Object?>> _sortedRows(List<Map<String, Object?>> rows) {
    final primaryColumn = _config['primary_field'] as String?;
    final primaryField = fieldByColumn(widget.config, primaryColumn);
    if (primaryField == null) return rows;
    final secondaryField = fieldByColumn(widget.config, _config['secondary_field'] as String?);
    final primaryDesc = _config['primary_sort_dir'] == 'desc';
    final secondaryDesc = _config['secondary_sort_dir'] == 'desc';

    final sorted = [...rows];
    sorted.sort((a, b) {
      var cmp = compareSavedViewValues(a[primaryField.column], b[primaryField.column]);
      if (primaryDesc) cmp = -cmp;
      if (cmp != 0) return cmp;
      if (secondaryField == null) return 0;
      var cmp2 = compareSavedViewValues(a[secondaryField.column], b[secondaryField.column]);
      if (secondaryDesc) cmp2 = -cmp2;
      return cmp2;
    });
    return sorted;
  }

  /// Groups already-sorted rows by the primary field's own *display* text
  /// (matching the reference screenshot: the group header shows the value
  /// itself, and every entry under it repeats that same value as its own
  /// Line 1) -- contiguous runs, safe because [_sortedRows] already sorts
  /// by the primary field first.
  List<_ListGroup> _buildGroups(List<Map<String, Object?>> sortedRows, FieldConfig primaryField, SavedViewData data) {
    final groups = <_ListGroup>[];
    for (final row in sortedRows) {
      final key = savedViewDisplayText(primaryField, row[primaryField.column], data);
      if (groups.isEmpty || groups.last.key != key) {
        groups.add(_ListGroup(key));
      }
      groups.last.rows.add(row);
    }
    return groups;
  }

  void _toggleGroup(String key) {
    setState(() {
      if (_collapsedGroups.contains(key)) {
        _collapsedGroups.remove(key);
      } else {
        _collapsedGroups.add(key);
      }
    });
    _saveCollapsed();
  }

  Future<void> _saveCollapsed() async {
    final deviceId = await DeviceId.resolve();
    final dao = _settingsDao ??= ThemeSettingsDao(deviceId: deviceId);
    await dao.setDeviceSetting(_collapsedKey, jsonEncode(_collapsedGroups.toList()));
  }

  void _expandAll() {
    setState(() => _collapsedGroups = {});
    _saveCollapsed();
  }

  Future<void> _collapseAll(SavedViewData data) async {
    final primaryField = fieldByColumn(widget.config, _config['primary_field'] as String?);
    if (primaryField == null) return;
    final groups = _buildGroups(_sortedRows(data.rows), primaryField, data);
    setState(() => _collapsedGroups = {for (final g in groups) g.key});
    await _saveCollapsed();
  }

  Future<void> _editConfig() async {
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (context) => _ListViewConfigDialog(fields: widget.config.fields, initial: _config),
    );
    if (result == null) return;
    await _viewsDao.updateViewConfig(_view.viewId, result);
    setState(() => _config = result);
  }

  Future<void> _openRow(Map<String, Object?> row) async {
    final openRowDetail = widget.config.openRowDetail;
    if (openRowDetail != null) {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (context) => openRowDetail(context, widget.config, row)));
      _reload();
      return;
    }
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => GenericFormScreen(config: widget.config, existing: row)),
    );
    if (changed == true) _reload();
  }

  /// "Add" FAB handler -- mirrors [GenericListScreen]'s own `addFab`.
  Future<void> _addRow() async {
    final changed = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => GenericFormScreen(config: widget.config)));
    if (changed == true) _reload();
  }

  /// Per-row "Copy" affordance -- a `ListView` has no TrinaGrid-style single
  /// -cell selection for a FAB to act on (see [GenericListScreen
  /// ._copySelected]'s own "whichever row the grid's current cell sits in"
  /// model), so copy lives directly on each row instead: no "select a row
  /// first" step needed, and every row already has an obvious tap target
  /// for it. Always the plain form, never [TableConfig.openRowDetail]'s
  /// detail view, same reasoning [GenericListScreen._copySelected] already
  /// documents -- duplicating a parent-child table's children was never the
  /// intent of "copy."
  Future<void> _copyRow(Map<String, Object?> row) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => GenericFormScreen(config: widget.config, copyFrom: row)),
    );
    if (changed == true) _reload();
  }

  Widget _buildRow(Map<String, Object?> row, FieldConfig primaryField, SavedViewData data) {
    final line1 = savedViewDisplayText(primaryField, row[primaryField.column], data);
    final secondaryField = fieldByColumn(widget.config, _config['secondary_field'] as String?);
    final extraColumns = (_config['extra_line2_fields'] as List?)?.cast<String>() ?? const [];

    final line2Parts = <String>[];
    if (secondaryField != null) {
      final text = savedViewDisplayText(secondaryField, row[secondaryField.column], data);
      if (text.isNotEmpty) line2Parts.add(text);
    }
    for (final column in extraColumns) {
      final field = fieldByColumn(widget.config, column);
      if (field == null) continue; // deleted since the view was configured
      final text = savedViewDisplayText(field, row[field.column], data);
      if (text.isNotEmpty) line2Parts.add(text);
    }

    return ListTile(
      title: Text(
        line1.isEmpty ? '(blank)' : line1,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: line2Parts.isEmpty ? null : Text(line2Parts.join(' · ')),
      trailing: IconButton(
        icon: const Icon(Icons.copy_outlined),
        tooltip: 'Copy',
        onPressed: () => _copyRow(row),
      ),
      onTap: () => _openRow(row),
    );
  }

  Widget _buildGroupHeader(_ListGroup group, bool collapsed) {
    return InkWell(
      onTap: () => _toggleGroup(group.key),
      child: Container(
        width: double.infinity,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                group.key.isEmpty ? '(blank)' : group.key,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Text('${group.rows.length}', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(SavedViewData data) {
    final primaryColumn = _config['primary_field'] as String?;
    final primaryField = fieldByColumn(widget.config, primaryColumn);
    // Covers both "never configured" and "the configured primary field was
    // since deleted" -- same "never crash on stale field metadata, offer a
    // way to fix it" posture as everywhere else in this app (see the design
    // doc's "Open questions" for this exact case).
    if (primaryField == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                primaryColumn == null
                    ? 'This view needs a Primary field before it can show anything.'
                    : 'This view\'s Primary field no longer exists -- pick a new one.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              ElevatedButton(onPressed: _editConfig, child: const Text('Configure view')),
            ],
          ),
        ),
      );
    }
    if (data.rows.isEmpty) return const Center(child: Text('No records yet.'));

    final sorted = _sortedRows(data.rows);
    if (_config['grouped'] != true) {
      return ListView.separated(
        itemCount: sorted.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) => _buildRow(sorted[i], primaryField, data),
      );
    }

    final groups = _buildGroups(sorted, primaryField, data);
    return ListView.builder(
      itemCount: groups.length,
      itemBuilder: (context, i) {
        final group = groups[i];
        final collapsed = _collapsedGroups.contains(group.key);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildGroupHeader(group, collapsed),
            if (!collapsed) for (final row in group.rows) _buildRow(row, primaryField, data),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _config['grouped'] == true;
    return Scaffold(
      appBar: AppBar(
        // The table's own name, not the view's -- matching GenericListScreen's
        // AppBar title exactly (`widget.config.displayName`). Which view is
        // active is already shown by the selected tab in ViewSwitcherBar
        // below; showing the view name here too read as confusing/redundant
        // (found live, real-device verification).
        title: Text(widget.config.displayName),
        actions: [
          if (grouped) ...[
            IconButton(icon: const Icon(Icons.unfold_more), tooltip: 'Expand all', onPressed: _expandAll),
            FutureBuilder<SavedViewData>(
              future: _dataFuture,
              builder: (context, snapshot) => IconButton(
                icon: const Icon(Icons.unfold_less),
                tooltip: 'Collapse all',
                onPressed: snapshot.data == null ? null : () => _collapseAll(snapshot.data!),
              ),
            ),
          ],
          IconButton(icon: const Icon(Icons.tune), tooltip: 'Configure view', onPressed: _editConfig),
        ],
        bottom: ViewSwitcherBar(
          tableName: widget.config.tableName,
          currentViewId: _view.viewId,
          onViewSelected: widget.onViewSelected,
        ),
      ),
      drawer: widget.drawer,
      body: FutureBuilder<SavedViewData>(
        future: _dataFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          return _buildBody(snapshot.data!);
        },
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'listViewAddFab',
        onPressed: _addRow,
        tooltip: 'Add',
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// Small config form -- Primary/Secondary field + sort direction, Group
/// checkbox, ordered Additional Line 2 fields. Matches
/// claude/essentials-v2-architecture.md's confirmed List view config
/// surface: "2 field pickers + 2 direction toggles + 1 checkbox + an
/// ordered list for extra Line 2 fields." Extra-field order is simply
/// check order (append on check, remove on uncheck) -- a full drag-reorder
/// widget wasn't judged worth the extra surface area for this first pass.
class _ListViewConfigDialog extends StatefulWidget {
  const _ListViewConfigDialog({required this.fields, required this.initial});

  final List<FieldConfig> fields;
  final Map<String, Object?> initial;

  @override
  State<_ListViewConfigDialog> createState() => _ListViewConfigDialogState();
}

class _ListViewConfigDialogState extends State<_ListViewConfigDialog> {
  String? _primary;
  String _primaryDir = 'asc';
  String? _secondary;
  String _secondaryDir = 'asc';
  bool _grouped = false;
  late List<String> _extra;

  @override
  void initState() {
    super.initState();
    _primary = widget.initial['primary_field'] as String?;
    _primaryDir = widget.initial['primary_sort_dir'] as String? ?? 'asc';
    _secondary = widget.initial['secondary_field'] as String?;
    _secondaryDir = widget.initial['secondary_sort_dir'] as String? ?? 'asc';
    _grouped = widget.initial['grouped'] == true;
    _extra = ((widget.initial['extra_line2_fields'] as List?)?.cast<String>() ?? const []).toList();

    // Drop a stale selection referencing a field deleted since this view
    // was last configured -- never crash on it, just forget the choice.
    final columns = {for (final f in widget.fields) f.column};
    if (!columns.contains(_primary)) _primary = null;
    if (!columns.contains(_secondary)) _secondary = null;
    _extra.removeWhere((c) => !columns.contains(c));
  }

  void _toggleExtra(String column, bool checked) {
    setState(() {
      if (checked) {
        if (!_extra.contains(column)) _extra.add(column);
      } else {
        _extra.remove(column);
      }
    });
  }

  /// Label above, [SegmentedButton] below (full width) rather than side by
  /// side -- a `Row` with a `Spacer` between the two overflowed on a narrow
  /// Android screen (found live, real-device verification: "RIGHT
  /// OVERFLOWED BY ... PIXELS" on both sort rows), since this dialog's own
  /// content width is capped to the *available* screen width (see [build]),
  /// not a fixed 420 that assumed a wide layout.
  Widget _sortDirRow(String label, String value, ValueChanged<String> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'asc', label: Text('Asc')),
            ButtonSegment(value: 'desc', label: Text('Desc')),
          ],
          selected: {value},
          onSelectionChanged: (selection) => onChanged(selection.first),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Configure List view'),
      content: SizedBox(
        // Capped to the available screen width (minus the AlertDialog's own
        // horizontal insets) rather than a fixed 420 -- that fixed width
        // assumed a wide/Windows layout and overflowed on a narrow Android
        // screen, found live on MIKE-12R.
        width: (MediaQuery.of(context).size.width - 96).clamp(240.0, 420.0).toDouble(),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _primary,
                decoration: const InputDecoration(labelText: 'Primary field (Line 1)'),
                items: [
                  for (final field in widget.fields)
                    DropdownMenuItem(value: field.column, child: Text(field.label)),
                ],
                onChanged: (v) => setState(() => _primary = v),
              ),
              _sortDirRow('Primary sort', _primaryDir, (v) => setState(() => _primaryDir = v)),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _secondary,
                decoration: const InputDecoration(labelText: 'Secondary field (Line 2)'),
                items: [
                  const DropdownMenuItem(child: Text('(none)')),
                  for (final field in widget.fields)
                    DropdownMenuItem(value: field.column, child: Text(field.label)),
                ],
                onChanged: (v) => setState(() => _secondary = v),
              ),
              _sortDirRow('Secondary sort', _secondaryDir, (v) => setState(() => _secondaryDir = v)),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Group by primary field'),
                value: _grouped,
                onChanged: (v) => setState(() => _grouped = v ?? false),
              ),
              const SizedBox(height: 8),
              const Align(alignment: Alignment.centerLeft, child: Text('Additional Line 2 fields')),
              for (final field in widget.fields)
                if (field.column != _primary && field.column != _secondary)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(field.label),
                    value: _extra.contains(field.column),
                    onChanged: (v) => _toggleExtra(field.column, v ?? false),
                  ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          onPressed: _primary == null
              ? null
              : () => Navigator.pop(context, <String, Object?>{
                  'primary_field': _primary,
                  'primary_sort_dir': _primaryDir,
                  'secondary_field': _secondary,
                  'secondary_sort_dir': _secondaryDir,
                  'extra_line2_fields': _extra,
                  'grouped': _grouped,
                }),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
