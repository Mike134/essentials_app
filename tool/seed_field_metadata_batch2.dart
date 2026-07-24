// ignore_for_file: avoid_print
// One-time field_metadata seeding pass for the 9 batch-2 tables (CLAUDE.md
// "Table Discovery phase" Part E.2) -- run with
// `dart run tool/seed_field_metadata_batch2.dart`.
//
// Same reasoning as tool/seed_field_metadata_batch1.dart: seeds only what
// introspection genuinely can't derive on its own. Checked field-by-field
// against every hand-written batch-2 TableConfig before writing this --
// journal needs zero overrides (every heuristic already reproduces it
// exactly, including entry_time as displayColumn and `entry_time DESC` as
// orderBy). `shipment` is the one real exception: no `name` column and no
// `NOT NULL` column at all for the displayColumn/orderBy heuristics to
// land on, so it uses the reserved field_metadata sentinel field names
// (`_display_column`/`_order_by`, see table_discovery_service.dart) to
// carry the exact table-level override forward -- a deliberately narrow
// convention, not a general mechanism, used only because this is the one
// table that needs it.
//
// Plain `dart run`, not `flutter test` -- see seed_field_metadata_batch1.dart
// for why. Idempotent (INSERT OR REPLACE) -- safe to re-run.
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _dbDirectory = r'C:\Databases\essentials_app';
const String _dbFileName = 'essentials.db';

/// Tables sharing batch-1's position/color-only gap -- every other
/// attribute (labels, lookup display columns, displayColumn/orderBy)
/// already matches introspection's heuristics with zero override needed.
const List<String> _positionColorOnlyTables = [
  'account_type',
  'person',
  'category',
  'time_frame',
  'account',
  'supplier',
  'shipper',
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
    Future<void> upsert(String table, String field, {String? label, String? defaultValue}) async {
      await db.insert('field_metadata', {
        'table_name': table,
        'field_name': field,
        'display_label': label,
        'default_value': defaultValue,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      seeded++;
      print('Seeded $table.$field'
          '${label != null ? ' label=$label' : ''}'
          '${defaultValue != null ? ' default=$defaultValue' : ''}');
    }

    for (final table in _positionColorOnlyTables) {
      await upsert(table, 'position', defaultValue: '255');
      await upsert(table, 'color', defaultValue: '#FFFFFF');
    }

    // shipment: no position/color columns at all -- just the display-label
    // casing fixes (titleCase can't know "ID" should stay all-caps) and the
    // reserved table-level overrides.
    await upsert('shipment', 'order_id', label: 'Order ID');
    await upsert('shipment', 'tracking_id', label: 'Tracking ID');
    await upsert('shipment', '_display_column', label: 'order_id');
    await upsert('shipment', '_order_by', label: 'order_date DESC, id DESC');

    print('\nDone -- $seeded field_metadata rows seeded across '
        '${_positionColorOnlyTables.length + 1} tables (journal needed none).');
  } finally {
    await db.close();
  }
}
