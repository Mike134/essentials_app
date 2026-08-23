import 'package:flutter/material.dart';

import 'formula_expression.dart';
import 'formula_service.dart';

/// The `formula` format's authoring sub-form -- expression box with live
/// parse-error feedback, a result-type picker, and tappable chips for the
/// table's own field names (Essentials v2 Phase 2 build order step 6).
///
/// Shared between `AddFieldScreen` and `ManageFieldsScreen`'s field editor
/// dialog rather than duplicated, same reasoning as
/// `InlineOptionListEditor` (step 4): the trivial one-or-two-field
/// sub-forms in those screens stay duplicated per this project's existing
/// convention, but this one carries real behaviour -- live validation and
/// insert-at-cursor -- that isn't worth maintaining twice.
///
/// **Live validation is the point.** A formula that fails to parse yields
/// blank cells at read time and nothing else (see
/// `FormulaService.expressionFor`, which deliberately swallows the
/// error so one bad field can't take down a grid). Catching it here, as
/// the user types, is the only place a real error message can reach them.
///
/// Controlled, like `InlineOptionListEditor`: the parent owns
/// [expressionController] and [resultType] and reads both at submit time.
class FormulaFieldEditor extends StatefulWidget {
  const FormulaFieldEditor({
    super.key,
    required this.expressionController,
    required this.resultType,
    required this.onResultTypeChanged,
    required this.availableFields,
    this.onChanged,
  });

  final TextEditingController expressionController;

  /// [FormulaService.resultTypeNumber] or [FormulaService.resultTypeText].
  final String resultType;

  final ValueChanged<String> onResultTypeChanged;

  /// Field name -> display name for the table this field belongs to, in
  /// display order. Empty is fine (a brand-new table with no other fields
  /// yet); the chips section simply doesn't render.
  final Map<String, String> availableFields;

  /// Fires after every expression edit, so a parent whose submit gate
  /// depends on the expression being valid can rebuild.
  final VoidCallback? onChanged;

  @override
  State<FormulaFieldEditor> createState() => _FormulaFieldEditorState();
}

class _FormulaFieldEditorState extends State<FormulaFieldEditor> {
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.expressionController.addListener(_revalidate);
    _error = formulaErrorFor(widget.expressionController.text);
  }

  @override
  void dispose() {
    widget.expressionController.removeListener(_revalidate);
    super.dispose();
  }

  void _revalidate() {
    final error = formulaErrorFor(widget.expressionController.text);
    if (error != _error) setState(() => _error = error);
    widget.onChanged?.call();
  }

  /// Inserts [text] at the cursor (replacing any selection), rather than
  /// appending -- so building an expression by alternating between typing
  /// and tapping a field chip doesn't jump the caret to the end.
  void _insert(String text) {
    final controller = widget.expressionController;
    final value = controller.value;
    final selection = value.selection;
    if (!selection.isValid) {
      controller.text = value.text + text;
      return;
    }
    controller.value = value.copyWith(
      text: value.text.replaceRange(selection.start, selection.end, text),
      selection: TextSelection.collapsed(offset: selection.start + text.length),
      composing: TextRange.empty,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: widget.expressionController,
          maxLines: null,
          decoration: InputDecoration(
            labelText: 'Formula',
            hintText: '{cost} * {quantity}',
            errorText: _error,
            helperText: 'Functions: ${FormulaExpression.functionNames.join(', ')}',
            helperMaxLines: 2,
          ),
        ),
        if (widget.availableFields.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Insert a field', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final entry in widget.availableFields.entries)
                ActionChip(
                  label: Text(entry.value),
                  tooltip: '{${entry.key}}',
                  onPressed: () => _insert('{${entry.key}}'),
                ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: widget.resultType,
          decoration: const InputDecoration(labelText: 'Result'),
          items: const [
            DropdownMenuItem(value: FormulaService.resultTypeNumber, child: Text('Number')),
            DropdownMenuItem(value: FormulaService.resultTypeText, child: Text('Text')),
          ],
          onChanged: (value) {
            if (value != null) widget.onResultTypeChanged(value);
          },
        ),
      ],
    );
  }
}

/// The parse error for [source], or `null` if it parses (or is blank --
/// an empty box is "not filled in yet", which the submit gate reports,
/// not a syntax error to shout about while the user is still typing).
String? formulaErrorFor(String source) {
  if (source.trim().isEmpty) return null;
  try {
    FormulaExpression.parse(source);
    return null;
  } on FormulaParseException catch (e) {
    return e.message;
  }
}

/// Whether [source] is a complete, usable formula -- what both screens'
/// submit gates check.
bool isUsableFormula(String source) =>
    source.trim().isNotEmpty && FormulaExpression.tryParse(source) != null;
