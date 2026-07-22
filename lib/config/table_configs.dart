import '../db/database_helper.dart';
import '../models/table_config.dart';

/// Batch 1 configs -- no lookups, prove the base template + navigation.
/// See CLAUDE.md "Build sequence" for the full batch-1/2/3 ordering.
///
/// Eight of the nine batch-1 tables share the exact same shape in
/// schema.sql: `name`, a free-text `description`, and the same
/// `active`/`position`/`color` triple. `unit` is the one exception
/// (`abbreviation`/`definition` instead of `description`) and is defined
/// separately below.
TableConfig _lookupConfig(String tableName) {
  return TableConfig(
    tableName: tableName,
    displayColumn: 'name',
    orderBy: 'position, name',
    fields: const [
      FieldConfig(column: 'name', label: 'Name', required: true),
      FieldConfig(column: 'description', label: 'Description'),
      FieldConfig(
        column: 'active',
        label: 'Active',
        type: FieldType.boolean,
        defaultValue: true, // schema.sql: active INTEGER NOT NULL DEFAULT 1
      ),
      FieldConfig(
        column: 'position',
        label: 'Position',
        type: FieldType.integer,
        defaultValue: 255,
      ),
      FieldConfig(column: 'color', label: 'Color', defaultValue: '#FFFFFF'),
    ],
  );
}

final domainConfig = _lookupConfig('domain');
final priorityConfig = _lookupConfig('priority');
final genderConfig = _lookupConfig('gender');
final statusConfig = _lookupConfig('status');
final qualityConfig = _lookupConfig('quality');
final conditionConfig = _lookupConfig('condition');
final importanceConfig = _lookupConfig('importance');
final dispositionConfig = _lookupConfig('disposition');
final classConfig = _lookupConfig('class');

final unitConfig = TableConfig(
  tableName: 'unit',
  displayColumn: 'name',
  orderBy: 'position, name',
  fields: const [
    FieldConfig(column: 'name', label: 'Name', required: true),
    FieldConfig(column: 'abbreviation', label: 'Abbreviation'),
    FieldConfig(column: 'definition', label: 'Definition'),
    FieldConfig(
      column: 'active',
      label: 'Active',
      type: FieldType.boolean,
      defaultValue: true,
    ),
    FieldConfig(
      column: 'position',
      label: 'Position',
      type: FieldType.integer,
      defaultValue: 255,
    ),
    FieldConfig(column: 'color', label: 'Color', defaultValue: '#FFFFFF'),
  ],
);

/// account_type shares unit's exact shape (abbreviation/definition, no FK)
/// -- kept separate rather than folded into [unitConfig] since it's a
/// distinct table, not a variant of `unit` itself.
final accountTypeConfig = TableConfig(
  tableName: 'account_type',
  displayColumn: 'name',
  orderBy: 'position, name',
  fields: const [
    FieldConfig(column: 'name', label: 'Name', required: true),
    FieldConfig(column: 'abbreviation', label: 'Abbreviation'),
    FieldConfig(column: 'definition', label: 'Definition'),
    FieldConfig(
      column: 'active',
      label: 'Active',
      type: FieldType.boolean,
      defaultValue: true,
    ),
    FieldConfig(
      column: 'position',
      label: 'Position',
      type: FieldType.integer,
      defaultValue: 255,
    ),
    FieldConfig(column: 'color', label: 'Color', defaultValue: '#FFFFFF'),
  ],
);

/// Batch 2 -- introduces the lookup-field variant of [FieldConfig]/
/// [LookupConfig] for the first time. See CLAUDE.md "Build sequence" for
/// the deliberate easiest-first ordering within the batch.
TableConfig _supplierLikeConfig(String tableName) {
  return TableConfig(
    tableName: tableName,
    displayColumn: 'name',
    orderBy: 'position, name',
    fields: const [
      FieldConfig(column: 'name', label: 'Name', required: true),
      FieldConfig(column: 'description', label: 'Description'),
      FieldConfig(column: 'hyperlink', label: 'Hyperlink', isLink: true),
      FieldConfig(
        column: 'active',
        label: 'Active',
        type: FieldType.boolean,
        defaultValue: true,
      ),
      FieldConfig(
        column: 'position',
        label: 'Position',
        type: FieldType.integer,
        defaultValue: 255,
      ),
      FieldConfig(column: 'color', label: 'Color', defaultValue: '#FFFFFF'),
    ],
  );
}

