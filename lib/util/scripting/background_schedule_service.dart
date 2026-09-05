import 'dart:convert';

import '../../db/event_definitions_dao.dart';
import '../../db/event_dispatch_service.dart';
import '../../db/theme_settings_dao.dart';
import '../device_id.dart';
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
    ThemeSettingsDao? settings,
    Future<void> Function(String message)? notify,
  }) : _events = events ?? EventDefinitionsDao(),
       _dispatcher = dispatcher ?? EventDispatchService(),
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
  final ThemeSettingsDao? _settingsOverride;
  final Future<void> Function(String message) _notify;

  Future<ThemeSettingsDao> get _settings async {
    final override = _settingsOverride;
    if (override != null) return override;
    return ThemeSettingsDao(deviceId: await DeviceId.resolve());
  }

  static String _lastRunKey(int eventDefinitionId) => 'schedule_last_run:$eventDefinitionId';

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

        final lastRunText = await settings.loadDeviceSetting(_lastRunKey(binding.id));
        final lastRun = lastRunText == null ? null : DateTime.tryParse(lastRunText);
        if (!_isDue(binding, lastRun, now)) continue;

        final results = await _dispatcher.dispatch(tableName: null, eventType: binding.eventType);
        await settings.setDeviceSetting(_lastRunKey(binding.id), now.toIso8601String());
        appliedCount++;

        for (final result in results) {
          for (final message in result.effects.notifications) {
            await _tryNotify(message);
          }
          if (result.outcome.timedOut) {
            await _tryNotify('A scheduled script timed out.');
          } else if (result.outcome.error != null) {
            await _tryNotify('Scheduled script error: ${result.outcome.error}');
          }
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
      final priorFailures = int.tryParse(await settings.loadDeviceSetting(statusConsecutiveFailuresKey) ?? '0') ?? 0;
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
  Future<void> _tryRecordStatus(ThemeSettingsDao settings, Map<String, String?> values) async {
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

  /// Due-checking logic, kept deliberately simple given WorkManager's own
  /// ~15-minute batching floor -- "exact time" was never on the table
  /// (`ScheduledEventsScreen`'s own copy already says "approximately").
  /// `hourly` just needs 60 real minutes to have elapsed. `daily`/`weekly`
  /// additionally honor the time-of-day (and, for weekly, the day of
  /// week) already collected by `ScheduledEventsScreen`'s own dialog --
  /// otherwise that config would sit stored and silently unused forever,
  /// the exact gap this build step exists to close. A binding with no
  /// `scheduleConfig` (created before this logic existed, or the
  /// `schedule_hourly` type, which never has one) degrades to a plain
  /// elapsed-time check.
  bool _isDue(EventDefinition binding, DateTime? lastRun, DateTime now) {
    switch (binding.eventType) {
      case 'schedule_hourly':
        return lastRun == null || now.difference(lastRun) >= const Duration(hours: 1);
      case 'schedule_daily':
        if (_alreadyRanToday(lastRun, now)) return false;
        return _pastConfiguredTime(binding.scheduleConfig, now);
      case 'schedule_weekly':
        if (_alreadyRanThisWeek(lastRun, now)) return false;
        if (!_matchesConfiguredWeekday(binding.scheduleConfig, now)) return false;
        return _pastConfiguredTime(binding.scheduleConfig, now);
      default:
        return false;
    }
  }

  bool _alreadyRanToday(DateTime? lastRun, DateTime now) =>
      lastRun != null && lastRun.year == now.year && lastRun.month == now.month && lastRun.day == now.day;

  bool _alreadyRanThisWeek(DateTime? lastRun, DateTime now) {
    if (lastRun == null) return false;
    final lastRunWeekStart = lastRun.subtract(Duration(days: lastRun.weekday - 1));
    final nowWeekStart = now.subtract(Duration(days: now.weekday - 1));
    return lastRunWeekStart.year == nowWeekStart.year &&
        lastRunWeekStart.month == nowWeekStart.month &&
        lastRunWeekStart.day == nowWeekStart.day;
  }

  static const _weekdayKeys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

  bool _matchesConfiguredWeekday(String? scheduleConfig, DateTime now) {
    final config = _decodeConfig(scheduleConfig);
    final day = config?['day'] as String?;
    if (day == null) return true; // unconfigured -- run whichever day it happens to first become due
    final index = _weekdayKeys.indexOf(day);
    if (index == -1) return true;
    return now.weekday == index + 1; // DateTime.weekday is 1=Monday..7=Sunday, matching _weekdayKeys' order
  }

  bool _pastConfiguredTime(String? scheduleConfig, DateTime now) {
    final config = _decodeConfig(scheduleConfig);
    final timeText = config?['time'] as String?;
    if (timeText == null) return true; // unconfigured -- any time of day is fine
    final parts = timeText.split(':');
    if (parts.length != 2) return true;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return true;
    final target = DateTime(now.year, now.month, now.day, hour, minute);
    return !now.isBefore(target);
  }

  Map<String, Object?>? _decodeConfig(String? scheduleConfig) {
    if (scheduleConfig == null) return null;
    try {
      return jsonDecode(scheduleConfig) as Map<String, Object?>;
    } catch (_) {
      return null;
    }
  }
}
