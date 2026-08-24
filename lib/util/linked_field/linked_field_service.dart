import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../../db/schema_registry.dart';
import '../../models/table_config.dart';
import '../formula/formula_expression.dart';
import '../formula/formula_service.dart';
import '../link_record.dart';
import '../sql_identifiers.dart';

/// Computes `lookup`/`rollup` field values at read time by resolving a
/// sibling `link_record` field's stored ids against the target table --
/// Essentials v2 Phase 4 build order step 2 (see
/// claude/essentials-v2-phase4-design.md, "`lookup` and `rollup` -- read
/// -only, computed at read time").
///
/// ## Relationship to [FormulaService]
///
/// Deliberately the same shape: a `lookup`/`rollup` field is a normal
/// `field_definitions` row with a normal physical `TEXT` column that is
/// **never written** ([FieldConfig.readOnly] is `true`, set by
/// `SchemaRegistry`, and both write paths already skip readOnly fields),
/// its value computed on the way out of [GenericDao.getAll] and previewed
/// live in the form via [TableConfig.computePreview]. Every argument
/// [FormulaService]'s own doc comment makes for keeping an always-NULL
/// physical column applies here unchanged.
///
/// **The one structural difference:** [FormulaService] is entirely
/// synchronous -- a formula only ever references values already present in
/// the row it's handed. A `lookup`/`rollup` has to read *another table's*
/// rows, so every entry point here is `async` and takes a [CrdtApi]. That
/// also makes an N+1 query trap real in a way it never was for formulas,
/// hence [applyToAll] (batch every row's target-row lookups into one query
/// per target table) rather than a per-row `applyTo`.
///
/// **Never call these from inside a `crdt.transaction`.** Target-table
/// field metadata is resolved through [SchemaRegistry], which opens its own
/// handle on the parent `SqliteCrdt` -- `sql_crdt`'s own `transaction()`
/// doc comment warns that calling back into the parent from inside a
/// transaction deadlocks (a real 30-second hang this project already hit
/// once, see CLAUDE.md "Syncing at the Record Level" Part D). Both real
/// call sites ([GenericDao.getAll] and `computePreview`) are outside any
/// transaction.
///
/// ## Graceful with bad metadata, always
///
/// Every resolution step can fail against real data -- a `link_field` that
/// names a field that no longer exists, a `source_field` that isn't on the
/// target table, a target table dropped outside the schema engine, a
/// `lookup` whose sibling link field was switched to another format. All of
/// them degrade to `null` (blank cell), never an exception: this runs on
/// the read path for every grid load, and one bad field definition must not
/// be able to blank -- or crash -- a whole table.
class LinkedFieldService {
  LinkedFieldService._();

  /// `field_definitions.format` values this service owns.
  static const String lookupFormat = 'lookup';
  static const String rollupFormat = 'rollup';

  /// `options.aggregate` values for a `rollup` (design doc: "one of
  /// `sum | avg | min | max | count`"). [aggregateCount] is the one that
  /// ignores `source_field` entirely.
  static const String aggregateSum = 'sum';
  static const String aggregateAvg = 'avg';
  static const String aggregateMin = 'min';
  static const String aggregateMax = 'max';
  static const String aggregateCount = 'count';

  static const Set<String> aggregates = {
    aggregateSum,
    aggregateAvg,
    aggregateMin,
    aggregateMax,
    aggregateCount,
  };

  /// Default when `options.aggregate` is missing or unrecognized -- matches
  /// the design doc's own "`_canSubmit` ... `rollup` also needs an
  /// aggregate chosen (default to `sum`)".
  static const String defaultAggregate = aggregateSum;

  /// Separator for a multi-valued `lookup`'s joined display value -- the
  /// design doc's own choice ("join every linked record's `source_field`
  /// value with `', '`, in the same order the link array stores them").
  static const String joinSeparator = ', ';

  /// SQLite's default `SQLITE_MAX_VARIABLE_NUMBER` is 999; batching target
  /// -row fetches well under that keeps a table linking to hundreds of rows
  /// from failing outright on the `id IN (...)` list.
  static const int _idBatchSize = 400;

  static bool isLookupField(FieldConfig field) => field.format == lookupFormat;

  static bool isRollupField(FieldConfig field) => field.format == rollupFormat;

  static bool isLinkedComputedField(FieldConfig field) =>
      isLinkedComputedFormat(field.format ?? '');

  /// [isLinkedComputedField] against a raw `field_definitions.format`
  /// string, for `SchemaRegistry._buildField` (which decides `readOnly`/
  /// `required` before any [FieldConfig] exists yet).
  static bool isLinkedComputedFormat(String format) =>
      format == lookupFormat || format == rollupFormat;

