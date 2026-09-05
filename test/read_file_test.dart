// Proves readFileFirstLineOf/readFileLinesOf -- the readFileFirstLine(path)/
// readFileLines(path, n) script API functions' Dart-side implementations.
// See claude/essentials-v2-extensibility-design.md. Pure Dart, real temp
// files, no DatabaseHelper/SyncService involved -- same category as
// test/lookup_value_test.dart/test/bool_value_test.dart.
import 'dart:io';

import 'package:essentials_app/util/scripting/read_file.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('read_file_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('readFileFirstLineOf', () {
    test('a single line with no trailing newline returns that line', () {
      final file = File('${tempDir.path}/one_line.txt')..writeAsStringSync('hello world');
      expect(readFileFirstLineOf(file.path), 'hello world');
    });

    test('a multi-line file returns only the first line', () {
      final file = File('${tempDir.path}/multi.txt')..writeAsStringSync('first\nsecond\nthird');
      expect(readFileFirstLineOf(file.path), 'first');
    });

    test('a CRLF file returns the first line without a trailing carriage return', () {
      final file = File('${tempDir.path}/crlf.txt')..writeAsStringSync('first\r\nsecond');
      expect(readFileFirstLineOf(file.path), 'first');
    });

    test('an empty file returns an empty string, not an error', () {
      final file = File('${tempDir.path}/empty.txt')..writeAsStringSync('');
      expect(readFileFirstLineOf(file.path), '');
    });

    test('a nonexistent path returns the real exception wrapped in <<...>>', () {
      final result = readFileFirstLineOf('${tempDir.path}/does_not_exist.txt');
      expect(result, startsWith('<<'));
      expect(result, endsWith('>>'));
      expect(result, contains('does_not_exist.txt'));
    });

    test('a directory path returns the real exception wrapped in <<...>>', () {
      final result = readFileFirstLineOf(tempDir.path);
      expect(result, startsWith('<<'));
      expect(result, endsWith('>>'));
    });
  });

  group('readFileLinesOf', () {
    test('fewer lines than requested returns every line, as a JSON array', () {
      final file = File('${tempDir.path}/multi.txt')..writeAsStringSync('first\nsecond\nthird');
      expect(readFileLinesOf(file.path, 10), '["first","second","third"]');
    });

    test('more lines than requested returns only the first n', () {
      final file = File('${tempDir.path}/multi.txt')..writeAsStringSync('first\nsecond\nthird');
      expect(readFileLinesOf(file.path, 2), '["first","second"]');
    });

    test('n <= 0 means every line, not zero lines', () {
      final file = File('${tempDir.path}/multi.txt')..writeAsStringSync('first\nsecond\nthird');
      expect(readFileLinesOf(file.path, 0), '["first","second","third"]');
      expect(readFileLinesOf(file.path, -1), '["first","second","third"]');
    });

    test('an empty file returns an empty JSON array, not an error', () {
      final file = File('${tempDir.path}/empty.txt')..writeAsStringSync('');
      expect(readFileLinesOf(file.path, 5), '[]');
    });

    test('a nonexistent path returns the real exception wrapped in <<...>>', () {
      final result = readFileLinesOf('${tempDir.path}/does_not_exist.txt', 5);
      expect(result, startsWith('<<'));
      expect(result, endsWith('>>'));
      expect(result, contains('does_not_exist.txt'));
    });

    test('a directory path returns the real exception wrapped in <<...>>', () {
      final result = readFileLinesOf(tempDir.path, 5);
      expect(result, startsWith('<<'));
      expect(result, endsWith('>>'));
    });
  });
}
