import 'dart:convert';
import 'dart:io';

/// Backs the `readFileFirstLine(path)`/`readFileLines(path, n)` script API
/// functions -- see claude/essentials-v2-extensibility-design.md. Factored
/// out as plain, pure-Dart functions (rather than inlined in
/// `_installBridge`'s closures) so they're directly unit-testable without
/// touching the isolate/QuickJS machinery at all -- same reasoning as
/// `lookup_value.dart`/`bool_value.dart`'s own small, standalone helpers.
///
/// No path restriction of any kind, either function -- attempts exactly
/// the path given, unconditionally. The real OS file permissions are the
/// only gate that exists, deliberately (see the design doc's own "let the
/// file system decide" framing). A bare `catch (e)` on purpose in both: an
/// error becomes `'<<$e>>'`, the real exception's own text verbatim -- no
/// invented category of "the" reasons a read can fail.

/// The file's first line, or `''` for a genuinely empty file (not an
/// error) -- `readAsLinesSync()` on an empty file returns an empty list.
String readFileFirstLineOf(String path) {
  try {
    final lines = File(path).readAsLinesSync();
    return lines.isEmpty ? '' : lines.first;
  } catch (e) {
    return '<<$e>>';
  }
}

/// Up to [maxLines] lines from the start of the file, as a JSON-encoded
/// array of strings (the same "return JSON, JS wrapper parses it"
/// convention `table().find()`/`table().all()` already use for
/// structured values crossing this bridge -- an error and a real array
/// are different JS types, so the wrapper checks for the `<<` sentinel
/// before ever calling `JSON.parse`). `maxLines <= 0` means "every line
/// in the file," not zero lines -- there's no everyday reason a script
/// would want to explicitly ask for nothing, so a non-positive count is
/// read as "no limit" rather than "empty result."
String readFileLinesOf(String path, int maxLines) {
  try {
    final lines = File(path).readAsLinesSync();
    final take = maxLines <= 0 ? lines.length : (maxLines < lines.length ? maxLines : lines.length);
    return jsonEncode(lines.take(take).toList());
  } catch (e) {
    return '<<$e>>';
  }
}
