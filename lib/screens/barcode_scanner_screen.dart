import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Full-screen camera scanner, pushed by [BarcodeFormatHandler]'s scan
/// button -- Essentials v2 Phase 2 build order step 7. Android-only in
/// practice (nothing ever pushes this route on another platform, see
/// that handler's own doc comment), but nothing here is Android-specific
/// itself; `mobile_scanner` simply has no implementation to back it on
/// Windows.
///
/// Pops with the scanned code's `rawValue` on the first successful
/// detection, or `null` if the user backs out -- the caller (the scan
/// button's own `TextEditingController`) decides what to do with either.
/// No manual-entry fallback here: backing out returns to the underlying
/// text field, which is already directly editable by keyboard.
class BarcodeScannerScreen extends StatefulWidget {
  const BarcodeScannerScreen({super.key});

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> {
  // MobileScanner keeps calling onDetect for every frame with a
  // recognizable code in it -- guards against popping twice (the second
  // pop would close whatever screen was underneath this one instead).
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled || capture.barcodes.isEmpty) return;
    final value = capture.barcodes.first.rawValue;
    if (value == null || value.isEmpty) return;
    _handled = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Barcode')),
      body: MobileScanner(onDetect: _onDetect),
    );
  }
}
