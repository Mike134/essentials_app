import 'package:flutter/material.dart';

import '../db/generic_dao.dart';
import '../models/table_config.dart';
import '../util/strings.dart';
import 'generic_form_screen.dart';

/// List view for a single table, driven entirely by [config]. Add/edit
/// opens [GenericFormScreen]; delete is RESTRICT-aware -- a row still
/// referenced elsewhere shows a snackbar instead of crashing.
class GenericListScreen extends StatefulWidget {
  const GenericListScreen({super.key, required this.config, this.drawer});

  final TableConfig config;

  /// Forwarded straight into this screen's own [Scaffold] -- lets the
  /// responsive nav shell attach the app's navigation [Drawer] on narrow
  /// (Android) layouts without this screen knowing about app-level nav.
  final Widget? drawer;

  @override
  State<GenericListScreen> createState() => _GenericListScreenState();
}

class _GenericListScreenState extends State<GenericListScreen> {
  late final GenericDao _dao;
  late Future<List<Map<String, Object?>>> _rowsFuture;

  @override
  void initState() {
    super.initState();
    _dao = GenericDao(widget.config);
    _reload();
  }

  @override
  void didUpdateWidget(covariant GenericListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config.tableName != widget.config.tableName) {
      _dao = GenericDao(widget.config);
      _reload();
    }
  }

  void _reload() {
    setState(() {
      _rowsFuture = _dao.getAll();
    });
  }

  Future<void> _openForm({Map<String, Object?>? row}) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => GenericFormScreen(config: widget.config, existing: row),
      ),
    );
    if (changed == true) _reload();
  }

  Future<void> _delete(Map<String, Object?> row) async {
    final label = '${row[widget.config.displayColumn] ?? ''}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete record?'),
        content: Text('Delete "$label"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _dao.delete(row['id'] as int);
      _reload();
    } on StillInUseException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(titleCase(widget.config.tableName))),
      drawer: widget.drawer,
      body: FutureBuilder<List<Map<String, Object?>>>(
        future: _rowsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          final rows = snapshot.data ?? const [];
          if (rows.isEmpty) {
            return const Center(child: Text('No records yet.'));
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final row = rows[index];
              return ListTile(
                title: Text('${row[widget.config.displayColumn] ?? ''}'),
                onTap: () => _openForm(row: row),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(row),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openForm(),
        tooltip: 'Add',
        child: const Icon(Icons.add),
      ),
    );
  }
}
