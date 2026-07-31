// Runs against the real hub.db (see CLAUDE.md "Working style / constraints"
// -- schema_admin runs only on MIKE-CU, so "the real db" is unambiguous
// here the same way it is for essentials_app's own db-touching tests).
// Confirms the migration_log/migration_status bootstrap tables are really
// there and readable before Part D's real end-to-end submission.

import 'package:flutter_test/flutter_test.dart';
import 'package:schema_admin/db/migration_dao.dart';

void main() {
  final dao = MigrationDao();

  test('history() reads real migration_log without error', () async {
    final entries = await dao.history();
    expect(entries, isA<List<MigrationLogEntry>>());
  });

  test('knownDeviceIds() reads real migration_status without error', () async {
    final devices = await dao.knownDeviceIds();
    expect(devices, isA<List<String>>());
  });

  test('checkDropSafety() detects a DROP TABLE referencing a real FK target', () async {
    final blockers = await dao.checkDropSafety('DROP TABLE supplier;');
    expect(blockers, hasLength(1));
    expect(blockers.first.blockedBy, isNotEmpty);
  });

  test('checkDropSafety() finds nothing for an ordinary ADD COLUMN', () async {
    final blockers = await dao.checkDropSafety("ALTER TABLE domain ADD COLUMN foo TEXT;");
    expect(blockers, isEmpty);
  });
}
