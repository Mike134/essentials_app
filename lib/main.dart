import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
      // TrinaGrid's lookup-field dropdown (TrinaColumnType.select, used by
      // GenericListScreen for FK columns) renders through shadcn_ui, which
      // needs a ShadTheme ancestor -- without one, opening that dropdown
      // throws ("ShadTheme.of() called with a context that does not
      // contain a ShadTheme"). Boolean/text/number columns don't hit this
      // since they don't use shadcn_ui's popup menu.
      builder: (context, child) => ShadTheme(
        data: ShadThemeData(brightness: Theme.of(context).brightness),
        child: child!,
      ),
      // Android needs the MANAGE_EXTERNAL_STORAGE gate before the db is
      // reachable at all; Windows has no such gate.
      home: Platform.isAndroid ? const PermissionGate() : const HomeShell(),
    );
  }
}
