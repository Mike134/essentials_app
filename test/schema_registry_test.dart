// Proves Essentials v2 Phase 1 build order step 4 -- SchemaRegistry
// .buildConfig -- against the REAL essentials.db. Run with
// `flutter test test/schema_registry_test.dart`.
//
// Every table is created through the real SchemaEditorService.createTable/
// addField pipeline (step 3), not hand-inserted, so this also proves the
// two steps compose correctly end to end. Every display name carries a
// per-run-unique tag and cleanup is soft-tombstone only (deleteWhere) --
// see CLAUDE.md "Essentials v2 Phase 1 -- Step 3" for exactly why: a raw
// SQL hard-delete against a CRDT-synced table, done in an earlier session
// for db hygiene between test iterations, caused a real FOREIGN KEY
// constraint failure once a live sync connection had already pushed that
// data to the server. Never doing that again.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/schema_registry.dart';
import 'package:essentials_app/db/sql_helpers.dart';
import 'package:essentials_app/models/table_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'support/schema_test_cleanup.dart';

void main() {
  late SqliteCrdt db;
  final editor = SchemaEditorService();
  final registry = SchemaRegistry();
  final metadata = SchemaMetadataDao();
  final runTag = DateTime.now().microsecondsSinceEpoch;

  setUpAll(() async {
    db = await DatabaseHelper.instance.crdt;
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  /// Creates a throwaway table via the real [SchemaEditorService], tagged
  /// unique to this run, with cleanup registered as this test's own
  /// tearDown -- see [dropTestTable]'s doc comment for why this must be a
  /// real, synced drop, not a raw local `DROP TABLE`.
  Future<String> createTestTable(String label) async {
    final tableName = await editor.createTable(displayName: '$label $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    return tableName;
  }

  test('buildConfig throws for a table with no table_definitions row', () async {
    await expectLater(
      () => registry.buildConfig('no_such_schema_registry_table_at_all'),
      throwsA(isA<SchemaValidationException>()),
    );
  });

  test('buildConfig produces displayColumn/orderBy from table_definitions', () async {
    final tableName = await editor.createTable(
      displayName: 'SR Display Column $runTag',
      description: 'test',
    );
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    // createTable doesn't accept displayField/orderBy yet (no UI to supply
    // them exists -- build order step 7); set them directly the same way
    // a future New Table screen would, via a plain upsert through the
    // real crdt path (not a raw SQL bypass).
    final row = (await db.query(
      'SELECT * FROM table_definitions WHERE table_name = ?1',
      [tableName],
    )).first;
    await db.upsert('table_definitions', {
      ...row,
      'display_field': 'id',
      'order_by': 'id DESC',
    });

    final config = await registry.buildConfig(tableName);
    expect(config.tableName, tableName);
    expect(config.displayColumn, 'id');
    expect(config.orderBy, 'id DESC');
  });

  test('buildConfig falls back to id as displayColumn when display_field is unset', () async {
    final tableName = await createTestTable('SR Default Display Column');
    final config = await registry.buildConfig(tableName);
    expect(config.displayColumn, 'id');
    expect(config.orderBy, isNull);
  });

  test('buildConfig maps a plain text field correctly, in position order', () async {
    final tableName = await createTestTable('SR Field Basics');
    await editor.addField(tableName: tableName, displayName: 'Notes', format: 'text');
    await editor.addField(
      tableName: tableName,
      displayName: 'Status',
      format: 'text',
      required: true,
      defaultValue: 'open',
    );

    final config = await registry.buildConfig(tableName);
    expect(config.fields, hasLength(2));

    final notes = config.fields[0];
    expect(notes.column, 'notes');
    expect(notes.label, 'Notes');
    expect(notes.type, FieldType.text);
    expect(notes.required, isFalse);
    expect(notes.lookup, isNull);

    final status = config.fields[1];
    expect(status.column, 'status');
    expect(status.label, 'Status');
    expect(status.required, isTrue);
    expect(status.defaultValue, 'open');
  });

  test('buildConfig maps format strings to the matching FieldType', () async {
    final tableName = await createTestTable('SR Format Mapping');
    await editor.addField(tableName: tableName, displayName: 'Count', format: 'integer');
    await editor.addField(tableName: tableName, displayName: 'Amount', format: 'real');
    await editor.addField(tableName: tableName, displayName: 'Active', format: 'boolean');
    await editor.addField(tableName: tableName, displayName: 'Due Date', format: 'date');
    await editor.addField(tableName: tableName, displayName: 'Logged At', format: 'dateTime');
    await editor.addField(tableName: tableName, displayName: 'Mystery', format: 'something_unrecognized');

    final config = await registry.buildConfig(tableName);
    final typeByColumn = {for (final f in config.fields) f.column: f.type};
    expect(typeByColumn['count'], FieldType.integer);
    expect(typeByColumn['amount'], FieldType.real);
    expect(typeByColumn['active'], FieldType.boolean);
    expect(typeByColumn['due_date'], FieldType.date);
    expect(typeByColumn['logged_at'], FieldType.dateTime);
    // Unrecognized formats fall back to text, never throw -- same safe
    // default TableDiscoveryService._deriveType already used.
    expect(typeByColumn['mystery'], FieldType.text);
  });

  test('buildConfig maps isLink/isColor from options JSON', () async {
    final tableName = await createTestTable('SR Options Flags');
    await editor.addField(
      tableName: tableName,
      displayName: 'Website',
      format: 'text',
      optionsJson: '{"isLink": true}',
    );
    await editor.addField(
      tableName: tableName,
      displayName: 'Swatch',
      format: 'text',
      optionsJson: '{"isColor": true}',
    );

    final config = await registry.buildConfig(tableName);
    final byColumn = {for (final f in config.fields) f.column: f};
    expect(byColumn['website']!.isLink, isTrue);
    expect(byColumn['website']!.isColor, isFalse);
    expect(byColumn['swatch']!.isColor, isTrue);
    expect(byColumn['swatch']!.isLink, isFalse);
  });

  test('buildConfig resolves a select/linked field into LookupConfig', () async {
    final referencedTable = await createTestTable('SR Lookup Target');
    final tableName = await createTestTable('SR Lookup Source');
    await editor.addField(
      tableName: tableName,
      displayName: 'Owner',
      format: 'select',
      optionsJson: '{"mode": "linked", "table": "$referencedTable", "displayField": "label"}',
    );

    final config = await registry.buildConfig(tableName);
    final owner = config.fields.single;
    expect(owner.type, FieldType.text);
    expect(owner.lookup, isNotNull);
    expect(owner.lookup!.table, referencedTable);
    expect(owner.lookup!.displayColumn, 'label');
    expect(owner.lookup!.valueColumn, 'id'); // default, not overridden here
  });

  test('buildConfig throws when field_definitions references a column that does not physically exist', () async {
    final tableName = await createTestTable('SR Drift Detection');
    // Simulates a migration that landed the field_definitions row (via the
    // real crdt-tracked upsert path, not a raw SQL bypass) but whose
    // ALTER TABLE never actually applied on this device -- exactly the
    // scenario SchemaValidationException exists to catch.
    await db.upsert('field_definitions', {
      'table_name': tableName,
      'field_name': 'never_actually_created',
      'display_name': 'Never Actually Created',
      'format': 'text',
      'required': 0,
      'position': 0,
    });

    await expectLater(
      () => registry.buildConfig(tableName),
      throwsA(
        isA<SchemaValidationException>().having(
          (e) => e.message,
          'message',
          contains('never_actually_created'),
        ),
      ),
    );
  });

  test('discoverTableNames lists a created table and excludes a soft-deleted one', () async {
    final tableName = await createTestTable('SR Discover Me');
    expect(await registry.discoverTableNames(), contains(tableName));
    expect(await registry.tableExists(tableName), isTrue);

    await db.deleteWhere('table_definitions', {'table_name': tableName});
    expect(await registry.discoverTableNames(), isNot(contains(tableName)));
    expect(await registry.tableExists(tableName), isFalse);
  });
}
