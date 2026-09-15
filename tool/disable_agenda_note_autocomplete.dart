// ignore_for_file: avoid_print
// One-off metadata fix, 2026-09-15: the "Agenda" table's "Note" field
// (physical column `note`, plain text) was created with no `options` at
// all, so `FieldConfig.isAutocompleteText`'s default (absent means "on")
// left it going through `GenericFormScreen._buildAutocompleteField`, which
// deliberately hardcodes `maxLines: 1` -- keyboard highlight-navigation of
// the suggestion list needs a single-line field (see column-autocomplete
// design). Mike's ask: Note should be a real multi-line notes field, not a
// one-line autocomplete box. Turning autocomplete off restores the plain
// `maxLines: null` auto-grow path every other text field already uses --
// same fix already applied once before for "Map Location" (see
// `GenericFormScreen._buildField`'s own `field != _mapLocationField &&
// field.isAutocompleteText` exemption), just via the field's own
// `options.autocomplete` setting this time (the mechanism the app's own
// Manage Fields screen already exposes for exactly this) instead of a
// hardcoded field-name exemption.
//
// Plain metadata edit through SchemaMetadataDao.updateField -- no DDL, no
// migration_log entry, syncs like any other row write.
//
// Run via `flutter test tool/disable_agenda_note_autocomplete.dart` -- NOT
// `dart run` (SchemaMetadataDao pulls in Flutter via table_config.dart; see
// CLAUDE.md "Essentials v2 Phase 1 -- Step 5"). "No tests ran" afterward is
// expected, not a failure.
import 'dart:convert';

import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';

const tableName = 'agenda';
const fieldName = 'note';

Future<void> main() async {
  final metadata = SchemaMetadataDao();

  final fields = await metadata.loadFields(tableName, includeDeleted: false);
  final note = fields.where((f) => f.fieldName == fieldName).toList();
  if (note.isEmpty) {
    print('No "$fieldName" field found on "$tableName" -- nothing to do.');
    await DatabaseHelper.instance.close();
    return;
  }
  final field = note.single;

  final options = field.optionsJson == null
      ? <String, Object?>{}
      : (jsonDecode(field.optionsJson!) as Map<String, Object?>);
  if (options['autocomplete'] == false) {
    print('Autocomplete is already off for "$tableName.$fieldName" -- nothing to do.');
    await DatabaseHelper.instance.close();
    return;
  }
  options['autocomplete'] = false;

  print('Turning off autocomplete for "$tableName.$fieldName" (was: ${field.optionsJson})...');
  await metadata.updateField(
    tableName,
    fieldName,
    displayName: field.displayName,
    format: field.format,
    optionsJson: jsonEncode(options),
    defaultValue: field.defaultValue,
    isRequired: field.required,
  );

  print('Done. "Note" is now a plain multi-line field. Relaunch essentials_app to pick it up.');
  await DatabaseHelper.instance.close();
}
