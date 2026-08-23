// Regression test for the v2 boolean read-back bug found while building
// CSV import (see CLAUDE.md's "Limited CSV import" write-up) -- confirms
// end to end, against the real pipeline, that a boolean field saved as
// true really does read back as true through GenericDao.getAll() +
// coerceBoolValue, the exact composition GenericFormScreen.initState and
// GenericListScreen._cellValueFor now both use. bool_value_test.dart
// already covers coerceBoolValue's own logic in isolation; this file's job
// is only to prove the real on-disk value (a v2 boolean column is
// physically TEXT, per SchemaEditorService.addField) actually round-trips
// through it correctly, not assumed from the pure-Dart test alone.
//
// **Run this file on its own** -- `flutter test test/bool_value_end_to_end_test.dart`
// -- never chained with other schema-engine test files. See CLAUDE.md
// "Essentials v2 Phase 1 -- Step 3"/the real-device verification session
// for why.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/schema_registry.dart';
import 'package:essentials_app/util/bool_value.dart';
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

  test('a boolean field saved as true reads back as true, not silently false', () async {
    final tableName = await editor.createTable(displayName: 'Bool Roundtrip $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Active', format: 'boolean');

    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);

    await dao.insert({'active': 1});
    await dao.insert({'active': 0});

    final rows = await dao.getAll();
    // Confirms the real, on-disk shape -- a string, not the int that was
    // written -- is exactly what motivated this fix, checked directly
    // rather than assumed.
    expect(rows.map((r) => r['active']).toSet(), {'1', '0'});

    final coerced = rows.map((r) => coerceBoolValue(r['active'])).toList();
    expect(coerced, containsAll([true, false]));
    expect(coerced.where((v) => v).length, 1);
    expect(coerced.where((v) => !v).length, 1);
  });
}
