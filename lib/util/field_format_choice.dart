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
///
/// `linkFile`/`currency`/`percentage`/`rating` are Phase 2 entries (see
/// claude/essentials-v2-phase2-design.md) -- unlike the seven above, none
/// of them has a dedicated branch in [SchemaRegistry]'s
/// `_formatToFieldType` (all four fall through to the same
/// [FieldType.text] every unrecognized format gets) and instead resolve
/// through a [FieldFormatHandler] registered by their `value` string --
/// see that class's doc comment for why new Phase 2 formats are routed
/// differently from these first seven. `real` also gained an `options
/// .decimals` display hint the same session `currency`/`percentage` were
/// added, but it's not a new catalog entry -- see
/// `GenericListScreen._decimalsFor`'s doc comment.
///
/// **`formula` is a third kind again** -- it *does* get a dedicated
/// `_formatToFieldType` branch (its `options.resultType` decides between
/// [FieldType.real] and [FieldType.text]) but has no
/// [FieldFormatHandler]: its value is computed at read time by
/// `FormulaService` and rendered through the long-standing
/// [FieldConfig.readOnly] path that v1's `subscription_computed` view
/// columns already used. See `FormulaService`'s own doc comment.
///
/// **`barcode` is back to the first kind** (a [FieldFormatHandler], `TEXT`
/// storage, `options: {}`) -- its grid/form rendering is otherwise
/// identical to plain `text`, it's routed through a handler purely to add
/// a camera-scan button on Android. See `BarcodeFormatHandler`'s own doc
/// comment for the package-choice spike this was built against.
///
/// **`url` is different again, and deliberately shares [text]'s `value`
/// (`'text'`) rather than getting its own** -- per the design doc, a link
/// field was never a new stored format at all: `SchemaRegistry._buildField`
/// already reads `options['isLink'] == true` off *any* field regardless of
/// format (`FieldConfig.isLink`, already fully wired through both screens
/// since batch 3, long before Essentials v2 existed). `url` exists purely
/// so `AddFieldScreen`'s picker has a discoverable entry for it -- picking
/// it writes `format: 'text'`, `options: {isLink: true}`. **This is why
/// [fromValue] can never resolve `url`** -- two entries sharing one
/// `value` means `firstWhere` always returns whichever is declared first
/// ([text]). Anywhere that needs to reverse-map an *existing* field's
/// format back to a picker selection (i.e. an edit screen, never
/// [AddFieldScreen] itself, which only ever creates new fields) must use
/// [resolve] instead, which also checks `options.isLink`.
///
/// **`inlineSelect` shares [select]'s `value` (`'select'`) for the exact
/// same reason `url` shares [text]'s** -- both `select` entries write
/// `format: 'select'`; only `options.mode` (`'linked'` vs `'inline'`)
/// tells them apart. Picking `inlineSelect` writes `options: {mode:
/// 'inline', options: [{key, label}, ...]}` -- see `InlineOptionListEditor`
/// for the picker UI and `FieldConfig.inlineOptions`/`isInlineSelect` for
/// how it renders. [resolve] handles this ambiguity too, same as `url`.
///
/// **`linkRecord`/`lookup`/`rollup` are Essentials v2 Phase 4 entries** (see
/// claude/essentials-v2-phase4-design.md) -- a distinct linking mechanism
/// from [select]'s linked-lookup mode (single scalar FK id; a small
/// reference table has exactly one of something). [linkRecord] stores a
/// JSON array of target ids (`lib/util/link_record.dart`), supports
/// linking to one *or many* rows (`options.multiple`), and is what
/// [lookup]/[rollup] read from -- a `lookup` shows one field from the
/// linked record(s); a `rollup` aggregates one. All three are genuinely new
/// stored formats, unlike `url`/`inlineSelect`/`color` above -- each gets
/// its own dedicated `SchemaRegistry`/`GenericDao`/render-layer handling,
/// see `FieldConfig.isLinkRecord`/`isFieldLookup`/`isRollup` and
/// `LinkedFieldService`.
///
/// **`color` shares [text]'s `value` for the same reason `url` does.**
/// `FieldConfig.isColor` (hex-string color swatch + picker, grid and form)
/// has been fully wired since v1 (`domain.color`/`class.color`) -- the gap
/// this closes is purely that `AddFieldScreen`'s picker had no way to
/// *create* a v2 field with `options.isColor == true`; the render/edit
/// side was never missing anything. Picking it writes `format: 'text'`,
/// `options: {isColor: true}`. [resolve] handles this the same way it
/// handles `url`.
/// **`button` is Essentials v2 Phase 5's new entry** (see
/// claude/essentials-v2-phase5-design.md's "Data model") -- a genuinely
/// new stored format (`TEXT`, never written, `options: {label: String}`),
/// same first-kind category as `link_file`/`currency`/`rating`: a real
/// [FieldFormatHandler] (`ButtonFormatHandler`), not a variant of
/// existing rendering and not computed. Renders disabled until Phase 5's
/// script-wiring steps land -- see that handler's own doc comment.
///
/// **`image` is a genuinely new stored format** (`TEXT` holding a
/// relative storage key, `options: {}` -- see
/// claude/essentials-v2-image-field-design.md). Same two-handler split as
/// `button`: [ImageFormatHandler] is registered for
/// [GenericListScreen]'s grid column only (a blank, always-empty
/// read-only cell -- this field is Form-view-only by design, see the
/// storage doc's "Preview" section); the real capture/drag-drop/preview
/// widget lives in `GenericFormScreen._buildImageField`, special-cased
/// before generic handler dispatch the same way `_buildButtonField` is,
/// because it needs a table name and record id the shared
/// [FieldFormatHandler.buildFormField] interface has no way to pass --
/// see claude/essentials-v2-image-field-ui-design.md.
enum FieldFormatChoice {
  text('text', 'Text'),
  integer('integer', 'Whole number'),
  real('real', 'Decimal number'),
  boolean('boolean', 'Yes/No'),
  date('date', 'Date'),
  dateTime('dateTime', 'Date & time'),
  select('select', 'Choose one (dropdown lookup)'),
  linkFile('link_file', 'Link to a file'),
  currency('currency', 'Currency'),
  percentage('percentage', 'Percentage'),
  url('text', 'Link (URL)'),
  inlineSelect('select', 'Fixed list of options'),
  color('text', 'Color'),
  rating('rating', 'Rating'),
  formula('formula', 'Calculated (formula)'),
  barcode('barcode', 'Barcode / QR code'),
  linkRecord('link_record', 'Link to record(s) in another table'),
  lookup('lookup', 'Show a value from a linked record'),
  rollup('rollup', 'Calculate from linked records'),
  button('button', 'Button (runs a script)'),
  image('image', 'Image');

  const FieldFormatChoice(this.value, this.label);

  final String value;
  final String label;

  static FieldFormatChoice fromValue(String value) =>
      FieldFormatChoice.values.firstWhere((c) => c.value == value, orElse: () => FieldFormatChoice.text);

  /// Same as [fromValue], but also recognizes [url]/[inlineSelect] -- see
  /// this enum's own doc comment for why [fromValue] structurally can't.
  /// Pass the field's already-parsed `options` map (e.g. via
  /// `parseFieldOptions`), not the raw JSON string.
  static FieldFormatChoice resolve(String format, Map<String, Object?> options) {
    final choice = fromValue(format);
    if (choice == text && options['isLink'] == true) return url;
    if (choice == text && options['isColor'] == true) return color;
    if (choice == select && options['mode'] == 'inline') return inlineSelect;
    return choice;
  }
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
