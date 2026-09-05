import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:workmanager/workmanager.dart';

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
String _lastRunKey(int eventDefinitionId) =>
    'schedule_last_run:$eventDefinitionId';

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
  // A binding this device isn't targeted at should never arm an alarm
  // here -- same device-targeting rule `BackgroundScheduleService
  // .runDueScheduledEvents` enforces at dispatch time, applied one layer
  // earlier so this device doesn't even wake up for it.
  final bindings = (await events.loadScheduled())
      .where((b) => b.targetDevices.contains(settings.deviceId))
      .toList();
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
Future<void> rescheduleNextAlarm({
  EventDefinitionsDao? events,
  ThemeSettingsDao? settings,
}) async {
  final eventsDao = events ?? EventDefinitionsDao();
  final settingsDao =
      settings ?? ThemeSettingsDao(deviceId: await DeviceId.resolve());

  final due = await computeNextDueTimeForDevice(
    events: eventsDao,
    settings: settingsDao,
  );

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
  //
  // alarmClock (AlarmManagerCompat.setAlarmClock), not exact
  // (setExactAndAllowWhileIdle) -- a real, live-confirmed escalation, not
  // the first fix attempted. First switched from a hardcoded exact=false
  // to a granted-status-checked exact=true after live testing showed
  // ColorOS batching an inexact alarm by several minutes -- fine for
  // hourly+ schedules, a real problem once schedule_interval allows
  // intervals as short as 5 minutes. That still wasn't enough: even a
  // genuinely exact alarm using setExactAndAllowWhileIdle is subject to
  // Android's own OS-level anti-abuse throttle (undocumented in this
  // plugin, but real -- AlarmManager's own platform docs: no more than
  // once every ~9 minutes per app, with OEM skins like ColorOS often
  // layering their own standby-bucket restrictions on top), confirmed
  // live: an 11-minute schedule_interval binding still drifted several
  // minutes late even with exact=true and the permission genuinely
  // granted (confirmed via a temporary debug print). `setAlarmClock` is
  // the one alarm type Android fully exempts from Doze/standby-bucket
  // throttling -- genuinely to-the-second, no OS-imposed minimum gap --
  // at the cost of a small, permanent status-bar "alarm" icon while one
  // is armed and somewhat higher battery use than the other two options.
  // Mike's own call, made knowingly: acceptable given short (<30 minute)
  // schedules are expected to be rare and short-lived (a couple hours at
  // most), not a permanent fixture.
  //
  // Same permission gate as before either way -- the native side checks
  // `AlarmManager.canScheduleExactAlarms()` for alarmClock too, not just
  // plain exact (confirmed by reading AlarmService.java). Checking the
  // real granted status live and falling back to the old inexact
  // behavior when it isn't means a device that hasn't granted the
  // permission yet (or ever revokes it) degrades gracefully instead of
  // AlarmService.java silently no-op'ing the schedule call (confirmed by
  // reading its native source: a missing permission there just logs an
  // error and returns -- it does NOT throw back to Dart, contrary to
  // this plugin's own Dart-side doc comment).
  final canScheduleExact = await Permission.scheduleExactAlarm.isGranted;
  await AndroidAlarmManager.oneShotAt(
    due,
    _scheduledEventsAlarmId,
    scheduledEventAlarmCallback,
    alarmClock: canScheduleExact,
    exact: canScheduleExact,
    allowWhileIdle: true,
    wakeup: true,
    rescheduleOnReboot: true,
  );
}

