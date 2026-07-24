import '../db/database_helper.dart';
import '../models/table_config.dart';

/// Batch 1 (`domain`, `priority`, `gender`, `status`, `quality`,
/// `condition`, `unit`, `importance`, `disposition`, `class`) retired onto
/// the discovery mechanism -- CLAUDE.md "Table Discovery phase" Part E.1.
/// `TableDiscoveryService`'s introspection heuristics reproduce every one
/// of these tables' shape exactly with zero hand-written config: `name`/
/// `description`/`abbreviation`/`definition` labels title-case correctly,
/// `active`'s boolean default comes straight from its real SQL `DEFAULT 1`,
/// `displayColumn`/`orderBy` both resolve to `name`/`position, name` via
/// the `position`-column heuristic. Only `position` and `color` needed a
/// seeded `field_metadata` row each (`tool/seed_field_metadata_batch1.dart`,
/// already run against the real db) -- neither has a real SQL `DEFAULT` in
/// schema.sql, so introspection alone would leave them null instead of the
/// `255`/`#FFFFFF` these tables always started new rows at. See
/// `test/batch1_conversion_regression_test.dart` for the full comparison
/// against this file's pre-conversion shape.

/// Batch 2 (`person`, `category`, `time_frame`, `account_type`, `account`,
/// `supplier`, `shipper`, `shipment`, `journal`) retired onto the discovery
/// mechanism -- CLAUDE.md "Table Discovery phase" Part E.2. Exercised the
/// FK lookup-display-column logic for real (every lookup here resolves
/// against the referenced table's own `name` column, discovered live via
/// `PRAGMA foreign_key_list` -- no hand-written `LookupConfig` needed for
/// any of them) and caught a real bug before it shipped: the discovery
/// service was forcing every lookup field to `required: false` regardless
/// of nullability, which would have silently dropped `time_frame.unit_id`'s
/// required validation.
///
/// `journal` needed zero `field_metadata` overrides -- every heuristic
/// (including `entry_time` as displayColumn and `entry_time DESC` as
/// orderBy, since journal has no `name` column) already reproduced its
/// exact pre-conversion shape. `shipment` is the one real exception: no
/// `name` column and no `NOT NULL` column at all, so its displayColumn/
/// orderBy use the reserved `field_metadata` sentinel field names
/// (`_display_column`/`_order_by` -- see `table_discovery_service.dart`)
/// to carry the original `order_id`/`order_date DESC, id DESC` forward.
/// Seeded via `tool/seed_field_metadata_batch2.dart` (already run against
/// the real db); see `test/batch2_conversion_regression_test.dart` for the
/// full comparison against this file's pre-conversion shape.

/// Batch 3 -- 7 FK fields, but by this point that's just a longer config on
/// the same lookup-field shape batch 2 already proved, not new architecture.
/// `readSource` points reads at the `subscription_computed` view (see
/// schema.sql) instead of the bare table, so `yearly_cost`/`next_date` --
/// computed at query time, never stored -- come back alongside the real
/// columns; both are marked `readOnly` since there's no column to write.
final subscriptionConfig = TableConfig(
  tableName: 'subscription',
  displayColumn: 'name',
  readSource: 'subscription_computed',
  computePreview: _computeSubscriptionPreview,
  fields: const [
    FieldConfig(column: 'name', label: 'Name', required: true),
    FieldConfig(
      column: 'domain_id',
      label: 'Domain',
      lookup: LookupConfig(table: 'domain'),
    ),
    FieldConfig(
      column: 'used_by_id',
      label: 'Used By',
      lookup: LookupConfig(table: 'person'),
    ),
    FieldConfig(
      column: 'class_id',
      label: 'Class',
      lookup: LookupConfig(table: 'class'),
    ),
    FieldConfig(
      column: 'renewal_period_id',
      label: 'Renewal Period',
      lookup: LookupConfig(table: 'time_frame'),
    ),
    FieldConfig(column: 'cost', label: 'Cost', type: FieldType.real),
    FieldConfig(
      column: 'yearly_cost',
      label: 'Yearly Cost',
      type: FieldType.real,
      readOnly: true,
    ),
    FieldConfig(
      column: 'payment_method_id',
      label: 'Payment Method',
      // account.code (e.g. "CAPONE MC (7072)"), not account.name -- see
      // CLAUDE.md "Known data quirks": this FK was always resolved against
      // code in the source workbook, not the account's display name.
      lookup: LookupConfig(table: 'account', displayColumn: 'code'),
    ),
    FieldConfig(
      column: 'importance_id',
      label: 'Importance',
      lookup: LookupConfig(table: 'importance'),
    ),
    FieldConfig(
      column: 'disposition_id',
      label: 'Disposition',
      lookup: LookupConfig(table: 'disposition'),
    ),
    FieldConfig(column: 'start_date', label: 'Start Date', type: FieldType.date),
    FieldConfig(
      column: 'next_date',
      label: 'Next Date',
      type: FieldType.date,
      readOnly: true,
    ),
    FieldConfig(column: 'last_date', label: 'Last Date', type: FieldType.date),
    FieldConfig(column: 'link', label: 'Link', isLink: true),
    FieldConfig(
      column: 'active',
      label: 'Active',
      type: FieldType.boolean,
      defaultValue: true, // schema.sql: active INTEGER NOT NULL DEFAULT 1
    ),
    FieldConfig(column: 'note', label: 'Note'),
  ],
);

