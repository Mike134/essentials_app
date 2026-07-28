import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../util/sql_identifiers.dart';
import 'database_helper.dart';
import 'table_discovery_service.dart';

/// SQL storage type for a column added via [SchemaEditorService.addColumn].
/// [boolean] is a convenience preset, not a real SQLite type -- SQLite has
/// none (see [TableDiscoveryService._deriveType]'s doc comment) -- it
/// generates `INTEGER NOT NULL DEFAULT 0/1`, the exact shape that
/// heuristic already recognizes as boolean.
enum NewColumnType { text, integer, real, boolean }

/// Runs `ALTER TABLE ... ADD COLUMN` directly against this device's own
/// `essentials.db`, for [AddColumnScreen]. Deliberately single-device --
/// see CLAUDE.md "Letos/DBeaver workflow going forward": sqlite_crdt has
/// no mechanism to propagate a schema change to any other copy (MIKE-12R,
/// the server's `hub.db`), so Mike still has to trigger this same
/// screen/DDL on each device by hand. What this buys over hand-typed SQL
/// in Letos/DBeaver is that the exact same generated DDL runs everywhere
/// -- no risk of a typo making one device's column subtly different from
/// another's (wrong type, missing default) -- and it solves the problem
/// for MIKE-12R, which has no Letos at all.
///
/// `crdt.execute()` passes `ALTER TABLE` straight through unmodified --
/// only `CREATE TABLE` gets sqlite_crdt's bookkeeping-column rewrite (the
/// exact code path with the sqlparser bug that drops a bare `key` column,
/// see CLAUDE.md) -- so this doesn't share that risk.
class SchemaEditorService {
  SchemaEditorService({TableDiscoveryService? discovery})
    : _discovery = discovery ?? TableDiscoveryService();

  final TableDiscoveryService _discovery;

  Future<SqliteCrdt> get _db async => DatabaseHelper.instance.crdt;

  /// Names not allowed for a new column -- sqlite_crdt's own bookkeeping
  /// columns (would collide with the sync layer) and `id` (always the
  /// structural surrogate key, see schema.sql).
  static const Set<String> _reservedColumnNames = {'id', ...crdtBookkeepingColumns};

  Future<List<String>> tableNames() => _discovery.discoverTableNames();

  /// [tableName]'s current column names (lowercased), including `id` and
  /// the bookkeeping columns -- used to reject a duplicate before SQLite
  /// itself does, with a friendlier message.
  Future<Set<String>> existingColumnNames(String tableName) async {
    assertSafeSqlIdentifier(tableName);
    final db = await _db;
    final rows = await db.query('PRAGMA table_info("$tableName")');
    return {for (final row in rows) (row['name'] as String).toLowerCase()};
  }

  /// Builds the `ALTER TABLE` statement [addColumn] would run, without
  /// running it -- [AddColumnScreen] shows this live as a preview, and
  /// afterward as the text to copy for applying identically to the
  /// server's `hub.db` (which doesn't run this app, so can't run this
  /// screen itself).
  ///
  /// Throws [ArgumentError] for an invalid default (not parseable as the
  /// chosen [type]) -- caught and shown inline by [AddColumnScreen].
  String buildDdl({
    required String tableName,
    required String columnName,
    required NewColumnType type,
    required bool notNull,
    String? defaultValue,
    bool booleanDefault = false,
  }) {
    assertSafeSqlIdentifier(tableName);
    assertSafeSqlIdentifier(columnName);

    final sqlType = switch (type) {
      NewColumnType.text => 'TEXT',
      NewColumnType.integer => 'INTEGER',
      NewColumnType.real => 'REAL',
      NewColumnType.boolean => 'INTEGER',
    };

    final buffer = StringBuffer('ALTER TABLE "$tableName" ADD COLUMN "$columnName" $sqlType');

    if (type == NewColumnType.boolean) {
      // Always NOT NULL with a literal 0/1 default -- exactly the shape
      // TableDiscoveryService._deriveType recognizes as boolean.
      buffer.write(' NOT NULL DEFAULT ${booleanDefault ? 1 : 0}');
    } else if (notNull) {
      // SQLite requires a non-NULL default for a NOT NULL column added via
      // ADD COLUMN, table-empty or not -- enforced here, not left to
      // SQLite's own less friendly rejection.
      buffer.write(' NOT NULL DEFAULT ${_literal(type, defaultValue)}');
    } else if (defaultValue != null && defaultValue.trim().isNotEmpty) {
      buffer.write(' DEFAULT ${_literal(type, defaultValue)}');
    }

    return buffer.toString();
  }

  String _literal(NewColumnType type, String? raw) {
    final value = raw?.trim() ?? '';
    switch (type) {
      case NewColumnType.integer:
        if (int.tryParse(value) == null) {
          throw ArgumentError('Default "$value" is not a whole number.');
        }
        return value;
      case NewColumnType.real:
        if (double.tryParse(value) == null) {
          throw ArgumentError('Default "$value" is not a number.');
        }
        return value;
      case NewColumnType.text:
        return "'${value.replaceAll("'", "''")}'";
      case NewColumnType.boolean:
        return value == '1' ? '1' : '0';
    }
  }

  /// Validates, builds the DDL via [buildDdl], and runs it against this
  /// device's own database. Throws [ArgumentError] for a reserved or
  /// duplicate column name -- caught and shown inline by [AddColumnScreen]
  /// rather than surfacing SQLite's own "duplicate column name" error.
  Future<String> addColumn({
    required String tableName,
    required String columnName,
    required NewColumnType type,
    required bool notNull,
    String? defaultValue,
    bool booleanDefault = false,
  }) async {
    assertSafeSqlIdentifier(tableName);
    assertSafeSqlIdentifier(columnName);
    if (_reservedColumnNames.contains(columnName.toLowerCase())) {
      throw ArgumentError('"$columnName" is reserved and can\'t be used as a column name.');
    }
    final existing = await existingColumnNames(tableName);
    if (existing.contains(columnName.toLowerCase())) {
      throw ArgumentError('"$tableName" already has a column named "$columnName".');
    }

    final ddl = buildDdl(
      tableName: tableName,
      columnName: columnName,
      type: type,
      notNull: notNull,
      defaultValue: defaultValue,
      booleanDefault: booleanDefault,
    );
    final db = await _db;
    await db.execute(ddl);
    return ddl;
  }
}
