// essentials_app's crdt_sync coordinator -- the record-level sync hub for
// MIKE-CU. Not a general-purpose service; lives inside this repo so a
// protocol change here and its matching client-side change travel together
// in the same commit history. See CLAUDE.md "Syncing at the Record Level".
//
// Deliberately NOT using crdt_sync_server's listen() helper directly --
// that function hardcodes InternetAddress.loopbackIPv4, which would make
// this unreachable from any other device on the LAN. upgrade() is the same
// helper listen() calls internally per-connection, exposed so a real bind
// address can be used instead.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crdt_sync/crdt_sync_server.dart' as crdt_sync_server;
import 'package:path/path.dart' as p;
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'migration_service.dart';

const port = 1340;

/// Timestamps every log line -- `server.log` had none before this, making
/// it impossible to tell when a connect/disconnect cycle actually happened
/// without cross-referencing file mtimes. Local time (not UTC), since this
/// is a single-machine hub read by a human, not a distributed system log.
void _log(String message) {
  print('${DateTime.now().toIso8601String()} $message');
}

/// How often to re-check `migration_log` for entries `schema_admin` wrote
/// directly into `hub.db` while this process was already running -- there's
/// no push notification for that (schema_admin isn't a crdt_sync client,
/// it opens the file directly, see CLAUDE.md), so periodic re-checking is
/// the only way to notice. Same interval as essentials_app's own periodic
/// reconnect, no particular reason it needs to match beyond consistency.
const Duration migrationCheckInterval = Duration(minutes: 5);
const dbDir = r'C:\Databases\essentials_app\server';
const dbPath = r'C:\Databases\essentials_app\server\hub.db';

/// Canonical store for `image`-field bytes -- see
/// claude/essentials-v2-file-transfer-endpoint-design.md. Deliberately
/// under the hub's own directory (next to hub.db), not
/// `C:\Databases\essentials_app\files\` -- that's MIKE-CU's own *client*
/// app instance's separate local cache, next to its `essentials.db`. Two
/// different files-roots on the same machine, same "two files with
/// overlapping content, kept correct by the sync layer, not a shared
/// handle" trade-off already accepted for the database itself.
const filesDir = r'C:\Databases\essentials_app\server\files';

/// See the client's own copy of this exact function
/// (`essentials_app/lib/db/sync_service.dart`'s `safeChangesetBuilder`) for
/// the full explanation -- duplicated here rather than shared because this
/// server is a separate Dart package/project. Short version: `sql_crdt`'s
/// sync watermark is a single maximum across every table, not per table, so
/// a fast-moving table (this app's per-device grid settings) can race past
/// a slower one's still-pending change and permanently strand it. This
/// drops the watermark (`modifiedAfter`) entirely for the one-time
/// catch-up pull on every (re)connect and sends the complete dataset
/// instead -- safe, since `sql_crdt`'s merge is an idempotent hlc-compared
/// upsert, and cheap enough for this app's size on a local network.
FutureOr<CrdtChangeset> safeChangesetBuilder(
  Crdt crdt, {
  Iterable<String>? onlyTables,
  String? onlyNodeId,
  String? exceptNodeId,
  Hlc? modifiedOn,
  Hlc? modifiedAfter,
}) {
  return crdt.getChangeset(
    onlyTables: onlyTables,
    onlyNodeId: onlyNodeId,
    exceptNodeId: exceptNodeId,
    modifiedOn: modifiedOn,
  );
}

