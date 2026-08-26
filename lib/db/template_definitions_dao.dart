import 'dart:convert';

import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../models/template_field.dart';
import 'database_helper.dart';
import 'sql_helpers.dart';

/// One `template_definitions` row -- a user-saved template ("Save as
/// Template"). See claude/essentials-v2-phase7-design.md, "Data model".
/// Built-in templates ([builtinTemplates]) never appear here -- they're
/// compiled Dart data, unified with these only at the picker UI level.
class SavedTemplate {
  SavedTemplate({
    required this.templateId,
    required this.displayName,
    required this.description,
    required this.icon,
    required this.fields,
    required this.createdAt,
  });

  factory SavedTemplate.fromRow(Map<String, Object?> row) {
    final fieldsJson = row['fields_json'] as String;
    final decoded = jsonDecode(fieldsJson);
    return SavedTemplate(
      templateId: row['template_id'] as int,
      displayName: row['display_name'] as String,
      description: row['description'] as String?,
      icon: row['icon'] as String?,
      fields: TemplateField.parseList(decoded),
      createdAt: row['created_at'] as String,
    );
  }

  final int templateId;
  final String displayName;
  final String? description;
  final String? icon;
  final List<TemplateField> fields;
  final String createdAt;
}

/// CRUD for `template_definitions` -- sibling of `ViewDefinitionsDao`, same
/// shared/synced, no-`migration_log` shape (the physical table itself was
/// bootstrapped once, out-of-band, by `tool/add_template_definitions_table
/// .dart`, same reasoning as `view_definitions`' own bootstrap). Every
/// method here is a plain row-level CRDT write against an already-existing
/// table.
class TemplateDefinitionsDao {
  Future<SqliteCrdt> get _db async => DatabaseHelper.instance.crdt;

  /// Every user-saved template, newest first -- the natural order for a
  /// picker list where a just-saved template should be easy to find.
  Future<List<SavedTemplate>> loadAll() async {
    final db = await _db;
    final rows = await db.query(
      'SELECT * FROM template_definitions WHERE is_deleted = 0 ORDER BY template_id DESC',
    );
    return [for (final row in rows) SavedTemplate.fromRow(row)];
  }

  /// Captures [tableName]'s current field list as a new saved template --
  /// see the design doc's "Saving a table as a template" for what's
  /// captured verbatim ([fields], already resolved to
  /// `{display_name, format, options_json}` by the caller, e.g. from
  /// `SchemaMetadataDao.loadFields`) and why (a `select`/`link_record`
  /// field's target-table name is captured as-is; a bad reference is
  /// handled at instantiation time, not save time -- see
  /// [templateFieldsToPendingCreation]'s own doc comment).
  ///
  /// `template_id` needs the same explicit-`DEFAULT`-injection handling
  /// every other timestamp+random-id table in this app already
  /// establishes -- omitting it from the INSERT would silently bypass the
  /// column's own `DEFAULT` and hand back a small sequential rowid
  /// instead.
  Future<int> createTemplate({
    required String displayName,
    String? description,
    String? icon,
    required List<TemplateField> fields,
  }) async {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) throw ArgumentError('A template needs a name.');

    final db = await _db;
    final idDefault = await _templateIdDefaultExpression(db);
    final createdAt = DateTime.now().toUtc().toIso8601String();
    final fieldsJson = jsonEncode([for (final f in fields) f.toJson()]);

    late final int templateId;
    await db.transaction((txn) async {
      final columnList = idDefault == null
          ? 'display_name, description, icon, fields_json, created_at'
          : 'template_id, display_name, description, icon, fields_json, created_at';
      final valuesSql = idDefault == null
          ? '?1, ?2, ?3, ?4, ?5'
          : '($idDefault), ?1, ?2, ?3, ?4, ?5';
      await txn.execute(
        'INSERT INTO template_definitions ($columnList) VALUES ($valuesSql)',
        [trimmed, description, icon, fieldsJson, createdAt],
      );
      final result = await txn.query('SELECT last_insert_rowid() AS id');
      templateId = result.first['id'] as int;
    });
    return templateId;
  }

  Future<void> softDeleteTemplate(int templateId) async {
    final db = await _db;
    await db.deleteWhere('template_definitions', {'template_id': templateId});
  }

  /// `template_definitions.template_id`'s own SQL `DEFAULT` expression --
  /// same lookup shape as `ViewDefinitionsDao._viewIdDefaultExpression`,
  /// repeated rather than shared for the same reason that one gives: this
  /// DAO isn't a `GenericDao` table.
  Future<String?> _templateIdDefaultExpression(SqliteCrdt db) async {
    final columns = await db.query('PRAGMA table_info("template_definitions")');
    for (final column in columns) {
      if (column['name'] == 'template_id') return column['dflt_value'] as String?;
    }
    return null;
  }
}
