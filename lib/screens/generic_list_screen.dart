import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:trina_grid/trina_grid.dart';

import '../db/generic_dao.dart';
import '../db/sync_service.dart';
import '../db/table_view_settings_dao.dart';
import '../db/view_definitions_dao.dart';
import '../models/table_config.dart';
import '../theme/theme_controller.dart';
import '../util/bool_value.dart';
import '../util/color_picker.dart';
import '../util/column_autocomplete.dart';
import '../util/date_format.dart';
import '../util/device_id.dart';
import '../util/field_formats/field_format_handler.dart';
import '../util/link_record.dart';
import '../util/links.dart';
import '../util/lookup_value.dart';
import '../util/strings.dart';
import 'csv_import_screen.dart';
import 'generic_form_screen.dart';
import 'view_switcher_bar.dart';

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
/// the actions column are structurally fixed only in that their *renderer*
/// (readOnly numeric id, edit/delete icons) is hardcoded, not user
/// configurable -- their position/frozen/width/visible state persists the
/// same as any [TableConfig.fields] column, since TrinaGrid already lets
/// the user drag/freeze/hide them like any other column. Every column/filter
/// affordance below (resize, drag-reorder, and the per-column header menu's
/// freeze/hide/filter items) already comes free from TrinaGrid; this screen
/// only adds capturing that state into `table_column_settings`/
/// `table_view_settings` and restoring it on the next load, scoped by the
/// live [DeviceId]. Writes are debounced (see [_scheduleSettingsSave]) --
/// TrinaGrid fires column-width-change notifications on every drag frame,
/// not just on release, and a settings row per table+device is a small
/// price per write but not one worth paying every frame.
class GenericListScreen extends StatefulWidget {
  const GenericListScreen({
    super.key,
    required this.config,
    this.drawer,
    this.formExtraValues,
    this.onViewSelected,
  });

  final TableConfig config;

  /// Forwarded straight into this screen's own [Scaffold] -- lets the
  /// responsive nav shell attach the app's navigation [Drawer] on narrow
  /// (Android) layouts without this screen knowing about app-level nav.
  final Widget? drawer;

  /// Forwarded straight into [GenericFormScreen.extraValues] for the
  /// add/edit form this screen opens -- only current use: the embedded
  /// `order_items` grid inside [OrderSplitPaneScreen] passes the parent
  /// order's id here, so a new item silently gets the right `order_id`
  /// without it ever appearing as a field. `null` everywhere else.
  final Map<String, Object?>? formExtraValues;

  /// Essentials v2 Phase 3 -- non-null only when `HomeShell` builds this
  /// screen as the top-level "Grid" tab for a table (never set for a
  /// scoped/embedded grid like `OrderSplitPaneScreen`'s items pane, since
  /// [TableConfig.filterWhere] being set there means "not really this
  /// table's whole-table view"). When set, this screen renders a
  /// [ViewSwitcherBar] in its own `AppBar.bottom`, always with `currentViewId:
  /// null` (this screen IS the implicit Grid tab) -- picking a different tab
  /// bubbles straight up to `HomeShell`, which owns the "which screen class
  /// to show" decision.
  final ValueChanged<ViewDefinition?>? onViewSelected;

  @override
  State<GenericListScreen> createState() => _GenericListScreenState();
}

class _GenericListScreenState extends State<GenericListScreen> {
  static const String _actionsField = '_actions';

  /// Debounce window between the last grid state change (resize, reorder,
  /// sort, filter, hide, freeze) and actually writing it -- coalesces a
  /// column drag's per-frame notifications into one write on release.
  static const Duration _saveDebounce = Duration(milliseconds: 600);

  late GenericDao _dao;
  late Future<_ScreenData> _screenDataFuture;

  TrinaGridStateManager? _stateManager;
  Timer? _saveTimer;

  /// Live-refresh subscription -- see [SyncService.dataChanges]'s own doc
  /// comment for why this exists at all (sync itself already works; this
  /// screen's own reactivity to a change made on *another* device didn't,
  /// found live: a row added elsewhere only ever showed up here after
  /// leaving and returning to this table). Debounced the same short beat
  /// [SyncService.dataChanges] itself recommends -- `onChangesetReceived`
  /// fires before the merge is actually awaited, so reloading instantly
  /// risks reading pre-merge data.
  StreamSubscription<Set<String>>? _dataChangeSubscription;
  Timer? _dataChangeDebounce;

  /// The rows [build] most recently rendered -- read by [_copySelected] to
  /// look the selected row up by `id`, the same "by id, not off the grid's
  /// own cells" reasoning as the actions column's edit/delete handlers (see
  /// [_buildColumns]'s doc comment): a boolean cell holds 1/0 and a null
  /// text cell holds `''`, either of which would feed the new record
  /// subtly wrong starting values if reconstructed from [TrinaCell]s
  /// instead.
  List<Map<String, Object?>> _currentRows = const [];

  /// The same lookup id -> color maps [build] most recently loaded (see
  /// [_loadData]'s doc comment), kept live for [_resolveRowColor] the same
  /// way [_currentRows] is kept for [_copySelected] -- populated fresh in
  /// [build], read whenever a cell repaints.
  Map<String, Map<int, Color>> _lookupColorMaps = const {};

  /// The field currently driving every record's row text color via "Use
  /// Color" (see [_ColumnMenuDelegate]'s doc comment), or `null` for none.
  /// Unlike [_wrapTextColumns]/[_columnAggregates], this doesn't need
  /// `putIfAbsent` seeding in [_buildFieldColumn] -- it's restored wholesale
  /// from [ViewSetting.rowColorColumn] in [_onGridLoaded] (a single scalar,
  /// same as [_groupedColumnField]'s value, not a per-column map that could
  /// go stale one column at a time).
  String? _rowColorColumn;

  /// Live wrap-text state per field column, keyed the same as
  /// [ColumnSetting.columnName] -- read by [_wrapAwareCellRenderer] on every
  /// cell repaint (so toggling it doesn't need TrinaGrid to rebuild the
  /// column/renderer itself, just repaint) and written by
  /// [_toggleWrapText]. Populated fresh from the saved [ColumnSetting]s on
  /// every grid (re)build in [build] -- only fields the plain/readOnly
  /// branches of [_buildFieldColumn] actually render through
  /// [_wrapAwareCellRenderer] get an entry, since that's the only renderer
  /// that reads this map; lookup/boolean/link/color columns keep their own
  /// dedicated renderers and never appear here.
  final Map<String, bool> _wrapTextColumns = {};

  /// Live footer-aggregate choice per numeric field column, keyed the same
  /// as [ColumnSetting.columnName] -- `null` means no footer for that
  /// column. Populated the same `putIfAbsent` way as [_wrapTextColumns] (see
  /// its doc comment) by [_buildFieldColumn]'s two numeric branches, and
  /// only for [FieldType.integer]/[FieldType.real] fields -- everything
  /// else (lookup/boolean/text/date/etc.) never gets an entry, which is
  /// also what gates the column menu's "Set column footer..." item and the
  /// CSV/other exports staying untouched by this feature.
  final Map<String, TrinaAggregateColumnType?> _columnAggregates = {};

