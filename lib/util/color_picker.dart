import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

/// Shows a popup color picker seeded at [initial] (white if null),
/// returning the chosen [Color] on "Select", or null if cancelled. See
/// CLAUDE.md "Real-usage findings" Step 6 -- values stay stored as hex
/// strings wherever they already were; this only replaces typing one by
/// hand.
Future<Color?> pickColor(BuildContext context, {Color? initial}) {
  var current = initial ?? Colors.white;
  return showDialog<Color>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Pick a color'),
      content: SingleChildScrollView(
        child: ColorPicker(
          pickerColor: current,
          onColorChanged: (color) => current = color,
          enableAlpha: false,
          hexInputBar: true,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, current),
          child: const Text('Select'),
        ),
      ],
    ),
  );
}
