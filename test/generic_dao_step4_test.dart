// Proves Essentials v2 Phase 4 build order step 4 -- GenericDao
// .getLinkedRecordOptions/.getReverseLinks -- against the REAL
// essentials.db. Run with
// `flutter test test/generic_dao_step4_test.dart` on its own, never
// chained with another SchemaEditorService.createTable-using test file
// (see CLAUDE.md "Essentials v2 Phase 1 -- Step 3" for why).
import 'dart:convert';

import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/schema_registry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/schema_test_cleanup.dart';

void main() {
  final editor = SchemaEditorService();
  final registry = SchemaRegistry();
  final metadata = SchemaMetadataDao();
  final runTag = DateTime.now().microsecondsSinceEpoch;

  setUpAll(() async {
    await DatabaseHelper.instance.crdt;
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  Future<String> createTestTable(String label) async {
    final tableName = await editor.createTable(displayName: '$label $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    return tableName;
  }

  Future<int> insertRow(String tableName, [Map<String, Object?> values = const {}]) async {
    final config = await registry.buildConfig(tableName);
    return GenericDao(config).insert(values);
  }

  test('getLinkedRecordOptions returns every live target row, ordered by displayColumn', () async {
    final target = await createTestTable('GDS4 Target A');
    await editor.addField(tableName: target, displayName: 'Name', format: 'text');
    final aId = await insertRow(target, {'name': 'Zeta'});
    final bId = await insertRow(target, {'name': 'Alpha'});

    final linker = await createTestTable('GDS4 Linker A');
    await editor.addField(
      tableName: linker,
      displayName: 'Link',
      format: 'link_record',
      optionsJson: jsonEncode({'table': target, 'multiple': false}),
    );

    final linkerConfig = await registry.buildConfig(linker);
    final field = linkerConfig.fields.firstWhere((f) => f.column == 'link');
    expect(field.isLinkRecord, isTrue);

    final options = await GenericDao(linkerConfig).getLinkedRecordOptions(field.linkRecord!);
    expect(options.map((o) => o['id']), [bId, aId]); // Alpha before Zeta.
  });

  test('getLinkedRecordOptions excludes soft-deleted target rows', () async {
    final target = await createTestTable('GDS4 Target B');
    await editor.addField(tableName: target, displayName: 'Name', format: 'text');
    final targetConfig = await registry.buildConfig(target);
    final keepId = await insertRow(target, {'name': 'Keep'});
    final goneId = await insertRow(target, {'name': 'Gone'});
    await GenericDao(targetConfig).delete(goneId);

    final linker = await createTestTable('GDS4 Linker B');
    await editor.addField(
      tableName: linker,
      displayName: 'Link',
      format: 'link_record',
      optionsJson: jsonEncode({'table': target, 'multiple': true}),
    );
    final linkerConfig = await registry.buildConfig(linker);
    final field = linkerConfig.fields.firstWhere((f) => f.column == 'link');

    final options = await GenericDao(linkerConfig).getLinkedRecordOptions(field.linkRecord!);
    expect(options.map((o) => o['id']), [keepId]);
  });

  test('getReverseLinks groups by referencing table, excludes soft-deleted referencing rows', () async {
    final target = await createTestTable('GDS4 Target C');
    final targetConfig = await registry.buildConfig(target);
    final targetId = await insertRow(target);

    final linkerA = await createTestTable('GDS4 Linker C1');
    await editor.addField(
      tableName: linkerA,
      displayName: 'Link',
      format: 'link_record',
      optionsJson: jsonEncode({'table': target, 'multiple': true}),
    );
    final linkerAConfig = await registry.buildConfig(linkerA);
    await GenericDao(
      linkerAConfig,
    ).insert({'link': jsonEncode([targetId])});
    final staleId = await GenericDao(
      linkerAConfig,
    ).insert({'link': jsonEncode([targetId])});
    await GenericDao(linkerAConfig).delete(staleId);

    final linkerB = await createTestTable('GDS4 Linker C2');
    await editor.addField(
      tableName: linkerB,
      displayName: 'Owner',
      format: 'link_record',
      optionsJson: jsonEncode({'table': target, 'multiple': false}),
    );
    final linkerBConfig = await registry.buildConfig(linkerB);
    await GenericDao(
      linkerBConfig,
    ).insert({'owner': jsonEncode([targetId])});

    final links = await GenericDao(targetConfig).getReverseLinks(targetId);
    final byTable = {for (final group in links) group.tableName: group};

    expect(byTable.keys, containsAll([linkerA, linkerB]));
    expect(byTable[linkerA]!.rows, hasLength(1)); // the soft-deleted one is excluded.
    expect(byTable[linkerB]!.rows, hasLength(1));
    expect(byTable[linkerB]!.fieldDisplayName, 'Owner');
  });

  test('getReverseLinks returns nothing for a row with no live back-references', () async {
    final target = await createTestTable('GDS4 Target D');
    final targetConfig = await registry.buildConfig(target);
    final targetId = await insertRow(target);

    final links = await GenericDao(targetConfig).getReverseLinks(targetId);
    expect(links, isEmpty);
  });

  // Real usability gap, found live: with no v2 table's UI ever setting
  // `table_definitions.display_field`, every ReverseLink used to show a
  // bare id -- "just click and see," per Mike's own words, once a row had
  // more than one linked record. displayColumn now falls back to the
  // referencing table's first field by position, not just `display_field`.
  test(
    "getReverseLinks' displayColumn falls back to the referencing table's first field",
    () async {
      final target = await createTestTable('GDS4 Target E');
      final targetConfig = await registry.buildConfig(target);
      final targetId = await insertRow(target);

      final linker = await createTestTable('GDS4 Linker E');
      await editor.addField(tableName: linker, displayName: 'Task Name', format: 'text');
      await editor.addField(
        tableName: linker,
        displayName: 'Link',
        format: 'link_record',
        optionsJson: jsonEncode({'table': target, 'multiple': false}),
      );
      final linkerConfig = await registry.buildConfig(linker);
      await GenericDao(
        linkerConfig,
      ).insert({'task_name': 'Write the report', 'link': jsonEncode([targetId])});

      final links = await GenericDao(targetConfig).getReverseLinks(targetId);
      expect(links, hasLength(1));
      expect(links.first.displayColumn, 'task_name');
      expect(links.first.rows.single['task_name'], 'Write the report');
    },
  );

  test(
    'getReverseLinks.displayColumn falls back to the link field itself when it is the only field',
    () async {
      final target = await createTestTable('GDS4 Target F');
      final targetConfig = await registry.buildConfig(target);
      final targetId = await insertRow(target);

      final linker = await createTestTable('GDS4 Linker F');
      await editor.addField(
        tableName: linker,
        displayName: 'Link',
        format: 'link_record',
        optionsJson: jsonEncode({'table': target, 'multiple': false}),
      );
      final linkerConfig = await registry.buildConfig(linker);
      await GenericDao(linkerConfig).insert({'link': jsonEncode([targetId])});

      final links = await GenericDao(targetConfig).getReverseLinks(targetId);
      // The link field itself is this table's only (and therefore first)
      // field -- a real, if narrow, case, worth documenting rather than
      // leaving a surprise: `displayColumn` is never actually `null` in
      // practice through the schema engine, since a referencing table
      // always has at least the field that made it show up here at all.
      expect(links.single.displayColumn, 'link');
    },
  );

  // Real bug, found live: a target table with no `name` column (its own
  // text field named something else, e.g. `condition`) crashed
  // `SELECT * FROM <table> ORDER BY name` outright the moment its options
  // JSON didn't set an explicit `displayField` -- see AddFieldScreen's
  // "Which field to show" picker (autoDisplayField), which now writes an
  // explicit, verified-to-exist column for every *new* field, and
  // GenericDao._resolveDisplayColumn, the safety net for fields that
  // predate that picker or whose options were hand-edited.
  group('display column resilience (no name column on target)', () {
    test('getLookupOptions falls back to id and never crashes', () async {
      final target = await createTestTable('GDS4 No Name Target A');
      await editor.addField(tableName: target, displayName: 'Label', format: 'text');
      final aId = await insertRow(target, {'label': 'Zeta'});

      final linker = await createTestTable('GDS4 No Name Linker A');
      await editor.addField(
        tableName: linker,
        displayName: 'Ref',
        format: 'select',
        optionsJson: jsonEncode({'mode': 'linked', 'table': target}), // no displayField -- the bug's exact shape.
      );
      final linkerConfig = await registry.buildConfig(linker);
      final field = linkerConfig.fields.firstWhere((f) => f.column == 'ref');

      final options = await GenericDao(linkerConfig).getLookupOptions(field.lookup!);
      expect(options, hasLength(1));
      expect(options.first['name'], aId); // falls back to the row's id, not a crash.
    });

    test('getLinkedRecordOptions falls back to id and never crashes', () async {
      final target = await createTestTable('GDS4 No Name Target B');
      await editor.addField(tableName: target, displayName: 'Label', format: 'text');
      final aId = await insertRow(target, {'label': 'Zeta'});

      final linker = await createTestTable('GDS4 No Name Linker B');
      await editor.addField(
        tableName: linker,
        displayName: 'Ref',
        format: 'link_record',
        optionsJson: jsonEncode({'table': target, 'multiple': false}), // no displayField.
      );
      final linkerConfig = await registry.buildConfig(linker);
      final field = linkerConfig.fields.firstWhere((f) => f.column == 'ref');

      final options = await GenericDao(linkerConfig).getLinkedRecordOptions(field.linkRecord!);
      expect(options, hasLength(1));
      expect(options.first['name'], aId);
    });

    test('an explicit displayField naming a real column is used as-is, no fallback', () async {
      final target = await createTestTable('GDS4 Real Display Target');
      await editor.addField(tableName: target, displayName: 'Label', format: 'text');
      await insertRow(target, {'label': 'Zeta'});
      await insertRow(target, {'label': 'Alpha'});

      final linker = await createTestTable('GDS4 Real Display Linker');
      await editor.addField(
        tableName: linker,
        displayName: 'Ref',
        format: 'link_record',
        optionsJson: jsonEncode({'table': target, 'multiple': false, 'displayField': 'label'}),
      );
      final linkerConfig = await registry.buildConfig(linker);
      final field = linkerConfig.fields.firstWhere((f) => f.column == 'ref');

      final options = await GenericDao(linkerConfig).getLinkedRecordOptions(field.linkRecord!);
      expect(options.map((o) => o['label']), ['Alpha', 'Zeta']); // real ordering, real column.
    });
  });
}
