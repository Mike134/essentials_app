import 'package:essentials_app/util/date_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isoDate', () {
    test('pads month/day and formats as yyyy-MM-dd', () {
      expect(isoDate(DateTime(2026, 3, 5)), '2026-03-05');
    });
  });

  group('isoDateTime', () {
    test('includes seconds, all padded', () {
      expect(isoDateTime(DateTime(2026, 9, 12, 6, 5, 7)), '2026-09-12 06:05:07');
    });
  });

  group('isoDateTimeMinutes', () {
    test('drops seconds entirely, hour/minute still padded', () {
      expect(isoDateTimeMinutes(DateTime(2026, 9, 12, 6, 5, 7)), '2026-09-12 06:05');
    });

    test('a DateTime with zero seconds formats identically to isoDateTime minus :ss', () {
      final dt = DateTime(2026, 1, 1, 23, 59, 0);
      expect(isoDateTimeMinutes(dt), isoDateTime(dt).substring(0, 16));
    });
  });
}
