import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../util/sql_identifiers.dart';
import '../util/sql_statements.dart';
import 'database_helper.dart';

class MigrationLogEntry {
  MigrationLogEntry({
    required this.id,
    required this.sqlText,
    required this.description,
    required this.createdAt,
  });

  factory MigrationLogEntry.fromRow(Map<String, Object?> row) => MigrationLogEntry(
    id: row['id'] as int,
    sqlText: row['sql_text'] as String,
    description: row['description'] as String?,
    createdAt: row['created_at'] as String,
  );

  final int id;
  final String sqlText;
  final String? description;
  final String createdAt;
}

/// One `migration_status` row -- `outcome` is `null` only for the
/// synthetic "not yet reported" entries [MigrationDao.statusFor] adds for
/// a known device with no row for this particular migration; every real
/// row from the table has a non-null `outcome`.
class MigrationStatusEntry {
  MigrationStatusEntry({
    required this.deviceId,
    required this.outcome,
    required this.errorMessage,
    required this.attemptedAt,
  });

  final String deviceId;
  final String? outcome;
  final String? errorMessage;
  final String? attemptedAt;

  bool get notYetReported => outcome == null;
}

/// A DROP TABLE/DROP COLUMN in a submitted migration that's still
/// structurally referenced elsewhere in the live schema -- blocks
/// submission until the SQL is changed. Same `RESTRICT`-aware spirit as
/// `essentials_app`'s `GenericDao.findBlockingReferences`, applied one
/// layer up: at the schema level (any FK reference blocks, not just a
/// live-row count), since dropping the table/column breaks the
/// constraint's very existence, not just today's data.
class SchemaSafetyBlocker {
  SchemaSafetyBlocker({required this.statement, required this.blockedBy});

  final String statement;
  final List<String> blockedBy;
}

class MigrationDao {
  Future<SqliteCrdt> get _crdt async => DatabaseHelper.instance.crdt;

  Future<List<MigrationLogEntry>> history() async {
    final crdt = await _crdt;
    final rows = await crdt.query(
      'SELECT * FROM migration_log WHERE is_deleted = 0 ORDER BY id DESC',
    );
    return [for (final row in rows) MigrationLogEntry.fromRow(row)];
  }

  /// Every real device that has ever reported a status for *any*
  /// migration, alphabetically -- the full device roster this tool can
  /// meaningfully show (a device that's never connected since this
  /// migration system existed has no row anywhere to derive its name
  /// from).
  Future<List<String>> knownDeviceIds() async {
    final crdt = await _crdt;
    final rows = await crdt.query(
      'SELECT DISTINCT device_id FROM migration_status WHERE is_deleted = 0 ORDER BY device_id',
    );
    return [for (final row in rows) row['device_id'] as String];
  }

  /// [migrationId]'s status across every known device -- including a
  /// synthetic not-yet-reported entry (see [MigrationStatusEntry]) for any
  /// known device with no real row for this migration yet, so the status
  /// view can show "not yet reported" rather than just omitting the
  /// device entirely.
  Future<List<MigrationStatusEntry>> statusFor(int migrationId) async {
    final crdt = await _crdt;
    final devices = await knownDeviceIds();
    final rows = await crdt.query(
      'SELECT * FROM migration_status WHERE is_deleted = 0 AND migration_id = ?1',
      [migrationId],
    );
    final byDevice = {for (final row in rows) row['device_id'] as String: row};

    return [
      for (final deviceId in devices)
        if (byDevice[deviceId] case final row?)
          MigrationStatusEntry(
            deviceId: deviceId,
            outcome: row['outcome'] as String?,
            errorMessage: row['error_message'] as String?,
            attemptedAt: row['attempted_at'] as String?,
          )
        else
          MigrationStatusEntry(deviceId: deviceId, outcome: null, errorMessage: null, attemptedAt: null),
    ];
  }

  /// Detects `DROP TABLE <t>` / `ALTER TABLE <t> DROP COLUMN <c>`
  /// statements in [sqlText] and checks the live hub.db schema for any
  /// other table's FK still pointing at the dropped table (any column) or
  /// specifically at the dropped column. Returns one [SchemaSafetyBlocker]
  /// per statement that would break something -- an empty list means
  /// nothing here needs the check, or nothing blocking was found.
  Future<List<SchemaSafetyBlocker>> checkDropSafety(String sqlText) async {
    final crdt = await _crdt;
    final blockers = <SchemaSafetyBlocker>[];

    for (final statement in splitSqlStatements(sqlText)) {
      final dropTable = RegExp(
        r'^\s*DROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?"?([A-Za-z_][A-Za-z0-9_]*)"?\s*$',
        caseSensitive: false,
      ).firstMatch(statement);
      final dropColumn = RegExp(
        r'^\s*ALTER\s+TABLE\s+"?([A-Za-z_][A-Za-z0-9_]*)"?\s+DROP\s+COLUMN\s+"?([A-Za-z_][A-Za-z0-9_]*)"?\s*$',
        caseSensitive: false,
      ).firstMatch(statement);

      if (dropTable != null) {
        final table = dropTable.group(1)!;
        final refs = await _referencesTo(crdt, table: table, column: null);
        if (refs.isNotEmpty) {
          blockers.add(SchemaSafetyBlocker(statement: statement, blockedBy: refs));
        }
      } else if (dropColumn != null) {
        final table = dropColumn.group(1)!;
        final column = dropColumn.group(2)!;
        final refs = await _referencesTo(crdt, table: table, column: column);
        if (refs.isNotEmpty) {
          blockers.add(SchemaSafetyBlocker(statement: statement, blockedBy: refs));
        }
      }
    }

    return blockers;
  }

  /// Every other real table's FK pointing at `<table>` (any column, when
  /// [column] is null -- the DROP TABLE case) or specifically at
  /// `<table>(<column>)` (the DROP COLUMN case). Formatted as
  /// `"other_table.fk_column"` strings for display.
  Future<List<String>> _referencesTo(
    SqliteCrdt crdt, {
    required String table,
    required String? column,
  }) async {
    final allTables = await crdt.query("SELECT name FROM sqlite_master WHERE type = 'table'");
    final blockedBy = <String>[];

    for (final row in allTables) {
      final otherTable = row['name'] as String;
      if (otherTable == table) continue;
      assertSafeSqlIdentifier(otherTable);

      final foreignKeys = await crdt.query('PRAGMA foreign_key_list("$otherTable")');
      for (final fk in foreignKeys) {
        if (fk['table'] != table) continue;
        if (column != null && fk['to'] != column) continue;
        blockedBy.add('$otherTable.${fk['from']}');
      }
    }

    return blockedBy;
  }

  /// Writes a new `migration_log` row via `crdt.execute()` -- the only way
  /// this write gets a real `hlc`/`node_id`/`modified` and actually syncs
  /// to `essentials_app`/`server` (see CLAUDE.md). `id` is
  /// `AUTOINCREMENT` (safe here -- centrally authored from this one tool,
  /// not independently written by multiple devices the way every other
  /// table's `id` scheme has to guard against), so it's always omitted
  /// from the INSERT and left to SQLite.
  Future<void> submit({required String sqlText, required String description}) async {
    final crdt = await _crdt;
    final createdAt = DateTime.now().toUtc().toIso8601String();
    await crdt.execute(
      'INSERT INTO migration_log (sql_text, description, created_at) VALUES (?1, ?2, ?3)',
      [sqlText, description, createdAt],
    );
  }
}
