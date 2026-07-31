import 'dart:async';

import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'sql_statements.dart';

/// This process's own identity in `migration_status`, deliberately **not**
/// `Platform.localHostname` (`MIKE-CU`) -- the server holds its own
/// separate `hub.db`, a different database file and a different sync peer
/// from MIKE-CU's own `essentials_app` instance (see CLAUDE.md "Server
/// holds its own separate hub-replica file"). Reusing `MIKE-CU` here would
/// conflate two genuinely different devices' migration progress under one
/// name in schema_admin's status view.
const String serverDeviceId = 'server';

/// Same design as `essentials_app/lib/db/migration_service.dart` --
/// duplicated, not shared (separate Dart package, same reasoning as
/// `safeChangesetBuilder`). Applies pending `migration_log` entries in
/// strict order, transaction-wrapped with `PRAGMA foreign_keys` off/on,
/// halting on the first failure (no silent retry) and recording a real
/// `migration_status` row after every attempt.
///
/// Run once at startup, before `HttpServer.bind` starts accepting any
/// client connections -- this fully closes the "apply migrations before
/// processing other queued data sync" requirement for the server, unlike
/// `essentials_app`'s client-side gap (the server has no "reconnect to a
/// remote" step of its own to race against). Also re-run on a timer (see
/// `main()`) since `schema_admin` can write a new `migration_log` row
/// directly into `hub.db` at any time while this process keeps running --
/// there's no push notification for that, only re-checking.
class MigrationService {
  MigrationService(this._crdt);

  final SqliteCrdt _crdt;

  Future<void> applyPending() async {
    final logRows = await _crdt.query(
      'SELECT id, sql_text FROM migration_log WHERE is_deleted = 0 ORDER BY id ASC',
    );
    final statusRows = await _crdt.query(
      'SELECT migration_id, outcome FROM migration_status '
      'WHERE is_deleted = 0 AND device_id = ?1',
      [serverDeviceId],
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
        // until Mike fixes/replaces it. No silent auto-retry.
        break;
      }

      final succeeded = await _attempt(migrationId: migrationId, sqlText: sqlText);
      if (!succeeded) break;
    }
  }

  Future<bool> _attempt({required int migrationId, required String sqlText}) async {
    String outcome;
    String? errorMessage;
    try {
      // Must happen outside the transaction -- SQLite only allows toggling
      // this pragma with no pending BEGIN.
      await _crdt.execute('PRAGMA foreign_keys = OFF');
      await _crdt.transaction((txn) async {
        for (final statement in splitSqlStatements(sqlText)) {
          await txn.execute(statement);
        }
      });
      outcome = 'succeeded';
      errorMessage = null;
    } catch (e) {
      // Real error text, not a generic "it failed".
      outcome = 'failed';
      errorMessage = e.toString();
    } finally {
      await _crdt.execute('PRAGMA foreign_keys = ON');
    }

    await _crdt.execute(
      'INSERT OR REPLACE INTO migration_status '
      '(migration_id, device_id, outcome, error_message, attempted_at) '
      'VALUES (?1, ?2, ?3, ?4, ?5)',
      [migrationId, serverDeviceId, outcome, errorMessage, DateTime.now().toUtc().toIso8601String()],
    );

    return outcome == 'succeeded';
  }
}
