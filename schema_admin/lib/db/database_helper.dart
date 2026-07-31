import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

/// Opens the server's own `hub.db` directly -- schema_admin runs only on
/// MIKE-CU, alongside the server, and is a local peer to it the same way
/// `essentials_app`'s own Windows instance is: a separate `SqliteCrdt`
/// connection to a file the server process also has open. SQLite's WAL
/// mode supports this (confirmed project-wide -- see CLAUDE.md "WAL
/// interaction"); `sqlite_crdt`'s merge/writes are ordinary SQL through
/// that same multi-process-safe path, no different from a second app
/// instance.
///
/// Every write here goes through `sqlite_crdt`'s own API (`crdt.execute`/
/// `crdt.query`), never raw `sqlite3` -- see CLAUDE.md "schema_admin --
/// migration authoring tool" for why that's a hard requirement, not a
/// style preference.
class DatabaseHelper {
  DatabaseHelper._();

  static final DatabaseHelper instance = DatabaseHelper._();

  static const String hubDbPath = r'C:\Databases\essentials_app\server\hub.db';

  // Same in-flight-Future-caching pattern as essentials_app's own
  // DatabaseHelper -- see that file's doc comment for the exact race this
  // avoids (several near-simultaneous unawaited callers each independently
  // calling _open()).
  Future<SqliteCrdt>? _openFuture;

  Future<SqliteCrdt> get crdt => _openFuture ??= _open();

  Future<SqliteCrdt> _open() async {
    // hub.db is always provisioned by server.dart's own onCreate the first
    // time the server runs -- schema_admin never creates it. Nothing at
    // this path means the server has never been started on this machine,
    // not "first run" for schema_admin -- refuse rather than let
    // sqlite_crdt silently create an empty file in its place (same
    // discipline as essentials_app's DatabaseHelper, same reasoning: see
    // CLAUDE.md "Sync architecture" incidents).
    if (!await File(hubDbPath).exists()) {
      throw StateError(
        'hub.db not found at $hubDbPath. schema_admin never creates this '
        'file -- start the essentials_app server (essentials_app/server/) '
        'at least once first, or check it\'s actually running on this '
        'machine.',
      );
    }

    sqfliteFfiInit();
    final crdt = await SqliteCrdt.open(hubDbPath);
    await crdt.execute('PRAGMA foreign_keys = ON');
    return crdt;
  }

  Future<void> close() async {
    final future = _openFuture;
    if (future != null) {
      await (await future).close();
      _openFuture = null;
    }
  }
}
