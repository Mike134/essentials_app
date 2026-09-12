import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../models/table_config.dart';
import '../util/bool_value.dart';
import '../util/device_id.dart';
import '../util/lookup_value.dart';
import '../util/scheduling/recurrence_when.dart';
import '../util/scheduling/recurring_reminder_fields.dart';
import '../util/sql_identifiers.dart';
import 'database_helper.dart';
import 'generic_dao.dart';
import 'schema_registry.dart';
import 'theme_settings_dao.dart';

/// Essentials v2 Agenda scheduling (see
/// claude/essentials-v2-agenda-scheduling-design.md) -- scans every table
/// with a [RecurringReminderFields] group for rows where Notify is on,
/// computes each one's real recurring occurrence via `recurrence_when
/// .dart`, and fires a genuine background notification the first time
/// "now" reaches (occurrence - Remind minutes). Deliberately its own
/// class, not folded into [BackgroundScheduleService] directly (that class
/// still owns *calling* this one, from [checkAndFireDueReminders]) --
/// this is a fundamentally different shape of "what's due" (per-row table
/// data, not a fixed set of `event_definitions` bindings) and benefits
/// from being independently testable the same way `LinkedFieldService`/
/// `FormulaService` are.
///
/// A table qualifies purely by field-name convention (see
/// `recurring_reminder_fields.dart`'s own doc comment) -- there is
/// deliberately no hardcoded "agenda" table name anywhere in this class,
/// so any future table shaped the same way gets the feature automatically,
/// the same way Geo Location works for any table with those four field
/// names, not just one Mike happened to build it for first.
class RecurringReminderService {
  RecurringReminderService({SchemaRegistry? registry, this._settingsOverride, this._onlyTables})
    : _registry = registry ?? SchemaRegistry();

  final SchemaRegistry _registry;
  final ThemeSettingsDao? _settingsOverride;

  /// Restricts scanning to exactly these table names when non-null --
  /// real callers (the background service, the alarm-arming computation)
  /// always leave this `null` (scan every table, the whole point of the
  /// field-name-convention design). Exists so tests can isolate themselves
  /// from whatever real, live data Mike's own Agenda table happens to hold
  /// at the moment a test runs -- this class deliberately scans the whole
  /// database, so an unscoped test would otherwise get real production
  /// rows mixed into its own counts/notifications.
  final List<String>? _onlyTables;

  Future<ThemeSettingsDao> get _settings async {
    final override = _settingsOverride;
    if (override != null) return override;
    return ThemeSettingsDao(deviceId: await DeviceId.resolve());
  }

  Future<SqliteCrdt> get _crdt async => DatabaseHelper.instance.crdt;

  /// `device_settings` key recording the last occurrence (its own computed
  /// `DateTime`, ISO8601) this device has already notified for -- per row,
  /// per device, same "device_settings is where per-device bookkeeping
  /// lives" convention as `schedule_last_run:<id>` above. Absence means
  /// "never notified for this row" -- the row's very first occurrence is
  /// still eligible.
  static String _lastFiredKey(String tableName, int rowId) =>
      'agenda_reminder_last_fired:$tableName:$rowId';

  /// Every currently-qualifying (Notify = on) row across every table with a
  /// [RecurringReminderFields] group -- the shared enumeration both
  /// [nextDueFireTime] and [checkAndFireDueReminders] scan. A table whose
  /// metadata has drifted from its physical schema
  /// ([SchemaValidationException]) is skipped, same posture
  /// `table_registry.dart` already takes for the real nav -- one broken
  /// table should never block reminders for every other one.
  Future<List<_QualifyingRow>> _loadQualifyingRows() async {
    final result = <_QualifyingRow>[];
    final onlyTables = _onlyTables;
    for (final tableName in await _registry.discoverTableNames()) {
      if (onlyTables != null && !onlyTables.contains(tableName)) continue;
      final TableConfig config;
      try {
        config = await _registry.buildConfig(tableName);
      } on SchemaValidationException {
        continue;
      }
      final fields = recurringReminderFieldsOf(config.fields);
      if (fields == null) continue;

      final rows = await GenericDao(config).getAll();
      for (final row in rows) {
        if (!coerceBoolValue(row[fields.notify.column])) continue;
        final id = row['id'];
        if (id is! int) continue; // never omitted in practice; defensive
        result.add(
          _QualifyingRow(tableName: tableName, config: config, fields: fields, row: row, id: id),
        );
      }
    }
    return result;
  }

