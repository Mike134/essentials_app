import 'dart:async';

import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

import '../models/table_config.dart';
import '../util/search_index_content.dart';
import 'database_helper.dart';
import 'schema_registry.dart';
import 'sync_service.dart';
import 'table_discovery_service.dart' show isInfraTable;

/// One matched record from [SearchIndexService.search] -- enough to open
/// the real record directly (`SchemaRegistry.buildConfig(tableName)` +
/// `GenericDao(config).getById(recordId)`) without re-running the table's
/// own `getAll()`/full grid load first, per
/// claude/essentials-v2-phase6-design.md's "Search UI" section.
class SearchResult {
  const SearchResult({
    required this.tableName,
    required this.recordId,
    required this.snippet,
  });

  final String tableName;
  final int recordId;

  /// FTS5's own `snippet()` output -- the matched text in context, with
  /// `**...**` markers around the match (see [SearchIndexService.search]).
  final String snippet;
}

/// Essentials v2 Phase 6 (Global Search) -- one unified FTS5 index across
/// every user table, per claude/essentials-v2-phase6-design.md's confirmed
/// scope (see that file for the two decisions this build holds to: one
/// shared `search_index` table, not per-table; and this first pass indexes
/// plain stored text only -- `text`/`url`/`link_file`/`barcode`, see
/// [isSearchIndexable] -- not resolved `select`/`link_record`/`lookup`
/// display values, a deliberate, deferred follow-up).
///
/// **Lives in its own, completely separate SQLite file** --
/// [DatabaseHelper.resolveSearchIndexDatabasePath], never a table inside
/// `essentials.db` -- see that method's own doc comment for the real
/// incident that made this non-negotiable, not just a design preference:
/// `sql_crdt`'s own `init()`/`getChangeset()` unconditionally scan *every*
/// physical table in whatever file `SqliteCrdt.open()`s, assuming each one
/// has `modified`/`hlc`/`node_id` columns -- an FTS5 virtual table (plus its
/// own shadow tables) inside `essentials.db` broke `SqliteCrdt.open()`
/// outright, for the whole app, on the very next launch. A separate file
/// sidesteps the entire category of problem: `sqlite_crdt` never opens it,
/// never scans it, never knows it exists.
///
/// **Verified before committing to FTS5 at all**
/// (`tool/search_index_spike.dart`, a throwaway scratch db, kept as a
/// record) -- `CREATE VIRTUAL TABLE ... USING fts5(...)` succeeded outright
/// against the FFI-loaded SQLite build this app links against
/// (`sqlite3_flutter_libs`, the same package/version that also supplies
/// Android's bundled binary -- genuinely untested from this environment on
/// real Android hardware, but the same build across both platforms).
/// [ensureIndexTable] swallows a failure here (logged, not thrown) --
/// exactly the design doc's own stated fallback for a platform where FTS5
/// turns out to be missing: [search]/[reindexRecord]/[reindexTable]/
/// [reindexAll] all check [_physicallyExists] first and silently no-op if
/// the table was never successfully created, so a device without FTS5
/// simply has no working search rather than a broken app.
///
/// **Never synced, by construction** -- a genuinely separate file, never
/// opened by `sqlite_crdt`/`crdt_sync`, never touched by Syncthing (not
/// inside the synced `essentials_app` folder's file set), holding nothing
/// that isn't already derivable from other (synced) tables' own data. Every
/// device independently (re)builds its own copy.
class SearchIndexService {
  SearchIndexService({SchemaRegistry? registry}) : _registry = registry ?? SchemaRegistry();

  final SchemaRegistry _registry;

  /// The virtual table's own name inside its dedicated file -- just
  /// `search_index`, since the file itself provides all the isolation this
  /// needs; no reason to also namespace the table name within it.
  static const String tableName = 'search_index';

  // Static, not per-instance -- every `SearchIndexService()` call site
  // should share one real connection to the file, same reasoning as
  // `DatabaseHelper.instance`'s own cached-Future pattern (and for the
  // identical reason: several near-simultaneous callers must never each
  // independently open their own separate connection).
  static Future<ffi.Database>? _dbFuture;

  Future<ffi.Database> get _db => _dbFuture ??= _open();

