import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';

import '../db/generic_dao.dart';
import '../db/sync_service.dart';
import '../db/view_definitions_dao.dart';
import '../models/table_config.dart';
import '../util/lookup_value.dart';
import '../util/saved_view_data.dart';
import 'generic_form_screen.dart';
import 'view_switcher_bar.dart';

/// Essentials v2 Phase 3, build order step 3 -- a saved Kanban view: the
/// same records as Grid, grouped into columns by one field's configured
/// options, in their already-set order. See
/// claude/essentials-v2-architecture.md's "Kanban view" write-up (confirmed
/// design, 2026-08-24) and claude/essentials-v2-phase3-design.md's
/// "kanban" `config` JSON shape.
///
/// **Group field can be either a fixed-list (inline `select`) field or a
/// `select`/linked (dropdown lookup) field** -- extended from the original
/// inline-only scope per Mike's real-world usage: "It is much more likely
/// that a lookup will contain status codes" than a fixed list defined
/// directly on the field. Both are just different sources for the same
/// "ordered id/key -> label" shape [_buildColumns] needs: an inline
/// field's own [FieldConfig.inlineOptions] for the first, and the referenced
/// lookup table's live rows (already fetched, in order, by
/// [loadSavedViewData]'s `lookupMaps` -- see that function's own doc
/// comment) for the second. A lookup field's raw stored value is the
/// referenced row's id, stringified per this app's TEXT-everything
/// convention (see [parseLookupValue]'s own doc comment) -- normalized to
/// that same string form before comparing against a column's key, so
/// dragging a card writes back exactly what a hand-edited dropdown would.
///
/// Sibling of [ListViewScreen]/[GenericListScreen] -- same constructor
/// contract, own top-level [Scaffold], own [ViewSwitcherBar] in
/// `AppBar.bottom`, same live-refresh-on-remote-change and
/// refresh-on-local-rename handling (see [ListViewScreen]'s own doc
/// comments for the two real bugs those close).
class KanbanViewScreen extends StatefulWidget {
  const KanbanViewScreen({
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
  State<KanbanViewScreen> createState() => _KanbanViewScreenState();
}

/// One board column -- [key] is `null` for the implicit "(none)" bucket
/// (a blank/unset group value), otherwise the stored value's string form
/// (an inline option's own key, or a lookup field's referenced row id).
/// Every configured option gets its own column ([isConfigured] `true`,
/// [label] from the option) -- an inline field's [FieldConfig.inlineOptions]
/// entry, or a lookup field's live referenced row (id + display text, from
/// [SavedViewData.lookupMaps]); a stored value that doesn't match any
/// configured option (a deleted option, a soft-deleted lookup row, a stray
/// CSV-imported value) gets its own ad-hoc column instead ([isConfigured]
/// `false`, [label] the literal value) -- never silently dropping the
/// record, per the confirmed design's own "never hide the record" posture.
class _KanbanColumn {
  _KanbanColumn({required this.key, required this.label, required this.isConfigured}) : rows = [];

  final String? key;
  final String label;
  final bool isConfigured;
  final List<Map<String, Object?>> rows;
}

class _KanbanViewScreenState extends State<KanbanViewScreen> {
  late GenericDao _dao;
  late Future<SavedViewData> _dataFuture;
  final _viewsDao = ViewDefinitionsDao();

  /// See [ListViewScreen._view]'s identical doc comment -- same reasoning,
  /// same bug this closes.
  late ViewDefinition _view;
  late Map<String, Object?> _config;

  StreamSubscription<Set<String>>? _dataChangeSubscription;
  Timer? _dataChangeDebounce;

  final _boardScrollController = ScrollController();

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
  void didUpdateWidget(covariant KanbanViewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.view.viewId != widget.view.viewId || !identical(oldWidget.config, widget.config)) {
      _dao = GenericDao(widget.config);
      _view = widget.view;
      _config = _view.config;
      setState(() {
        _dataFuture = _load();
      });
    } else if (!identical(oldWidget.view, widget.view)) {
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
    _boardScrollController.dispose();
    super.dispose();
  }

  void _onDataChanged(Set<String> tables) {
    final touchesData = tables.contains(widget.config.tableName);
    final touchesView = tables.contains('view_definitions');
    if (!touchesData && !touchesView) return;
    _dataChangeDebounce?.cancel();
    _dataChangeDebounce = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      if (touchesView) _refreshViewMetadata();
      if (touchesData) _reload();
    });
  }

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

