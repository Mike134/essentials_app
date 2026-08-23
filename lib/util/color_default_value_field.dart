import 'package:flutter/material.dart';

import '../theme/theme_controller.dart';
import 'color_picker.dart';

/// Default-value entry for a [FieldFormatChoice.color] field, used by both
/// [AddFieldScreen] and [ManageFieldsScreen]'s field editor -- same
/// "shared, not duplicated" call as [InlineOptionListEditor] for real
/// interactive UI, not just a sub-form's static layout. Mirrors
/// [GenericFormScreen]'s own `isColor` field exactly (live swatch prefix +
/// palette-icon popup picker, [pickColor]/[ThemeController.parseHexColor]/
/// [ThemeController.colorToHex]) -- a plain hex-typing box was the gap
/// Mike explicitly flagged when `color` became a pickable format: every
/// other place a color value is entered already gets the popup picker,
/// this is the one that didn't.
class ColorDefaultValueField extends StatelessWidget {
  const ColorDefaultValueField({
    super.key,
    required this.controller,
    required this.labelText,
    this.onChanged,
  });

  final TextEditingController controller;
  final String labelText;

  /// Fires after a pick (in addition to a plain typed edit, via the normal
  /// [TextField.onChanged]) -- callers use this to re-evaluate their own
  /// submit-button gating (e.g. "required needs a non-empty default"),
  /// same reasoning [InlineOptionListEditor.onChanged] already has.
  final VoidCallback? onChanged;

  Future<void> _pick(BuildContext context) async {
    final current = ThemeController.parseHexColor(controller.text) ?? Colors.white;
    final picked = await pickColor(context, initial: current);
    if (picked == null) return;
    controller.text = ThemeController.colorToHex(picked);
    onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: labelText,
        prefixIcon: Padding(
          padding: const EdgeInsets.all(12),
          // Listens to controller directly, not a parent setState -- a
          // typed hex edit and a picked color both notify it the same way,
          // so the swatch stays live either way with no extra plumbing.
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: ThemeController.parseHexColor(controller.text),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.grey),
              ),
            ),
          ),
        ),
        suffixIcon: IconButton(
          icon: const Icon(Icons.palette_outlined),
          tooltip: 'Pick a color',
          onPressed: () => _pick(context),
        ),
      ),
      onChanged: (_) => onChanged?.call(),
    );
  }
}
