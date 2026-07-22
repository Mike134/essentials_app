import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:trina_grid/trina_grid.dart';

import '../db/generic_dao.dart';
import '../models/table_config.dart';
import '../util/strings.dart';
import 'generic_form_screen.dart';

/// Table view for a single table, driven entirely by [config], built on
/// TrinaGrid (https://github.com/doonfrs/trina_grid -- the maintained
/// fork of the now-unmaintained PlutoGrid). TrinaGrid owns scrolling
/// (frozen header, frozen columns), column resizing, sorting, and normal
/// cell editing natively -- a hand-rolled grid was tried first but kept
/// hitting exactly the problems a real grid widget already solves
/// (synced horizontal scroll with a frozen header, resizable/frozen
/// columns).
///
/// Interaction model, adapted to what TrinaGrid does natively rather than
/// forcing an exact match to the original hand-rolled design: a cell
/// enters edit mode on double-click or Enter-after-selecting (TrinaGrid's
/// own default), not on single tap. `id` is frozen to the left and
/// `readOnly`, so it never enters edit mode at all -- structurally
/// read-only, not just visually. Opening the full form and deleting are
/// both explicit icon buttons in a frozen trailing actions column, rather
/// than a double-tap -- TrinaGrid already claims double-tap for its own
/// inline cell editing, so reusing it for "open the form" would race
/// against that.
class GenericListScreen extends StatefulWidget {
  const GenericListScreen({super.key, required this.config, this.drawer});

  final TableConfig config;

  /// Forwarded straight into this screen's own [Scaffold] -- lets the
  /// responsive nav shell attach the app's navigation [Drawer] on narrow
  /// (Android) layouts without this screen knowing about app-level nav.
  final Widget? drawer;

  @override
  State<GenericListScreen> createState() => _GenericListScreenState();
}

class _GenericListScreenState extends State<GenericListScreen> {
  static const String _actionsField = '_actions';

  late final GenericDao _dao;
  late Future<_ListData> _rowsFuture;

  @override
  void initState() {
    super.initState();
    _dao = GenericDao(widget.config);
    _reload();
  }

