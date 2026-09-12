import 'package:flutter/material.dart';
import 'package:trina_grid/trina_grid.dart';

import '../db/sync_service.dart';
import '../db/view_definitions_dao.dart';
import '../util/display_aware_filters.dart';

/// Replaces TrinaGrid's own stock filter-management popup (the bare
/// `+`/`-`/red-`X` icon toolbar over a raw Column/Type/Value grid) with a
/// plain-language dialog -- Mike's own report: "the filter dialogue is
/// anything but intuitive... lose the icons and have buttons stating Add
/// Filter, Remove Filter, Clear Filters, and Close."
///
/// Reached from [GenericListScreen]'s own column context menu ("Set
/// Filter" -- see `_ColumnMenuDelegate.onSelected`'s override of
/// [TrinaColumnMenuDelegateDefault.defaultMenuSetFilter]), which is the
/// only place this app can actually intercept: the small filter icon
/// TrinaGrid shows next to an already-filtered column's own title calls
/// `stateManager.showFilterPopup` directly (`trina_column_title.dart`,
/// hardcoded, no override hook exposed) -- clicking *that* icon still
/// opens the library's own stock popup. Known, accepted gap; the column
/// menu's "Set Filter" is the reliable path to this dialog.
///
/// Edits are staged locally (a plain in-memory list, not applied to
/// [stateManager] until "Close") -- matches an ordinary dialog's Cancel-
/// by-default feel more closely than TrinaGrid's own popup, which applies
/// every keystroke live.
///
/// Also where a Filter Set gets saved ("Save as Filter Set...") -- a named,
/// shared (`view_definitions`, `view_type = 'filter'`) snapshot of whatever
/// rows are currently staged here, surfaced as its own button in
/// [ViewSwitcherBar] (see that file's own `onFilterSetSelected` doc
/// comment) for one-tap re-application later. Mike's own framing: "we
/// can create and save List views and Kanban views... can we also save
/// Filter Sets and make them buttons along the top."
Future<void> showFilterEditorDialog(
  BuildContext context,
  TrinaGridStateManager stateManager,
  TrinaColumn initialColumn,
  String tableName,
) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) =>
        _FilterEditorDialog(stateManager: stateManager, initialColumn: initialColumn, tableName: tableName),
  );
}

class _EditableFilterRow {
  _EditableFilterRow({required this.columnField, required this.filterType, required String value})
    : valueController = TextEditingController(text: value);

  String? columnField;
  TrinaFilterType filterType;
  final TextEditingController valueController;

  void dispose() => valueController.dispose();
}

class _FilterEditorDialog extends StatefulWidget {
  const _FilterEditorDialog({required this.stateManager, required this.initialColumn, required this.tableName});

  final TrinaGridStateManager stateManager;
  final TrinaColumn initialColumn;
  final String tableName;

  @override
  State<_FilterEditorDialog> createState() => _FilterEditorDialogState();
}

class _FilterEditorDialogState extends State<_FilterEditorDialog> {
  late final List<TrinaColumn> _filterableColumns = widget.stateManager.refColumns
      .where((c) => c.enableFilterMenuItem)
      .toList();

  late final List<_EditableFilterRow> _rows = [
    for (final row in widget.stateManager.filterRows)
      _EditableFilterRow(
        columnField: row.cells[FilterHelper.filterFieldColumn]!.value as String?,
        filterType: row.cells[FilterHelper.filterFieldType]!.value as TrinaFilterType,
        value: row.cells[FilterHelper.filterFieldValue]!.value?.toString() ?? '',
      ),
  ];

  int? _selectedIndex;

