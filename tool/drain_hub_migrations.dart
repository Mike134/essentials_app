// ignore_for_file: avoid_print
// One-off recovery tool -- runs the server's own MigrationService
// .applyPending() directly against hub.db, with no HTTP server running at
// all, so it can drain a large pending-migration backlog with zero risk of
// racing a concurrent SqlCrdt.getChangeset() call (see server/bin
// /migration_service.dart's own doc comment on the already-documented
// "database is locked" race with crdt_sync's merge -- this is the mirror
// case: applyPending()'s own CREATE-then-DROP DDL sequence racing
// getChangeset()'s "list tables, then query each" two-step, which crashed
// the live server outright on two consecutive restarts, 2026-09-13,
// working through a backlog of this session's own throwaway test tables
// that had never been applied to hub.db because the server had been
// stopped/restarted several times without a clean, uninterrupted window to
// finish catching up).
//
//   dart run tool/drain_hub_migrations.dart --path C:\Databases\essentials_app\server\hub.db
//
// Safe to run repeatedly -- applyPending() itself skips anything already
// 'succeeded' and halts (without retrying) on a real 'failed' migration.
import 'dart:io';

import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../server/bin/migration_service.dart';

Future<void> main(List<String> args) async {
  final path = _argValue(args, '--path') ?? r'C:\Databases\essentials_app\server\hub.db';
  if (!await File(path).exists()) {
    print('REFUSING: no file at $path');
    exitCode = 1;
    return;
  }

  print('Opening $path ...');
  final crdt = await SqliteCrdt.open(path);
  try {
    final before = await crdt.query(
      "SELECT COUNT(*) AS c FROM migration_log l WHERE l.is_deleted = 0 AND NOT EXISTS "
      "(SELECT 1 FROM migration_status s WHERE s.migration_id = l.id AND s.device_id = 'server' "
      "AND s.outcome = 'succeeded' AND s.is_deleted = 0)",
    );
    print('Pending (not yet succeeded for device "server"): ${before.first['c']}');

    print('Running MigrationService.applyPending() ...');
    await MigrationService(crdt).applyPending();

    final after = await crdt.query(
      "SELECT COUNT(*) AS c FROM migration_log l WHERE l.is_deleted = 0 AND NOT EXISTS "
      "(SELECT 1 FROM migration_status s WHERE s.migration_id = l.id AND s.device_id = 'server' "
      "AND s.outcome = 'succeeded' AND s.is_deleted = 0)",
    );
    print('Still pending after this run: ${after.first['c']}');

    final failed = await crdt.query(
      "SELECT migration_id, error_message FROM migration_status "
      "WHERE device_id = 'server' AND outcome = 'failed' AND is_deleted = 0",
    );
    if (failed.isNotEmpty) {
      print('FAILED migrations (halts the pipeline until retracted):');
      for (final row in failed) {
        print('  #${row['migration_id']}: ${row['error_message']}');
      }
    }

    final integrity = await crdt.query('PRAGMA integrity_check');
    print('integrity_check: ${integrity.first.values.first}');
  } finally {
    await crdt.close();
  }
}

String? _argValue(List<String> args, String flag) {
  final index = args.indexOf(flag);
  if (index == -1 || index + 1 >= args.length) return null;
  return args[index + 1];
}
