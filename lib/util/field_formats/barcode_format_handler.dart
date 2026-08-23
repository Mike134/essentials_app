import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:trina_grid/trina_grid.dart';

import '../../models/table_config.dart';
import '../../screens/barcode_scanner_screen.dart';
import 'field_format_handler.dart';

/// `barcode` -- Essentials v2 Phase 2 build order step 7, the last of the
/// design doc's format catalog. Storage: plain `TEXT`, no `options` --
/// exactly like any text field. The format only changes the *input
/// method*, not what's stored: a camera-scan button on Android, nothing
/// extra on Windows (there's no less-capable substitute offered there --
/// per the design doc, "text (Windows)" already means the field's own
/// keyboard input, which every text-backed field already has for free).
///
/// ## Package choice -- spiked before writing this file, not guessed
///
/// `mobile_scanner: ^7.4.0` (see pubspec.yaml's own comment). Checked
/// against the design doc's two stated risks:
///
/// 1. **Google Play Services dependency** -- the package offers a
///    "bundled" mode (MLKit compiled directly into the app, the default)
///    and an "unbundled" mode (downloaded via Play Services on first use,
///    smaller APK). This project stays on the bundled default
///    specifically to avoid the Play Services assumption the design doc
///    flagged -- never opt into `useUnbundled=true`.
/// 2. **Windows must degrade cleanly, not break the build** -- confirmed
///    directly, not assumed: `flutter pub get` then `flutter build
///    windows` both succeeded with this dependency present. Flutter's
///    federated plugin architecture means a platform with no
///    implementation is simply absent from the generated plugin
///    registrant, not a build error -- Windows-side code here never
///    references `mobile_scanner` at all (see [buildFormField]'s
///    `Platform.isAndroid` gate), so there's nothing to fail even if it
///    tried to.
///
/// **One real caveat found by the spike, accepted, worth tracking:**
/// `flutter build apk` prints a real (non-fatal, today) warning --
/// `mobile_scanner` applies Kotlin Gradle Plugin (KGP) directly rather
/// than through Flutter's newer built-in-Kotlin support, and a future
/// Flutter release will turn this into a hard build failure. Same
/// category of dependency risk this project already lived through once
/// (`pubspec.yaml`'s `file_picker` comment, forced onto a beta by an
/// AGP9/KGP incompatibility) -- not a blocker today, but revisit if a
/// future `flutter upgrade` starts failing the Android build citing this.
class BarcodeFormatHandler implements FieldFormatHandler {
  const BarcodeFormatHandler();

  @override
  String get format => 'barcode';

  @override
  TrinaColumn buildGridColumn(FieldConfig field) {
    // Plain text column -- scanning is a form-only convenience (see the
    // doc comment above); the grid displays/edits a barcode value exactly
    // like any other text field. Routed through this handler anyway
    // (rather than left to the FieldType.text fallback every unrecognized
    // format already gets) purely so buildFormField below has a hook to
    // add the scan button -- once any handler is registered for a
    // format, it owns every render site for that field, grid included.
    return TrinaColumn(title: field.label, field: field.column, type: TrinaColumnType.text(), width: 200);
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
      decoration: InputDecoration(
        labelText: field.label,
        // Android only -- no disabled/greyed-out icon on Windows, no
        // icon at all. A visible-but-broken control would be the
        // opposite of "degrades cleanly" the design doc asked for; the
        // field is still a completely normal, directly-typable text
        // field there either way.
        suffixIcon: Platform.isAndroid
            ? IconButton(
                icon: const Icon(Icons.qr_code_scanner),
                tooltip: 'Scan barcode',
                onPressed: () => _scan(context, controller),
              )
            : null,
      ),
      validator: field.required
          ? (value) => (value == null || value.trim().isEmpty) ? '${field.label} is required' : null
          : null,
    );
  }

  Future<void> _scan(BuildContext context, TextEditingController controller) async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Camera permission is needed to scan a barcode.')));
      }
      return;
    }
    if (!context.mounted) return;
    final result = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const BarcodeScannerScreen()));
    if (result != null) controller.text = result;
  }
}
