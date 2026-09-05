import '../../db/event_definitions_dao.dart';
import '../../db/event_dispatch_service.dart';
import '../../db/script_definitions_dao.dart';
import '../../db/theme_settings_dao.dart';
import '../device_id.dart';
import 'recurrence.dart';
import 'script_notifications.dart';

/// Essentials v2 Phase 5 build order step 7 originally wired this class up
/// to a 15-minute `workmanager` periodic task -- see
/// claude/essentials-v2-phase5-design.md's own step 7 write-up for that
/// history. **That periodic-polling registration has since been replaced**
/// by the exact-time alarm chain in `alarm_schedule_service.dart` (see
/// claude/essentials-v2-alarm-scheduling-design.md) -- this class's own
/// due-check/dispatch logic is unchanged and still the thing that actually
/// runs, on both platforms, just triggered differently now:
/// [scheduledEventAlarmCallback] (Android, via `android_alarm_manager_plus`)
/// and [runWindowsBackgroundScheduleCheck] (Windows, via a Scheduled Task)
/// both call [runDueScheduledEvents] directly. `registerAlarmSafetyNetTask`/
/// `alarmSafetyNetDispatcherCallback` in `alarm_schedule_service.dart` are
/// the low-frequency `workmanager` task's new home -- it never calls this
/// class at all, only recomputes/re-arms the alarm (see that file's own
/// doc comment for why).
///
/// The actual "what's due, run it" logic -- kept as its own class so it's
/// directly unit-testable against the real `essentials.db` without needing
/// a real alarm/WorkManager fire (this project's own established
/// discipline for anything DB-backed -- see every `*_service_test.dart`
/// file since Phase 1).
class BackgroundScheduleService {
  BackgroundScheduleService({
    EventDefinitionsDao? events,
    EventDispatchService? dispatcher,
    ScriptDefinitionsDao? scripts,
    ThemeSettingsDao? settings,
    Future<void> Function(String message)? notify,
  }) : _events = events ?? EventDefinitionsDao(),
       _dispatcher = dispatcher ?? EventDispatchService(),
       _scripts = scripts ?? ScriptDefinitionsDao(),
       _settingsOverride = settings,
       // Injectable so tests can avoid touching the real
       // flutter_local_notifications platform channel -- that plugin has
       // no working implementation under a bare `flutter test` host
       // (confirmed live: `FlutterLocalNotificationsPlatform._instance`
       // is never set outside a real app/plugin-registered context, the
       // same category of test-harness limitation already documented for
       // flutter_js's native `quickjs_c_bridge.dll` -- see JsEngine's own
       // test file comment). Defaults to the real notification path for
       // every real (non-test) caller.
       _notify = notify ?? ScriptNotifications.instance.show;

  final EventDefinitionsDao _events;
  final EventDispatchService _dispatcher;
  final ScriptDefinitionsDao _scripts;
  final ThemeSettingsDao? _settingsOverride;
  final Future<void> Function(String message) _notify;

  Future<ThemeSettingsDao> get _settings async {
    final override = _settingsOverride;
    if (override != null) return override;
    return ThemeSettingsDao(deviceId: await DeviceId.resolve());
  }

  static String _lastRunKey(int eventDefinitionId) =>
      'schedule_last_run:$eventDefinitionId';

  /// `device_settings` keys ([ThemeSettingsDao.loadDeviceSetting]/
  /// [ThemeSettingsDao.setDeviceSetting]) this class records every pass
  /// into, regardless of platform -- both the in-app "Background
  /// Processes" screen ([BackgroundProcessesScreen]) and the Windows
  /// watchdog script read the same values, so what the UI shows and what
  /// trips the toast alarm can never silently disagree. Chosen over a new
  /// table specifically to avoid touching `SchemaEditorService`/
  /// `migration_log` for what's purely internal bookkeeping, never
  /// user-visible schema -- see this project's own hard-won caution
  /// around that pipeline (`MigrationService`'s halt-on-failure doc
  /// comment, and the incident `test/support/schema_test_cleanup.dart`
  /// documents).
  static const statusLastAttemptKey = 'bg_check:last_attempt_at';
  static const statusLastResultKey = 'bg_check:last_result';
  static const statusLastErrorKey = 'bg_check:last_error';
  static const statusLastSuccessAtKey = 'bg_check:last_success_at';
  static const statusConsecutiveFailuresKey = 'bg_check:consecutive_failures';
  static const statusLastAppliedCountKey = 'bg_check:last_applied_count';

