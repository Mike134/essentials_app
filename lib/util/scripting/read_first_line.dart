import 'dart:io';

/// Backs the `readFirstLine(path)` script API function -- see
/// claude/essentials-v2-extensibility-design.md. Factored out as a plain,
/// pure-Dart function (rather than inlined in `_installBridge`'s closure)
/// so it's directly unit-testable without touching the isolate/QuickJS
/// machinery at all -- same reasoning as `lookup_value.dart`/`bool_value
/// .dart`'s own small, standalone helpers.
///
/// No path restriction of any kind -- attempts exactly the path given,
/// unconditionally. The real OS file permissions are the only gate that
/// exists, deliberately (see the design doc's own "let the file system
/// decide" framing). A bare `catch (e)` on purpose: whatever actually
/// goes wrong, the sentinel wraps the real exception's own text verbatim
/// -- no invented category of "the" reasons a read can fail. An empty
/// file is not an error -- `readAsLinesSync()` on an empty file returns
/// an empty list, correctly yielding `''` as its (nonexistent) first line.
String readFirstLineOf(String path) {
  try {
    final lines = File(path).readAsLinesSync();
    return lines.isEmpty ? '' : lines.first;
  } catch (e) {
    return '<<$e>>';
  }
}
