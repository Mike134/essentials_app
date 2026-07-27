import 'dart:async';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'database_helper.dart';
import 'sql_helpers.dart';

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
      onConnect: (nodeId, info) => _log('connected to server (peer $nodeId)'),
      onDisconnect: (nodeId, code, reason) =>
          _log('disconnected from server (code=$code reason=$reason)'),
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
