// ignore_for_file: avoid_print
// Image field design, build order step 6 (real-device verification) -- see
// claude/essentials-v2-image-field-ui-design.md. Creates a real throwaway
// table through the actual app-facing SchemaEditorService/GenericDao (not
// raw SQL), with one seed row already inserted so the image field's
// disabled-until-saved gate is already satisfied -- open this row on
// MIKE-12R and MIKE-CU and the Camera/Choose Photo/Browse/drag-and-drop
// affordances are immediately live, no separate "add a row first" step.
//
//   flutter test tool/create_image_test_table.dart
//
// (Not `dart run` -- SchemaEditorService transitively imports
// `package:flutter/widgets.dart` via TableConfig, which crashes the
// vanilla Dart SDK's compiler; `flutter test` on a bare `main()` with no
// `test()` calls runs it to completion fine -- see CLAUDE.md "Essentials
// v2 Phase 1 -- Step 5" for the same gotcha hit there first.)
//
// Paired with tool/remove_image_test_table.dart once the real-device pass
// is confirmed working in both directions.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_registry.dart';

const displayName = 'Image Field Test';

Future<void> main() async {
  final editor = SchemaEditorService();
  final registry = SchemaRegistry();

  print('Creating "$displayName"...');
  final tableName = await editor.createTable(
    displayName: displayName,
    description: 'Image field design, build order step 6 real-device '
        'verification test data. Safe to delete once confirmed working on '
        'both MIKE-CU and MIKE-12R -- see tool/remove_image_test_table.dart.',
  );
  print('  table_name: $tableName');

  print('Adding "Name" (text, primary field)...');
  await editor.addField(tableName: tableName, displayName: 'Name', format: 'text');

  print('Adding "Photo" (image)...');
  await editor.addField(tableName: tableName, displayName: 'Photo', format: 'image');

  final config = await registry.buildConfig(tableName);
  final dao = GenericDao(config);

  print('Inserting one seed row (so the image field is immediately usable, '
      'no "add a row first" step)...');
  final id = await dao.insert({'name': 'Test record'});
  print('  #$id  Test record');

  print('');
  print('Done. On each device: launch essentials_app, open "$displayName", '
      'open the "Test record" row, and try adding/replacing the photo.');
  await DatabaseHelper.instance.close();
}
