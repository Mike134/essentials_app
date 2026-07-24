// ignore_for_file: avoid_print
// One-time field_metadata seeding pass for `subscription` (CLAUDE.md
// "Table Discovery phase" Part E.3) -- run with
// `dart run tool/seed_field_metadata_subscription.dart`.
//
// Exactly one override needed, checked field-by-field against the
// hand-written subscriptionConfig before writing this: `payment_method_id`
// resolves against `account.code`, not `account.name` (see CLAUDE.md
// "Known data quirks") -- the one heuristic introspection alone would get
// wrong, since `account` genuinely has its own `name` column, so the
// default lookup-display-column heuristic would otherwise pick that
// instead. Every other field (labels including `used_by_id` -> "Used By"
// and `renewal_period_id` -> "Renewal Period", `active`'s real SQL
// `DEFAULT 1`, displayColumn/orderBy both resolving to `name`) already
// matches introspection's heuristics with zero override needed --
// `subscription` has no `position`/`color` columns, so unlike batches 1/2
// there's nothing else to seed.
//
// This script does NOT handle the subscription_computed readSource or the
// yearly_cost/next_date view-only columns -- those stay genuine, deliberate
// exceptions in table_configs.dart's buildSubscriptionConfig, not
// something field_metadata can express (computePreview is Dart code; the
// two extra columns don't exist on the real `subscription` table for
// PRAGMA table_info to ever see).
//
// Plain `dart run`, not `flutter test` -- see seed_field_metadata_batch1.dart
// for why. Idempotent (INSERT OR REPLACE) -- safe to re-run.
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
      'table_name': 'subscription',
      'field_name': 'payment_method_id',
      'lookup_display_column': 'code',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    print('Seeded subscription.payment_method_id lookup_display_column=code');
  } finally {
    await db.close();
  }
}
