/// Guards against a stray quote/injection in a SQL identifier (table/column
/// name) interpolated directly into a query string -- identifiers can't be
/// bound parameters the normal way SQL values are. Every caller's
/// identifiers come from `sqlite_master`/`PRAGMA` output, not external
/// input, but this is cheap insurance against a maliciously- or
/// accidentally-named table/column breaking a query into something else.
void assertSafeSqlIdentifier(String identifier) {
  if (!isSafeSqlIdentifier(identifier)) {
    throw ArgumentError('Refusing to use suspicious SQL identifier: $identifier');
  }
}

/// The non-throwing form of [assertSafeSqlIdentifier], for a caller that
/// must degrade rather than fail -- `LinkedFieldService` runs on the read
/// path for every grid load and treats an unusable identifier in stale
/// `field_definitions.options` metadata as "this field has no computable
/// value" (blank cell), not as a reason to blow up the whole table.
bool isSafeSqlIdentifier(String identifier) =>
    RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(identifier);

/// SQLite's own reserved keywords (https://www.sqlite.org/lang_keywords.html),
/// lowercased. An unquoted column/table name matching one of these isn't a
/// SQL syntax error by itself (SQLite is lenient about many of them in
/// context), but `sql_crdt`'s `sqlparser` dependency can silently fail to
/// recognize it as a plain identifier and skip rewriting the statement to
/// add its own `is_deleted`/`hlc`/`node_id`/`modified` bookkeeping --
/// exactly the same failure shape already documented for a column literally
/// named `key` (see CLAUDE.md's "007_rename_settings_key_column.sql"), first
/// hit for real with a field named `end` (a real user table, "agenda",
/// 2026-09-11 -- every INSERT against it silently omitted `hlc`, throwing a
/// `NOT NULL constraint failed: agenda.hlc` on every save). Blocking every
/// reserved word here, not just the ones already known to break, avoids
/// discovering the rest one broken table at a time.
const Set<String> sqlReservedKeywords = {
  'abort', 'action', 'add', 'after', 'all', 'alter', 'always', 'analyze',
  'and', 'as', 'asc', 'attach', 'autoincrement', 'before', 'begin',
  'between', 'by', 'cascade', 'case', 'cast', 'check', 'collate', 'column',
  'commit', 'conflict', 'constraint', 'create', 'cross', 'current',
  'current_date', 'current_time', 'current_timestamp', 'database',
  'default', 'deferrable', 'deferred', 'delete', 'desc', 'detach',
  'distinct', 'do', 'drop', 'each', 'else', 'end', 'escape', 'except',
  'exclude', 'exclusive', 'exists', 'explain', 'fail', 'filter', 'first_value',
  'following', 'for', 'foreign', 'from', 'full', 'generated', 'glob',
  'group', 'groups', 'having', 'if', 'ignore', 'immediate', 'in', 'index',
  'indexed', 'initially', 'inner', 'insert', 'instead', 'intersect',
  'into', 'is', 'isnull', 'join', 'key', 'last_value', 'left', 'like', 'limit',
  'match', 'materialized', 'natural', 'no', 'not', 'nothing', 'notnull',
  'null', 'nulls', 'of', 'offset', 'on', 'or', 'order', 'others', 'outer',
  'over', 'partition', 'plan', 'pragma', 'preceding', 'primary', 'query',
  'raise', 'range', 'recursive', 'references', 'regexp', 'reindex',
  'release', 'rename', 'replace', 'restrict', 'returning', 'right',
  'rollback', 'row', 'rows', 'savepoint', 'select', 'set', 'table',
  'temp', 'temporary', 'then', 'ties', 'to', 'transaction', 'trigger',
  'unbounded', 'union', 'unique', 'update', 'using', 'vacuum', 'values',
  'view', 'virtual', 'when', 'where', 'window', 'with', 'without',
};

/// Case-insensitive membership check against [sqlReservedKeywords].
bool isSqlReservedKeyword(String identifier) =>
    sqlReservedKeywords.contains(identifier.toLowerCase());