  /// Mirrors [FormulaService.hasFormulaFields] -- the cheap gate every
  /// caller checks before doing any work at all.
  static bool hasLinkedComputedFields(List<FieldConfig> fields) =>
      fields.any(isLinkedComputedField);

  /// Whether [field]'s computed value should be treated (and displayed) as
  /// a number.
  ///
  /// **The default deliberately differs by format**, unlike
  /// [FormulaService.producesNumber]'s single numeric default. A `rollup`
  /// is an aggregate -- numeric unless explicitly set to text. A `lookup`
  /// produces the *joined display text* of one or more linked records
  /// (design doc: "join ... with `', '`"), so defaulting it to numeric
  /// would render a comma-joined string inside a
  /// `TrinaColumnType.number` column -- broken out of the box for the
  /// format's own documented behaviour. `options.resultType: 'number'`
  /// still opts a single-valued `lookup` of a numeric field into numeric
  /// rendering explicitly.
  static bool producesNumber(FieldConfig field) =>
      producesNumberFor(field.format ?? '', field.options);

  /// [producesNumber] against a raw `field_definitions` row's format/options
  /// -- so `SchemaRegistry._formatToFieldType` can decide a field's
  /// [FieldType] from the same single source of truth, before any
  /// [FieldConfig] exists to pass in. The [FieldType] the grid renders and
  /// the value this service computes must never disagree.
  static bool producesNumberFor(String format, Map<String, Object?> options) {
    final resultType = options['resultType'] as String?;
    if (format == rollupFormat) return resultType != FormulaService.resultTypeText;
    return resultType == FormulaService.resultTypeNumber;
  }

  /// Decimal places for a numeric result -- same `options.decimals` key and
  /// same default as [FormulaService.decimalsFor], reused directly so a
  /// `rollup` column and a `formula`/`real` column side by side display
  /// consistently.
  static int decimalsFor(FieldConfig field) => FormulaService.decimalsFor(field);

  /// [rows] with every `lookup`/`rollup` field's computed value merged in,
  /// or [rows] itself untouched when [fields] has none (the common case --
  /// deliberately allocation-free there, matching
  /// [FormulaService.applyTo]'s own no-op property).
  ///
  /// Batched, not per-row: every distinct `(target table, id)` needed
  /// across *all* rows and *all* linked-computed fields is collected first,
  /// then fetched with one `id IN (...)` query per target table (chunked at
  /// [_idBatchSize]). This matters -- [GenericDao.getAll] runs on every
  /// grid load, and the naive per-row shape would be one query per row per
  /// field.
  static Future<List<Map<String, Object?>>> applyToAll(
    CrdtApi crdt,
    List<FieldConfig> fields,
    List<Map<String, Object?>> rows, {
    SchemaRegistry? registry,
  }) async {
    if (!hasLinkedComputedFields(fields)) return rows;
    if (rows.isEmpty) return rows;

    final plan = await _buildPlan(crdt, fields, registry);
    if (plan.isEmpty) return rows;

    final cache = await _fetchTargetRows(crdt, plan, rows);
    return [
      for (final row in rows) {...row, ..._computeWithPlan(plan, row, cache)},
    ];
  }

  /// Every `lookup`/`rollup` field's raw computed value for one row's worth
  /// of values, keyed by column -- the single-row equivalent of
  /// [applyToAll], and the raw-value half of [computeAllForDisplay].
  ///
  /// Exposed separately so `SchemaRegistry`'s `computePreview` closure can
  /// merge these raw values into what it hands [FormulaService] -- letting
  /// a `formula` reference a `rollup` column and see a real `num`, not a
  /// pre-formatted display string.
  static Future<Map<String, Object?>> computeAll(
    CrdtApi crdt,
    List<FieldConfig> fields,
    Map<String, Object?> values, {
    SchemaRegistry? registry,
  }) async {
    if (!hasLinkedComputedFields(fields)) return const {};
    final plan = await _buildPlan(crdt, fields, registry);
    if (plan.isEmpty) return const {};
    final cache = await _fetchTargetRows(crdt, plan, [values]);
    return _computeWithPlan(plan, values, cache);
  }

