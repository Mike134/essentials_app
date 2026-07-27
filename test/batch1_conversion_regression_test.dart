// Regression proof for CLAUDE.md "Table Discovery phase" Part E.1: the 10
// batch-1 lookup tables (domain/priority/gender/status/quality/condition/
// unit/importance/disposition/class) had their hand-written TableConfigs
// retired from table_configs.dart in favor of TableDiscoveryService's
// introspection + the seeded field_metadata rows
// (tool/seed_field_metadata_batch1.dart). This asserts the *converted*
// result against the exact shape those hand-written configs had
// beforehand -- run with `flutter test test/batch1_conversion_regression_test.dart`.
//
// Against the real db, not a fixture -- these are real, permanent tables
// (unlike the throwaway-table tests), so this only reads, never
// creates/drops/mutates anything.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/table_discovery_service.dart';
import 'package:essentials_app/models/table_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every one of these 9 tables shared `_lookupConfig`'s exact shape before
/// conversion: name/description/active/position/color, nothing else.
const List<String> _plainLookupTables = [
  'domain',
  'priority',
  'gender',
  'status',
  'quality',
  'condition',
  'importance',
  'disposition',
  'class',
];

void main() {
  final discovery = TableDiscoveryService();

  setUpAll(() async {
    await DatabaseHelper.instance.crdt;
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  for (final table in _plainLookupTables) {
    test('$table: converted config matches its pre-conversion shape', () async {
      final config = await discovery.buildConfig(table);
      expect(config.displayColumn, 'name');
      expect(config.orderBy, 'position, name');

      final byColumn = {for (final f in config.fields) f.column: f};
      expect(byColumn.keys.toSet(), {'name', 'description', 'active', 'position', 'color'});

      expect(byColumn['name']!.label, 'Name');
      expect(byColumn['name']!.required, isTrue);

      expect(byColumn['description']!.label, 'Description');
      expect(byColumn['description']!.required, isFalse);

      expect(byColumn['active']!.label, 'Active');
      expect(byColumn['active']!.type, FieldType.boolean);
      expect(byColumn['active']!.defaultValue, true);

      expect(byColumn['position']!.label, 'Position');
      expect(byColumn['position']!.type, FieldType.integer);
      expect(byColumn['position']!.defaultValue, 255, reason: 'seeded field_metadata override');

      expect(byColumn['color']!.label, 'Color');
      expect(byColumn['color']!.isColor, isTrue);
      expect(
        byColumn['color']!.defaultValue,
        '#FFFFFF',
        reason: 'seeded field_metadata override',
      );
    });
  }

  test('unit: converted config matches its pre-conversion shape (abbreviation/definition)', () async {
    final config = await discovery.buildConfig('unit');
    expect(config.displayColumn, 'name');
    expect(config.orderBy, 'position, name');

    final byColumn = {for (final f in config.fields) f.column: f};
    expect(byColumn.keys.toSet(), {'name', 'abbreviation', 'definition', 'active', 'position', 'color'});

    expect(byColumn['name']!.required, isTrue);
    expect(byColumn['abbreviation']!.label, 'Abbreviation');
    expect(byColumn['definition']!.label, 'Definition');
    expect(byColumn['active']!.type, FieldType.boolean);
    expect(byColumn['active']!.defaultValue, true);
    expect(byColumn['position']!.defaultValue, 255);
    expect(byColumn['color']!.isColor, isTrue);
    expect(byColumn['color']!.defaultValue, '#FFFFFF');
  });
}
