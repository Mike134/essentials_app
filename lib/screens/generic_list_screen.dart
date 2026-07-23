import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:trina_grid/trina_grid.dart';

import '../db/generic_dao.dart';
import '../db/table_view_settings_dao.dart';
import '../models/table_config.dart';
import '../theme/theme_controller.dart';
import '../util/color_picker.dart';
import '../util/device_id.dart';
import '../util/links.dart';
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
///
/// **Per-device view persistence** (column width/order/visibility/frozen
/// state, sort, filter) -- see CLAUDE.md "Real-usage findings". `id` and
/// the actions column are structurally fixed (never customized, never
/// persisted) -- only [TableConfig.fields] columns are. Every column/filter
/// affordance below (resize, drag-reorder, and the per-column header menu's
/// freeze/hide/filter items) already comes free from TrinaGrid; this screen
/// only adds capturing that state into `table_column_settings`/
/// `table_view_settings` and restoring it on the next load, scoped by the
/// live [DeviceId]. Writes are debounced (see [_scheduleSettingsSave]) --
/// TrinaGrid fires column-width-change notifications on every drag frame,
/// not just on release, and a settings row per table+device is a small
/// price per write but not one worth paying every frame.
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

  /// Debounce window between the last grid state change (resize, reorder,
  /// sort, filter, hide, freeze) and actually writing it -- coalesces a
  /// column drag's per-frame notifications into one write on release.
  static const Duration _saveDebounce = Duration(milliseconds: 600);

  late final GenericDao _dao;
  late Future<_ScreenData> _screenDataFuture;

  TrinaGridStateManager? _stateManager;
  Timer? _saveTimer;

  /// Serialized form of the last snapshot actually written to the db --
  /// lets [_scheduleSettingsSave] skip a write when nothing that matters
  /// (column width/order/hide/frozen, sort, filter) actually changed, since
  /// the same stateManager listener also fires on plain cell edits/
  /// selection changes that this screen doesn't need to persist.
  String? _lastPersistedSnapshot;

  /// Set from the same [_ScreenData] the grid itself was built from --
  /// [_persistGridSettings] and the Restore Defaults button need the dao,
  /// not just the settings values.
  TableViewSettingsDao? _settingsDao;

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
    // The pending timer (if any) closes over the stateManager that's about
    // to be torn down (GenericListScreen's build() below always remounts a
    // fresh TrinaGrid on reload -- see the doc comment on _ScreenData) --
    // cancel it rather than let it fire against a disposed stateManager.
    _saveTimer?.cancel();
    _stateManager = null;
    _lastPersistedSnapshot = null;
    setState(() {
      _screenDataFuture = _loadScreenData();
    });
  }

  /// Fetches everything one grid build needs: rows, lookup id -> text maps
  /// (see [_loadData]'s original doc), the live per-device id, and that
  /// device's saved column/view settings for this table (empty/null when
  /// there's nothing saved yet, e.g. first run or just after Restore
  /// Defaults).
  Future<_ScreenData> _loadScreenData() async {
    final data = await _loadData();
    final deviceId = await DeviceId.resolve();
    final settingsDao = TableViewSettingsDao(
      tableName: widget.config.tableName,
      deviceId: deviceId,
    );
    final columnSettings = {
      for (final setting in await settingsDao.loadColumnSettings())
        setting.columnName: setting,
    };
    final viewSetting = await settingsDao.loadViewSettings();
    return _ScreenData(
      rows: data.rows,
      lookupMaps: data.lookupMaps,
      settingsDao: settingsDao,
      columnSettings: columnSettings,
      viewSetting: viewSetting,
    );
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
      // A computed field (e.g. subscription_computed's yearly_cost) can
      // depend on whatever column just changed -- cost affects yearly_cost,
      // start_date/renewal_period_id affect next_date, etc. Rather than
      // hardcode that dependency graph in Dart (a second place the SQL
      // formula in schema.sql would need to stay in sync with), just
      // re-fetch whenever the table has any readOnly field at all. TrinaGrid
      // otherwise keeps showing whatever value a computed cell held at the
      // last full load, since editing a different cell doesn't touch it.
      if (widget.config.fields.any((f) => f.readOnly)) _reload();
    } on DatabaseException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  Future<void> _restoreDefaults(TableViewSettingsDao settingsDao) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore default view?'),
        content: const Text(
          'Resets column widths, order, visibility, frozen state, sort, and '
          'filter for this table on this device. Does not affect theme, '
          'font, or color settings, or any record data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await settingsDao.restoreDefaults();
    _reload();
  }

  // ===================== Per-device view state: restore =====================

  /// Applies [viewSetting]'s saved sort/filter to a just-loaded grid, then
  /// starts persisting future changes -- in that order, so restoring the
  /// saved state doesn't immediately re-trigger a save of the same state.
  void _onGridLoaded(TrinaGridOnLoadedEvent event, ViewSetting? viewSetting) {
    final stateManager = event.stateManager;
    _stateManager = stateManager;

    if (viewSetting?.sortColumn != null) {
      TrinaColumn? column;
      for (final c in stateManager.refColumns) {
        if (c.field == viewSetting!.sortColumn) {
          column = c;
          break;
        }
      }
      if (column != null) {
        if (viewSetting!.sortDirection == 'desc') {
          stateManager.sortDescending(column);
        } else {
          stateManager.sortAscending(column);
        }
      }
    }

    final filterJson = viewSetting?.filterJson;
    if (filterJson != null && filterJson.isNotEmpty) {
      final decoded = jsonDecode(filterJson) as List<dynamic>;
      final filterRows = [
        for (final entry in decoded)
          FilterHelper.createFilterRow(
            columnField: entry['column'] as String?,
            filterType:
                _filterTypesByName[entry['type']] ??
                const TrinaFilterTypeContains(),
            filterValue: entry['value'],
          ),
      ];
      if (filterRows.isNotEmpty) {
        stateManager.setFilterWithFilterRows(filterRows);
      }
    }

    stateManager.addListener(_scheduleSettingsSave);
    stateManager.resizingChangeNotifier.addListener(_scheduleSettingsSave);
  }

  // ===================== Per-device view state: persist =====================

  void _scheduleSettingsSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, _persistGridSettings);
  }

  Future<void> _persistGridSettings() async {
    final stateManager = _stateManager;
    final settingsDao = _settingsDao;
    if (stateManager == null || settingsDao == null) return;

    final fieldColumns = stateManager.columns.where(
      (c) => c.field != 'id' && c.field != _actionsField,
    );

    final columnSettings = [
      for (final (index, column) in fieldColumns.indexed)
        ColumnSetting(
          columnName: column.field,
          width: column.width,
          displayOrder: index,
          visible: !column.hide,
          frozen: switch (column.frozen) {
            TrinaColumnFrozen.start => 'left',
            TrinaColumnFrozen.end => 'right',
            TrinaColumnFrozen.none => null,
          },
        ),
    ];

    final sortedColumn = stateManager.hasSortedColumn ? stateManager.getSortedColumn : null;
    final filterRows = stateManager.hasFilter ? stateManager.filterRows : const <TrinaRow>[];
    final filterJson = filterRows.isEmpty
        ? null
        : jsonEncode([
            for (final row in filterRows)
              {
                'column': row.cells[FilterHelper.filterFieldColumn]!.value,
                'type':
                    (row.cells[FilterHelper.filterFieldType]!.value as TrinaFilterType)
                        .title,
                'value': row.cells[FilterHelper.filterFieldValue]!.value,
              },
          ]);
    final viewSetting = ViewSetting(
      sortColumn: sortedColumn?.field,
      sortDirection: sortedColumn == null
          ? null
          : (sortedColumn.sort.isDescending ? 'desc' : 'asc'),
      filterJson: filterJson,
    );

    final snapshot = jsonEncode({
      'columns': [
        for (final c in columnSettings)
          [c.columnName, c.width, c.displayOrder, c.visible, c.frozen],
      ],
      'sortColumn': viewSetting.sortColumn,
      'sortDirection': viewSetting.sortDirection,
      'filterJson': viewSetting.filterJson,
    });
    if (snapshot == _lastPersistedSnapshot) return;
    _lastPersistedSnapshot = snapshot;

    await settingsDao.saveColumnSettings(columnSettings);
    await settingsDao.saveViewSettings(viewSetting);
  }

  // ===================== Column building =====================

  /// [TableConfig.fields] reordered per saved `display_order`, falling back
  /// to declaration order for any field with nothing saved yet (a field
  /// added to the config after the device last saved, for instance).
  List<FieldConfig> _orderedFields(Map<String, ColumnSetting> columnSettings) {
    final fields = List<FieldConfig>.from(widget.config.fields);
    final order = [
      for (var i = 0; i < fields.length; i++)
        columnSettings[fields[i].column]?.displayOrder ?? i,
    ];
    final indexes = List<int>.generate(fields.length, (i) => i)
      ..sort((a, b) => order[a].compareTo(order[b]));
    return [for (final i in indexes) fields[i]];
  }

  List<TrinaColumn> _buildColumns(
    List<Map<String, Object?>> rows,
    Map<String, Map<int, String>> lookupMaps,
    Map<String, ColumnSetting> columnSettings,
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
      for (final field in _orderedFields(columnSettings))
        _buildFieldColumn(field, lookupMaps, columnSettings[field.column]),
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

  /// Applies a saved [ColumnSetting]'s width/visibility/frozen override, if
  /// any, on top of a just-built [column] -- these are all plain mutable
  /// fields on [TrinaColumn] (the same fields TrinaGrid's own resize/hide/
  /// freeze handlers mutate directly), so overriding post-construction is
  /// the natural way to layer a saved override onto the field's declared
  /// default without threading it through every branch in
  /// [_buildFieldColumn].
  TrinaColumn _withColumnSetting(TrinaColumn column, ColumnSetting? setting) {
    if (setting == null) return column;
    if (setting.width != null) column.width = setting.width!;
    column.hide = !setting.visible;
    column.frozen = switch (setting.frozen) {
      'left' => TrinaColumnFrozen.start,
      'right' => TrinaColumnFrozen.end,
      _ => TrinaColumnFrozen.none,
    };
    return column;
  }

  TrinaColumn _buildFieldColumn(
    FieldConfig field,
    Map<String, Map<int, String>> lookupMaps,
    ColumnSetting? setting,
  ) {
    if (field.readOnly) {
      // Computed, query-time-only value (e.g. subscription_computed's
      // yearly_cost/next_date) -- nothing to write back, so no inline
      // editor at all, same reasoning as `id`.
      return _withColumnSetting(
        TrinaColumn(
          title: field.label,
          field: field.column,
          type: switch (field.type) {
            FieldType.real => TrinaColumnType.number(format: '#,##0.##'),
            FieldType.integer => TrinaColumnType.number(),
            _ => TrinaColumnType.text(),
          },
          readOnly: true,
          width: field.type == FieldType.text ? 220 : 110,
        ),
        setting,
      );
    }

    if (field.type == FieldType.boolean) {
      return _withColumnSetting(
        TrinaColumn(
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
                // force: true -- this column is readOnly (see above, to
                // keep TrinaGrid's own text/number editor from opening);
                // changeCellValue's default readOnly gate
                // (canChangeCellValue -> column.checkReadOnly) silently
                // no-ops the change otherwise, since it can't distinguish
                // "readOnly so TrinaGrid's editor shouldn't open" from
                // "readOnly so this cell can never change" -- force says
                // the latter doesn't apply here, this renderer *is* the
                // editor. onChanged (-> _onGridChanged -> the actual db
                // write) still fires normally once the gate is bypassed.
                rendererContext.stateManager.changeCellValue(
                  rendererContext.cell,
                  (checked ?? false) ? 1 : 0,
                  force: true,
                );
              },
            );
          },
        ),
        setting,
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
      return _withColumnSetting(
        TrinaColumn(
          title: field.label,
          field: field.column,
          type: TrinaColumnType.select<int?>(items, itemToString: displayFor),
          formatter: (value) => displayFor(value as int?),
          width: 160,
        ),
        setting,
      );
    }

    if (field.isLink) {
      // Not readOnly -- double-click still enters TrinaGrid's normal text
      // editor to type/paste a URL, same as any other text field. Only the
      // trailing icon button is a distinct tap target for actually opening
      // it, so a plain tap/double-tap anywhere else in the cell still hits
      // TrinaGrid's own select/edit gesture handling rather than the icon.
      return _withColumnSetting(
        TrinaColumn(
          title: field.label,
          field: field.column,
          type: TrinaColumnType.text(),
          width: 220,
          renderer: (rendererContext) {
            final value = rendererContext.cell.value as String?;
            if (value == null || value.isEmpty) return const SizedBox.shrink();
            return Row(
              children: [
                Expanded(
                  child: Text(
                    value,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.blue,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.open_in_new, size: 16),
                  tooltip: 'Open link',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => openLink(value),
                ),
              ],
            );
          },
        ),
        setting,
      );
    }

    if (field.isColor) {
      // Not readOnly, same reasoning as isLink above -- the swatch is a
      // distinct tap target that opens the picker; a plain tap/double-tap
      // anywhere else in the cell still hits TrinaGrid's own text editor,
      // so typing a hex value directly still works too.
      return _withColumnSetting(
        TrinaColumn(
          title: field.label,
          field: field.column,
          type: TrinaColumnType.text(),
          width: 140,
          renderer: (rendererContext) {
            final value = rendererContext.cell.value as String?;
            final color = ThemeController.parseHexColor(value);
            return Row(
              children: [
                GestureDetector(
                  onTap: () async {
                    final picked = await pickColor(context, initial: color ?? Colors.white);
                    if (picked == null) return;
                    rendererContext.stateManager.changeCellValue(
                      rendererContext.cell,
                      ThemeController.colorToHex(picked),
                    );
                  },
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.grey),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(value ?? '', overflow: TextOverflow.ellipsis)),
              ],
            );
          },
        ),
        setting,
      );
    }

    return _withColumnSetting(
      TrinaColumn(
        title: field.label,
        field: field.column,
        type: switch (field.type) {
          FieldType.integer => TrinaColumnType.number(),
          FieldType.real => TrinaColumnType.number(format: '#,##0.##'),
          _ => TrinaColumnType.text(),
        },
        width: field.type == FieldType.text ? 220 : 110,
      ),
      setting,
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
      appBar: AppBar(
        title: Text(titleCase(widget.config.tableName)),
        actions: [
          FutureBuilder<_ScreenData>(
            future: _screenDataFuture,
            builder: (context, snapshot) {
              final settingsDao = snapshot.data?.settingsDao;
              return IconButton(
                icon: const Icon(Icons.restart_alt),
                tooltip: 'Restore default view',
                onPressed: settingsDao == null
                    ? null
                    : () => _restoreDefaults(settingsDao),
              );
            },
          ),
        ],
      ),
      drawer: widget.drawer,
      body: FutureBuilder<_ScreenData>(
        future: _screenDataFuture,
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
          _settingsDao = data.settingsDao;
          return TrinaGrid(
            columns: _buildColumns(rows, lookupMaps, data.columnSettings),
            rows: _buildRows(rows),
            configuration: TrinaGridConfiguration(
              columnSize: const TrinaGridColumnSizeConfig(
                autoSizeMode: TrinaAutoSizeMode.none,
                resizeMode: TrinaResizeMode.normal,
              ),
              style: _trinaGridStyle(context),
            ),
            onChanged: _onGridChanged,
            onLoaded: (event) => _onGridLoaded(event, data.viewSetting),
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

  /// TrinaGrid has its own independent theming (`TrinaGridStyleConfig`) --
  /// it does not read the ambient Flutter [Theme] at all, so without this
  /// the grid stayed hardcoded light regardless of what
  /// [ThemeController]/the Settings screen (CLAUDE.md "Real-usage
  /// findings" Step 5) set everything else to. Found by Mike switching to
  /// Dark and noticing the window chrome and form followed but the grid
  /// didn't. Starts from TrinaGrid's own light/dark preset (closest
  /// built-in match for borders/hover/selection colors, which this app
  /// doesn't have its own opinion on) and overrides just the background
  /// and text color/size to match the resolved theme exactly.
  TrinaGridStyleConfig _trinaGridStyle(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final backgroundColor = theme.scaffoldBackgroundColor;
    final textStyle = (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      color: theme.colorScheme.onSurface,
    );

    final base = isDark
        ? const TrinaGridStyleConfig.dark()
        : const TrinaGridStyleConfig();

    return base.copyWith(
      gridBackgroundColor: backgroundColor,
      rowColor: backgroundColor,
      cellTextStyle: textStyle,
      columnTextStyle: textStyle.copyWith(fontWeight: FontWeight.w600),
    );
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}

/// Every default [TrinaFilterType] TrinaGrid ships with, keyed by
/// [TrinaFilterType.title] -- used to turn a persisted filter's type name
/// (see [_GenericListScreenState._persistGridSettings]) back into the actual
/// instance TrinaGrid's filter row cells expect (see
/// [_GenericListScreenState._onGridLoaded]).
final Map<String, TrinaFilterType> _filterTypesByName = {
  for (final filterType in FilterHelper.defaultFilters) filterType.title: filterType,
};

/// Result of [_GenericListScreenState._loadData]: the raw rows (used for
/// editing/deleting, and for any non-lookup cell value) plus, per lookup
/// field, an id -> display-text map (used only to render grid cells).
class _ListData {
  const _ListData({required this.rows, required this.lookupMaps});

  final List<Map<String, Object?>> rows;
  final Map<String, Map<int, String>> lookupMaps;
}

/// Everything one grid build needs -- [_ListData]'s rows/lookupMaps plus
/// this device's saved column/view settings for [TableConfig.tableName].
/// [GenericListScreen] always fully remounts TrinaGrid on reload (the
/// FutureBuilder's `ConnectionState.waiting` branch swaps in a loading
/// spinner in between, so the next successful build sees a widget-type
/// change at that tree position and mounts a fresh TrinaGrid/state manager
/// rather than updating the old one) -- that remount is exactly the hook
/// [_GenericListScreenState._onGridLoaded] needs to reapply saved sort/
/// filter on every load, not just the first.
class _ScreenData {
  const _ScreenData({
    required this.rows,
    required this.lookupMaps,
    required this.settingsDao,
    required this.columnSettings,
    required this.viewSetting,
  });

  final List<Map<String, Object?>> rows;
  final Map<String, Map<int, String>> lookupMaps;
  final TableViewSettingsDao settingsDao;
  final Map<String, ColumnSetting> columnSettings;
  final ViewSetting? viewSetting;
}