/// One-time request for the `SCHEDULE_EXACT_ALARM` permission -- see this
/// file's own manifest comment for why exact timing is now wanted.
/// `Permission.scheduleExactAlarm.request()` doesn't show a normal
/// Allow/Deny runtime dialog for this particular permission (Android's own
/// design, not a permission_handler quirk) -- it takes the user straight to
/// the system "Alarms & reminders" special-app-access settings screen,
/// where the grant is a persistent device setting, not something re-asked
/// on every launch. Safe to call unconditionally on every bootstrap: a
/// no-op once already granted (`request()` only actually opens the screen
/// when the status isn't already granted), same idempotent-call posture as
/// every other bootstrap permission check in this app.
Future<void> ensureExactAlarmPermission() async {
  final status = await Permission.scheduleExactAlarm.status;
  if (!status.isGranted) {
    await Permission.scheduleExactAlarm.request();
  }
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

/// Build order step 6 -- the low-frequency `workmanager` safety net this
/// design's own "Safety net" section calls for. If the alarm-rescheduling
/// chain above ever silently breaks (a bug in the reschedule-on-fire step,
/// a missed reboot re-registration edge case, an aggressive OEM background
/// restriction eating the alarm broadcast -- MIKE-12R's ColorOS has
/// already fought this app's background execution more than once, per
/// CLAUDE.md's own history), there would be no periodic check left at all
/// to notice and recover. This task exists purely as that backstop.
///
/// **This is the replacement for [BackgroundScheduleService]'s old
/// 15-minute `workmanager` registration**, not a second, additional
/// periodic task -- [registerAlarmSafetyNetTask] cancels that old
/// registration by its unique name before registering this one, so the
/// two mechanisms never run side-by-side (the design doc's own
/// "Migration / coexistence" section, folded into this step rather than
/// left as a separate one: leaving the old chatty task running alongside
/// this one would defeat the entire point of building it -- reducing how
/// often Android boots a full `FlutterEngine` just to check for due work).
const _safetyNetUniqueWorkName = 'essentials_alarm_safety_net';
const _safetyNetTaskName = 'check_alarm_safety_net';

/// The unique name the now-retired 15-minute `BackgroundScheduleService`
/// task was registered under (see that file's own history) -- kept here,
/// not there, since this is the one place still doing anything with
/// `workmanager`'s unique-name bookkeeping. Cancelling by name is safe to
/// call even on a device that never had it registered (a device installed
/// fresh after this change) -- `workmanager`'s own `cancelByUniqueName` is
/// documented as a no-op when nothing matches.
const _legacyPollingUniqueWorkName = 'essentials_scheduled_events';

/// Deliberately does **not** run [BackgroundScheduleService
/// .runDueScheduledEvents] -- the design doc's own "Safety net" section is
/// explicit that this task's engine-boot cost must stay both minimal and
/// rare, and the real due-check/dispatch work already happens through the
/// alarm chain above. All this does is recompute the next due time and
/// re-arm (or cancel) exactly one alarm -- [rescheduleNextAlarm] is safe
/// and cheap to call unconditionally regardless of whether an alarm is
/// already correctly armed (recomputing an already-correct answer is a
/// harmless no-op), which is simpler than first checking whether one is
/// currently scheduled and only recomputing if not, for the same
/// end result.
@pragma('vm:entry-point')
void alarmSafetyNetDispatcherCallback() {
  Workmanager().executeTask((taskName, inputData) async {
    try {
      await rescheduleNextAlarm();
      return true;
    } catch (_) {
      // Same retry-on-failure posture as the old dispatch task -- a
      // transient failure (e.g. the db momentarily locked by a concurrent
      // foreground write) should retry, not permanently give up.
      return false;
    }
  });
}

/// Registers (or re-registers, idempotently) the low-frequency safety-net
/// task, and cancels the old 15-minute polling task if it's still
/// registered on this device (build order step 7, folded into this call
/// rather than a separate one -- see [_safetyNetUniqueWorkName]'s own doc
/// comment for why). 12 hours is this design doc's own proposed frequency
/// -- "6-24 hours, open to adjustment" -- picked as a reasonable middle
/// ground; Android enforces a 15-minute floor on `frequency` regardless,
/// so nothing here is anywhere near being silently clamped.
Future<void> registerAlarmSafetyNetTask() async {
  await Workmanager().initialize(alarmSafetyNetDispatcherCallback);
  await Workmanager().cancelByUniqueName(_legacyPollingUniqueWorkName);
  await Workmanager().registerPeriodicTask(
    _safetyNetUniqueWorkName,
    _safetyNetTaskName,
    frequency: const Duration(hours: 12),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}
