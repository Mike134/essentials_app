import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'screens/home_shell.dart';
import 'screens/permission_gate.dart';
import 'theme/theme_controller.dart';

void main() {
  runApp(const EssentialsApp());
}

/// A [StatelessWidget] originally -- now needs to be a [StatefulWidget]
/// purely so [ThemeController.instance] (a [ChangeNotifier]) has a
/// [ListenableBuilder] to rebuild [MaterialApp]'s `theme:` under when
/// settings change (see the Font/Color/Theme settings screen, CLAUDE.md
/// "Real-usage findings" Step 5). [ThemeController.load] itself is *not*
/// called here -- see its own doc comment for why that has to wait until
/// `HomeShell`, after Android's permission gate.
class EssentialsApp extends StatefulWidget {
  const EssentialsApp({super.key});

  @override
  State<EssentialsApp> createState() => _EssentialsAppState();
}

class _EssentialsAppState extends State<EssentialsApp> {
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeController.instance,
      builder: (context, _) {
        return MaterialApp(
          title: 'Essentials',
          theme: ThemeController.instance.themeData,
          // TrinaGrid's lookup-field dropdown (TrinaColumnType.select, used
          // by GenericListScreen for FK columns) renders through
          // shadcn_ui, which needs a ShadTheme ancestor -- without one,
          // opening that dropdown throws ("ShadTheme.of() called with a
          // context that does not contain a ShadTheme"). Boolean/text/
          // number columns don't hit this since they don't use shadcn_ui's
          // popup menu.
          builder: (context, child) => ShadTheme(
            data: ShadThemeData(brightness: Theme.of(context).brightness),
            child: child!,
          ),
          // Android needs the MANAGE_EXTERNAL_STORAGE gate before the db is
          // reachable at all; Windows has no such gate.
          home: Platform.isAndroid ? const PermissionGate() : const HomeShell(),
        );
      },
    );
  }
}
