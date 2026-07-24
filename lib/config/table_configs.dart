import '../db/database_helper.dart';
import '../db/table_discovery_service.dart';
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

/// `subscription` -- CLAUDE.md "Table Discovery phase" Part E.3, the last
/// table converted and the only one that keeps *any* hand-written Dart,
/// for its two genuine exceptions (neither expressible as data):
///
/// 1. `payment_method_id` resolves against `account.code`, not the
///    default-heuristic `account.name` -- a real `field_metadata` row
///    (`tool/seed_field_metadata_subscription.dart`, already run), same as
///    `shipment`'s reserved-sentinel rows, not Dart. Every other field
///    (labels including `used_by_id` -> "Used By" and `renewal_period_id`
///    -> "Renewal Period", `active`'s real `DEFAULT 1`, displayColumn/
///    orderBy both resolving to `name`) already matches introspection's
///    heuristics -- see `test/subscription_conversion_regression_test.dart`.
/// 2. `yearly_cost`/`next_date` are query-time-only columns on the
///    `subscription_computed` VIEW (schema.sql) -- `PRAGMA
///    table_info(subscription)` can never see them, since they don't exist
///    on the real table. [buildSubscriptionConfig] introspects the real
///    `subscription` table for everything else, then injects these two as
///    hand-written `readOnly` [FieldConfig]s at the same position they
///    held before conversion (right after `cost`/`start_date`, matching
///    `subscription_computed`'s column order) and points [TableConfig
///    .readSource] at the view. [_computeSubscriptionPreview] (Dart code,
///    inherently not data) still supplies the form's live pre-save preview.
const String subscriptionTableName = 'subscription';

Future<TableConfig> buildSubscriptionConfig(TableDiscoveryService discovery) async {
  final base = await discovery.buildConfig(subscriptionTableName);
  final fields = [
    for (final field in base.fields) ...[
      field,
      if (field.column == 'cost')
        const FieldConfig(column: 'yearly_cost', label: 'Yearly Cost', type: FieldType.real, readOnly: true),
      if (field.column == 'start_date')
        const FieldConfig(column: 'next_date', label: 'Next Date', type: FieldType.date, readOnly: true),
    ],
  ];
  return TableConfig(
    tableName: base.tableName,
    displayColumn: base.displayColumn,
    orderBy: base.orderBy,
    readSource: 'subscription_computed',
    computePreview: _computeSubscriptionPreview,
    fields: fields,
  );
}

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

