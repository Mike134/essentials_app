import 'package:flutter/material.dart';

import '../config/table_configs.dart';
import '../models/table_config.dart';
import '../util/strings.dart';
import 'generic_list_screen.dart';

/// Responsive nav chrome around the per-table [GenericListScreen]s:
/// [NavigationRail] on wide (Windows desktop) layouts, [Drawer] on narrow
/// (Android) layouts -- one [LayoutBuilder] switch, not two separate
/// implementations, per CLAUDE.md's "one codebase, no native control
/// mapping" decision. Every registered table (batch 1 and batch 2) shares
/// this same nav shell -- new tables are just additions to
/// [registeredTables].
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
              // Not Flutter's NavigationRail -- it needs bounded height
              // (uses Expanded internally) and can't be made to scroll, so
              // it just overflows once there are more destinations than
              // fit. With all 19 batch-1/2 tables eventually registered, a
              // plain scrollable ListView is the only reliable option.
              SizedBox(
                width: 140,
                child: ListView(
                  children: [
                    for (var i = 0; i < tables.length; i++)
                      _railItem(
                        context,
                        label: titleCase(tables[i].tableName),
                        selected: i == _selectedIndex,
                        onTap: () => _select(i),
                      ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: content),
            ],
          ),
        );
      },
    );
  }

  Widget _railItem(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        color: selected ? colorScheme.secondaryContainer : null,
        child: Column(
          children: [
            Icon(
              selected ? Icons.table_chart : Icons.table_chart_outlined,
              color: selected ? colorScheme.onSecondaryContainer : null,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: selected ? colorScheme.onSecondaryContainer : null,
              ),
            ),
          ],
        ),
      ),
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