  /// [computeAll], with each value rendered as the text the form should
  /// show -- the direct analogue of [FormulaService.computeAllForDisplay],
  /// and for the same reason: a numeric result like `3.0` would otherwise
  /// reach the form's readOnly `TextFormField` as the literal string "3.0"
  /// while the *grid* shows "3.00" for the same value (the grid column
  /// formats it through `TrinaColumnType.number` with the field's own
  /// `options.decimals`). Formatting here keeps the two views of one value
  /// identical instead of subtly different.
  static Future<Map<String, Object?>> computeAllForDisplay(
    CrdtApi crdt,
    List<FieldConfig> fields,
    Map<String, Object?> values, {
    SchemaRegistry? registry,
  }) async =>
      displayTexts(fields, await computeAll(crdt, fields, values, registry: registry));

  /// [computed]'s raw values rendered as display text -- split out of
  /// [computeAllForDisplay] so a caller that already has the raw map (e.g.
  /// `SchemaRegistry`'s `computePreview`, which needs the raw values for
  /// [FormulaService] too) doesn't have to compute everything twice.
  static Map<String, Object?> displayTexts(
    List<FieldConfig> fields,
    Map<String, Object?> computed,
  ) {
    final byColumn = <String, FieldConfig>{for (final field in fields) field.column: field};
    return {
      for (final entry in computed.entries)
        entry.key: _displayText(byColumn[entry.key], entry.value),
    };
  }

  static String _displayText(FieldConfig? field, Object? value) {
    if (value is num && field != null && producesNumber(field)) {
      return value.toStringAsFixed(decimalsFor(field));
    }
    return formulaToText(value);
  }

  // ===================================================================
  // Plan building -- done once per call, never per row.
  // ===================================================================

  /// One resolvable `lookup`/`rollup` field. A field whose metadata can't
  /// be resolved (no `link_field`, the named field isn't a `link_record`
  /// field on this table, a `rollup` with no `source_field` for a
  /// non-`count` aggregate) is simply absent from the plan -- and therefore
  /// never gets a computed value, leaving its cell blank. Silent by design:
  /// see this class's doc comment.
  static Future<List<_LinkedComputation>> _buildPlan(
    CrdtApi crdt,
    List<FieldConfig> fields,
    SchemaRegistry? registry,
  ) async {
    final byColumn = <String, FieldConfig>{for (final field in fields) field.column: field};
    final resolver = registry ?? SchemaRegistry();
    final targetConfigs = <String, TableConfig?>{};

    final plan = <_LinkedComputation>[];
    for (final field in fields) {
      if (!isLinkedComputedField(field)) continue;

      final linkColumn = field.options['link_field'] as String?;
      if (linkColumn == null) continue;
      final linkField = byColumn[linkColumn];
      // Must be a real `link_record` field on THIS table -- a `lookup`
      // pointing at a `select`/linked field (or at a plain text column, or
      // at nothing) has no JSON id array to resolve.
      if (linkField == null || !linkField.isLinkRecord) continue;

      final targetTable = linkField.linkRecord!.table;
      if (!isSafeSqlIdentifier(targetTable)) continue;

      final sourceColumn = field.options['source_field'] as String?;
      final aggregate = isRollupField(field) ? _aggregateFor(field) : null;
      final needsSource = aggregate != aggregateCount;
      if (needsSource && (sourceColumn == null || !isSafeSqlIdentifier(sourceColumn))) {
        continue;
      }

      // Resolve the target table's own FieldConfig for `source_field`, so
      // numeric coercion below knows whether it's looking at a number.
      // Cached per target table -- several lookup/rollup fields commonly
      // share one link field, and buildConfig is not cheap.
      FieldConfig? sourceField;
      if (sourceColumn != null) {
        if (!targetConfigs.containsKey(targetTable)) {
          try {
            targetConfigs[targetTable] = await resolver.buildConfig(targetTable);
          } catch (_) {
            // Target table dropped, never created through the schema
            // engine, or its metadata hasn't synced to this device yet
            // (SchemaValidationException). Not this method's job to
            // reconcile drift -- see SchemaRegistry's own doc comment.
            targetConfigs[targetTable] = null;
          }
        }
        final targetConfig = targetConfigs[targetTable];
        if (targetConfig == null) continue;
        for (final candidate in targetConfig.fields) {
          if (candidate.column == sourceColumn) {
            sourceField = candidate;
            break;
          }
        }
        // `source_field` naming something that isn't a declared field is
        // only legitimate for `id` (the one real column that is never a
        // FieldConfig entry) -- anything else is stale metadata and yields
        // a blank cell rather than a guess.
        if (sourceField == null && sourceColumn != 'id') continue;
      }

      plan.add(
        _LinkedComputation(
          field: field,
          linkColumn: linkColumn,
          targetTable: targetTable,
          sourceColumn: sourceColumn,
          aggregate: aggregate,
          sourceField: sourceField,
        ),
      );
    }
    return plan;
  }

