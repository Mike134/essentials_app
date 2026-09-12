import 'package:trina_grid/trina_grid.dart';

import '../models/table_config.dart';
import 'display_aware_filters.dart';
import 'saved_view_data.dart';

/// A table's Filter Sets (`view_definitions` rows, `view_type = 'filter'`)
/// were originally built for -- and remain -- a `GenericListScreen`/
/// `TrinaGridStateManager` concept: `_applyFilterSet` turns a Filter Set's
/// saved `{column, type, value}` rows into real `TrinaRow`s and hands them
/// to the grid's own filter engine. Calendar has no live `TrinaGrid` to
/// hand rows to -- it just needs a plain `bool` per row, computed once
/// while building this load's entries. This is that standalone evaluator,
/// deliberately reusing every piece of resolution logic the grid path
/// already has rather than re-deriving it: [savedViewDisplayText] for
/// "what does this cell actually show" (identical to what a human typed
/// into the filter in the first place -- see [displayAwareFilterTypes]'s
/// own doc comment for why a lookup/inline-select column's *display text*,
/// not its raw stored id, is the correct thing to compare), and
/// [displayAwareFilterTypes] itself (keyed by title, exactly as
/// `GenericListScreen`'s own `_filterTypesByName` already does) for the
/// actual comparison -- including its numeric/date-aware ordering for the
/// GreaterThan/LessThan family, which needs a real [TrinaColumn] to read
/// `.type` off of. [_placeholderColumnFor] builds one shaped like the
/// field's own [FieldType] purely for that purpose -- its `.type` is never
/// a `TrinaColumnTypeSelect`, so [resolveFilterDisplayText] correctly
/// no-ops on it (the display-text resolution already happened, once,
/// against the *real* field above).
///
/// All conditions in [filterRows] are ANDed together, matching
/// `TrinaGridStateManager.setFilterWithFilterRows`'s own semantics for a
/// Filter Set's saved rows. A row referencing a column no longer present on
/// this table (a field renamed/removed since the Filter Set was saved) is
/// simply skipped for that one condition, not treated as a hard failure --
/// same lenient "stale reference degrades gracefully" posture every other
/// display-text resolution in this app already takes.
bool rowMatchesFilterSet(
  TableConfig config,
  SavedViewData data,
  Map<String, Object?> row,
  List<dynamic> filterRows,
) {
  for (final entry in filterRows) {
    if (entry is! Map) continue;
    final field = fieldByColumn(config, entry['column'] as String?);
    if (field == null) continue;

    final filterType = _filterTypesByTitle[entry['type']] ?? const TrinaFilterTypeContains();
    final base = savedViewDisplayText(field, row[field.column], data);
    final search = entry['value']?.toString() ?? '';

    if (!filterType.compare(base: base, search: search, column: _placeholderColumnFor(field))) {
      return false;
    }
  }
  return true;
}

final Map<String, TrinaFilterType> _filterTypesByTitle = {
  for (final type in displayAwareFilterTypes) type.title: type,
};

TrinaColumn _placeholderColumnFor(FieldConfig field) {
  final type = switch (field.type) {
    FieldType.integer || FieldType.real => TrinaColumnType.number(),
    FieldType.date => TrinaColumnType.date(format: 'yyyy-MM-dd'),
    FieldType.dateTime => TrinaColumnType.dateTime(format: 'yyyy-MM-dd HH:mm'),
    FieldType.text || FieldType.boolean => TrinaColumnType.text(),
  };
  return TrinaColumn(title: field.column, field: field.column, type: type);
}
