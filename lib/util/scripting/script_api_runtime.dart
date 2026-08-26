import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_js/flutter_js.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../sql_identifiers.dart';
import 'js_engine.dart';

/// Which record (if any) a script run is bound to -- see
/// claude/essentials-v2-phase5-design.md's Script API section: `record`
/// is only in scope for events bound to a specific row (data events,
/// field-changed, a button on a record's own form); scheduled/app-launch
/// events have no ambient record, so both fields are `null` and the JS
/// global `record` is `null` too.
class ScriptRunContext {
  const ScriptRunContext({this.recordTable, this.recordId});

  final String? recordTable;
  final int? recordId;
}

/// Where a `navigate.*` call wants to go -- captured during script
/// execution, never acted on by this class itself. Per the design doc,
/// "navigate.* only makes sense when a UI is actually present" -- turning
/// this into a real `Navigator.push` (when there is one) is the caller's
/// job (build order step 4), not this layer's.
class NavigateRequest {
  const NavigateRequest.toTable(this.tableName) : recordId = null;
  const NavigateRequest.toRecord(this.tableName, this.recordId);

  final String tableName;
  final int? recordId;

  @override
  String toString() => recordId == null ? 'toTable($tableName)' : 'toRecord($tableName, $recordId)';
}

/// Everything a script asked the app to do, beyond writing to the
/// database -- collected during execution, reported once the script
/// finishes (see [ScriptApiRuntime]'s own doc comment for why these are
/// captured rather than dispatched live).
class ScriptEffects {
  const ScriptEffects({this.notifications = const [], this.navigations = const []});

  final List<String> notifications;
  final List<NavigateRequest> navigations;
}

/// [JsExecutionOutcome] plus whatever [ScriptEffects] the script queued
/// along the way -- `effects` is populated even when [outcome] failed or
/// timed out partway through (whatever ran before the failure still
/// happened).
class ScriptRunResult {
  const ScriptRunResult({required this.outcome, this.effects = const ScriptEffects()});

  final JsExecutionOutcome outcome;
  final ScriptEffects effects;
}

/// Essentials v2 Phase 5 build order step 3 -- the real `record`/`table`/
/// `notify`/`navigate` script API (see claude/essentials-v2-phase5-design
/// .md), built against [JsEngine]'s isolate-per-run safety model rather
/// than [JsEngine] itself: [JsEngine.run] takes a bare code string with no
/// hook to install bridge functions or a database connection first, so
/// this class owns its own isolate-spawn/timeout-race pair (a small,
/// deliberate duplication of [JsEngine]'s ~15-line pattern -- same
/// "duplicate a small proven pattern rather than force a shared
/// abstraction onto two genuinely different jobs" call this project
/// already makes for `MigrationService`/`schemaStatements`).
///
/// **A real architectural tension, resolved deliberately, not glossed
/// over: QuickJS's `evaluate()` is synchronous, but `sqlite_crdt`'s real
/// write API is async -- and this project's own hard-won rule (see
/// CLAUDE.md, "no record-level edits in Letos/DBeaver, full stop") is
/// that a write bypassing `sqlite_crdt`'s own API silently never syncs.**
/// There is no way in Dart to synchronously block one isolate's event
/// loop on a Future without deadlocking it, so a script's write calls
/// can't get a real synchronous round-trip through the correct async
/// API. Resolved with a two-phase model, not a workaround that cuts a
/// correctness corner:
/// - **Reads are genuinely synchronous**, via a second, read-only
///   connection opened with `package:sqlite3` directly -- the real,
///   non-async native call `sqflite_common_ffi` itself sits on top of.
///   Safe for reads specifically because a `SELECT` needs no CRDT
///   bookkeeping at all; `table('X').find()/.all()` return live data,
///   mid-script, exactly as the design doc's API sketch implies.
/// - **Writes are deferred, not synchronous.** `record.save()`/`.delete()`
///   and `table('X').create()` queue an in-memory action during the
///   script (no I/O, so no synchronicity problem) instead of writing
///   immediately. Once `evaluate()` returns -- back in ordinary,
///   awaitable Dart code, not inside a synchronous native call frame --
///   every queued write runs for real through a freshly-opened
///   `SqliteCrdt` connection's own `execute()`, getting correct
///   `hlc`/`node_id`/`modified` stamping automatically, the same way
///   `GenericDao` already does it (including the identical
///   rowid-alias-bypasses-DEFAULT fix for a new row's `id` -- see
///   `_applyCreate`'s own comment). **Known, accepted limitation:** a
///   script cannot see its own `table('X').create(...)`/`record.save()`
///   effects in a *later* read within the *same* run (the read
///   connection doesn't see a write that hasn't happened yet) -- a
///   reasonable v1 scope limit, not something silently broken.
/// - **`notify`/`navigate` need no database access at all** -- captured
///   into an in-memory list during the script, reported back as
///   [ScriptEffects] once the run finishes. Real dispatch (an actual
///   SnackBar/Navigator push when a UI exists) is build order step 4's
///   job, not this layer's -- matches the design doc's own "navigate.*
///   ... a no-op ... when the app is backgrounded" framing: this layer
///   doesn't know or care whether a UI exists, it just reports what the
///   script asked for.
///
/// **Deliberately out of scope for step 3, flagged rather than silently
/// skipped:** deferred writes don't reindex `search_index` (unlike
/// `GenericDao.insert()`/`.update()`) -- `SearchIndexService` assumes the
/// normal app's own `DatabaseHelper`/`SchemaRegistry` bootstrap, which
/// this isolate deliberately doesn't replicate. A record a script creates
/// or edits won't be findable via Search until something else touches it
/// (e.g. opening its form) reindexes it. Worth closing once this API has
/// a real caller (step 4) and the gap's actual impact is clearer.
class ScriptApiRuntime {
  ScriptApiRuntime({this.timeout = const Duration(seconds: 5)});