// Essentials v2 Phase 1 -- infra/bookkeeping tables ONLY. The 19 former
// business tables (domain, subscription, journal, orders, order_items,
// etc.) are deliberately gone from this list -- per the clean-slate
// directive (claude/essentials-v2-phase1-design.md), business tables no
// longer exist until Mike creates them through the app's own New Table UI,
// and they reach this hub the same way they reach any device: replaying
// `migration_log`, not hardcoded DDL here.
//
// MUST be kept byte-for-byte identical to `infraSchemaStatements` in
// tool/bootstrap_fresh_db.dart -- same cross-package duplication
// convention already used for `safeChangesetBuilder` and
// `splitSqlStatements` (server/ is a separate Dart package from
// essentials_app, so the two can't share a file). If one changes, the
// other must change with it in the same commit.
const schemaStatements = <String>[
  // sqflite_common_ffi's own internal table. Not part of this app's design,
  // but Android's sqflite creates it locally and the sync layer doesn't
  // distinguish business tables from anything else -- without a structural
  // counterpart on every peer, merging its changeset fails (found live against
  // the real server, see server.dart's own comment). `locale` is a real
  // PRIMARY KEY, not bare -- per migrations/006.
  '''
    CREATE TABLE "android_metadata" (
      "locale" TEXT PRIMARY KEY
    )
  ''',

  // ---------- Dynamic schema metadata (NEW in v2 Phase 1) ----------
  // The heart of the dynamic schema engine. One row per user-visible table.
  // `table_name` is the physical SQLite identifier and is IMMUTABLE once
  // created; only `display_name` ever changes. That single rule is what makes
  // rename/delete/reorder pure metadata operations with zero DDL.
  '''
    CREATE TABLE "table_definitions" (
      "table_name"     TEXT PRIMARY KEY,
      "display_name"   TEXT NOT NULL,
      "description"    TEXT,
      "icon"           TEXT,
      "display_field"  TEXT,
      "order_by"       TEXT,
      "position"       INTEGER,
      "created_at"     TEXT NOT NULL,
      "calendar_field" TEXT
    )
  ''',
  // One row per field. Supersedes v1's `field_metadata` entirely -- that table
  // held only the policy half (label, default, lookup display column) and
  // derived the structural half from PRAGMA introspection. This holds both, so
  // `field_metadata` is NOT created here.
  //
  // `format` is a presentation/input hint, never a storage constraint --
  // every user field's physical column is TEXT. `options` is JSON (format
  // mask, currency symbol, select source table + display field, on_delete,
  // etc.).
  '''
    CREATE TABLE "field_definitions" (
      "table_name"    TEXT NOT NULL,
      "field_name"    TEXT NOT NULL,
      "display_name"  TEXT NOT NULL,
      "format"        TEXT NOT NULL,
      "options"       TEXT,
      "default_value" TEXT,
      "required"      INTEGER NOT NULL DEFAULT 0,
      "position"      INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY ("table_name", "field_name")
    )
  ''',

  // ---------- Per-device table view state ----------
  '''
    CREATE TABLE "table_column_settings" (
      "table_name"    TEXT NOT NULL,
      "device_id"     TEXT NOT NULL,
      "column_name"   TEXT NOT NULL,
      "width"         REAL,
      "display_order" INTEGER,
      "visible"       INTEGER NOT NULL DEFAULT 1,
      "frozen"        TEXT,
      "wrap_text"     INTEGER NOT NULL DEFAULT 0,
      "aggregate"     TEXT,
      PRIMARY KEY ("table_name", "device_id", "column_name")
    )
  ''',
  '''
    CREATE TABLE "table_view_settings" (
      "table_name"       TEXT NOT NULL,
      "device_id"        TEXT NOT NULL,
      "sort_column"      TEXT,
      "sort_direction"   TEXT,
      "filter_json"      TEXT,
      "group_column"     TEXT,
      "row_color_column" TEXT,
      PRIMARY KEY ("table_name", "device_id")
    )
  ''',

  // ---------- App/device settings, groups ----------
  // `setting_key`, never a bare `key` -- migrations/007 renamed it precisely
  // because of the sqlparser bug this file's header describes. Quoting would
  // also fix it now, but the rename stands so no future fresh CREATE TABLE
  // depends on remembering to quote.
  '''
    CREATE TABLE "app_settings" (
      "setting_key" TEXT PRIMARY KEY,
      "value"       TEXT
    )
  ''',
  '''
    CREATE TABLE "device_settings" (
      "device_id"   TEXT NOT NULL,
      "setting_key" TEXT NOT NULL,
      "value"       TEXT,
      PRIMARY KEY ("device_id", "setting_key")
    )
  ''',
  '''
    CREATE TABLE "table_group" (
      "table_name"     TEXT PRIMARY KEY,
      "group_name"     TEXT NOT NULL,
      "group_position" INTEGER
    )
  ''',

  // ---------- Views (Essentials v2 Phase 3) ----------
  // Saved List/Kanban (per-table, table_name set) / Calendar (aggregate,
  // table_name NULL) views -- shared/synced, same bucket as
  // table_definitions/field_definitions. `view_id` is the timestamp+random
  // scheme, not AUTOINCREMENT, same collision-avoidance reasoning as
  // migration_log.id. MUST stay identical to schema.sql / tool/
  // bootstrap_fresh_db.dart's infraSchemaStatements.
  '''
    CREATE TABLE "view_definitions" (
      "view_id"      INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
      ),
      "table_name"   TEXT,
      "view_type"    TEXT NOT NULL,
      "display_name" TEXT NOT NULL,
      "position"     INTEGER,
      "config"       TEXT,
      "created_at"   TEXT NOT NULL
    )
  ''',

  // ---------- Templates (Essentials v2 Phase 7) ----------
  // User-saved templates only -- built-in templates are a compiled Dart
  // catalog on the client, never rows here. `template_id` is the
  // timestamp+random scheme, same collision-avoidance reasoning as
  // migration_log.id/view_definitions.view_id. MUST stay identical to
  // schema.sql / tool/bootstrap_fresh_db.dart's infraSchemaStatements.
  '''
    CREATE TABLE "template_definitions" (
      "template_id"  INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
      ),
      "display_name" TEXT NOT NULL,
      "description"  TEXT,
      "icon"         TEXT,
      "fields_json"  TEXT NOT NULL,
      "created_at"   TEXT NOT NULL
    )
  ''',

  // ---------- Scripts & Events (Essentials v2 Phase 5) ----------
  // User-authored JavaScript automation -- shared/synced. See
  // claude/essentials-v2-phase5-design.md, "Data model". `id` is the
  // timestamp+random scheme on both tables, same collision-avoidance
  // reasoning as migration_log.id/view_definitions.view_id/
  // template_definitions.template_id. MUST stay identical to schema.sql /
  // tool/bootstrap_fresh_db.dart's infraSchemaStatements.
  '''
    CREATE TABLE "script_definitions" (
      "id" INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
      ),
      "name"        TEXT NOT NULL,
      "code"        TEXT NOT NULL,
      "description" TEXT
    )
  ''',
  '''
    CREATE TABLE "event_definitions" (
      "id" INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
      ),
      "script_id"       INTEGER NOT NULL,
      "event_type"      TEXT NOT NULL,
      "table_name"      TEXT,
      "field_name"      TEXT,
      "schedule_config" TEXT,
      "enabled"         INTEGER NOT NULL DEFAULT 1
    )
  ''',

  // ---------- Schema migration system ----------
  // `id` is the timestamp+random scheme, NOT AUTOINCREMENT -- changed for v2.
  // v1's AUTOINCREMENT was safe only because migrations were authored from
  // exactly one place (schema_admin on MIKE-CU). Phase 1 breaks that: any
  // device can create a table, so any device authors migration_log rows.
  // AUTOINCREMENT is max(existing)+1, so two devices both synced through
  // migration N will BOTH deterministically pick N+1 -- and since `id` is the
  // primary key, CRDT merges the two rows into one and silently loses a
  // migration. Not a microsecond race; the window is the whole sync interval.
  '''
    CREATE TABLE "migration_log" (
      "id" INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
      ),
      "sql_text"    TEXT NOT NULL,
      "description" TEXT,
      "created_at"  TEXT NOT NULL
    )
  ''',
  '''
    CREATE TABLE "migration_status" (
      "migration_id"  INTEGER NOT NULL REFERENCES "migration_log"("id"),
      "device_id"     TEXT NOT NULL,
      "outcome"       TEXT NOT NULL,
      "error_message" TEXT,
      "attempted_at"  TEXT,
      PRIMARY KEY ("migration_id", "device_id")
    )
  ''',
];

