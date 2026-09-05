import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'database_helper.dart';

/// Every real `event_type` an `event_definitions` row can carry -- see
/// claude/essentials-v2-phase5-design.md's "Data model". Kept as a plain
/// list of strings, not a Dart `enum`, since `EventDispatchService`
/// already matches purely by string and there's no behavior difference
/// between values beyond which UI section offers them.
const dataEventTypes = ['record_created', 'record_saved', 'record_updated', 'record_deleted'];
const uiEventTypes = ['form_opened', 'form_closed', 'button_clicked'];
const fieldScopedEventTypes = ['field_changed', 'button_clicked'];

/// `schedule_hourly`/`schedule_daily`/`schedule_weekly` were retired for
/// `schedule_interval` -- see
/// claude/essentials-v2-recurring-schedule-design.md. One generic type
/// (`{"interval": N, "unit": "minutes"|"hours"|"days"|"weeks", "anchor":
/// "an ISO8601 string"}` in `schedule_config`, `anchor` optional)
/// subsumes all three -- no dual-format support needed, since zero real
/// bindings existed at the time of the change.
const scheduledEventTypes = ['schedule_interval', 'app_launch'];

/// One `event_definitions` row.
class EventDefinition {
  EventDefinition({
    required this.id,
    required this.scriptId,
    required this.eventType,
    required this.tableName,
    required this.fieldName,
    required this.scheduleConfig,
    required this.enabled,
  });

  factory EventDefinition.fromRow(Map<String, Object?> row) => EventDefinition(
    id: row['id'] as int,
    scriptId: row['script_id'] as int,
    eventType: row['event_type'] as String,
    tableName: row['table_name'] as String?,
    fieldName: row['field_name'] as String?,
    scheduleConfig: row['schedule_config'] as String?,
    enabled: (row['enabled'] as int) == 1,
  );

  final int id;
  final int scriptId;
  final String eventType;
  final String? tableName;
  final String? fieldName;
  final String? scheduleConfig;
  final bool enabled;
}

/// CRUD for `event_definitions` -- same shape/conventions as
/// [ScriptDefinitionsDao]; the two are siblings, never combined into one
/// DAO since a script and its bindings are edited from genuinely
/// different screens (the script editor vs. per-table/global binding
/// screens).
class EventDefinitionsDao {
  Future<SqliteCrdt> get _db async => DatabaseHelper.instance.crdt;

  /// Every active binding for [tableName] -- data events, form events,
  /// `field_changed`/`button_clicked` alike. Used by `ManageEventsScreen`.
  Future<List<EventDefinition>> loadForTable(String tableName) async {
    final db = await _db;
    final rows = await db.query(
      'SELECT * FROM event_definitions WHERE is_deleted = 0 AND table_name = ?1 ORDER BY id',
      [tableName],
    );
    return [for (final row in rows) EventDefinition.fromRow(row)];
  }

  /// Every active scheduled/app-launch binding -- `table_name IS NULL`,
  /// per the design doc's schema comment. Used by `ScheduledEventsScreen`,
  /// the one *global* (not per-table) event binding screen.
  Future<List<EventDefinition>> loadScheduled() async {
    final db = await _db;
    final rows = await db.query(
      'SELECT * FROM event_definitions WHERE is_deleted = 0 AND table_name IS NULL ORDER BY id',
    );
    return [for (final row in rows) EventDefinition.fromRow(row)];
  }

  Future<int> create({
    required int scriptId,
    required String eventType,
    String? tableName,
    String? fieldName,
    String? scheduleConfig,
    bool enabled = true,
  }) async {
    final db = await _db;
    final idDefault = await _idDefaultExpression(db);
    late final int id;
    await db.transaction((txn) async {
      final columnList = idDefault == null
          ? 'script_id, event_type, table_name, field_name, schedule_config, enabled'
          : 'id, script_id, event_type, table_name, field_name, schedule_config, enabled';
      final valuesSql = idDefault == null
          ? '?1, ?2, ?3, ?4, ?5, ?6'
          : '($idDefault), ?1, ?2, ?3, ?4, ?5, ?6';
      await txn.execute(
        'INSERT INTO event_definitions ($columnList) VALUES ($valuesSql)',
        [scriptId, eventType, tableName, fieldName, scheduleConfig, enabled ? 1 : 0],
      );
      final result = await txn.query('SELECT last_insert_rowid() AS id');
      id = result.first['id'] as int;
    });
    return id;
  }

  Future<void> setEnabled(int id, bool enabled) async {
    final db = await _db;
    await db.execute('UPDATE event_definitions SET enabled = ?1 WHERE id = ?2', [enabled ? 1 : 0, id]);
  }

  Future<void> softDelete(int id) async {
    final db = await _db;
    await db.execute('UPDATE event_definitions SET is_deleted = 1 WHERE id = ?1', [id]);
  }

  Future<String?> _idDefaultExpression(SqliteCrdt db) async {
    final columns = await db.query('PRAGMA table_info("event_definitions")');
    for (final column in columns) {
      if (column['name'] == 'id') return column['dflt_value'] as String?;
    }
    return null;
  }
}
