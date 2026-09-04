import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';

import '../../db/event_definitions_dao.dart';
import '../../db/theme_settings_dao.dart';
import '../device_id.dart';
import 'background_schedule_service.dart';
import 'next_due_time.dart';

/// Essentials v2 alarm-based scheduling, build order step 3 (see
/// claude/essentials-v2-alarm-scheduling-design.md). Replaces
/// [BackgroundScheduleService]'s own 15-minute polling entry point with a
/// self-rescheduling chain of one-shot alarms: [rescheduleNextAlarm]
/// computes the single next due time across every scheduled binding (via
/// [nextDueTime], build order step 1) and arms exactly one alarm for it;
/// on fire, [scheduledEventAlarmCallback] runs the existing due-check/
/// dispatch logic completely unchanged, then immediately recomputes and
/// re-arms the next one.
///
/// **Android only** -- `android_alarm_manager_plus` has no Windows
/// implementation, so every caller here must guard with `Platform
/// .isAndroid` itself, same convention this codebase already uses for
/// [BackgroundScheduleService]'s own `registerBackgroundScheduleTask`
/// call site in `HomeShell`. Not guarded internally on purpose -- keeps
/// this file's own behavior unconditional and simple to reason about,
/// consistent with how `windows_background_entrypoint.dart` doesn't
/// guard itself either.
///
/// [BackgroundScheduleService.runDueScheduledEvents] itself needs zero
/// changes -- it already re-verifies "is this genuinely due right now"
/// before running anything (`_isDue`), which is exactly the safety
/// property that makes it fine for an alarm to fire a little early/late
/// (OS batching an inexact `allowWhileIdle` alarm, confirmed in the build
/// order step 2 spike to run ~30-40s later than requested; clock drift
/// between "when the next alarm was computed" and "when it actually
/// fires") -- a stale alarm firing before or after its target moment
/// still just re-checks and does the right thing.
///
/// This file has no direct unit tests of its own -- `AndroidAlarmManager`
/// has no implementation under a bare `flutter test` host (same category
/// of limitation already documented for `flutter_js`/`geolocator`/
/// `mobile_scanner` elsewhere in this app), so nothing here can be
/// exercised without a real device. [computeNextDueTimeForDevice] is
/// factored out specifically so the one genuinely testable part -- turning
/// this device's real `event_definitions`/`schedule_last_run:*` rows into
/// a due time -- has real, DB-backed test coverage
/// (`test/alarm_schedule_service_test.dart`) without touching the plugin
/// at all.
const _scheduledEventsAlarmId = 1;

/// One-time cleanup for a real, if harmless, artifact of the now-deleted
/// build order step 2 spike (`alarm_manager_spike.dart`) -- its alarm
/// (id `990001`, `rescheduleOnReboot: true`) is still persisted natively
/// in `android_alarm_manager_plus`'s own `SharedPreferences` on any
/// device that ran that spike (MIKE-12R). Confirmed live: on this ROM
/// (ColorOS), a `BOOT_COMPLETED`-equivalent broadcast is redelivered to
/// the app's boot receiver not just on a genuine reboot but on *every*
/// force-stop-then-relaunch cycle too, each time trying (and failing,
/// harmlessly) to resolve the deleted spike file's callback handle --
/// `Dart Error: Dart_LookupLibrary: ... alarm_manager_spike.dart not
/// found`, logged but not fatal to anything. `AndroidAlarmManager.cancel`
/// is exactly what the plugin's own API offers for clearing a persisted
/// alarm (it doesn't need the original callback reference, just the
/// numeric id), and is safe to call even when nothing is actually
/// registered under this id (logs "broadcast receiver not found," a
/// no-op). Called once per [rescheduleNextAlarm] invocation -- cheap, and
/// guarantees this resolves itself the moment this build first runs on
/// the affected device, without needing a dedicated one-off migration
/// step. Safe to remove once confirmed clear on every real device (the
/// call becomes a permanent, harmless no-op otherwise).
Future<void> _cancelLeftoverSpikeAlarm() => AndroidAlarmManager.cancel(990001);

/// Same `schedule_last_run:<id>` key format
/// [BackgroundScheduleService]/`background_schedule_service_test.dart`
/// already use -- duplicated here rather than shared, matching this
/// project's own established convention for a small, stable string
/// format used by more than one file (e.g. `schemaStatements` between
/// `essentials_app` and `server/`) -- these two call sites read/write the
/// exact same `device_settings` rows, so the format has to stay in sync,
/// but it's simple and stable enough that a shared constant would be more
/// ceremony than the duplication it avoids.
String _lastRunKey(int eventDefinitionId) => 'schedule_last_run:$eventDefinitionId';

