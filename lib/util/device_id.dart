import 'dart:io';

import 'package:flutter/services.dart';

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
      final name = await _channel.invokeMethod<String>('deviceName');
      id = (name == null || name.isEmpty) ? 'unknown-android' : name;
    } else {
      throw UnsupportedError(
        'essentials_app only targets Windows desktop and Android.',
      );
    }

    return _cached = id;
  }
}