  static String _aggregateFor(FieldConfig field) {
    final raw = (field.options['aggregate'] as String?)?.trim().toLowerCase();
    if (raw != null && aggregates.contains(raw)) return raw;
    return defaultAggregate;
  }

  // ===================================================================
  // Target-row fetching -- one query per target table, chunked.
  // ===================================================================

  /// `{target table: {id: row}}` for every live target row any of [rows]
  /// links to through any field in [plan]. Soft-deleted target rows are
  /// simply absent, which is exactly the design doc's requirement that a
  /// deleted linked row drops out of both `lookup` display and `rollup`
  /// aggregates -- no per-row filtering needed downstream.
  static Future<Map<String, Map<int, Map<String, Object?>>>> _fetchTargetRows(
    CrdtApi crdt,
    List<_LinkedComputation> plan,
    List<Map<String, Object?>> rows,
  ) async {
    final wanted = <String, Set<int>>{};
    for (final computation in plan) {
      final ids = wanted.putIfAbsent(computation.targetTable, () => <int>{});
      for (final row in rows) {
        ids.addAll(parseLinkedIds(row[computation.linkColumn]));
      }
    }

    final cache = <String, Map<int, Map<String, Object?>>>{};
    for (final entry in wanted.entries) {
      final table = entry.key;
      final byId = <int, Map<String, Object?>>{};
      cache[table] = byId;
      if (entry.value.isEmpty) continue;
      assertSafeSqlIdentifier(table);

      final ids = entry.value.toList();
      for (var start = 0; start < ids.length; start += _idBatchSize) {
        final batch = ids.sublist(
          start,
          start + _idBatchSize < ids.length ? start + _idBatchSize : ids.length,
        );
        final placeholders = List.generate(batch.length, (i) => '?${i + 1}').join(', ');
        List<Map<String, Object?>> fetched;
        try {
          fetched = await crdt.query(
            'SELECT * FROM "$table" WHERE is_deleted = 0 AND id IN ($placeholders)',
            batch,
          );
        } on DatabaseException {
          // The target table no longer physically exists -- same stale
          // -metadata case GenericDao.findBlockingReferences already
          // tolerates. Leaves this table's cache empty; every lookup
          // against it resolves to blank.
          break;
        }
        for (final row in fetched) {
          final id = row['id'];
          if (id is int) byId[id] = row;
        }
      }
    }
    return cache;
  }

  // ===================================================================
  // Per-row computation.
  // ===================================================================

  static Map<String, Object?> _computeWithPlan(
    List<_LinkedComputation> plan,
    Map<String, Object?> row,
    Map<String, Map<int, Map<String, Object?>>> cache,
  ) {
    final computed = <String, Object?>{};
    for (final computation in plan) {
      final ids = parseLinkedIds(row[computation.linkColumn]);
      final byId = cache[computation.targetTable] ?? const {};
      // Order preserved from the stored array, and soft-deleted/missing
      // target rows dropped -- both per the design doc.
      final linked = <Map<String, Object?>>[
        for (final id in ids)
          if (byId[id] != null) byId[id]!,
      ];
      computed[computation.field.column] = computation.aggregate == null
          ? _lookupValue(computation, linked)
          : _rollupValue(computation, linked);
    }
    return computed;
  }

  /// Every linked row's `source_field` value, joined with
  /// [joinSeparator] in link-array order. `null` (blank cell) when nothing
  /// is linked or every linked value is blank -- deliberately not an empty
  /// string, so a `lookup` column reads the same as any other empty cell.
  ///
  /// Uses each value's raw stored text rather than routing it through
  /// [FormulaService.typedValue] first: the stored TEXT is already exactly
  /// what that field's own column displays elsewhere (a `date` field's
  /// ISO8601 string, a `currency` field's own decimal text), so passing it
  /// through unchanged is both lossless and consistent with how the target
  /// table itself shows the same value.
  static Object? _lookupValue(_LinkedComputation computation, List<Map<String, Object?>> linked) {
    final parts = <String>[];
    for (final target in linked) {
      final raw = target[computation.sourceColumn];
      if (raw == null) continue;
      final text = raw is String ? raw : raw.toString();
      if (text.trim().isEmpty) continue;
      parts.add(text);
    }
    if (parts.isEmpty) return null;
    final joined = parts.join(joinSeparator);
    // A resultType: 'number' lookup (an explicit opt-in, never the
    // default -- see [producesNumber]) should reach the grid as a real num
    // so its column can right-align and format it.
    if (producesNumber(computation.field)) {
      final value = num.tryParse(joined.trim());
      if (value == null) return null;
      return roundFormulaNum(value, decimalsFor(computation.field));
    }
    return joined;
  }

