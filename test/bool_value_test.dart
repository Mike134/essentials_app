import 'package:essentials_app/util/bool_value.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('coerceBoolValue', () {
    test('null -> false', () {
      expect(coerceBoolValue(null), isFalse);
    });

    test('real bool passes through', () {
      expect(coerceBoolValue(true), isTrue);
      expect(coerceBoolValue(false), isFalse);
    });

    test('real int (v1-era INTEGER columns)', () {
      expect(coerceBoolValue(1), isTrue);
      expect(coerceBoolValue(0), isFalse);
    });

    test('string "1"/"0" -- the actual on-disk shape for a v2 TEXT-affinity boolean column', () {
      expect(coerceBoolValue('1'), isTrue);
      expect(coerceBoolValue('0'), isFalse);
    });

    test('string "true"/"false", case-insensitive', () {
      expect(coerceBoolValue('true'), isTrue);
      expect(coerceBoolValue('TRUE'), isTrue);
      expect(coerceBoolValue('false'), isFalse);
    });

    test('anything else -> false, not a crash', () {
      expect(coerceBoolValue(''), isFalse);
      expect(coerceBoolValue('nonsense'), isFalse);
      expect(coerceBoolValue(2.5), isFalse);
    });
  });
}
