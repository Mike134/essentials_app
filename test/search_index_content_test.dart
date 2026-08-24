// Pure-Dart tests for Essentials v2 Phase 6 (Global Search)'s
// isSearchIndexable/buildSearchContent -- no db involved, mirrors the
// style of test/lookup_value_test.dart / test/bool_value_test.dart.
import 'package:essentials_app/models/table_config.dart';
import 'package:essentials_app/util/search_index_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isSearchIndexable', () {
    test('plain text is eligible', () {
      final field = FieldConfig(column: 'notes', label: 'Notes', format: 'text');
      expect(isSearchIndexable(field), isTrue);
    });

    test('url (format text + isLink) is eligible', () {
      final field = FieldConfig(
        column: 'site',
        label: 'Site',
        format: 'text',
        isLink: true,
        options: const {'isLink': true},
      );
      expect(isSearchIndexable(field), isTrue);
    });

    test('color (format text + isColor) is NOT eligible', () {
      final field = FieldConfig(
        column: 'shade',
        label: 'Shade',
        format: 'text',
        isColor: true,
        options: const {'isColor': true},
      );
      expect(isSearchIndexable(field), isFalse);
    });

    test('link_file is eligible', () {
      final field = FieldConfig(column: 'attachment', label: 'Attachment', format: 'link_file');
      expect(isSearchIndexable(field), isTrue);
    });

    test('barcode is eligible', () {
      final field = FieldConfig(column: 'sku', label: 'SKU', format: 'barcode');
      expect(isSearchIndexable(field), isTrue);
    });

    test('currency is NOT eligible (deliberately, per confirmed scope)', () {
      final field = FieldConfig(column: 'price', label: 'Price', format: 'currency', type: FieldType.text);
      expect(isSearchIndexable(field), isFalse);
    });

    test('percentage is NOT eligible', () {
      final field = FieldConfig(column: 'rate', label: 'Rate', format: 'percentage', type: FieldType.text);
      expect(isSearchIndexable(field), isFalse);
    });

    test('rating is NOT eligible', () {
      final field = FieldConfig(column: 'stars', label: 'Stars', format: 'rating', type: FieldType.text);
      expect(isSearchIndexable(field), isFalse);
    });

    test('integer/real/boolean/date/dateTime are NOT eligible', () {
      expect(
        isSearchIndexable(FieldConfig(column: 'n', label: 'N', format: 'integer', type: FieldType.integer)),
        isFalse,
      );
      expect(
        isSearchIndexable(FieldConfig(column: 'n', label: 'N', format: 'real', type: FieldType.real)),
        isFalse,
      );
      expect(
        isSearchIndexable(FieldConfig(column: 'n', label: 'N', format: 'boolean', type: FieldType.boolean)),
        isFalse,
      );
      expect(
        isSearchIndexable(FieldConfig(column: 'n', label: 'N', format: 'date', type: FieldType.date)),
        isFalse,
      );
    });

    test('formula (readOnly) is NOT eligible even with a text result type', () {
      final field = FieldConfig(
        column: 'summary',
        label: 'Summary',
        format: 'formula',
        readOnly: true,
      );
      expect(isSearchIndexable(field), isFalse);
    });

    test('lookup/rollup (readOnly) are NOT eligible', () {
      expect(
        isSearchIndexable(FieldConfig(column: 'x', label: 'X', format: 'lookup', readOnly: true)),
        isFalse,
      );
      expect(
        isSearchIndexable(FieldConfig(column: 'y', label: 'Y', format: 'rollup', readOnly: true)),
        isFalse,
      );
    });

    test('select in linked mode (isLookup) is NOT eligible', () {
      final field = FieldConfig(
        column: 'status_id',
        label: 'Status',
        format: 'select',
        lookup: const LookupConfig(table: 'status'),
      );
      expect(isSearchIndexable(field), isFalse);
    });

    test('select in inline mode (isInlineSelect) is NOT eligible', () {
      final field = FieldConfig(
        column: 'priority',
        label: 'Priority',
        format: 'select',
        inlineOptions: const [InlineOption(key: 'low', label: 'Low')],
      );
      expect(isSearchIndexable(field), isFalse);
    });

    test('link_record is NOT eligible', () {
      final field = FieldConfig(
        column: 'tasks',
        label: 'Tasks',
        format: 'link_record',
        linkRecord: const LinkRecordConfig(table: 'task'),
      );
      expect(isSearchIndexable(field), isFalse);
    });
  });

  group('buildSearchContent', () {
    test('joins every eligible field\'s non-null, non-blank value with a space', () {
      final fields = [
        FieldConfig(column: 'name', label: 'Name', format: 'text'),
        FieldConfig(column: 'notes', label: 'Notes', format: 'text'),
      ];
      final content = buildSearchContent(fields, {'name': 'Acme', 'notes': 'Rope supplier'});
      expect(content, 'Acme Rope supplier');
    });

    test('skips null values', () {
      final fields = [
        FieldConfig(column: 'name', label: 'Name', format: 'text'),
        FieldConfig(column: 'notes', label: 'Notes', format: 'text'),
      ];
      final content = buildSearchContent(fields, {'name': 'Acme', 'notes': null});
      expect(content, 'Acme');
    });

    test('skips blank/whitespace-only values', () {
      final fields = [
        FieldConfig(column: 'name', label: 'Name', format: 'text'),
        FieldConfig(column: 'notes', label: 'Notes', format: 'text'),
      ];
      final content = buildSearchContent(fields, {'name': 'Acme', 'notes': '   '});
      expect(content, 'Acme');
    });

    test('a row with nothing to contribute yields an empty string', () {
      final fields = [FieldConfig(column: 'notes', label: 'Notes', format: 'text')];
      final content = buildSearchContent(fields, {'notes': null});
      expect(content, isEmpty);
    });

    test('an empty field list yields an empty string', () {
      final content = buildSearchContent(const [], {'name': 'Acme'});
      expect(content, isEmpty);
    });

    test('non-string values are stringified', () {
      final fields = [FieldConfig(column: 'sku', label: 'SKU', format: 'barcode')];
      final content = buildSearchContent(fields, {'sku': 12345});
      expect(content, '12345');
    });
  });
}
