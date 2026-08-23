/// UI-level format catalog for [AddFieldScreen]/[ManageFieldsScreen] --
/// deliberately a separate enum from [SchemaRegistry]'s own format-string
/// handling, same relationship the retired `NewColumnType` had to raw SQL
/// types for the also-retired `AddColumnScreen`. Keeps the DAO layer
/// (`SchemaEditorService.addField`/`SchemaMetadataDao.updateField`) taking
/// a plain `format`
/// string, format-catalog-agnostic, while this enum is where the actual
/// picker choices live -- see CLAUDE.md "Essentials v2 Phase 1 -- Step 4"
/// for why the format catalog was left provisional until this screen
/// existed to design it against.
///
/// `value` matches [SchemaRegistry]'s `_formatToFieldType` mapping 1:1 --
/// `text`/`integer`/`real`/`boolean`/`date`/`dateTime`/`select` (a linked
/// lookup). No collapsed `number` format (see Step 4's write-up for why
/// that was deliberately not guessed at ahead of this screen).
enum FieldFormatChoice {
  text('text', 'Text'),
  integer('integer', 'Whole number'),
  real('real', 'Decimal number'),
  boolean('boolean', 'Yes/No'),
  date('date', 'Date'),
  dateTime('dateTime', 'Date & time'),
  select('select', 'Linked to another table');

  const FieldFormatChoice(this.value, this.label);

  final String value;
  final String label;

  static FieldFormatChoice fromValue(String value) =>
      FieldFormatChoice.values.firstWhere((c) => c.value == value, orElse: () => FieldFormatChoice.text);
}

/// `field_definitions.options.on_delete` choices for a [FieldFormatChoice
/// .select] field -- see `GenericDao._linkedFieldRefs`'s doc comment
/// (CLAUDE.md "Essentials v2 Phase 1 -- Step 6") for what each actually
/// does. `restrict` is the default when unset, matching this project's
/// long-standing "block deletion unless explicitly told otherwise"
/// posture -- listed first here for the same reason.
enum OnDeleteChoice {
  restrict('restrict', 'Block deleting the linked row while this still references it'),
  cascade('cascade', 'Delete this row too, when the linked row is deleted'),
  ignore('ignore', 'Leave this row alone, even if the linked row is deleted');

  const OnDeleteChoice(this.value, this.label);

  final String value;
  final String label;

  static OnDeleteChoice fromValue(String? value) =>
      OnDeleteChoice.values.firstWhere((c) => c.value == value, orElse: () => OnDeleteChoice.restrict);
}
