import 'package:flutter/material.dart';

import '../models/table_config.dart';
import '../screens/generic_form_screen.dart';
import '../screens/generic_list_screen.dart';
import '../util/scripting/script_api_runtime.dart';
import 'database_helper.dart';
import 'generic_dao.dart';
import 'schema_registry.dart';

/// Essentials v2 Phase 5 build order step 4 -- the foreground, in-app
/// event wiring: finds every enabled `event_definitions` row matching a
/// real UI/data event, runs each bound script through [ScriptApiRuntime],
/// and (via [dispatchAndApplyEffects]) turns whatever `notify`/`navigate`
/// effects came back into a real `SnackBar`/`Navigator.push` -- the part
/// [ScriptApiRuntime] deliberately left undone (see that class's own doc
/// comment: "this layer doesn't know or care whether a UI exists, it
/// just reports what the script asked for"). Background/scheduled firing
/// (steps 6-8) is a different, later caller of the same [dispatch] --
/// this class never assumes a `BuildContext` exists.
///
/// **A real, deliberate design call, not what the design doc's own "What
/// the code already does today" section assumed:** `SyncService
/// .dataChanges` only ever fires for a changeset *received from a remote
/// peer* (confirmed by reading `SyncService`'s source -- it's fed
/// exclusively from `onChangesetReceived`), never for a write made on
/// this device. Wiring data events to it, as the design doc originally
/// suggested, would mean a script bound to "record created" never fires
/// for the overwhelmingly common case (the user creating a record
/// through this device's own form) and instead fires in a burst for
/// every row a reconnect happens to pull in -- exactly backwards from
/// "notify me when I create a record," and a real risk of a
/// notification flood the first time a device reconnects after being
/// offline. **Data events are dispatched from the real local write call
/// sites instead** (`GenericFormScreen`'s save, `GenericListScreen`'s
/// delete) -- correct for the common case, at the cost of not (yet)
/// firing for a change that arrives purely via sync from another device.
/// Flagged as an explicit, open follow-up -- not silently dropped --
/// worth revisiting once real usage shows whether that's ever wanted.
///
/// **`field_changed` is scoped to the form's save flow only for this
/// step** -- diffing `existing` against the form's new values, one event
/// per changed field. `GenericListScreen`'s own inline grid cell-edit
/// path (`_saveCellEdit`) is a second, separate write call site that
/// could fire `record_updated`/`field_changed` too but doesn't yet --
/// flagged as a known, deliberate scope limit for this step rather than
/// touching every code path in an already-large screen in one pass.
class EventDispatchService {
  EventDispatchService({ScriptApiRuntime? runtime}) : _runtime = runtime ?? ScriptApiRuntime();

  final ScriptApiRuntime _runtime;

  /// Runs every enabled script bound to this exact event, returning each
  /// run's [ScriptRunResult] for the caller to act on. Empty (no scripts
  /// run at all) when nothing is bound -- the common case for every table
  /// today, since no UI to create an `event_definitions` row exists yet
  /// (that's build order step 5) -- so this is cheap to call
  /// unconditionally from every write/lifecycle site.
  ///
  /// [tableName] is `null` for a scheduled/`app_launch` event (per the
  /// design doc's schema, `event_definitions.table_name IS NULL` for
  /// those) -- the `IS` comparisons below (not `=`) are what let a bare
  /// `null` correctly match those rows instead of matching nothing.
  Future<List<ScriptRunResult>> dispatch({
    required String? tableName,
    required String eventType,
    String? fieldName,
    int? recordId,
  }) async {
    final crdt = await DatabaseHelper.instance.crdt;
    final bindings = await crdt.query(
      'SELECT script_id FROM event_definitions '
      'WHERE is_deleted = 0 AND enabled = 1 AND event_type = ?1 '
      'AND table_name IS ?2 AND field_name IS ?3',
      [eventType, tableName, fieldName],
    );
    if (bindings.isEmpty) return const [];

    final databasePath = await DatabaseHelper.instance.resolveDatabasePath();
    final results = <ScriptRunResult>[];
    for (final binding in bindings) {
      final scriptId = binding['script_id'] as int;
      final scriptRows = await crdt.query(
        'SELECT code FROM script_definitions WHERE id = ?1 AND is_deleted = 0',
        [scriptId],
      );
      if (scriptRows.isEmpty) continue;
      final code = scriptRows.first['code'] as String;
      final result = await _runtime.run(
        code,
        databasePath: databasePath,
        context: ScriptRunContext(recordTable: tableName, recordId: recordId),
      );
      results.add(result);
    }
    return results;
  }

  /// [dispatch], then applies every resulting effect for real: a
  /// `notify()` becomes a `SnackBar`, a `navigate.*` becomes a real
  /// `Navigator.push`, and a failed/timed-out script surfaces as its own
  /// `SnackBar` rather than silently vanishing. Every `context` use is
  /// preceded by a `mounted` check -- `dispatch` awaits real async work
  /// (script execution, possibly a full timeout), during which the
  /// calling screen can easily have been popped.
  Future<void> dispatchAndApplyEffects(
    BuildContext context, {
    required String? tableName,
    required String eventType,
    String? fieldName,
    int? recordId,
  }) async {
    final results = await dispatch(
      tableName: tableName,
      eventType: eventType,
      fieldName: fieldName,
      recordId: recordId,
    );
    for (final result in results) {
      if (!context.mounted) return;
      for (final message in result.effects.notifications) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
      for (final navigation in result.effects.navigations) {
        if (!context.mounted) return;
        await _applyNavigation(context, navigation);
      }
      if (!context.mounted) return;
      if (result.outcome.timedOut) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('A script timed out.')));
      } else if (result.outcome.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Script error: ${result.outcome.error}')),
        );
      }
    }
  }

  Future<void> _applyNavigation(BuildContext context, NavigateRequest navigation) async {
    final config = await _tryBuildConfig(SchemaRegistry(), navigation.tableName);
    if (config == null || !context.mounted) return;

    if (navigation.recordId == null) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => GenericListScreen(config: config)));
      return;
    }

    final row = await GenericDao(config).getById(navigation.recordId!);
    if (row == null || !context.mounted) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => GenericFormScreen(config: config, existing: row)));
  }

  Future<TableConfig?> _tryBuildConfig(SchemaRegistry registry, String tableName) async {
    try {
      return await registry.buildConfig(tableName);
    } catch (_) {
      // A script named a table that's since been renamed/removed -- same
      // "degrade, don't crash" posture SchemaRegistry's own callers
      // already take for schema drift.
      return null;
    }
  }
}
