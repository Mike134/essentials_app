import '../db/database_helper.dart';
import '../db/table_discovery_service.dart';
import '../models/table_config.dart';
import '../screens/order_split_pane_screen.dart';

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
    displayName: base.displayName,
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
    final db = await DatabaseHelper.instance.crdt;
    final rows = await db.query(
      'SELECT multiplier FROM time_frame WHERE id = ?1 AND is_deleted = 0',
      [renewalPeriodId],
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

/// `orders`/`order_items` -- CLAUDE.md "Split-Pane Layout" session, Part C.
/// Both tables were created directly in `essentials.db` via Letos (Table
/// Discovery's own precedent target) and resolve through the same
/// introspection + `field_metadata` mechanism as every other table --
/// `order_items` needs no hand-written Dart at all (its two overrides,
/// `order_id`'s `lookup_display_column` and its `_display_column`
/// sentinel, are pure `field_metadata` data, seeded by
/// `tool/seed_field_metadata_order_items.dart`). `orders` keeps exactly
/// two small, explicitly-documented exceptions layered on top of
/// discovery, same category as `subscription`'s two (`readSource`/
/// `computePreview`) -- not a return to hand-written per-table configs:
///
/// 1. [TableConfig.openRowDetail] -- opening an existing order shows
///    [OrderSplitPaneScreen] (order form + its items grid, side-by-side or
///    push-navigated depending on layout width) instead of the default
///    plain form.
/// 2. [TableConfig.deleteWarning] -- names the real cascade consequence
///    (`order_items.order_id` is `ON DELETE CASCADE`) before deleting an
///    order that still has items, rather than a generic "Are you sure?"
///    that hides it.
const String ordersTableName = 'orders';
const String orderItemsTableName = 'order_items';

Future<TableConfig> buildOrdersConfig(TableDiscoveryService discovery) async {
  final base = await discovery.buildConfig(ordersTableName);
  return TableConfig(
    tableName: base.tableName,
    displayName: base.displayName,
    displayColumn: base.displayColumn,
    orderBy: base.orderBy,
    fields: base.fields,
    openRowDetail: (context, config, row) =>
        OrderSplitPaneScreen(orderConfig: config, order: row),
    deleteWarning: _orderDeleteWarning,
  );
}

/// `null` (falls back to [GenericListScreen]'s default "Delete X?" message)
/// when the order has no items -- nothing hidden to call out in that case.
Future<String?> _orderDeleteWarning(Map<String, Object?> row) async {
  final db = await DatabaseHelper.instance.crdt;
  final result = await db.query(
    'SELECT COUNT(*) AS count FROM order_items WHERE order_id = ?1 AND is_deleted = 0',
    [row['id']],
  );
  final count = result.first['count'] as int;
  if (count == 0) return null;
  final itemWord = count == 1 ? 'item' : 'items';
  return 'This order has $count $itemWord. Deleting it will delete them too.';
}

/// Builds `order_items`' config scoped to one parent [orderId] -- reused
/// for both [OrderSplitPaneScreen] layouts (the wide-mode embedded grid and
/// the narrow-mode pushed full-screen list). `order_id` is stripped from
/// [TableConfig.fields] entirely (Part B: never a user-facing field in this
/// embedded context, unlike the standalone `order_items` screen reached
/// via direct nav) -- [GenericListScreen.formExtraValues] supplies it
/// silently on insert instead.
Future<TableConfig> buildOrderItemsConfigForOrder(
  TableDiscoveryService discovery,
  int orderId,
) async {
  final base = await discovery.buildConfig(orderItemsTableName);
  final fields = [
    for (final field in base.fields) if (field.column != 'order_id') field,
  ];
  return TableConfig(
    tableName: base.tableName,
    displayName: base.displayName,
    displayColumn: base.displayColumn,
    orderBy: base.orderBy,
    fields: fields,
    filterWhere: 'order_id = ?',
    filterArgs: [orderId],
  );
}

