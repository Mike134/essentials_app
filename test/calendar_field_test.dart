// Pure-Dart tests for Essentials v2 Phase 3 build order step 5's
// CalendarFieldConfig model -- no DatabaseHelper/SchemaEditorService
// involved, so this file can be run alone or chained with any other test
// file freely.
import 'package:essentials_app/models/table_config.dart';
import 'package:essentials_app/util/calendar_field.dart';
import 'package:flutter_test/flutter_test.dart';

TableConfig _configWith(List<FieldConfig> fields) => TableConfig(
  tableName: 't',
  displayName: 'T',
  displayColumn: 'id',
  fields: fields,
);

FieldConfig _field(String column, FieldType type) =>
    FieldConfig(column: column, label: column, type: type);

void main() {
  group('CalendarFieldConfig JSON round-trip', () {
    test('single mode', () {
      const config = CalendarFieldConfig.single('due_date');
      expect(config.toJson(), {'mode': 'single', 'field': 'due_date'});

      final parsed = CalendarFieldConfig.tryParse('{"mode":"single","field":"due_date"}');
      expect(parsed, isNotNull);
      expect(parsed!.isRange, isFalse);
      expect(parsed.field, 'due_date');
    });

    test('range mode', () {
      const config = CalendarFieldConfig.range('start', 'end');
      expect(config.toJson(), {'mode': 'range', 'start_field': 'start', 'end_field': 'end'});

      final parsed = CalendarFieldConfig.tryParse('{"mode":"range","start_field":"start","end_field":"end"}');
      expect(parsed, isNotNull);
      expect(parsed!.isRange, isTrue);
      expect(parsed.startField, 'start');
      expect(parsed.endField, 'end');
    });

    test('tryParse returns null for blank/malformed/wrong-shape input', () {
      expect(CalendarFieldConfig.tryParse(null), isNull);
      expect(CalendarFieldConfig.tryParse(''), isNull);
      expect(CalendarFieldConfig.tryParse('   '), isNull);
      expect(CalendarFieldConfig.tryParse('not json'), isNull);
      expect(CalendarFieldConfig.tryParse('[]'), isNull);
      expect(CalendarFieldConfig.tryParse('{"mode":"single"}'), isNull); // missing field
      expect(CalendarFieldConfig.tryParse('{"mode":"range","start_field":"a"}'), isNull); // missing end
    });
  });

  group('eligibleCalendarFields / hasEligibleCalendarField', () {
    test('only date/dateTime fields are eligible, in position order', () {
      final config = _configWith([
        _field('name', FieldType.text),
        _field('due', FieldType.date),
        _field('cost', FieldType.real),
        _field('created', FieldType.dateTime),
      ]);
      expect(eligibleCalendarFields(config).map((f) => f.column), ['due', 'created']);
      expect(hasEligibleCalendarField(config), isTrue);
    });

    test('a table with no date/dateTime field is not eligible', () {
      final config = _configWith([_field('name', FieldType.text), _field('cost', FieldType.real)]);
      expect(eligibleCalendarFields(config), isEmpty);
      expect(hasEligibleCalendarField(config), isFalse);
    });
  });

  group('resolveCalendarField', () {
    test('null for a table with no eligible field, regardless of stored config', () {
      final config = _configWith([_field('name', FieldType.text)]);
      expect(resolveCalendarField(config, '{"mode":"single","field":"due"}'), isNull);
    });

    test('falls back to the first eligible field, single mode, when nothing stored', () {
      final config = _configWith([_field('due', FieldType.date), _field('created', FieldType.dateTime)]);
      final resolved = resolveCalendarField(config, null);
      expect(resolved!.isRange, isFalse);
      expect(resolved.field, 'due');
    });

    test('uses the stored single-field choice when it still names a real date field', () {
      final config = _configWith([_field('due', FieldType.date), _field('created', FieldType.dateTime)]);
      final resolved = resolveCalendarField(config, '{"mode":"single","field":"created"}');
      expect(resolved!.field, 'created');
    });

    test('uses the stored range when both fields still exist', () {
      final config = _configWith([_field('start', FieldType.date), _field('end', FieldType.date)]);
      final resolved = resolveCalendarField(config, '{"mode":"range","start_field":"start","end_field":"end"}');
      expect(resolved!.isRange, isTrue);
      expect(resolved.startField, 'start');
      expect(resolved.endField, 'end');
    });

    test('falls back to the first eligible field when the stored field no longer exists', () {
      // Simulates the field having been renamed/dropped since the calendar
      // field was chosen -- must degrade gracefully, not throw or return a
      // config pointing at a column that isn't there.
      final config = _configWith([_field('due', FieldType.date)]);
      final resolved = resolveCalendarField(config, '{"mode":"single","field":"deleted_field"}');
      expect(resolved!.field, 'due');
    });

    test('falls back when a stored range has one field that no longer exists', () {
      final config = _configWith([_field('due', FieldType.date)]);
      final resolved = resolveCalendarField(config, '{"mode":"range","start_field":"due","end_field":"gone"}');
      expect(resolved!.isRange, isFalse);
      expect(resolved.field, 'due');
    });
  });

  group('parseStoredDate', () {
    test('parses a plain date and a dateTime string', () {
      expect(parseStoredDate('2026-08-25'), DateTime(2026, 8, 25));
      expect(parseStoredDate('2026-08-25 14:30:00'), DateTime(2026, 8, 25, 14, 30));
    });

    test('null for blank, non-string, or unparseable input', () {
      expect(parseStoredDate(null), isNull);
      expect(parseStoredDate(''), isNull);
      expect(parseStoredDate('   '), isNull);
      expect(parseStoredDate(42), isNull);
      expect(parseStoredDate('not a date'), isNull);
    });
  });
}
