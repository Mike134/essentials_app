import 'package:flutter/material.dart';
import 'package:trina_grid/trina_grid.dart';

import '../../models/table_config.dart';
import 'field_format_handler.dart';

/// `currency` -- Essentials v2 Phase 2 build order step 2 (see
/// claude/essentials-v2-phase2-design.md's `currency` entry). Storage:
/// `TEXT` holding a plain decimal string (`"19.99"`), same as `real` --
/// never the symbol or thousands separators. `options`: `{symbol: string
/// (default '$'), decimals: int (default 2)}`.
///
/// Both `parseStoredValue`/`serializeForStorage` equivalents
/// (`cellValueFor`/`valueForSave`) are the identity/`toString()` this doc
/// comment predicted -- there's no unit conversion between the stored and
/// displayed number the way `percentage` needs (see that handler's doc
/// comment for the contrast), so unlike percentage this doesn't need a
/// wrapper widget around the shared controller for the form side either.
class CurrencyFormatHandler implements FieldFormatHandler {
  const CurrencyFormatHandler();

  @override
  String get format => 'currency';

  String _symbol(FieldConfig field) => (field.options['symbol'] as String?) ?? '\$';

  int _decimals(FieldConfig field) {
    final raw = field.options['decimals'];
    if (raw is int) return raw;
    return int.tryParse(raw?.toString() ?? '') ?? 2;
  }

  @override
  TrinaColumn buildGridColumn(FieldConfig field) {
    return TrinaColumn(
      title: field.label,
      field: field.column,
      // trina_grid's own built-in currency column type -- handles
      // symbol/decimal formatting and edit-time parsing (via the shared
      // TrinaColumnTypeWithNumberFormat mixin every number-family column
      // type uses) without this handler reimplementing either.
      type: TrinaColumnType.currency(symbol: _symbol(field), decimalDigits: _decimals(field)),
      width: 130,
      textAlign: TrinaColumnTextAlign.right,
    );
  }

  @override
  Object? cellValueFor(FieldConfig field, Object? raw) => raw;

  @override
  String? valueForSave(FieldConfig field, Object? gridValue) {
    // TrinaGrid hands back a real num here (via castValueByColumnType's
    // toNumber(applyFormat(value)) -- confirmed by reading
    // editing_state.dart), not the raw typed/formatted text -- same as
    // every other number-family column, currency included, no ÷100
    // conversion needed (that's percentage's own thing).
    if (gridValue == null) return null;
    if (gridValue is num) return gridValue.toString();
    final text = gridValue.toString().trim();
    return text.isEmpty ? null : text;
  }

  @override
  Widget buildFormField(BuildContext context, FieldConfig field, TextEditingController controller) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: field.label, prefixText: _symbol(field)),
      validator: field.required
          ? (value) => (value == null || value.trim().isEmpty) ? '${field.label} is required' : null
          : null,
    );
  }
}
