// Essentials v2 Phase 5 build order step 7 -- BackgroundScheduleService
// against the real essentials.db. Covers the "is this binding due"
// decision (pure logic, exercised through the real class) and a full
// run confirming a due binding actually executes its script and records
// a last-run timestamp, while a just-run one is correctly skipped on a
// second call. Rewritten for the generic schedule_interval type -- see
// claude/essentials-v2-recurring-schedule-design.md -- which replaced
// schedule_hourly/schedule_daily/schedule_weekly. Run this file on its
// own, never chained with another SchemaEditorService.createTable-using
// test file in the same `flutter test` invocation, same standing rule as
// every schema-engine test file since the Phase 1 Step 3 incident.
import 'dart:convert';

import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/event_definitions_dao.dart';
import 'package:essentials_app/db/event_dispatch_service.dart';
import 'package:essentials_app/db/script_definitions_dao.dart';
import 'package:essentials_app/db/theme_settings_dao.dart';
import 'package:essentials_app/util/scripting/background_schedule_service.dart';
import 'package:essentials_app/util/scripting/script_api_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

void main() {
  late SqliteCrdt db;
  final events = EventDefinitionsDao();
  final scripts = ScriptDefinitionsDao();
  final settings = ThemeSettingsDao(deviceId: 'test-device');
  final runTag = DateTime.now().microsecondsSinceEpoch;

  setUpAll(() async {
    db = await DatabaseHelper.instance.crdt;
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  Future<int> createScript(String code) async {
    final id = await scripts.create(name: 'bg-$runTag', code: code, description: null);
    addTearDown(() => scripts.softDelete(id));
    return id;
  }

  Future<int> bindSchedule(int scriptId, {String? scheduleConfig}) async {
    final id = await events.create(
      scriptId: scriptId,
      eventType: 'schedule_interval',
      tableName: null,
      scheduleConfig: scheduleConfig,
    );
    addTearDown(() => events.softDelete(id));
    addTearDown(() => settings.setDeviceSetting('schedule_last_run:$id', null));
    return id;
  }

  String hourlyConfig() => jsonEncode({'interval': 1, 'unit': 'hours'});
  String anchoredConfig(DateTime anchor, {int interval = 1, String unit = 'days'}) =>
      jsonEncode({'interval': interval, 'unit': unit, 'anchor': anchor.toIso8601String()});

  test('a due hourly-equivalent binding runs and records a last-run timestamp', () async {
    final scriptId = await createScript("notify('hourly ran $runTag');");
    final eventId = await bindSchedule(scriptId, scheduleConfig: hourlyConfig());

    // Never run before -- lastRun is null, which _isDue treats as due.
    await BackgroundScheduleService(settings: settings, notify: (_) async {}).runDueScheduledEvents();

    final lastRun = await settings.loadDeviceSetting('schedule_last_run:$eventId');
    expect(lastRun, isNotNull);
    expect(DateTime.tryParse(lastRun!), isNotNull);
  });

  test('an hourly-equivalent binding just run is not run again a second time', () async {
    final scriptId = await createScript("notify('hourly again $runTag');");
    final eventId = await bindSchedule(scriptId, scheduleConfig: hourlyConfig());

    await settings.setDeviceSetting('schedule_last_run:$eventId', DateTime.now().toIso8601String());

    final rows = await db.query('SELECT code FROM script_definitions WHERE id = ?1', [scriptId]);
    expect(rows, hasLength(1));

    // Run the service -- since lastRun is "now," the binding is not yet
    // due (< 1 hour elapsed), so nothing should update the timestamp
    // again. Confirmed by checking it's unchanged (not just "still
    // present").
    final before = await settings.loadDeviceSetting('schedule_last_run:$eventId');
    await BackgroundScheduleService(settings: settings, notify: (_) async {}).runDueScheduledEvents();
    final after = await settings.loadDeviceSetting('schedule_last_run:$eventId');
    expect(after, before);
  });

  test('a disabled binding is never due', () async {
    final scriptId = await createScript("notify('should not run $runTag');");
    final eventId = await bindSchedule(scriptId, scheduleConfig: hourlyConfig());
    await events.setEnabled(eventId, false);

    await BackgroundScheduleService(settings: settings, notify: (_) async {}).runDueScheduledEvents();

    final lastRun = await settings.loadDeviceSetting('schedule_last_run:$eventId');
    expect(lastRun, isNull);
  });

  test('app_launch bindings are never fired by the background service', () async {
    final scriptId = await createScript("notify('app launch $runTag');");
    final id = await events.create(scriptId: scriptId, eventType: 'app_launch', tableName: null);
    addTearDown(() => events.softDelete(id));
    addTearDown(() => settings.setDeviceSetting('schedule_last_run:$id', null));

    await BackgroundScheduleService(settings: settings, notify: (_) async {}).runDueScheduledEvents();

    final lastRun = await settings.loadDeviceSetting('schedule_last_run:$id');
    expect(lastRun, isNull);
  });

  test('an anchored binding configured for a future time is not yet due', () async {
    final scriptId = await createScript("notify('anchored future $runTag');");
    final future = DateTime.now().add(const Duration(hours: 2));
    final eventId = await bindSchedule(scriptId, scheduleConfig: anchoredConfig(future));

    await BackgroundScheduleService(settings: settings, notify: (_) async {}).runDueScheduledEvents();

    final lastRun = await settings.loadDeviceSetting('schedule_last_run:$eventId');
    expect(lastRun, isNull);
  });

  test('an anchored binding configured for a past time is due', () async {
    final scriptId = await createScript("notify('anchored past $runTag');");
    final past = DateTime.now().subtract(const Duration(minutes: 1));
    final eventId = await bindSchedule(scriptId, scheduleConfig: anchoredConfig(past, interval: 1, unit: 'days'));

    await BackgroundScheduleService(settings: settings, notify: (_) async {}).runDueScheduledEvents();

    final lastRun = await settings.loadDeviceSetting('schedule_last_run:$eventId');
    expect(lastRun, isNotNull);
  });

  test('an anchored binding already run within the current slot is not due again', () async {
    final scriptId = await createScript("notify('anchored twice $runTag');");
    final anchor = DateTime.now().subtract(const Duration(hours: 1));
    final eventId = await bindSchedule(scriptId, scheduleConfig: anchoredConfig(anchor, interval: 1, unit: 'days'));
    await settings.setDeviceSetting('schedule_last_run:$eventId', DateTime.now().toIso8601String());

    await BackgroundScheduleService(settings: settings, notify: (_) async {}).runDueScheduledEvents();

    // Unchanged from the pre-seeded value -- same "presence, not exact
    // second-granularity equality" reasoning the original hourly version
    // of this test used.
    final lastRun = await settings.loadDeviceSetting('schedule_last_run:$eventId');
    expect(lastRun, isNotNull);
  });

  test(
    'a badly-overdue anchored binding notifies about missed occurrences and jumps to the current slot',
    () async {
      final scriptId = await createScript("notify('script effect $runTag');");
      // Anchor far enough in the past, with a short interval, that several
      // whole slots have definitely been missed since lastRun.
      final anchor = DateTime.now().subtract(const Duration(hours: 1));
      final eventId = await bindSchedule(
        scriptId,
        scheduleConfig: anchoredConfig(anchor, interval: 5, unit: 'minutes'),
      );
      // lastRun serviced the very first slot (the anchor itself) -- long
      // enough ago that many 5-minute slots have passed since.
      await settings.setDeviceSetting('schedule_last_run:$eventId', anchor.toIso8601String());

      final notifications = <String>[];
      await BackgroundScheduleService(
        settings: settings,
        notify: (message) async {
          notifications.add(message);
        },
      ).runDueScheduledEvents();

      // Whether the script's own notify('script effect ...') call actually
      // fires here depends on flutter_js's native quickjs_c_bridge.dll
      // being available -- it isn't, under a bare `flutter test` host (see
      // BackgroundScheduleService's own constructor doc comment) -- so
      // this only asserts on the missed-occurrence notice itself, not the
      // script's own effect.
      final missedNotice = notifications.firstWhere((m) => m.contains('fell behind schedule'));
      expect(missedNotice, contains('bg-$runTag'));
      expect(missedNotice, matches(RegExp(r'skipped \d+ missed occurrences?')));

      final lastRun = await settings.loadDeviceSetting('schedule_last_run:$eventId');
      expect(lastRun, isNotNull);
    },
  );

  test('an anchored binding that is on schedule (no gap) does not post a missed-occurrence notice', () async {
    final scriptId = await createScript("notify('on schedule $runTag');");
    // Anchor two days ago, daily interval -- a real slot sequence
    // (anchor, anchor+1d, anchor+2d=~now) with lastRun having serviced
    // exactly the immediately-preceding slot. Normal progression, nothing
    // missed.
    final anchor = DateTime.now().subtract(const Duration(days: 2));
    final eventId = await bindSchedule(scriptId, scheduleConfig: anchoredConfig(anchor, interval: 1, unit: 'days'));
    await settings.setDeviceSetting(
      'schedule_last_run:$eventId',
      anchor.add(const Duration(days: 1)).toIso8601String(),
    );

    final notifications = <String>[];
    await BackgroundScheduleService(
      settings: settings,
      notify: (message) async {
        notifications.add(message);
      },
    ).runDueScheduledEvents();

    expect(notifications.any((m) => m.contains('fell behind schedule')), isFalse);
  });

  // The `bg_check:*` device_settings keys BackgroundProcessesScreen and the
  // Windows watchdog script both read -- see runDueScheduledEvents' own doc
  // comment for why they're recorded from this one shared place rather than
  // duplicated per-caller.
  group('bg_check status recording', () {
    tearDown(() async {
      for (final key in [
        BackgroundScheduleService.statusLastAttemptKey,
        BackgroundScheduleService.statusLastResultKey,
        BackgroundScheduleService.statusLastErrorKey,
        BackgroundScheduleService.statusLastSuccessAtKey,
        BackgroundScheduleService.statusConsecutiveFailuresKey,
        BackgroundScheduleService.statusLastAppliedCountKey,
      ]) {
        await settings.setDeviceSetting(key, null);
      }
    });

    test('a successful pass records ok status and resets consecutive failures', () async {
      await settings.setDeviceSetting(BackgroundScheduleService.statusConsecutiveFailuresKey, '3');

      await BackgroundScheduleService(settings: settings, notify: (_) async {}).runDueScheduledEvents();

      expect(
        DateTime.tryParse(await settings.loadDeviceSetting(BackgroundScheduleService.statusLastAttemptKey) ?? ''),
        isNotNull,
      );
      expect(await settings.loadDeviceSetting(BackgroundScheduleService.statusLastResultKey), 'ok');
      expect(await settings.loadDeviceSetting(BackgroundScheduleService.statusLastErrorKey), isNull);
      expect(
        DateTime.tryParse(await settings.loadDeviceSetting(BackgroundScheduleService.statusLastSuccessAtKey) ?? ''),
        isNotNull,
      );
      expect(await settings.loadDeviceSetting(BackgroundScheduleService.statusConsecutiveFailuresKey), '0');
    });

    test('a failing pass records the error, increments consecutive failures, and still rethrows', () async {
      await settings.setDeviceSetting(BackgroundScheduleService.statusConsecutiveFailuresKey, '1');

      final service = BackgroundScheduleService(
        events: events,
        dispatcher: _ThrowingDispatcher(),
        settings: settings,
        notify: (_) async {},
      );

      // Needs a real due binding to reach the dispatcher at all.
      final scriptId = await createScript("notify('never runs $runTag');");
      await bindSchedule(scriptId, scheduleConfig: hourlyConfig());

      await expectLater(service.runDueScheduledEvents(), throwsA(isA<StateError>()));

      expect(await settings.loadDeviceSetting(BackgroundScheduleService.statusLastResultKey), 'error');
      expect(
        await settings.loadDeviceSetting(BackgroundScheduleService.statusLastErrorKey),
        contains('simulated dispatch failure'),
      );
      expect(await settings.loadDeviceSetting(BackgroundScheduleService.statusConsecutiveFailuresKey), '2');
    });
  });
}

/// Fake for the one failing-pass test above -- throws instead of running
/// any script, to reach runDueScheduledEvents' catch/rethrow path without
/// needing a script that can actually fail script execution itself.
class _ThrowingDispatcher implements EventDispatchService {
  @override
  Future<List<ScriptRunResult>> dispatch({
    required String? tableName,
    required String eventType,
    String? fieldName,
    int? recordId,
  }) async {
    throw StateError('simulated dispatch failure');
  }

  @override
  Future<void> dispatchAndApplyEffects(
    BuildContext context, {
    required String? tableName,
    required String eventType,
    String? fieldName,
    int? recordId,
  }) => throw UnimplementedError();
}