  final Duration timeout;

  /// Runs [code] against the real `essentials.db` at [databasePath].
  /// [context] binds the ambient `record` (or leaves it `null` for a
  /// scheduled/app-launch event, per the design doc). Both [databasePath]
  /// and [context] must be resolved by the caller beforehand -- this
  /// class never touches `DatabaseHelper`/platform channels itself, so it
  /// works identically whether called from the main app isolate or (in
  /// later build order steps) a headless background one.
  Future<ScriptRunResult> run(
    String code, {
    required String databasePath,
    ScriptRunContext context = const ScriptRunContext(),
  }) async {
    final port = ReceivePort();
    Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _runInIsolate,
        _ScriptIsolateRequest(code, databasePath, context, port.sendPort),
      );
    } catch (e) {
      port.close();
      return ScriptRunResult(outcome: JsExecutionOutcome.failure('Failed to start script isolate: $e'));
    }

    try {
      final message = await port.first.timeout(timeout);
      final reply = message as _ScriptIsolateReply;
      final outcome = reply.timedOut
          ? JsExecutionOutcome.timeout()
          : reply.error != null
          ? JsExecutionOutcome.failure(reply.error!)
          : JsExecutionOutcome.ok(reply.value);
      return ScriptRunResult(outcome: outcome, effects: reply.effects);
    } on TimeoutException {
      return ScriptRunResult(outcome: JsExecutionOutcome.timeout());
    } finally {
      port.close();
      // Best-effort only -- see JsEngine's own doc comment for why this
      // can't be relied on to reclaim a genuinely hung script's isolate.
      isolate.kill(priority: Isolate.immediate);
    }
  }
}

class _ScriptIsolateRequest {
  const _ScriptIsolateRequest(this.code, this.databasePath, this.context, this.replyTo);
  final String code;
  final String databasePath;
  final ScriptRunContext context;
  final SendPort replyTo;
}

class _ScriptIsolateReply {
  const _ScriptIsolateReply({this.value, this.error, this.timedOut = false, this.effects = const ScriptEffects()});
  final String? value;
  final String? error;
  final bool timedOut;
  final ScriptEffects effects;
}

abstract class _PendingWrite {}

class _SaveRecord implements _PendingWrite {
  _SaveRecord(this.table, this.id, this.fields);
  final String table;
  final int id;
  final Map<String, Object?> fields;
}

class _DeleteRecord implements _PendingWrite {
  _DeleteRecord(this.table, this.id);
  final String table;
  final int id;
}

class _CreateRow implements _PendingWrite {
  _CreateRow(this.table, this.fields);
  final String table;
  final Map<String, Object?> fields;
}

