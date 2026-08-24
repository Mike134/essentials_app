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

  /// Fires whenever an incoming changeset includes at least one
  /// `table_definitions`/`field_definitions`/`migration_log` row -- i.e.
  /// the schema itself (not just row data within an already-known table)
  /// changed on another device. [HomeShell] listens for this to refresh
  /// its nav/table list live, instead of only on return from Settings --
  /// found live (CLAUDE.md "Essentials v2 Phase 1" -- Step 9 follow-up): a
  /// rename made on one device only ever showed up on another after that
  /// other device's user happened to open and leave Settings, since
  /// nothing reactive existed for this app's own most basic architectural
  /// fact -- table discovery is "at launch, not live" (CLAUDE.md "Table
  /// Discovery phase") -- once the *sync* side of "live" genuinely started
  /// working this session (see the frozen-hlc fix above), the *display*
  /// side's missing reactivity became the next visible gap.
  ///
  /// `migration_log` was added to the trigger set after a second, real gap
  /// this surfaced: a table *created* on another device while this one was
  /// already connected arrived with correct `table_definitions`/
  /// `field_definitions` metadata (plain CRDT row sync, always live) but
  /// its physical `CREATE TABLE` never actually ran here -- nothing except
  /// app launch and `SyncService`'s own `onConnect` ever called
  /// `MigrationService.applyPending`, and neither of those fires for a
  /// migration arriving mid-session over an already-open connection. The
  /// table showed up correctly in Manage Tables (reads `table_definitions`
  /// directly, no physical check) but silently never appeared in the real
  /// nav (`SchemaRegistry.buildConfig` correctly detects the schema drift
  /// and skips it rather than crash -- see `loadEffectiveTables`'s own doc
  /// comment). [HomeShell]'s listener now calls
  /// `MigrationService().applyPending()` before reloading, so the physical
  /// DDL exists by the time it tries to build a `TableConfig` for it.
  static final _schemaChangesController = StreamController<void>.broadcast();
  static Stream<void> get schemaChanges => _schemaChangesController.stream;

  /// Fires with the set of table names an incoming changeset touched,
  /// for *any* table -- not just the schema tables [schemaChanges] narrows
  /// to. [GenericListScreen] listens for this to reload its grid live when
  /// another device adds/edits/deletes a row in the table it's currently
  /// showing, instead of only on this screen's own explicit actions
  /// (add/edit/delete/cell-edit/table-switch).
  ///
  /// Found live: a record added on one device only ever showed up on
  /// another device's already-open grid after leaving and returning to
  /// that table -- the exact same "sync itself works, the *display* side's
  /// reactivity doesn't" gap [schemaChanges] was built to close for nav/
  /// table-list changes, just never extended to row data. Same
  /// before-the-merge-completes timing caveat as [schemaChanges] --
  /// listeners should debounce a short beat before reloading rather than
  /// assuming the merge has landed by the time this fires.
  static final _dataChangesController = StreamController<Set<String>>.broadcast();
  static Stream<Set<String>> get dataChanges => _dataChangesController.stream;

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
        _lastConnectedAt = DateTime.now().toUtc();
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
      // Fires before crdt_sync actually merges the changeset (confirmed by
      // reading crdt_sync's own source -- CrdtSync._mergeChangeset calls
      // this, then awaits crdt.merge() right after), so this can't wait for
      // the merge to be visibly done -- [HomeShell]'s listener debounces a
      // short beat before reloading rather than assuming the merge has
      // landed by the time this fires.
      onChangesetReceived: (nodeId, recordCounts) {
        if (recordCounts.containsKey('table_definitions') ||
            recordCounts.containsKey('field_definitions') ||
            recordCounts.containsKey('migration_log')) {
          _schemaChangesController.add(null);
        }
        if (recordCounts.isNotEmpty) {
          _dataChangesController.add(recordCounts.keys.toSet());
        }
      },
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

  /// Best-effort "has this device connected to the server since <time>"
  /// signal -- used to gate stage-2 "Permanently delete"
  /// (claude/essentials-v2-phase1-design.md, "Permanently delete gating
  /// signal": stage 2 should stay unavailable until sync has confirmed a
  /// soft-delete's tombstone actually reached the server). crdt_sync has
  /// no per-row acknowledgment ([safeChangesetBuilder]'s own doc comment
  /// covers why the periodic reconnect above exists at all) -- a connect
  /// that happens *after* a tombstone's own `modified` timestamp means
  /// that tombstone was necessarily included in that connect's outgoing
  /// catch-up push ([safeChangesetBuilder] always sends the complete local
  /// dataset on connect, never just anything newer than a watermark), so
  /// comparing the two is the best confirmation available without building
  /// real per-row ack tracking. Not an ironclad guarantee -- the push
  /// could in principle still fail silently the same way the real FOREIGN
  /// KEY failure documented in CLAUDE.md once did -- but a plain
  /// `is_deleted` tombstone with no dependencies is exactly the kind of
  /// write that failure mode doesn't apply to. Static (not per-instance)
  /// since `ManageTablesScreen`/`ManageFieldsScreen` need this before ever
  /// touching a [SyncService] instance themselves.
  static DateTime? get lastConnectedAt => _lastConnectedAt;
  static DateTime? _lastConnectedAt;

  static Future<Uri> _resolveServerUri(SqliteCrdt crdt) async {
    final address = await resolveServerAddress(crdt);
    return Uri.parse('ws://$address');
  }

  /// `app_settings.sync_server_address` (format `host:port`) if a device
  /// has ever connected before, else [compileTimeDefaultServerHost]:
  /// [compileTimeDefaultServerPort] -- and seeds that default into
  /// `app_settings` so it becomes the synced source of truth for every
  /// device from here on (repointing the server later is then a data
  /// change, not a rebuild). See CLAUDE.md "Syncing at the Record Level" --
  /// "Server-address bootstrapping." Public (not just [_resolveServerUri]'s
  /// internal use) so [MigrationService] can reach the server's plain-HTTP
  /// `/migrations` endpoint at the same address, without duplicating this
  /// resolution logic.
  static Future<String> resolveServerAddress(SqliteCrdt crdt) async {
    final rows = await crdt.query(
      'SELECT value FROM app_settings WHERE setting_key = ?1 AND is_deleted = 0',
      [_serverAddressKey],
    );
    final stored = rows.isEmpty ? null : rows.first['value'] as String?;

    if (stored != null && stored.isNotEmpty) {
      return stored;
    }

    final defaultAddress = '$compileTimeDefaultServerHost:$compileTimeDefaultServerPort';
    await crdt.upsert('app_settings', {'setting_key': _serverAddressKey, 'value': defaultAddress});
    return defaultAddress;
  }

  static void _log(String message) {
    // ignore: avoid_print
    print('[SyncService] $message');
  }
}
