/// Guards against a stray quote/injection in a SQL identifier (table/column
/// name) interpolated directly into a query string -- identifiers can't be
/// bound parameters the normal way SQL values are. Every caller's
/// identifiers come from `sqlite_master`/`PRAGMA` output, not external
/// input, but this is cheap insurance against a maliciously- or
/// accidentally-named table/column breaking a query into something else.
void assertSafeSqlIdentifier(String identifier) {
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(identifier)) {
    throw ArgumentError('Refusing to use suspicious SQL identifier: $identifier');
  }
}