Future<void> createSchema(CrdtTableExecutor db, int version) async {
  for (final statement in schemaStatements) {
    await db.execute(statement);
  }
}

Future<void> main() async {
  Directory(dbDir).createSync(recursive: true);
  Directory(filesDir).createSync(recursive: true);

  final crdt = await SqliteCrdt.open(dbPath, version: 1, onCreate: createSchema);
  await crdt.execute('PRAGMA foreign_keys = ON');
  _log('Hub replica open: $dbPath');
  _log('Hub node id: ${crdt.nodeId}');

  // Applied before HttpServer.bind -- no client connection is accepted,
  // and so no other queued data sync is processed, until this device's own
  // pending migrations are settled. See migration_service.dart and
  // CLAUDE.md "schema_admin -- migration authoring tool".
  final migrations = MigrationService(crdt);
  await migrations.applyPending();

  // Guards every applyPending() call below (the periodic timer and the
  // live debounced trigger) so at most one ever runs at a time -- doesn't
  // eliminate the risk of racing crdt_sync's own internal merge
  // transaction (that one's real fix is MigrationService._attempt's own
  // transient-lock retry, see its doc comment), but there's no reason to
  // also let *this* code's own two separate triggers race each other on
  // top of that.
  var applyingMigrations = false;
  Future<void> runApplyPending() async {
    if (applyingMigrations) return;
    applyingMigrations = true;
    try {
      await migrations.applyPending();
    } catch (e) {
      _log('[migration check error] $e');
    } finally {
      applyingMigrations = false;
    }
  }

  Timer.periodic(migrationCheckInterval, (_) => runApplyPending());

  // Debounced re-application, triggered live by onChangesetReceived below
  // -- not called immediately from there: crdt_sync calls that callback
  // *before* awaiting the actual merge (confirmed by reading crdt_sync's
  // own source, same finding already documented on the client's identical
  // fix), so an incoming migration_log row isn't necessarily in hub.db yet
  // at the moment the callback fires. A short delay is cheap insurance,
  // not a precise wait, and coalesces a batch of near-simultaneous
  // changesets into one applyPending() call instead of several.
  Timer? migrationApplyDebounce;
  void scheduleMigrationApply() {
    migrationApplyDebounce?.cancel();
    migrationApplyDebounce = Timer(const Duration(milliseconds: 500), runApplyPending);
  }

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  _log('Listening on 0.0.0.0:$port (reachable at 10.0.0.134:$port)');
  _log('Press Ctrl+C to stop.');

  await for (final request in server) {
    try {
      // Plain HTTP, not the crdt_sync websocket protocol -- a real bug
      // caught in Part D verification, not theorized: crdt_sync's catch-up
      // pull merges every table in one all-or-nothing transaction (same
      // "one missing column poisoned the entire batch" failure mode as the
      // aggregate/group_column/row_color_column incident). Once any peer
      // has applied a migration, its outgoing row data for the migrated
      // table carries the new column -- a device that hasn't applied that
      // migration locally yet yet can't merge it ("no such column"), which
      // (confirmed live against MIKE-12R, not assumed) also rolls back
      // migration_log in the very same batch, so the device can never even
      // learn about the migration that would fix it. Infinite loop,
      // self-inflicted, every reconnect. Fix: fetch pending migrations over
      // a side-channel that doesn't depend on the schema already matching,
      // and apply them *before* the risky crdt_sync merge ever runs -- see
      // essentials_app's MigrationService.fetchFromServer.
      if (request.uri.path == '/migrations' && request.method == 'GET') {
        await _handleMigrationsGet(crdt, request);
        continue;
      }

      // `image`-field bytes -- a second instance of the same "plain HTTP
      // side-channel, not crdt_sync" pattern /migrations already
      // established, for the same class of reason: crdt_sync's changeset
      // mechanism is built for row-level SQL merges, not multi-megabyte
      // binaries. See claude/essentials-v2-file-transfer-endpoint-design.md.
      if (request.uri.pathSegments.isNotEmpty && request.uri.pathSegments.first == 'files') {
        await _handleFilesRequest(request);
        continue;
      }

      await crdt_sync_server.upgrade(
        crdt,
        request,
        changesetBuilder: ({onlyTables, onlyNodeId, exceptNodeId, modifiedOn, modifiedAfter}) =>
            safeChangesetBuilder(
              crdt,
              onlyTables: onlyTables,
              onlyNodeId: onlyNodeId,
              exceptNodeId: exceptNodeId,
              modifiedOn: modifiedOn,
            ),
        onConnect: (crdtSync, data) =>
            _log('[connect] peer ${crdtSync.peerId}'),
        onDisconnect: (peerId, code, reason) =>
            _log('[disconnect] peer $peerId (code=$code reason=$reason)'),
        // Real gap found live (CLAUDE.md "Real-device final verification
        // pass"): this used to be a plain print -- applying pending
        // migrations here relied entirely on the 5-minute periodic timer
        // above, written back when only schema_admin ever authored
        // migrations (rare, deliberate). Essentials v2's live schema
        // engine means any device can author one at any moment; a
        // still-connected client kept re-offering the same batch every
        // reconnect while the server's own applyPending never ran in
        // between, so a table dropped on one device took up to 5 minutes
        // (a full periodic-timer cycle) to actually disappear from
        // hub.db, not the "quick" propagation record-level sync otherwise
        // has. Mirrors the identical fix already made client-side
        // (`SyncService.onChangesetReceived` -> `HomeShell`'s debounced
        // `MigrationService().applyPending()`) -- same trigger condition,
        // same debounced-not-immediate handling via scheduleMigrationApply
        // above.
        onChangesetReceived: (nodeId, counts) {
          _log('[recv] from $nodeId: $counts');
          if (counts.containsKey('table_definitions') ||
              counts.containsKey('field_definitions') ||
              counts.containsKey('migration_log')) {
            scheduleMigrationApply();
          }
        },
        onChangesetSent: (nodeId, counts) =>
            _log('[send] to $nodeId: $counts'),
      );
    } catch (e) {
      _log('[upgrade error] $e');
    }
  }
}