  Future<ffi.Database> _open() async {
    final path = await DatabaseHelper.instance.resolveSearchIndexDatabasePath();
    return ffi.databaseFactoryFfi.openDatabase(path);
  }

  Future<bool> _physicallyExists() async {
    final db = await _db;
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [tableName],
    );
    return rows.isNotEmpty;
  }

  /// Creates `search_index` in its own file on this device if it doesn't
  /// already exist, and -- **only on that first creation** -- immediately
  /// backfills it with [reindexAll]. Safe and cheap to call on every app
  /// launch: the physical-existence check makes table creation a no-op on
  /// every call after the first that actually lands, and the backfill only
  /// ever runs once per device (a device that already has the table never
  /// re-triggers it).
  ///
  /// **The backfill is not optional -- found live, a real gap, not a
  /// hypothetical one.** Without it, a device's index only ever grows from
  /// writes made *after* this feature first ran (the two reindex hooks in
  /// [GenericDao]/[listenForRemoteChanges]) -- every row that already
  /// existed in the database at that point is silently never indexed unless
  /// something happens to write to it again, or Settings' manual "Rebuild
  /// search index" is used. Confirmed directly against real data: two
  /// lookup tables with real rows (`condition`/`status`) had zero rows in
  /// the index while two entity tables edited after this feature went live
  /// were fully indexed -- searching for a value that only ever existed in
  /// one of the never-touched tables (e.g. a `status` row literally named
  /// "New") silently found nothing, while a search hitting the
  /// already-indexed tables worked fine. Looked like a broken/inconsistent
  /// search; was actually a missing backfill.
  ///
  /// Swallows (logs, doesn't throw) a failure to create the table -- see
  /// this class's own doc comment for why that's the deliberate fallback if
  /// a device's SQLite build ever turns out to lack FTS5, rather than
  /// crashing app startup over a non-essential feature. The backfill itself
  /// is fire-and-forget (not awaited) -- it can genuinely take a moment on
  /// a database with real data, and there's no reason app launch should
  /// wait on it; every table already tolerates being searched before its
  /// own reindex has landed (an empty/partial result, not an error).
  Future<void> ensureIndexTable() async {
    if (await _physicallyExists()) return;
    try {
      final db = await _db;
      await db.execute(
        'CREATE VIRTUAL TABLE IF NOT EXISTS $tableName USING fts5('
        'table_name UNINDEXED, record_id UNINDEXED, content)',
      );
    } catch (e) {
      _log('could not create $tableName -- FTS5 may not be available on this device: $e');
      return;
    }
    unawaited(reindexAll());
  }

  /// Re-derives [table]'s eligible field list via [SchemaRegistry
  /// .buildConfig] -- `null` if the table's schema can't be resolved right
  /// now (drift/not-yet-synced, same [SchemaValidationException] case
  /// every other v2 read path already tolerates rather than crashing on).
  Future<List<FieldConfig>?> _eligibleFields(String table) async {
    try {
      final config = await _registry.buildConfig(table);
      return [for (final field in config.fields) if (isSearchIndexable(field)) field];
    } catch (e) {
      _log('could not resolve "$table"\'s schema (drift or not yet synced?): $e');
      return null;
    }
  }

  /// Re-indexes exactly one record: delete then re-insert, so this is
  /// naturally idempotent (repeated calls for the same table+id never leave
  /// a duplicate row). Wired into [GenericDao.insert]/[GenericDao.update]
  /// so a local write is immediately searchable, and into the remote-change
  /// listener [listenForRemoteChanges] starts (via [reindexTable] there --
  /// no per-row granularity is available from that stream).
  Future<void> reindexRecord(String table, int id) async {
    try {
      if (!await _physicallyExists()) return;
      final fields = await _eligibleFields(table);
      final db = await _db;
      await db.delete(tableName, where: 'table_name = ? AND record_id = ?', whereArgs: [table, id]);
      if (fields == null || fields.isEmpty) return;

      final crdt = await DatabaseHelper.instance.crdt;
      final rows = await crdt.query(
        'SELECT * FROM "$table" WHERE id = ?1 AND is_deleted = 0',
        [id],
      );
      if (rows.isEmpty) return;

      final content = buildSearchContent(fields, rows.first);
      if (content.isEmpty) return;
      await db.insert(tableName, {'table_name': table, 'record_id': id, 'content': content});
    } catch (e) {
      _log('reindexRecord("$table", $id) failed: $e');
    }
  }

  /// Removes one record from the index -- [GenericDao.delete] calls this
  /// for the row being deleted itself (its cascaded children go through
  /// [reindexTable] instead, since the cascade pass deletes them by a bulk
  /// `WHERE` clause without ever materializing their individual ids).
  Future<void> removeFromIndex(String table, int id) async {
    try {
      if (!await _physicallyExists()) return;
      final db = await _db;
      await db.delete(tableName, where: 'table_name = ? AND record_id = ?', whereArgs: [table, id]);
    } catch (e) {
      _log('removeFromIndex("$table", $id) failed: $e');
    }
  }

  /// Delete-all-then-bulk-reinsert for [table] -- used for a cascaded
  /// delete's child tables (ids not individually known), the remote-change
  /// listener (no per-row detail available), and [reindexAll]'s per-table
  /// loop.
  Future<void> reindexTable(String table) async {
    try {
      if (!await _physicallyExists()) return;
      final db = await _db;
      await db.delete(tableName, where: 'table_name = ?', whereArgs: [table]);

      final fields = await _eligibleFields(table);
      if (fields == null || fields.isEmpty) return;

      final crdt = await DatabaseHelper.instance.crdt;
      final rows = await crdt.query('SELECT * FROM "$table" WHERE is_deleted = 0');
      if (rows.isEmpty) return;

      final batch = db.batch();
      for (final row in rows) {
        final content = buildSearchContent(fields, row);
        if (content.isEmpty) continue;
        batch.insert(tableName, {
          'table_name': table,
          'record_id': row['id'] as int,
          'content': content,
        });
      }
      await batch.commit(noResult: true);
    } catch (e) {
      _log('reindexTable("$table") failed: $e');
    }
  }

  /// Full rebuild, every table -- the first-run bootstrap (nothing to
  /// re-derive from an event stream before this ever ran once) and the
  /// manual "Rebuild search index" escape hatch in Settings, for the known,
  /// accepted staleness gap a pure schema change (a field's format
  /// changing, a new field added) leaves behind -- see this class's own
  /// module doc / the design doc's "Known, accepted staleness gap" note.
  Future<void> reindexAll() async {
    final tables = await _registry.discoverTableNames();
    for (final table in tables) {
      await reindexTable(table);
    }
  }

  /// Removes every `search_index` row whose `table_name` no longer refers
  /// to a live table -- a table permanently dropped via [SchemaEditorService
  /// .dropTable] leaves its old rows behind forever otherwise, since
  /// [reindexAll]/the two reindex hooks only ever touch tables that still
  /// exist, never notice one that's gone. Same "startup pass, scoped to
  /// currently-live tables" shape as [OrphanCleanupService] already
  /// established for the settings tables -- this is that same idea, just
  /// for `search_index`'s own separate file, which `OrphanCleanupService`
  /// itself has no reach into.
  ///
  /// **Stage-1 soft-deleted tables are deliberately left untouched** --
  /// [SchemaRegistry.discoverTableNames] excludes them (matching real nav),
  /// but the physical table -- and its data -- genuinely still exists and
  /// is fully recoverable, so purging its search entries here would mean a
  /// restored table comes back with a stale/empty index until its next
  /// write or a manual "Rebuild search index". Only a table that's
  /// actually gone (stage-2 [SchemaEditorService.dropTable], or one
  /// created directly against `essentials.db` outside the schema engine
  /// and later removed) has its entries reclaimed.
  ///
  /// Returns the table names actually cleaned up (empty if nothing was
  /// orphaned) -- useful for a startup debug log, same as
  /// [OrphanCleanupService.cleanupOrphans]' own return value.
  Future<Set<String>> cleanupOrphans() async {
    try {
      if (!await _physicallyExists()) return const {};
      final db = await _db;
      // Physical existence in essentials.db, not SchemaRegistry
      // .discoverTableNames() (metadata-visibility-based, which also
      // excludes a merely stage-1-soft-deleted table -- exactly the
      // distinction this method's own doc comment above draws, and the
      // same `sqlite_master`-based check `OrphanCleanupService` already
      // uses for the identical reason).
      final crdt = await DatabaseHelper.instance.crdt;
      final physicalTables = (await crdt.query(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((r) => r['name'] as String).toSet();

      final rows = await db.rawQuery('SELECT DISTINCT table_name FROM $tableName');
      final orphaned = <String>{};
      for (final row in rows) {
        final table = row['table_name'] as String;
        if (physicalTables.contains(table)) continue;
        orphaned.add(table);
        await db.delete(tableName, where: 'table_name = ?', whereArgs: [table]);
      }
      return orphaned;
    } catch (e) {
      _log('cleanupOrphans failed: $e');
      return const {};
    }
  }

  /// FTS5 full-text search across every indexed table, most-relevant first
  /// (`ORDER BY rank`, FTS5's own built-in relevance -- no custom scoring
  /// per the design doc's explicit "out of scope" list). An empty/
  /// whitespace-only [query] returns nothing rather than everything (the
  /// unrestricted "match anything" behavior a literal empty FTS5 MATCH
  /// string would otherwise produce).
  Future<List<SearchResult>> search(String query, {int limit = 50}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    try {
      if (!await _physicallyExists()) return const [];
      final db = await _db;
      final rows = await db.rawQuery(
        'SELECT table_name, record_id, '
        "snippet($tableName, 2, '**', '**', '…', 10) AS snippet "
        'FROM $tableName WHERE $tableName MATCH ? ORDER BY rank LIMIT ?',
        [_buildFtsQuery(trimmed), limit],
      );
      return [
        for (final row in rows)
          SearchResult(
            tableName: row['table_name'] as String,
            recordId: row['record_id'] as int,
            snippet: row['snippet'] as String,
          ),
      ];
    } catch (e) {
      _log('search("$query") failed: $e');
      return const [];
    }
  }

  /// Quotes every whitespace-separated term as its own FTS5 phrase, joined
  /// with an explicit `AND` -- this indexes real, free-form personal data
  /// (emails, phone numbers, anything with `-`/`*`/`:`/etc.), and FTS5's
  /// own query syntax treats several of those characters as operators
  /// (e.g. a bare leading `-` is NOT) when left unquoted. Quoting each term
  /// makes every character inside it literal.
  String _buildFtsQuery(String raw) {
    final terms = raw.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    return terms.map((t) => '"${t.replaceAll('"', '""')}"').join(' AND ');
  }

  // ===================== remote-change reindex hook =====================

  static StreamSubscription<Set<String>>? _remoteChangesSubscription;
  static Timer? _remoteChangesDebounce;
  static final Set<String> _pendingRemoteTables = {};

  /// Subscribes (once, process-wide) to [SyncService.dataChanges] so a
  /// record synced in from another device becomes searchable here without
  /// needing a local write of its own -- the second of the two reindex
  /// hooks the design doc calls for (the first, local writes, is wired
  /// directly into [GenericDao.insert]/[update]/[delete]). Debounced the
  /// same short beat every other [SyncService.dataChanges]/
  /// [SyncService.schemaChanges] listener in this app already uses --
  /// `onChangesetReceived` fires before the merge is actually awaited, so
  /// reindexing instantly risks reading pre-merge data. Call once, e.g.
  /// from `HomeShell`'s bootstrap alongside this app's other one-time
  /// app-wide setup; safe to call more than once (subsequent calls are
  /// no-ops).
  static void listenForRemoteChanges() {
    _remoteChangesSubscription ??= SyncService.dataChanges.listen((tables) {
      _pendingRemoteTables.addAll(tables);
      _remoteChangesDebounce?.cancel();
      _remoteChangesDebounce = Timer(const Duration(milliseconds: 500), () async {
        final tables = _pendingRemoteTables.toList();
        _pendingRemoteTables.clear();
        final service = SearchIndexService();
        for (final table in tables) {
          // Skip infra/settings tables (table_column_settings,
          // device_settings, migration_log, etc.) -- these fire on this
          // stream constantly (every column resize/sort/filter/migration)
          // but have no table_definitions row for SchemaRegistry to build a
          // config from, so reindexing them would just log a harmless but
          // noisy failure every time.
          if (isInfraTable(table)) continue;
          await service.reindexTable(table);
        }
      });
    });
  }

  static void _log(String message) {
    // ignore: avoid_print
    print('[SearchIndexService] $message');
  }
}