/// Mirrors `subscription_computed`'s formula (schema.sql) in Dart, for the
/// form's live pre-save preview only -- see [TableConfig.computePreview]'s
/// doc comment for why this duplication is an accepted, low-risk tradeoff
/// rather than a single-source-of-truth violation: the real, authoritative
/// value always comes from the view once the row is saved and reloaded.
Future<Map<String, Object?>> _computeSubscriptionPreview(
  Map<String, Object?> values,
) async {
  final cost = values['cost'] as num?;
  final renewalPeriodId = values['renewal_period_id'] as int?;
  final startDateText = values['start_date'] as String?;

  int? multiplier;
  if (renewalPeriodId != null) {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'time_frame',
      columns: ['multiplier'],
      where: 'id = ?',
      whereArgs: [renewalPeriodId],
    );
    if (rows.isNotEmpty) multiplier = rows.first['multiplier'] as int?;
  }

  double? yearlyCost;
  if (cost != null && multiplier != null && multiplier != 0) {
    yearlyCost = double.parse((cost * 12.0 / multiplier).toStringAsFixed(2));
  }

  String? nextDate;
  final startDate = startDateText == null ? null : DateTime.tryParse(startDateText);
  if (startDate != null && multiplier != null) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startDateOnly = DateTime(startDate.year, startDate.month, startDate.day);
    if (startDateOnly.isAfter(today)) {
      nextDate = startDateText;
    } else {
      final monthsElapsed = (today.year - startDate.year) * 12 +
          (today.month - startDate.month) -
          (today.day < startDate.day ? 1 : 0);
      final periodsElapsed = (monthsElapsed ~/ multiplier) + 1;
      final next = _addMonthsClamped(startDate, periodsElapsed * multiplier);
      nextDate = '${next.year.toString().padLeft(4, '0')}-'
          '${next.month.toString().padLeft(2, '0')}-'
          '${next.day.toString().padLeft(2, '0')}';
    }
  }

  return {'yearly_cost': yearlyCost, 'next_date': nextDate};
}

/// Adds [months] to [start], clamping the day to the target month's last
/// valid day rather than rolling over into the following month -- matches
/// SQLite's `date(x, '+N months')` modifier (what subscription_computed
/// actually uses), which Dart's plain `DateTime(y, m, d)` constructor does
/// not do on its own.
DateTime _addMonthsClamped(DateTime start, int months) {
  final totalMonths = (start.year * 12 + start.month - 1) + months;
  final year = totalMonths ~/ 12;
  final month = totalMonths % 12 + 1;
  final lastDayOfMonth = DateTime(year, month + 1, 0).day;
  final day = start.day > lastDayOfMonth ? lastDayOfMonth : start.day;
  return DateTime(year, month, day);
}

/// Tables that still have a hand-written [TableConfig] -- just
/// `subscription` now (batches 1 and 2 are both gone, see this file's
/// top-of-file comments), and only for its two genuine exceptions (the
/// `subscription_computed` read source and `computePreview`), not because
/// its fields need hand-writing. `lib/config/table_registry.dart`'s
/// `loadEffectiveTables` is what actually resolves the full nav list, this
/// entry plus everything discovered.
final List<TableConfig> registeredTables = [subscriptionConfig];
