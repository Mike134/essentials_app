import '../db/generic_dao.dart';
import '../models/table_config.dart';
import 'bool_value.dart';
import 'link_record.dart';
import 'lookup_value.dart';

/// Shared read-side plumbing for Essentials v2 Phase 3's saved view
/// screens (`ListViewScreen`, `KanbanViewScreen`) -- both need the same
/// thing `GenericListScreen` already builds for its own grid cells (rows,
/// plus id -> display-text maps for lookup/`link_record` fields), and the
/// same best-effort plain-text rendering of a field's raw value. Factored
/// out once a second saved-view screen needed the identical logic, rather
/// than duplicated a second time.
class SavedViewData {
  SavedViewData({required this.rows, required this.lookupMaps, required this.linkRecordOptionMaps});

  final List<Map<String, Object?>> rows;
  final Map<String, Map<int, String>> lookupMaps;
  final Map<String, Map<int, String>> linkRecordOptionMaps;
}

/// Fetches [config]'s rows plus, for every lookup/`link_record` field, an
/// id -> display-text map -- same shape (and same two DAO calls)
/// `GenericListScreen._loadData` already builds for its own grid cells,
/// minus the color maps (only "Use Color" row-coloring needs those, a
/// Grid-only feature).
Future<SavedViewData> loadSavedViewData(GenericDao dao, TableConfig config) async {
  final rows = await dao.getAll();
  final lookupMaps = <String, Map<int, String>>{};
  final linkRecordOptionMaps = <String, Map<int, String>>{};
  for (final field in config.fields) {
    if (field.isLinkRecord) {
      final linkRecord = field.linkRecord!;
      final options = await dao.getLinkedRecordOptions(linkRecord);
      linkRecordOptionMaps[field.column] = {
        for (final option in options) option['id'] as int: '${option[linkRecord.displayColumn]}',
      };
    } else if (field.isLookup) {
      final lookup = field.lookup!;
      final options = await dao.getLookupOptions(lookup);
      lookupMaps[field.column] = {
        for (final option in options) option[lookup.valueColumn] as int: '${option[lookup.displayColumn]}',
      };
    }
  }
  return SavedViewData(rows: rows, lookupMaps: lookupMaps, linkRecordOptionMaps: linkRecordOptionMaps);
}

/// Best-effort plain-text rendering of one field's raw stored value --
/// resolves lookup/`link_record` ids and inline-select keys to their real
/// display text. Deliberately simpler than the grid's own currency/
/// percentage/rating `FieldFormatHandler`-driven formatting (a plain
/// `toString()` fallback for those) -- List/Kanban views are secondary,
/// lighter-weight displays, not a second full renderer for every Phase 2
/// format.
String savedViewDisplayText(FieldConfig field, Object? raw, SavedViewData data) {
  if (field.isLookup) {
    final id = parseLookupValue(raw);
    return id == null ? '' : (data.lookupMaps[field.column]?[id] ?? '');
  }
  if (field.isLinkRecord) {
    final ids = parseLinkedIds(raw);
    final map = data.linkRecordOptionMaps[field.column] ?? const {};
    return ids.map((id) => map[id] ?? '').where((s) => s.isNotEmpty).join(', ');
  }
  if (field.isInlineSelect) {
    final key = raw?.toString();
    for (final option in field.inlineOptions ?? const []) {
      if (option.key == key) return option.label;
    }
    return key ?? '';
  }
  if (field.type == FieldType.boolean) {
    return coerceBoolValue(raw) ? 'Yes' : 'No';
  }
  return raw?.toString() ?? '';
}

/// Generic best-effort ordering for two raw stored values -- numeric
/// comparison when both sides parse as a number (every v2 field is
/// physically `TEXT`, so a `real`/`integer` column's values are numeric
/// strings), otherwise plain string comparison. `null` sorts first.
int compareSavedViewValues(Object? a, Object? b) {
  if (a == null && b == null) return 0;
  if (a == null) return -1;
  if (b == null) return 1;
  if (a is num && b is num) return a.compareTo(b);
  final an = num.tryParse(a.toString());
  final bn = num.tryParse(b.toString());
  if (an != null && bn != null) return an.compareTo(bn);
  return a.toString().compareTo(b.toString());
}

FieldConfig? fieldByColumn(TableConfig config, String? column) {
  if (column == null) return null;
  for (final field in config.fields) {
    if (field.column == column) return field;
  }
  return null;
}
