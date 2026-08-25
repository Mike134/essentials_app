// ignore_for_file: avoid_print
// Essentials v2 Phase 3, Step 3 (Kanban) -- creates a real throwaway table
// through the actual app-facing SchemaEditorService/GenericDao (not raw
// SQL), with fields and rows specifically shaped to exercise every corner
// of the Kanban view: an inline-select "Status" field to group by (three
// configured columns, in a deliberately non-alphabetical order so the
// board's own column-ordering is actually being tested), rows spread
// across every configured status, one row with a *blank* status (exercises
// the implicit "(none)" column), and one row with a status value that
// doesn't match any configured option (exercises the ad-hoc "unmatched
// value" column -- see KanbanViewScreen's own doc comment).
//
//   flutter test tool/create_kanban_test_table.dart
//
// (Not `dart run` -- SchemaEditorService transitively imports
// `package:flutter/widgets.dart` via TableConfig, which crashes the
// vanilla Dart SDK's compiler; `flutter test` on a bare `main()` with no
// `test()` calls runs it to completion fine -- see CLAUDE.md "Essentials
// v2 Phase 1 -- Step 5" for the same gotcha hit there first.)
//
// Paired with tool/remove_kanban_test_table.dart once Mike's done testing.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/db/schema_editor_service.dart';
import 'package:essentials_app/db/schema_registry.dart';
import 'package:essentials_app/db/view_definitions_dao.dart';

const displayName = 'Kanban Test';

Future<void> main() async {
  final editor = SchemaEditorService();
  final registry = SchemaRegistry();
  final views = ViewDefinitionsDao();

  print('Creating "$displayName"...');
  final tableName = await editor.createTable(
    displayName: displayName,
    description: 'Essentials v2 Phase 3 Step 3 (Kanban) test data. Safe to '
        'delete once confirmed on both platforms -- see '
        'tool/remove_kanban_test_table.dart.',
  );
  print('  table_name: $tableName');

  print('Adding "Task" (text, primary field)...');
  await editor.addField(tableName: tableName, displayName: 'Task', format: 'text');

  print('Adding "Status" (inline select, group field)...');
  // Deliberately not alphabetical (To Do / In Progress / Done, not the
  // alphabetical Done/In Progress/To Do) -- a real check that the board
  // renders columns in *configured* order, not some derived order.
  await editor.addField(
    tableName: tableName,
    displayName: 'Status',
    format: 'select',
    optionsJson:
        '{"mode": "inline", "options": '
        '[{"key": "todo", "label": "To Do"}, '
        '{"key": "in_progress", "label": "In Progress"}, '
        '{"key": "done", "label": "Done"}]}',
  );

  print('Adding "Owner" (text, secondary field)...');
  await editor.addField(tableName: tableName, displayName: 'Owner', format: 'text');

  print('Adding "Priority" (text, extra card field)...');
  await editor.addField(tableName: tableName, displayName: 'Priority', format: 'text');

  final config = await registry.buildConfig(tableName);
  final dao = GenericDao(config);

  print('Inserting test rows...');
  final rows = <Map<String, Object?>>[
    {'task': 'Write project brief', 'status': 'todo', 'owner': 'Mike', 'priority': 'High'},
    {'task': 'Pick a color scheme', 'status': 'todo', 'owner': 'Sam', 'priority': 'Low'},
    {'task': 'Draft the wireframes', 'status': 'in_progress', 'owner': 'Mike', 'priority': 'High'},
    {'task': 'Review vendor quotes', 'status': 'in_progress', 'owner': 'Sam', 'priority': 'Medium'},
    {'task': 'Set up the dev environment', 'status': 'done', 'owner': 'Mike', 'priority': 'Medium'},
    {'task': 'Kickoff meeting notes', 'status': 'done', 'owner': 'Sam', 'priority': 'Low'},
    // Blank status -- exercises the implicit "(none)" column.
    {'task': 'Something not triaged yet', 'status': null, 'owner': 'Mike', 'priority': 'Medium'},
    // A status value that isn't one of the three configured options --
    // exercises the ad-hoc "unmatched value" column (imagine this is what
    // a deleted option or a stray CSV import would leave behind).
    {'task': 'Legacy item from the old tracker', 'status': 'blocked', 'owner': 'Sam', 'priority': 'High'},
  ];
  for (final row in rows) {
    final id = await dao.insert(row);
    print('  #$id  ${row['task']}  (${row['status'] ?? 'blank'})');
  }

  print('Creating a real Kanban view for "$displayName"...');
  final viewId = await views.createView(
    tableName: tableName,
    viewType: 'kanban',
    displayName: 'Board',
    config: {
      'group_field': 'status',
      'primary_field': 'task',
      'primary_sort_dir': 'asc',
      'secondary_field': 'owner',
      'secondary_sort_dir': 'asc',
      'extra_fields': ['priority'],
    },
  );
  print('  view_id: $viewId');

  print('');
  print('Done. Launch essentials_app, open "$displayName", and switch to the "Board" tab.');
  await DatabaseHelper.instance.close();
}