final personConfig = TableConfig(
  tableName: 'person',
  displayColumn: 'name',
  orderBy: 'position, name',
  fields: const [
    FieldConfig(column: 'name', label: 'Name', required: true),
    FieldConfig(column: 'description', label: 'Description'),
    FieldConfig(
      column: 'gender_id',
      label: 'Gender',
      lookup: LookupConfig(table: 'gender'),
    ),
    FieldConfig(
      column: 'active',
      label: 'Active',
      type: FieldType.boolean,
      defaultValue: true,
    ),
    FieldConfig(
      column: 'position',
      label: 'Position',
      type: FieldType.integer,
      defaultValue: 255,
    ),
    FieldConfig(column: 'color', label: 'Color', defaultValue: '#FFFFFF'),
  ],
);

final categoryConfig = TableConfig(
  tableName: 'category',
  displayColumn: 'name',
  orderBy: 'position, name',
  fields: const [
    FieldConfig(column: 'name', label: 'Name', required: true),
    FieldConfig(
      column: 'class_id',
      label: 'Class',
      lookup: LookupConfig(table: 'class'),
    ),
    FieldConfig(column: 'description', label: 'Description'),
    FieldConfig(
      column: 'active',
      label: 'Active',
      type: FieldType.boolean,
      defaultValue: true,
    ),
    FieldConfig(
      column: 'position',
      label: 'Position',
      type: FieldType.integer,
      defaultValue: 255,
    ),
    FieldConfig(column: 'color', label: 'Color', defaultValue: '#FFFFFF'),
  ],
);

final timeFrameConfig = TableConfig(
  tableName: 'time_frame',
  displayColumn: 'name',
  orderBy: 'position, name',
  fields: const [
    FieldConfig(column: 'name', label: 'Name', required: true),
    FieldConfig(
      column: 'unit_id',
      label: 'Unit',
      required: true, // schema.sql: unit_id INTEGER NOT NULL
      lookup: LookupConfig(table: 'unit'),
    ),
    FieldConfig(
      column: 'multiplier',
      label: 'Multiplier',
      type: FieldType.integer,
      required: true, // schema.sql: multiplier INTEGER NOT NULL
    ),
    FieldConfig(column: 'description', label: 'Description'),
    FieldConfig(
      column: 'active',
      label: 'Active',
      type: FieldType.boolean,
      defaultValue: true,
    ),
    FieldConfig(
      column: 'position',
      label: 'Position',
      type: FieldType.integer,
      defaultValue: 255,
    ),
    FieldConfig(column: 'color', label: 'Color', defaultValue: '#FFFFFF'),
  ],
);

final accountConfig = TableConfig(
  tableName: 'account',
  displayColumn: 'name',
  orderBy: 'position, name',
  fields: const [
    FieldConfig(column: 'name', label: 'Name', required: true),
    FieldConfig(column: 'code', label: 'Code'),
    FieldConfig(column: 'institution', label: 'Institution'),
    FieldConfig(
      column: 'account_type_id',
      label: 'Account Type',
      lookup: LookupConfig(table: 'account_type'),
    ),
    FieldConfig(
      column: 'domain_id',
      label: 'Domain',
      lookup: LookupConfig(table: 'domain'),
    ),
    FieldConfig(column: 'notes', label: 'Notes'),
    FieldConfig(
      column: 'active',
      label: 'Active',
      type: FieldType.boolean,
      defaultValue: true,
    ),
    FieldConfig(
      column: 'position',
      label: 'Position',
      type: FieldType.integer,
      defaultValue: 255,
    ),
    FieldConfig(column: 'color', label: 'Color', defaultValue: '#FFFFFF'),
  ],
);

final supplierConfig = _supplierLikeConfig('supplier');
final shipperConfig = _supplierLikeConfig('shipper');

