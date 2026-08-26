import 'dart:convert';

import 'table_config.dart' show InlineOption;
import 'template_field.dart';

/// A starter template shipped with the app -- compiled Dart data, never a
/// `template_definitions` row. Confirmed decision, per
/// claude/essentials-v2-phase7-design.md: identical on every install by
/// construction, versioned with the app itself, never edited by the user
/// (that's what "Save as Template" -- real `template_definitions` rows --
/// is for). Unified with saved templates only at the picker UI level (one
/// combined list, one instantiation flow), never at the storage level.
class BuiltinTemplate {
  const BuiltinTemplate({required this.displayName, required this.icon, required this.fields});

  final String displayName;
  final String icon;
  final List<TemplateField> fields;
}

String _inlineSelectOptions(List<(String key, String label)> options) => jsonEncode({
  'mode': 'inline',
  'options': [for (final (key, label) in options) InlineOption(key: key, label: label).toJson()],
});

const _colorFormat = 'text';
const _isColorOptions = '{"isColor":true}';

/// The seven confirmed starter templates (2026-08-25) -- see the design
/// doc's own catalog table. **Passwords deliberately left out** -- this
/// app has no field-level encryption (every value is physically plain
/// TEXT), and a built-in Passwords template would visually imply a
/// protection level that doesn't exist. Nothing stops Mike building his
/// own Passwords table by hand; this only affects the curated list.
final List<BuiltinTemplate> builtinTemplates = [
  BuiltinTemplate(
    displayName: 'Contacts',
    icon: 'contacts',
    fields: [
      const TemplateField(displayName: 'Name', format: 'text'),
      const TemplateField(displayName: 'Phone', format: 'text'),
      const TemplateField(displayName: 'Email', format: 'text'),
      const TemplateField(displayName: 'Address', format: 'text'),
      const TemplateField(displayName: 'Birthday', format: 'date'),
      const TemplateField(displayName: 'Notes', format: 'text'),
    ],
  ),
  BuiltinTemplate(
    displayName: 'Books',
    icon: 'book',
    fields: [
      const TemplateField(displayName: 'Title', format: 'text'),
      const TemplateField(displayName: 'Author', format: 'text'),
      const TemplateField(displayName: 'ISBN', format: 'barcode'),
      TemplateField(
        displayName: 'Genre',
        format: 'select',
        optionsJson: _inlineSelectOptions(const [
          ('fiction', 'Fiction'),
          ('non_fiction', 'Non-fiction'),
          ('biography', 'Biography'),
          ('sci_fi', 'Sci-Fi'),
          ('mystery', 'Mystery'),
          ('other', 'Other'),
        ]),
      ),
      const TemplateField(displayName: 'Rating', format: 'rating'),
      const TemplateField(displayName: 'Read', format: 'boolean'),
      const TemplateField(displayName: 'Notes', format: 'text'),
    ],
  ),
  BuiltinTemplate(
    displayName: 'Movies',
    icon: 'movie',
    fields: [
      const TemplateField(displayName: 'Title', format: 'text'),
      const TemplateField(displayName: 'Director', format: 'text'),
      const TemplateField(displayName: 'Year', format: 'integer'),
      TemplateField(
        displayName: 'Genre',
        format: 'select',
        optionsJson: _inlineSelectOptions(const [
          ('action', 'Action'),
          ('comedy', 'Comedy'),
          ('drama', 'Drama'),
          ('sci_fi', 'Sci-Fi'),
          ('horror', 'Horror'),
          ('documentary', 'Documentary'),
          ('other', 'Other'),
        ]),
      ),
      const TemplateField(displayName: 'Rating', format: 'rating'),
      const TemplateField(displayName: 'Watched', format: 'boolean'),
      const TemplateField(displayName: 'Notes', format: 'text'),
    ],
  ),
  BuiltinTemplate(
    displayName: 'Expenses',
    icon: 'receipt',
    fields: [
      const TemplateField(displayName: 'Description', format: 'text'),
      const TemplateField(displayName: 'Amount', format: 'currency'),
      const TemplateField(displayName: 'Date', format: 'date'),
      TemplateField(
        displayName: 'Category',
        format: 'select',
        optionsJson: _inlineSelectOptions(const [
          ('food', 'Food'),
          ('transport', 'Transport'),
          ('housing', 'Housing'),
          ('entertainment', 'Entertainment'),
          ('health', 'Health'),
          ('other', 'Other'),
        ]),
      ),
      const TemplateField(displayName: 'Paid', format: 'boolean'),
    ],
  ),
  BuiltinTemplate(
    displayName: 'Subscriptions',
    icon: 'subscriptions',
    fields: [
      const TemplateField(displayName: 'Name', format: 'text'),
      const TemplateField(displayName: 'Cost', format: 'currency'),
      TemplateField(
        displayName: 'Renewal Period',
        format: 'select',
        optionsJson: _inlineSelectOptions(const [
          ('weekly', 'Weekly'),
          ('monthly', 'Monthly'),
          ('yearly', 'Yearly'),
        ]),
      ),
      const TemplateField(displayName: 'Next Renewal', format: 'date'),
      const TemplateField(displayName: 'Color', format: _colorFormat, optionsJson: _isColorOptions),
    ],
  ),
  BuiltinTemplate(
    displayName: 'Journal',
    icon: 'edit_note',
    fields: [
      const TemplateField(displayName: 'Date', format: 'date'),
      const TemplateField(displayName: 'Title', format: 'text'),
      const TemplateField(displayName: 'Entry', format: 'text'),
      TemplateField(
        displayName: 'Mood',
        format: 'select',
        optionsJson: _inlineSelectOptions(const [
          ('great', 'Great'),
          ('good', 'Good'),
          ('okay', 'Okay'),
          ('bad', 'Bad'),
          ('terrible', 'Terrible'),
        ]),
      ),
    ],
  ),
  BuiltinTemplate(
    displayName: 'Household Inventory',
    icon: 'inventory_2',
    fields: [
      const TemplateField(displayName: 'Item', format: 'text'),
      const TemplateField(displayName: 'Location', format: 'text'),
      const TemplateField(displayName: 'Quantity', format: 'integer'),
      const TemplateField(displayName: 'Value', format: 'currency'),
      const TemplateField(displayName: 'Barcode', format: 'barcode'),
    ],
  ),
];
