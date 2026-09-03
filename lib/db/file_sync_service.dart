import 'dart:io';

import 'package:path/path.dart';

import 'database_helper.dart';
import 'sync_service.dart';

/// Client side of the hub's `/files/...` endpoint -- see
/// claude/essentials-v2-file-transfer-endpoint-design.md and
/// claude/essentials-v2-image-field-ui-design.md. Mirrors
/// [MigrationService.fetchFromServer]'s exact shape: resolve the hub's
/// address via [SyncService.resolveServerAddress] (the same helper the
/// WebSocket connection itself uses), open a plain [HttpClient], and
/// swallow-and-log any failure rather than throwing -- this is a
/// best-effort transfer layer, never something that should block the UI
/// or crash a form save.
///
/// **Deliberately not wired into [SyncService]'s connect/reconnect
/// lifecycle**, unlike [MigrationService.fetchFromServer] -- [upload] is
/// triggered by user action (capture/drop) and [fetch] by render (a Form
/// view actually showing that field), matching the design doc's "lazy
/// pull, not eager push" choice. **Real consequence: a failed [upload]
/// has no retry queue in v1.** If the hub is unreachable at capture time,
/// the image stays local-only (visible on the capturing device, absent
/// from every other device) until something re-triggers an upload for
/// that same field -- there is no background pass that notices and
/// retries it. Accepted for now as a known gap, not a designed-in
/// guarantee; worth a real retry/backoff story if this turns out to bite
/// in practice (offline capture is exactly the case the earlier design
/// discussion flagged as still open).
class FileSyncService {
  /// Where `{table}/{record_id}/{field_name}/{filename}` resolves to on
  /// this device's own disk -- shared by [fetch] (where to save a pulled
  /// file) and by the UI's own local-write step at capture/drop time
  /// (where to write before ever calling [upload]), so both sides agree
  /// on the exact same path without duplicating the join logic.
  Future<String> localPathFor({
    required String table,
    required String recordId,
    required String fieldName,
    required String filename,
  }) async {
    final root = await DatabaseHelper.instance.resolveFilesDirectory();
    return join(root, table, recordId, fieldName, filename);
  }

  /// Uploads [localFile]'s bytes to the hub, keyed by the same relative
  /// key [localPathFor] would resolve locally. Fire-and-forget from the
  /// caller's perspective -- the caller's own local write (and therefore
  /// its own preview) already happened before this is ever called, so
  /// nothing about this device's UI depends on the upload succeeding.
  Future<void> upload({
    required String table,
    required String recordId,
    required String fieldName,
    required String filename,
    required File localFile,
  }) async {
    try {
      final crdt = await DatabaseHelper.instance.crdt;
      final address = await SyncService.resolveServerAddress(crdt);
      final client = HttpClient();
      try {
        final request = await client.putUrl(
          Uri.parse('http://$address/files/$table/$recordId/$fieldName/$filename'),
        );
        request.contentLength = await localFile.length();
        await request.addStream(localFile.openRead());
        final response = await request.close();
        await response.drain<void>();
        if (response.statusCode != HttpStatus.ok) {
          // ignore: avoid_print
          print('[FileSyncService] upload failed: HTTP ${response.statusCode} for '
              '$table/$recordId/$fieldName/$filename');
        }
      } finally {
        client.close();
      }
    } catch (e) {
      // ignore: avoid_print
      print('[FileSyncService] upload failed (no retry queue -- see this class\'s '
          'own doc comment): $e');
    }
  }

  /// Pulls the file from the hub if this device doesn't already have it
  /// locally, saving it at the same path [localPathFor] resolves to.
  /// Returns the local [File] on success, `null` on a 404 (an ordinary,
  /// expected outcome -- the hub genuinely doesn't have it, or doesn't
  /// have it yet) or any other failure (hub unreachable, disk error).
  /// Callers (the Form view's preview widget) treat `null` as "show the
  /// placeholder/broken-image state," not as something to surface as an
  /// error.
  ///
  /// Same temp-file-then-rename discipline as the hub's own upload
  /// handler -- a second concurrent [fetch] for the same key (unlikely
  /// but not impossible if a field renders in two places at once) should
  /// never observe a partially-written file under the real name.
  Future<File?> fetch({
    required String table,
    required String recordId,
    required String fieldName,
    required String filename,
  }) async {
    final localPath = await localPathFor(
      table: table,
      recordId: recordId,
      fieldName: fieldName,
      filename: filename,
    );
    if (await File(localPath).exists()) return File(localPath);

    try {
      final crdt = await DatabaseHelper.instance.crdt;
      final address = await SyncService.resolveServerAddress(crdt);
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('http://$address/files/$table/$recordId/$fieldName/$filename'),
        );
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          return null;
        }

        await Directory(dirname(localPath)).create(recursive: true);
        final tempPath = '$localPath.download-tmp';
        final sink = File(tempPath).openWrite();
        await sink.addStream(response);
        await sink.close();
        await File(tempPath).rename(localPath);
        return File(localPath);
      } finally {
        client.close();
      }
    } catch (e) {
      // ignore: avoid_print
      print('[FileSyncService] fetch failed for $table/$recordId/$fieldName/$filename: $e');
      return null;
    }
  }
}
