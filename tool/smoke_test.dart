// ignore_for_file: avoid_print
// One-shot connection smoke test -- run with `dart run tool/smoke_test.dart`.
//
// Opens the real essentials.db (not a copy), asserts PRAGMA foreign_keys is
// really on, and confirms `domain` has its expected 5 seed rows. Meant to
// verify the foundation (path + FK pragma) before any UI is built on top of
// it -- see CLAUDE.md's "risk-first prototyping" approach.
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
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    ),
  );

  try {
    final fkRows = await db.rawQuery('PRAGMA foreign_keys');
    final fkOn = fkRows.first.values.first == 1;
    print('PRAGMA foreign_keys = ${fkRows.first.values.first} '
        '(${fkOn ? 'ON' : 'OFF'})');
    if (!fkOn) {
      throw StateError('foreign_keys pragma did not take effect');
    }

    final countRows = await db.rawQuery('SELECT COUNT(*) AS c FROM domain');
    final count = countRows.first['c'] as int;
    print('domain row count = $count');
    if (count != 5) {
      throw StateError('expected 5 domain rows, got $count');
    }

    print('SMOKE TEST PASSED: connection, FK pragma, and domain data all OK');
  } finally {
    await db.close();
  }
}
