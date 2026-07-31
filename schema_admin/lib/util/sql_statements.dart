/// Splits a migration's `sql_text` into individual statements -- SQLite's
/// execute-one-statement-at-a-time API (what `sqlite_crdt`/`sqflite` both
/// expose) can't run a whole table-rebuild script in one call the way the
/// `sqlite3` CLI can. Duplicated into `essentials_app`/`server` (separate
/// packages) where the actual apply mechanism uses the same splitter to
/// run each statement in sequence -- see CLAUDE.md "schema_admin --
/// migration authoring tool".
///
/// Deliberately simple, not a real SQL parser: splits on `;` outside a
/// single-quoted string (SQL's own `''`-escaped-quote rule is honored so a
/// literal apostrophe in a string doesn't end the string early), strips
/// `--` line comments, and drops a leading `BEGIN`/`BEGIN TRANSACTION` and
/// trailing `COMMIT` if present (Mike's own tested-offline scripts often
/// already have these, matching the `migrations/00N_*.sql` convention --
/// the apply mechanism wraps every migration in its own transaction
/// automatically, so these would otherwise nest a transaction inside a
/// transaction). This is deliberately not "safe" against multi-line
/// (`/* */`) comments or trigger/view bodies with embedded `;` -- both are
/// out of scope for schema_admin (views/triggers are avoided project-wide,
/// see CLAUDE.md), so a real SQL parser would be solving a problem this
/// tool doesn't have.
List<String> splitSqlStatements(String sqlText) {
  final withoutLineComments = sqlText
      .split('\n')
      .map((line) {
        final commentIndex = _findLineCommentStart(line);
        return commentIndex == null ? line : line.substring(0, commentIndex);
      })
      .join('\n');

  final statements = <String>[];
  final buffer = StringBuffer();
  var inString = false;

  for (var i = 0; i < withoutLineComments.length; i++) {
    final char = withoutLineComments[i];
    if (char == "'") {
      inString = !inString;
      buffer.write(char);
      continue;
    }
    if (char == ';' && !inString) {
      statements.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  if (buffer.toString().trim().isNotEmpty) {
    statements.add(buffer.toString());
  }

  final trimmed = [
    for (final s in statements)
      if (s.trim().isNotEmpty) s.trim(),
  ];

  if (trimmed.isNotEmpty && RegExp(r'^BEGIN(\s+TRANSACTION)?$', caseSensitive: false).hasMatch(trimmed.first)) {
    trimmed.removeAt(0);
  }
  if (trimmed.isNotEmpty && RegExp(r'^COMMIT$', caseSensitive: false).hasMatch(trimmed.last)) {
    trimmed.removeLast();
  }

  return trimmed;
}

/// Index of `--` in [line] if it starts a line comment, else null. Doesn't
/// special-case `--` inside a string on the same line (e.g. `WHERE x =
/// '--'`) -- a real edge case a full parser would handle, deliberately not
/// worth it here (see [splitSqlStatements]'s doc comment).
int? _findLineCommentStart(String line) {
  final index = line.indexOf('--');
  return index == -1 ? null : index;
}