  @override
  void didUpdateWidget(covariant GenericListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config.tableName != widget.config.tableName) {
      _dao = GenericDao(widget.config);
      _reload();
    }
  }

  void _reload() {
    setState(() {
      _rowsFuture = _loadData();
    });
  }

  /// Fetches rows plus, for every lookup [FieldConfig], an id -> display-text
  /// map -- used both to label each option in that field's inline dropdown
  /// (see _buildFieldColumn's `TrinaColumnType.select`) and to turn the
  /// selected id back into text for the cell's own display (`formatter`).
  Future<_ListData> _loadData() async {
    final rows = await _dao.getAll();
    final lookupMaps = <String, Map<int, String>>{};
    for (final field in widget.config.fields) {
      if (!field.isLookup) continue;
      final lookup = field.lookup!;
      final options = await _dao.getLookupOptions(lookup);
      lookupMaps[field.column] = {
        for (final option in options)
          option[lookup.valueColumn] as int: '${option[lookup.displayColumn]}',
      };
    }
    return _ListData(rows: rows, lookupMaps: lookupMaps);
  }

  Future<void> _openForm({Map<String, Object?>? row}) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => GenericFormScreen(config: widget.config, existing: row),
      ),
    );
    if (changed == true) _reload();
  }

  Future<void> _delete(Map<String, Object?> row) async {
    final label = '${row[widget.config.displayColumn] ?? ''}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete record?'),
        content: Text('Delete "$label"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _dao.delete(row['id'] as int);
      _reload();
    } on StillInUseException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _saveCellEdit(int id, String column, Object? value) async {
    try {
      await _dao.update(id, {column: value});
    } on DatabaseException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  List<TrinaColumn> _buildColumns(
    List<Map<String, Object?>> rows,
    Map<String, Map<int, String>> lookupMaps,
  ) {
    return [
      TrinaColumn(
        title: 'ID',
        field: 'id',
        type: TrinaColumnType.number(),
        readOnly: true,
        frozen: TrinaColumnFrozen.start,
        width: 80,
      ),
      for (final field in widget.config.fields) _buildFieldColumn(field, lookupMaps),
      TrinaColumn(
        title: '',
        field: _actionsField,
        type: TrinaColumnType.text(),
        readOnly: true,
        frozen: TrinaColumnFrozen.end,
        width: 120,
        renderer: (rendererContext) {
          // Looked up from the original rows by id, not rebuilt from the
          // grid's own cells -- boolean cells hold 1/0 rather than the row's
          // original null, and text cells coerce a null column to '', so
          // reconstructing from cells would feed the edit form subtly wrong
          // starting values for an existing row.
          final id = rendererContext.row.cells['id']!.value as int;
          final row = rows.firstWhere((r) => r['id'] == id);
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                visualDensity: VisualDensity.compact,
                onPressed: () => _openForm(row: row),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                visualDensity: VisualDensity.compact,
                onPressed: () => _delete(row),
              ),
            ],
          );
        },
      ),
    ];
  }

  TrinaColumn _buildFieldColumn(
    FieldConfig field,
    Map<String, Map<int, String>> lookupMaps,
  ) {
    if (field.readOnly) {
      // Computed, query-time-only value (e.g. subscription_computed's
      // yearly_cost/next_date) -- nothing to write back, so no inline
      // editor at all, same reasoning as `id`.
      return TrinaColumn(
        title: field.label,
        field: field.column,
        type: switch (field.type) {
          FieldType.real => TrinaColumnType.number(format: '#,##0.##'),
          FieldType.integer => TrinaColumnType.number(),
          _ => TrinaColumnType.text(),
        },
        readOnly: true,
        width: field.type == FieldType.text ? 220 : 110,
      );
    }

    if (field.type == FieldType.boolean) {
      return TrinaColumn(
        title: field.label,
        field: field.column,
        type: TrinaColumnType.number(),
        // Never enters TrinaGrid's own text/number editor -- the checkbox
        // renderer below *is* the edit, same as the original hand-rolled
        // design's "tap toggles immediately, no separate edit mode".
        readOnly: true,
        width: 100,
        renderer: (rendererContext) {
          final value = rendererContext.cell.value == 1 || rendererContext.cell.value == true;
          return Checkbox(
            value: value,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (checked) {
              rendererContext.stateManager.changeCellValue(
                rendererContext.cell,
                (checked ?? false) ? 1 : 0,
              );
            },
          );
        },
      );
    }

    if (field.isLookup) {
      // Cell values stay the raw FK id (see _cellValueFor) -- TrinaColumnType
      // .select's `items` are the ids themselves, not the referenced rows,
      // so the stored/edited value and the underlying column type never
      // diverge. `itemToString` labels each id in the dropdown popup;
      // `formatter` (a plain TrinaColumn property, independent of column
      // type) labels the cell itself when not being edited -- select columns
      // don't format their own display text the way number/date columns do.
      final options = lookupMaps[field.column] ?? const <int, String>{};
      String displayFor(int? id) => id == null ? '' : (options[id] ?? '');
      final items = <int?>[if (!field.required) null, ...options.keys];
      return TrinaColumn(
        title: field.label,
        field: field.column,
        type: TrinaColumnType.select<int?>(items, itemToString: displayFor),
        formatter: (value) => displayFor(value as int?),
        width: 160,
      );
    }

    return TrinaColumn(
      title: field.label,
      field: field.column,
      type: switch (field.type) {
        FieldType.integer => TrinaColumnType.number(),
        FieldType.real => TrinaColumnType.number(format: '#,##0.##'),
        _ => TrinaColumnType.text(),
      },
      width: field.type == FieldType.text ? 220 : 110,
    );
  }

  Object? _cellValueFor(FieldConfig field, Object? raw) {
    // Left as the raw FK id (or null) -- the select column's `items` are
    // ids, and its `formatter` (see _buildFieldColumn) turns that back into
    // display text for the cell. Converting it to a string here the way the
    // plain-text branch below does would desync the cell's value from
    // `TrinaColumnType.select<int?>`'s item type and break both the
    // dropdown's current-selection highlight and its edit validation.
    if (field.isLookup) return raw;
    if (field.type == FieldType.boolean) {
      return raw == 1 || raw == true ? 1 : 0;
    }
    if (field.type == FieldType.text) {
      return raw?.toString() ?? '';
    }
    return raw;
  }

  List<TrinaRow> _buildRows(List<Map<String, Object?>> rows) {
    return [
      for (final row in rows)
        TrinaRow(
          cells: {
            'id': TrinaCell(value: row['id']),
            for (final field in widget.config.fields)
              field.column: TrinaCell(value: _cellValueFor(field, row[field.column])),
            _actionsField: TrinaCell(value: ''),
          },
        ),
    ];
  }

  void _onGridChanged(TrinaGridOnChangedEvent event) {
    if (event.column.field == 'id' || event.column.field == _actionsField) return;

    final field = widget.config.fields.firstWhere((f) => f.column == event.column.field);
    // Computed/readOnly columns are readOnly in TrinaGrid too, so this
    // shouldn't fire for them -- guard anyway rather than writing to a
    // column that doesn't exist on the write target.
    if (field.readOnly) return;
    final id = event.row.cells['id']!.value as int;

    Object? value = event.value;
    if (field.isLookup) {
      // Already the selected option's raw id (or null) -- the select
      // column's items are ids themselves (see _buildFieldColumn), unlike
      // the plain-text branch below, which needs its own trim/empty->null
      // handling because TrinaGrid's text editor hands back a raw String.
    } else if (field.type == FieldType.text) {
      final text = (value as String? ?? '').trim();
      value = text.isEmpty ? null : text;
    }
    _saveCellEdit(id, event.column.field, value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(titleCase(widget.config.tableName))),
      drawer: widget.drawer,
      body: FutureBuilder<_ListData>(
        future: _rowsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          final data = snapshot.data;
          final rows = data?.rows ?? const [];
          if (rows.isEmpty) {
            return const Center(child: Text('No records yet.'));
          }
          final lookupMaps = data!.lookupMaps;
          return TrinaGrid(
            columns: _buildColumns(rows, lookupMaps),
            rows: _buildRows(rows),
            configuration: const TrinaGridConfiguration(
              columnSize: TrinaGridColumnSizeConfig(
                autoSizeMode: TrinaAutoSizeMode.none,
                resizeMode: TrinaResizeMode.normal,
              ),
            ),
            onChanged: _onGridChanged,
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openForm(),
        tooltip: 'Add',
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// Result of [_GenericListScreenState._loadData]: the raw rows (used for
/// editing/deleting, and for any non-lookup cell value) plus, per lookup
/// field, an id -> display-text map (used only to render grid cells).
class _ListData {
  const _ListData({required this.rows, required this.lookupMaps});

  final List<Map<String, Object?>> rows;
  final Map<String, Map<int, String>> lookupMaps;
}
