import 'dart:async';

import 'package:flutter/material.dart';

import '../db/event_definitions_dao.dart';
import '../db/schema_metadata_dao.dart';
import '../db/script_definitions_dao.dart';
import '../db/sync_service.dart';

/// Essentials v2 Phase 5 build order step 5 -- per-table event bindings
/// (data events, form lifecycle, `field_changed`, `button_clicked`). See
/// claude/essentials-v2-phase5-design.md's "Event binding UI" -- one
/// screen for every per-table event type rather than splitting
/// `field_changed`/`button_clicked` out to `AddFieldScreen`/
/// `ManageFieldsScreen` as that doc's sketch floats, since both are
/// already just `event_definitions` rows with a `field_name` set --
/// exactly the same shape every other binding here already has, needing
/// no separate mechanism. Reached from Settings, alongside Manage
/// Tables/Manage Fields. Scheduled/`app_launch` bindings are a *separate*
/// screen ([ScheduledEventsScreen]), since they're not attached to any
/// one table's data -- see this file's own sibling.
class ManageEventsScreen extends StatefulWidget {
  const ManageEventsScreen({super.key});

  @override
  State<ManageEventsScreen> createState() => _ManageEventsScreenState();
}

class _ManageEventsScreenState extends State<ManageEventsScreen> {
  final _metadata = SchemaMetadataDao();
  final _events = EventDefinitionsDao();
  final _scripts = ScriptDefinitionsDao();

  late Future<List<TableDefinitionRow>> _tablesFuture;
  String? _selectedTable;
  List<EventDefinition> _bindings = const [];
  List<FieldDefinitionRow> _fields = const [];
  List<ScriptDefinition> _availableScripts = const [];
  bool _loadingBindings = false;

  /// Live-refresh subscription -- see `ScriptEditorScreen`'s own doc
  /// comment for the full "sync works, this screen's own reactivity
  /// doesn't" reasoning (already fixed there, extended here for the same
  /// gap). Refreshes the current table's bindings on an `event_definitions`
  /// change and the script picker's own list on a `script_definitions`
  /// change (e.g. a script renamed elsewhere would otherwise leave this
  /// screen's dropdown showing its old name until manually reopened).
  StreamSubscription<Set<String>>? _dataChangeSubscription;
  Timer? _dataChangeDebounce;

  @override
  void initState() {
    super.initState();
    _tablesFuture = _metadata.loadActiveTables();
    _availableScripts = const [];
    _scripts.loadAll().then((scripts) {
      if (mounted) setState(() => _availableScripts = scripts);
    });
    _dataChangeSubscription = SyncService.dataChanges.listen(_onDataChanged);
  }

  void _onDataChanged(Set<String> tables) {
    if (!tables.contains('event_definitions') && !tables.contains('script_definitions')) return;
    _dataChangeDebounce?.cancel();
    _dataChangeDebounce = Timer(const Duration(milliseconds: 500), () async {
      if (!mounted) return;
      if (tables.contains('script_definitions')) {
        final scripts = await _scripts.loadAll();
        if (mounted) setState(() => _availableScripts = scripts);
      }
      if (tables.contains('event_definitions') && mounted) {
        await _reloadBindings();
      }
    });
  }

  @override
  void dispose() {
    _dataChangeSubscription?.cancel();
    _dataChangeDebounce?.cancel();
    super.dispose();
  }

  Future<void> _selectTable(String? tableName) async {
    setState(() {
      _selectedTable = tableName;
      _bindings = const [];
      _fields = const [];
    });
    if (tableName == null) return;
    await _reloadBindings();
    final fields = await _metadata.loadFields(tableName, includeDeleted: false);
    if (mounted && _selectedTable == tableName) setState(() => _fields = fields);
  }

  Future<void> _reloadBindings() async {
    final tableName = _selectedTable;
    if (tableName == null) return;
    setState(() => _loadingBindings = true);
    final bindings = await _events.loadForTable(tableName);
    if (!mounted || _selectedTable != tableName) return;
    setState(() {
      _bindings = bindings;
      _loadingBindings = false;
    });
  }

  Future<void> _addBinding() async {
    final tableName = _selectedTable;
    if (tableName == null || _availableScripts.isEmpty) return;
    final result = await showDialog<_NewBindingResult>(
      context: context,
      builder: (context) => _NewBindingDialog(fields: _fields, scripts: _availableScripts),
    );
    if (result == null) return;
    await _events.create(
      scriptId: result.scriptId,
      eventType: result.eventType,
      tableName: tableName,
      fieldName: result.fieldName,
    );
    await _reloadBindings();
  }

