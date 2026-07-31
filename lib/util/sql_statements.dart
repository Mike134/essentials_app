/// Duplicated from `schema_admin/lib/util/sql_statements.dart` -- separate
/// Dart package, can't share a file, same reasoning as `safeChangesetBuilder`
/// being duplicated between `essentials_app` and `server/`. See that file's
/// doc comment for the full explanation of what this does and doesn't
/// handle; kept byte-for-byte identical here on purpose so both projects'
/// splitting logic can never quietly drift apart.
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

int? _findLineCommentStart(String line) {
  final index = line.indexOf('--');
  return index == -1 ? null : index;
}
