import 'dart:io';

import 'package:flutter/material.dart';

import '../db/file_sync_service.dart';
import 'table_icon.dart';

/// Renders a table's `icon` value (see `table_icon.dart`'s own doc
/// comment for the two shapes it can hold) -- a Material icon, a small
/// resolved custom image, or [fallback] when [icon] is `null`/unrecognized.
/// Used everywhere a table shows up in nav/lists (`HomeShell`'s rail/
/// drawer, `ManageTablesScreen`'s list) so every one of those sites stays
/// visually consistent without duplicating the icon/image dispatch logic.
class TableIconWidget extends StatefulWidget {
  const TableIconWidget({
    super.key,
    required this.icon,
    this.size = 24,
    this.color,
    this.fallback = Icons.table_chart_outlined,
  });

  final String? icon;
  final double size;
  final Color? color;

  /// Shown when [icon] is `null` or doesn't resolve to a real Material
  /// icon/image -- same default `HomeShell`'s rail/drawer already used
  /// for every table before this feature existed, so a table with no icon
  /// set renders exactly as it always has.
  final IconData fallback;

  @override
  State<TableIconWidget> createState() => _TableIconWidgetState();
}

class _TableIconWidgetState extends State<TableIconWidget> {
  final _fileSync = FileSyncService();
  Future<File?>? _imageFuture;
  String? _imageFutureKey;

  @override
  Widget build(BuildContext context) {
    final materialData = materialIconDataFor(widget.icon);
    if (materialData != null) {
      return Icon(materialData, size: widget.size, color: widget.color);
    }

    final imageKey = imageIconKeyFor(widget.icon);
    if (imageKey != null) {
      if (_imageFutureKey != imageKey) {
        _imageFutureKey = imageKey;
        _imageFuture = _fileSync.fetchByRelativeKey(imageKey);
      }
      return FutureBuilder<File?>(
        future: _imageFuture,
        builder: (context, snapshot) {
          final file = snapshot.data;
          if (file == null) {
            // Covers both "still loading" and "genuinely 404/unreachable"
            // -- same as GenericFormScreen's own image preview, a broken-
            // image placeholder is the right state for either, not an
            // error surfaced to the user (this is a small nav icon, not
            // the field itself).
            return SizedBox(
              width: widget.size,
              height: widget.size,
              child: Icon(Icons.broken_image_outlined, size: widget.size, color: widget.color),
            );
          }
          return ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Image.file(file, width: widget.size, height: widget.size, fit: BoxFit.cover),
          );
        },
      );
    }

    return Icon(widget.fallback, size: widget.size, color: widget.color);
  }
}
