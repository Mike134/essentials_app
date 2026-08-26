import 'dart:io';

import 'database_helper.dart';

/// Full-database backup -- Essentials v2 Phase 7, build order step 5.
/// Export-only, no restore UI (see claude/essentials-v2-phase7-design.md's
/// "Confirmed decisions" for why restore is a separate, harder problem,
/// deliberately out of scope here). Produces a single, self-contained,
/// WAL-safe snapshot of the live `essentials.db` via SQLite's own `VACUUM
/// INTO` -- doesn't need to pause sync, close the app, or stop writes.
class DatabaseBackupService {
  /// Writes a full snapshot of `essentials.db` to [destinationPath].
  /// Throws if a file already exists there -- `VACUUM INTO` refuses to
  /// overwrite an existing file (SQLite's own documented behavior), so the
  /// caller must pick a genuinely new filename, not reuse one.
  Future<void> backupTo(String destinationPath) async {
    if (await File(destinationPath).exists()) {
      throw StateError(
        'A file already exists at $destinationPath -- VACUUM INTO refuses to overwrite it.',
      );
    }

    final crdt = await DatabaseHelper.instance.crdt;
    // Run through crdt.execute(), the same live connection every other
    // write in this app already uses -- confirmed safe, not just
    // plausible, by reading sql_crdt's own source (CrdtWriteExecutor
    // .execute): VACUUM has no dedicated statement class in the
    // sqlparser dependency sql_crdt uses to rewrite CREATE TABLE/INSERT/
    // UPDATE/DELETE, so "VACUUM INTO '...'" parses as an InvalidStatement
    // and falls straight through to plain, unmodified execution against
    // the underlying sqflite connection -- the exact same fallback path
    // the already-working `PRAGMA journal_mode`/`PRAGMA foreign_keys`
    // statements in database_helper.dart already rely on (PRAGMA has no
    // dedicated statement class in sqlparser either, confirmed the same
    // way). Escapes the path as a SQL string literal by doubling embedded
    // single quotes, same convention SchemaEditorService.addField already
    // uses for its own default-value literal.
    final escaped = destinationPath.replaceAll("'", "''");
    await crdt.execute("VACUUM INTO '$escaped'");
  }

  /// A reasonable default filename -- `essentials_backup_YYYY-MM-DD.db`,
  /// matching the design doc's own example.
  String suggestedFileName() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'essentials_backup_${now.year}-${two(now.month)}-${two(now.day)}.db';
  }
}
