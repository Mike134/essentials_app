/// Duplicated from `essentials_app/lib/util/sql_identifiers.dart` --
/// separate Dart package, can't share a file, same reasoning as
/// `safeChangesetBuilder` being duplicated between `essentials_app` and
/// `server/`. Guards against a stray quote/injection in a SQL identifier
/// (table/column name) interpolated directly into a query string.
void assertSafeSqlIdentifier(String identifier) {
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(identifier)) {
    throw ArgumentError('Refusing to use suspicious SQL identifier: $identifier');
  }
}