  String _scriptNameFor(int scriptId) =>
      _availableScripts.firstWhere((s) => s.id == scriptId, orElse: () => ScriptDefinition(id: scriptId, name: '(deleted script)', code: '', description: null)).name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Events')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
        children: [
          const Text(
            'Runs a script when something happens to a table -- a record is '
            'created/saved/updated/deleted, a form opens/closes, a specific '
            'field changes, or a button field is tapped.',
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<TableDefinitionRow>>(
            future: _tablesFuture,
            builder: (context, snapshot) {
              final tables = snapshot.data ?? const [];
              return DropdownButtonFormField<String>(
                initialValue: _selectedTable,
                decoration: const InputDecoration(labelText: 'Table'),
                items: [
                  for (final t in tables) DropdownMenuItem(value: t.tableName, child: Text(t.displayName)),
                ],
                onChanged: _selectTable,
              );
            },
          ),
          const SizedBox(height: 16),
          if (_selectedTable != null) ...[
            if (_availableScripts.isEmpty)
              const Text('No scripts exist yet -- create one first, from Scripts in the nav.')
            else
              OutlinedButton.icon(
                onPressed: _addBinding,
                icon: const Icon(Icons.add),
                label: const Text('Add binding'),
              ),
            const SizedBox(height: 8),
            if (_loadingBindings)
              const Center(child: CircularProgressIndicator())
            else if (_bindings.isEmpty)
              const Text('No events bound to this table yet.')
            else
              for (final binding in _bindings)
                ListTile(
                  title: Text(_eventLabel(binding)),
                  subtitle: Text('Runs "${_scriptNameFor(binding.scriptId)}"'),
                  leading: Switch(
                    value: binding.enabled,
                    onChanged: (value) async {
                      await _events.setEnabled(binding.id, value);
                      await _reloadBindings();
                    },
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await _events.softDelete(binding.id);
                      await _reloadBindings();
                    },
                  ),
                ),
          ],
        ],
      ),
    );
  }

  String _eventLabel(EventDefinition binding) {
    final base = _eventTypeLabels[binding.eventType] ?? binding.eventType;
    if (binding.fieldName == null) return base;
    final field = _fields.where((f) => f.fieldName == binding.fieldName);
    final fieldLabel = field.isEmpty ? binding.fieldName! : field.first.displayName;
    return '$base ($fieldLabel)';
  }
}

const _eventTypeLabels = {
  'record_created': 'Record created',
  'record_saved': 'Record saved',
  'record_updated': 'Record updated',
  'record_deleted': 'Record deleted',
  'form_opened': 'Form opened',
  'form_closed': 'Form closed',
  'field_changed': 'Field changed',
  'button_clicked': 'Button clicked',
};

class _NewBindingResult {
  const _NewBindingResult({required this.eventType, required this.scriptId, this.fieldName});
  final String eventType;
  final int scriptId;
  final String? fieldName;
}

class _NewBindingDialog extends StatefulWidget {
  const _NewBindingDialog({required this.fields, required this.scripts});
  final List<FieldDefinitionRow> fields;
  final List<ScriptDefinition> scripts;

  @override
  State<_NewBindingDialog> createState() => _NewBindingDialogState();
}

class _NewBindingDialogState extends State<_NewBindingDialog> {
  String _eventType = dataEventTypes.first;
  String? _fieldName;
  int? _scriptId;

  bool get _needsField => fieldScopedEventTypes.contains(_eventType);

  List<FieldDefinitionRow> get _candidateFields =>
      _eventType == 'button_clicked' ? widget.fields.where((f) => f.format == 'button').toList() : widget.fields;

  bool get _canSubmit => _scriptId != null && (!_needsField || _fieldName != null);

  @override
  void initState() {
    super.initState();
    _scriptId = widget.scripts.first.id;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add event binding'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _eventType,
              decoration: const InputDecoration(labelText: 'Event'),
              items: [
                for (final type in [...dataEventTypes, ...uiEventTypes])
                  DropdownMenuItem(value: type, child: Text(_eventTypeLabels[type] ?? type)),
                const DropdownMenuItem(value: 'field_changed', child: Text('Field changed')),
              ],
              onChanged: (value) => setState(() {
                _eventType = value ?? dataEventTypes.first;
                _fieldName = null;
              }),
            ),
            if (_needsField) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _fieldName,
                decoration: const InputDecoration(labelText: 'Field'),
                items: [
                  for (final f in _candidateFields) DropdownMenuItem(value: f.fieldName, child: Text(f.displayName)),
                ],
                onChanged: (value) => setState(() => _fieldName = value),
              ),
              if (_candidateFields.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _eventType == 'button_clicked'
                        ? 'This table has no button field yet.'
                        : 'This table has no fields yet.',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _scriptId,
              decoration: const InputDecoration(labelText: 'Script'),
              items: [
                for (final s in widget.scripts) DropdownMenuItem(value: s.id, child: Text(s.name)),
              ],
              onChanged: (value) => setState(() => _scriptId = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _canSubmit
              ? () => Navigator.pop(
                  context,
                  _NewBindingResult(eventType: _eventType, scriptId: _scriptId!, fieldName: _fieldName),
                )
              : null,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
