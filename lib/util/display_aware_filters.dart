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
final List<TrinaFilterType> displayAwareFilterTypes = [
  for (final original in FilterHelper.defaultFilters) _DisplayAwareFilterType(original),
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
