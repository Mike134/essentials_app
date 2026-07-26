// ignore_for_file: avoid_print
// One-time field_metadata seeding pass for `order_items` (CLAUDE.md
// "Split-Pane Layout" session, Part A) -- run with
// `dart run tool/seed_field_metadata_order_items.dart`.
//
// Two overrides needed:
// 1. `order_items.order_id`'s generic FK dropdown would otherwise default
//    to assuming a `name` column on `orders` -- there isn't one, `orders`
//    only has `order_number`. Same pattern as
//    `subscription.payment_method_id` -> `account.code`
//    (see seed_field_metadata_subscription.dart).
// 2. `order_items` has no `name` column and no `NOT NULL` column either
//    (`description`/`cost` are both nullable) -- the displayColumn
//    heuristic would otherwise fall back to the bare `id`. Same reserved
//    `_display_column` sentinel `shipment` already uses (CLAUDE.md "Table
//    Discovery phase" Part E.2) to carry `description` forward instead.
//
// Plain `dart run`, not `flutter test`. Idempotent (INSERT OR REPLACE) --
// safe to re-run.
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _dbDirectory = r'C:\Databases\essentials_app';
const String _dbFileName = 'essentials.db';

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
    await db.insert('field_metadata', {
      'table_name': 'order_items',
      'field_name': 'order_id',
      'lookup_display_column': 'order_number',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert('field_metadata', {
      'table_name': 'order_items',
      'field_name': '_display_column',
      'display_label': 'description',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    print('Seeded order_items.order_id lookup_display_column=order_number');
    print('Seeded order_items _display_column=description');
  } finally {
    await db.close();
  }
}
