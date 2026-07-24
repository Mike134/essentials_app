// Regression proof for CLAUDE.md "Table Discovery phase" Part E.2: the 9
// batch-2 tables (person/category/time_frame/account_type/account/
// supplier/shipper/shipment/journal) had their hand-written TableConfigs
// retired from table_configs.dart in favor of TableDiscoveryService's
// introspection + the seeded field_metadata rows
// (tool/seed_field_metadata_batch2.dart). This asserts the *converted*
// result against the exact shape those hand-written configs had
// beforehand, including the real FK lookup-display-column resolution and
// shipment's reserved-field_metadata table-level override -- run with
// `flutter test test/batch2_conversion_regression_test.dart`.
//
// Against the real db, not a fixture -- read-only, never creates/drops/
// mutates anything (unlike the throwaway-table tests).
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/table_discovery_service.dart';
import 'package:essentials_app/models/table_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final discovery = TableDiscoveryService();

  setUpAll(() async {
    await DatabaseHelper.instance.database;
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  test('account_type: matches its pre-conversion shape', () async {
    final config = await discovery.buildConfig('account_type');
    expect(config.displayColumn, 'name');
    expect(config.orderBy, 'position, name');
    final byColumn = {for (final f in config.fields) f.column: f};
    expect(byColumn.keys.toSet(), {'name', 'abbreviation', 'definition', 'active', 'position', 'color'});
    expect(byColumn['name']!.required, isTrue);
    expect(byColumn['active']!.defaultValue, true);
    expect(byColumn['position']!.defaultValue, 255);
    expect(byColumn['color']!.defaultValue, '#FFFFFF');
  });

  test('person: matches its pre-conversion shape, gender_id lookup resolves to gender.name', () async {
    final config = await discovery.buildConfig('person');
    expect(config.displayColumn, 'name');
    expect(config.orderBy, 'position, name');
    final byColumn = {for (final f in config.fields) f.column: f};
    expect(byColumn.keys.toSet(), {'name', 'description', 'gender_id', 'active', 'position', 'color'});

    final genderId = byColumn['gender_id']!;
    expect(genderId.label, 'Gender');
    expect(genderId.isLookup, isTrue);
    expect(genderId.lookup!.table, 'gender');
    expect(genderId.lookup!.displayColumn, 'name');
    expect(genderId.required, isFalse, reason: 'gender_id is nullable in schema.sql');

    expect(byColumn['position']!.defaultValue, 255);
    expect(byColumn['color']!.defaultValue, '#FFFFFF');
  });

  test('category: matches its pre-conversion shape, class_id lookup resolves to class.name', () async {
    final config = await discovery.buildConfig('category');
    expect(config.displayColumn, 'name');
    expect(config.orderBy, 'position, name');
    final byColumn = {for (final f in config.fields) f.column: f};
    expect(byColumn.keys.toSet(), {'name', 'class_id', 'description', 'active', 'position', 'color'});

    final classId = byColumn['class_id']!;
    expect(classId.label, 'Class');
    expect(classId.lookup!.table, 'class');
    expect(classId.lookup!.displayColumn, 'name');
  });

  test('time_frame: matches its pre-conversion shape, required lookup and required multiplier', () async {
    final config = await discovery.buildConfig('time_frame');
    expect(config.displayColumn, 'name');
    expect(config.orderBy, 'position, name');
    final byColumn = {for (final f in config.fields) f.column: f};
    expect(byColumn.keys.toSet(), {
      'name',
      'unit_id',
      'multiplier',
      'description',
      'active',
      'position',
      'color',
    });

    final unitId = byColumn['unit_id']!;
    expect(unitId.label, 'Unit');
    expect(unitId.lookup!.table, 'unit');
    expect(
      unitId.required,
      isTrue,
      reason: 'unit_id is NOT NULL with no default -- the required-lookup fix this catches',
    );

    expect(byColumn['multiplier']!.required, isTrue);
    expect(byColumn['multiplier']!.type, FieldType.integer);
  });

  test('account: matches its pre-conversion shape, two independent lookups', () async {
    final config = await discovery.buildConfig('account');
    expect(config.displayColumn, 'name');
    expect(config.orderBy, 'position, name');
    final byColumn = {for (final f in config.fields) f.column: f};
    expect(byColumn.keys.toSet(), {
      'name',
      'code',
      'institution',
      'account_type_id',
      'domain_id',
      'notes',
      'active',
      'position',
      'color',
    });

    expect(byColumn['account_type_id']!.label, 'Account Type');
    expect(byColumn['account_type_id']!.lookup!.table, 'account_type');
    expect(byColumn['domain_id']!.label, 'Domain');
    expect(byColumn['domain_id']!.lookup!.table, 'domain');
    expect(byColumn['position']!.defaultValue, 255);
    expect(byColumn['color']!.defaultValue, '#FFFFFF');
  });

  for (final table in ['supplier', 'shipper']) {
    test('$table: matches its pre-conversion shape (hyperlink isLink)', () async {
      final config = await discovery.buildConfig(table);
      expect(config.displayColumn, 'name');
      expect(config.orderBy, 'position, name');
      final byColumn = {for (final f in config.fields) f.column: f};
      expect(byColumn.keys.toSet(), {'name', 'description', 'hyperlink', 'active', 'position', 'color'});
      expect(byColumn['hyperlink']!.label, 'Hyperlink');
      expect(byColumn['hyperlink']!.isLink, isTrue);
      expect(byColumn['position']!.defaultValue, 255);
      expect(byColumn['color']!.defaultValue, '#FFFFFF');
    });
  }

  test('shipment: matches its pre-conversion shape via the reserved field_metadata override', () async {
    final config = await discovery.buildConfig('shipment');
    expect(
      config.displayColumn,
      'order_id',
      reason: 'from the reserved _display_column field_metadata row, not derivable by heuristic alone',
    );
    expect(
      config.orderBy,
      'order_date DESC, id DESC',
      reason: 'from the reserved _order_by field_metadata row',
    );

    final byColumn = {for (final f in config.fields) f.column: f};
    expect(byColumn.keys.toSet(), {
      'supplier_id',
      'order_date',
      'due_date',
      'received_date',
      'domain_id',
      'order_id',
      'order_link',
      'shipper_id',
      'tracking_id',
      'tracking_link',
      'items',
      'note',
    });

    expect(byColumn['supplier_id']!.label, 'Supplier');
    expect(byColumn['supplier_id']!.lookup!.table, 'supplier');
    expect(byColumn['order_date']!.type, FieldType.date);
    expect(byColumn['due_date']!.type, FieldType.date);
    expect(byColumn['received_date']!.type, FieldType.date);
    expect(byColumn['order_id']!.label, 'Order ID', reason: 'seeded field_metadata override');
    expect(byColumn['order_link']!.isLink, isTrue);
    expect(byColumn['shipper_id']!.lookup!.table, 'shipper');
    expect(byColumn['tracking_id']!.label, 'Tracking ID', reason: 'seeded field_metadata override');
    expect(byColumn['tracking_link']!.isLink, isTrue);
  });

  test('journal: matches its pre-conversion shape with zero field_metadata overrides needed', () async {
    final config = await discovery.buildConfig('journal');
    expect(config.displayColumn, 'entry_time', reason: 'first NOT NULL TEXT column, no name column exists');
    expect(config.orderBy, 'entry_time DESC', reason: 'displayColumn resolved to a dateTime field');

    final byColumn = {for (final f in config.fields) f.column: f};
    expect(byColumn.keys.toSet(), {
      'entry_time',
      'entry',
      'tag',
      'status_id',
      'location',
      'who_id',
      'domain_id',
      'follow_up',
      'scheduled',
      'link',
      'image',
      'file',
      'latitude',
      'longitude',
      'notes',
    });

    expect(byColumn['entry_time']!.type, FieldType.dateTime);
    expect(byColumn['entry_time']!.required, isTrue);
    expect(byColumn['entry']!.required, isTrue);
    expect(byColumn['status_id']!.label, 'Status');
    expect(byColumn['status_id']!.lookup!.table, 'status');
    expect(byColumn['who_id']!.label, 'Who', reason: 'strip _id from who_id -> Who');
    expect(byColumn['who_id']!.lookup!.table, 'person');
    expect(byColumn['domain_id']!.label, 'Domain');
    expect(byColumn['follow_up']!.label, 'Follow Up');
    expect(byColumn['scheduled']!.type, FieldType.boolean);
    expect(byColumn['scheduled']!.defaultValue, false, reason: 'from schema.sql\'s real DEFAULT 0, no override needed');
    expect(byColumn['link']!.isLink, isTrue);
    expect(byColumn['latitude']!.type, FieldType.real);
    expect(byColumn['longitude']!.type, FieldType.real);
  });
}
