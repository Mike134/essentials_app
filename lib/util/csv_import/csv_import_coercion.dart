import '../../models/table_config.dart';
import '../date_format.dart';

/// One CSV cell's outcome after [coerceCsvCell] -- either a value to store
/// (cleanly coerced, or the raw text as an "Excel model" fallback -- see
/// claude/essentials-v2-csv-import-design.md's "Malformed values" section)
/// or a signal that the whole row must be skipped because a `required`
/// field came up empty/unparseable.
sealed class CsvCellCoercion {
  const CsvCellCoercion();
}

/// Store [value] in the column. [warning] is non-null only when [value] is
/// the *raw, unparsed* CSV text stored as a fallback (a non-`required`
/// field whose cell didn't match its format) -- callers use its presence
/// to decide whether to log a per-cell warning in the import summary,
/// rather than re-deriving "did this really parse" themselves.
class CsvCellStore extends CsvCellCoercion {
  const CsvCellStore(this.value, {this.warning});

  final Object? value;
  final String? warning;
}

/// [field] is `required` and this row's cell for it was empty, or its text
/// didn't parse into a real value at all (not even the format's normal
/// fallback) -- storing `NULL`/omitting the column would throw a real
/// `NOT NULL` violation, so the caller must skip this entire row rather
/// than attempt the insert.
class CsvCellRequiredMissing extends CsvCellCoercion {
  const CsvCellRequiredMissing(this.field);

  final FieldConfig field;
}

/// A field is a valid CSV import mapping target iff it isn't computed
/// ([FieldConfig.readOnly] -- a `formula` field, never written) and isn't a
/// linked lookup ([FieldConfig.isLookup] -- resolving a CSV cell's text to
/// another table's row `id` is exactly the child-table-link complexity this
/// task was scoped away from, per claude/essentials-v2-csv-import-design
/// .md's "Scope"). `id` never needs excluding here explicitly -- it's never
/// one of [TableConfig.fields] in the first place (see that class's own doc
/// comment), so it can never reach this function at all.
bool isCsvImportable(FieldConfig field) => !field.readOnly && !field.isLookup;

/// Coerces one raw CSV cell's text into whatever [field] should actually
/// store, mirroring exactly what typing the equivalent value into the form
/// and saving would produce (`GenericFormScreen._currentValues`/each
/// `FieldFormatHandler.valueForSave`) -- see the design doc's "Per-format
/// import coercion rules" table, which this function implements one rule
/// per row of. [field] must satisfy [isCsvImportable]; the CSV import
/// screen never offers anything else as a mapping target, so this throws
/// on a bad caller rather than silently guessing.
CsvCellCoercion coerceCsvCell(FieldConfig field, String rawCellText) {
  if (!isCsvImportable(field)) {
    throw ArgumentError(
      '"${field.column}" is not a valid CSV import target (linked/formula '
      'fields are never mapping targets -- see isCsvImportable).',
    );
  }

  final trimmed = rawCellText.trim();

  // Boolean is the one format where an empty cell has its own real
  // fallback (0/"No"), not the generic "null if optional, skip if
  // required" rule every other format below uses -- see the design doc's
  // own boolean row.
  if (field.type == FieldType.boolean) {
    if (trimmed.isEmpty) return const CsvCellStore(0);
    final parsed = _tryParseBoolean(trimmed.toLowerCase());
    if (parsed != null) return CsvCellStore(parsed);
    if (field.required) return CsvCellRequiredMissing(field);
    return CsvCellStore(trimmed, warning: 'not recognized as Yes/No -- stored as raw text');
  }

  if (trimmed.isEmpty) {
    if (field.required) return CsvCellRequiredMissing(field);
    return const CsvCellStore(null);
  }

  final parsed = _tryParseNonEmpty(field, trimmed);
  if (parsed != null) return CsvCellStore(parsed);

  if (field.required) return CsvCellRequiredMissing(field);
  return CsvCellStore(trimmed, warning: "didn't match ${field.label}'s format -- stored as raw text");
}

const _trueBooleanTexts = {'1', 'true', 'yes', 'y'};
const _falseBooleanTexts = {'0', 'false', 'no', 'n'};

int? _tryParseBoolean(String lowerTrimmed) {
  if (_trueBooleanTexts.contains(lowerTrimmed)) return 1;
  if (_falseBooleanTexts.contains(lowerTrimmed)) return 0;
  return null;
}

