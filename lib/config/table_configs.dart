import '../models/table_config.dart';

/// Batch 1 -- no lookups, proves the base template + navigation.
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

/// All tables with a registered [TableConfig], in nav-menu order --
/// matches CLAUDE.md's batch-1 ordering exactly.
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
];