  /// Resolves the linked/inline-select Timeframe field's current value to
  /// its lowercased display keyword (e.g. `"weekly"`) -- `null` if unset,
  /// unresolvable (a stale id, a soft-deleted lookup row), or the field
  /// isn't a recognized shape. Mirrors `GenericFormScreen`'s own
  /// `_lookupValues`/`_inlineSelectValues` resolution, just against a
  /// plain row map instead of live form state.
  Future<String?> _resolveTimeframeKeyword(FieldConfig timeframeField, Object? rawValue) async {
    if (timeframeField.isInlineSelect) {
      final key = rawValue as String?;
      if (key == null || key.isEmpty) return null;
      for (final option in timeframeField.inlineOptions!) {
        if (option.key == key) return option.label.trim().toLowerCase();
      }
      return null;
    }
    final lookup = timeframeField.lookup;
    if (lookup == null) return null;
    final id = parseLookupValue(rawValue);
    if (id == null) return null;
    if (!isSafeSqlIdentifier(lookup.table) || !isSafeSqlIdentifier(lookup.displayColumn)) return null;

    final crdt = await _crdt;
    final rows = await crdt.query(
      'SELECT "${lookup.displayColumn}" AS display_value FROM "${lookup.table}" '
      'WHERE id = ?1 AND is_deleted = 0',
      [id],
    );
    if (rows.isEmpty) return null;
    final value = rows.first['display_value'];
    return value?.toString().trim().toLowerCase();
  }

  /// Combines the row's own "Remind" value with its "Remind Unit" choice
  /// into a real fire time -- Mike's own real complaint about the old,
  /// minutes-only field ("if you wanted to be notified a week in advance,
  /// not everyone would know to multiply 1440 x 7... I would have to get
  /// out a calculator"). Minute/Hour/Day are exact `Duration` subtraction
  /// -- unambiguous, no calendar involved. Month/Year deliberately do
  /// **not** approximate via a fixed day count (a month isn't a fixed
  /// number of minutes) -- they subtract real calendar units from
  /// [occurrence] instead (`DateTime(occurrence.year, occurrence.month -
  /// value, ...)`), matching what "1 month before" actually means to a
  /// person. Dart's `DateTime` constructor normalizes an out-of-range
  /// month by rolling into the correct prior year on its own (no manual
  /// borrow needed here) -- the one inherent ambiguity this can't remove
  /// is a day-of-month that doesn't exist in the target month (e.g. "1
  /// month before" a March 31st occurrence), which every real calendar
  /// tool shares and Dart's own normalization resolves by rolling forward
  /// into the following month, same as most calendar apps.
  ///
  /// [remindUnit] absent, blank, or holding an unrecognized key all fall
  /// back to plain minutes -- identical to this feature's original,
  /// unit-less behavior, so a table that never adds a "Remind Unit" field
  /// (or a row that hasn't picked one yet) keeps working exactly as
  /// before.
  DateTime _fireTimeFor(_QualifyingRow q, DateTime occurrence) {
    final field = q.fields.remindMinutes;
    final raw = field == null ? null : q.row[field.column];
    final value = raw == null ? 0 : (int.tryParse(raw.toString()) ?? 0);
    if (value == 0) return occurrence;

    final unitField = q.fields.remindUnit;
    final unit = unitField == null ? null : q.row[unitField.column]?.toString();
    switch (unit) {
      case 'hour':
        return occurrence.subtract(Duration(hours: value));
      case 'day':
        return occurrence.subtract(Duration(days: value));
      case 'month':
        return DateTime(
          occurrence.year,
          occurrence.month - value,
          occurrence.day,
          occurrence.hour,
          occurrence.minute,
          occurrence.second,
        );
      case 'year':
        return DateTime(
          occurrence.year - value,
          occurrence.month,
          occurrence.day,
          occurrence.hour,
          occurrence.minute,
          occurrence.second,
        );
      case 'minute':
      default:
        return occurrence.subtract(Duration(minutes: value));
    }
  }

