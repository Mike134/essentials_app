/// Parses a raw db value for a lookup/linked field's stored id back into
/// an `int`.
///
/// Every v2 schema-engine field -- including a `select`/linked one -- is
/// physically `TEXT` (claude/essentials-v2-phase1-design.md: "every user
/// field is TEXT from day one"). Writing a Dart `int` into that column
/// works transparently: SQLite's own TEXT-affinity conversion silently
/// stringifies it on the way in. Reading it back does not undo that --
/// `sqlite_crdt`/`sqflite_common_ffi` hands back exactly what's stored,
/// a `String`, never the original `int`. Every place that reads an
/// existing linked field's value (as opposed to reading the *target*
/// table's own real `INTEGER PRIMARY KEY` `id` column, which needs no
/// such parsing) needs to go through this, not a bare `as int?` cast.
///
/// Found live, real-device verification session: a table with a genuine
/// `select`/linked field crashed to a blank grey screen (Flutter's
/// release-mode error widget) the moment an existing record was opened
/// for editing -- `GenericFormScreen`'s own `as int?` cast on the stored
/// value threw, since it was a `String`. The grid's own lookup column
/// showed a blank cell for the same underlying reason, one level removed
/// (`TrinaColumnType.select<int?>` silently failing to match a `String`
/// cell value against its `int` items).
int? parseLookupValue(Object? raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is String) return int.tryParse(raw);
  return null;
}
