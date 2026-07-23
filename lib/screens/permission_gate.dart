import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../db/database_helper.dart';
import 'home_shell.dart';

/// First-run gate for Android's MANAGE_EXTERNAL_STORAGE ("All files
/// access") permission -- required to reach the fixed, arbitrary,
/// Syncthing-synced db path under scoped storage (Android 10+). Only ever
/// mounted on Android (see main.dart); Windows goes straight to
/// [HomeShell].
class PermissionGate extends StatefulWidget {
  const PermissionGate({super.key});

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate> {
  late Future<bool> _needsPermission;

  @override
  void initState() {
    super.initState();
    _needsPermission = DatabaseHelper.instance.needsAndroidStoragePermission();
  }

  Future<void> _grant() async {
    await Permission.manageExternalStorage.request();
    setState(() {
      _needsPermission = DatabaseHelper.instance.needsAndroidStoragePermission();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _needsPermission,
      builder: (context, snapshot) {
        // See CLAUDE.md "Sync architecture" incident writeup / home_shell
        // .dart's matching fix -- `!snapshot.hasData` alone can't tell
        // "still loading" from "errored," so a thrown exception here would
        // otherwise spin forever with no indication anything was wrong.
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Failed to load: ${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (!snapshot.data!) {
          return const HomeShell();
        }
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Essentials needs "All files access" to reach the shared '
                    'database folder synced via Syncthing.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _grant, child: const Text('Grant Access')),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
