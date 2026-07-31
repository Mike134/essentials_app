import 'dart:async';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'database_helper.dart';
import 'migration_service.dart';
import 'sql_helpers.dart';

/// Custom [ChangesetBuilder] -- not crdt_sync's own default
/// (`Crdt.getChangeset` directly), which is what [CrdtSyncClient] uses if
/// you don't override it. Works around a real, confirmed sync gap:
/// `sql_crdt`'s watermark (`Crdt.getLastModified`) is a single maximum
/// across *every* table, not tracked per table. This app's per-device grid
/// settings (`table_column_settings`/`device_settings`) write very
/// frequently -- every resize, wrap toggle, footer choice, filter change.
/// If one of those lands with a *later* timestamp before some other,
/// slower-moving table's still-pending change has synced, that table's
/// change gets permanently excluded: the peer's "send me anything newer
/// than my watermark" request has already raced past it, and nothing about
/// that old change is ever going to become newer than the watermark on its
/// own. Not a timing fluke the existing periodic reconnect (see
/// [periodicReconnectInterval]) papers over -- confirmed directly, root-
/// caused with MIKE-12R's own `status` colors staying stuck at their
/// pre-edit values across many reconnects spanning several minutes, while
/// the server kept re-offering the exact same unsent batch every time.
///
/// Fix: for the one-time "catch up since last sync" pull crdt_sync makes on
/// every (re)connect -- identifiable here by [modifiedAfter] being set --
/// ignore that watermark entirely and send the complete current dataset
/// instead. Safe and cheap: `sql_crdt`'s own merge is an idempotent,
/// hlc-compared upsert (`INSERT ... ON CONFLICT DO UPDATE ... WHERE
/// excluded.hlc > table.hlc`) -- a resend of already-applied data is a
/// same-row no-op, confirmed directly by replaying it by hand against a
/// pulled copy of MIKE-12R's database. This app's whole dataset is small
/// enough on a local network that resending everything every reconnect
/// (currently every 5 minutes) is negligible. The *live* push path (a
/// single just-made local edit, identifiable by [modifiedOn] being set
/// instead) is left exactly as narrow as the library's own default --
/// there's no watermark to get stuck there, it's already scoped to one
/// specific change.
///
/// Used by both [SyncService] (this file) and the server (`server/bin/
/// server.dart`'s own copy, passed to `crdt_sync_server.upgrade`) --
/// duplicated rather than shared, since the server is a separate Dart
/// package/project, the same way `schema.sql`'s statements are already
/// duplicated into the server's own `schemaStatements` list.
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
    // modifiedAfter deliberately dropped -- see doc comment above.
  );
}

/// MIKE-CU's fixed address, made permanent via a router-side DHCP
/// reservation on the HOMExf gateway -- see CLAUDE.md "Syncing at the
/// Record Level". Compile-time fallback only: a device without a synced
/// copy of essentials.db yet has no other way to know where to connect the
/// very first time. Once connected at least once, [SyncService] reads the
/// real value from `app_settings` instead -- see [_resolveServerUri].
const String compileTimeDefaultServerHost = '10.0.0.134';
const int compileTimeDefaultServerPort = 1340;

const String _serverAddressKey = 'sync_server_address';

/// How often to force a fresh reconnect on an already-healthy connection --
/// see [_schedulePeriodicReconnect]'s doc comment for why this exists at
/// all. Not tuned precisely; just short enough to bound the worst case to
/// something reasonable without being wasteful.
const Duration periodicReconnectInterval = Duration(minutes: 5);

/// Owns this device's outward connection to the crdt_sync coordinator
/// running on MIKE-CU (`essentials_app/server/`). Every device, including
/// MIKE-CU's own Flutter app instance, connects as a plain network client
/// -- there is no special-cased "server IS the app" path, so real-time push
/// notifications work identically everywhere (see CLAUDE.md's "Server's
/// database file" decision for why).
class SyncService {
  SyncService._(this._client);

  final CrdtSyncClient _client;
  Timer? _reconnectTimer;

  static SyncService? _instance;

