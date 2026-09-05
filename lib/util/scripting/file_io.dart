import 'dart:convert';
import 'dart:io';

/// Backs the `readFileFirstLine(path)`/`readFileLines(path, n)`/
/// `writeFile(path, text)` script API functions -- see
/// claude/essentials-v2-extensibility-design.md. Factored out as plain,
/// pure-Dart functions (rather than inlined in `_installBridge`'s
/// closures) so they're directly unit-testable without touching the
/// isolate/QuickJS machinery at all -- same reasoning as `lookup_value
/// .dart`/`bool_value.dart`'s own small, standalone helpers.
///
/// No path restriction of any kind, any of the three -- attempts exactly
/// the path given, unconditionally. The real OS file permissions are the
/// only gate that exists, deliberately (see the design doc's own "let the
/// file system decide" framing). A bare `catch (e)` on purpose in all
/// three: an error becomes `'<<$e>>'`, the real exception's own text
/// verbatim -- no invented category of "the" reasons a read or write can
/// fail.

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

/// Writes [text] to [path] verbatim, overwriting the file's entire
/// contents in one shot (never appends, never partial-writes). `text` is
/// written as plain UTF-8 -- this function makes no interpretation of its
/// content beyond that; a script representing hex/base64/binary-as-text
/// data is responsible for its own encoding choice, this is purely the
/// pipe that gets a string onto disk. Returns `null` on success (nothing
/// meaningful to hand back -- the write either happened or it didn't,
/// same as `record.save()`'s own `null`-on-success shape), or the real
/// exception wrapped in `<<...>>` verbatim on failure -- same convention
/// as the two read functions above, same `startsWith('<<')` check a
/// script already uses for those. No directory auto-creation -- a
/// missing parent folder fails with the real OS error, same "attempt
/// exactly what's given" posture as the read side.
String? writeFileOf(String path, String text) {
  try {
    File(path).writeAsStringSync(text);
    return null;
  } catch (e) {
    return '<<$e>>';
  }
}
