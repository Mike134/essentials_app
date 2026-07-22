import 'package:flutter/material.dart';

import '../config/table_configs.dart';
import '../models/table_config.dart';
import '../util/strings.dart';
import 'generic_list_screen.dart';

/// Responsive nav chrome around the per-table [GenericListScreen]s:
/// [NavigationRail] on wide (Windows desktop) layouts, [Drawer] on narrow
/// (Android) layouts -- one [LayoutBuilder] switch, not two separate
/// implementations, per CLAUDE.md's "one codebase, no native control
/// mapping" decision. Only `domain` is registered so far (batch 1); the
/// rest of batch 1 is just additions to [registeredTables].
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const double _wideBreakpoint = 600;

  int _selectedIndex = 0;

  void _select(int index) => setState(() => _selectedIndex = index);

  @override
  Widget build(BuildContext context) {
    final tables = registeredTables;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= _wideBreakpoint;
        final content = GenericListScreen(
          key: ValueKey(tables[_selectedIndex].tableName),
          config: tables[_selectedIndex],
          drawer: isWide ? null : _buildDrawer(tables),
        );

        if (!isWide) return content;

        return Scaffold(
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: _selectedIndex,
                onDestinationSelected: _select,
                labelType: NavigationRailLabelType.all,
                destinations: [
                  for (final table in tables)
                    NavigationRailDestination(
                      icon: const Icon(Icons.table_chart_outlined),
                      selectedIcon: const Icon(Icons.table_chart),
                      label: Text(titleCase(table.tableName)),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: content),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDrawer(List<TableConfig> tables) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(child: Text('Essentials')),
          for (var i = 0; i < tables.length; i++)
            ListTile(
              leading: const Icon(Icons.table_chart_outlined),
              title: Text(titleCase(tables[i].tableName)),
              selected: i == _selectedIndex,
              onTap: () {
                _select(i);
                Navigator.pop(context);
              },
            ),
        ],
      ),
    );
  }
}