/// Runs entirely on the spawned isolate -- see [ScriptApiRuntime]'s own
/// doc comment for the two-phase (synchronous read / deferred write)
/// design this implements.
void _runInIsolate(_ScriptIsolateRequest request) async {
  sqlite3.Database? readDb;
  QuickJsRuntime2? runtime;
  final notifications = <String>[];
  final navigations = <NavigateRequest>[];
  final pendingWrites = <_PendingWrite>[];
  final recordFields = <String, Object?>{};
  final recordTable = request.context.recordTable;
  final recordId = request.context.recordId;

  void reply({String? value, String? error, bool timedOut = false}) {
    request.replyTo.send(
      _ScriptIsolateReply(
        value: value,
        error: error,
        timedOut: timedOut,
        effects: ScriptEffects(notifications: notifications, navigations: navigations),
      ),
    );
  }

  try {
    readDb = sqlite3.sqlite3.open(request.databasePath);

    if (recordTable != null && recordId != null) {
      assertSafeSqlIdentifier(recordTable);
      final rows = readDb.select('SELECT * FROM "$recordTable" WHERE id = ? AND is_deleted = 0', [recordId]);
      if (rows.isNotEmpty) recordFields.addAll(rows.first);
    }

    runtime = QuickJsRuntime2(timeout: 0);
    _installBridge(
      runtime,
      readDb: readDb,
      recordTable: recordTable,
      recordId: recordId,
      recordFields: recordFields,
      notifications: notifications,
      navigations: navigations,
      pendingWrites: pendingWrites,
    );

    final result = runtime.evaluate(request.code);
    if (result.isError) {
      reply(error: result.stringResult);
      return;
    }

    if (pendingWrites.isNotEmpty) {
      final writeError = await _applyPendingWrites(request.databasePath, pendingWrites);
      if (writeError != null) {
        reply(error: 'Script ran, but a deferred write failed: $writeError');
        return;
      }
    }

    reply(value: result.stringResult);
  } catch (e) {
    reply(error: e.toString());
  } finally {
    runtime?.dispose();
    readDb?.close();
  }
}

/// Installs `record`/`table`/`notify`/`navigate` as real global JS values,
/// backed by plain Dart closures wrapped via `QuickJsRuntime2`'s own
/// `_DartFunction`/`JSInvokable` mechanism (the same one
/// `initChannelFunctions()` uses internally for `sendMessage`) -- a
/// genuine synchronous Dart-function-as-JS-global, not the one-way
/// `sendMessage`/`onMessage` event channel (which has no return value at
/// all, confirmed by reading the package's source -- not what `record
/// .get()` etc. need).
void _installBridge(
  QuickJsRuntime2 runtime, {
  required sqlite3.Database readDb,
  required String? recordTable,
  required int? recordId,
  required Map<String, Object?> recordFields,
  required List<String> notifications,
  required List<NavigateRequest> navigations,
  required List<_PendingWrite> pendingWrites,
}) {
  final setGlobal = runtime.localContext['setToGlobalObject'] as JSInvokable;
  void install(String name, Function fn) => setGlobal.invoke([name, fn]);

  install('__bridge_record_get', (String field) => recordFields[field]?.toString());
  install('__bridge_record_set', (String field, Object? value) {
    recordFields[field] = value?.toString();
    return null;
  });
  install('__bridge_record_save', () {
    if (recordTable == null || recordId == null) {
      throw StateError('No record is bound to this script -- record.save() has nothing to save.');
    }
    pendingWrites.add(_SaveRecord(recordTable, recordId, Map.of(recordFields)));
    return null;
  });
  install('__bridge_record_delete', () {
    if (recordTable == null || recordId == null) {
      throw StateError('No record is bound to this script -- record.delete() has nothing to delete.');
    }
    pendingWrites.add(_DeleteRecord(recordTable, recordId));
    return null;
  });

  install('__bridge_table_find', (String table, String criteriaJson) {
    assertSafeSqlIdentifier(table);
    final criteria = (jsonDecode(criteriaJson) as Map).cast<String, Object?>();
    final whereParts = ['is_deleted = 0'];
    final args = <Object?>[];
    for (final entry in criteria.entries) {
      assertSafeSqlIdentifier(entry.key);
      whereParts.add('"${entry.key}" = ?');
      args.add(entry.value?.toString());
    }
    final rows = readDb.select('SELECT * FROM "$table" WHERE ${whereParts.join(' AND ')}', args);
    return jsonEncode(_rowsToJson(table, rows));
  });
  install('__bridge_table_all', (String table) {
    assertSafeSqlIdentifier(table);
    final rows = readDb.select('SELECT * FROM "$table" WHERE is_deleted = 0');
    return jsonEncode(_rowsToJson(table, rows));
  });
  install('__bridge_table_create', (String table, String fieldsJson) {
    assertSafeSqlIdentifier(table);
    final fields = (jsonDecode(fieldsJson) as Map).cast<String, Object?>();
    pendingWrites.add(_CreateRow(table, fields));
    return null;
  });

  install('__bridge_notify', (String message) {
    notifications.add(message);
    return null;
  });
  install('__bridge_navigate_to', (String table) {
    navigations.add(NavigateRequest.toTable(table));
    return null;
  });
  install('__bridge_navigate_to_record', (String table, Object? id) {
    final parsedId = id is int ? id : int.tryParse(id?.toString() ?? '');
    if (parsedId != null) navigations.add(NavigateRequest.toRecord(table, parsedId));
    return null;
  });

  runtime.evaluate('''
    var record = ${recordTable != null && recordId != null ? '{}' : 'null'};
    if (record) {
      record.__table = ${jsonEncode(recordTable)};
      record.get = function(field) { return __bridge_record_get(field); };
      record.set = function(field, value) { return __bridge_record_set(field, value); };
      record.save = function() { return __bridge_record_save(); };
      record.delete = function() { return __bridge_record_delete(); };
    }
    function table(name) {
      return {
        find: function(criteria) { return JSON.parse(__bridge_table_find(name, JSON.stringify(criteria || {}))); },
        all: function() { return JSON.parse(__bridge_table_all(name)); },
        create: function(fields) { return __bridge_table_create(name, JSON.stringify(fields || {})); },
      };
    }
    function notify(message) { return __bridge_notify(String(message)); }
    var navigate = {
      to: function(tableName) { return __bridge_navigate_to(tableName); },
      toRecord: function(rec) {
        var t = (rec && rec.__table) || (record && record.__table);
        var id = (rec && rec.id !== undefined) ? rec.id : (record ? record.get('id') : undefined);
        return __bridge_navigate_to_record(t, id);
      },
    };
  ''');
}