/// Dispatches every non-boolean, non-empty cell to its format's own parse
/// rule. `null` means "didn't parse" -- the caller decides skip-vs-raw-text
/// from there. Plain text (including `url`/`link_file`/`barcode`/`isColor`
/// fields -- all plain-`TEXT`-backed, per the design doc's `text` row)
/// never fails: it's just [trimmed] as-is.
Object? _tryParseNonEmpty(FieldConfig field, String trimmed) {
  if (field.isInlineSelect) return _tryParseInlineSelect(field, trimmed);

  switch (field.format) {
    case 'currency':
      return _tryParseCurrency(trimmed);
    case 'percentage':
      return _tryParsePercentage(trimmed);
    case 'rating':
      return int.tryParse(trimmed);
  }

  switch (field.type) {
    case FieldType.integer:
      return int.tryParse(trimmed);
    case FieldType.real:
      return double.tryParse(trimmed);
    case FieldType.date:
      final parsedDate = _tryParseDateLike(trimmed);
      return parsedDate == null ? null : isoDate(parsedDate);
    case FieldType.dateTime:
      final parsedDateTime = _tryParseDateLike(trimmed);
      return parsedDateTime == null ? null : isoDateTime(parsedDateTime);
    case FieldType.boolean:
      // Handled entirely by coerceCsvCell before this is ever reached.
      return null;
    case FieldType.text:
      return trimmed;
  }
}

/// Case-insensitive match against [FieldConfig.inlineOptions]' labels,
/// storing the matching option's `key` -- per the design doc's `select`
/// (inline mode) row. No match -> `null` (malformed), same as everything
/// else here.
String? _tryParseInlineSelect(FieldConfig field, String trimmed) {
  final lowerTrimmed = trimmed.toLowerCase();
  for (final option in field.inlineOptions ?? const []) {
    if (option.label.toLowerCase() == lowerTrimmed) return option.key;
  }
  return null;
}

/// Strips everything but digits/`.`/`-` (currency symbols, thousands
/// separators, whitespace -- `$1,234.56` -> `1234.56`) then parses as a
/// plain decimal, matching `CurrencyFormatHandler`'s plain-decimal-string
/// storage.
double? _tryParseCurrency(String trimmed) {
  final cleaned = trimmed.replaceAll(RegExp(r'[^0-9.\-]'), '');
  if (cleaned.isEmpty) return null;
  return double.tryParse(cleaned);
}

/// An explicit trailing `%` divides by 100 (`"15%"` -> `0.15`); anything
/// else is parsed as-is, already assumed to be the stored fraction
/// (`"0.15"` -> `0.15`) -- deliberately no magnitude-based guessing, since
/// a percentage field can legitimately store a fraction above 1 (150%
/// growth = `1.5`). Matches `PercentageFormatHandler`'s stored-vs-displayed
/// asymmetry.
double? _tryParsePercentage(String trimmed) {
  if (trimmed.endsWith('%')) {
    final value = double.tryParse(trimmed.substring(0, trimmed.length - 1).trim());
    return value == null ? null : value / 100;
  }
  return double.tryParse(trimmed);
}

/// `DateTime.tryParse` first (covers ISO `YYYY-MM-DD`/`YYYY-MM-DD HH:MM:SS`
/// directly), then a short fallback list for the common US-locale Excel
/// export shape (`MM/DD/YYYY`, `M/D/YYYY`, optionally followed by a
/// `HH:MM[:SS]` time). `null` if nothing matches -- callers must not
/// silently accept "close enough".
DateTime? _tryParseDateLike(String trimmed) {
  final isoParsed = DateTime.tryParse(trimmed);
  if (isoParsed != null) return isoParsed;

  final match = RegExp(
    r'^(\d{1,2})/(\d{1,2})/(\d{4})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$',
  ).firstMatch(trimmed);
  if (match == null) return null;

  final month = int.parse(match.group(1)!);
  final day = int.parse(match.group(2)!);
  final year = int.parse(match.group(3)!);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final hour = int.tryParse(match.group(4) ?? '') ?? 0;
  final minute = int.tryParse(match.group(5) ?? '') ?? 0;
  final second = int.tryParse(match.group(6) ?? '') ?? 0;

  try {
    return DateTime(year, month, day, hour, minute, second);
  } on ArgumentError {
    return null;
  }
}
