import 'dart:io';

import 'package:path/path.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opens the single shared `essentials.db`, platform-conditionally.
///
/// Windows: `sqflite_common_ffi` pointed at the one real Windows copy in
/// `C:\Databases\essentials_app` (see CLAUDE.md "Project layout" -- this
/// path must never diverge from that, no local copy inside the Flutter
/// project). Android: native `sqflite` pointed at the Syncthing-synced
/// folder under external storage, gated behind a first-run
/// MANAGE_EXTERNAL_STORAGE check (scoped storage blocks arbitrary paths
/// without it).
class DatabaseHelper {
  DatabaseHelper._();

  static final DatabaseHelper instance = DatabaseHelper._();

  static const String _windowsDirectory = r'C:\Databases\essentials_app';
  static const String _androidDirectory =
      '/storage/emulated/0/Databases/essentials_app';
  static const String _fileName = 'essentials.db';

  Database? _db;

  Future<Database> get database async {
    return _db ??= await _open();
  }

  Future<Database> _open() async {
    final path = await _resolveDatabasePath();

    // sqflite/sqflite_common_ffi both silently create an empty db if
    // nothing exists at `path` -- normally a reasonable default, but wrong
    // for this app: essentials.db is always provisioned externally (CSV/
    // Letos into schema.sql's tables), never created by the app itself, so
    // "nothing at path" always means something's actually wrong (most
    // often Syncthing mid-move/mid-conflict), not "first run." Hit this
    // exactly once already: the file was briefly missing here mid-sync,
    // the app quietly created an empty stand-in, and Syncthing then
    // propagated that empty db over the real one on the *other* device too
    // -- see CLAUDE.md "Sync architecture" for the full incident writeup
    // and recovery. Failing loudly here is what should have caught it
    // before any data was ever at risk.
    if (!await File(path).exists()) {
      throw StateError(
        'essentials.db not found at $path. Refusing to let sqflite '
        'silently create an empty one in its place -- this almost always '
        'means Syncthing has the real file mid-move or mid-conflict. Wait '
        'for sync to settle (check the Syncthing UI), or look in '
        '.stversions for a recoverable copy -- do not just relaunch '
        'repeatedly, that is how the empty-db incident happened.',
      );
    }

    final DatabaseFactory factory;
    if (Platform.isWindows) {
      sqfliteFfiInit();
      factory = databaseFactoryFfi;
    } else if (Platform.isAndroid) {
      factory = databaseFactory;
    } else {
      throw UnsupportedError(
        'essentials_app only targets Windows desktop and Android.',
      );
    }

    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        // Every connection must re-assert this -- SQLite does not persist
        // PRAGMA foreign_keys across connections, and it must be set in
        // onConfigure (not onCreate), which only fires once per fresh db.
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          // Defensive, not just belt-and-suspenders: journal_mode=WAL has
          // been found reverted to the default (delete) twice now with no
          // confirmed trigger (see CLAUDE.md "Sync architecture" -- ruled
          // out migrate.py, inconclusive on Android's scoped-storage FUSE
          // layer). journal_mode is a no-op to re-set when already WAL, so
          // asserting it on every connection open costs nothing and removes
          // the dependency on someone noticing via a manual Letos check.
          //
          // Must be rawQuery, not execute -- unlike `PRAGMA foreign_keys`
          // (which returns nothing), `PRAGMA journal_mode=WAL` returns the
          // resulting mode as a row. Android's SQLiteDatabase.execSQL()
          // (what sqflite's execute() calls into on that platform) rejects
          // any statement that returns a result set with "Queries can be
          // performed using SQLiteDatabase query or rawQuery methods only"
          // -- hit exactly that on MIKE-12R, crashing the db open during
          // app startup (which also explains the intermittent "log reader
          // stopped unexpectedly" VS Code debug-connection failures around
          // the same time -- the process was dying before the debugger
          // could attach).
          await db.rawQuery('PRAGMA journal_mode = WAL');
        },
      ),
    );

    await _verifyRealSchema(db, path);

    return db;
  }

  /// Defense in depth alongside the file-existence check above: even if a
  /// file exists at [path], confirm it actually has the app's real schema
  /// (checked via one known core table) before handing the connection
  /// back. Catches the same underlying failure a different way -- e.g. a
  /// still-empty file that already existed at the moment of the exists()
  /// check above (the empty stub itself, once created, does exist).
  Future<void> _verifyRealSchema(Database db, String path) async {
    final tables = await db.query(
      'sqlite_master',
      where: 'type = ? AND name = ?',
      whereArgs: ['table', 'domain'],
    );
    if (tables.isEmpty) {
      await db.close();
      throw StateError(
        'essentials.db at $path exists but has no real schema (missing '
        'the domain table) -- refusing to use it. Same underlying issue '
        'as the file-not-found check above: do not delete or reset this '
        'file, check Syncthing / .stversions for a recoverable copy.',
      );
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
    final db = _db;
    if (db != null) {
      await db.close();
      _db = null;
    }
  }
}