List<Map<String, Object?>> _rowsToJson(String table, List<Map<String, Object?>> rows) {
  return [
    for (final row in rows) {...row, '__table': table},
  ];
}

/// Runs every queued write for real, through a fresh `SqliteCrdt`
/// connection opened *after* the script finished (ordinary awaitable
/// Dart code at this point, not inside a synchronous native call frame)
/// -- correct `hlc`/`node_id`/`modified` stamping comes automatically
/// from `sqlite_crdt`'s own `execute()`, same as every other write in
/// this app. Returns an error message, or `null` on success.
Future<String?> _applyPendingWrites(String databasePath, List<_PendingWrite> writes) async {
  final crdt = await SqliteCrdt.open(databasePath);
  try {
    for (final write in writes) {
      switch (write) {
        case _SaveRecord w:
          final columns = w.fields.keys.where((c) => c != 'id').toList();
          if (columns.isEmpty) break;
          final setClause = List.generate(columns.length, (i) => '"${columns[i]}" = ?${i + 1}').join(', ');
          await crdt.execute(
            'UPDATE "${w.table}" SET $setClause WHERE id = ?${columns.length + 1}',
            [...columns.map((c) => w.fields[c]), w.id],
          );
        case _DeleteRecord w:
          await crdt.execute('UPDATE "${w.table}" SET is_deleted = 1 WHERE id = ?1', [w.id]);
        case _CreateRow w:
          // Same rowid-alias-bypasses-DEFAULT fix as GenericDao.insert()
          // (see that method's own doc comment) -- omitting `id` from the
          // INSERT would silently get a small sequential id instead of
          // this table's real timestamp+random one, defeating the
          // collision-avoidance property that scheme exists for.
          final idDefault = await _idDefaultExpression(crdt, w.table);
          final columns = w.fields.keys.toList();
          final columnNames = [if (idDefault != null) 'id', ...columns];
          final valueExpressions = [
            if (idDefault != null) '($idDefault)',
            ...List.generate(columns.length, (i) => '?${i + 1}'),
          ];
          if (columnNames.isEmpty) {
            await crdt.execute('INSERT INTO "${w.table}" (id) VALUES (NULL)');
          } else {
            await crdt.execute(
              'INSERT INTO "${w.table}" (${columnNames.join(', ')}) VALUES (${valueExpressions.join(', ')})',
              columns.map((c) => w.fields[c]).toList(),
            );
          }
      }
    }
    return null;
  } catch (e) {
    return e.toString();
  } finally {
    await crdt.close();
  }
}

Future<String?> _idDefaultExpression(SqliteCrdt crdt, String table) async {
  assertSafeSqlIdentifier(table);
  final columns = await crdt.query('PRAGMA table_info("$table")');
  for (final column in columns) {
    if (column['name'] == 'id') return column['dflt_value'] as String?;
  }
  return null;
}
