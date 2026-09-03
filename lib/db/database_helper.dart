import 'dart:io';

import 'package:path/path.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

/// Opens the single shared `essentials.db`, platform-conditionally, as a
/// [SqliteCrdt] -- see CLAUDE.md "Syncing at the Record Level".
///
/// Windows: the one real Windows copy in `C:\Databases\essentials_app` (see
/// CLAUDE.md "Project layout" -- this path must never diverge from that, no
/// local copy inside the Flutter project). Android: the Syncthing-synced
/// folder under external storage, gated behind a first-run
/// MANAGE_EXTERNAL_STORAGE check (scoped storage blocks arbitrary paths
/// without it) -- Syncthing sync for this folder is now unshared (see
/// CLAUDE.md), but the same path convention carries forward for the new
/// record-level sync pathway.
///
/// Note: sqlite_crdt always opens through sqflite_common_ffi's FFI factory
/// internally, on every platform including Android -- it has no native
/// -sqflite code path (confirmed by reading its source). Unlike the
/// pre-CRDT version of this file, there is no platform branch on
/// `databaseFactory` here anymore; sqlite_crdt owns that choice.
class DatabaseHelper {
  DatabaseHelper._();

  static final DatabaseHelper instance = DatabaseHelper._();

  static const String _windowsDirectory = r'C:\Databases\essentials_app';
  static const String _androidDirectory =
      '/storage/emulated/0/Databases/essentials_app';
  static const String _fileName = 'essentials.db';

  // Caches the in-flight Future itself, not just the resolved value --
  // deliberately NOT `Future<SqliteCrdt> get crdt async { return _crdt ??=
  // await _open(); }`. That pattern only serializes *sequential* calls: an
  // async getter's body runs synchronously up to its first `await` on
  // *every* invocation, so several near-simultaneous unawaited callers (as
  // of this session, HomeShell.initState fires three: _loadGroups(),
  // ThemeController.load(), SyncService.connect()) would all see `_crdt ==
  // null` and each independently call _open(), racing each other's
  // connection lifecycle. Caching the Future in a plain (non-async) getter
  // makes the `??=` assignment happen synchronously on the very first call,
  // so every concurrent caller awaits the one shared in-flight Future
  // instead. Caught by this exact race actually happening: a real
  // "Bad state: This database has already been closed" crash during live
  // verification against the real, built app.
  Future<SqliteCrdt>? _openFuture;

  Future<SqliteCrdt> get crdt => _openFuture ??= _open();

  Future<SqliteCrdt> _open() async {
    final path = await _resolveDatabasePath();

    // essentials.db is always provisioned externally (CSV/Letos into
    // schema.sql's tables, or migrated in place -- see migrations/), never
    // created by the app itself, so "nothing at path" always means
    // something's actually wrong, not "first run." Checked independently of
    // sqlite_crdt succeeding or not, via a plain sqflite connection opened
    // and closed before sqlite_crdt ever touches the file -- see CLAUDE.md
    // "Sync architecture" for the empty-db-propagation incidents this
    // guards against.
    if (!await File(path).exists()) {
      throw StateError(
        'essentials.db not found at $path. Refusing to let sqlite_crdt '
        'silently create an empty one in its place -- this almost always '
        'means Syncthing has the real file mid-move or mid-conflict, or the '
        'crdt_sync server/another device hasn\'t finished its first real '
        'sync yet. Wait for sync to settle, or look in .stversions for a '
        'recoverable copy -- do not just relaunch repeatedly.',
      );
    }
    await _verifyRealSchema(path);

    sqfliteFfiInit();
    final crdt = await SqliteCrdt.open(path);

    // Every connection must re-assert this -- SQLite does not persist
    // PRAGMA foreign_keys across connections. sqlite_crdt has no
    // onConfigure hook, so this happens right after open instead, same as
    // the pre-CRDT version of this file did inside onConfigure. Native
    // SQLite FK actions (RESTRICT/CASCADE) are now purely a local-write
    // safety net, not the primary enforcement mechanism -- see CLAUDE.md
    // for why (crdt.execute() rewrites every DELETE into a soft-delete
    // UPDATE, which SQLite's FK actions never see) -- still worth having
    // for the same reason it always was: catches direct local SQL mistakes
    // even though it's no longer relied on for the RESTRICT/CASCADE
    // pathway proper.
    await crdt.execute('PRAGMA foreign_keys = ON');

    // Defensive, not just belt-and-suspenders -- see the original
    // pre-CRDT version of this file for the WAL-reversion history this
    // guards against. Must be query(), not execute() -- PRAGMA journal_mode
    // = WAL returns the resulting mode as a row, and Android's native
    // execSQL() (irrelevant now that sqlite_crdt is FFI-only, but keeping
    // the same defensive shape rather than assuming the new path is immune
    // to a bug of exactly this class).
    await crdt.query('PRAGMA journal_mode = WAL');

    return crdt;
  }