/// Extension -> MIME type for `image`-field bytes -- this field is images
/// only (see the UI design doc's platform-specific pick/capture/drop
/// entry points), so a small fixed map is enough; not a general-purpose
/// MIME registry. Falls back to `application/octet-stream` for anything
/// unrecognized rather than guessing wrong.
const _imageContentTypes = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'heic': 'image/heic',
  'webp': 'image/webp',
  'gif': 'image/gif',
};

ContentType _contentTypeFor(String filename) {
  final ext = p.extension(filename).replaceFirst('.', '').toLowerCase();
  final mime = _imageContentTypes[ext];
  return mime == null ? ContentType.binary : ContentType.parse(mime);
}

/// Validates one `/files/...` path segment before it's ever joined into a
/// real filesystem path -- see the design doc's "Path-traversal
/// validation" section. Rejects anything that's empty, a bare `.`/`..`,
/// or smuggles a second path separator (`request.uri.pathSegments`
/// already splits on `/` and percent-decodes, so this is the remaining
/// check, not the whole job -- the four validated segments are then
/// joined under a fixed, hardcoded root, never handed to the filesystem
/// as one unvalidated combined string).
bool _isValidKeySegment(String segment) {
  if (segment.isEmpty || segment == '.' || segment == '..') return false;
  if (segment.contains('/') || segment.contains(r'\')) return false;
  return true;
}

/// Routes every `/files/{table}/{record_id}/{field_name}/{filename}`
/// request -- see claude/essentials-v2-file-transfer-endpoint-design.md.
/// `PUT` uploads, `GET` downloads, `HEAD` checks existence without a body,
/// `DELETE` removes it -- added once the image field's "delete behavior"
/// open item was actually resolved (see the image field design doc's
/// "What happens on capture/drop" section and `FileSyncService.delete`'s
/// own doc comment), not part of the original endpoint design.
Future<void> _handleFilesRequest(HttpRequest request) async {
  // ['files', table, record_id, field_name, filename] -- exactly 5.
  final segments = request.uri.pathSegments;
  if (segments.length != 5 || segments.skip(1).any((s) => !_isValidKeySegment(s))) {
    request.response.statusCode = HttpStatus.badRequest;
    await request.response.close();
    return;
  }

  final relativeParts = segments.skip(1).toList();
  final filePath = p.joinAll([filesDir, ...relativeParts]);

  switch (request.method) {
    case 'PUT':
      await _handleFilesPut(request, filePath);
    case 'GET':
      await _handleFilesGet(request, filePath, filename: relativeParts.last);
    case 'HEAD':
      await _handleFilesHead(request, filePath);
    case 'DELETE':
      await _handleFilesDelete(request, filePath);
    default:
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
  }
}

/// Writes to `$filePath.upload-tmp` then renames into place -- `rename`
/// on the same volume is atomic, so a `GET`/`HEAD` arriving mid-upload
/// never observes a partial file under the real name. Same class of
/// concern this project has already been burned by once (the empty-stub
/// `essentials.db` incidents were exactly "a reader observed a file
/// mid-write") -- see the design doc's "upload" section.
Future<void> _handleFilesPut(HttpRequest request, String filePath) async {
  try {
    await Directory(p.dirname(filePath)).create(recursive: true);
    final tempPath = '$filePath.upload-tmp';
    final sink = File(tempPath).openWrite();
    await sink.addStream(request);
    await sink.close();
    await File(tempPath).rename(filePath);
    request.response.statusCode = HttpStatus.ok;
  } catch (e) {
    _log('[files PUT error] $filePath: $e');
    request.response.statusCode = HttpStatus.internalServerError;
  }
  await request.response.close();
}

Future<void> _handleFilesGet(HttpRequest request, String filePath, {required String filename}) async {
  final file = File(filePath);
  if (!await file.exists()) {
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
    return;
  }
  request.response
    ..statusCode = HttpStatus.ok
    ..headers.contentType = _contentTypeFor(filename)
    ..headers.contentLength = await file.length();
  await request.response.addStream(file.openRead());
  await request.response.close();
}

Future<void> _handleFilesHead(HttpRequest request, String filePath) async {
  final exists = await File(filePath).exists();
  request.response.statusCode = exists ? HttpStatus.ok : HttpStatus.notFound;
  await request.response.close();
}

/// Idempotent, like every DELETE should be -- always `200`, whether or
/// not the file was actually there. "Delete this" succeeded either way:
/// the end state (no file at this key) is what the caller asked for and
/// now has, regardless of the starting state. Never removes the parent
/// directories -- harmless empty leftovers, not worth the extra
/// bookkeeping to clean up.
Future<void> _handleFilesDelete(HttpRequest request, String filePath) async {
  try {
    final file = File(filePath);
    if (await file.exists()) await file.delete();
  } catch (e) {
    _log('[files DELETE error] $filePath: $e');
  }
  request.response.statusCode = HttpStatus.ok;
  await request.response.close();
}

/// Every live `migration_log` row's business columns, as JSON -- not
/// `hlc`/`node_id`/`modified` (the receiving client re-inserts these
/// through its own `sqlite_crdt` connection the normal way every other
/// write in this app does, e.g. `GenericDao.insert`, so they get a
/// freshly-generated, correctly-scoped value under that device's own
/// identity rather than an inconsistent hand-copied one). See the doc
/// comment above this endpoint's routing for why it exists as a plain
/// HTTP fetch instead of going through crdt_sync.
Future<void> _handleMigrationsGet(SqliteCrdt crdt, HttpRequest request) async {
  final rows = await crdt.query(
    'SELECT id, sql_text, description, created_at '
    'FROM migration_log WHERE is_deleted = 0 ORDER BY id ASC',
  );
  request.response
    ..statusCode = HttpStatus.ok
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(rows));
  await request.response.close();
}