  Future<SavedViewData> _load() => loadSavedViewData(_dao, widget.config);

  void _reload() {
    setState(() {
      _dataFuture = _load();
    });
  }

  Future<void> _editConfig() async {
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (context) => _KanbanViewConfigDialog(fields: widget.config.fields, initial: _config),
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

  Future<void> _addRow() async {
    final changed = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => GenericFormScreen(config: widget.config)));
    if (changed == true) _reload();
  }

  Future<void> _copyRow(Map<String, Object?> row) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => GenericFormScreen(config: widget.config, copyFrom: row)),
    );
    if (changed == true) _reload();
  }

  /// Moving a card between columns is a plain [GenericDao.update] on the
  /// group field -- the same write path every other edit in this app
  /// already uses, no new write logic needed, per the confirmed design.
  Future<void> _moveRow(Map<String, Object?> row, FieldConfig groupField, String? newKey) async {
    final currentRaw = row[groupField.column]?.toString();
    final currentKey = (currentRaw == null || currentRaw.trim().isEmpty) ? null : currentRaw;
    if (currentKey == newKey) return;
    await _dao.update(row['id'] as int, {groupField.column: newKey});
    _reload();
  }

  List<_KanbanColumn> _buildColumns(List<Map<String, Object?>> rows, FieldConfig groupField, SavedViewData data) {
    final none = _KanbanColumn(key: null, label: '(none)', isConfigured: true);
    final configured = groupField.isLookup
        ? [
            for (final entry in (data.lookupMaps[groupField.column] ?? const {}).entries)
              _KanbanColumn(key: entry.key.toString(), label: entry.value, isConfigured: true),
          ]
        : [
            for (final option in groupField.inlineOptions ?? const [])
              _KanbanColumn(key: option.key, label: option.label, isConfigured: true),
          ];
    final byKey = {for (final c in [none, ...configured]) c.key: c};
    final extras = <_KanbanColumn>[];

    for (final row in rows) {
      final raw = row[groupField.column];
      final key = groupField.isLookup ? parseLookupValue(raw)?.toString() : raw?.toString();
      final normalizedKey = (key == null || key.trim().isEmpty) ? null : key;
      var column = byKey[normalizedKey];
      if (column == null) {
        // A stored value that doesn't match any currently-configured
        // option -- a deleted option, a stray CSV-imported value. Gets its
        // own ad-hoc column instead of silently dropping the record, per
        // the confirmed design's "never hide the record" posture.
        column = _KanbanColumn(key: normalizedKey, label: normalizedKey!, isConfigured: false);
        byKey[normalizedKey] = column;
        extras.add(column);
      }
      column.rows.add(row);
    }

    return [none, ...configured, ...extras];
  }

  List<Map<String, Object?>> _sortColumnRows(List<Map<String, Object?>> rows, SavedViewData data) {
    final primaryField = fieldByColumn(widget.config, _config['primary_field'] as String?);
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

  Widget _buildCard(Map<String, Object?> row, FieldConfig primaryField, SavedViewData data) {
    final title = savedViewDisplayText(primaryField, row[primaryField.column], data);
    final secondaryField = fieldByColumn(widget.config, _config['secondary_field'] as String?);
    final extraColumns = (_config['extra_fields'] as List?)?.cast<String>() ?? const [];

    final subtitleParts = <String>[];
    if (secondaryField != null) {
      final text = savedViewDisplayText(secondaryField, row[secondaryField.column], data);
      if (text.isNotEmpty) subtitleParts.add(text);
    }
    for (final column in extraColumns) {
      final field = fieldByColumn(widget.config, column);
      if (field == null) continue;
      final text = savedViewDisplayText(field, row[field.column], data);
      if (text.isNotEmpty) subtitleParts.add(text);
    }

    final card = Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        title: Text(title.isEmpty ? '(blank)' : title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: subtitleParts.isEmpty ? null : Text(subtitleParts.join(' · ')),
        trailing: IconButton(
          icon: const Icon(Icons.copy_outlined),
          tooltip: 'Copy',
          onPressed: () => _copyRow(row),
        ),
        onTap: () => _openRow(row),
      ),
    );

    // Long-press, not a plain Draggable -- matches this app's own established
    // cross-platform drag convention (see HomeShell's sidebar table drag),
    // so a quick tap still reaches the card's own onTap without racing a
    // drag gesture, on both mouse (Windows) and touch (Android).
    return LongPressDraggable<Map<String, Object?>>(
      data: row,
      feedback: Material(elevation: 4, borderRadius: BorderRadius.circular(4), child: SizedBox(width: 260, child: card)),
      childWhenDragging: Opacity(opacity: 0.3, child: card),
      child: card,
    );
  }

  Widget _buildColumn(_KanbanColumn column, FieldConfig groupField, FieldConfig primaryField, SavedViewData data) {
    final sorted = _sortColumnRows(column.rows, data);
    return SizedBox(
      width: 280,
      child: DragTarget<Map<String, Object?>>(
        onAcceptWithDetails: (details) => _moveRow(details.data, groupField, column.key),
        builder: (context, candidateData, rejectedData) {
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: candidateData.isNotEmpty
                ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3)
                : Theme.of(context).colorScheme.surfaceContainerLow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          column.label,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text('${sorted.length}', style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: sorted.isEmpty
                      ? const SizedBox.shrink()
                      : ListView(
                          children: [for (final row in sorted) _buildCard(row, primaryField, data)],
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody(SavedViewData data) {
    final groupColumn = _config['group_field'] as String?;
    final groupField = fieldByColumn(widget.config, groupColumn);
    final primaryColumn = _config['primary_field'] as String?;
    final primaryField = fieldByColumn(widget.config, primaryColumn);

    // Covers "never configured" and "the configured group/primary field
    // was since deleted" alike -- same posture as ListViewScreen's own
    // identical guard.
    final groupFieldValid = groupField != null && (groupField.isInlineSelect || groupField.isLookup);
    if (!groupFieldValid || primaryField == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                !groupFieldValid
                    ? 'This view needs a fixed-list or lookup Group field before it can show columns.'
                    : 'This view needs a Primary field before it can show anything.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              ElevatedButton(onPressed: _editConfig, child: const Text('Configure view')),
            ],
          ),
        ),
      );
    }

    final columns = _buildColumns(data.rows, groupField, data);
    // Visible thumb (not just touch/trackpad-swipe scrolling) -- found live
    // on MIKE-CU: a board with more columns than fit the window had no
    // visible way to tell it was scrollable at all, or to scroll it with a
    // mouse rather than a trackpad/touch gesture. `Scrollbar` needs its own
    // explicit controller shared with the `SingleChildScrollView` it wraps
    // to draw correctly for a horizontal, non-primary scroll view.
    return Scrollbar(
      controller: _boardScrollController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _boardScrollController,
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final column in columns)
              SizedBox(
                height: MediaQuery.of(context).size.height, // fills the body; Scaffold clips it correctly
                child: _buildColumn(column, groupField, primaryField, data),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Same fix as ListViewScreen's own identical AppBar title -- see
        // that screen's doc comment.
        title: Text(widget.config.displayName),
        actions: [
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
        heroTag: 'kanbanAddFab',
        onPressed: _addRow,
        tooltip: 'Add',
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// Group field (fixed-list/inline-select only, see the file's own doc
/// comment for why) + Primary/Secondary field + sort direction + ordered
/// extra card fields. Same shape as `ListViewScreen`'s own
/// `_ListViewConfigDialog`, plus the one Kanban-specific Group field
/// picker up front.
class _KanbanViewConfigDialog extends StatefulWidget {
  const _KanbanViewConfigDialog({required this.fields, required this.initial});

  final List<FieldConfig> fields;
  final Map<String, Object?> initial;

  @override
  State<_KanbanViewConfigDialog> createState() => _KanbanViewConfigDialogState();
}

class _KanbanViewConfigDialogState extends State<_KanbanViewConfigDialog> {
  String? _group;
  String? _primary;
  String _primaryDir = 'asc';
  String? _secondary;
  String _secondaryDir = 'asc';
  late List<String> _extra;

  List<FieldConfig> get _groupCandidates =>
      [for (final f in widget.fields) if (f.isInlineSelect || f.isLookup) f];

  @override
  void initState() {
    super.initState();
    _group = widget.initial['group_field'] as String?;
    _primary = widget.initial['primary_field'] as String?;
    _primaryDir = widget.initial['primary_sort_dir'] as String? ?? 'asc';
    _secondary = widget.initial['secondary_field'] as String?;
    _secondaryDir = widget.initial['secondary_sort_dir'] as String? ?? 'asc';
    _extra = ((widget.initial['extra_fields'] as List?)?.cast<String>() ?? const []).toList();

    final columns = {for (final f in widget.fields) f.column};
    final groupColumns = {for (final f in _groupCandidates) f.column};
    if (!groupColumns.contains(_group)) _group = null;
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
    final groupCandidates = _groupCandidates;
    return AlertDialog(
      title: const Text('Configure Kanban view'),
      content: SizedBox(
        width: (MediaQuery.of(context).size.width - 96).clamp(240.0, 420.0).toDouble(),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (groupCandidates.isEmpty)
                const Text(
                  'This table has no fixed-list or lookup field yet -- add one via '
                  'Manage Fields before a Kanban view can group by it.',
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: _group,
                  decoration: const InputDecoration(labelText: 'Group field (columns)'),
                  items: [
                    for (final field in groupCandidates)
                      DropdownMenuItem(value: field.column, child: Text(field.label)),
                  ],
                  onChanged: (v) => setState(() => _group = v),
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _primary,
                decoration: const InputDecoration(labelText: 'Primary field (card title)'),
                items: [
                  for (final field in widget.fields)
                    DropdownMenuItem(value: field.column, child: Text(field.label)),
                ],
                onChanged: (v) => setState(() => _primary = v),
              ),
              _sortDirRow('Primary sort (within column)', _primaryDir, (v) => setState(() => _primaryDir = v)),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _secondary,
                decoration: const InputDecoration(labelText: 'Secondary field (subtitle)'),
                items: [
                  const DropdownMenuItem(child: Text('(none)')),
                  for (final field in widget.fields)
                    DropdownMenuItem(value: field.column, child: Text(field.label)),
                ],
                onChanged: (v) => setState(() => _secondary = v),
              ),
              _sortDirRow('Secondary sort', _secondaryDir, (v) => setState(() => _secondaryDir = v)),
              const SizedBox(height: 12),
              const Align(alignment: Alignment.centerLeft, child: Text('Additional card fields')),
              for (final field in widget.fields)
                if (field.column != _group && field.column != _primary && field.column != _secondary)
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
          onPressed: (_group == null || _primary == null)
              ? null
              : () => Navigator.pop(context, <String, Object?>{
                  'group_field': _group,
                  'primary_field': _primary,
                  'primary_sort_dir': _primaryDir,
                  'secondary_field': _secondary,
                  'secondary_sort_dir': _secondaryDir,
                  'extra_fields': _extra,
                }),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
