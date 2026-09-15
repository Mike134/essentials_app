import 'package:trina_grid/trina_grid.dart';

/// Every stock [TrinaFilterType] ([FilterHelper.defaultFilters]), wrapped
/// so the value they actually compare against is a lookup/inline-select
/// column's *display text*, not its raw stored value -- see
/// claude/essentials-v2-agenda-scheduling-design.md's sibling write-up (or
/// CLAUDE.md's own history) for the finding this fixes: TrinaGrid's own
/// "Set filter" popup (`FilterHelper.convertRowsToFilter`) always compares
/// `row.cells[field]!.value.toString()` -- the raw cell value -- against
/// whatever the user typed. For a plain text/number/date column that's
/// exactly right. For a `select`-type column (this app's linked lookups
/// *and* inline-select fields, both built via `TrinaColumnType.select`),
/// the raw value is the underlying id/key (e.g. a lookup's ~16-digit row
/// id), never the label the grid actually shows -- so typing "closed"
/// into **any** stock filter type (Contains, Equals, Regex, ...) silently
/// matches nothing, or worse, matches everything (a negative-lookahead
/// regex written against "closed" trivially "doesn't equal closed" when
/// compared against an id that was never going to contain the word
/// "closed" in the first place).
///
/// Fix: resolve the raw value to its display text *before* handing it to
/// the original comparator, using the exact same `itemToString` callback
/// the column already carries for rendering its own cells/dropdown items
/// (`TrinaColumnTypeSelect.itemToString` -- see
/// `GenericListScreen._buildFieldColumn`'s lookup/inline-select branches
/// for where that's built). No new lookup machinery, no per-column
/// wiring -- this is generic across every `select`-type column in the
/// app (Status, Priority, Event Type, Domain, any inline-select field),
/// and a complete no-op for every other column type (`_resolveDisplayText`
/// returns the raw value unchanged whenever `column.type` isn't a
/// `TrinaColumnTypeSelect`).
///
/// Passed as `TrinaGridConfiguration(columnFilter: TrinaGridColumnFilterConfig(
/// filters: displayAwareFilterTypes))` -- the `filters:` list *replaces*
/// [FilterHelper.defaultFilters] entirely (per
/// [TrinaGridColumnFilterConfig.filters]'s own doc comment), so this must
/// cover every filter type Mike might want to pick from the "Set filter"
/// popup's Type dropdown, not just the one this was found via (Regex).
/// Wraps every stock filter type twice: [_DisplayAwareFilterType] resolves a
/// `select`-type column's raw value to display text (see the class doc
/// comment above), then [_DateKeywordAwareFilterType] recognizes "Today" /
/// "Tomorrow" / "This week" as the filter *value* on a date/dateTime
/// column -- Mike's own ask, mirroring the plain-language spirit of
/// `filter_editor_dialog.dart`'s own Add/Remove/Clear buttons: typing
/// "Today" into a Start filter should just work, the same way it'd read in
/// a sentence, rather than requiring an exact date typed by hand and
/// re-typed the next day. See [_DateKeywordAwareFilterType]'s own doc
/// comment for why this needs real range logic, not a string substitution.
final List<TrinaFilterType> displayAwareFilterTypes = [
  for (final original in FilterHelper.defaultFilters)
    _DateKeywordAwareFilterType(_DisplayAwareFilterType(original)),
];

/// Resolves [raw] (a column's stored cell value, already stringified) to
/// its display text when [column] is a `select`-type column with an
/// `itemToString` callback -- otherwise returns [raw] unchanged. Matches
/// [raw] against `TrinaColumnTypeSelect.items` by string equality (an
/// item is either an `int` id or a `String` inline-select key in this
/// app, both of which round-trip cleanly through `.toString()`), so a
/// stale/unmatched value (a soft-deleted lookup row, an edited-away
/// inline option) just falls through unresolved rather than throwing --
/// same lenient posture every other display-text resolution in this app
/// already takes (`GenericListScreen._cellValueFor`'s own lookup
/// fallback, `KanbanViewScreen`'s unmatched-value column, ...).
String? resolveFilterDisplayText(TrinaColumn column, String? raw) {
  if (raw == null) return raw;
  final type = column.type;
  if (type is! TrinaColumnTypeSelect) return raw;

  // Deliberately `dynamic`, not a smart-cast to `TrinaColumnTypeSelect`
  // (which Dart narrows to `TrinaColumnTypeSelect<dynamic>` for a raw,
  // type-argument-less `is` check) -- reading `.itemToString` through
  // that narrowed static type throws at runtime for a real
  // `TrinaColumnTypeSelect<int?>` instance: `String Function(int?)` isn't
  // a sound subtype of the narrowed type's `String Function(dynamic)?`,
  // an unsound-downcast rejection, not a bug in the underlying object.
  // A `dynamic` member access skips that static subtype check entirely,
  // resolving at the real call site instead, which succeeds because the
  // actual argument passed really is assignable to the real (`int?` or
  // `String?`, in this app's two `select` conventions) parameter type.
  final dynamic dynamicType = type;
  final itemToString = dynamicType.itemToString;
  if (itemToString == null) return raw;

  for (final item in dynamicType.items) {
    if (item?.toString() == raw) return itemToString(item) as String;
  }
  return raw;
}

class _DisplayAwareFilterType implements TrinaFilterType {
  const _DisplayAwareFilterType(this._inner);

  final TrinaFilterType _inner;

  @override
  String get title => _inner.title;