  /// Defense in depth alongside the file-existence check above: confirm the
  /// file actually has the app's real, v2-bootstrapped schema (checked via
  /// `table_definitions`'s `hlc` column -- present only once the file has
  /// been through `tool/bootstrap_fresh_db.dart`) before ever handing it to
  /// sqlite_crdt. `table_definitions` is the marker rather than any business
  /// table since v2's clean-slate rebuild means business tables no longer
  /// exist until Mike creates them -- see claude/essentials-v2-step2-wipe-
  /// procedure.md. Uses a plain sqflite connection, independent of
  /// sqlite_crdt succeeding or not, opened and closed before sqlite_crdt
  /// touches the file at all.
  Future<void> _verifyRealSchema(String path) async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(path);
    try {
      final columns = await db.rawQuery("PRAGMA table_info('table_definitions')");
      final hasMetadataTable = columns.isNotEmpty;
      final hasHlcColumn = columns.any((c) => c['name'] == 'hlc');
      if (!hasMetadataTable) {
        throw StateError(
          'essentials.db at $path exists but has no real schema (missing '
          'the table_definitions table) -- refusing to use it. This should '
          'never happen to a genuine v2 database; rebuild it with '
          '`dart run tool/bootstrap_fresh_db.dart --out $path --force` '
          'rather than deleting or resetting it by hand.',
        );
      }
      if (!hasHlcColumn) {
        throw StateError(
          'essentials.db at $path has the table_definitions table but is '
          'missing the hlc column -- this copy was never created through '
          'sqlite_crdt\'s CREATE TABLE rewrite (e.g. written by a raw SQL '
          'tool instead of tool/bootstrap_fresh_db.dart). Refusing to open '
          'it with sqlite_crdt; recreate it with '
          '`dart run tool/bootstrap_fresh_db.dart --out $path --force`.',
        );
      }
    } finally {
      await db.close();
    }
  }

  /// Public wrapper around [_resolveDatabasePath] -- exposed for [_verifyRealSchema]
  /// only in the pre-CRDT era; kept public since callers may reasonably want
  /// the real path for diagnostics. **Not** what `SearchIndexService` uses
  /// for its own file -- see [resolveSearchIndexDatabasePath] and that
  /// class's own doc comment for why `search_index` deliberately lives in a
  /// completely separate SQLite file, never a table inside this one.
  Future<String> resolveDatabasePath() => _resolveDatabasePath();

  Future<String> _resolveDatabasePath() async {
    if (Platform.isWindows) {
      return join(_windowsDirectory, _fileName);
    }

    if (Platform.isAndroid) {
      await _ensureAndroidStoragePermission();
      return join(_androidDirectory, _fileName);
    }

    throw UnsupportedError(
      'essentials_app only targets Windows desktop and Android.',
    );
  }

  static const String _searchIndexFileName = 'search_index.db';

  /// Essentials v2 Phase 6 (Global Search) -- the path to `search_index`'s
  /// own, completely separate SQLite file, alongside `essentials.db` in the
  /// same directory on each platform.
  ///
  /// **Not a table inside `essentials.db` -- confirmed, the hard way, this
  /// cannot be one.** `sql_crdt`'s own `init()` (run on every single
  /// `SqliteCrdt.open()`) and `getChangeset()` (run on every sync) both call
  /// `getTables()`, which unconditionally returns *every* physical table in
  /// `sqlite_schema` except `sqlite_%`-prefixed ones -- no opt-out, no
  /// filtering hook (confirmed by reading `sqlite_crdt`'s source:
  /// `getTables()` is a bare `SELECT name FROM sqlite_schema WHERE type =
  /// 'table' AND name NOT LIKE 'sqlite_%'`). Both then blindly assume every
  /// table returned has `modified`/`hlc`/`node_id` columns. An FTS5 virtual
  /// table (plus its own shadow tables --
  /// `<name>_data`/`_idx`/`_content`/`_docsize`/`_config`, all real
  /// `sqlite_schema` entries) has none of those -- the very first attempt at
  /// this (a `search_index` table inside `essentials.db`) broke
  /// `SqliteCrdt.open()` outright for the whole app on the very next launch
  /// (`SqliteException: no such column: modified`), caught only by
  /// `flutter test` immediately re-opening a fresh connection against the
  /// same real db -- not a theoretical risk, an actual incident, fixed by
  /// dropping the table and moving to this separate-file design instead.
  /// A completely separate file sidesteps this category of problem
  /// entirely: `sqlite_crdt` never touches it, never scans it, never knows
  /// it exists.
  Future<String> resolveSearchIndexDatabasePath() async {
    if (Platform.isWindows) {
      return join(_windowsDirectory, _searchIndexFileName);
    }

    if (Platform.isAndroid) {
      await _ensureAndroidStoragePermission();
      return join(_androidDirectory, _searchIndexFileName);
    }

    throw UnsupportedError(
      'essentials_app only targets Windows desktop and Android.',
    );
  }

  static const String _filesDirectoryName = 'files';

  /// The `image` field's own local files-root, alongside `essentials.db`
  /// in the same directory on each platform -- see
  /// claude/essentials-v2-image-field-design.md. Mirrors
  /// [resolveSearchIndexDatabasePath]'s exact shape (a sibling path, not a
  /// table inside `essentials.db`) for the same platform-conditional
  /// reasoning, but a directory instead of a single file:
  /// `FileSyncService` resolves `{table}/{record_id}/{field_name}/
  /// {filename}` relative keys against this root, joined the same way on
  /// every device. Unlike `essentials.db` itself, this directory has no
  /// external provisioning step -- created here if it doesn't exist yet,
  /// since the first image ever captured/dropped is what creates it.
  Future<String> resolveFilesDirectory() async {
    late final String base;
    if (Platform.isWindows) {
      base = _windowsDirectory;
    } else if (Platform.isAndroid) {
      await _ensureAndroidStoragePermission();
      base = _androidDirectory;
    } else {
      throw UnsupportedError(
        'essentials_app only targets Windows desktop and Android.',
      );
    }
    final dir = join(base, _filesDirectoryName);
    await Directory(dir).create(recursive: true);
    return dir;
  }

  Future<void> _ensureAndroidStoragePermission() async {
    var status = await Permission.manageExternalStorage.status;
    if (status.isGranted) return;

    status = await Permission.manageExternalStorage.request();
    if (!status.isGranted) {
      throw StateError(
        'MANAGE_EXTERNAL_STORAGE was not granted -- essentials_app cannot '
        'reach the synced database folder without it.',
      );
    }
  }

  /// Whether the first-run Android storage permission still needs asking.
  /// Always false on Windows.
  Future<bool> needsAndroidStoragePermission() async {
    if (!Platform.isAndroid) return false;
    final status = await Permission.manageExternalStorage.status;
    return !status.isGranted;
  }

  Future<void> close() async {
    final future = _openFuture;
    if (future != null) {
      await (await future).close();
      _openFuture = null;
    }
  }
}
