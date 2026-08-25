// ignore_for_file: avoid_print
// Essentials v2 Phase 3, Step 5 (Calendar) -- creates a real throwaway table
// through the actual app-facing SchemaEditorService/GenericDao (not raw
// SQL), with fields and rows shaped to exercise every corner of the
// Calendar view: single-date entries, multi-day range entries (rendered as
// a chip on every day they cover), a colored entry (from the table's own
// `color` field), an uncolored entry (default chip styling), a blank-date
// row (must simply not appear -- no error state), and an entry a month out
// (for testing Month-view navigation). The table's `calendar_field` is set
// to *range* mode (Start Date/End Date) since that's the less-visited path
// -- "Due Date" is left as a second, unused-by-default date field so you
// can switch the table to single-date mode via Manage Tables and see the
// same rows re-render.
//
//   flutter test tool/create_calendar_test_table.dart
//
// (Not `dart run` -- SchemaEditorService transitively imports
// `package:flutter/widgets.dart` via TableConfig, which crashes the vanilla
// Dart SDK's compiler; `flutter test` on a bare `main()` with no `test()`
// calls runs it to completion fine -- see CLAUDE.md "Essentials v2 Phase 1
// -- Step 5" for the same gotcha hit there first.)
//
// Paired with tool/remove_calendar_test_table.dart once Mike's done testing.
import 'dart:convert';

import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_metadata_dao.dart';
import 'package:essentials_app/db/schema_registry.dart';
import 'package:essentials_app/util/date_format.dart';

const displayName = 'Calendar Test';

Future<void> main() async {
  final editor = SchemaEditorService();
  final registry = SchemaRegistry();
  final metadata = SchemaMetadataDao();

  print('Creating "$displayName"...');
  final tableName = await editor.createTable(
    displayName: displayName,
    description: 'Essentials v2 Phase 3 Step 5 (Calendar) test data. Safe to '
        'delete once confirmed on both platforms -- see '
        'tool/remove_calendar_test_table.dart.',
  );
  print('  table_name: $tableName');

  print('Adding "Title" (text, primary field)...');
  await editor.addField(tableName: tableName, displayName: 'Title', format: 'text');

  print('Adding "Status" (inline select, just for variety)...');
  await editor.addField(
    tableName: tableName,
    displayName: 'Status',
    format: 'select',
    optionsJson:
        '{"mode": "inline", "options": '
        '[{"key": "planned", "label": "Planned"}, '
        '{"key": "confirmed", "label": "Confirmed"}]}',
  );

  print('Adding "Color" (color field -- drives entry chip color)...');
  await editor.addField(
    tableName: tableName,
    displayName: 'Color',
    format: 'text',
    optionsJson: '{"isColor": true}',
  );

  print('Adding "Due Date" (single date, unused by default -- for switching modes)...');
  await editor.addField(tableName: tableName, displayName: 'Due Date', format: 'date');

  print('Adding "Start Date" / "End Date" (range fields, the default calendar_field)...');
  await editor.addField(tableName: tableName, displayName: 'Start Date', format: 'date');
  await editor.addField(tableName: tableName, displayName: 'End Date', format: 'date');

  final config = await registry.buildConfig(tableName);
  final dao = GenericDao(config);

  final today = DateTime.now();
  DateTime d(int offsetDays) => today.add(Duration(days: offsetDays));

  print('Inserting test rows...');
  final rows = <Map<String, Object?>>[
    {
      'title': 'Single day -- today',
      'status': 'confirmed',
      'color': '#1E88E5',
      'due_date': isoDate(d(0)),
      'start_date': isoDate(d(0)),
      'end_date': isoDate(d(0)),
    },
    {
      'title': 'Single day -- yesterday',
      'status': 'confirmed',
      'color': null, // deliberately uncolored -- default chip styling
      'due_date': isoDate(d(-1)),
      'start_date': isoDate(d(-1)),
      'end_date': isoDate(d(-1)),
    },
    {
      'title': 'Single day -- tomorrow',
      'status': 'planned',
      'color': '#43A047',
      'due_date': isoDate(d(1)),
      'start_date': isoDate(d(1)),
      'end_date': isoDate(d(1)),
    },
    {
      'title': 'Overlaps with today -- 2 day span',
      'status': 'confirmed',
      'color': null,
      'due_date': isoDate(d(0)),
      'start_date': isoDate(d(0)),
      'end_date': isoDate(d(1)),
    },
    {
      'title': '3-day trip',
      'status': 'planned',
      'color': '#FB8C00',
      'due_date': isoDate(d(2)),
      'start_date': isoDate(d(2)),
      'end_date': isoDate(d(4)),
    },
    {
      'title': 'Week-long project',
      'status': 'confirmed',
      'color': '#8E24AA',
      'due_date': isoDate(d(-1)),
      'start_date': isoDate(d(-1)),
      'end_date': isoDate(d(5)),
    },
    {
      'title': 'Next month check-in',
      'status': 'planned',
      'color': '#E53935',
      'due_date': isoDate(d(24)),
      'start_date': isoDate(d(24)),
      'end_date': isoDate(d(24)),
    },
    // Blank dates -- must simply not appear on the calendar, no error state.
    {
      'title': 'No date set yet',
      'status': 'planned',
      'color': null,
      'due_date': null,
      'start_date': null,
      'end_date': null,
    },
  ];
  for (final row in rows) {
    final id = await dao.insert(row);
    print('  #$id  ${row['title']}  (${row['start_date'] ?? 'no date'} -> ${row['end_date'] ?? '-'})');
  }

  print('Setting calendar_field to range mode (Start Date / End Date)...');
  await metadata.updateCalendarField(
    tableName,
    jsonEncode({'mode': 'range', 'start_field': 'start_date', 'end_field': 'end_date'}),
  );

  print('');
  print('Done. Open the Calendar view, tap the checklist icon (top right), and');
  print('turn on "$displayName". Entries span from yesterday through next month.');
  print('To test single-date mode instead: Settings -> Manage Tables -> '
      '"$displayName" -> Calendar field -> Single date -> "Due Date".');
  await DatabaseHelper.instance.close();
}