  @override
  void initState() {
    super.initState();
    _selectedIndex = _rows.isEmpty ? null : _rows.length - 1;
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  TrinaFilterType _typeByTitle(String title) =>
      displayAwareFilterTypes.firstWhere((f) => f.title == title, orElse: () => displayAwareFilterTypes.first);

  void _addFilter() {
    setState(() {
      _rows.add(
        _EditableFilterRow(
          columnField: widget.initialColumn.field,
          filterType: displayAwareFilterTypes.first,
          value: '',
        ),
      );
      _selectedIndex = _rows.length - 1;
    });
  }

  void _removeSelected() {
    final index = _selectedIndex;
    if (index == null) return;
    setState(() {
      _rows.removeAt(index).dispose();
      _selectedIndex = _rows.isEmpty ? null : index.clamp(0, _rows.length - 1);
    });
  }

  void _clearAll() {
    setState(() {
      for (final row in _rows) {
        row.dispose();
      }
      _rows.clear();
      _selectedIndex = null;
    });
  }

  /// Prompts for a name, then saves the *currently staged* rows (not
  /// necessarily applied yet -- saving and applying are independent
  /// actions here, same as this dialog's own "Close" not being the only
  /// way anything happens) as a real, shared `view_definitions` row.
  /// Reuses the exact same `{column, type, value}` shape
  /// `GenericListScreen._persistGridSettings`/`_onGridLoaded` already use
  /// for a table's own per-device saved filter, so one JSON shape covers
  /// both concepts. [SyncService.notifyLocalDataChange] is the only way
  /// [ViewSwitcherBar]'s own live-refresh subscription (fed by *remote*
  /// changesets only) learns about a filter set saved from over here,
  /// a completely different widget than the one holding that subscription.
  Future<void> _saveAsFilterSet() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Save as Filter Set'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Filter Set name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;

    await ViewDefinitionsDao().createView(
      tableName: widget.tableName,
      viewType: 'filter',
      displayName: name,
      config: {
        'rows': [
          for (final row in _rows)
            if (row.columnField != null)
              {
                'column': row.columnField,
                'type': row.filterType.title,
                'value': row.valueController.text,
              },
        ],
      },
    );
    SyncService.notifyLocalDataChange({'view_definitions'});
  }

  void _close() {
    final filterRows = [
      for (final row in _rows)
        if (row.columnField != null)
          FilterHelper.createFilterRow(
            columnField: row.columnField,
            filterType: row.filterType,
            filterValue: row.valueController.text,
          ),
    ];
    widget.stateManager.setFilterWithFilterRows(filterRows);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Filters'),
      content: SizedBox(
        width: 520,
        height: 360,
        child: _rows.isEmpty
            ? const Center(child: Text('No filters set.'))
            : RadioGroup<int>(
                groupValue: _selectedIndex,
                onChanged: (value) => setState(() => _selectedIndex = value),
                child: ListView.separated(
                  itemCount: _rows.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (context, index) => _buildRow(index),
                ),
              ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        Wrap(
          spacing: 4,
          children: [
            TextButton(onPressed: _addFilter, child: const Text('Add Filter')),
            TextButton(onPressed: _selectedIndex == null ? null : _removeSelected, child: const Text('Remove Filter')),
            TextButton(onPressed: _rows.isEmpty ? null : _clearAll, child: const Text('Clear Filters')),
            TextButton(
              onPressed: _rows.isEmpty ? null : _saveAsFilterSet,
              child: const Text('Save as Filter Set...'),
            ),
          ],
        ),
        FilledButton(onPressed: _close, child: const Text('Close')),
      ],
    );
  }

  Widget _buildRow(int index) {
    final row = _rows[index];
    final isSelected = index == _selectedIndex;
    return Material(
      color: isSelected ? Theme.of(context).colorScheme.primaryContainer : null,
      child: InkWell(
        // Selecting a row by tapping *anywhere* on it doesn't reliably
        // work on its own -- the dropdowns/text field each absorb their
        // own taps before this InkWell ever sees them, leaving only the
        // thin gaps between controls as a real tap target. Mike's own
        // report: "you need to be able to select any existing row." The
        // explicit Radio below is the actual, always-reachable way to
        // select a row for "Remove Filter" -- this outer onTap stays too,
        // as a convenience for whatever margin *does* exist, not the only
        // way in.
        onTap: () => setState(() => _selectedIndex = index),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              Radio<int>(value: index),
              Expanded(
                child: DropdownButton<String?>(
                  isExpanded: true,
                  value: row.columnField,
                  items: [
                    for (final column in _filterableColumns)
                      DropdownMenuItem(value: column.field, child: Text(column.title, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (value) => setState(() => row.columnField = value),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: row.filterType.title,
                  items: [
                    for (final type in displayAwareFilterTypes)
                      DropdownMenuItem(value: type.title, child: Text(type.title, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (value) => setState(() => row.filterType = _typeByTitle(value!)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(controller: row.valueController, decoration: const InputDecoration(isDense: true)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
