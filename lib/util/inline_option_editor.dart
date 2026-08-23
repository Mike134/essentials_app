import 'package:flutter/material.dart';

import '../models/table_config.dart';

/// Repeatable key/label list editor for a `select` field's inline option
/// list (`options.mode == 'inline'` -- see
/// claude/essentials-v2-phase2-design.md's "Inline select" entry).
/// Shared between `AddFieldScreen` and `ManageFieldsScreen`'s field
/// editor dialog -- unlike the trivial one-or-two-field sub-forms those
/// two screens otherwise duplicate for `select`(linked)/`currency`/
/// `percentage` (this project's established convention for small
/// sub-forms), a full add/remove/reorder/edit list is enough surface
/// area that a shared widget is worth it instead of two copies of the
/// same drag-and-drop bookkeeping.
///
/// **Controlled, not self-contained**: [options] is the current list,
/// owned by the parent (which needs it at submit time to build
/// `options.options` JSON), and every change -- add, remove, reorder, or
/// editing a row's text -- calls [onChanged] with a complete new list.
/// The parent just holds whatever it's given; it never reaches into this
/// widget's own state.
class InlineOptionListEditor extends StatefulWidget {
  const InlineOptionListEditor({super.key, required this.options, required this.onChanged});

  final List<InlineOption> options;
  final ValueChanged<List<InlineOption>> onChanged;

  @override
  State<InlineOptionListEditor> createState() => _InlineOptionListEditorState();
}

/// A synthetic, purely-local row id -- stable across reorders/edits so
/// each row's [TextEditingController]s survive a rebuild without losing
/// cursor position, and so [ReorderableListView] has the unique [Key]
/// every child needs. Never part of the [InlineOption] data model itself
/// (that only ever has `key`/`label`).
class _Row {
  _Row(this.id, String key, String label)
    : keyController = TextEditingController(text: key),
      labelController = TextEditingController(text: label);

  final int id;
  final TextEditingController keyController;
  final TextEditingController labelController;

  void dispose() {
    keyController.dispose();
    labelController.dispose();
  }
}

class _InlineOptionListEditorState extends State<InlineOptionListEditor> {
  final List<_Row> _rows = [];
  int _nextId = 0;

  @override
  void initState() {
    super.initState();
    for (final option in widget.options) {
      _rows.add(_Row(_nextId++, option.key, option.label));
    }
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _notify() {
    widget.onChanged([
      for (final row in _rows)
        InlineOption(key: row.keyController.text.trim(), label: row.labelController.text.trim()),
    ]);
  }

  void _addRow() {
    setState(() => _rows.add(_Row(_nextId++, '', '')));
    _notify();
  }

  void _removeRow(int index) {
    setState(() => _rows.removeAt(index).dispose());
    _notify();
  }

  void _reorder(int oldIndex, int newIndex) {
    // onReorderItem (not the deprecated onReorder) already adjusts
    // newIndex for the removed item -- same convention already
    // established in ManageFieldsScreen's own field reorder.
    setState(() => _rows.insert(newIndex, _rows.removeAt(oldIndex)));
    _notify();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Options', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        if (_rows.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No options yet -- add at least one.'),
          )
        else
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            onReorderItem: _reorder,
            children: [
              for (var i = 0; i < _rows.length; i++)
                Padding(
                  key: ValueKey(_rows[i].id),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _rows[i].keyController,
                          decoration: const InputDecoration(labelText: 'Stored value'),
                          onChanged: (_) => _notify(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _rows[i].labelController,
                          decoration: const InputDecoration(labelText: 'Shown as'),
                          onChanged: (_) => _notify(),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        tooltip: 'Remove option',
                        onPressed: () => _removeRow(i),
                      ),
                      const Icon(Icons.drag_handle),
                    ],
                  ),
                ),
            ],
          ),
        TextButton.icon(onPressed: _addRow, icon: const Icon(Icons.add), label: const Text('Add option')),
      ],
    );
  }
}
