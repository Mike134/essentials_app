package com.example.essentials_app

import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Exposes the user-facing Android device name (Settings > About phone /
// Bluetooth, e.g. "MIKE-12R") to Dart -- there's no Windows-hostname
// equivalent reachable from dart:io on Android, so this platform channel is
// how lib/util/device_id.dart gets it. See CLAUDE.md "Real-usage findings"
// for why device_id must be the live OS-reported name, not hardcoded.
class MainActivity : FlutterActivity() {
    private val deviceIdChannel = "essentials_app/device_id"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceIdChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "deviceName") {
                    result.success(Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME))
                } else {
                    result.notImplemented()
                }
            }
    }
}
