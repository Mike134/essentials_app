import '../models/table_config.dart';

/// Whether [field] is a plain-stored-text field eligible for Essentials v2
/// Phase 6's first-pass global search index -- see
/// claude/essentials-v2-phase6-design.md's confirmed scope: `text`/`url`/
/// `barcode`/`link_file` (anything whose real stored value is free text),
/// deliberately **not** a resolved `select`/`link_record`/`lookup` display
/// value (a separate, deferred follow-up per the design doc) and not a
/// computed value (`formula`/`lookup`/`rollup`, all `readOnly`).
///
/// `url`/`color` both also store as plain `format: 'text'` (see
/// [FieldFormatChoice]'s own doc comment for why) -- [isColor] is excluded
/// explicitly (a hex string isn't meaningful full-text content); a `url`
/// field is left in (its stored value is a real, searchable string, same
/// as plain text). `currency`/`percentage`/`rating` all also happen to
/// carry [FieldType.text] (see [SchemaRegistry._formatToFieldType] -- none
/// of the three has its own branch there), which is exactly why this
/// checks [FieldConfig.format] directly rather than [FieldConfig.type]:
/// a decimal-as-string or a star rating isn't "plain stored text" in the
/// sense this pass means, even though its physical column happens to be
/// [FieldType.text] like everything else in this schema engine.
bool isSearchIndexable(FieldConfig field) {
  if (field.readOnly) return false;
  if (field.isLookup || field.isInlineSelect || field.isLinkRecord) return false;
  if (field.isColor) return false;
  return field.format == 'text' || field.format == 'link_file' || field.format == 'barcode';
}

/// Builds one record's searchable content: every [isSearchIndexable] field's
/// non-null, non-blank value, space-joined -- see `SearchIndexService`'s own
/// doc comment. [fields] should already be pre-filtered to the eligible
/// subset ([isSearchIndexable]) so this can be called once per row without
/// re-filtering the whole field list every time.
String buildSearchContent(List<FieldConfig> fields, Map<String, Object?> row) {
  final parts = <String>[];
  for (final field in fields) {
    final value = row[field.column];
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isEmpty) continue;
    parts.add(text);
  }
  return parts.join(' ');
}
