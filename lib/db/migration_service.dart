import 'dart:convert';
import 'dart:io';

import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../util/device_id.dart';
import '../util/sql_statements.dart';
import 'database_helper.dart';
import 'sql_helpers.dart';
import 'sync_service.dart';

/// Applies `migration_log` entries this device hasn't yet recorded as
/// `succeeded` in `migration_status` -- see CLAUDE.md "schema_admin --
/// migration authoring tool" for the full design. Built independently
/// here and in `server/bin/server.dart` (separate processes, separate
/// lifecycles, neither inherits the other's logic -- same duplication
/// reasoning as `safeChangesetBuilder`).
///
/// **Real bug, found in Part D live verification, not theorized -- and
/// why [fetchFromServer] exists.** The first design here just re-ran
/// [applyPending] before `SyncService.connect` and again on every
/// `onConnect`, assuming that would be enough. It wasn't: `crdt_sync`'s
/// catch-up merge is one all-or-nothing transaction across every table in
/// the changeset (the same "one missing column poisoned the entire batch"
/// failure mode as the `aggregate`/`group_column`/`row_color_column`
/// incident -- CLAUDE.md "Debugging session, continued"). Once *any* peer
/// has applied a migration, its outgoing row data for the migrated table
/// carries the new column; a device that hasn't applied that migration yet
/// can't merge those rows ("no such column") -- and confirmed live against
/// MIKE-12R, that failure rolled back `migration_log` in the very same
/// batch too, so the device could never even learn about the migration
/// that would fix it. A genuine infinite loop, reproduced for real (three
/// failed reconnects, 15+ minutes, zero progress) before this fix.
///
/// **Fix:** [fetchFromServer] pulls pending `migration_log` rows over a
/// plain HTTP endpoint (`server.dart`'s `/migrations`) that doesn't go
/// through `crdt_sync` at all, and [applyPending] runs immediately after --
/// both *before* [SyncService.connect] ever opens the risky websocket
/// connection. By the time the schema-dependent merge happens, this
/// device's schema already matches, so the failure mode above can't occur
/// on this path anymore.
class MigrationService {
  Future<SqliteCrdt> get _crdt async => DatabaseHelper.instance.crdt;

  /// Fetches every live `migration_log` row from the server's plain-HTTP
  /// side-channel and inserts any this device doesn't already have --
  /// through `crdt.upsert()` like every other write in this app, so it
  /// gets a real, freshly-scoped `hlc`/`node_id`/`modified` under this
  /// device's own identity (not hand-copied from the server's row -- see
  /// `server.dart`'s endpoint doc comment for why that's fine: the
  /// business columns are what matter, and they're identical either way).
  /// Silently gives up on any network failure (server unreachable, no
  /// connectivity) -- this is a best-effort head start, not a hard
  /// dependency; [applyPending] alone still handles anything already
  /// synced from a previous session, and `SyncService`'s own retry loop
  /// covers the rest once a connection succeeds.
  Future<void> fetchFromServer() async {
    final crdt = await _crdt;
    try {
      final address = await SyncService.resolveServerAddress(crdt);
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse('http://$address/migrations'));
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) return;
        final body = await response.transform(utf8.decoder).join();
        final rows = jsonDecode(body) as List<Object?>;

        final existing = await crdt.query('SELECT id FROM migration_log');
        final existingIds = {for (final row in existing) row['id'] as int};

        for (final row in rows.cast<Map<String, Object?>>()) {
          final id = row['id'] as int;
          if (existingIds.contains(id)) continue;
          await crdt.upsert('migration_log', {
            'id': id,
            'sql_text': row['sql_text'],
            'description': row['description'],
            'created_at': row['created_at'],
          });
        }
      } finally {
        client.close();
      }
    } catch (e) {
      // ignore: avoid_print
      print('[MigrationService] fetchFromServer failed (will retry once '
          'SyncService connects): $e');
    }
  }

  /// Applies every not-yet-succeeded, not-yet-halted migration for this
  /// device, in strict `id` order. Stops at the first migration that's
  /// already recorded `failed` for this device (stays halted, no silent
  /// retry) or that fails on this attempt.
  Future<void> applyPending() async {
    final crdt = await _crdt;
    final deviceId = await DeviceId.resolve();

    final logRows = await crdt.query(
      'SELECT id, sql_text FROM migration_log WHERE is_deleted = 0 ORDER BY id ASC',
    );
    final statusRows = await crdt.query(
      'SELECT migration_id, outcome FROM migration_status '
      'WHERE is_deleted = 0 AND device_id = ?1',
      [deviceId],
    );
    final outcomeByMigration = {
      for (final row in statusRows) row['migration_id'] as int: row['outcome'] as String,
    };

    for (final row in logRows) {
      final migrationId = row['id'] as int;
      final sqlText = row['sql_text'] as String;
      final existingOutcome = outcomeByMigration[migrationId];

      if (existingOutcome == 'succeeded') continue;
      if (existingOutcome == 'failed') {
        // Already halted here on a previous run -- stays visibly stuck
        // until Mike fixes/replaces it. No silent auto-retry (see
        // CLAUDE.md -- this is exactly the reconnect-timer-hiding-problems
        // pattern this project has already been burned by once).
        break;
      }

      final succeeded = await _attempt(crdt, deviceId: deviceId, migrationId: migrationId, sqlText: sqlText);
      if (!succeeded) break;
    }
  }

  /// Runs [sqlText] (one or more statements) wrapped in a transaction with
  /// `PRAGMA foreign_keys` off/on around it, then records the outcome.
  /// Returns whether it succeeded.
  Future<bool> _attempt(
    SqliteCrdt crdt, {
    required String deviceId,
    required int migrationId,
    required String sqlText,
  }) async {
    String outcome;
    String? errorMessage;
    try {
      // Must happen outside the transaction -- SQLite only allows toggling
      // this pragma with no pending BEGIN.
      await crdt.execute('PRAGMA foreign_keys = OFF');
      await crdt.transaction((txn) async {
        for (final statement in splitSqlStatements(sqlText)) {
          await txn.execute(statement);
        }
      });
      outcome = 'succeeded';
      errorMessage = null;
    } catch (e) {
      // Real error text, not a generic "it failed" -- schema_admin's
      // status view needs this to actually be useful.
      outcome = 'failed';
      errorMessage = e.toString();
    } finally {
      await crdt.execute('PRAGMA foreign_keys = ON');
    }

    await crdt.upsert('migration_status', {
      'migration_id': migrationId,
      'device_id': deviceId,
      'outcome': outcome,
      'error_message': errorMessage,
      'attempted_at': DateTime.now().toUtc().toIso8601String(),
    });

    return outcome == 'succeeded';
  }
}
