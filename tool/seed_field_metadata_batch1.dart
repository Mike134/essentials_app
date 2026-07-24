// ignore_for_file: avoid_print
// One-time field_metadata seeding pass for the 10 batch-1 lookup tables
// (CLAUDE.md "Table Discovery phase" Part E.1) -- run with
// `dart run tool/seed_field_metadata_batch1.dart`.
//
// Preserves the two values every batch-1 TableConfig in table_configs.dart
// hardcoded that introspection cannot derive on its own (neither has a
// real SQL-level DEFAULT in schema.sql, so TableDiscoveryService would
// otherwise leave them null): position=255, color='#FFFFFF'. Everything
// else about these tables (name/description/active/abbreviation/definition
// labels, active's boolean default, displayColumn, orderBy) already matches
// introspection's heuristics with zero override needed -- verified in
// test/batch1_conversion_regression_test.dart.
//
// Plain `dart run`, not `flutter test` -- deliberately avoids importing
// database_helper.dart (pulls in permission_handler -> package:flutter ->
// dart:ui, unavailable outside a Flutter host), same reasoning as
// tool/smoke_test.dart. Idempotent (INSERT OR REPLACE) -- safe to re-run.
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _dbDirectory = r'C:\Databases\essentials_app';
const String _dbFileName = 'essentials.db';

const List<String> _batch1Tables = [
  'domain',
  'priority',
  'gender',
  'status',
  'quality',
  'condition',
  'unit',
  'importance',
  'disposition',
  'class',
];

Future<void> main() async {
  sqfliteFfiInit();
  final path = join(_dbDirectory, _dbFileName);

  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
    ),
  );

  try {
    var seeded = 0;
    for (final table in _batch1Tables) {
      await db.insert('field_metadata', {
        'table_name': table,
        'field_name': 'position',
        'default_value': '255',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert('field_metadata', {
        'table_name': table,
        'field_name': 'color',
        'default_value': '#FFFFFF',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      seeded += 2;
      print('Seeded $table.position=255, $table.color=#FFFFFF');
    }
    print('\nDone -- $seeded field_metadata rows seeded across ${_batch1Tables.length} tables.');
  } finally {
    await db.close();
  }
}
