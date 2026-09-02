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

  /// A transient SQLite busy/lock error retries a few times before being
  /// recorded as a real failure -- see [_attempt]'s own doc comment for
  /// why this exists.
  static const _maxLockRetries = 3;
  static const _lockRetryDelay = Duration(milliseconds: 300);

  /// True if [message] is SQLite's own "this DDL target already exists"
  /// error -- see the client's identical helper
  /// (`essentials_app/lib/db/migration_service.dart`) for the full
  /// incident write-up this is fixing. A statement that fails this way has
  /// already achieved its goal state, so it's treated as a no-op rather
  /// than a fatal failure -- makes the pipeline self-healing against a
  /// double-application race instead of needing a manual retraction.
  static bool _isAlreadyExistsError(String message) {
    final lower = message.toLowerCase();
    return lower.contains('already exists') || lower.contains('duplicate column name');
  }

  /// **Retries a transient "database is locked" error a few times before
  /// giving up -- a real incident on this exact server, not a
  /// theoretical one.** Once `server.dart`'s `onChangesetReceived` started
  /// triggering this live off incoming changesets (not just startup and
  /// the 5-minute periodic check -- see CLAUDE.md "Real-device final
  /// verification pass" for why that was added), it became newly
  /// possible for this transaction to genuinely overlap with crdt_sync's
  /// *own* internal merge transaction on the same shared `hub.db`
  /// connection. Confirmed live: a real `SqliteException(5): database is
  /// locked` on `COMMIT`, caught by crdt_sync's own try/catch around
  /// `crdt.merge()` and silently swallowed there (same "no ack, no
  /// retry" pattern this project has already documented for a failed
  /// merge elsewhere) -- while a same-shaped failure *here* would have
  /// been recorded as a permanent `'failed'` `migration_status` row, and
  /// [applyPending]'s own halt-on-failure logic would then have
  /// permanently blocked every later migration for the server's own
  /// device over what was really just bad timing, not a real DDL
  /// problem. A locked-database error is definitionally transient (the
  /// other transaction finishes and releases it), so retrying briefly is
  /// the correct response, not halting.
  Future<bool> _attempt({required int migrationId, required String sqlText}) async {
    String outcome = 'failed';
    String? errorMessage;

    for (var attempt = 1; attempt <= _maxLockRetries; attempt++) {
      try {
        // Must happen outside the transaction -- SQLite only allows
        // toggling this pragma with no pending BEGIN.
        await _crdt.execute('PRAGMA foreign_keys = OFF');
        await _crdt.transaction((txn) async {
          for (final statement in splitSqlStatements(sqlText)) {
            try {
              await txn.execute(statement);
            } catch (e) {
              if (_isAlreadyExistsError(e.toString())) {
                continue;
              }
              rethrow;
            }
          }
        });
        outcome = 'succeeded';
        errorMessage = null;
        break;
      } catch (e) {
        final message = e.toString();
        final isTransientLock =
            message.contains('database is locked') || message.contains('SQLITE_BUSY');
        if (isTransientLock && attempt < _maxLockRetries) {
          await Future.delayed(_lockRetryDelay * attempt);
          continue;
        }
        // Real error text, not a generic "it failed".
        outcome = 'failed';
        errorMessage = message;
        break;
      } finally {
        await _crdt.execute('PRAGMA foreign_keys = ON');
      }
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
