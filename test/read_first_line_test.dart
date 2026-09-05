// Proves readFirstLineOf -- the readFirstLine(path) script API function's
// Dart-side implementation. See claude/essentials-v2-extensibility-design.md.
// Pure Dart, real temp files, no DatabaseHelper/SyncService involved --
// same category as test/lookup_value_test.dart/test/bool_value_test.dart.
import 'dart:io';

import 'package:essentials_app/util/scripting/read_first_line.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('read_first_line_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('a single line with no trailing newline returns that line', () {
    final file = File('${tempDir.path}/one_line.txt')..writeAsStringSync('hello world');
    expect(readFirstLineOf(file.path), 'hello world');
  });

  test('a multi-line file returns only the first line', () {
    final file = File('${tempDir.path}/multi.txt')..writeAsStringSync('first\nsecond\nthird');
    expect(readFirstLineOf(file.path), 'first');
  });

  test('a CRLF file returns the first line without a trailing carriage return', () {
    final file = File('${tempDir.path}/crlf.txt')..writeAsStringSync('first\r\nsecond');
    expect(readFirstLineOf(file.path), 'first');
  });

  test('an empty file returns an empty string, not an error', () {
    final file = File('${tempDir.path}/empty.txt')..writeAsStringSync('');
    expect(readFirstLineOf(file.path), '');
  });

  test('a nonexistent path returns the real exception wrapped in <<...>>', () {
    final result = readFirstLineOf('${tempDir.path}/does_not_exist.txt');
    expect(result, startsWith('<<'));
    expect(result, endsWith('>>'));
    expect(result, contains('does_not_exist.txt'));
  });

  test('a directory path returns the real exception wrapped in <<...>>', () {
    final result = readFirstLineOf(tempDir.path);
    expect(result, startsWith('<<'));
    expect(result, endsWith('>>'));
  });
}
