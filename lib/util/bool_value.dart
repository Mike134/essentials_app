/// Parses a raw db value for a boolean field back into a real `bool`.
///
/// Every v2 schema-engine field -- boolean ones included -- is physically
/// `TEXT` (`SchemaEditorService.addField`: "every user field is TEXT from
/// day one"). Writing a Dart `int` (1/0) into that column works
/// transparently on the way in: SQLite's own TEXT-affinity conversion
/// silently stringifies it. Reading it back does not undo that --
/// `sqlite_crdt`/`sqflite_common_ffi` hands back exactly what's stored, the
/// *string* `"1"`/`"0"`, never the original `int`. A bare `raw == 1 ||
/// raw == true` comparison (what both call sites used before this existed)
/// is therefore always false for a v2 boolean field -- a value saved as
/// checked/true silently reads back as unchecked/false on the very next
/// load, in both the grid and the form.
///
/// Same failure shape this project already found and fixed once for linked
/// fields -- see `parseLookupValue`'s doc comment. A v1-era boolean field
/// (a real SQL `INTEGER` column, none of which exist anymore after the
/// Essentials v2 clean-slate wipe) never hit this, since `int` came back as
/// `int`; this only ever affected fields created through the schema engine.
bool coerceBoolValue(Object? raw) {
  if (raw == null) return false;
  if (raw is bool) return raw;
  if (raw is int) return raw == 1;
  if (raw is String) return raw == '1' || raw.toLowerCase() == 'true';
  return false;
}
