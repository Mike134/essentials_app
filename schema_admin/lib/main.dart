import 'package:flutter/material.dart';

import 'screens/history_screen.dart';
import 'screens/status_screen.dart';
import 'screens/submission_screen.dart';

void main() {
  runApp(const SchemaAdminApp());
}

/// A lean migration authoring tool for `essentials_app`'s schema --
/// deliberately not a Letos replacement (no views/triggers, no general
/// data browsing/editing). Runs only on MIKE-CU, writing `migration_log`
/// rows straight into the server's `hub.db` -- see CLAUDE.md "schema_admin
/// -- migration authoring tool" and `lib/db/database_helper.dart`.
class SchemaAdminApp extends StatelessWidget {
  const SchemaAdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'schema_admin',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
      home: const _HomeShell(),
    );
  }
}

class _HomeShell extends StatefulWidget {
  const _HomeShell();

  @override
  State<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<_HomeShell> with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(length: 3, vsync: this);
  int? _statusFocusId;

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _goToStatus(int migrationId) {
    setState(() => _statusFocusId = migrationId);
    _tabController.animateTo(2);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('schema_admin'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.upload_file), text: 'Submit'),
            Tab(icon: Icon(Icons.history), text: 'History'),
            Tab(icon: Icon(Icons.fact_check), text: 'Status'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          const SubmissionScreen(),
          HistoryScreen(onShowStatus: _goToStatus),
          StatusScreen(key: ValueKey(_statusFocusId), focusMigrationId: _statusFocusId),
        ],
      ),
    );
  }
}
