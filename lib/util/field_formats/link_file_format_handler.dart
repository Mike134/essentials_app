import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:trina_grid/trina_grid.dart';

import '../../models/table_config.dart';
import '../links.dart';
import 'field_format_handler.dart';

/// `link_file` -- Phase 2's first [FieldFormatHandler], deliberately
/// chosen to prove the pattern end to end first (build order step 1, see
/// claude/essentials-v2-phase2-design.md) because it's the lowest-risk
/// new format: `TEXT` storage identical to a plain text field, no new
/// package (`file_picker`/`url_launcher` are both already dependencies,
/// used elsewhere in this app for CSV export and `isLink` fields
/// respectively), no sync concern (a path/URL string the app doesn't own
/// or manage, contrast `attachment`, dropped from Phase 2 entirely).
/// `options` is always `{}` for this format -- nothing configurable yet.
class LinkFileFormatHandler implements FieldFormatHandler {
  const LinkFileFormatHandler();

  @override
  String get format => 'link_file';

  @override
  TrinaColumn buildGridColumn(FieldConfig field) {
    return TrinaColumn(
      title: field.label,
      field: field.column,
      type: TrinaColumnType.text(),
      width: 220,
      // Same "double-click still enters the normal text editor, the icon
      // is the only extra tap target" shape as the isLink renderer this
      // was modeled on (GenericListScreen._buildFieldColumn) -- typing/
      // pasting a path directly still works.
      renderer: (rendererContext) {
        if (rendererContext.row.type.isGroup) return const SizedBox.shrink();
        final value = rendererContext.cell.value as String?;
        if (value == null || value.isEmpty) return const SizedBox.shrink();
        return Row(
          children: [
            Expanded(
              child: Text(
                value,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.blue, decoration: TextDecoration.underline),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.file_open_outlined, size: 16),
              tooltip: 'Open file',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              visualDensity: VisualDensity.compact,
              onPressed: () => openFileLink(value),
            ),
          ],
        );
      },
    );
  }

  @override
  Object? cellValueFor(FieldConfig field, Object? raw) => raw?.toString() ?? '';

  @override
  String? valueForSave(FieldConfig field, Object? gridValue) {
    final text = (gridValue as String? ?? '').trim();
    return text.isEmpty ? null : text;
  }

  @override
  Widget buildFormField(BuildContext context, FieldConfig field, TextEditingController controller) {
    return TextFormField(
      controller: controller,
      maxLines: null,
      style: const TextStyle(color: Colors.blue, decoration: TextDecoration.underline),
      decoration: InputDecoration(
        labelText: field.label,
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.folder_open_outlined),
              tooltip: 'Browse...',
              onPressed: () async {
                final result = await FilePicker.pickFiles();
                final path = result?.files.single.path;
                if (path != null) controller.text = path;
              },
            ),
            IconButton(
              icon: const Icon(Icons.open_in_new),
              tooltip: 'Open file',
              onPressed: () => openFileLink(controller.text),
            ),
          ],
        ),
      ),
      validator: field.required
          ? (value) => (value == null || value.trim().isEmpty) ? '${field.label} is required' : null
          : null,
    );
  }
}
