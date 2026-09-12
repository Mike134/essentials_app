// ignore_for_file: avoid_print
// Essentials v2 Agenda scheduling (see
// claude/essentials-v2-agenda-scheduling-design.md) -- real schema changes
// to the live "agenda" table, through the real app-facing
// SchemaEditorService/SchemaMetadataDao, not raw SQL:
//
//   1. Renames the existing "Period" field to "When" (same physical
//      column, `period` -- physical identifiers are immutable in this
//      app's architecture; only display_name changes). This field was
//      always meant to be "When" (Mike's own words: "I had renamed the
//      When field to Period" -- a naming mistake, not a real 'Period'
//      concept), and its contextual weekday/monthly-pattern UI is keyed
//      off the display label "When", not the physical column name.
//   2. Adds "Notify" (boolean, default off) -- real recurring
//      notifications only ever fire for a row where this is on.
//   3. Adds "Remind (Minutes Before)" (integer, default 0 -- fire exactly
//      at the computed occurrence unless overridden per row).
//
// Run via `flutter test tool/add_agenda_scheduling_fields.dart` -- a plain
// `dart run` can't compile anything that transitively imports Flutter
// (SchemaEditorService -> TableDiscoveryService -> table_config.dart),
// same reason every other schema-engine tool script in this project uses
// `flutter test` instead (see tool/create_checkpoint_table.dart's own
// history in CLAUDE.md, Essentials v2 Phase 1 Step 5).
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';

const tableName = 'agenda';

Future<void> main() async {
  final editor = SchemaEditorService();
  final metadata = SchemaMetadataDao();

  print('Renaming "Period" -> "When" on "$tableName"...');
  await metadata.updateField(
    tableName,
    'period',
    displayName: 'When',
    format: 'text',
    optionsJson: null,
    defaultValue: null,
    isRequired: false,
  );

  print('Adding "Notify" (boolean, default off)...');
  await editor.addField(
    tableName: tableName,
    displayName: 'Notify',
    format: 'boolean',
    defaultValue: '0',
  );

  print('Adding "Remind (Minutes Before)" (integer, default 0)...');
  await editor.addField(
    tableName: tableName,
    displayName: 'Remind (Minutes Before)',
    format: 'integer',
    defaultValue: '0',
  );

  print('');
  print('Done. Relaunch essentials_app to see the changes.');
  await DatabaseHelper.instance.close();
}