  /// Resolves the server address (see [_resolveServerUri]) and connects.
  /// Safe to call once at app startup; [CrdtSyncClient] handles its own
  /// reconnection with exponential backoff after that.
  static Future<SyncService> connect() async {
    if (_instance != null) return _instance!;

    final crdt = await DatabaseHelper.instance.crdt;
    final uri = await _resolveServerUri(crdt);

    final client = CrdtSyncClient(
      crdt,
      uri,
      onConnect: (nodeId, info) {
        _log('connected to server (peer $nodeId)');
        // Re-check for newly-arrived migrations on every connect, not just
        // app launch -- including the periodic reconnect below. See
        // MigrationService's doc comment for why this is here: it's the
        // mitigation for the one real gap HomeShell's launch-time
        // applyPending() can't close on its own (a migration and
        // migration-dependent data arriving in the same catch-up pull).
        // Fire-and-forget -- a failure here already recorded a real
        // migration_status row of its own; nothing here needs to block
        // the connection.
        MigrationService().applyPending();
      },
      onDisconnect: (nodeId, code, reason) =>
          _log('disconnected from server (code=$code reason=$reason)'),
      changesetBuilder: ({onlyTables, onlyNodeId, exceptNodeId, modifiedOn, modifiedAfter}) =>
          safeChangesetBuilder(
            crdt,
            onlyTables: onlyTables,
            onlyNodeId: onlyNodeId,
            exceptNodeId: exceptNodeId,
            modifiedOn: modifiedOn,
          ),
    );
    client.connect();

    final service = SyncService._(client);
    service._schedulePeriodicReconnect();
    _instance = service;
    return service;
  }

  /// crdt_sync has no acknowledgment/retry mechanism -- if a changeset
  /// fails to merge on the receiving side (a real, confirmed failure mode:
  /// see CLAUDE.md "Syncing at the Record Level" -- a live test hit a real
  /// FOREIGN KEY failure this way), the sender is never told, and nothing
  /// resends it automatically within one continuously-healthy connection.
  /// The only thing that actually re-triggers a resend is a fresh
  /// handshake, which only happens on (re)connect -- confirmed directly:
  /// that same failed write only recovered because the connection happened
  /// to drop and reconnect on its own afterward, not because of any
  /// built-in retry. This timer makes that recovery path deliberate
  /// instead of incidental, by periodically forcing a disconnect+reconnect
  /// even on an already-healthy connection -- cheap on a local network,
  /// and bounds how long a silently-failed write could stay stuck to
  /// roughly one interval instead of "however long until something else
  /// happens to drop the connection."
  void _schedulePeriodicReconnect() {
    _reconnectTimer = Timer.periodic(periodicReconnectInterval, (_) async {
      _log('periodic reconnect (forces a fresh handshake so any '
          'previously-failed merge gets re-evaluated and resent)');
      await _client.disconnect();
      _client.connect();
    });
  }

  Future<void> disconnect() {
    _reconnectTimer?.cancel();
    return _client.disconnect();
  }

  SocketState get state => _client.state;

  Stream<SocketState> get watchState => _client.watchState;

  /// `app_settings.sync_server_address` (format `host:port`) if a device
  /// has ever connected before, else [compileTimeDefaultServerHost]:
  /// [compileTimeDefaultServerPort] -- and seeds that default into
  /// `app_settings` so it becomes the synced source of truth for every
  /// device from here on (repointing the server later is then a data
  /// change, not a rebuild). See CLAUDE.md "Syncing at the Record Level" --
  /// "Server-address bootstrapping."
  static Future<Uri> _resolveServerUri(SqliteCrdt crdt) async {
    final rows = await crdt.query(
      'SELECT value FROM app_settings WHERE setting_key = ?1 AND is_deleted = 0',
      [_serverAddressKey],
    );
    final stored = rows.isEmpty ? null : rows.first['value'] as String?;

    if (stored != null && stored.isNotEmpty) {
      return Uri.parse('ws://$stored');
    }

    final defaultAddress = '$compileTimeDefaultServerHost:$compileTimeDefaultServerPort';
    await crdt.upsert('app_settings', {'setting_key': _serverAddressKey, 'value': defaultAddress});
    return Uri.parse('ws://$defaultAddress');
  }

  static void _log(String message) {
    // ignore: avoid_print
    print('[SyncService] $message');
  }
}
