import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'database_helper.dart';

/// One `script_definitions` row -- see
/// claude/essentials-v2-phase5-design.md's "Data model".
class ScriptDefinition {
  ScriptDefinition({
    required this.id,
    required this.name,
    required this.code,
    required this.description,
  });

  factory ScriptDefinition.fromRow(Map<String, Object?> row) => ScriptDefinition(
    id: row['id'] as int,
    name: row['name'] as String,
    code: row['code'] as String,
    description: row['description'] as String?,
  );

  final int id;
  final String name;
  final String code;
  final String? description;
}

/// CRUD for `script_definitions` -- sibling of `TemplateDefinitionsDao`/
/// `ViewDefinitionsDao`, same shared/synced, no-`migration_log` shape (the
/// physical table itself was bootstrapped once, out-of-band, by
/// `tool/add_script_event_tables.dart`, build order step 1). Every method
/// here is a plain row-level CRDT write against an already-existing table
/// -- writing a script's *code* is never DDL, so none of this needs the
/// `SchemaEditorService`/`migration_log` machinery `script_definitions`'
/// own bootstrap did.
class ScriptDefinitionsDao {
  Future<SqliteCrdt> get _db async => DatabaseHelper.instance.crdt;

  /// Every active script, alphabetical -- the natural order for a picker
  /// list (event binding UI) and the script list screen alike.
  Future<List<ScriptDefinition>> loadAll() async {
    final db = await _db;
    final rows = await db.query('SELECT * FROM script_definitions WHERE is_deleted = 0 ORDER BY name');
    return [for (final row in rows) ScriptDefinition.fromRow(row)];
  }

  /// `id`'s own SQL `DEFAULT` expression needs explicit injection, same
  /// "omitting it from the INSERT silently bypasses it" gotcha as every
  /// other timestamp+random-id table in this app --
  /// `SqliteCrdtHelpers.insertGetId`'s own doc comment only holds for a
  /// true rowid-alias table with *no* competing `DEFAULT`, which this
  /// isn't.
  Future<int> create({required String name, required String code, String? description}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('A script needs a name.');

    final db = await _db;
    final idDefault = await _idDefaultExpression(db);
    late final int id;
    await db.transaction((txn) async {
      final columnList = idDefault == null
          ? 'name, code, description'
          : 'id, name, code, description';
      final valuesSql = idDefault == null ? '?1, ?2, ?3' : '($idDefault), ?1, ?2, ?3';
      await txn.execute(
        'INSERT INTO script_definitions ($columnList) VALUES ($valuesSql)',
        [trimmed, code, description],
      );
      final result = await txn.query('SELECT last_insert_rowid() AS id');
      id = result.first['id'] as int;
    });
    return id;
  }

  Future<void> update(int id, {required String name, required String code, String? description}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('A script needs a name.');

    final db = await _db;
    await db.execute(
      'UPDATE script_definitions SET name = ?1, code = ?2, description = ?3 WHERE id = ?4',
      [trimmed, code, description, id],
    );
  }

  Future<void> softDelete(int id) async {
    final db = await _db;
    await db.execute('UPDATE script_definitions SET is_deleted = 1 WHERE id = ?1', [id]);
  }

  Future<String?> _idDefaultExpression(SqliteCrdt db) async {
    final columns = await db.query('PRAGMA table_info("script_definitions")');
    for (final column in columns) {
      if (column['name'] == 'id') return column['dflt_value'] as String?;
    }
    return null;
  }
}