  /// The column whose value should actually name a row in a notification
  /// -- [TableConfig.displayColumn] itself isn't reliable for this: it
  /// falls back to the bare `id` column whenever `table_definitions
  /// .display_field` is unset, which is every real v2 table today (no UI
  /// has ever set it -- see `GenericDao.getReverseLinks`'s own doc comment
  /// for the identical gap already found and fixed there). Same fallback
  /// that fix already established: the table's first real field by
  /// position, e.g. Agenda's "Activity" -- far more useful in a
  /// notification than a raw ~16-digit id. Falls back to `id` itself only
  /// for a table with no fields at all.
  String _titleColumnFor(TableConfig config) {
    if (config.displayColumn != 'id') return config.displayColumn;
    return config.fields.isNotEmpty ? config.fields.first.column : 'id';
  }

  /// Finds the smallest occurrence of the *current* Start/Timeframe/When
  /// combination that's still strictly after [lastFired] -- **not** simply
  /// `nextOccurrenceAfter(after: lastFired)`, which assumes [lastFired] is
  /// itself a real occurrence of the exact same Start value. That
  /// assumption breaks the moment a record's Start is edited after it's
  /// already fired once: real bug, found live -- editing an already-fired
  /// "once" record's Start to a new future time never fired again, because
  /// `nextOccurrenceAfter('once', after: non-null)` always returns `null`
  /// (a `once` timeframe assumes there's nothing left to compute once its
  /// single occurrence has been consumed) -- with no way to tell "this
  /// *is* that same already-fired occurrence" apart from "Start changed
  /// entirely since then."
  ///
  /// Correct approach: always start from this row's own first occurrence
  /// under its *current* Start/rule ([after]: `null`), then walk forward
  /// only as far as needed to get past [lastFired]. If Start moved
  /// forward, the very first occurrence is already past `lastFired` and is
  /// returned immediately -- a genuinely new occurrence, correctly
  /// eligible to fire again. If Start/rule haven't changed, this walks the
  /// same sequence [lastFired] was already found in and reproduces the
  /// original (correct) "next occurrence after last fired" behavior.
  /// Capped at 100,000 steps as a defensive bound against a pathological
  /// config looping forever (never expected in practice).
  DateTime? _nextUnfiredOccurrence({
    required DateTime start,
    required String? timeframeKeyword,
    required RecurrenceWhenRule? rule,
    required DateTime? lastFired,
  }) {
    var occurrence = nextOccurrenceAfter(start: start, timeframeKeyword: timeframeKeyword, rule: rule);
    if (occurrence == null) return null;
    if (lastFired == null) return occurrence;

    var steps = 0;
    while (!occurrence!.isAfter(lastFired) && steps < 100000) {
      occurrence = nextOccurrenceAfter(
        start: start,
        timeframeKeyword: timeframeKeyword,
        rule: rule,
        after: occurrence,
      );
      if (occurrence == null) return null;
      steps++;
    }
    return occurrence;
  }

  /// The next fire time (occurrence minus Remind minutes) this row hasn't
  /// already been notified for -- `null` if the row has no more
  /// occurrences (`once`, already past, and Start hasn't changed since) or
  /// its Start/Timeframe can't be resolved at all. Used both to arm the
  /// next alarm ([nextDueFireTime]) and to decide whether a row is
  /// actually due right now ([_dueOccurrenceToFire]).
  Future<({DateTime occurrence, DateTime fireTime})?> _nextFireFor(
    ThemeSettingsDao settings,
    _QualifyingRow q,
  ) async {
    final start = DateTime.tryParse(q.row[q.fields.start.column]?.toString() ?? '');
    if (start == null) return null;

    final keyword = await _resolveTimeframeKeyword(q.fields.timeframe, q.row[q.fields.timeframe.column]);
    final rule = RecurrenceWhenRule.decode(q.row[q.fields.when.column]?.toString());

    final lastFiredText = await settings.loadDeviceSetting(_lastFiredKey(q.tableName, q.id));
    final lastFired = lastFiredText == null ? null : DateTime.tryParse(lastFiredText);

    final occurrence = _nextUnfiredOccurrence(
      start: start,
      timeframeKeyword: keyword,
      rule: rule,
      lastFired: lastFired,
    );
    if (occurrence == null) return null;
    return (occurrence: occurrence, fireTime: _fireTimeFor(q, occurrence));
  }