  /// Checks every enabled scheduled (non-`app_launch`) binding, runs
  /// whichever ones are due, records their new last-run time, and posts a
  /// real OS notification for any `notify()` effect a script produced --
  /// there's no foreground `SnackBar` to show when the app isn't even
  /// running, which is the whole point of this class existing.
  ///
  /// Also records this pass's own outcome under the `statusLast*`/
  /// `statusConsecutiveFailuresKey` keys above -- best-effort (a status
  /// write failing must never be what makes a background check fail) and
  /// on the way out, not swallowed: a thrown exception here still
  /// propagates to the caller exactly as before, since
  /// `backgroundDispatcherCallback` depends on that to tell WorkManager
  /// to retry. Recording status is additive instrumentation, not a
  /// change to that contract.
  Future<void> runDueScheduledEvents() async {
    final settings = await _settings;
    final attemptedAt = DateTime.now().toUtc().toIso8601String();
    await _tryRecordStatus(settings, {statusLastAttemptKey: attemptedAt});

    try {
      final bindings = await _events.loadScheduled();
      final now = DateTime.now();
      var appliedCount = 0;
      for (final binding in bindings) {
        if (!binding.enabled) continue;
        if (binding.eventType == 'app_launch') continue;
        // A binding with no device selected is real but dormant -- never
        // fires anywhere, on any device -- and one with a real list only
        // fires on the device(s) actually in it. See
        // claude/essentials-v2-recurring-schedule-design.md's "Per-device
        // targeting" section for why: without this, a script's side
        // effects would silently multiply once per connected device.
        if (!binding.targetDevices.contains(settings.deviceId)) continue;

        final lastRunText = await settings.loadDeviceSetting(
          _lastRunKey(binding.id),
        );
        final lastRun = lastRunText == null
            ? null
            : DateTime.tryParse(lastRunText);
        if (!_isDue(binding, lastRun, now)) continue;

        if (lastRun != null)
          await _notifyIfOccurrencesWereMissed(binding, lastRun, now);

        // Exactly this one due binding's script -- not `_dispatcher
        // .dispatch()`, which matches broadly on (event_type, table_name,
        // field_name) and would run every other enabled schedule_interval
        // binding sharing that same tuple too (every one of them, since
        // table_name/field_name are always null for a schedule). See
        // EventDispatchService.runScript's own doc comment for the real,
        // live double-notification bug this replaced.
        final result = await _dispatcher.runScript(binding.scriptId);
        await settings.setDeviceSetting(
          _lastRunKey(binding.id),
          now.toIso8601String(),
        );
        appliedCount++;

        for (final message in result.effects.notifications) {
          await _tryNotify(message);
        }
        if (result.outcome.timedOut) {
          await _tryNotify('A scheduled script timed out.');
        } else if (result.outcome.error != null) {
          await _tryNotify('Scheduled script error: ${result.outcome.error}');
        }
      }

      await _tryRecordStatus(settings, {
        statusLastResultKey: 'ok',
        statusLastErrorKey: null,
        statusLastSuccessAtKey: attemptedAt,
        statusConsecutiveFailuresKey: '0',
        statusLastAppliedCountKey: '$appliedCount',
      });
    } catch (e) {
      final priorFailures =
          int.tryParse(
            await settings.loadDeviceSetting(statusConsecutiveFailuresKey) ??
                '0',
          ) ??
          0;
      await _tryRecordStatus(settings, {
        statusLastResultKey: 'error',
        statusLastErrorKey: e.toString(),
        statusConsecutiveFailuresKey: '${priorFailures + 1}',
      });
      rethrow;
    }
  }

