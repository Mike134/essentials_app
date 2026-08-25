import 'package:flutter/material.dart';

import '../db/generic_dao.dart';
import '../db/schema_metadata_dao.dart';
import '../db/schema_registry.dart';
import '../db/view_definitions_dao.dart';
import '../models/table_config.dart';
import '../theme/theme_controller.dart';
import '../util/calendar_field.dart';
import '../util/layout.dart';
import '../util/saved_view_data.dart';
import 'generic_form_screen.dart';

/// Essentials v2 Phase 3, build order step 5 (the last one) -- the one
/// Calendar surface, table-agnostic (reached as its own top-level nav
/// destination, like Search, not through any one table's
/// `ViewSwitcherBar`). See claude/essentials-v2-architecture.md's
/// "Calendar view" write-up for the confirmed design this implements:
/// aggregate by default (every eligible table toggle-able on/off via a
/// "Lists" checklist), eligibility not error states (a table with no
/// date/dateTime field never appears in that checklist), color from the
/// table's own `color`-format field if it has one, Day/Week/Month
/// granularity only.
///
/// **A deliberate, documented simplification of the "spanning bar" part of
/// the confirmed design:** a date-range entry is rendered as a plain chip
/// on *every* day it covers, not a single continuous bar spanning multiple
/// day cells. A true spanning-bar layout (with cross-day collision
/// avoidance) is a much larger undertaking -- this delivers the same
/// underlying information (the record shows on every day in its range)
/// without that layout engine. Worth revisiting if Mike wants the fuller
/// visual later.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

enum _Granularity { day, week, month }

/// One record placed on the calendar -- [start]/[end] are calendar *days*
/// (time-of-day stripped), inclusive, same for both in single-date mode.
class _CalendarEntry {
  _CalendarEntry({
    required this.tableConfig,
    required this.row,
    required this.start,
    required this.end,
    required this.title,
    required this.color,
  });

  final TableConfig tableConfig;
  final Map<String, Object?> row;
  final DateTime start;
  final DateTime end;
  final String title;
  final Color? color;

  bool coversDay(DateTime day) => !day.isBefore(start) && !day.isAfter(end);
}

class _EligibleTable {
  _EligibleTable({required this.config, required this.calendarField});

  final TableConfig config;
  final CalendarFieldConfig calendarField;
}

class _CalendarScreenState extends State<CalendarScreen> {
  final _viewsDao = ViewDefinitionsDao();
  final _metadata = SchemaMetadataDao();
  final _registry = SchemaRegistry();

  _Granularity _granularity = _Granularity.month;
  DateTime _anchor = _dateOnly(DateTime.now());

  ViewDefinition? _view;
  List<_EligibleTable> _eligible = const [];
  List<_CalendarEntry> _entries = const [];
  bool _loading = true;
  String? _error;

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Same calendar date, ignoring time-of-day -- deliberately NOT plain
  /// DateTime `==`. Dart's local-time `DateTime.add(Duration)` is
  /// DST-aware (it adds real elapsed time, then re-expresses the result
  /// in local wall-clock time), so a date built by chaining thousands of
  /// day-additions from a fixed epoch (every day this screen shows, via
  /// `_weekStartForIndex`) can end up sitting an hour or so off midnight
  /// even though its calendar date is correct -- silently breaking a
  /// strict `==` against a freshly-built `_dateOnly(DateTime.now())`.
  /// Confirmed live: Mike's "Today" cell showed no highlight at all
  /// despite entries for that same day rendering in the right cell (entry
  /// matching uses an inclusive day-range comparison, tolerant of exactly
  /// this kind of drift; a strict equality check is not).
  static bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  // Month view -- continuous, freely-scrollable weeks (Mike's ask: "scroll
  // a week at a time rather than being fixed month") instead of a static
  // single-month 6-row grid that only changed on the prev/next arrows.
  // Bounded (not truly infinite) but generous: 1900-2100, ~10,400 weeks --
  // ListView.builder only ever builds the visible rows, so the bound costs
  // nothing at runtime; it just needs to comfortably cover any date a
  // personal record could realistically carry.
  static final DateTime _weekEpoch = _weekStart(DateTime(1900, 1, 1));
  static const int _monthWeekItemCount = 10400;
  static const double _monthRowHeight = 110;

