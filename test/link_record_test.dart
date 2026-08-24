import 'package:essentials_app/util/link_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseLinkedIds', () {
    test('null -> empty', () {
      expect(parseLinkedIds(null), isEmpty);
    });

    test('blank string -> empty', () {
      expect(parseLinkedIds(''), isEmpty);
      expect(parseLinkedIds('   '), isEmpty);
    });

    test('empty array', () {
      expect(parseLinkedIds('[]'), isEmpty);
    });

    test('one id', () {
      expect(parseLinkedIds('[42]'), [42]);
    });

    test('many ids, order preserved', () {
      expect(parseLinkedIds('[42,57,103]'), [42, 57, 103]);
    });

    test('malformed JSON -> empty', () {
      expect(parseLinkedIds('not json'), isEmpty);
      expect(parseLinkedIds('[42'), isEmpty);
    });

    test('non-array JSON -> empty', () {
      expect(parseLinkedIds('{"a":1}'), isEmpty);
      expect(parseLinkedIds('42'), isEmpty);
    });

    test('string-encoded ids in the array still parse (defensive)', () {
      expect(parseLinkedIds('["42","57"]'), [42, 57]);
    });

    test('non-numeric entries are skipped, not thrown', () {
      expect(parseLinkedIds('[42,"abc",57]'), [42, 57]);
    });
  });

  group('encodeLinkedIds', () {
    test('empty list', () {
      expect(encodeLinkedIds([]), '[]');
    });

    test('round-trips through parseLinkedIds', () {
      final ids = [42, 57, 103];
      expect(parseLinkedIds(encodeLinkedIds(ids)), ids);
    });
  });
}
