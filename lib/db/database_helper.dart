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
  /// file actually has the app's real, CRDT-migrated schema (checked via
  /// `domain`'s `hlc` column -- present only after migrations/004 ran)
  /// before ever handing it to sqlite_crdt. Uses a plain sqflite connection,
  /// independent of sqlite_crdt succeeding or not, opened and closed before
  /// sqlite_crdt touches the file at all.
  Future<void> _verifyRealSchema(String path) async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(path);
    try {
      final columns = await db.rawQuery("PRAGMA table_info('domain')");
      final hasDomainTable = columns.isNotEmpty;
      final hasHlcColumn = columns.any((c) => c['name'] == 'hlc');
      if (!hasDomainTable) {
        throw StateError(
          'essentials.db at $path exists but has no real schema (missing '
          'the domain table) -- refusing to use it. Do not delete or reset '
          'this file, check Syncthing / .stversions for a recoverable copy.',
        );
      }
      if (!hasHlcColumn) {
        throw StateError(
          'essentials.db at $path has the domain table but is missing the '
          'hlc column -- this copy predates the CRDT-tracking migration '
          '(migrations/004_crdt_tracking_columns.sql / '
          '005_entity_id_scheme_and_crdt_columns.sql). Refusing to open it '
          'with sqlite_crdt; run the migration against this copy first.',
        );
      }
    } finally {
      await db.close();
    }
  }

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
