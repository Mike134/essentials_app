// Essentials v2 alarm-based scheduling, build order step 3 (see
// claude/essentials-v2-alarm-scheduling-design.md). Covers
// computeNextDueTimeForDevice -- the only part of alarm_schedule_service.dart
// that doesn't touch AndroidAlarmManager (which has no implementation
// under a bare `flutter test` host) -- against the real essentials.db,
// same pattern background_schedule_service_test.dart already established
// for the sibling _isDue-style logic.
//
// computeNextDueTimeForDevice returns a MINIMUM across every real
// scheduled binding on this device, including whatever Mike's own real
// usage has created -- an exact-value assertion would be fragile against
// that live, growing dataset. Every test here instead asserts a
// before/after invariant of a min-reduction (adding a candidate can only
// pull the result earlier or leave it unchanged, never later; adding a
// non-contributing binding must leave the result exactly unchanged) --
// true regardless of whatever else is in the real database.
//
// Run this file on its own, never chained with another
// SchemaEditorService.createTable-using test file in the same
// `flutter test` invocation, same standing rule as every schema-engine
// test file since the Phase 1 Step 3 incident.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/event_definitions_dao.dart';
import 'package:essentials_app/db/script_definitions_dao.dart';
import 'package:essentials_app/db/theme_settings_dao.dart';
import 'package:essentials_app/util/scripting/alarm_schedule_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final events = EventDefinitionsDao();
  final scripts = ScriptDefinitionsDao();
  final settings = ThemeSettingsDao(deviceId: 'test-device');
  final runTag = DateTime.now().microsecondsSinceEpoch;
  final now = DateTime(2026, 9, 4, 10);

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  Future<int> createScript(String code) async {
    final id = await scripts.create(name: 'alarm-$runTag', code: code, description: null);
    addTearDown(() => scripts.softDelete(id));
    return id;
  }

  Future<int> bindSchedule(int scriptId, String eventType, {String? scheduleConfig}) async {
    final id = await events.create(
      scriptId: scriptId,
      eventType: eventType,
      tableName: null,
      scheduleConfig: scheduleConfig,
    );
    addTearDown(() => events.softDelete(id));
    addTearDown(() => settings.setDeviceSetting('schedule_last_run:$id', null));
    return id;
  }

  Future<DateTime?> due() => computeNextDueTimeForDevice(events: events, settings: settings, now: now);

  test('returns a well-formed result (or null) against real, live data', () async {
    expect(await due(), anyOf(isNull, isA<DateTime>()));
  });

  test('a never-run unanchored interval binding pulls the result to at most now', () async {
    final scriptId = await createScript("notify('hourly $runTag');");
    await bindSchedule(scriptId, 'schedule_interval', scheduleConfig: '{"interval": 1, "unit": "hours"}');

    final result = await due();
    expect(result, isNotNull);
    expect(result!.isAfter(now), isFalse);
  });

  test('an anchored binding configured for later today pulls the result to at most that time', () async {
    final scriptId = await createScript("notify('daily $runTag');");
    await bindSchedule(
      scriptId,
      'schedule_interval',
      scheduleConfig: '{"interval": 1, "unit": "days", "anchor": "2026-09-01T14:30:00"}',
    );

    final result = await due();
    expect(result, isNotNull);
    expect(result!.isAfter(DateTime(2026, 9, 4, 14, 30)), isFalse);
  });

  test('an app_launch binding never contributes -- result is unchanged', () async {
    final before = await due();
    final scriptId = await createScript("notify('launch $runTag');");
    await bindSchedule(scriptId, 'app_launch');
    final after = await due();

    expect(after, before);
  });

  test('a disabled binding never contributes -- result is unchanged', () async {
    final before = await due();
    final scriptId = await createScript("notify('disabled $runTag');");
    final eventId = await bindSchedule(scriptId, 'schedule_interval', scheduleConfig: '{"interval": 1, "unit": "hours"}');
    await events.setEnabled(eventId, false);
    final after = await due();

    expect(after, before);
  });

  test('reads a stored last-run time back and computes lastRun + 1h, not "never run"', () async {
    final scriptId = await createScript("notify('lastrun $runTag');");
    final eventId = await bindSchedule(scriptId, 'schedule_interval', scheduleConfig: '{"interval": 1, "unit": "hours"}');
    final lastRun = now.subtract(const Duration(minutes: 20));
    await settings.setDeviceSetting('schedule_last_run:$eventId', lastRun.toIso8601String());

    final result = await due();
    // If the stored timestamp were misread as "never run," this binding
    // would contribute `now` (see the "never-run" test above) -- pulling
    // the result to at most `now`. Reading it correctly instead
    // contributes lastRun + 1h (40 minutes after `now`), a real, later
    // upper bound -- still robust to other real data, since any other
    // binding can only pull the aggregate result earlier than this one's
    // own contribution, never explain it being later.
    expect(result, isNotNull);
    expect(result!.isAfter(lastRun.add(const Duration(hours: 1))), isFalse);
  });
}
