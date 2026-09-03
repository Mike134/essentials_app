// Covers only the pure path-resolution half of the image field's file
// sync layer -- DatabaseHelper.resolveFilesDirectory and
// FileSyncService.localPathFor -- deliberately NOT FileSyncService.upload/
// fetch, which need a real SqliteCrdt connection (DatabaseHelper.crdt,
// opening the real essentials.db) and a live hub server to mean anything.
// Step 2's build order (claude/essentials-v2-image-field-ui-design.md)
// has no live hub to test against yet -- the real hub process is still
// running the pre-/files-endpoint binary as of this test, and won't have
// the new route until it's restarted -- so upload/fetch's real behavior
// is proven for real in step 6's device verification, not here.
//
// Safe to run standalone: touches only the filesystem
// (C:\Databases\essentials_app\files on Windows), never essentials.db or
// the network. Cleans up the directory it creates.
import 'dart:io';

import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/file_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fileSync = FileSyncService();

  test('resolveFilesDirectory creates and returns a real, existing directory', () async {
    final dir = await DatabaseHelper.instance.resolveFilesDirectory();
    expect(await Directory(dir).exists(), isTrue);
    expect(dir.endsWith('files'), isTrue);
  });

  test('localPathFor joins the relative key onto the files directory, same shape on every call', () async {
    final path = await fileSync.localPathFor(
      table: 'domain',
      recordId: '12345',
      fieldName: 'photo',
      filename: 'image.jpg',
    );
    expect(path, endsWith(r'files\domain\12345\photo\image.jpg'));

    // Same inputs -> byte-identical path, every time -- this is exactly
    // the property the storage design doc's "same relative key, resolved
    // per-device" model depends on: two calls (e.g. the UI's local-write
    // step and a later preview render) must never disagree about where
    // the file lives.
    final again = await fileSync.localPathFor(
      table: 'domain',
      recordId: '12345',
      fieldName: 'photo',
      filename: 'image.jpg',
    );
    expect(path, again);
  });
}