  /// The aggregate across every linked row's `source_field` value.
  ///
  /// `count` counts *live linked records* and ignores `source_field`
  /// entirely -- so it works on a table with nothing numeric to sum at all
  /// ("how many tasks does this project have").
  ///
  /// For `sum`/`avg`/`min`/`max`, a linked row whose value is missing or
  /// non-numeric is **skipped**, not treated as zero -- the design doc's
  /// explicit requirement. A `rollup` pointed at a genuinely non-numeric
  /// field therefore aggregates nothing and yields `null`, matching the
  /// same doc's "just yields 'nothing summed'".
  ///
  /// **Judgment call, flagged:** an empty contribution set yields `null`
  /// (blank cell), not `0`. A spreadsheet's `SUM` of an empty range is
  /// conventionally `0`, but returning `0` here would directly contradict
  /// the design doc's "not treated as zero" instruction, and would show a
  /// confident "0.00" for a row that has nothing linked at all -- blank is
  /// the more honest rendering, and matches how every other computed field
  /// in this app (`formula`) already handles missing inputs.
  static Object? _rollupValue(_LinkedComputation computation, List<Map<String, Object?>> linked) {
    if (computation.aggregate == aggregateCount) {
      return _round(computation, linked.length);
    }

    final values = <num>[];
    for (final target in linked) {
      final value = _numericValue(computation, target[computation.sourceColumn]);
      if (value != null) values.add(value);
    }
    if (values.isEmpty) return null;

    return switch (computation.aggregate) {
      aggregateAvg => _round(
        computation,
        values.reduce((a, b) => a + b) / values.length,
      ),
      aggregateMin => _round(computation, values.reduce((a, b) => a < b ? a : b)),
      aggregateMax => _round(computation, values.reduce((a, b) => a > b ? a : b)),
      _ => _round(computation, values.reduce((a, b) => a + b)),
    };
  }

  /// [raw] as a `num`, or `null` if this source field isn't numeric at all
  /// or this particular value doesn't parse.
  ///
  /// Delegates the "is this field numeric" question to
  /// [FormulaService.isNumericField] rather than re-deriving it, because
  /// the answer is genuinely subtle and already solved there:
  /// `currency`/`percentage`/`rating` all carry [FieldType.text] (their
  /// real behaviour lives in a `FieldFormatHandler`, not the type enum), so
  /// checking [FieldConfig.type] alone would silently refuse to sum a
  /// currency column -- exactly the bug that method's own doc comment
  /// exists to prevent.
  static num? _numericValue(_LinkedComputation computation, Object? raw) {
    if (raw == null) return null;
    final field = computation.sourceField;
    if (field == null) {
      // `source_field: 'id'` -- the one real column that is never a
      // FieldConfig entry (see _buildPlan). Always an integer.
      return raw is num ? raw : num.tryParse(raw.toString().trim());
    }
    if (!FormulaService.isNumericField(field)) return null;
    final typed = FormulaService.typedValue(field, raw);
    return typed is num ? typed : null;
  }

  static num _round(_LinkedComputation computation, num value) =>
      roundFormulaNum(value, decimalsFor(computation.field));
}

/// One fully-resolved `lookup`/`rollup` field, built once per
/// [LinkedFieldService] call rather than per row.
class _LinkedComputation {
  _LinkedComputation({
    required this.field,
    required this.linkColumn,
    required this.targetTable,
    required this.sourceColumn,
    required this.aggregate,
    required this.sourceField,
  });

  /// The `lookup`/`rollup` field itself -- its own column is what gets the
  /// computed value, and its `options` carry `resultType`/`decimals`.
  final FieldConfig field;

  /// The sibling `link_record` column on the *same* table holding the JSON
  /// id array.
  final String linkColumn;

  /// [LinkRecordConfig.table] -- where the linked rows live.
  final String targetTable;

  /// Column read on each linked row. `null` only for a `count` rollup.
  final String? sourceColumn;

  /// `null` for a `lookup`; one of [LinkedFieldService.aggregates] for a
  /// `rollup`. Doubles as the lookup-vs-rollup discriminator.
  final String? aggregate;

  /// [sourceColumn]'s own [FieldConfig] on the *target* table, needed for
  /// correct numeric coercion. `null` when [sourceColumn] is `id` (never a
  /// declared field).
  final FieldConfig? sourceField;
}