/// Reads this device's real scheduled bindings and their last-run times,
/// and returns the next moment any of them will next be due -- the pure
/// DB-to-`nextDueTime` plumbing [rescheduleNextAlarm] needs, factored out
/// so it can be tested directly against the real `essentials.db` without
/// ever touching `AndroidAlarmManager`.
Future<DateTime?> computeNextDueTimeForDevice({
  required EventDefinitionsDao events,
  required ThemeSettingsDao settings,
  DateTime? now,
}) async {
  final bindings = await events.loadScheduled();
  final lastRunTimes = <int, DateTime?>{};
  for (final binding in bindings) {
    final text = await settings.loadDeviceSetting(_lastRunKey(binding.id));
    lastRunTimes[binding.id] = text == null ? null : DateTime.tryParse(text);
  }
  return nextDueTime(bindings, lastRunTimes, now ?? DateTime.now());
}

/// Recomputes the next due time across every enabled, non-`app_launch`
/// scheduled binding and arms (or cancels, if nothing is due at all --
/// e.g. every binding was just disabled or deleted) exactly one alarm for
/// it. Called both from [scheduledEventAlarmCallback] itself (to arm the
/// *next* alarm right after handling the current one) and -- build order
/// step 4 -- from every place a binding's schedule could have changed
/// (`ScheduledEventsScreen`'s create/edit/delete/enable/disable actions,
/// its own remote-sync reload, and `HomeShell`'s app-launch bootstrap).
///
/// Safe to call from either the foreground app or this plugin's own
/// headless background isolate: `AndroidAlarmManager.initialize()` is
/// idempotent (confirmed both by the plugin's own README and the step 2
/// spike) and native already has the one callback dispatcher it needs
/// once any real app launch has ever called it -- this app's Android
/// bootstrap (`HomeShell`) is guaranteed to run before any background
/// alarm chain could exist in the first place, since scheduled events are
/// themselves created through the app's own UI.
Future<void> rescheduleNextAlarm({EventDefinitionsDao? events, ThemeSettingsDao? settings}) async {
  final eventsDao = events ?? EventDefinitionsDao();
  final settingsDao = settings ?? ThemeSettingsDao(deviceId: await DeviceId.resolve());

  final due = await computeNextDueTimeForDevice(events: eventsDao, settings: settingsDao);

  await AndroidAlarmManager.initialize();
  await _cancelLeftoverSpikeAlarm();
  if (due == null) {
    await AndroidAlarmManager.cancel(_scheduledEventsAlarmId);
    return;
  }

  // oneShotAt (an absolute time), not oneShot (a delay) -- due is already
  // the absolute moment nextDueTime computed; converting it to a delay
  // and back would just be an unnecessary round trip. A due time already
  // in the past (e.g. an overdue hourly binding) is fine -- AlarmManager
  // fires an alarm requested for the past as soon as possible, exactly
  // the desired "catch up" behavior, confirmed live during the step 2
  // reboot-survival test.
  await AndroidAlarmManager.oneShotAt(
    due,
    _scheduledEventsAlarmId,
    scheduledEventAlarmCallback,
    exact: false,
    allowWhileIdle: true,
    wakeup: true,
    rescheduleOnReboot: true,
  );
}

/// The alarm callback itself -- runs in the plugin's own separate,
/// headless isolate/engine, never the main app's, whether or not the app
/// is even running (same mechanics as `alarm_manager_spike.dart`'s now-
/// removed spike callback, which proved this pattern live on MIKE-12R,
/// including surviving a real reboot). Must stay a top-level function and
/// keep this `@pragma`, per the plugin's own requirement, otherwise AOT
/// tree-shaking removes it in a release/profile build.
///
/// **Real constraint, confirmed by reading the plugin's own Dart source,
/// not just assumed:** its callback dispatcher (`_alarmManagerCallbackDispatcher`
/// in `android_alarm_manager_plus`) invokes this closure without ever
/// awaiting its returned `Future` -- true whether this function is
/// declared `async` or not. So there is no way to make native code wait
/// for the real work below to finish; the fire-and-forget `Future<void>`
/// block is not a shortcut, it's the only shape available. This matches
/// the step 2 spike's own proven-live pattern (a real sqlite write
/// completed correctly both on a normal fire and a reboot-triggered one),
/// and this app's actual due-check/dispatch workload is similarly light
/// (a handful of SQL queries, plus whatever a bound script itself does --
/// already guarded against hanging forever by `ScriptApiRuntime`'s own
/// isolate-timeout wrapper, Phase 5's own safety mechanism). Worth
/// revisiting only if real-device verification (build order step 8) ever
/// shows a dispatch pass getting cut off mid-run.
@pragma('vm:entry-point')
void scheduledEventAlarmCallback() {
  Future<void>(() async {
    try {
      await BackgroundScheduleService().runDueScheduledEvents();
    } finally {
      // Always reschedule, even if the dispatch pass itself threw --
      // otherwise a single failed pass would silently end the entire
      // self-rescheduling chain right there, going quiet forever exactly
      // like a broken reconnect loop would. runDueScheduledEvents()
      // already records its own failure into bg_check:* before
      // rethrowing (see that method's own doc comment), so rescheduling
      // regardless doesn't hide anything from BackgroundProcessesScreen
      // -- the next fire will simply re-attempt whatever's still due.
      await rescheduleNextAlarm();
    }
  });
}