  late final ScrollController _monthScrollController;
  int? _monthTrackedWeekIndex;
  // Set whenever _anchor changes from something OTHER than the month
  // scroll listener itself (Day/Week nav, "Today" while not viewing
  // Month) -- _buildMonth() consumes this to re-sync the scroll position
  // next time it's actually the visible view, rather than fighting the
  // listener with a jump mid-scroll.
  bool _monthScrollDirty = true;

  static int _weekIndexForDate(DateTime day) => _weekStart(day).difference(_weekEpoch).inDays ~/ 7;

  static DateTime _weekStartForIndex(int index) => _weekEpoch.add(Duration(days: index * 7));

  @override
  void initState() {
    super.initState();
    final initialIndex = _weekIndexForDate(_anchor).clamp(0, _monthWeekItemCount - 1);
    _monthTrackedWeekIndex = initialIndex;
    _monthScrollController = ScrollController(initialScrollOffset: initialIndex * _monthRowHeight)
      ..addListener(_onMonthScroll);
    _load();
  }

  @override
  void dispose() {
    _monthScrollController.dispose();
    super.dispose();
  }

  void _onMonthScroll() {
    if (!_monthScrollController.hasClients) return;
    final index = (_monthScrollController.offset / _monthRowHeight).round().clamp(0, _monthWeekItemCount - 1);
    if (index == _monthTrackedWeekIndex) return;
    _monthTrackedWeekIndex = index;
    setState(() => _anchor = _weekStartForIndex(index));
  }

  /// The month/year the header and dimming logic treat as "current" while
  /// scrolling continuously -- Thursday of `_anchor`'s week, not the
  /// week's Monday. A week that straddles a month boundary is credited to
  /// whichever month owns the *majority* of its 7 days (same reasoning
  /// ISO week-numbering already uses for edge weeks: Thursday is always
  /// the middle day of a Mon-Sun week). Using the Monday directly (the
  /// first attempt) made the header lag up to 6 days behind what was
  /// actually mostly on screen -- flagged live by Mike ("should have
  /// already changed to September... a week late").
  DateTime get _monthLabelReference => _weekStart(_anchor).add(const Duration(days: 3));

