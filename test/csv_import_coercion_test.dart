import 'package:essentials_app/models/table_config.dart';
import 'package:essentials_app/util/csv_import/csv_import_coercion.dart';
import 'package:flutter_test/flutter_test.dart';

FieldConfig _field({
  FieldType type = FieldType.text,
  bool required = false,
  bool readOnly = false,
  LookupConfig? lookup,
  String? format,
  Map<String, Object?> options = const {},
  List<InlineOption>? inlineOptions,
}) {
  return FieldConfig(
    column: 'col',
    label: 'Col',
    type: type,
    required: required,
    readOnly: readOnly,
    lookup: lookup,
    format: format,
    options: options,
    inlineOptions: inlineOptions,
  );
}

void main() {
  group('isCsvImportable', () {
    test('excludes readOnly (formula) fields', () {
      expect(isCsvImportable(_field(readOnly: true)), isFalse);
    });

    test('excludes linked lookup fields', () {
      expect(isCsvImportable(_field(lookup: const LookupConfig(table: 'other'))), isFalse);
    });

    test('includes every plain format', () {
      expect(isCsvImportable(_field()), isTrue);
      expect(isCsvImportable(_field(type: FieldType.integer)), isTrue);
      expect(isCsvImportable(_field(format: 'currency')), isTrue);
      expect(
        isCsvImportable(_field(format: 'select', inlineOptions: const [])),
        isTrue,
      );
    });
  });

  group('coerceCsvCell -- throws on a non-importable field', () {
    test('formula field', () {
      expect(() => coerceCsvCell(_field(readOnly: true), 'x'), throwsArgumentError);
    });

    test('linked lookup field', () {
      expect(
        () => coerceCsvCell(_field(lookup: const LookupConfig(table: 'other')), 'x'),
        throwsArgumentError,
      );
    });
  });

  group('text (incl. url/link_file/barcode/isColor)', () {
    test('stores trimmed text as-is, never malformed', () {
      final result = coerceCsvCell(_field(), '  hello world  ') as CsvCellStore;
      expect(result.value, 'hello world');
      expect(result.warning, isNull);
    });

    test('empty + not required -> null', () {
      final result = coerceCsvCell(_field(), '  ') as CsvCellStore;
      expect(result.value, isNull);
    });

    test('empty + required -> skip', () {
      final result = coerceCsvCell(_field(required: true), '');
      expect(result, isA<CsvCellRequiredMissing>());
    });
  });

  group('integer', () {
    final field = _field(type: FieldType.integer);

    test('parses cleanly', () {
      final result = coerceCsvCell(field, '42') as CsvCellStore;
      expect(result.value, 42);
      expect(result.warning, isNull);
    });

    test('malformed + not required -> raw text with warning', () {
      final result = coerceCsvCell(field, 'not a number') as CsvCellStore;
      expect(result.value, 'not a number');
      expect(result.warning, isNotNull);
    });

    test('malformed + required -> skip', () {
      final result = coerceCsvCell(_field(type: FieldType.integer, required: true), 'nope');
      expect(result, isA<CsvCellRequiredMissing>());
    });
  });

  group('real', () {
    test('parses a plain decimal', () {
      final result = coerceCsvCell(_field(type: FieldType.real), '3.14') as CsvCellStore;
      expect(result.value, 3.14);
    });
  });

  group('boolean', () {
    final field = _field(type: FieldType.boolean);

    for (final text in ['1', 'true', 'TRUE', 'yes', 'Y']) {
      test('"$text" -> 1', () {
        final result = coerceCsvCell(field, text) as CsvCellStore;
        expect(result.value, 1);
      });
    }

    for (final text in ['0', 'false', 'FALSE', 'no', 'N']) {
      test('"$text" -> 0', () {
        final result = coerceCsvCell(field, text) as CsvCellStore;
        expect(result.value, 0);
      });
    }

    test('empty -> 0, even when not required', () {
      final result = coerceCsvCell(field, '') as CsvCellStore;
      expect(result.value, 0);
      expect(result.warning, isNull);
    });

    test('unrecognized + not required -> raw text with warning', () {
      final result = coerceCsvCell(field, 'maybe') as CsvCellStore;
      expect(result.value, 'maybe');
      expect(result.warning, isNotNull);
    });

    test('unrecognized + required -> skip', () {
      final result = coerceCsvCell(_field(type: FieldType.boolean, required: true), 'maybe');
      expect(result, isA<CsvCellRequiredMissing>());
    });
  });

  group('date', () {
    final field = _field(type: FieldType.date);

    test('ISO yyyy-MM-dd', () {
      final result = coerceCsvCell(field, '2026-08-23') as CsvCellStore;
      expect(result.value, '2026-08-23');
    });

    test('US MM/DD/YYYY', () {
      final result = coerceCsvCell(field, '08/23/2026') as CsvCellStore;
      expect(result.value, '2026-08-23');
    });

    test('US M/D/YYYY (no leading zeros)', () {
      final result = coerceCsvCell(field, '8/3/2026') as CsvCellStore;
      expect(result.value, '2026-08-03');
    });

    test('garbage -> raw text with warning, not silently accepted', () {
      final result = coerceCsvCell(field, 'next tuesday') as CsvCellStore;
      expect(result.value, 'next tuesday');
      expect(result.warning, isNotNull);
    });

    test('garbage + required -> skip', () {
      final result = coerceCsvCell(_field(type: FieldType.date, required: true), 'nope');
      expect(result, isA<CsvCellRequiredMissing>());
    });
  });

  group('dateTime', () {
    final field = _field(type: FieldType.dateTime);

    test('ISO with time', () {
      final result = coerceCsvCell(field, '2026-08-23 14:30:00') as CsvCellStore;
      expect(result.value, '2026-08-23 14:30:00');
    });

    test('US date + time', () {
      final result = coerceCsvCell(field, '08/23/2026 14:30') as CsvCellStore;
      expect(result.value, '2026-08-23 14:30:00');
    });

    test('US date only -> midnight', () {
      final result = coerceCsvCell(field, '08/23/2026') as CsvCellStore;
      expect(result.value, '2026-08-23 00:00:00');
    });
  });

  group('currency', () {
    final field = _field(format: 'currency');

    test('strips symbol and thousands separators', () {
      final result = coerceCsvCell(field, r'$1,234.56') as CsvCellStore;
      expect(result.value, 1234.56);
    });

    test('plain decimal, no symbol', () {
      final result = coerceCsvCell(field, '19.99') as CsvCellStore;
      expect(result.value, 19.99);
    });

    test('malformed -> raw text with warning', () {
      final result = coerceCsvCell(field, 'free') as CsvCellStore;
      expect(result.value, 'free');
      expect(result.warning, isNotNull);
    });
  });

  group('percentage', () {
    final field = _field(format: 'percentage');

    test('explicit % suffix divides by 100', () {
      final result = coerceCsvCell(field, '15%') as CsvCellStore;
      expect(result.value, closeTo(0.15, 1e-9));
    });

    test('no suffix -- stored as the fraction as-is', () {
      final result = coerceCsvCell(field, '0.15') as CsvCellStore;
      expect(result.value, 0.15);
    });

    test('a fraction above 1 is not treated specially', () {
      final result = coerceCsvCell(field, '1.5') as CsvCellStore;
      expect(result.value, 1.5);
    });
  });

  group('rating', () {
    final field = _field(format: 'rating');

    test('parses a plain int, not clamped to any max', () {
      final result = coerceCsvCell(field, '11') as CsvCellStore;
      expect(result.value, 11);
    });
  });

  group('select (inline mode)', () {
    final options = [
      const InlineOption(key: 'low', label: 'Low'),
      const InlineOption(key: 'high', label: 'High'),
    ];
    final field = _field(format: 'select', inlineOptions: options);

    test('case-insensitive match on label, stores the key', () {
      final result = coerceCsvCell(field, 'high') as CsvCellStore;
      expect(result.value, 'high');
    });

    test('exact-case match too', () {
      final result = coerceCsvCell(field, 'Low') as CsvCellStore;
      expect(result.value, 'low');
    });

    test('no match -> raw text with warning', () {
      final result = coerceCsvCell(field, 'Medium') as CsvCellStore;
      expect(result.value, 'Medium');
      expect(result.warning, isNotNull);
    });

    test('no match + required -> skip', () {
      final requiredField = _field(format: 'select', required: true, inlineOptions: options);
      final result = coerceCsvCell(requiredField, 'Medium');
      expect(result, isA<CsvCellRequiredMissing>());
    });
  });
}