  /// The earliest upcoming (or already-overdue) fire time across every
  /// qualifying row on this device -- feeds
  /// `alarm_schedule_service.dart`'s [computeNextDueTimeForDevice] so
  /// Android's exact-alarm chain actually wakes up for an Agenda reminder,
  /// not just for `event_definitions` scheduled scripts. `null` when
  /// nothing qualifies at all. Deliberately takes no `now` -- each row's
  /// next fire time is always its own earliest un-fired occurrence
  /// (tracked via [_lastFiredKey]), which can validly already be in the
  /// past (meaning "already due"); an alarm scheduler is expected to fire
  /// immediately for a past due time, same posture `nextDueTime` already
  /// takes for `event_definitions` bindings.
  Future<DateTime?> nextDueFireTime() async {
    final settings = await _settings;
    DateTime? earliest;
    for (final q in await _loadQualifyingRows()) {
      final next = await _nextFireFor(settings, q);
      if (next == null) continue;
      if (earliest == null || next.fireTime.isBefore(earliest)) earliest = next.fireTime;
    }
    return earliest;
  }

  /// If [q] has an occurrence whose fire time has already passed [now] and
  /// hasn't been notified for yet, returns it -- catching up to the single
  /// most-recent overdue occurrence if more than one was missed (a device
  /// left off for days doesn't chain-fire every skipped occurrence, same
  /// "jump to current" posture `BackgroundScheduleService._isDue` already
  /// takes for scheduled scripts), capped at 10,000 steps as a defensive
  /// bound against a pathological config looping forever (never expected
  /// in practice -- every real recurrence here advances by at least an
  /// hour per step).
  Future<DateTime?> _dueOccurrenceToFire(ThemeSettingsDao settings, _QualifyingRow q, DateTime now) async {
    var next = await _nextFireFor(settings, q);
    if (next == null || next.fireTime.isAfter(now)) return null;

    var due = next.occurrence;
    var steps = 0;
    while (steps < 10000) {
      final start = DateTime.tryParse(q.row[q.fields.start.column]?.toString() ?? '');
      if (start == null) break;
      final keyword = await _resolveTimeframeKeyword(q.fields.timeframe, q.row[q.fields.timeframe.column]);
      final rule = RecurrenceWhenRule.decode(q.row[q.fields.when.column]?.toString());
      final following = nextOccurrenceAfter(start: start, timeframeKeyword: keyword, rule: rule, after: due);
      if (following == null) break;
      final followingFireTime = _fireTimeFor(q, following);
      if (followingFireTime.isAfter(now)) break;
      due = following;
      steps++;
    }
    return due;
  }

  /// Fires (via [notify]) and records every row whose next occurrence is
  /// due as of [now], returning how many were fired -- called from
  /// [BackgroundScheduleService.runDueScheduledEvents] on both platforms
  /// (Windows' 1-minute poll and Android's alarm chain alike), so no
  /// separate background trigger was needed for this feature.
  Future<int> checkAndFireDueReminders({
    DateTime? now,
    required Future<void> Function(String message) notify,
  }) async {
    final settings = await _settings;
    final reference = now ?? DateTime.now();
    var fired = 0;
    for (final q in await _loadQualifyingRows()) {
      final due = await _dueOccurrenceToFire(settings, q, reference);
      if (due == null) continue;

      final title = q.row[_titleColumnFor(q.config)]?.toString();
      final label = (title == null || title.trim().isEmpty) ? q.config.displayName : title.trim();
      await notify('${q.config.displayName}: $label');
      await settings.setDeviceSetting(_lastFiredKey(q.tableName, q.id), due.toIso8601String());
      fired++;
    }
    return fired;
  }
}

class _QualifyingRow {
  const _QualifyingRow({
    required this.tableName,
    required this.config,
    required this.fields,
    required this.row,
    required this.id,
  });

  final String tableName;
  final TableConfig config;
  final RecurringReminderFields fields;
  final Map<String, Object?> row;
  final int id;
}
