import 'package:flutter/material.dart';

import '../db/migration_dao.dart';

/// Past migrations, so submission isn't happening blind. Tapping one shows
/// its full SQL and jumps straight to its per-device status.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.onShowStatus});

  final void Function(int migrationId) onShowStatus;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _dao = MigrationDao();
  late Future<List<MigrationLogEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _dao.history();
  }

  Future<void> _refresh() async {
    setState(() => _future = _dao.history());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<MigrationLogEntry>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Failed to load history: ${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final entries = snapshot.data!;
        if (entries.isEmpty) {
          return const Center(child: Text('No migrations submitted yet.'));
        }
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = entries[index];
              return ListTile(
                title: Text('#${entry.id} -- ${entry.description ?? '(no description)'}'),
                subtitle: Text(entry.createdAt),
                onTap: () => _showDetail(context, entry),
              );
            },
          ),
        );
      },
    );
  }

  void _showDetail(BuildContext context, MigrationLogEntry entry) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('#${entry.id} -- ${entry.description ?? '(no description)'}'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: SelectableText(entry.sqlText, style: const TextStyle(fontFamily: 'monospace')),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onShowStatus(entry.id);
            },
            child: const Text('View status'),
          ),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        ],
      ),
    );
  }
}
