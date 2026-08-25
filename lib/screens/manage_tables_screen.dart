import 'dart:convert';

import 'package:flutter/material.dart';

import '../db/schema_editor_service.dart';
import '../db/schema_metadata_dao.dart';
import '../db/schema_registry.dart';
import '../db/table_discovery_service.dart';
import '../models/table_config.dart';
import '../util/calendar_field.dart';
import '../util/permanent_delete_gate.dart';

/// Essentials v2 Phase 1's "Manage Tables" screen (build order step 8) --
/// the table-level counterpart to [ManageFieldsScreen], which already
/// covers stage-1 soft delete/restore for *fields*. Rename (`display_name`/
/// `description`) and stage-1 soft delete/restore for the table itself,
/// via [SchemaMetadataDao]. "Permanently delete" (build order step 9,
/// [SchemaEditorService.dropTable]) is real DDL through `migration_log` --
/// gated on [tombstoneLikelySynced] per
/// claude/essentials-v2-phase1-design.md's "Permanently delete gating
/// signal".
class ManageTablesScreen extends StatefulWidget {
  const ManageTablesScreen({super.key});

  @override
  State<ManageTablesScreen> createState() => _ManageTablesScreenState();
}

/// [SchemaMetadataDao.loadAllTables]'s soft-deleted rows, split into what's
/// actually shown -- see [_ManageTablesScreenState._loadTables]'s doc
/// comment for why this split exists.
class _TablesData {
  _TablesData({required this.active, required this.recoverableDeleted});

  final List<TableDefinitionRow> active;
  final List<TableDefinitionRow> recoverableDeleted;
}

class _ManageTablesScreenState extends State<ManageTablesScreen> {
  final _metadata = SchemaMetadataDao();
  final _editor = SchemaEditorService();
  final _discovery = TableDiscoveryService();
  late Future<_TablesData> _tablesFuture;
  bool _deletedExpanded = false;
  bool _dropping = false;

  @override
  void initState() {
    super.initState();
    _tablesFuture = _loadTables();
  }

  /// `table_definitions` rows never truly disappear once tombstoned --
  /// even [SchemaEditorService.dropTable] (stage 2) only ever tombstones
  /// the row again, same as stage 1, since there's no true hard-delete in
  /// this CRDT architecture (see CLAUDE.md's Essentials v2 Phase 1 -- Step
  /// 3 incident write-up for why that's a hard rule). A stage-2-dropped
  /// table's own physical table is genuinely gone, though -- "Restore"
  /// couldn't actually restore anything for it, there's no data left.
  /// Found live, real-device verification session: a full day of v2
  /// schema-engine testing had left 500+ soft-deleted `table_definitions`
  /// rows behind (harmless individually, but with zero way to tell which
  /// ones were real vs. permanently-gone test residue at a glance -- Mike
  /// couldn't find one genuinely recoverable table among hundreds of dead
  /// entries). Filters the "Deleted" section down to rows whose physical
  /// table still exists (`TableDiscoveryService.discoverTableNames`, the
  /// same purely-`sqlite_master`-based check `orphan_cleanup_service`
  /// already uses for exactly this "does this still physically exist"
  /// question) -- the only ones "Restore" can actually do anything useful
  /// for. A permanently-gone row is invisible everywhere now, not shown
  /// with a Restore button that would silently do nothing meaningful.
  Future<_TablesData> _loadTables() async {
    final rows = await _metadata.loadAllTables();
    final physicalTables = (await _discovery.discoverTableNames()).toSet();
    return _TablesData(
      active: [for (final t in rows) if (!t.isDeleted) t],
      recoverableDeleted: [
        for (final t in rows)
          if (t.isDeleted && physicalTables.contains(t.tableName)) t,
      ],
    );
  }

  void _reload() {
    // Block-bodied, not `() => _tablesFuture = _loadTables()` -- an arrow
    // closure whose body is that Future-returning assignment infers a
    // Future return type itself, which setState's own debug-mode runtime
    // check rejects ("setState() callback argument returned a Future") --
    // a real, latent instance of the same bug found live in
    // ListViewScreen (Essentials v2 Phase 3), fixed here too since it's
    // the identical landmine.
    setState(() {
      _tablesFuture = _loadTables();
    });
  }

