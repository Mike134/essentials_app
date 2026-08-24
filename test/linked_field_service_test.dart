// Pure-Dart unit tests for LinkedFieldService's metadata-only surface --
// Essentials v2 Phase 4 build order step 2. No DatabaseHelper, no
// SyncService, no real db: safe to run chained with any other pure test
// file. The value-resolution half necessarily needs a real database (it
// reads another table's rows) and lives in
// linked_field_service_end_to_end_test.dart.
import 'package:essentials_app/models/table_config.dart';
import 'package:essentials_app/util/linked_field/linked_field_service.dart';
import 'package:flutter_test/flutter_test.dart';

FieldConfig field(
  String column, {
  String? format,
  Map<String, Object?> options = const {},
  FieldType type = FieldType.text,
}) => FieldConfig(
  column: column,
  label: column,
  format: format,
  options: options,
  type: type,
);

void main() {
  group('format detection', () {
    test('recognizes lookup and rollup, and nothing else', () {
      expect(LinkedFieldService.isLookupField(field('a', format: 'lookup')), isTrue);
      expect(LinkedFieldService.isRollupField(field('a', format: 'rollup')), isTrue);
      expect(LinkedFieldService.isLookupField(field('a', format: 'rollup')), isFalse);
      expect(LinkedFieldService.isRollupField(field('a', format: 'lookup')), isFalse);

      for (final other in const [
        'text',
        'integer',
        'real',
        'boolean',
        'date',
        'dateTime',
        'select',
        'formula',
        'link_record',
        'currency',
      ]) {
        expect(
          LinkedFieldService.isLinkedComputedField(field('a', format: other)),
          isFalse,
          reason: '$other must not be treated as a linked computed field',
        );
      }
    });

    test('a null format (pre-Phase-2 FieldConfig) is never linked-computed', () {
      expect(LinkedFieldService.isLinkedComputedField(field('a')), isFalse);
    });

    test('hasLinkedComputedFields gates on any lookup/rollup field', () {
      expect(LinkedFieldService.hasLinkedComputedFields(const []), isFalse);
      expect(
        LinkedFieldService.hasLinkedComputedFields([field('a', format: 'text')]),
        isFalse,
      );
      expect(
        LinkedFieldService.hasLinkedComputedFields([
          field('a', format: 'text'),
          field('b', format: 'rollup'),
        ]),
        isTrue,
      );
    });

    test('isLinkedComputedFormat matches the FieldConfig-based check', () {
      expect(LinkedFieldService.isLinkedComputedFormat('lookup'), isTrue);
      expect(LinkedFieldService.isLinkedComputedFormat('rollup'), isTrue);
      expect(LinkedFieldService.isLinkedComputedFormat('link_record'), isFalse);
      expect(LinkedFieldService.isLinkedComputedFormat(''), isFalse);
    });
  });

  group('producesNumber -- the default deliberately differs by format', () {
    test('rollup defaults to numeric', () {
      expect(LinkedFieldService.producesNumber(field('a', format: 'rollup')), isTrue);
      expect(LinkedFieldService.producesNumberFor('rollup', const {}), isTrue);
    });

    test('rollup opts out with resultType: text', () {
      expect(
        LinkedFieldService.producesNumber(
          field('a', format: 'rollup', options: const {'resultType': 'text'}),
        ),
        isFalse,
      );
    });

    test('lookup defaults to text -- it produces comma-joined display values', () {
      expect(LinkedFieldService.producesNumber(field('a', format: 'lookup')), isFalse);
      expect(LinkedFieldService.producesNumberFor('lookup', const {}), isFalse);
    });

    test('lookup opts IN with an explicit resultType: number', () {
      expect(
        LinkedFieldService.producesNumber(
          field('a', format: 'lookup', options: const {'resultType': 'number'}),
        ),
        isTrue,
      );
    });
  });

  group('decimalsFor', () {
    test('defaults to 2, matching real/formula/currency columns', () {
      expect(LinkedFieldService.decimalsFor(field('a', format: 'rollup')), 2);
    });

    test('honors an explicit options.decimals', () {
      expect(
        LinkedFieldService.decimalsFor(
          field('a', format: 'rollup', options: const {'decimals': 0}),
        ),
        0,
      );
      expect(
        LinkedFieldService.decimalsFor(
          field('a', format: 'rollup', options: const {'decimals': '4'}),
        ),
        4,
      );
    });
  });

  group('displayTexts', () {
    test('formats a numeric rollup to its own decimal count', () {
      final fields = [
        field('total', format: 'rollup', options: const {'aggregate': 'sum'}),
        field('items', format: 'rollup', options: const {'aggregate': 'count', 'decimals': 0}),
      ];
      final texts = LinkedFieldService.displayTexts(fields, {'total': 13.5, 'items': 3});
      // The grid formats the same values through TrinaColumnType.number
      // with the same options.decimals -- these strings are what keeps the
      // form's readOnly text field identical to the grid cell.
      expect(texts['total'], '13.50');
      expect(texts['items'], '3');
    });

    test('leaves a text-result lookup as its joined value', () {
      final fields = [field('names', format: 'lookup')];
      final texts = LinkedFieldService.displayTexts(fields, {'names': 'Alice, Bob'});
      expect(texts['names'], 'Alice, Bob');
    });

    test('renders null as empty text, never "null"', () {
      final fields = [
        field('total', format: 'rollup'),
        field('names', format: 'lookup'),
      ];
      final texts = LinkedFieldService.displayTexts(fields, {'total': null, 'names': null});
      expect(texts['total'], '');
      expect(texts['names'], '');
    });

    test('a computed column with no matching field still renders safely', () {
      expect(LinkedFieldService.displayTexts(const [], {'ghost': 7}), {'ghost': '7'});
    });
  });

  group('aggregate catalog', () {
    test('is exactly the design doc\'s five', () {
      expect(LinkedFieldService.aggregates, {'sum', 'avg', 'min', 'max', 'count'});
    });

    test('defaults to sum', () {
      expect(LinkedFieldService.defaultAggregate, 'sum');
      expect(LinkedFieldService.aggregates, contains(LinkedFieldService.defaultAggregate));
    });
  });
}
