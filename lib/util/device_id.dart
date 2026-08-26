import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../db/database_helper.dart';

/// Live OS-reported device identifier used to scope per-device rows in
/// `table_column_settings`/`table_view_settings` (see CLAUDE.md "Real-usage
/// findings" -- device_id must be queried live, never hardcoded or
/// config-set).
///
/// Windows has a real hostname (`Platform.localHostname`, e.g. `MIKE-LP`).
/// Android has no equivalent -- `Platform.localHostname` there resolves to a
/// meaningless generic value, not the user-facing device name (`MIKE-12R`)
/// shown in Settings > About phone / Bluetooth -- so Android goes through a
/// small platform channel to read `Settings.Global.DEVICE_NAME` instead (see
/// `MainActivity.kt`).
class DeviceId {
  DeviceId._();

  static const MethodChannel _channel = MethodChannel(
    'essentials_app/device_id',
  );

  static String? _cached;

  /// Resolves once per app run, then returns the cached value -- the
  /// device's identity can't change mid-session.
  static Future<String> resolve() async {
    final cached = _cached;
    if (cached != null) return cached;

    final String id;
    if (Platform.isWindows) {
      id = Platform.localHostname;
    } else if (Platform.isAndroid) {
      id = await _resolveAndroid();
    } else {
      throw UnsupportedError(
        'essentials_app only targets Windows desktop and Android.',
      );
    }

    return _cached = id;
  }

  /// **A real bug, found live: this channel's handler only exists in
  /// `MainActivity.configureFlutterEngine` -- it is never registered on
  /// the completely separate, headless `FlutterEngine` Android's
  /// `workmanager` plugin creates for background execution (confirmed by
  /// reading `workmanager_android`'s own `BackgroundWorker.kt`: it
  /// constructs a bare `FlutterEngine(applicationContext)` with no
  /// `MainActivity` ever attached to it).** Real Flutter *plugins*
  /// (`sqflite`, `flutter_local_notifications`, `permission_handler`) auto
  /// -register on that engine too via `GeneratedPluginRegistrant`
  /// (`FlutterEngine`'s own default constructor behavior) -- only this
  /// app's own hand-rolled, `Activity`-scoped channel does not, since it
  /// was never declared as a real plugin. Confirmed live on MIKE-12R: the
  /// background-scheduled-check job ran and completed (visible in `adb
  /// shell dumpsys jobscheduler`), but the invoked method threw
  /// `MissingPluginException` immediately, aborting
  /// `BackgroundScheduleService.runDueScheduledEvents` before it ever
  /// checked what was due -- no crash log, no notification, silently
  /// caught by `backgroundDispatcherCallback`'s own catch-all (same "no
  /// UI to report to" posture as its Windows counterpart).
  ///
  /// Fixed without any native/plugin-registration changes: every
  /// successful foreground resolution (which always works -- `MainActivity`
  /// is attached whenever the app is actually open) also writes the
  /// resolved name to a small cache file next to `essentials.db`. A
  /// background-isolate resolution that hits `MissingPluginException`
  /// falls back to that cached value instead of failing outright --
  /// correct in practice, since a personal device's own name essentially
  /// never changes between one foreground app open and the next
  /// background check.
  static Future<String> _resolveAndroid() async {
    try {
      final name = await _channel.invokeMethod<String>('deviceName');
      final resolved = (name == null || name.isEmpty) ? 'unknown-android' : name;
      unawaited(_writeCache(resolved));
      return resolved;
    } on MissingPluginException {
      final cached = await _readCache();
      return cached ?? 'unknown-android';
    }
  }

  static Future<File> _cacheFile() async {
    final dbPath = await DatabaseHelper.instance.resolveDatabasePath();
    return File(p.join(p.dirname(dbPath), '.device_id_cache'));
  }

  static Future<void> _writeCache(String id) async {
    try {
      final file = await _cacheFile();
      await file.writeAsString(id);
    } catch (_) {
      // Best-effort -- a failed cache write just means a future
      // background-isolate resolution falls back to 'unknown-android'
      // instead of the real name, not a functional break of anything
      // running in the foreground right now.
    }
  }

  static Future<String?> _readCache() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return null;
      final content = (await file.readAsString()).trim();
      return content.isEmpty ? null : content;
    } catch (_) {
      return null;
    }
  }
}