  Future<void> _openEditor(TableDefinitionRow table) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _TableEditorDialog(metadata: _metadata, table: table),
    );
    if (saved == true) _reload();
  }

  Future<void> _softDelete(TableDefinitionRow table) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete table?'),
        content: Text(
          '"${table.displayName}" will disappear from the grid and form on '
          'every device. Nothing is lost -- the table and all its data '
          'stay exactly where they are, and this can be undone from the '
          'Deleted section below.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _metadata.softDeleteTable(table.tableName);
    _reload();
  }

  Future<void> _restore(TableDefinitionRow table) async {
    await _metadata.restoreTable(table.tableName);
    _reload();
  }

  Future<void> _permanentlyDelete(TableDefinitionRow table) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permanently delete table?'),
        content: Text(
          '"${table.displayName}" and every row in it will be gone -- on '
          'every device, forever. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Permanently delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _dropping = true);
    try {
      await _editor.dropTable(table.tableName);
      _reload();
    } catch (e) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("Couldn't permanently delete"),
            content: Text('$e'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _dropping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Tables')),
      body: FutureBuilder<_TablesData>(
        future: _tablesFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Failed to load: ${snapshot.error}'));
          }
          final data = snapshot.data;
          if (data == null) return const Center(child: CircularProgressIndicator());

          final active = data.active;
          final deleted = data.recoverableDeleted;

          return ListView(
            // Same system-nav-bar overlap fix as SettingsScreen -- see
            // that screen's own doc comment for why a plain
            // EdgeInsets.all(16) isn't enough.
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
            children: [
              if (active.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('No tables yet. Create one from "New table".'),
                )
              else
                for (final table in active)
                  ListTile(
                    title: Text(table.displayName),
                    subtitle: Text(table.description ?? table.tableName),
                    onTap: () => _openEditor(table),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Delete table',
                      onPressed: () => _softDelete(table),
                    ),
                  ),
              if (deleted.isNotEmpty) ...[
                const SizedBox(height: 8),
                ExpansionTile(
                  title: Text('Deleted (${deleted.length})'),
                  initiallyExpanded: _deletedExpanded,
                  onExpansionChanged: (v) => setState(() => _deletedExpanded = v),
                  children: [
                    for (final table in deleted)
                      ListTile(
                        title: Text(table.displayName),
                        subtitle: Text(table.description ?? table.tableName),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(onPressed: () => _restore(table), child: const Text('Restore')),
                            IconButton(
                              icon: const Icon(Icons.delete_forever),
                              tooltip:
                                  permanentDeleteDisabledReason(table.modified) ?? 'Permanently delete',
                              onPressed: _dropping || !tombstoneLikelySynced(table.modified)
                                  ? null
                                  : () => _permanentlyDelete(table),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _TableEditorDialog extends StatefulWidget {
  const _TableEditorDialog({required this.metadata, required this.table});

  final SchemaMetadataDao metadata;
  final TableDefinitionRow table;

  @override
  State<_TableEditorDialog> createState() => _TableEditorDialogState();
}

class _TableEditorDialogState extends State<_TableEditorDialog> {
  late final TextEditingController _displayNameController;
  late final TextEditingController _descriptionController;
  String? _error;
  bool _saving = false;

  /// Essentials v2 Phase 3 (Calendar) -- needs this table's real field list
  /// (to offer only date/dateTime fields) and isn't available from
  /// [TableDefinitionRow] alone, unlike `display_name`/`description`.
  late Future<TableConfig> _configFuture;
  bool _calendarRange = false;
  String? _calendarField;
  String? _calendarStartField;
  String? _calendarEndField;

  @override
  void initState() {
    super.initState();
    _displayNameController = TextEditingController(text: widget.table.displayName);
    _descriptionController = TextEditingController(text: widget.table.description ?? '');
    _configFuture = SchemaRegistry().buildConfig(widget.table.tableName);

    final parsed = CalendarFieldConfig.tryParse(widget.table.calendarField);
    if (parsed != null) {
      _calendarRange = parsed.isRange;
      _calendarField = parsed.field;
      _calendarStartField = parsed.startField;
      _calendarEndField = parsed.endField;
    }
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  bool get _canSave => _displayNameController.text.trim().isNotEmpty;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.metadata.updateTable(
        widget.table.tableName,
        displayName: _displayNameController.text,
        description: _descriptionController.text.trim().isEmpty ? null : _descriptionController.text.trim(),
      );

      // Only ever written when there's a real eligible field selected --
      // an unset/cleared choice just leaves calendar_field NULL, which
      // already means "default to the first date/dateTime field by
      // position" (see resolveCalendarField), so there's nothing to save
      // in that case.
      final config = await _configFuture;
      final eligible = {for (final f in eligibleCalendarFields(config)) f.column};
      final CalendarFieldConfig? toSave;
      if (_calendarRange && _calendarStartField != null && _calendarEndField != null) {
        toSave = CalendarFieldConfig.range(_calendarStartField!, _calendarEndField!);
      } else if (!_calendarRange && _calendarField != null && eligible.contains(_calendarField)) {
        toSave = CalendarFieldConfig.single(_calendarField!);
      } else {
        toSave = null;
      }
      await widget.metadata.updateCalendarField(
        widget.table.tableName,
        toSave == null ? null : jsonEncode(toSave.toJson()),
      );

      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = 'Failed: $e';
      });
    }
  }

  Widget _buildCalendarFieldSection(TableConfig config) {
    final eligible = eligibleCalendarFields(config);
    if (eligible.isEmpty) {
      // Eligibility, not an error state -- matches the Calendar view's own
      // "a table with no date/dateTime field simply never appears" posture
      // (see claude/essentials-v2-architecture.md's "Calendar view" entry).
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        const Divider(),
        const SizedBox(height: 4),
        Text('Calendar field', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(
          'Which field(s) place this table\'s records on the Calendar view. '
          'Defaults to "${eligible.first.label}" if never set.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Single date')),
            ButtonSegment(value: true, label: Text('Date range')),
          ],
          selected: {_calendarRange},
          onSelectionChanged: (s) => setState(() => _calendarRange = s.first),
        ),
        const SizedBox(height: 8),
        if (!_calendarRange)
          DropdownButtonFormField<String>(
            initialValue: eligible.any((f) => f.column == _calendarField) ? _calendarField : null,
            decoration: const InputDecoration(labelText: 'Date field'),
            items: [for (final f in eligible) DropdownMenuItem(value: f.column, child: Text(f.label))],
            onChanged: (v) => setState(() => _calendarField = v),
          )
        else ...[
          DropdownButtonFormField<String>(
            initialValue: eligible.any((f) => f.column == _calendarStartField) ? _calendarStartField : null,
            decoration: const InputDecoration(labelText: 'Start field'),
            items: [for (final f in eligible) DropdownMenuItem(value: f.column, child: Text(f.label))],
            onChanged: (v) => setState(() => _calendarStartField = v),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: eligible.any((f) => f.column == _calendarEndField) ? _calendarEndField : null,
            decoration: const InputDecoration(labelText: 'End field'),
            items: [for (final f in eligible) DropdownMenuItem(value: f.column, child: Text(f.label))],
            onChanged: (v) => setState(() => _calendarEndField = v),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Edit "${widget.table.displayName}"'),
      content: SizedBox(
        // Capped to the available screen width, not a fixed value -- same
        // overflow this project already found and fixed for the List/
        // Kanban config dialogs' own SegmentedButton on a narrow Android
        // screen (see ListViewScreen's `_ListViewConfigDialog`).
        width: (MediaQuery.of(context).size.width - 96).clamp(240.0, 420.0).toDouble(),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _displayNameController,
                decoration: const InputDecoration(labelText: 'Table name'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descriptionController,
                decoration: const InputDecoration(labelText: 'Description (optional)'),
              ),
              FutureBuilder<TableConfig>(
                future: _configFuture,
                builder: (context, snapshot) {
                  final config = snapshot.data;
                  return config == null ? const SizedBox.shrink() : _buildCalendarFieldSection(config);
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(
          onPressed: _canSave && !_saving ? _save : null,
          child: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }
}
