import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../util/device_id.dart';
import '../util/sql_statements.dart';
import 'database_helper.dart';
import 'sql_helpers.dart';

/// Applies `migration_log` entries this device hasn't yet recorded as
/// `succeeded` in `migration_status` -- see CLAUDE.md "schema_admin --
/// migration authoring tool" for the full design. Built independently
/// here and in `server/bin/server.dart` (separate processes, separate
/// lifecycles, neither inherits the other's logic -- same duplication
/// reasoning as `safeChangesetBuilder`).
///
/// **Known gap, deliberately not fully closable with this stack:** running
/// this before [SyncService.connect] (see `HomeShell`) only guarantees
/// migrations already synced from a *previous* session are applied before
/// this session's own data processing starts. A `migration_log` row and
/// data that depends on its new column can still arrive together in the
/// very first catch-up pull of *this* session -- `crdt_sync`'s merge is
/// opaque and changeset-wide, there's no hook to apply a migration
/// mid-changeset (the same architectural limit documented for the
/// `aggregate`/`group_column`/`row_color_column` missing-column incident,
/// just inverted). Mitigated, not eliminated: [applyPending] is also
/// re-run from `SyncService`'s `onConnect` (every connect, including the
/// periodic reconnect), so a migration that arrives in one changeset gets
/// applied promptly, and if a same-batch data merge failed as a result,
/// the already-existing periodic-reconnect retry (see CLAUDE.md "Open
/// items") picks it up on the next cycle once the migration is already
/// in place locally.
class MigrationService {
  Future<SqliteCrdt> get _crdt async => DatabaseHelper.instance.crdt;

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
