// Proves the `image` field format end to end through the REAL pipeline --
// SchemaEditorService.addField -> SchemaRegistry.buildConfig ->
// GenericDao.insert/getAll -- against the real essentials.db. Build order
// step 3/4 of the image field design (see
// claude/essentials-v2-image-field-ui-design.md). Scoped the same way the
// existing formula/bool "end to end" tests are: proves the format survives
// the real schema engine and storage round-trip, not
// GenericFormScreen._buildImageField's actual widget behavior -- this
// codebase has no existing precedent for pumping GenericFormScreen itself
// in a test (nothing else does either, even for more mature formats), so
// the capture/preview widget is left to real-device verification (build
// order step 6), same boundary every other format handler here already
// draws.
//
// **Run this file on its own** -- `flutter test test/image_field_end_to_end_test.dart`
// -- never chained with other schema-engine test files. See CLAUDE.md
// "Essentials v2 Phase 1 -- Step 3"/the real-device verification session
// for why.
import 'dart:io';

import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/file_sync_service.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/schema_registry.dart';
import 'package:essentials_app/models/table_config.dart';
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

  test('SchemaRegistry builds an image field as a plain, writable text-shaped column', () async {
    final tableName = await editor.createTable(displayName: 'Image Field Config $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Photo', format: 'image');

    final config = await registry.buildConfig(tableName);
    final photo = config.fields.firstWhere((f) => f.column == 'photo');

    expect(photo.format, 'image');
    // Falls through to FieldType.text, same as link_file/barcode -- image
    // has no dedicated SchemaRegistry._formatToFieldType branch, per
    // ImageFormatHandler's own doc comment.
    expect(photo.type, FieldType.text);
    expect(photo.readOnly, isFalse);
  });

  test('a relative-key value round-trips through insert/getAll unchanged', () async {
    final tableName = await editor.createTable(displayName: 'Image Field Roundtrip $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Photo', format: 'image');

    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);

    final relativeKey = '$tableName/12345/photo/image.jpg';
    await dao.insert({'photo': relativeKey});

    final rows = await dao.getAll();
    expect(rows.single['photo'], relativeKey);
  });

  test('an empty/null image field stores and reads back as null, same as any other text field', () async {
    final tableName = await editor.createTable(displayName: 'Image Field Empty $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Photo', format: 'image');

    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);

    await dao.insert({});

    final rows = await dao.getAll();
    expect(rows.single['photo'], isNull);
  });

  test('deleting a record with an image field removes the local file too', () async {
    final tableName = await editor.createTable(displayName: 'Image Field Delete $runTag');
    addTearDown(() => dropTestTable(editor, metadata, tableName));
    await editor.addField(tableName: tableName, displayName: 'Photo', format: 'image');

    final config = await registry.buildConfig(tableName);
    final dao = GenericDao(config);
    final fileSync = FileSyncService();

    final id = await dao.insert({});
    final relativeKey = '$tableName/$id/photo/image.jpg';
    await dao.update(id, {'photo': relativeKey});

    // Simulate the local write GenericFormScreen._ingestPickedImage does
    // at capture time -- this test doesn't need a real image, just a real
    // file at the exact path GenericDao.delete's cleanup step resolves to.
    final localPath = await fileSync.localPathFor(
      table: tableName,
      recordId: id.toString(),
      fieldName: 'photo',
      filename: 'image.jpg',
    );
    await Directory(localPath.substring(0, localPath.lastIndexOf(Platform.pathSeparator))).create(
      recursive: true,
    );
    await File(localPath).writeAsBytes([1, 2, 3]);
    expect(await File(localPath).exists(), isTrue);

    await dao.delete(id);

    // The image-cleanup step fires an unawaited FileSyncService.delete --
    // give its local-delete half (synchronous disk I/O, no network) a
    // moment to actually run before asserting.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await File(localPath).exists(), isFalse);
  });
}
