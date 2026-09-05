// ignore_for_file: avoid_print
// Essentials v2 recurring-schedule design, device-targeting follow-up --
// one-time bootstrap that adds `event_definitions.target_devices` to an
// EXISTING, already-live essentials.db. Same chicken-and-egg reasoning and
// same shape as tool/add_calendar_field_column.dart -- see that file's own
// doc comment for the full rationale.
//
//   dart run tool/add_target_devices_column.dart --path <db> [--device-id <id>]
//
// `--device-id` defaults to this machine's own hostname ONLY when `--path`
// is omitted (i.e. targeting this device's own default essentials.db) --
// pass it explicitly for anything else (hub.db, a pulled device copy). See
// CLAUDE.md's Essentials v2 Phase 3 session write-up for exactly the
// incident this refusal exists to prevent (re-authoring a duplicate
// migration_log row under the wrong identity).
//
// Idempotent: does nothing (prints and exits 0) if the column already
// exists.
//
// `target_devices` is a JSON array of device-name strings (e.g.
// '["MIKE-CU","MIKE-12R"]') -- NULL/empty means the binding is real but
// dormant, never fires anywhere, per Mike's explicit ask: no device
// selected must never mean "runs everywhere" (the opposite of every other
// nullable/unconfigured field in this schema, which all fail permissive --
// this one deliberately fails closed instead, since the whole point is
// preventing a script's side effects from silently multiplying across
// every connected device).
import 'dart:io';

import 'package:sqlite_crdt/sqlite_crdt.dart';

const _ddl = 'ALTER TABLE "event_definitions" ADD COLUMN "target_devices" TEXT';

Future<void> main(List<String> args) async {
  final path = _argValue(args, '--path') ?? r'C:\Databases\essentials_app\essentials.db';
  final explicitDeviceId = _argValue(args, '--device-id');
  final isDefaultPath = _argValue(args, '--path') == null;
  final deviceId = explicitDeviceId ?? (isDefaultPath ? Platform.localHostname : null);
  if (deviceId == null) {
    print('REFUSING: pass --device-id explicitly when --path targets anything other than');
    print('this machine\'s own essentials.db (e.g. --device-id server for hub.db, or the');
    print('real device_id for a pulled-and-about-to-be-pushed-back device copy).');
    exitCode = 64;
    return;
  }

  if (!await File(path).exists()) {
    print('REFUSING: no file at $path');
    exitCode = 1;
    return;
  }

  print('Opening $path ...');
  final crdt = await SqliteCrdt.open(path);
  try {
    final columns = await crdt.query('PRAGMA table_info("event_definitions")');
    if (columns.any((c) => c['name'] == 'target_devices')) {
      print('target_devices already exists -- nothing to do.');
      return;
    }

    String? migrationIdDefault;
    final migrationLogColumns = await crdt.query('PRAGMA table_info("migration_log")');
    for (final column in migrationLogColumns) {
      if (column['name'] == 'id') migrationIdDefault = column['dflt_value'] as String?;
    }

    final createdAt = DateTime.now().toUtc().toIso8601String();
    final columnList = migrationIdDefault == null
        ? 'sql_text, description, created_at'
        : 'id, sql_text, description, created_at';
    final valuesSql = migrationIdDefault == null ? '?1, ?2, ?3' : '($migrationIdDefault), ?1, ?2, ?3';

    print('Authoring migration_log entry ...');
    await crdt.transaction((txn) async {
      await txn.execute(
        'INSERT INTO migration_log ($columnList) VALUES ($valuesSql)',
        [_ddl, 'Add event_definitions.target_devices (per-device schedule targeting)', createdAt],
      );
    });

    print('Applying DDL to this device ...');
    await crdt.execute('PRAGMA foreign_keys = OFF');
    try {
      await crdt.transaction((txn) async {
        await txn.execute(_ddl);
      });
    } finally {
      await crdt.execute('PRAGMA foreign_keys = ON');
    }

    await crdt.execute(
      "INSERT INTO migration_status (migration_id, device_id, outcome, attempted_at) "
      "SELECT id, ?1, 'succeeded', ?2 FROM migration_log WHERE sql_text = ?3 ORDER BY id DESC LIMIT 1",
      [deviceId, DateTime.now().toUtc().toIso8601String(), _ddl],
    );

    final after = await crdt.query('PRAGMA table_info("event_definitions")');
    if (after.any((c) => c['name'] == 'target_devices')) {
      print('OK: target_devices added.');
      print('This device ($deviceId) is done. The migration_log row will sync to the');
      print('server and MIKE-12R normally next time each connects -- nothing further');
      print('to run by hand on those (but see the tool\'s own header: apply directly to');
      print('hub.db / a pulled device copy too if you want to avoid waiting on that sync).');
    } else {
      print('FAIL: target_devices missing after ALTER TABLE.');
      exitCode = 1;
    }
  } finally {
    await crdt.close();
  }
}

String? _argValue(List<String> args, String flag) {
  final index = args.indexOf(flag);
  if (index == -1 || index + 1 >= args.length) return null;
  return args[index + 1];
}
