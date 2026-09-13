// Pure-function coverage for buttonLabelFor -- the one bit of real logic
// shared by GenericFormScreen's form button and GenericListScreen's grid
// button, both of which special-case `format == 'button'` themselves
// rather than going through ButtonFormatHandler's own (dead)
// buildFormField/buildGridColumn. No database involved.
import 'package:essentials_app/models/table_config.dart';
import 'package:essentials_app/util/field_formats/button_format_handler.dart';
import 'package:flutter_test/flutter_test.dart';

FieldConfig _buttonField({Map<String, Object?> options = const {}}) {
  return FieldConfig(
    column: 'next',
    label: 'Next',
    type: FieldType.text,
    format: 'button',
    options: options,
  );
}

void main() {
  test('buttonLabelFor falls back to "Run script" when no label option is set', () {
    expect(buttonLabelFor(_buttonField()), 'Run script');
  });

  test('buttonLabelFor uses the configured label, trimmed', () {
    expect(buttonLabelFor(_buttonField(options: {'label': '  Create Next Occurrence  '})), 'Create Next Occurrence');
  });

  test('buttonLabelFor falls back when the label option is blank or the wrong type', () {
    expect(buttonLabelFor(_buttonField(options: {'label': '   '})), 'Run script');
    expect(buttonLabelFor(_buttonField(options: {'label': 42})), 'Run script');
  });
}