  @override
  TrinaCompareFunction get compare {
    final innerCompare = _inner.compare;
    return ({required String? base, required String? search, required TrinaColumn column}) {
      return innerCompare(
        base: resolveFilterDisplayText(column, base),
        search: search,
        column: column,
      );
    };
  }
}

/// Recognizes "Today" / "Tomorrow" / "This week" (case-insensitive, any
/// surrounding whitespace) as the filter *value* on a date/dateTime column,
/// resolving to a real range comparison instead of delegating to the stock
/// literal-text compare -- which would never match anything, since a
/// column's real stored value is always an ISO8601 string like
/// `2026-09-14` or `2026-09-14 08:30`, never the word "Today".
///
/// **Why this needs a real range, not a string substitution:** for a plain
/// `date` column "Today" is a single value, but for a `dateTime` column
/// (e.g. Agenda's own `Start`, which carries a time) "Today" means *any*
/// time on today's calendar date -- inherently a range
/// (`[today 00:00, tomorrow 00:00)`), not one value an `Equals` could
/// literally match. "This week" is a range for either column type. So each
/// recognized keyword resolves to a `[start, end)` bound here, and each
/// filter type's own comparator (`Equals`, `Greater than`, ...) is
/// reinterpreted against that bound rather than compared as text:
///
/// - `Equals` -- base falls within `[start, end)`.
/// - `Greater than` -- base is on/after `end` (strictly later than the
///   whole keyword period).
/// - `Greater than or equal to` -- base is on/after `start`.
/// - `Less than` -- base is strictly before `start`.
/// - `Less than or equal to` -- base is strictly before `end` (on or
///   before the keyword period).
///
/// Every other filter type (`Contains`, `Starts with`, `Regex`, ...) has no
/// sensible range interpretation, so a keyword value there just falls
/// through to the stock literal-text compare unchanged -- same as it
/// already does for a non-keyword value.
///
/// "This week" is Monday-start, matching Calendar's own week convention
/// (`CalendarScreen`'s continuous week-scroll) so "this week" means the
/// same seven days everywhere in the app, not two different definitions.
class _DateKeywordAwareFilterType implements TrinaFilterType {
  const _DateKeywordAwareFilterType(this._inner);

  final TrinaFilterType _inner;

  @override
  String get title => _inner.title;

  @override
  TrinaCompareFunction get compare {
    final innerCompare = _inner.compare;
    return ({required String? base, required String? search, required TrinaColumn column}) {
      final range = _dateKeywordRange(search);
      if (range == null || !isDateFilterColumn(column)) {
        return innerCompare(base: base, search: search, column: column);
      }
      final baseDate = base == null ? null : DateTime.tryParse(base.trim());
      if (baseDate == null) return false;
      // `.name` on each stock filter type is a plain mutable static field,
      // not a compile-time constant, so this has to be an if/else chain --
      // it can't be a switch-case pattern.
      if (title == TrinaFilterTypeEquals.name) {
        return !baseDate.isBefore(range.start) && baseDate.isBefore(range.end);
      }
      if (title == TrinaFilterTypeGreaterThan.name) return !baseDate.isBefore(range.end);
      if (title == TrinaFilterTypeGreaterThanOrEqualTo.name) return !baseDate.isBefore(range.start);
      if (title == TrinaFilterTypeLessThan.name) return baseDate.isBefore(range.start);
      if (title == TrinaFilterTypeLessThanOrEqualTo.name) return baseDate.isBefore(range.end);
      return innerCompare(base: base, search: search, column: column);
    };
  }
}

/// Public (not just an implementation detail of [_DateKeywordAwareFilterType])
/// because [filter_editor_dialog.dart] needs the identical check to decide
/// whether to show its own "Today"/"Tomorrow"/"This week" quick-filter
/// buttons for a given row's selected column.
bool isDateFilterColumn(TrinaColumn column) =>
    column.type is TrinaColumnTypeDate || column.type is TrinaColumnTypeDateTime;

/// Display labels for the quick-filter buttons in `filter_editor_dialog
/// .dart` -- kept here, next to [_dateKeywordRange], so the two can never
/// drift apart. Capitalization is purely cosmetic ([_dateKeywordRange]
/// matches case-insensitively); the *words* have to stay exactly these
/// three, since those are the only ones [_dateKeywordRange] recognizes.
const List<String> dateFilterKeywordLabels = ['Today', 'Tomorrow', 'This week'];

class _DateKeywordRange {
  const _DateKeywordRange(this.start, this.end);

  /// Inclusive.
  final DateTime start;

  /// Exclusive.
  final DateTime end;
}

/// `null` when [search] isn't a recognized keyword -- the caller falls back
/// to the stock literal-text compare in that case, so a genuinely-typed
/// date/number value (or a non-keyword search on a date column) behaves
/// exactly as before this feature existed.
_DateKeywordRange? _dateKeywordRange(String? search) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  switch (search?.trim().toLowerCase()) {
    case 'today':
      return _DateKeywordRange(today, today.add(const Duration(days: 1)));
    case 'tomorrow':
      final tomorrow = today.add(const Duration(days: 1));
      return _DateKeywordRange(tomorrow, tomorrow.add(const Duration(days: 1)));
    case 'this week':
      // DateTime.weekday: Monday == 1 ... Sunday == 7.
      final weekStart = today.subtract(Duration(days: today.weekday - 1));
      return _DateKeywordRange(weekStart, weekStart.add(const Duration(days: 7)));
    default:
      return null;
  }
}
