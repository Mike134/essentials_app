import '../../models/table_config.dart';
import 'formula_expression.dart';

/// Bridges [FormulaExpression] (a pure evaluator that knows nothing about
/// this app) to real rows and real [FieldConfig] metadata -- Essentials v2
/// Phase 2 build order step 6.
///
/// ## Where a formula value actually comes from
///
/// A `formula` field is a normal `field_definitions` row with a normal
/// physical `TEXT` column, exactly like every other v2 field -- but that
/// column is **never written**. [FieldConfig.readOnly] is `true` for it
/// (set by `SchemaRegistry`), and both write paths already skip readOnly
/// fields (`GenericFormScreen._currentValues` and
/// `GenericListScreen._onGridChanged`). The value the user sees is
/// computed here, at read time, and merged into the row by
/// [GenericDao.getAll].
///
/// **Why keep a physical column that's always NULL** rather than skipping
/// the `ALTER TABLE`: the architecture's stated north star is that
/// "changing a field's format is metadata-only" (see
/// claude/essentials-v2-architecture.md). Give formula fields no column
/// and switching an existing `text` field to `formula` would need a
/// destructive `DROP COLUMN`, and switching back an `ADD COLUMN` --
/// turning a metadata edit into real, irreversible DDL. An unused column
/// is a small, honest price for keeping format changes free. It also
/// means `SchemaRegistry`'s physical-column validation needs no formula
/// exception.
///
/// **The one real consequence, worth knowing:** the *stored* column stays
/// NULL, so anything reading raw SQL rather than going through
/// [GenericDao.getAll] sees nothing. Concretely, a `table_definitions
/// .order_by` naming a formula column would sort by NULLs. Grid sorting,
/// filtering, footer aggregates and CSV export are all unaffected -- they
/// operate on the cell values [GenericDao.getAll] already populated.
class FormulaService {
  FormulaService._();

  /// `field_definitions.format` for a formula field.
  static const String formatName = 'formula';

  /// `options.resultType` values. Numeric is the default when unset --
  /// arithmetic is the dominant case and the design doc's own example
  /// (`{cost} * {quantity}`) is numeric.
  static const String resultTypeNumber = 'number';
  static const String resultTypeText = 'text';

  /// Default decimal places for a numeric result when `options.decimals`
  /// is unset -- matches `real`'s own default (see
  /// `GenericListScreen._decimalsFor`), so a formula column and a plain
  /// decimal column display consistently side by side.
  static const int defaultDecimals = 2;

  static bool isFormulaField(FieldConfig field) => field.format == formatName;

  static bool hasFormulaFields(List<FieldConfig> fields) => fields.any(isFormulaField);

  /// `false` when `options.resultType` is `'text'` -- drives both the
  /// [FieldType] `SchemaRegistry` gives the field and whether
  /// [isNumericField] treats it as a number when *another* formula
  /// references it.
  static bool producesNumber(FieldConfig field) =>
      (field.options['resultType'] as String?) != resultTypeText;

  /// Parsed form of `options.expression`, or `null` if it's missing or
  /// malformed. Cached by source text -- parsing is pure, expressions are
  /// few and user-authored, and [GenericDao.getAll] would otherwise
  /// re-parse the same string once per row.
  static FormulaExpression? expressionFor(FieldConfig field) {
    final source = field.options['expression'] as String?;
    if (source == null || source.trim().isEmpty) return null;
    return _parseCache.putIfAbsent(source, () => FormulaExpression.tryParse(source));
  }

  static final Map<String, FormulaExpression?> _parseCache = {};

  /// [row] with every formula field's computed value merged in, or [row]
  /// itself when the table has no formula fields (the overwhelmingly
  /// common case -- deliberately allocation-free there).
  static Map<String, Object?> applyTo(List<FieldConfig> fields, Map<String, Object?> row) {
    if (!hasFormulaFields(fields)) return row;
    return {...row, ...computeAll(fields, row)};
  }

