# Agenda scheduling — design (2026-09-12)

Mike's real `Agenda` table (built earlier as a live test bed for the
Calendar/scripting phases) is meant to become his actual TickTick
replacement. The table itself ("the current field setup works well")
needed one real gap fixed: a genuine recurrence engine for the "When"
field (previously mis-named "Period" — Mike's own words: "I had renamed
the When field to Period"), plus real, gated, recurring notifications.

## Confirmed decisions (from a short clarifying round before building)

1. **Both calendar display and real recurring notifications** — but a
   notification only ever fires for a record where a new **Notify**
   (boolean) field is on. "If and only if."
2. **"Period" is renamed to "When"** — same physical column
   (`period` — physical identifiers are immutable in this app's
   architecture), only the display label and its actual behavior change.
3. **Weekly recurrence is one weekday per record**, not a multi-select —
   need more than one day, make more than one record.
4. **Monthly recurrence needs all three real patterns**: a fixed day of
   month (clamped for shorter months), the last day of the month, and a
   weekday position ("2nd Tuesday", "last Friday").
5. **Notification lead time is configurable per record** — a new
   **Remind (Minutes Before)** integer field. Blank/absent means 0 (fire
   exactly at the occurrence).

## Field-name convention, not a new schema concept

Exactly like Geo Location (`lib/util/geo_location.dart`) and Map Location
before it: a table qualifies for recurring reminders purely by having
five fields with these exact display labels (case-insensitive), detected
by `lib/util/scheduling/recurring_reminder_fields.dart`'s
`recurringReminderFieldsOf`:

| Label | Format | Required |
|---|---|---|
| Start | `dateTime` | required |
| Timeframe | linked `select` or inline `select`, resolving to `once`/`hourly`/`daily`/`weekly`/`monthly`/`yearly` | required |
| When | `text` | required |
| Notify | `boolean` | required |
| Remind (Minutes Before) | `integer` | optional — absent means "always 0 lead time" |

No hardcoded `"agenda"` table name exists anywhere in this feature — any
future table shaped the same way gets recurring reminders automatically,
the same way Geo Location works for any table with those four field
names.

## The "When" field's storage shape

Still a plain `TEXT` column (every v2 field is), holding a small tagged
JSON object — `lib/util/scheduling/recurrence_when.dart`'s
`RecurrenceWhenRule`:

```
Weekly:  {"weekday": 1..7}                              (1=Mon..7=Sun, matches DateTime.weekday)
Monthly: {"monthlyKind":"day_of_month","dayOfMonth":1..31}
         {"monthlyKind":"last_day"}
         {"monthlyKind":"nth_weekday","nth":1..4|-1,"nthWeekday":1..7}
Daily/Yearly/Hourly/Once: blank -- ignored entirely
```

`nth` is capped at 1-4 plus `-1` for "Last" — deliberately never a literal
5, since a weekday occurs 4 or 5 times in a month depending on the month;
"Last" already covers the unreliable 5th-occurrence case reliably (a
weekday's last occurrence in a month always exists).

The rule object carries *every* possible field at once, not just the
active pattern's — lets the form widget remember a previously-chosen
weekday even while Timeframe is switched to Monthly and back.

## The recurrence math (`recurrence_when.dart`)

`nextOccurrenceAfter({start, timeframeKeyword, rule, after})` — pure,
heavily tested (`test/recurrence_when_test.dart`, 20 tests including an
exhaustive brute-force cross-check of every nth-weekday/month/weekday
combination). `after: null` returns the very first occurrence (at or
after `start`); a non-null `after` returns the next one following it.
`null` overall means "no more occurrences" (`once`, past its single
occurrence) or an unrecognized/blank Timeframe.

Every occurrence keeps `start`'s own hour/minute — there's no separate
"time of day" field, and TickTick-style recurrence always keeps the
anchor's original time. Monthly/yearly clamp against the *original*
`start.day`/`rule.dayOfMonth` every time (never a previously-clamped
value), so a Jan-31 monthly rule correctly "un-clamps" back to 31 in
March after landing on 28 in February, and a Feb-29 yearly rule correctly
lands on 29 again the next leap year.

## Contextual "When" form widget

`lib/util/scheduling/recurrence_when_field.dart`'s `RecurrenceWhenField`
— a controlled `StatefulWidget` over the same shared `TextEditingController`
`GenericFormScreen` already keeps for every plain-text field, wired in via
`_buildRecurrenceWhenField` (detected by field-name match, same pattern as
Geo Location's capture button — not a `FieldFormatHandler`, since that
interface has no way to read a *sibling* field's live value). Reads the
Timeframe field's current selection (resolving a linked-lookup id or an
inline-select key to its lowercased display text) and renders:

- **Weekly** → a weekday dropdown.
- **Monthly** → a pattern dropdown (Day of month / Last day / Weekday
  position) plus whichever sub-picker that implies.
- **Daily/Yearly/Hourly/Once/unset** → a disabled informational line
  ("Not needed for Daily.").

Rewrites the controller's JSON immediately on every Timeframe change
(`didUpdateWidget`), so a save made right after switching Timeframe —
before ever touching "When" — still writes a value matching whatever
pattern is now active, never stale JSON from a different Timeframe.

## Background firing — reuses the existing scheduling infrastructure, adds no new trigger

`lib/db/recurring_reminder_service.dart`'s `RecurringReminderService` is
a new, independently-testable class (mirrors `LinkedFieldService`/
`FormulaService`'s "pure enough to test without the plugin stack"
posture) — **not** a new background trigger:

- `checkAndFireDueReminders()` is called from
  `BackgroundScheduleService.runDueScheduledEvents()`, right after the
  existing `event_definitions` scheduled-script loop — so it rides both
  platforms' *existing* triggers (Windows' 1-minute Task Scheduler poll,
  Android's exact-alarm chain) with zero new registration.
- `nextDueFireTime()` feeds into `alarm_schedule_service.dart`'s
  `computeNextDueTimeForDevice` (folded into the same single-alarm `min()`
  computation `event_definitions` bindings already use) — without this,
  a device with no scheduled *scripts* at all would never arm an Android
  alarm, and Agenda notifications would silently never fire there.

**Per-row, per-device bookkeeping** — `device_settings` key
`agenda_reminder_last_fired:<table_name>:<row_id>` records the last
occurrence (its own computed timestamp) this device has already notified
for. Absence means "never fired" — the row's very first occurrence is
still eligible. Chosen over a new table for the same reason `bg_check:*`
status already lives in `device_settings`: purely internal bookkeeping,
never worth touching `SchemaEditorService`/`migration_log` for (see this
project's own hard-won caution around that pipeline).

A device left off for a while catches up to the single most-recent
overdue occurrence rather than chain-firing every missed one — same
"jump to current" posture `BackgroundScheduleService._isDue` already
takes for scheduled scripts.

## Real bug found live, fixed same session: notifications named the row by its bare id

Mike's first real notification showed `Agenda: 1789219961762258` instead
of the record's Activity text. Root cause: `TableConfig.displayColumn`
(`SchemaRegistry.buildConfig`) falls back to the literal `id` column
whenever `table_definitions.display_field` is unset -- which is every
real v2 table today, since no UI in this app has ever actually set it
(the identical gap `GenericDao.getReverseLinks` already found and fixed
for the reverse-relation panel, Essentials v2 Phase 4). Fixed the same
way: `RecurringReminderService._titleColumnFor` falls back to the
table's first real field by position (Agenda's "Activity") whenever
`displayColumn` resolves to `id`, rather than using it directly.

**Also fixed, found while writing that fix's own regression test:**
`checkAndFireDueReminders`/`nextDueFireTime` scan *every* qualifying
table in the whole database by design -- correct for the feature, but it
meant a test inserting its own throwaway Notify=1 row could pick up
Mike's real Agenda data too (and vice versa), making `fired`-count
assertions non-deterministic depending on what's actually in the live
app at the moment a test happens to run. Added an `onlyTables` scoping
parameter to `RecurringReminderService` (real callers -- the background
service, the alarm-arming computation -- always leave it `null`,
scanning everything; only tests pass it) so `test/recurring_reminder_service_test.dart`
is now fully isolated from live production data. 8 tests, including a
new one covering the title fix directly.

## Real bug found live, fixed same session: editing an already-fired record's Start never fired again

Mike's own testing: a record fires once, then its Start is edited forward
(e.g. 09:00 -> 10:00) -- it never fired again. Root cause:
`_nextFireFor` passed the *previous* fired occurrence straight into
`nextOccurrenceAfter(..., after: lastFired)` -- valid only when Start
hasn't changed since that occurrence was computed. For `once`
specifically, `nextOccurrenceAfter` always returns `null` once `after`
is non-null (a `once` timeframe has nothing left once its single
occurrence is consumed) -- with no way to tell "this *is* that same
already-fired occurrence" apart from "Start changed entirely since then."

**Fix:** `_nextUnfiredOccurrence` always recomputes the row's *own*
first occurrence from its *current* Start/rule (`after: null`), then
walks forward only as far as needed to pass `lastFired`. If Start moved
forward, the very first occurrence under the new Start is already past
`lastFired` and is returned immediately -- correctly treated as a
genuinely new, eligible occurrence. If Start/rule haven't changed, this
walks the same sequence `lastFired` was already found in and reproduces
the original correct behavior. New regression test reproducing the exact
scenario: fires once, confirms it doesn't fire again unedited, edits
Start forward via a real `GenericDao.update` call, confirms it fires
again for the new time, confirms it doesn't fire a third time
afterward. 9 tests total in `recurring_reminder_service_test.dart`.

## What's deliberately deferred

- **The grid's "When" column shows raw JSON**, not a human-readable
  summary ("Every Wednesday", "2nd Tuesday of each month") — a real UX
  gap, but the primary ask was the recurrence engine and the form
  experience, not grid polish. A `formatter`-only fix (display text only,
  no change to the underlying stored value or edit behavior) is a
  reasonable follow-up whenever it's worth the time.
- **No tap-to-navigate from the fired notification** — `ScriptNotifications
  .show` is a plain, un-actioned notification (same as every scheduled-
  script notification already is). Wiring a payload + navigation-on-tap
  is a real feature, not attempted here.
- **`once`/`hourly` aren't part of Mike's original four-timeframe rule**
  (only daily/weekly/monthly/yearly were specified) but exist as real
  rows in the `timeframe` lookup table from earlier phases — handled
  anyway, gracefully: `once` fires a single occurrence at Start and never
  again; `hourly` repeats every hour indefinitely. Neither reads the
  "When" field.

## Build/test summary

- `lib/util/scheduling/recurrence_when.dart` — pure recurrence math.
  `test/recurrence_when_test.dart`, 20 tests.
- `lib/util/scheduling/recurring_reminder_fields.dart` — field-group
  detection. `test/recurring_reminder_fields_test.dart`, 6 tests (pure,
  no DB).
- `lib/util/scheduling/recurrence_when_field.dart` — the contextual form
  widget.
- `lib/db/recurring_reminder_service.dart` — the background check/fire
  logic. `test/recurring_reminder_service_test.dart`, 7 tests (DB-backed,
  run in isolation per this project's standing
  `SchemaEditorService.createTable`-test rule).
- `test/agenda_recurring_reminder_regression_test.dart` — confirms the
  real, live `agenda` table is actually recognized (read-only, safe to
  run alongside other files).
- `lib/screens/generic_form_screen.dart` — wires `RecurrenceWhenField` in
  by field-name detection.
- `lib/util/scripting/background_schedule_service.dart` /
  `alarm_schedule_service.dart` — wire `RecurringReminderService` into
  the existing background-firing/alarm-arming pipeline.
- `tool/add_agenda_scheduling_fields.dart` — the real, one-time schema
  change applied to Mike's live `agenda` table (rename Period → When, add
  Notify + Remind (Minutes Before)), through the real
  `SchemaEditorService`/`SchemaMetadataDao` pipeline, already run and
  confirmed (`PRAGMA integrity_check: ok`) as of this design doc.

Separately (same session, unrelated to the recurrence engine itself):
`isoDateTimeMinutes` (`lib/util/date_format.dart`) drops the seconds
component from every dateTime field's grid/form display and from every
value written by the "Now"/date-time picker going forward — Start/End no
longer show or write `:SS`.

**Build-verified only as of this doc — not yet Mike-tested interactively.**
Next: on MIKE-CU, set Timeframe to Weekly/Monthly on a real Agenda row and
confirm the "When" widget's contextual UI (weekday dropdown; day-of-month/
last-day/weekday-position picker), turn Notify on with a near-future Start
and a short Remind lead time, confirm a real notification fires at the
right moment, then F5/relaunch MIKE-12R to confirm the new fields and a
fired reminder's bookkeeping both behave correctly on that platform too.
