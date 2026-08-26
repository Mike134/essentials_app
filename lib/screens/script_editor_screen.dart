import 'package:flutter/material.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';
import 'package:highlight/languages/javascript.dart';

import '../db/script_definitions_dao.dart';

/// Essentials v2 Phase 5 build order step 5 -- the script list, reached
/// via a new nav rail/drawer entry (same pattern as Search, Phase 6). See
/// claude/essentials-v2-phase5-design.md's "Script editor UI".
class ScriptEditorScreen extends StatefulWidget {
  const ScriptEditorScreen({super.key});

  @override
  State<ScriptEditorScreen> createState() => _ScriptEditorScreenState();
}

class _ScriptEditorScreenState extends State<ScriptEditorScreen> {
  final _dao = ScriptDefinitionsDao();
  late Future<List<ScriptDefinition>> _scriptsFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() => _scriptsFuture = _dao.loadAll());
  }

  Future<void> _openEditor({ScriptDefinition? existing}) async {
    final changed = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => ScriptEditScreen(existing: existing)));
    if (changed == true) _reload();
  }

  Future<void> _delete(ScriptDefinition script) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete script?'),
        content: Text(
          'Delete "${script.name}"? Any event still bound to it will simply '
          'find no script to run -- this does not delete the event binding '
          'itself.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _dao.softDelete(script.id);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scripts')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(),
        child: const Icon(Icons.add),
      ),
      body: FutureBuilder<List<ScriptDefinition>>(
        future: _scriptsFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text('Error: ${snapshot.error}'));
          final scripts = snapshot.data;
          if (scripts == null) return const Center(child: CircularProgressIndicator());
          if (scripts.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No scripts yet. Tap + to write your first one.'),
              ),
            );
          }
          return ListView(
            padding: EdgeInsets.fromLTRB(0, 0, 0, MediaQuery.paddingOf(context).bottom),
            children: [
              for (final script in scripts)
                ListTile(
                  title: Text(script.name),
                  subtitle: script.description == null || script.description!.isEmpty
                      ? null
                      : Text(script.description!, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => _openEditor(existing: script),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(script),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The full-screen code editor for one script -- create (no [existing]) or
/// edit. `flutter_code_editor`'s `CodeController`/`CodeField` give real JS
/// syntax highlighting (see pubspec.yaml's own comment for the package
/// choice) -- `CodeController` extends `TextEditingController` directly,
/// so `.text`/`.fullText` at save time is exactly what a plain
/// `TextEditingController` would give.
class ScriptEditScreen extends StatefulWidget {
  const ScriptEditScreen({super.key, this.existing});

  final ScriptDefinition? existing;

  bool get isEditing => existing != null;

  @override
  State<ScriptEditScreen> createState() => _ScriptEditScreenState();
}

class _ScriptEditScreenState extends State<ScriptEditScreen> {
  final _dao = ScriptDefinitionsDao();
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final CodeController _codeController;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    _descriptionController = TextEditingController(text: widget.existing?.description ?? '');
    _codeController = CodeController(text: widget.existing?.code ?? '', language: javascript);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'A script needs a name.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final description = _descriptionController.text.trim();
    final code = _codeController.fullText;

    try {
      if (widget.isEditing) {
        await _dao.update(
          widget.existing!.id,
          name: name,
          code: code,
          description: description.isEmpty ? null : description,
        );
      } else {
        await _dao.create(name: name, code: code, description: description.isEmpty ? null : description);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = 'Failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Edit Script' : 'New Script'),
        actions: [
          IconButton(
            icon: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check),
            onPressed: _saving ? null : _save,
            tooltip: 'Save',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _descriptionController,
                  decoration: const InputDecoration(labelText: 'Description (optional)'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(0, 0, 0, MediaQuery.paddingOf(context).bottom),
              // A real CodeTheme is required, not optional -- the first
              // version of this screen never supplied one at all, which
              // left every token the same plain text color (no syntax
              // highlighting, the whole point of choosing this package)
              // and, worse, is also why selected text was hard to make
              // out live: with no theme, this package's fallback text/
              // selection colors don't contrast reliably against each
              // other. `textSelectionTheme` is set explicitly here too,
              // rather than trusting whatever ambient Theme.of(context)
              // supplies -- this editor's own background is always dark
              // (monokaiSublimeTheme), independent of the app's own
              // light/dark setting, so the selection color needs to be
              // chosen against *that* background specifically, not the
              // app theme's.
              child: CodeTheme(
                data: CodeThemeData(styles: monokaiSublimeTheme),
                child: Theme(
                  data: Theme.of(context).copyWith(
                    textSelectionTheme: const TextSelectionThemeData(
                      selectionColor: Color(0xB3FFC107),
                      cursorColor: Color(0xFFFFC107),
                    ),
                  ),
                  child: CodeField(
                    controller: _codeController,
                    background: const Color(0xFF23241F),
                    textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    minLines: 20,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