  /// Every formula field's computed value, keyed by column. [row] supplies
  /// the non-formula field values; formula fields referencing *other*
  /// formula fields are resolved recursively, so a chain like
  /// `total = {subtotal} + {tax}` works without the caller ordering
  /// anything.
  ///
  /// A reference cycle (`{a}` -> `{b}` -> `{a}`) resolves to `null` at the
  /// point the cycle closes rather than recursing forever -- no UI exists
  /// to warn about one at authoring time yet (the Add Field screen can't
  /// know what a *future* field will reference), so failing quietly and
  /// safely beats a stack overflow in a grid.
  static Map<String, Object?> computeAll(List<FieldConfig> fields, Map<String, Object?> row) {
    final byColumn = <String, FieldConfig>{for (final field in fields) field.column: field};
    final computed = <String, Object?>{};
    final inProgress = <String>{};

    late final FormulaFieldResolver resolve;

    Object? evaluate(FieldConfig field) {
      if (computed.containsKey(field.column)) return computed[field.column];
      if (!inProgress.add(field.column)) return null; // cycle
      try {
        final value = expressionFor(field)?.evaluate(resolve);
        final result = value is num ? roundFormulaNum(value, decimalsFor(field)) : value;
        computed[field.column] = result;
        return result;
      } finally {
        inProgress.remove(field.column);
      }
    }

    resolve = (name) {
      final field = byColumn[name];
      if (field != null && isFormulaField(field)) return evaluate(field);
      return typedValue(field, row[name]);
    };

    for (final field in fields) {
      if (isFormulaField(field)) evaluate(field);
    }
    return computed;
  }

  /// [computeAll], but with each value rendered as the text the form
  /// should show -- used for [TableConfig.computePreview], which feeds a
  /// readOnly `TextFormField` rather than a typed grid cell.
  ///
  /// Worth the separate entry point: a numeric result like `3.0` would
  /// otherwise reach the form as the literal string "3.0" (via
  /// `toString()`) while the *grid* shows "3.00" for the same value, since
  /// the grid column formats it through `TrinaColumnType.number` with the
  /// field's own `options.decimals`. Formatting here keeps the two views
  /// of one value identical instead of subtly different.
  static Map<String, Object?> computeAllForDisplay(
    List<FieldConfig> fields,
    Map<String, Object?> row,
  ) {
    final byColumn = <String, FieldConfig>{for (final field in fields) field.column: field};
    return {
      for (final entry in computeAll(fields, row).entries)
        entry.key: _displayText(byColumn[entry.key], entry.value),
    };
  }

  static String _displayText(FieldConfig? field, Object? value) {
    if (value is num && field != null && producesNumber(field)) {
      return value.toStringAsFixed(decimalsFor(field));
    }
    return formulaToText(value);
  }

  static int decimalsFor(FieldConfig field) {
    final raw = field.options['decimals'];
    if (raw is int) return raw;
    return int.tryParse(raw?.toString() ?? '') ?? defaultDecimals;
  }

  /// Whether a `{reference}` to [field] should evaluate as a number.
  ///
  /// Checking [FieldConfig.type] alone is **not** enough, and this is the
  /// subtle part: `currency`/`percentage`/`rating` are all unrecognized by
  /// `SchemaRegistry._formatToFieldType` and therefore carry
  /// [FieldType.text] (their real behaviour lives in a
  /// `FieldFormatHandler`, not the type enum -- see
  /// claude/essentials-v2-phase2-design.md's "Key decision"). Without the
  /// format check below, `{cost} * 2` on a currency field would compare
  /// and multiply as text.
  static bool isNumericField(FieldConfig field) {
    if (field.type == FieldType.integer || field.type == FieldType.real) return true;
    if (isFormulaField(field)) return producesNumber(field);
    return const {'currency', 'percentage', 'rating'}.contains(field.format);
  }

  /// [raw] (a physically-`TEXT` column value, so almost always a `String`)
  /// as the Dart type [field] semantically holds. [field] is `null` for a
  /// reference to something that isn't a [TableConfig.fields] entry --
  /// `{id}` being the realistic case -- in which case the value passes
  /// through as-is.
  static Object? typedValue(FieldConfig? field, Object? raw) {
    if (raw == null) return null;
    if (field == null) return raw;
    if (isNumericField(field)) {
      return raw is num ? raw : num.tryParse(raw.toString().trim());
    }
    if (field.type == FieldType.boolean) {
      return raw == 1 || raw == true || raw == '1';
    }
    return raw is String ? raw : raw.toString();
  }
}
