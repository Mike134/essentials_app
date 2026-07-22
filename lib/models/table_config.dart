/// How a [FieldConfig]'s raw SQLite column value should be edited/parsed.
enum FieldType { text, integer, real, boolean }

/// Describes a field that is really a foreign key into another table --
/// the form should render it as a dropdown of that table's rows rather
/// than a free-text box. Not used by any batch-1 table (all lookup-free),
/// but shaped now so batch 2 (`person` -> `gender`, `category` -> `class`,
/// etc.) is just a config addition, not a rework of [TableConfig].
class LookupConfig {
  const LookupConfig({
    required this.table,
    this.displayColumn = 'name',
    this.valueColumn = 'id',
  });

  /// The referenced table, e.g. `gender` for `person.gender_id`.
  final String table;

  /// Column shown to the user in the dropdown (e.g. `name`).
  final String displayColumn;

  /// Column actually stored in the FK column (almost always `id`).
  final String valueColumn;
}

/// One editable column on a [TableConfig]'s table. Excludes `id`, which is
/// always the surrogate primary key and never user-edited.
class FieldConfig {
  const FieldConfig({
    required this.column,
    required this.label,
    this.type = FieldType.text,
    this.required = false,
    this.lookup,
    this.defaultValue,
    this.readOnly = false,
  });

  /// The literal SQLite column name.
  final String column;

  /// Label shown on the form field.
  final String label;

  final FieldType type;

  final bool required;

  /// Value a new (add, not edit) row's field starts at -- e.g. `true` for
  /// a column declared `DEFAULT 1` in schema.sql. The form always writes
  /// an explicit value on insert (never omits a key), so a SQL-side
  /// `DEFAULT` is silently overridden unless mirrored here; this makes
  /// that default visible in the one place ([TableConfig]) that already
  /// drives everything else about the field, rather than an implicit
  /// dependency on whatever the schema happens to say.
  final Object? defaultValue;

  /// Non-null if this column is a foreign key that should render as a
  /// dropdown instead of a plain text/number field.
  final LookupConfig? lookup;

  bool get isLookup => lookup != null;

  /// True for a value computed at query time (e.g. `subscription_computed`'s
  /// `yearly_cost`/`next_date`, per schema.sql) rather than stored as a real
  /// column on [TableConfig.tableName] -- never editable in the grid or
  /// form, and never written on insert/update (there's no column to write).
  final bool readOnly;
}

/// Drives the generic list + form screens for one SQLite table. One config
/// per table; batch 1 tables (no FKs) prove this shape, batch 2 exercises
/// the [FieldConfig.lookup] variant, and `subscription` (7 FK fields) is
/// just a longer config on the same shape.
class TableConfig {
  const TableConfig({
    required this.tableName,
    required this.displayColumn,
    required this.fields,
    this.orderBy,
    this.readSource,
    this.computePreview,
  });

  final String tableName;

  /// Column shown as each row's title in the list screen (e.g. `name`).
  final String displayColumn;

  /// SQL ORDER BY clause; defaults to [displayColumn] if omitted.
  final String? orderBy;

  /// Editable fields, in the order they should appear on the form.
  final List<FieldConfig> fields;

  /// Query source for reads ([GenericDao.getAll]) -- defaults to
  /// [tableName] when null. Set this when a table has computed/derived
  /// columns not stored on the table itself, e.g. `subscription` ->
  /// `subscription_computed` (see schema.sql): `yearly_cost`/`next_date`
  /// only exist in that view, computed at query time so they can never go
  /// stale. Writes (insert/update/delete) always target [tableName] --
  /// a plain SQLite view is read-only without `INSTEAD OF` triggers,
  /// which this project doesn't use.
  final String? readSource;

  /// Recomputes [FieldConfig.readOnly] field values for a live preview in
  /// the form, before the row has been saved -- e.g. subscription's
  /// yearly_cost/next_date as you edit cost/start_date/renewal_period.
  /// [GenericFormScreen] calls this when the user leaves a field the
  /// computed columns depend on (not on every keystroke), passing the
  /// in-progress form values keyed by column name; the returned map's
  /// entries overwrite the matching readOnly fields' displayed text.
  ///
  /// This necessarily duplicates the SQL view's formula in Dart -- there's
  /// no row to query the view against until the user saves. Keep it a
  /// preview only (never written on save; [GenericFormScreen] always
  /// excludes readOnly fields from what it writes) so any drift between
  /// this and schema.sql's formula is cosmetic, not a data-correctness
  /// risk -- it self-corrects the moment the row is saved and reloaded.
  final Future<Map<String, Object?>> Function(Map<String, Object?> values)? computePreview;
}