/// No `name`/`active`/`position`/`color` triple -- `shipment` is a
/// transactional table, not a lookup, so [TableConfig.displayColumn] falls
/// back to `order_id` (the closest thing to a human-readable identifier)
/// even though it isn't unique or required.
final shipmentConfig = TableConfig(
  tableName: 'shipment',
  displayColumn: 'order_id',
  orderBy: 'order_date DESC, id DESC',
  fields: const [
    FieldConfig(
      column: 'supplier_id',
      label: 'Supplier',
      lookup: LookupConfig(table: 'supplier'),
    ),
    FieldConfig(column: 'order_date', label: 'Order Date'),
    FieldConfig(column: 'due_date', label: 'Due Date'),
    FieldConfig(column: 'received_date', label: 'Received Date'),
    FieldConfig(
      column: 'domain_id',
      label: 'Domain',
      lookup: LookupConfig(table: 'domain'),
    ),
    FieldConfig(column: 'order_id', label: 'Order ID'),
    FieldConfig(column: 'order_link', label: 'Order Link', isLink: true),
    FieldConfig(
      column: 'shipper_id',
      label: 'Shipper',
      lookup: LookupConfig(table: 'shipper'),
    ),
    FieldConfig(column: 'tracking_id', label: 'Tracking ID'),
    FieldConfig(column: 'tracking_link', label: 'Tracking Link', isLink: true),
    FieldConfig(column: 'items', label: 'Items'),
    FieldConfig(column: 'note', label: 'Note'),
  ],
);

/// `entry_time` (not `entry`, which can be long free text) is the
/// [TableConfig.displayColumn] here -- concise and effectively unique
/// enough for the delete-confirmation label even though schema.sql doesn't
/// enforce uniqueness on it.
final journalConfig = TableConfig(
  tableName: 'journal',
  displayColumn: 'entry_time',
  orderBy: 'entry_time DESC',
  fields: const [
    FieldConfig(column: 'entry_time', label: 'Entry Time', required: true),
    FieldConfig(column: 'entry', label: 'Entry', required: true),
    FieldConfig(column: 'tag', label: 'Tag'),
    FieldConfig(
      column: 'status_id',
      label: 'Status',
      lookup: LookupConfig(table: 'status'),
    ),
    FieldConfig(column: 'location', label: 'Location'),
    FieldConfig(
      column: 'who_id',
      label: 'Who',
      lookup: LookupConfig(table: 'person'),
    ),
    FieldConfig(
      column: 'domain_id',
      label: 'Domain',
      lookup: LookupConfig(table: 'domain'),
    ),
    FieldConfig(column: 'follow_up', label: 'Follow Up'),
    FieldConfig(
      column: 'scheduled',
      label: 'Scheduled',
      type: FieldType.boolean,
      defaultValue: false, // schema.sql: scheduled INTEGER NOT NULL DEFAULT 0
    ),
    FieldConfig(column: 'link', label: 'Link', isLink: true),
    FieldConfig(column: 'image', label: 'Image'),
    FieldConfig(column: 'file', label: 'File'),
    FieldConfig(column: 'latitude', label: 'Latitude', type: FieldType.real),
    FieldConfig(column: 'longitude', label: 'Longitude', type: FieldType.real),
    FieldConfig(column: 'notes', label: 'Notes'),
  ],
);

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
    FieldConfig(column: 'start_date', label: 'Start Date'),
    FieldConfig(column: 'next_date', label: 'Next Date', readOnly: true),
    FieldConfig(column: 'last_date', label: 'Last Date'),
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

/// All tables with a registered [TableConfig], in nav-menu order --
/// matches CLAUDE.md's batch-1/batch-2/batch-3 ordering exactly.
final List<TableConfig> registeredTables = [
  domainConfig,
  priorityConfig,
  genderConfig,
  statusConfig,
  qualityConfig,
  conditionConfig,
  unitConfig,
  importanceConfig,
  dispositionConfig,
  classConfig,
  personConfig,
  categoryConfig,
  timeFrameConfig,
  accountTypeConfig,
  accountConfig,
  supplierConfig,
  shipperConfig,
  shipmentConfig,
  journalConfig,
  subscriptionConfig,
];
