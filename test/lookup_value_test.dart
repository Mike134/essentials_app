// Proves parseLookupValue -- the fix for a real crash found live in the
// real-device verification session: a v2 linked field's own column is
// always physically TEXT, so its stored id round-trips through the db as
// a String, not the int GenericFormScreen/GenericListScreen previously
// assumed via a bare `as int?` cast. Run with
// `flutter test test/lookup_value_test.dart`.
import 'package:essentials_app/util/lookup_value.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a String-stored id (the real, v2 on-disk shape)', () {
    expect(parseLookupValue('1787500024698233'), 1787500024698233);
  });

  test('passes through a real int unchanged (defensive, not the common case)', () {
    expect(parseLookupValue(42), 42);
  });

  test('returns null for null', () {
    expect(parseLookupValue(null), isNull);
  });

  test('returns null for an unparseable string rather than throwing', () {
    expect(parseLookupValue('not a number'), isNull);
  });
}
