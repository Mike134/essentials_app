import '../models/table_config.dart';

/// Batch 1 -- no lookups, proves the base template + navigation.
/// See CLAUDE.md "Build sequence" for the full batch-1/2/3 ordering.
const domainConfig = TableConfig(
  tableName: 'domain',
  displayColumn: 'name',
  orderBy: 'position, name',
  fields: [
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

/// All tables with a registered [TableConfig], in nav-menu order. Just
/// `domain` for now -- the other nine batch-1 tables are a config each,
/// not new architecture.
const List<TableConfig> registeredTables = [domainConfig];