  bool _isInCurrentMonthLabel(DateTime day) {
    final ref = _monthLabelReference;
    return day.year == ref.year && day.month == ref.month;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var view = await _viewsDao.loadCalendarView();
      view ??= await _createCalendarView();
      _view = view;

      final tables = await _metadata.loadActiveTables();
      final eligible = <_EligibleTable>[];
      for (final table in tables) {
        final config = await _registry.buildConfig(table.tableName);
        final calendarField = resolveCalendarField(config, table.calendarField);
        if (calendarField != null) {
          eligible.add(_EligibleTable(config: config, calendarField: calendarField));
        }
      }
      _eligible = eligible;

      final selectedIds = (view.config['table_ids'] as List?)?.cast<String>().toSet() ?? const <String>{};
      final entries = <_CalendarEntry>[];
      for (final table in eligible) {
        if (!selectedIds.contains(table.config.tableName)) continue;
        entries.addAll(await _loadEntriesFor(table));
      }

      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<ViewDefinition> _createCalendarView() async {
    await _viewsDao.createView(
      tableName: null,
      viewType: 'calendar',
      displayName: 'Calendar',
    );
    final view = await _viewsDao.loadCalendarView();
    return view ?? (throw StateError('Failed to create the calendar view.'));
  }

  Future<List<_CalendarEntry>> _loadEntriesFor(_EligibleTable table) async {
    final dao = GenericDao(table.config);
    final data = await loadSavedViewData(dao, table.config);
    final colorField = _colorField(table.config);
    // Falls back to the first real field by position when the table's own
    // displayColumn heuristic lands on the bare "id" (no NOT NULL/UNIQUE
    // column to derive a display column from -- e.g. every field on
    // "Calendar Test" is a plain optional TEXT column). fieldByColumn
    // returns null for "id" since it's structural, never a FieldConfig --
    // showing the raw numeric id as a calendar entry's title is never
    // useful, so this always prefers a real field when one exists.
    final titleField = fieldByColumn(table.config, table.config.displayColumn) ??
        (table.config.fields.isNotEmpty ? table.config.fields.first : null);

    final entries = <_CalendarEntry>[];
    for (final row in data.rows) {
      final DateTime? start;
      final DateTime? end;
      if (table.calendarField.isRange) {
        start = parseStoredDate(row[table.calendarField.startField]);
        end = parseStoredDate(row[table.calendarField.endField]);
      } else {
        start = parseStoredDate(row[table.calendarField.field]);
        end = start;
      }
      if (start == null || end == null) continue; // blank date -- just doesn't appear, no error state
      final normalizedStart = _dateOnly(start);
      final normalizedEnd = _dateOnly(end);
      if (normalizedEnd.isBefore(normalizedStart)) continue; // malformed range -- skip rather than crash

      final title = titleField != null
          ? savedViewDisplayText(titleField, row[titleField.column], data)
          : '${row['id']}';
      final colorHex = colorField == null ? null : row[colorField.column] as String?;

      entries.add(
        _CalendarEntry(
          tableConfig: table.config,
          row: row,
          start: normalizedStart,
          end: normalizedEnd,
          title: title.isEmpty ? '(blank)' : title,
          color: ThemeController.parseHexColor(colorHex),
        ),
      );
    }
    return entries;
  }

  FieldConfig? _colorField(TableConfig config) {
    for (final field in config.fields) {
      if (field.isColor) return field;
    }
    return null;
  }

  Future<void> _toggleTable(String tableName, bool selected) async {
    final view = _view;
    if (view == null) return;
    final current = (view.config['table_ids'] as List?)?.cast<String>().toSet() ?? <String>{};
    if (selected) {
      current.add(tableName);
    } else {
      current.remove(tableName);
    }
    await _viewsDao.updateViewConfig(view.viewId, {'table_ids': current.toList()});
    _load();
  }

  void _shift(int amount) {
    switch (_granularity) {
      case _Granularity.day:
        setState(() => _anchor = _anchor.add(Duration(days: amount)));
        _monthScrollDirty = true;
      case _Granularity.week:
        setState(() => _anchor = _anchor.add(Duration(days: amount * 7)));
        _monthScrollDirty = true;
      case _Granularity.month:
        // Scrolls by one week, per Mike's ask -- _onMonthScroll updates
        // _anchor itself once the animation settles, same as any other
        // scroll.
        if (_monthScrollController.hasClients) {
          _monthScrollController.animateTo(
            _monthScrollController.offset + amount * _monthRowHeight,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        } else {
          setState(() => _anchor = _anchor.add(Duration(days: amount * 7)));
          _monthScrollDirty = true;
        }
    }
  }

  void _goToday() {
    final today = _dateOnly(DateTime.now());
    if (_granularity == _Granularity.month && _monthScrollController.hasClients) {
      final index = _weekIndexForDate(today).clamp(0, _monthWeekItemCount - 1);
      _monthScrollController.animateTo(
        index * _monthRowHeight,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      setState(() => _anchor = today);
      _monthScrollDirty = true;
    }
  }

  Future<void> _openRow(_CalendarEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GenericFormScreen(config: entry.tableConfig, existing: entry.row),
      ),
    );
    _load();
  }

  Future<void> _showListsPanel() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final selectedIds = (_view?.config['table_ids'] as List?)?.cast<String>().toSet() ?? const <String>{};
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text('Lists', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                if (_eligible.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No tables have a date/dateTime field yet.'),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final table in _eligible)
                          CheckboxListTile(
                            title: Text(table.config.displayName),
                            value: selectedIds.contains(table.config.tableName),
                            onChanged: (v) {
                              Navigator.pop(context);
                              _toggleTable(table.config.tableName, v ?? false);
                            },
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showDayDetail(DateTime day, List<_CalendarEntry> entries) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(_formatDayHeader(day), style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final entry in entries)
                      ListTile(
                        leading: Icon(Icons.circle, size: 12, color: entry.color),
                        title: Text(entry.title),
                        subtitle: Text(entry.tableConfig.displayName),
                        onTap: () {
                          Navigator.pop(context);
                          _openRow(entry);
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<_CalendarEntry> _entriesForDay(DateTime day) =>
      [for (final e in _entries) if (e.coversDay(day)) e];

  String _formatDayHeader(DateTime day) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', // ignore: unnecessary_comment
    ];
    return '${weekdays[day.weekday - 1]}, ${months[day.month - 1]} ${day.day}, ${day.year}';
  }

  String _headerLabel() {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December', // ignore: unnecessary_comment
    ];
    switch (_granularity) {
      case _Granularity.month:
        final ref = _monthLabelReference;
        return '${months[ref.month - 1]} ${ref.year}';
      case _Granularity.week:
        final start = _weekStart(_anchor);
        final end = start.add(const Duration(days: 6));
        return '${months[start.month - 1]} ${start.day} - ${end.month == start.month ? '' : '${months[end.month - 1]} '}${end.day}, ${end.year}';
      case _Granularity.day:
        return _formatDayHeader(_anchor);
    }
  }

  static DateTime _weekStart(DateTime day) => day.subtract(Duration(days: day.weekday - 1));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        actions: [
          IconButton(icon: const Icon(Icons.checklist), tooltip: 'Lists', onPressed: _showListsPanel),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text('Error: $_error'))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Narrow (Android): the nav row and the granularity
                      // switch don't fit on one line -- confirmed live on
                      // MIKE-12R (a real overflow, the header text squeezed
                      // to near-zero width and wrapping one character per
                      // line). Wide (Windows): keep the original single
                      // row, same threshold HomeShell's own rail/drawer
                      // split already uses.
                      final wide = constraints.maxWidth >= wideLayoutBreakpoint;
                      final navRow = Row(
                        children: [
                          IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _shift(-1)),
                          Expanded(
                            child: Text(
                              _headerLabel(),
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _shift(1)),
                          TextButton(onPressed: _goToday, child: const Text('Today')),
                        ],
                      );
                      final granularitySwitch = SegmentedButton<_Granularity>(
                        segments: const [
                          ButtonSegment(value: _Granularity.day, label: Text('Day')),
                          ButtonSegment(value: _Granularity.week, label: Text('Week')),
                          ButtonSegment(value: _Granularity.month, label: Text('Month')),
                        ],
                        selected: {_granularity},
                        onSelectionChanged: (s) => setState(() => _granularity = s.first),
                      );
                      if (wide) {
                        return Row(
                          children: [
                            Expanded(child: navRow),
                            const SizedBox(width: 8),
                            granularitySwitch,
                          ],
                        );
                      }
                      return Column(
                        children: [
                          navRow,
                          const SizedBox(height: 8),
                          Center(child: granularitySwitch),
                        ],
                      );
                    },
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: _buildGrid()),
              ],
            ),
    );
  }

  Widget _buildGrid() {
    switch (_granularity) {
      case _Granularity.month:
        return _buildMonth();
      case _Granularity.week:
        return _buildWeek();
      case _Granularity.day:
        return _buildDay();
    }
  }

  Widget _buildMonth() {
    if (_monthScrollDirty) {
      // _anchor moved while this view wasn't the one on screen (Day/Week
      // nav, or "Today" pressed from another tab) -- resync once this
      // frame lands rather than fighting _onMonthScroll's own listener
      // with a jump mid-build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_monthScrollController.hasClients) return;
        final index = _weekIndexForDate(_anchor).clamp(0, _monthWeekItemCount - 1);
        _monthTrackedWeekIndex = index;
        _monthScrollController.jumpTo(index * _monthRowHeight);
      });
      _monthScrollDirty = false;
    }

    return Column(
      children: [
        Row(
          children: [
            for (final label in const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'])
              Expanded(
                child: Center(
                  child: Text(label, style: Theme.of(context).textTheme.labelSmall),
                ),
              ),
          ],
        ),
        Expanded(
          child: ListView.builder(
            controller: _monthScrollController,
            physics: const _RowSnapScrollPhysics(itemExtent: _monthRowHeight),
            itemExtent: _monthRowHeight,
            itemCount: _monthWeekItemCount,
            itemBuilder: (context, index) {
              final weekStart = _weekStartForIndex(index);
              final days = [for (var i = 0; i < 7; i++) weekStart.add(Duration(days: i))];
              return Row(children: [for (final d in days) Expanded(child: _buildMonthCell(d))]);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMonthCell(DateTime day) {
    // Dims a day that falls outside the month currently named in the
    // header -- see _monthLabelReference for why that's Thursday-of-week,
    // not the week's Monday. A continuous week-by-week scroll has no hard
    // "page" boundary the way a paginated single-month grid does, so
    // without this a row spanning two months (e.g. Aug 31 / Sep 1 side by
    // side) reads as ambiguous -- flagged by Mike, who pointed at a
    // reference calendar app that dims exactly this way even though its
    // own month view is paginated, not scrolled.
    final inMonth = _isInCurrentMonthLabel(day);
    final isToday = _isSameDate(day, DateTime.now());
    final entries = _entriesForDay(day);
    const maxVisible = 3;

    return InkWell(
      onTap: entries.isEmpty ? null : () => _showDayDetail(day, entries),
      child: Container(
        decoration: BoxDecoration(
          // Full-strength primaryContainer, not a faint tint -- an alpha
          // -reduced version read as "not very apparent" against this
          // app's own muted theme palette when Mike first tried it.
          color: isToday ? Theme.of(context).colorScheme.primaryContainer : null,
          border: Border.all(
            color: isToday ? Theme.of(context).colorScheme.primary : Theme.of(context).dividerColor,
            width: isToday ? 3 : 1,
          ),
        ),
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: isToday
                  ? BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(4),
                    )
                  : null,
              child: Text(
                '${day.day}',
                style: TextStyle(
                  fontSize: 11,
                  color: isToday
                      ? Theme.of(context).colorScheme.onPrimary
                      : inMonth
                      ? null
                      : Theme.of(context).disabledColor,
                ),
              ),
            ),
            for (final entry in entries.take(maxVisible)) _buildChip(entry),
            if (entries.length > maxVisible)
              Text('+${entries.length - maxVisible} more', style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }

  Widget _buildChip(_CalendarEntry entry) {
    return GestureDetector(
      onTap: () => _openRow(entry),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        width: double.infinity,
        decoration: BoxDecoration(
          color: entry.color ?? Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          entry.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            color: entry.color == null
                ? Theme.of(context).colorScheme.onSecondaryContainer
                : _contrastingText(entry.color!),
          ),
        ),
      ),
    );
  }

  /// Plain luminance check -- readable text on an arbitrary record color,
  /// same "just needs to work, not be pixel-perfect" bar as everywhere
  /// else a table's own color field drives display in this app.
  Color _contrastingText(Color background) =>
      background.computeLuminance() > 0.5 ? Colors.black : Colors.white;

  Widget _buildWeek() {
    final start = _weekStart(_anchor);
    final days = [for (var i = 0; i < 7; i++) start.add(Duration(days: i))];
    return Row(
      children: [
        for (final day in days)
          Expanded(
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  color: _isSameDate(day, DateTime.now())
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                  child: Text('${day.day}', textAlign: TextAlign.center),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(2),
                    children: [for (final entry in _entriesForDay(day)) _buildChip(entry)],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDay() {
    final entries = _entriesForDay(_anchor);
    if (entries.isEmpty) return const Center(child: Text('Nothing on the calendar today.'));
    return ListView(
      children: [
        for (final entry in entries)
          ListTile(
            leading: Icon(Icons.circle, size: 12, color: entry.color),
            title: Text(entry.title),
            subtitle: Text(entry.tableConfig.displayName),
            onTap: () => _openRow(entry),
          ),
      ],
    );
  }
}

/// Snaps a free-scrolling, fixed-[itemExtent] `ListView.builder` to the
/// nearest whole-row boundary once the user releases it, instead of
/// settling at whatever arbitrary offset the fling happened to end on.
/// Without this, Month view's continuous scroll could stop mid-row --
/// flagged live by Mike as day numbers looking "cut off"/"missing" (a
/// partial row, only half showing at the very top or bottom of the
/// viewport). `FixedExtentScrollPhysics` (Flutter's own built-in
/// snap-to-item physics) isn't usable here -- it's `ListWheelScrollView`
/// -specific, requiring `FixedExtentMetrics` a plain `ListView` never
/// provides. Standard "snap to nearest fixed-extent item" recipe, adapted
/// for a full-height row rather than a single wheel item.
class _RowSnapScrollPhysics extends ScrollPhysics {
  const _RowSnapScrollPhysics({super.parent, required this.itemExtent});

  final double itemExtent;

  @override
  _RowSnapScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _RowSnapScrollPhysics(parent: buildParent(ancestor), itemExtent: itemExtent);

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    // Already at rest against an edge -- let the parent physics handle any
    // overscroll bounce rather than fighting it with a snap target.
    if ((velocity <= 0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    var row = position.pixels / itemExtent;
    if (velocity < -tolerance.velocity) {
      row -= 0.5;
    } else if (velocity > tolerance.velocity) {
      row += 0.5;
    }
    final target = row.roundToDouble() * itemExtent;
    if ((target - position.pixels).abs() < tolerance.distance) return null;
    return ScrollSpringSimulation(spring, position.pixels, target, velocity, tolerance: tolerance);
  }

  @override
  bool get allowImplicitScrolling => false;
}