  /// Height applied to every row once at least one column has wrap enabled
  /// -- TrinaGrid has no per-column row-height concept, only a single
  /// grid-wide default (`TrinaGridStyleConfig.rowHeight`, set in
  /// [_trinaGridStyle]), so this is one height shared by the whole grid
  /// rather than something computed per cell's actual wrapped line count.
  /// Read live from [ThemeController] (a user setting, not a hardcoded
  /// constant -- see Settings' "Grid row height") each time it's needed
  /// rather than cached, so a change made in Settings takes effect the next
  /// time wrap is toggled without this screen needing its own listener on
  /// the controller.
  ///
  /// Deliberately a grid-wide style default, not TrinaGrid's per-row
  /// `setRowHeight`/`resetRowHeight` (tried first) -- those index into
  /// `stateManager.refRows` directly, which once "Group by this column" is
  /// active holds only the top-level group-summary rows, not the real rows
  /// nested inside each group's `children`. Wrap looked like it silently
  /// stopped working the moment a table was grouped -- the flag and
  /// renderer were still correct, the row just wasn't tall enough since
  /// nothing had actually resized it. A grid-wide default sidesteps that
  /// entirely: every row, grouped or not, falls back to it identically.
  double get _wrappedRowHeight => ThemeController.instance.wrapRowHeight;

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
    _dataChangeSubscription = SyncService.dataChanges.listen(_onDataChanged);
  }

  /// Reloads this screen's data shortly after another device's change
  /// arrives -- but only if it actually touched this table; every other
  /// table's own screen (if open) gets the same notification and filters
  /// it the same way. See [_dataChangeSubscription]'s own doc comment for
  /// why this is debounced rather than reloading the instant this fires.
  void _onDataChanged(Set<String> tables) {
    if (!tables.contains(widget.config.tableName)) return;
    _dataChangeDebounce?.cancel();
    _dataChangeDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _reload();
    });
  }

  /// **Real bug, found live (CLAUDE.md "Essentials v2 Phase 1" -- Step 9
  /// follow-up): this used to check `oldWidget.config.tableName !=
  /// widget.config.tableName`, which can never actually be true.**
  /// `HomeShell` keys this screen with `ValueKey(selected.tableName)`, so a
  /// genuine table switch destroys this whole State and runs [initState]
  /// fresh -- [didUpdateWidget] is only ever called for the *same* table,
  /// meaning the old condition was dead code, and there was no reload path
  /// at all for the case that actually happens: `HomeShell._reloadTables()`
  /// (fired on every return from Settings) builds a brand-new [TableConfig]
  /// for the *same* table whenever its own field list changed underneath it
  /// (Add Field / Manage Fields' soft-delete / restore / reorder). Found by
  /// Mike soft-deleting two fields via Manage Fields and finding them still
  /// in the grid on return -- the screen was still holding the very first
  /// [TableConfig] it was ever built with. Fixed by reloading whenever
  /// [widget.config] is a genuinely different object, not just a
  /// differently-named table -- `_tables` in `HomeShell` is only ever
  /// rebuilt (producing new [TableConfig] instances) by
  /// [HomeShell._loadGroups]/`_reloadTables`, never by the purely-grouping
  /// `_reloadGroups`, so this can't fire on every unrelated rebuild (e.g.
  /// toggling a sidebar group) -- only when the table list itself was
  /// actually refreshed.
  @override
  void didUpdateWidget(covariant GenericListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.config, widget.config)) {
      _dao = GenericDao(widget.config);
      _reload();
    }
  }

  void _reload() {
    // The pending timer (if any) closes over the stateManager that's about
    // to be torn down (GenericListScreen's build() below always remounts a
    // fresh TrinaGrid on reload -- see the doc comment on _ScreenData) --
    // cancel it rather than let it fire against a disposed stateManager. But
    // a change made inside the debounce window (e.g. a wrap toggle right
    // before switching tables) must still be flushed now, or it's silently
    // lost -- _persistGridSettings captures _stateManager/_settingsDao
    // synchronously before its first await, so calling it here (still
    // pointed at the outgoing grid) and letting it finish in the background
    // is safe even though they're reset on the very next lines.
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      unawaited(_persistGridSettings());
    }
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
      lookupColorMaps: data.lookupColorMaps,
      linkRecordOptionMaps: data.linkRecordOptionMaps,
      settingsDao: settingsDao,
      columnSettings: columnSettings,
      viewSetting: viewSetting,
    );
  }

  /// Fetches rows plus, for every lookup [FieldConfig], an id -> display-text
  /// map -- used both to label each option in that field's inline dropdown
  /// (see _buildFieldColumn's `TrinaColumnType.select`) and to turn the
  /// selected id back into text for the cell's own display (`formatter`) --
  /// and an id -> color map, read from the referenced table's own `color`
  /// column if it has one (via [GenericDao.getLookupOptions]'s `SELECT *`),
  /// used only by row coloring (see [_resolveRowColor]) when a lookup field
  /// is the current "Use Color" source. A lookup target with no `color`
  /// column just gets an empty map -- [_resolveRowColor] already treats
  /// "not found" the same as "nothing to color with", no separate check
  /// needed here.
  Future<_ListData> _loadData() async {
    final rows = await _dao.getAll();
    final lookupMaps = <String, Map<int, String>>{};
    final lookupColorMaps = <String, Map<int, Color>>{};
    final linkRecordOptionMaps = <String, Map<int, String>>{};
    for (final field in widget.config.fields) {
      if (field.isLinkRecord) {
        // Essentials v2 Phase 4 -- id -> display-text map for the grid cell
        // renderer's comma-joined display and the picker dialog's option
        // list, same shape as isLookup's own lookupMaps below.
        final linkRecord = field.linkRecord!;
        final options = await _dao.getLinkedRecordOptions(linkRecord);
        linkRecordOptionMaps[field.column] = {
          for (final option in options)
            option['id'] as int: '${option[linkRecord.displayColumn]}',
        };
        continue;
      }
      if (!field.isLookup) continue;
      final lookup = field.lookup!;
      final options = await _dao.getLookupOptions(lookup);
      lookupMaps[field.column] = {
        for (final option in options)
          option[lookup.valueColumn] as int: '${option[lookup.displayColumn]}',
      };
      final colorMap = <int, Color>{};
      for (final option in options) {
        final color = ThemeController.parseHexColor(option['color'] as String?);
        if (color != null) colorMap[option[lookup.valueColumn] as int] = color;
      }
      lookupColorMaps[field.column] = colorMap;
    }
    return _ListData(
      rows: rows,
      lookupMaps: lookupMaps,
      lookupColorMaps: lookupColorMaps,
      linkRecordOptionMaps: linkRecordOptionMaps,
    );
  }

  /// [row] opens the plain/detail form pre-filled for *editing* that row;
  /// [copyFrom] (mutually exclusive -- see [GenericFormScreen]'s assert)
  /// opens the plain form pre-filled for a new one instead. A copy always
  /// goes to the plain form even when [TableConfig.openRowDetail] is set --
  /// copying `orders`, say, makes sense as "a new order with the same
  /// fields," not "a new order that also duplicates its `order_items`,"
  /// which [openRowDetail] has no way to express anyway.
  Future<void> _openForm({Map<String, Object?>? row, Map<String, Object?>? copyFrom}) async {
    final openRowDetail = widget.config.openRowDetail;
    if (row != null && openRowDetail != null) {
      // A parent-child detail view (e.g. orders -> OrderSplitPaneScreen)
      // rather than the plain form -- it manages its own saves internally
      // (embedded forms save in place, no pop), so there's no `changed`
      // pop value to gate the reload on; always reload, cheap either way.
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (context) => openRowDetail(context, widget.config, row)));
      _reload();
      return;
    }
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => GenericFormScreen(
          config: widget.config,
          existing: row,
          copyFrom: copyFrom,
          extraValues: widget.formExtraValues,
        ),
      ),
    );
    if (changed == true) _reload();
  }

  /// "Copy" FAB handler -- the selected row is whichever one the grid's own
  /// current cell sits in (TrinaGrid's native single-click-selects-a-cell
  /// model, see CLAUDE.md), same notion of "selected" as everywhere else in
  /// this grid.
  void _copySelected() {
    final id = _stateManager?.currentRow?.cells['id']?.value as int?;
    if (id == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No record selected.')));
      return;
    }
    final row = _currentRows.firstWhere((r) => r['id'] == id);
    _openForm(copyFrom: row);
  }

  Future<void> _delete(Map<String, Object?> row) async {
    final label = '${row[widget.config.displayColumn] ?? ''}';
    final id = row['id'] as int;

    // Checked *before* any confirm dialog -- a "Delete"/"Cancel" choice
    // implies deletion might succeed, which it structurally can't while a
    // RESTRICT reference exists elsewhere. Found by Mike attempting to
    // delete a supplier still referenced by shipment/orders: the generic
    // confirm dialog invited a click that could only ever fail.
    final blockers = await _dao.findBlockingReferences(id);
    if (!mounted) return;
    if (blockers.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("Can't delete"),
          content: Text(
            'Still referenced by ${blockers.map(titleCase).join(', ')}. '
            'Deleting "$label" isn\'t possible until those references are removed.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
          ],
        ),
      );
      return;
    }

    final customWarning = await widget.config.deleteWarning?.call(row);
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete record?'),
        content: Text(customWarning ?? 'Delete "$label"? This cannot be undone.'),
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
      await _dao.delete(id);
      _reload();
    } on StillInUseException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _saveCellEdit(int id, String column, Object? value) async {
    try {
      await _dao.update(id, {column: value});
      // Always reload, not just when the table has a computed (readOnly)
      // field. Two independent reasons this matters, not just the
      // originally-scoped one:
      // 1. A computed field (e.g. subscription_computed's yearly_cost) can
      //    depend on whatever column just changed -- cost affects
      //    yearly_cost, start_date/renewal_period_id affect next_date, etc.
      //    Re-fetching sidesteps hardcoding that dependency graph in Dart
      //    (a second place schema.sql's formula would need to stay in sync
      //    with). TrinaGrid otherwise keeps showing whatever value a
      //    computed cell held at the last full load.
      // 2. The actions column's edit button (and delete's confirmation
      //    label) read from the `rows` list captured when this screen last
      //    loaded, not from TrinaGrid's own live cell state -- without a
      //    reload here, that list goes stale the instant any cell is
      //    edited, and the form opened from the pencil icon shows the
      //    pre-edit value even after backing out of the cell and back in
      //    (that only touches TrinaGrid's own selection, not this list).
      //    Found via a real repro: editing a lookup cell in the grid, then
      //    immediately opening that row's form, showed the old value.
      _reload();
    } on DatabaseException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  /// "Export to CSV" toolbar action -- exports exactly what the grid is
  /// currently showing, not unconditionally the whole table: the active
  /// filter (via [TrinaGridStateManager.iterateRow], which -- unlike
  /// [TrinaGridStateManager.iterateAllRow] despite the name similarity --
  /// respects it), the active sort (rows are read in their current live
  /// order, sort already applied in place), and "Group by this column"
  /// flattened back into plain rows regardless of which groups are
  /// currently expanded/collapsed (a collapsed group's rows shouldn't
  /// silently disappear from an export). Hidden columns and the actions
  /// column are skipped; visible ones use [TrinaColumn.formattedValueForDisplay]
  /// rather than the cell's raw value, so a lookup column exports its
  /// display text (e.g. "Amazon"), not the underlying FK id -- the same
  /// text the grid itself shows.
  ///
  /// Hand-rolled rather than trina_grid's own built-in CSV exporter
  /// (`TrinaGridExportCsv`) -- that one reads raw cell values directly and
  /// iterates `refRows` (top-level only), so it would export FK ids
  /// instead of lookup display text, and silently drop every row once a
  /// table's grouped (`refRows` holds only the group-summary rows then,
  /// see [_wrappedRowHeight]'s doc comment for the same `refRows` pitfall
  /// found while fixing wrap-vs-grouping).
  Future<void> _exportCsv() async {
    final stateManager = _stateManager;
    if (stateManager == null) return;

    final columns = stateManager.columns
        .where((c) => !c.hide && c.field != _actionsField)
        .toList();

    final buffer = StringBuffer();
    buffer.writeln(columns.map((c) => _csvField(c.title)).join(','));
    for (final row in stateManager.iterateRow) {
      final fields = [
        for (final column in columns)
          _csvField(column.formattedValueForDisplay(row.cells[column.field]?.value)),
      ];
      buffer.writeln(fields.join(','));
    }

    final savedPath = await FilePicker.saveFile(
      dialogTitle: 'Export ${widget.config.displayName} to CSV',
      fileName: '${widget.config.tableName}.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
      bytes: Uint8List.fromList(utf8.encode(buffer.toString())),
    );
    if (savedPath == null) return; // user cancelled
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Exported to $savedPath')));
  }

  /// "Import from CSV" toolbar action -- symmetric with [_exportCsv], but
  /// its own dedicated screen rather than an inline dialog (see
  /// [CsvImportScreen]'s own doc comment for why: a multi-step flow with
  /// real state to carry between steps, same shape as [NewTableScreen]/
  /// [AddFieldScreen]). Pre-selects this screen's own table but leaves it
  /// changeable -- picking the target table is a real step in that screen's
  /// flow, not just a default. Reloads on return only when at least one row
  /// was actually imported, same "changed == true" convention [_openForm]
  /// already uses.
  Future<void> _openCsvImport() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CsvImportScreen(initialTableName: widget.config.tableName),
      ),
    );
    if (changed == true) _reload();
  }

  /// Encloses in double quotes (doubling any embedded quotes first) if the
  /// field contains a comma, quote, or newline -- standard CSV escaping,
  /// same rule trina_grid's own `TrinaGridExportCsv._escapeCsvField` uses.
  String _csvField(String field) {
    if (field.contains(',') || field.contains('\n') || field.contains('"')) {
      return '"${field.replaceAll('"', '""')}"';
    }
    return field;
  }

  Future<void> _restoreDefaults(TableViewSettingsDao settingsDao) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore default view?'),
        content: const Text(
          'Resets column widths, order, visibility, frozen state, footer '
          'aggregates, row coloring, sort, filter, and grouping for this '
          'table on this device. Does not affect theme, font, or color '
          'settings, or any record data.',
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
    // _buildFieldColumn's putIfAbsent (see its doc comment) means a wiped
    // `wrap_text`/`aggregate` column setting alone wouldn't actually clear
    // what's already in these maps from earlier in the session -- has to be
    // cleared explicitly here to genuinely reset, not just leave stale
    // in-memory flags in place under a now-empty saved setting.
    _wrapTextColumns.clear();
    _columnAggregates.clear();
    _reload();
  }

  // ===================== Per-device view state: restore =====================

  /// Applies [viewSetting]'s saved group/sort/filter to a just-loaded grid,
  /// then starts persisting future changes -- in that order, so restoring
  /// the saved state doesn't immediately re-trigger a save of the same
  /// state. Group-by first, before sort/filter: [TrinaRowGroupByColumnDelegate]
  /// sorts/filters *within* groups once one is active, so setting it up
  /// first is what makes the sort/filter calls below group-aware instead of
  /// racing the grouping that hasn't been applied yet.
  void _onGridLoaded(TrinaGridOnLoadedEvent event, ViewSetting? viewSetting) {
    final stateManager = event.stateManager;
    _stateManager = stateManager;

    // No separate "restore tall rows if a previous session left something
    // wrapped" step needed here (there used to be one) -- [_trinaGridStyle]
    // computes the grid-wide row height fresh from [_wrapTextColumns] on
    // every build, and [_wrapTextColumns] is already populated by
    // [_buildFieldColumn] (called for `columns:` earlier in that same
    // build) by the time [_trinaGridStyle] runs for `configuration:`. The
    // right height is there from this table's very first load, nothing to
    // restore after the fact.

    // Footer *renderers* are likewise already set on each numeric column by
    // [_buildFieldColumn]/[_seedAggregate] before this method ever runs --
    // but unlike row height, the footer *row itself* defaults to hidden
    // (`showColumnFooter` starts `false`) and nothing else turns it on, so
    // that one step does need doing here, once, for a freshly (re)mounted
    // grid. [_setColumnAggregate] handles it for any later in-session
    // change.
    if (_columnAggregates.values.any((type) => type != null)) {
      stateManager.setShowColumnFooter(true);
    }

    // A plain scalar overwrite, not putIfAbsent -- see _rowColorColumn's
    // doc comment for why this one doesn't need the same seeding dance as
    // wrapTextColumns/columnAggregates. rowTextStyleCallback and the two
    // renderers that read this directly (see _resolveRowColor) all close
    // over `this`, so setting it here, before the grid's first real paint,
    // is enough -- no stateManager call needed the way showColumnFooter
    // needed one above (nothing about row color has its own on/off flag on
    // TrinaGrid to flip).
    _rowColorColumn = viewSetting?.rowColorColumn;

    final groupColumn = _columnByField(stateManager, viewSetting?.groupColumn);
    if (groupColumn != null) {
      stateManager.setRowGroup(TrinaRowGroupByColumnDelegate(columns: [groupColumn]));
    }

    final sortColumn = _columnByField(stateManager, viewSetting?.sortColumn);
    if (sortColumn != null) {
      if (viewSetting!.sortDirection == 'desc') {
        stateManager.sortDescending(sortColumn);
      } else {
        stateManager.sortAscending(sortColumn);
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

  /// `null` if [field] is `null` or matches no current column (e.g. a saved
  /// group/sort column that's since been renamed or removed from
  /// [TableConfig.fields]) -- used by [_onGridLoaded] for both.
  TrinaColumn? _columnByField(TrinaGridStateManager stateManager, String? field) {
    if (field == null) return null;
    for (final column in stateManager.refColumns) {
      if (column.field == field) return column;
    }
    return null;
  }

  /// Column-menu "Wrap text" handler (see [_ColumnMenuDelegate]) -- flips
  /// this column's entry in [_wrapTextColumns] (read live by
  /// [_wrapAwareCellRenderer] on every repaint) and `setState`s so
  /// [_trinaGridStyle] recomputes the grid-wide row height from the new
  /// flag. That alone is enough to reach the live grid: [TrinaGrid]'s own
  /// `didUpdateWidget` calls `stateManager.setConfiguration` whenever the
  /// `configuration` it's passed changes, which is how the new row height
  /// actually lands -- rebuilding this widget does *not* otherwise disturb
  /// the grid's live state (current sort/group/filter/scroll/selection),
  /// since TrinaGrid only ever consumes the `columns`/`rows` constructor
  /// params once, at its own first build, and ignores them on every
  /// rebuild after that.
  ///
  /// A save still needs scheduling explicitly here -- unlike every other
  /// persisted change in this screen, this one doesn't originate from a
  /// `stateManager` notification (nothing about wrap lives on
  /// `stateManager`), so the `addListener(_scheduleSettingsSave)` wired up
  /// in [_onGridLoaded] never sees it on its own.
  void _toggleWrapText(TrinaColumn column) {
    setState(() {
      _wrapTextColumns[column.field] = !(_wrapTextColumns[column.field] ?? false);
    });
    _scheduleSettingsSave();
  }

  /// Column-menu "Group by this column" handler (see [_ColumnMenuDelegate])
  /// -- one column at a time, not stacked, so selecting a new column
  /// replaces whatever was previously grouped rather than adding to it.
  /// [TrinaGridStateManager.setRowGroup] notifies the grid's own listeners,
  /// which (via [_scheduleSettingsSave], same as every other grid-state
  /// change) is what actually persists this -- no separate save call here.
  void _groupByColumn(TrinaColumn column) {
    _stateManager?.setRowGroup(TrinaRowGroupByColumnDelegate(columns: [column]));
  }

  /// Column-menu "Ungroup" handler -- see [_ColumnMenuDelegate], shown on
  /// every groupable column's menu whenever grouping is active anywhere,
  /// not just the grouped column's own menu. A separate, explicitly-named
  /// item rather than folding this into "Group by this column" as a
  /// checked/uncheck toggle (the first cut of this feature) -- that made
  /// the only way to ungroup "reopen the specific column that's already
  /// grouped and click its now-checked item," easy to lose track of once
  /// something else is grouped instead.
  ///
  /// `setRowGroup(null)` (tried first) crashes -- a genuine trina_grid
  /// bug: its own `_updateRowGroup` asserts `hasRowGroups` (delegate not
  /// null) as its very first line, but `setRowGroup` had just set the
  /// delegate to null one line earlier, so clearing grouping this way
  /// always trips that assert (debug builds only; release strips asserts,
  /// but this app runs debug during development, so it always fires
  /// there). An empty-columns delegate sidesteps it entirely -- non-null,
  /// so `hasRowGroups` holds, and `TrinaRowGroupByColumnDelegate.enabled`
  /// (`visibleColumns.isNotEmpty`) is already designed to read as
  /// "disabled" with nothing to group by, which is exactly the outcome
  /// wanted. [_groupedColumnField]/[_ColumnMenuDelegate._isGroupedBy]
  /// already treat an empty-columns delegate the same as no delegate at
  /// all, so nothing downstream needed to change for this.
  void _ungroup() {
    _stateManager?.setRowGroup(TrinaRowGroupByColumnDelegate(columns: const []));
  }

  /// The single field currently grouped, or `null` if nothing is --
  /// [_ColumnMenuDelegate] uses this to decide which of "Group by this
  /// column"/"Ungroup" to show, and [_persistGridSettings] to save it.
  String? _groupedColumnField(TrinaGridStateManager stateManager) {
    final delegate = stateManager.rowGroupDelegate;
    if (delegate is! TrinaRowGroupByColumnDelegate || delegate.columns.isEmpty) return null;
    return delegate.columns.first.field;
  }

  FieldConfig? _fieldByColumnName(String name) {
    for (final field in widget.config.fields) {
      if (field.column == name) return field;
    }
    return null;
  }

  /// Column-menu "Use Color"/"Stop using color" handler (see
  /// [_ColumnMenuDelegate]) -- like [_setColumnAggregate], this can't work
  /// through a plain `setState` rebuild (TrinaGrid only consumes `columns`/
  /// `rows` once, at its own first build), so [_rowColorColumn] is read
  /// live by [rowTextStyleCallback]'s closure and by [_wrapAwareCellRenderer]
  /// /the color-field renderer, and this just mutates it plus forces a
  /// repaint via [TrinaGridStateManager.notifyListeners] -- same shape as
  /// [_setColumnAggregate], see its doc comment for why that's the right
  /// tool here instead of a rebuild.
  void _setRowColorColumn(String? field) {
    final stateManager = _stateManager;
    if (stateManager == null) return;
    _rowColorColumn = field;
    stateManager.notifyListeners();
  }

  /// The color every cell in [row] should show its text in, or `null` for
  /// no override -- `null` whenever [_rowColorColumn] is unset, the field
  /// it names no longer exists (e.g. removed from [TableConfig.fields]
  /// since the setting was saved), [row] is a group-summary row missing
  /// that cell (see the actions-column renderer's doc comment for the same
  /// group-row-has-no-real-cells situation), or the color itself doesn't
  /// parse/isn't found. Every caller already falls back to the theme's
  /// normal cell text color on `null`, so this never needs a non-null
  /// fallback of its own.
  Color? _resolveRowColor(TrinaRow row) {
    final columnName = _rowColorColumn;
    if (columnName == null) return null;
    final field = _fieldByColumnName(columnName);
    if (field == null) return null;
    if (field.isColor) {
      return ThemeController.parseHexColor(row.cells[columnName]?.value as String?);
    }
    if (field.isLookup) {
      final id = row.cells[columnName]?.value as int?;
      if (id == null) return null;
      return _lookupColorMaps[columnName]?[id];
    }
    return null;
  }

  /// Column-menu "Set column footer..." handler (see [_ColumnMenuDelegate])
  /// -- unlike wrap/group-by, this can't work through `setState` plus a
  /// rebuild: `TrinaGrid` only ever consumes the `columns`/`rows`
  /// constructor params once, at its own first build (see
  /// [_toggleWrapText]'s doc comment), so a fresh `_buildColumns()` call
  /// producing a new `footerRenderer` would just be discarded. Instead this
  /// mutates `footerRenderer` directly on [column] -- the same *live*
  /// object `stateManager` already holds (a plain mutable field, not
  /// `final`, exactly like the `width`/`hide`/`frozen` [_withColumnSetting]
  /// already mutates post-construction) -- then calls
  /// [TrinaGridStateManager.notifyListeners] directly, the documented way
  /// to force a repaint after changing something TrinaGrid itself has no
  /// setter for.
  void _setColumnAggregate(TrinaColumn column, TrinaAggregateColumnType? type) {
    final stateManager = _stateManager;
    if (stateManager == null) return;
    _columnAggregates[column.field] = type;
    column.footerRenderer = _footerRendererFor(type);
    // setShowColumnFooter no-ops (including skipping its own notify) if the
    // flag isn't actually changing -- e.g. switching an already-shown
    // footer from Sum to Average on one column while another column still
    // has one active. The unconditional notifyListeners() below is what
    // actually repaints that case; this call only matters for the
    // show-the-footer-row-for-the-first-time / hide-it-when-nothing's-left
    // transitions.
    stateManager.setShowColumnFooter(_columnAggregates.values.any((t) => t != null));
    stateManager.notifyListeners();
  }

  /// `null` if [name] doesn't match any [TrinaAggregateColumnType] --
  /// used by [_seedAggregate] to parse a saved [ColumnSetting.aggregate]
  /// back into the enum (there's no built-in `tryByName` on a plain enum).
  TrinaAggregateColumnType? _parseAggregate(String? name) {
    for (final type in TrinaAggregateColumnType.values) {
      if (type.name == name) return type;
    }
    return null;
  }

  /// Seeds [_columnAggregates] from [setting] the first time [field] is
  /// built (same `putIfAbsent` reasoning as [_wrapTextColumns] -- see
  /// [_buildFieldColumn]'s doc comment on that map) and returns the
  /// resulting current value, for immediate use building that column's
  /// `footerRenderer`. Only meaningful for [FieldType.integer]/
  /// [FieldType.real] -- returns `null` without touching the map for any
  /// other field type, which is also what keeps aggregates off of
  /// lookup/boolean/text/date columns entirely (see the map's own doc
  /// comment).
  TrinaAggregateColumnType? _seedAggregate(FieldConfig field, ColumnSetting? setting) {
    if (field.type != FieldType.integer && field.type != FieldType.real) return null;
    return _columnAggregates.putIfAbsent(
      field.column,
      () => _parseAggregate(setting?.aggregate),
    );
  }

  /// `null` (no footer) when [type] is `null`, otherwise a
  /// [TrinaAggregateColumnFooter] of that type -- trina_grid's own built-in
  /// footer widget already handles filter/group-aware recomputation, no
  /// need to hand-roll that. `numberFormat` is read from the column
  /// itself (`context.column`, guaranteed a `TrinaColumnTypeWithNumberFormat`
  /// here -- this is only ever wired up for integer/real fields, see
  /// [_seedAggregate]) rather than left at [TrinaAggregateColumnFooter]'s
  /// own default (`#,###`, no decimals) -- otherwise a currency-like `cost`
  /// column showing `#,##0.00` in every cell would show its footer sum
  /// rounded to a whole number instead, a mismatch with what every cell
  /// above it displays. `alignment` is likewise pinned right rather than
  /// left ([TrinaAggregateColumnFooter]'s own default) -- this is only
  /// ever wired up for integer/real fields, and [_numericTextAlign] already
  /// right-aligns every one of those, so a left-aligned sum sitting under a
  /// column of right-aligned numbers would visually misalign for exactly
  /// the columns this exists for.
  TrinaColumnFooterRenderer? _footerRendererFor(TrinaAggregateColumnType? type) {
    if (type == null) return null;
    return (context) => TrinaAggregateColumnFooter(
      rendererContext: context,
      type: type,
      numberFormat: (context.column.type as TrinaColumnTypeWithNumberFormat).numberFormat,
      alignment: AlignmentDirectional.centerEnd,
    );
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

    // `id` and the actions column used to be excluded here (see the removed
    // doc comment on this class -- "structurally fixed, never persisted"),
    // but TrinaGrid's column menu already lets the user drag/freeze/hide
    // them exactly like any other column, so Mike doing that (moving `id`
    // to the end, freezing the actions column to the start) is a real
    // customization, not a mistake -- it deserves the same persistence as
    // every other column, not a silent revert on next visit.
    final columnSettings = [
      for (final (index, column) in stateManager.columns.indexed)
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
          // Not a TrinaColumn property (TrinaGrid has no native wrap-text
          // concept) -- sourced from the separately-tracked _wrapTextColumns
          // map instead of the column itself, unlike width/hide/frozen above.
          wrapText: _wrapTextColumns[column.field] ?? false,
          // column.footerRenderer itself isn't inspectable for *which*
          // TrinaAggregateColumnType it renders (it's just a closure by the
          // time it's on the column) -- _columnAggregates is the one source
          // of truth for that, same reasoning as wrapText above.
          aggregate: _columnAggregates[column.field]?.name,
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
      groupColumn: _groupedColumnField(stateManager),
      rowColorColumn: _rowColorColumn,
    );

    final snapshot = jsonEncode({
      'columns': [
        for (final c in columnSettings)
          [c.columnName, c.width, c.displayOrder, c.visible, c.frozen, c.wrapText, c.aggregate],
      ],
      'sortColumn': viewSetting.sortColumn,
      'sortDirection': viewSetting.sortDirection,
      'filterJson': viewSetting.filterJson,
      'groupColumn': viewSetting.groupColumn,
      'rowColorColumn': viewSetting.rowColorColumn,
    });
    if (snapshot == _lastPersistedSnapshot) return;
    _lastPersistedSnapshot = snapshot;

    await settingsDao.saveColumnSettings(columnSettings);
    await settingsDao.saveViewSettings(viewSetting);
  }

  // ===================== Column building =====================

  /// Every column identifier -- `id`, each [TableConfig.fields] column, and
  /// the trailing actions column -- in render order. Defaults to `id`
  /// first and actions last (their original hardcoded spots), but a saved
  /// `display_order` for either overrides that default exactly like it
  /// does for any other column, since from TrinaGrid's own perspective
  /// they're plain columns like any other (see the class doc comment).
  List<String> _orderedColumnIds(Map<String, ColumnSetting> columnSettings) {
    final ids = ['id', for (final field in widget.config.fields) field.column, _actionsField];
    final defaultOrder = {for (final (i, id) in ids.indexed) id: i};
    final order = {
      for (final id in ids) id: columnSettings[id]?.displayOrder ?? defaultOrder[id]!,
    };
    return List<String>.from(ids)..sort((a, b) => order[a]!.compareTo(order[b]!));
  }

  List<TrinaColumn> _buildColumns(
    List<Map<String, Object?>> rows,
    Map<String, Map<int, String>> lookupMaps,
    Map<String, Map<int, String>> linkRecordOptionMaps,
    Map<String, ColumnSetting> columnSettings,
  ) {
    final idColumn = _withColumnSetting(
      TrinaColumn(
        title: 'ID',
        field: 'id',
        // No grouping -- the new timestamp+random id scheme (see
        // CLAUDE.md "id convention changed") produces ~16-digit values,
        // and TrinaColumnType.number()'s default format ('#,###') would
        // otherwise comma-group those into something unreadable.
        type: TrinaColumnType.number(format: '0'),
        readOnly: true,
        frozen: TrinaColumnFrozen.start,
        width: 80,
      ),
      columnSettings['id'],
    );

    final actionsColumn = _withColumnSetting(
      TrinaColumn(
        title: '',
        field: _actionsField,
        type: TrinaColumnType.text(),
        readOnly: true,
        frozen: TrinaColumnFrozen.end,
        width: 120,
        renderer: (rendererContext) {
          // A group summary row (see "Group by this column") has no `id`
          // cell of its own -- TrinaGrid still calls every column's
          // renderer for it same as a real row, so this must bail before
          // the id-based lookup below, not after. Nothing to edit/delete on
          // a summary row anyway.
          if (rendererContext.row.type.isGroup) return const SizedBox.shrink();
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
                // A form/document icon, not a pencil -- the form view isn't
                // just "edit this row" anymore (Essentials v2 Phase 4's
                // reverse-relation panel means opening it can also be about
                // *seeing* a record's linked/parent-child data, not only
                // changing it), so a document-shaped icon reads more
                // accurately than an edit pencil. Per Mike's request.
                icon: const Icon(Icons.article_outlined, size: 18),
                tooltip: 'Open form',
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
      columnSettings[_actionsField],
    );

    final columnsById = <String, TrinaColumn>{
      'id': idColumn,
      for (final field in widget.config.fields)
        field.column: _buildFieldColumn(
          field,
          lookupMaps,
          linkRecordOptionMaps,
          columnSettings[field.column],
        ),
      _actionsField: actionsColumn,
    };

    return [for (final id in _orderedColumnIds(columnSettings)) columnsById[id]!];
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

  /// Right for a plain numeric [FieldConfig] (integer/real), left-aligned
  /// [TrinaColumnTextAlign.start] (TrinaColumn's own default) for
  /// everything else -- deliberately narrower than "every column backed by
  /// a number," per Mike: excludes lookup fields (a `TrinaColumnType.select`
  /// of ids, built in a separate branch of [_buildFieldColumn] that never
  /// calls this -- their cell value is a raw FK id, not a number meant to
  /// be read as one) and the `id` column (built directly
  /// in [_buildColumns], never through [_buildFieldColumn] at all, so
  /// there's nothing to exclude here -- it just never reaches this).
  TrinaColumnTextAlign _numericTextAlign(FieldType type) =>
      type == FieldType.integer || type == FieldType.real
      ? TrinaColumnTextAlign.right
      : TrinaColumnTextAlign.start;

  /// Essentials v2 Phase 2's `real` `options.decimals` (default 2, per
  /// claude/essentials-v2-phase2-design.md's `real` entry) -- a
  /// display-only hint for the grid's own number format string, not a new
  /// format and not a [FieldFormatHandler] (unlike `currency`/`percentage`
  /// below, `real` keeps its existing [FieldType.real] code path
  /// untouched otherwise). Read leniently -- `jsonDecode` always hands
  /// back a Dart `int` for a JSON integer literal, but this tolerates a
  /// stringified one too rather than silently falling back to the default.
  int _decimalsFor(FieldConfig field) {
    final raw = field.options['decimals'];
    if (raw is int) return raw;
    return int.tryParse(raw?.toString() ?? '') ?? 2;
  }

  /// `decimals <= 0` collapses to a whole-number format (no trailing
  /// `.` with zero digits after it) -- same shape `_decimalNumberFormat`'s
  /// callers already expect from the hardcoded `'#,##0.00;-#,##0.00'`
  /// this replaces, just parameterized on [decimals] instead of always 2.
  String _decimalNumberFormat(int decimals) => decimals <= 0
      ? '#,##0;-#,##0'
      : '#,##0.${'0' * decimals};-#,##0.${'0' * decimals}';

  /// Essentials v2 Phase 2 -- see claude/essentials-v2-phase2-design.md's
  /// "Key decision". `null` for every Phase 1 format, always (nothing is
  /// registered for them), in which case every call site below falls
  /// through to the existing [FieldType]-based branches completely
  /// unchanged -- no regression risk for the six formats already verified
  /// on real hardware.
  FieldFormatHandler? _formatHandlerFor(FieldConfig field) =>
      FieldFormatRegistry.instance.handlerFor(field.format);

  TrinaColumn _buildFieldColumn(
    FieldConfig field,
    Map<String, Map<int, String>> lookupMaps,
    Map<String, Map<int, String>> linkRecordOptionMaps,
    ColumnSetting? setting,
  ) {
    final handler = _formatHandlerFor(field);
    if (handler != null) {
      return _withColumnSetting(handler.buildGridColumn(field), setting);
    }

    if (field.readOnly) {
      // Computed, query-time-only value (e.g. subscription_computed's
      // yearly_cost/next_date) -- nothing to write back, so no inline
      // editor at all, same reasoning as `id`. Date/dateTime fields skip
      // _wrapAwareCellRenderer (and so never get a _wrapTextColumns entry,
      // same as lookup/boolean/link/color below) -- a single formatted date
      // never wraps, and TrinaColumnType.date/dateTime already formats it
      // via `column.formatter`-equivalent display logic without a renderer.
      if (field.type == FieldType.date || field.type == FieldType.dateTime) {
        return _withColumnSetting(
          TrinaColumn(
            title: field.label,
            field: field.column,
            type: field.type == FieldType.dateTime
                ? TrinaColumnType.dateTime(format: 'yyyy-MM-dd HH:mm:ss')
                : TrinaColumnType.date(format: 'yyyy-MM-dd'),
            readOnly: true,
            width: field.type == FieldType.dateTime ? 170 : 120,
          ),
          setting,
        );
      }
      // putIfAbsent, not a blind overwrite -- _buildColumns runs on every
      // rebuild (including the setState _toggleWrapText now triggers, see
      // its doc comment), but `setting` only reflects the last *persisted*
      // value. Overwriting unconditionally would stomp an in-session
      // toggle back to its old value on the very next rebuild, before the
      // debounced save even had a chance to land. _restoreDefaults clears
      // this map explicitly first, which is what lets a real reset back to
      // "nothing saved" still take effect through the same putIfAbsent.
      _wrapTextColumns.putIfAbsent(field.column, () => setting?.wrapText ?? false);
      return _withColumnSetting(
        TrinaColumn(
          title: field.label,
          field: field.column,
          type: switch (field.type) {
            FieldType.real => TrinaColumnType.number(format: _decimalNumberFormat(_decimalsFor(field))),
            FieldType.integer => TrinaColumnType.number(),
            _ => TrinaColumnType.text(),
          },
          readOnly: true,
          width: field.type == FieldType.text ? 220 : 110,
          renderer: _wrapAwareCellRenderer,
          footerRenderer: _footerRendererFor(_seedAggregate(field, setting)),
          textAlign: _numericTextAlign(field.type),
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
            // Same group-row bailout as the actions column above -- a
            // synthetic summary row has nothing real to toggle, and its
            // cell value is null unless this happens to be the grouped
            // column itself.
            if (rendererContext.row.type.isGroup) return const SizedBox.shrink();
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

    if (field.isLinkRecord) {
      // Essentials v2 Phase 4 -- a general one-or-many relationship, stored
      // as a JSON array of target ids (see lib/util/link_record.dart),
      // structurally unlike isLookup's single scalar FK id below. `readOnly`
      // here is deliberate: TrinaGrid's own double-click text editor makes
      // no sense against a raw JSON array, so the *only* way in is the
      // dedicated tap target below opening a picker dialog -- same
      // "readOnly column, dedicated tap target is the real editor" shape
      // the boolean checkbox column above already uses (force: true on the
      // resulting changeCellValue call, for the same reason).
      final linkRecord = field.linkRecord!;
      final options = linkRecordOptionMaps[field.column] ?? const <int, String>{};
      return _withColumnSetting(
        TrinaColumn(
          title: field.label,
          field: field.column,
          type: TrinaColumnType.text(),
          readOnly: true,
          width: 220,
          renderer: (rendererContext) {
            if (rendererContext.row.type.isGroup) return const SizedBox.shrink();
            final ids = parseLinkedIds(rendererContext.cell.value);
            final text = ids.map((id) => options[id] ?? '#$id').join(', ');
            return Row(
              children: [
                Expanded(
                  child: Text(
                    text,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _resolveRowColor(rendererContext.row)),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.link, size: 16),
                  tooltip: linkRecord.multiple ? 'Edit links' : 'Edit link',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _editLinkRecordCell(rendererContext, field),
                ),
              ],
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

    if (field.isInlineSelect) {
      // Same select-column shape as isLookup above, but keyed on the
      // option's own String key instead of an int FK id -- no lookupMaps
      // query needed, field.inlineOptions is already the complete answer
      // (Essentials v2 Phase 2 build order step 4, see
      // claude/essentials-v2-phase2-design.md's "Inline select" entry).
      final options = {for (final o in field.inlineOptions!) o.key: o.label};
      // A stored value that doesn't match any configured option (a deleted
      // option, a stray CSV-imported value) shows as its own literal text
      // rather than going blank -- same "never hide the record" posture as
      // KanbanViewScreen's own ad-hoc column for the identical case, and
      // the same fix `GenericFormScreen`'s inline-select dropdown needed
      // after crashing outright on an unmatched value (found live,
      // real-device verification -- see that fix's own doc comment).
      String displayFor(String? key) => key == null ? '' : (options[key] ?? key);
      final items = <String?>[if (!field.required) null, ...options.keys];
      return _withColumnSetting(
        TrinaColumn(
          title: field.label,
          field: field.column,
          type: TrinaColumnType.select<String?>(items, itemToString: displayFor),
          formatter: (value) => displayFor(value as String?),
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
            // Same group-row bailout as the actions column above -- no
            // color to pick or preview on a synthetic summary row.
            if (rendererContext.row.type.isGroup) return const SizedBox.shrink();
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
                Expanded(
                  child: Text(
                    value ?? '',
                    overflow: TextOverflow.ellipsis,
                    // Same reasoning as _wrapAwareCellRenderer's doc comment
                    // -- this renderer builds its own Text, bypassing
                    // TrinaGrid's rowTextStyleCallback entirely, so row
                    // coloring has to be applied here explicitly too.
                    style: TextStyle(color: _resolveRowColor(rendererContext.row)),
                  ),
                ),
              ],
            );
          },
        ),
        setting,
      );
    }

    if (field.type == FieldType.date || field.type == FieldType.dateTime) {
      // TrinaColumnType.date/dateTime's own popup (calendar, or calendar +
      // time) opens on TrinaGrid's normal double-click-to-edit gesture --
      // no custom renderer/interaction wiring needed, same as the select
      // dropdown lookup columns above. No _wrapTextColumns entry either,
      // same reasoning as the readOnly date branch above -- a single
      // formatted date never wraps.
      return _withColumnSetting(
        TrinaColumn(
          title: field.label,
          field: field.column,
          type: field.type == FieldType.dateTime
              ? TrinaColumnType.dateTime(format: 'yyyy-MM-dd HH:mm:ss')
              : TrinaColumnType.date(format: 'yyyy-MM-dd'),
          width: field.type == FieldType.dateTime ? 170 : 120,
        ),
        setting,
      );
    }

    // putIfAbsent -- see the readOnly branch above for why a blind
    // overwrite would stomp an in-session toggle.
    _wrapTextColumns.putIfAbsent(field.column, () => setting?.wrapText ?? false);
    return _withColumnSetting(
      TrinaColumn(
        title: field.label,
        field: field.column,
        type: switch (field.type) {
          FieldType.integer => TrinaColumnType.number(),
          FieldType.real => TrinaColumnType.number(format: _decimalNumberFormat(_decimalsFor(field))),
          _ => TrinaColumnType.text(),
        },
        width: field.type == FieldType.text ? 220 : 110,
        renderer: _wrapAwareCellRenderer,
        footerRenderer: _footerRendererFor(_seedAggregate(field, setting)),
        textAlign: _numericTextAlign(field.type),
        editCellRenderer: field.isAutocompleteText
            ? (defaultEditCellWidget, cell, controller, focusNode, handleSelected) =>
                  _buildGridAutocompleteEditor(defaultEditCellWidget, cell, controller, focusNode, field)
            : null,
      ),
      setting,
    );
  }

  /// Essentials v2 Phase 4's grid-side `link_record` editor -- a dialog
  /// listing every target-table row (checkbox per row when
  /// [LinkRecordConfig.multiple], tap-to-select-and-close otherwise), per
  /// claude/essentials-v2-phase4-design.md's "Grid rendering" section.
  ///
  /// Implemented as a dedicated tap-target-opens-dialog (the same shape
  /// this screen already uses for [FieldConfig.isColor]'s swatch and
  /// [FieldConfig.isLookup]'s dropdown, just via a modal picker instead of
  /// an inline one) rather than routing the picker through
  /// [TrinaColumn.editCellRenderer] -- a JSON-array cell value has no
  /// sensible plain-text inline edit to fall back to the way autocomplete's
  /// text field does, so there's no reason to fight that hook for a
  /// checkbox-list UI it was never built to host; a dialog achieves the
  /// identical end-user picker behavior the design doc describes.
  Future<void> _editLinkRecordCell(
    TrinaColumnRendererContext rendererContext,
    FieldConfig field,
  ) async {
    final linkRecord = field.linkRecord!;
    final currentIds = parseLinkedIds(rendererContext.cell.value).toSet();
    final options = await _dao.getLinkedRecordOptions(linkRecord);
    if (!mounted) return;
    final result = await showDialog<List<int>>(
      context: context,
      builder: (context) => _LinkRecordPickerDialog(
        title: field.label,
        options: options,
        displayColumn: linkRecord.displayColumn,
        multiple: linkRecord.multiple,
        initialSelectedIds: currentIds,
      ),
    );
    if (result == null) return;
    rendererContext.stateManager.changeCellValue(
      rendererContext.cell,
      encodeLinkedIds(result),
      force: true,
    );
  }

  /// See claude/essentials-v2-column-autocomplete-design.md. Wraps
  /// TrinaGrid's own default text cell editor via [TrinaColumn
  /// .editCellRenderer] -- confirmed against the installed `trina_grid`
  /// 2.2.2 that this hook exists (`text_cell.dart`'s `TextCellState.build`
  /// checks `column.editCellRenderer` before falling back to the plain
  /// `TextField`), so this is the "yes" branch of the design doc's step 1,
  /// not the manual-`OverlayEntry` fallback.
  ///
  /// **A real, confirmed limitation, not an oversight:** unlike the form
  /// side's [Autocomplete] (see [GenericFormScreen._buildAutocompleteField]),
  /// arrow-key/Enter keyboard navigation of the suggestion list does not
  /// work here. [defaultEditCellWidget] is built by TrinaGrid's own
  /// `TextCellState`, whose `FocusNode` already has its own `onKeyEvent`
  /// handler (`_handleOnKey`, set once at that state's `initState`,
  /// before this renderer ever runs) that unconditionally claims and
  /// consumes vertical-arrow/Enter/Escape/Tab key events for its own
  /// cell-navigation purposes. Since that `FocusNode` is the one actually
  /// holding focus (the innermost node in Flutter's key-dispatch order),
  /// [Autocomplete]'s own `Shortcuts` wrapper -- an ancestor in the tree
  /// once wrapped here -- never gets a chance to see those keys, no matter
  /// how it's wired. Confirmed by reading `trina_grid`'s source, not
  /// guessed. Mouse/touch selection (tapping a suggestion) is unaffected
  /// and is the primary way this is expected to be used in the grid;
  /// typing a value and pressing Enter/Tab/Escape still behaves exactly as
  /// it always has (TrinaGrid's own commit/cancel), just without a
  /// suggestion getting keyboard-highlighted first.
  Widget _buildGridAutocompleteEditor(
    Widget defaultEditCellWidget,
    TrinaCell cell,
    TextEditingController controller,
    FocusNode focusNode,
    FieldConfig field,
  ) {
    final source = ColumnAutocompleteSource(
      dao: _dao,
      field: field,
      excludeValue: () => controller.text,
    );
    return Autocomplete<String>(
      optionsBuilder: source.call,
      // [focusNode] is the exact same FocusNode already bound inside
      // [defaultEditCellWidget] itself (TrinaGrid's `text_cell.dart` hands
      // it to us as this callback's 4th parameter precisely so a custom
      // renderer can wire it up) -- not a second, competing node.
      // **Required, not optional, to pair with [textEditingController]
      // below** -- [Autocomplete]'s own doc comment says so explicitly
      // ("If this parameter is not null, then focusNode must also be
      // non-null"), enforced by an assert in [RawAutocomplete]'s
      // constructor. Missing this was a real bug: the assert only fires
      // in debug builds (stripped from the release exe this was first
      // tested against), so it silently fell back to Autocomplete's own
      // disconnected internal FocusNode -- one that never received real
      // focus events from the actual on-screen field (`fieldViewBuilder`
      // below returns [defaultEditCellWidget] verbatim, which uses the
      // real [focusNode], not Autocomplete's fallback) -- so the options
      // overlay's focus-driven show/hide logic never engaged. Found live:
      // suggestions worked correctly on the form (which passes its own
      // FocusNode correctly, see GenericFormScreen._buildAutocompleteField)
      // but never appeared in the grid.
      focusNode: focusNode,
      textEditingController: controller,
      fieldViewBuilder: (context, _, _, _) => defaultEditCellWidget,
      onSelected: (value) {
        // Writes through the grid's own change pipeline (same path a
        // normal typed edit takes -- see _onGridChanged) rather than only
        // updating the visible text, so selecting a suggestion commits
        // immediately instead of waiting for the cell to lose focus.
        _stateManager?.changeCellValue(cell, value);
        controller.text = value;
        controller.selection = TextSelection.collapsed(offset: value.length);
      },
    );
  }

  /// Replaces TrinaGrid's own default single-line-ellipsis cell text for
  /// plain/readOnly columns -- reads [_wrapTextColumns] live on every
  /// repaint (rather than baking a fixed renderer in at column-build time)
  /// so [_toggleWrapText] can flip behavior without rebuilding the column.
  /// `ClipRect` matters once wrapped: an unbounded `maxLines` inside a fixed-
  /// height row would otherwise paint past the row's bounds and bleed into
  /// the row above/below instead of just being cut off at [_wrappedRowHeight].
  ///
  /// Also reads [_resolveRowColor] live, same reasoning -- this renderer
  /// bypasses TrinaGrid's own text-style resolution entirely (it builds its
  /// own `Text` instead of going through the default cell widget), so it's
  /// one of the two places (the other being the color-field renderer) that
  /// has to apply row coloring itself rather than getting it for free via
  /// `rowTextStyleCallback`.
  Widget _wrapAwareCellRenderer(TrinaColumnRendererContext rendererContext) {
    final wrapped = _wrapTextColumns[rendererContext.column.field] ?? false;
    final rowColor = _resolveRowColor(rendererContext.row);
    final baseStyle = rendererContext.stateManager.style.cellTextStyle;
    final text = Text(
      rendererContext.column.formattedValueForDisplay(rendererContext.cell.value),
      style: rowColor == null ? baseStyle : baseStyle.copyWith(color: rowColor),
      textAlign: rendererContext.column.textAlign.value,
      overflow: wrapped ? TextOverflow.clip : TextOverflow.ellipsis,
      softWrap: wrapped,
      maxLines: wrapped ? null : 1,
    );
    return wrapped ? ClipRect(child: text) : text;
  }

  Object? _cellValueFor(FieldConfig field, Object? raw) {
    // Parsed to a real int (or null) -- the select column's `items` are
    // ids, and its `formatter` (see _buildFieldColumn) turns that back into
    // display text for the cell. Real bug, found live: `raw` here is a v2
    // linked field's own physically-TEXT column value (see
    // parseLookupValue's doc comment), a String, not the int
    // `TrinaColumnType.select<int?>` requires -- previously left as-is
    // ("the raw FK id"), which held for v1's real INTEGER FK columns but
    // silently mismatched v2's, rendering a blank cell instead of the
    // linked row's display text. Converting it to a *string* instead the
    // way the plain-text branch below does would be equally wrong -- it
    // would desync the cell's value from `TrinaColumnType.select<int?>`'s
    // item type and break both the dropdown's current-selection highlight
    // and its edit validation; parsing to the same int the column type
    // actually expects is the correct fix, not a same-shape workaround.
    final handler = _formatHandlerFor(field);
    if (handler != null) return handler.cellValueFor(field, raw);
    if (field.isLinkRecord) {
      // The raw stored TEXT is already the JSON array string this column's
      // renderer/picker expect -- see the isLinkRecord branch of
      // _buildFieldColumn. Never null in practice (SchemaEditorService's
      // physical column has no default, but every write path always writes
      // a real encodeLinkedIds() string, including '[]' for "nothing
      // linked") -- the fallback is defensive only.
      return raw?.toString() ?? '[]';
    }
    if (field.isLookup) return parseLookupValue(raw);
    if (field.isInlineSelect) {
      // The stored key IS the item type TrinaColumnType.select<String?>
      // expects, unlike isLookup's int-id parsing above -- just needs
      // blank -> null, same "no selection" convention as everywhere else.
      final key = raw as String?;
      return (key == null || key.isEmpty) ? null : key;
    }
    if (field.type == FieldType.boolean) {
      return coerceBoolValue(raw) ? 1 : 0;
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
    final handler = _formatHandlerFor(field);
    if (handler != null) {
      value = handler.valueForSave(field, value);
    } else if (field.isLinkRecord) {
      // Already a real encodeLinkedIds() JSON array string, written
      // directly by _editLinkRecordCell's picker dialog -- nothing to
      // normalize. The column is readOnly to TrinaGrid's own text editor
      // (see _buildFieldColumn), so this is the only way this branch fires.
    } else if (field.isLookup) {
      // Already the selected option's raw id (or null) -- the select
      // column's items are ids themselves (see _buildFieldColumn), unlike
      // the plain-text branch below, which needs its own trim/empty->null
      // handling because TrinaGrid's text editor hands back a raw String.
    } else if (field.isInlineSelect) {
      // Same reasoning as isLookup above -- already the selected key (or
      // null), no trim/empty->null handling needed.
    } else if (field.type == FieldType.text) {
      final text = (value as String? ?? '').trim();
      value = text.isEmpty ? null : text;
    } else if (field.type == FieldType.date || field.type == FieldType.dateTime) {
      // TrinaGrid's date/dateTime column hands back a raw DateTime when
      // picked via its popup calendar, but a plain String when typed
      // directly into the same cell's text-entry fallback -- schema.sql
      // stores these as plain ISO8601 TEXT either way, so both paths need
      // normalizing to that exact string shape before the write.
      if (value is DateTime) {
        value = field.type == FieldType.dateTime ? isoDateTime(value) : isoDate(value);
      } else {
        final text = (value as String? ?? '').trim();
        value = text.isEmpty ? null : text;
      }
    }
    _saveCellEdit(id, event.column.field, value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.config.displayName),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: 'Import from CSV',
            onPressed: _openCsvImport,
          ),
          FutureBuilder<_ScreenData>(
            future: _screenDataFuture,
            builder: (context, snapshot) {
              // Same "enabled once data's loaded" gate as Restore Defaults
              // below -- _exportCsv still separately guards on _stateManager
              // itself being set, for the brief window between this
              // FutureBuilder resolving and TrinaGrid's onLoaded firing.
              return IconButton(
                icon: const Icon(Icons.file_download_outlined),
                tooltip: 'Export to CSV',
                onPressed: snapshot.data == null ? null : _exportCsv,
              );
            },
          ),
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
        bottom: widget.onViewSelected == null || widget.config.filterWhere != null
            ? null
            : ViewSwitcherBar(
                tableName: widget.config.tableName,
                currentViewId: null,
                onViewSelected: widget.onViewSelected!,
              ),
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
          _currentRows = rows;
          _lookupColorMaps = data.lookupColorMaps;
          return TrinaGrid(
            columns: _buildColumns(rows, lookupMaps, data.linkRecordOptionMaps, data.columnSettings),
            rows: _buildRows(rows),
            configuration: TrinaGridConfiguration(
              columnSize: const TrinaGridColumnSizeConfig(
                autoSizeMode: TrinaAutoSizeMode.none,
                resizeMode: TrinaResizeMode.normal,
              ),
              // Default thickness (8.0) read as too thin to grab comfortably
              // -- 1.5x, per Mike.
              scrollbar: const TrinaGridScrollbarConfig(thickness: 12.0),
              style: _trinaGridStyle(context),
            ),
            onChanged: _onGridChanged,
            onLoaded: (event) => _onGridLoaded(event, data.viewSetting),
            // Row coloring, for everything that goes through TrinaGrid's own
            // default cell rendering (lookup/date/id columns -- none of them
            // have a custom `renderer:`) -- see [_resolveRowColor]'s doc
            // comment. The columns that *do* have a custom renderer
            // (_wrapAwareCellRenderer, the color-field renderer) don't route
            // through this at all and consult [_resolveRowColor] directly
            // instead; the link renderer deliberately never does either, per
            // Mike's "except hyperlinks."
            rowTextStyleCallback: (rowColorContext) {
              final color = _resolveRowColor(rowColorContext.row);
              return color == null ? null : TextStyle(color: color);
            },
            columnMenuDelegate: _ColumnMenuDelegate(
              wrapTextColumns: _wrapTextColumns,
              onToggleWrapText: _toggleWrapText,
              // `id`/actions are excluded automatically -- neither is a
              // TableConfig.fields entry, and grouping either wouldn't mean
              // anything (every id is distinct; actions has no data cells).
              groupableColumns: {for (final field in widget.config.fields) field.column},
              onGroupByColumn: _groupByColumn,
              onUngroup: _ungroup,
              lookupOptions: lookupMaps,
              // Sum/average/min/max only mean something on a number field --
              // count would work on any column, but isn't offered outside
              // this set either, to keep "which columns get this item" one
              // simple rule instead of a per-aggregate-type exception.
              aggregatableColumns: {
                for (final field in widget.config.fields)
                  if (field.type == FieldType.integer || field.type == FieldType.real)
                    field.column,
              },
              columnAggregates: _columnAggregates,
              onSetColumnAggregate: _setColumnAggregate,
              // The color field itself (if this table has one) plus every
              // lookup field -- see the "Row coloring" discussion: Mike
              // confirmed every lookup target already has its own `color`
              // column, so no extra gating needed beyond `isLookup`.
              colorableColumns: {
                for (final field in widget.config.fields)
                  if (field.isColor || field.isLookup) field.column,
              },
              getRowColorColumn: () => _rowColorColumn,
              onUseColor: (column) => _setRowColorColumn(column.field),
              onStopUsingColor: () => _setRowColorColumn(null),
            ),
          );
        },
      ),
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton(
            heroTag: 'copyFab',
            onPressed: _copySelected,
            tooltip: 'Copy',
            child: const Icon(Icons.copy),
          ),
          const SizedBox(width: 12),
          FloatingActionButton(
            heroTag: 'addFab',
            onPressed: () => _openForm(),
            tooltip: 'Add',
            child: const Icon(Icons.add),
          ),
        ],
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
      // Grid-wide, not per-row -- see [_wrappedRowHeight]'s doc comment for
      // why a row-height toggle needs to be a single style default rather
      // than TrinaGrid's per-row `setRowHeight` API. Settings-driven either
      // way (see [_wrappedRowHeight]/[ThemeController.rowHeight]), not a
      // hardcoded TrinaGrid default.
      rowHeight: _wrapTextColumns.values.any((wrapped) => wrapped)
          ? _wrappedRowHeight
          : ThemeController.instance.rowHeight,
    );
  }

  @override
  void dispose() {
    // Same reasoning as _reload(): flush a still-pending save rather than
    // dropping it, so leaving the screen mid-debounce doesn't revert the
    // change on next visit.
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      unawaited(_persistGridSettings());
    }
    _dataChangeSubscription?.cancel();
    _dataChangeDebounce?.cancel();
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
  const _ListData({
    required this.rows,
    required this.lookupMaps,
    required this.lookupColorMaps,
    required this.linkRecordOptionMaps,
  });

  final List<Map<String, Object?>> rows;
  final Map<String, Map<int, String>> lookupMaps;
  final Map<String, Map<int, Color>> lookupColorMaps;

  /// Essentials v2 Phase 4 -- id -> display-text map per `link_record`
  /// field, same shape/purpose as [lookupMaps] but keyed off
  /// [FieldConfig.linkRecord] instead of [FieldConfig.lookup].
  final Map<String, Map<int, String>> linkRecordOptionMaps;
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
    required this.lookupColorMaps,
    required this.linkRecordOptionMaps,
    required this.settingsDao,
    required this.columnSettings,
    required this.viewSetting,
  });

  final List<Map<String, Object?>> rows;
  final Map<String, Map<int, String>> lookupMaps;
  final Map<String, Map<int, Color>> lookupColorMaps;
  final Map<String, Map<int, String>> linkRecordOptionMaps;
  final TableViewSettingsDao settingsDao;
  final Map<String, ColumnSetting> columnSettings;
  final ViewSetting? viewSetting;
}

/// Wraps TrinaGrid's own column header menu (freeze/hide/autofit/filter --
/// [TrinaColumnMenuDelegateDefault]) to add two more entries, "Wrap text"
/// and "Group by this column", rather than replacing the menu wholesale.
///
/// "Wrap text" only shows for a column with an entry in [wrapTextColumns]
/// -- populated exclusively by the plain/readOnly branches of
/// [_GenericListScreenState._buildFieldColumn] that render through
/// [_GenericListScreenState._wrapAwareCellRenderer], so lookup/boolean/
/// link/color columns (each with their own dedicated renderer that doesn't
/// consult wrap state) never get the item at all.
///
/// "Group by this column"/"Ungroup" show for any column in
/// [groupableColumns] -- every [TableConfig.fields] column, excluding
/// `id`/actions (neither is a real field, and grouping either wouldn't
/// mean anything: every `id` is distinct, actions has no data cells).
/// "Group by this column" is hidden on the column that's already grouped
/// (selecting it there would be a same-column no-op); "Ungroup" shows on
/// *every* groupable column's menu whenever anything is grouped, not just
/// the grouped column's own -- so ungrouping is always reachable from
/// wherever the user happens to right-click, not just from the one column
/// that's easy to lose track of once something else is grouped instead.
/// Reads [TrinaGridStateManager.rowGroupDelegate] directly for this rather
/// than needing its own callback in from [_GenericListScreenState] --
/// grouping is TrinaGrid's own state, already available on the
/// `stateManager` this method receives.
///
/// "Filter by value" shows for any column in [lookupOptions] -- every
/// lookup field, keyed the same as [_GenericListScreenState._ListData
/// .lookupMaps]. Exists because TrinaGrid's own "Set filter" (stock
/// [TrinaColumnMenuDelegateDefault] item, untouched, still available
/// alongside this) opens a popup whose value field is hardcoded plain text
/// for every column regardless of type (`FilterHelper.filterPopup`'s
/// "Value" column is a bare `TrinaColumnType.text()` -- confirmed by
/// reading trina_grid's source, no per-column override point exists) --
/// so filtering a lookup column that way means typing the underlying FK
/// id, not the display text the grid actually shows. This picks from the
/// same display options the grid renders (no extra query --[lookupOptions]
/// is the exact map already loaded for cell display) and translates the
/// choice to an exact-match id filter under the hood, entirely bypassing
/// the stock popup for this one case. Deliberately exact-match only, not a
/// full contains/starts-with/etc. picker like the stock popup offers for
/// text columns -- a lookup field is a finite set of real values, "is
/// exactly this one" is the only comparison that means anything.
///
/// "Set column footer..." shows for any column in [aggregatableColumns] --
/// integer/real fields only (see the set's construction at the call site).
/// Opens a dialog picking one of trina_grid's built-in
/// [TrinaAggregateColumnType]s (sum/average/min/max/count) or "None", same
/// dialog-for-a-multi-choice-setting shape as "Filter by value" above.
/// Unlike every other item here, applying the choice can't go through a
/// plain callback into [_GenericListScreenState] the same way -- see
/// [_GenericListScreenState._setColumnAggregate]'s doc comment for why it
/// has to mutate the live column directly instead -- so [onSetColumnAggregate]
/// *is* that method, called straight from here once the dialog resolves.
///
/// "Use Color"/"Stop using color" show for any column in [colorableColumns]
/// -- the table's own color field (if it has one) plus every lookup field
/// (every lookup target already has its own `color` column, per Mike).
/// Same shape as "Group by this column"/"Ungroup": "Use Color" hidden on
/// whichever column [getRowColorColumn] currently names (self-selecting it
/// again would be a no-op), "Stop using color" shown on every colorable
/// column whenever *any* one is active, not just that one -- same
/// reachability fix Ungroup already needed (see this class's doc comment
/// above). [getRowColorColumn] is a closure, not a plain value, because
/// this whole delegate instance is only rebuilt when [_GenericListScreenState]
/// itself rebuilds, which a live in-session color change doesn't trigger
/// (see [_GenericListScreenState._setRowColorColumn]'s doc comment) -- a
/// plain value captured at construction would go stale the moment the
/// color source changed without a full rebuild; reading it fresh through a
/// closure each time the menu opens doesn't have that problem.
class _ColumnMenuDelegate implements TrinaColumnMenuDelegate<dynamic> {
  const _ColumnMenuDelegate({
    required this.wrapTextColumns,
    required this.onToggleWrapText,
    required this.groupableColumns,
    required this.onGroupByColumn,
    required this.onUngroup,
    required this.lookupOptions,
    required this.aggregatableColumns,
    required this.columnAggregates,
    required this.onSetColumnAggregate,
    required this.colorableColumns,
    required this.getRowColorColumn,
    required this.onUseColor,
    required this.onStopUsingColor,
  });

  static const String _menuWrapText = 'wrapText';
  static const String _menuGroupByColumn = 'groupByColumn';
  static const String _menuUngroup = 'ungroup';
  static const String _menuFilterByValue = 'filterByValue';
  static const String _menuSetColumnAggregate = 'setColumnAggregate';
  static const String _menuUseColor = 'useColor';
  static const String _menuStopUsingColor = 'stopUsingColor';
  static const TrinaColumnMenuDelegateDefault _defaultDelegate =
      TrinaColumnMenuDelegateDefault();

  final Map<String, bool> wrapTextColumns;
  final void Function(TrinaColumn column) onToggleWrapText;
  final Set<String> groupableColumns;
  final void Function(TrinaColumn column) onGroupByColumn;
  final VoidCallback onUngroup;
  final Map<String, Map<int, String>> lookupOptions;
  final Set<String> aggregatableColumns;
  final Map<String, TrinaAggregateColumnType?> columnAggregates;
  final void Function(TrinaColumn column, TrinaAggregateColumnType? type) onSetColumnAggregate;
  final Set<String> colorableColumns;
  final String? Function() getRowColorColumn;
  final void Function(TrinaColumn column) onUseColor;
  final VoidCallback onStopUsingColor;

  bool _isGroupedBy(TrinaGridStateManager stateManager, TrinaColumn column) {
    final delegate = stateManager.rowGroupDelegate;
    return delegate is TrinaRowGroupByColumnDelegate &&
        delegate.columns.isNotEmpty &&
        delegate.columns.first.field == column.field;
  }

  @override
  List<PopupMenuEntry<dynamic>> buildMenuItems({
    required TrinaGridStateManager stateManager,
    required TrinaColumn column,
  }) {
    var items = _defaultDelegate.buildMenuItems(
      stateManager: stateManager,
      column: column,
    );

    final textColor = stateManager.style.isDarkStyle
        ? TrinaGridStyleConfig.defaultDarkCellTextStyle.color
        : TrinaGridStyleConfig.defaultLightCellTextStyle.color;
    final textStyle = TextStyle(color: textColor, fontSize: 13);

    if (wrapTextColumns.containsKey(column.field)) {
      items = [
        ...items,
        const PopupMenuDivider(),
        CheckedPopupMenuItem<dynamic>(
          value: _menuWrapText,
          checked: wrapTextColumns[column.field] ?? false,
          height: 36,
          child: Text('Wrap text', style: textStyle),
        ),
      ];
    }

    if (groupableColumns.contains(column.field)) {
      final groupedByThisColumn = _isGroupedBy(stateManager, column);
      items = [
        ...items,
        const PopupMenuDivider(),
        if (!groupedByThisColumn)
          PopupMenuItem<dynamic>(
            value: _menuGroupByColumn,
            height: 36,
            child: Text('Group by this column', style: textStyle),
          ),
        // enabledRowGroups, not hasRowGroups -- _ungroup sets an
        // empty-columns delegate rather than null (see its doc comment),
        // so hasRowGroups (delegate != null) would stay true forever after
        // the first group/ungroup cycle, permanently showing this item
        // even with nothing actually grouped. enabledRowGroups correctly
        // reads the empty-columns delegate as disabled.
        if (stateManager.enabledRowGroups)
          PopupMenuItem<dynamic>(
            value: _menuUngroup,
            height: 36,
            child: Text('Ungroup', style: textStyle),
          ),
      ];
    }

    if (lookupOptions.containsKey(column.field)) {
      items = [
        ...items,
        const PopupMenuDivider(),
        PopupMenuItem<dynamic>(
          value: _menuFilterByValue,
          height: 36,
          child: Text('Filter by value...', style: textStyle),
        ),
      ];
    }

    if (aggregatableColumns.contains(column.field)) {
      items = [
        ...items,
        const PopupMenuDivider(),
        PopupMenuItem<dynamic>(
          value: _menuSetColumnAggregate,
          height: 36,
          child: Text('Set column footer...', style: textStyle),
        ),
      ];
    }

    if (colorableColumns.contains(column.field)) {
      final currentRowColorColumn = getRowColorColumn();
      items = [
        ...items,
        const PopupMenuDivider(),
        if (currentRowColorColumn != column.field)
          PopupMenuItem<dynamic>(
            value: _menuUseColor,
            height: 36,
            child: Text('Use Color', style: textStyle),
          ),
        if (currentRowColorColumn != null)
          PopupMenuItem<dynamic>(
            value: _menuStopUsingColor,
            height: 36,
            child: Text('Stop using color', style: textStyle),
          ),
      ];
    }

    return items;
  }

  @override
  void onSelected({
    required BuildContext context,
    required TrinaGridStateManager stateManager,
    required TrinaColumn column,
    required bool mounted,
    required dynamic selected,
  }) {
    if (selected == _menuWrapText) {
      onToggleWrapText(column);
      return;
    }
    if (selected == _menuGroupByColumn) {
      onGroupByColumn(column);
      return;
    }
    if (selected == _menuUngroup) {
      onUngroup();
      return;
    }
    if (selected == _menuFilterByValue) {
      // Not awaited -- onSelected itself isn't async, and the dialog
      // manages its own lifecycle from here (applies or clears the filter
      // in its own callback once the user responds).
      unawaited(_showFilterByValueDialog(context, stateManager, column));
      return;
    }
    if (selected == _menuSetColumnAggregate) {
      unawaited(_showSetColumnAggregateDialog(context, column));
      return;
    }
    if (selected == _menuUseColor) {
      onUseColor(column);
      return;
    }
    if (selected == _menuStopUsingColor) {
      onStopUsingColor();
      return;
    }
    _defaultDelegate.onSelected(
      context: context,
      stateManager: stateManager,
      column: column,
      mounted: mounted,
      selected: selected,
    );
  }

  /// Dropdown of [column]'s actual display values (from [lookupOptions],
  /// the same map the grid renders cells from -- no extra query), pre-
  /// selected to the column's current filter if it's already an exact-match
  /// filter set this same way. Applying calls [TrinaGridStateManager
  /// .setColumnFilter] with the chosen option's id (or [TrinaGridStateManager
  /// .removeColumnFilter] if "(any)" is chosen) -- the user only ever sees
  /// display text, the id substitution happens entirely here.
  Future<void> _showFilterByValueDialog(
    BuildContext context,
    TrinaGridStateManager stateManager,
    TrinaColumn column,
  ) async {
    final options = lookupOptions[column.field] ?? const <int, String>{};
    final currentFilterType = stateManager.getColumnFilterType(column.field);
    final currentFilterValue = stateManager.getColumnFilterValue(column.field);
    int? selected = currentFilterType is TrinaFilterTypeEquals
        ? int.tryParse('$currentFilterValue')
        : null;

    final apply = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text('Filter ${column.title}'),
          content: DropdownButtonFormField<int?>(
            initialValue: selected,
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('(any)')),
              for (final entry in options.entries)
                DropdownMenuItem<int?>(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: (value) => setState(() => selected = value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (apply != true) return;

    if (selected == null) {
      stateManager.removeColumnFilter(column.field);
    } else {
      stateManager.setColumnFilter(
        columnField: column.field,
        filterType: const TrinaFilterTypeEquals(),
        filterValue: selected.toString(),
      );
    }
  }

  /// Dropdown of every [TrinaAggregateColumnType] plus "None", pre-selected
  /// to [column]'s current choice in [columnAggregates]. Applying calls
  /// [onSetColumnAggregate] (== [_GenericListScreenState._setColumnAggregate])
  /// with the choice, or `null` for "None" -- same Cancel/Apply shape as
  /// [_showFilterByValueDialog] above.
  Future<void> _showSetColumnAggregateDialog(BuildContext context, TrinaColumn column) async {
    TrinaAggregateColumnType? selected = columnAggregates[column.field];

    final apply = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text('Footer for ${column.title}'),
          content: DropdownButtonFormField<TrinaAggregateColumnType?>(
            initialValue: selected,
            items: [
              const DropdownMenuItem<TrinaAggregateColumnType?>(
                value: null,
                child: Text('None'),
              ),
              for (final type in TrinaAggregateColumnType.values)
                DropdownMenuItem<TrinaAggregateColumnType?>(
                  value: type,
                  child: Text(_aggregateLabel(type)),
                ),
            ],
            onChanged: (value) => setState(() => selected = value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (apply != true) return;

    onSetColumnAggregate(column, selected);
  }

  /// Title-case display label for a [TrinaAggregateColumnType] -- its own
  /// `.name` (`average`, `min`, ...) is fine for storage (see
  /// [ColumnSetting.aggregate]'s doc comment) but not really a UI label.
  String _aggregateLabel(TrinaAggregateColumnType type) => switch (type) {
    TrinaAggregateColumnType.sum => 'Sum',
    TrinaAggregateColumnType.average => 'Average',
    TrinaAggregateColumnType.min => 'Min',
    TrinaAggregateColumnType.max => 'Max',
    TrinaAggregateColumnType.count => 'Count',
  };
}

/// Essentials v2 Phase 4's `link_record` grid picker, opened by
/// [_GenericListScreenState._editLinkRecordCell] -- lists every row of the
/// target table, single-select (tap one, dialog closes immediately) or
/// multi-select (checkbox per row, "Done" to commit), per
/// claude/essentials-v2-phase4-design.md's "Grid rendering" section.
class _LinkRecordPickerDialog extends StatefulWidget {
  const _LinkRecordPickerDialog({
    required this.title,
    required this.options,
    required this.displayColumn,
    required this.multiple,
    required this.initialSelectedIds,
  });

  final String title;
  final List<Map<String, Object?>> options;
  final String displayColumn;
  final bool multiple;
  final Set<int> initialSelectedIds;

  @override
  State<_LinkRecordPickerDialog> createState() => _LinkRecordPickerDialogState();
}

class _LinkRecordPickerDialogState extends State<_LinkRecordPickerDialog> {
  late final Set<int> _selected = {...widget.initialSelectedIds};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        height: 420,
        child: widget.options.isEmpty
            ? const Center(child: Text('No records to link to yet.'))
            : ListView(
                shrinkWrap: true,
                children: [
                  if (!widget.multiple)
                    ListTile(
                      title: const Text('(none)'),
                      selected: _selected.isEmpty,
                      onTap: () => Navigator.pop(context, <int>[]),
                    ),
                  for (final option in widget.options)
                    if (option['id'] is int)
                      widget.multiple
                          ? CheckboxListTile(
                              title: Text('${option[widget.displayColumn]}'),
                              value: _selected.contains(option['id']),
                              onChanged: (checked) => setState(() {
                                final id = option['id'] as int;
                                if (checked ?? false) {
                                  _selected.add(id);
                                } else {
                                  _selected.remove(id);
                                }
                              }),
                            )
                          : ListTile(
                              title: Text('${option[widget.displayColumn]}'),
                              selected: _selected.contains(option['id']),
                              onTap: () => Navigator.pop(context, [option['id'] as int]),
                            ),
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (widget.multiple)
          FilledButton(
            onPressed: () => Navigator.pop(context, _selected.toList()),
            child: const Text('Done'),
          ),
      ],
    );
  }
}