  /// Swallows its own failures on purpose -- see [runDueScheduledEvents]'s
  /// doc comment. A `null` value deletes that key
  /// ([ThemeSettingsDao.setDeviceSetting]'s own convention), used here for
  /// [statusLastErrorKey] on a successful pass.
  Future<void> _tryRecordStatus(
    ThemeSettingsDao settings,
    Map<String, String?> values,
  ) async {
    try {
      for (final entry in values.entries) {
        await settings.setDeviceSetting(entry.key, entry.value);
      }
    } catch (_) {
      // Same posture as _tryNotify -- status bookkeeping is best-effort.
    }
  }

  /// Wraps [_notify] so a real notification-delivery failure (e.g. the
  /// exact `WindowsInitializationSettings` gap found live -- see
  /// `ScriptNotifications`' own doc comment) can never abort processing
  /// of the *rest* of this run's due bindings -- their last-run
  /// timestamps and any real database writes their own scripts made
  /// already succeeded above; only the notification itself is best-effort.
  Future<void> _tryNotify(String message) async {
    try {
      await _notify(message);
    } catch (_) {
      // Nothing to report to -- same posture as runWindowsBackgroundScheduleCheck's
      // own catch-all.
    }
  }

  /// Due-checking logic, kept deliberately simple given the alarm chain's
  /// own inexactness -- "exact time" was never on the table
  /// (`ScheduledEventsScreen`'s own copy already says "approximately").
  /// Shares its actual recurrence math with [nextDueTime] via
  /// `recurrence.dart` -- see claude/essentials-v2-recurring-schedule
  /// -design.md for why `schedule_hourly`/`schedule_daily`/
  /// `schedule_weekly`'s old three-way duplicated logic was retired for
  /// one generic `schedule_interval` type. A binding with no/malformed
  /// `scheduleConfig` is treated as due -- same permissive fallback every
  /// schedule type here has always used for a bad config, rather than
  /// silently never firing.
  bool _isDue(EventDefinition binding, DateTime? lastRun, DateTime now) {
    if (binding.eventType != 'schedule_interval') return false;

    final recurrence = parseRecurrenceConfig(binding.scheduleConfig);
    if (recurrence == null) return true;

    final anchor = recurrence.anchor;
    if (anchor == null) {
      return lastRun == null || now.difference(lastRun) >= recurrence.interval;
    }
    if (now.isBefore(anchor)) return false;
    final currentSlot = anchorAlignedSlotAtOrBefore(
      anchor,
      recurrence.interval,
      now,
    );
    return lastRun == null || lastRun.isBefore(currentSlot);
  }

  /// If [binding] is anchored and fell behind by more than one occurrence
  /// since [lastRun] -- e.g. the app was closed/force-stopped for a
  /// while -- [_isDue] above already jumped straight to the current slot
  /// rather than chain-firing through everything missed in between (see
  /// `recurrence.dart`'s own doc comment on why). Mike's explicit ask:
  /// that silent skip should never be silent -- post a real notification
  /// naming the script and how many occurrences it missed, right before
  /// running the one that's actually about to happen. Best-effort, same
  /// as every other notification this class posts -- a failure here must
  /// never block the real dispatch that follows.
  Future<void> _notifyIfOccurrencesWereMissed(
    EventDefinition binding,
    DateTime lastRun,
    DateTime now,
  ) async {
    if (binding.eventType != 'schedule_interval') return;
    final recurrence = parseRecurrenceConfig(binding.scheduleConfig);
    final anchor = recurrence?.anchor;
    if (anchor == null)
      return; // unanchored schedules have no fixed slots to miss

    final missed = missedOccurrenceCount(
      anchor,
      recurrence!.interval,
      lastRun,
      now,
    );
    if (missed <= 0) return;

    final scriptName =
        await _scripts.loadName(binding.scriptId) ?? 'a scheduled script';
    final occurrenceWord = missed == 1 ? 'occurrence' : 'occurrences';
    await _tryNotify(
      '"$scriptName" fell behind schedule -- skipped $missed missed $occurrenceWord and caught up to now.',
    );
  }
}
