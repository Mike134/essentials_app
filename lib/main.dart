import 'dart:io';

import 'package:flutter/material.dart';

import 'screens/home_shell.dart';
import 'screens/permission_gate.dart';

void main() {
  runApp(const EssentialsApp());
}

class EssentialsApp extends StatelessWidget {
  const EssentialsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Essentials',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
      // Android needs the MANAGE_EXTERNAL_STORAGE gate before the db is
      // reachable at all; Windows has no such gate.
      home: Platform.isAndroid ? const PermissionGate() : const HomeShell(),
    );
  }
}
