# Generalized recurring schedules for scripted events — design (2026-09-05)

**Status: built, tested, and real-device verified on MIKE-12R.** A real
UI-created anchored binding (every 20 minutes, starting at a specific
time, Mike's own test) fired on schedule and rescheduled correctly to the
next slot, confirmed via `dumpsys alarm`. The missed-occurrence
notification was also confirmed live -- a deliberately backdated test
binding (`tool/create_missed_occurrence_test.dart`, ~18 missed 5-minute
slots) produced a real notification Mike saw on the device itself, not
just in a test's captured callback. Grew out of a conversation while
babysitting the alarm-scheduling reboot/PSS re-verification session (see
`claude/essentials-v2-alarm-scheduling-design.md`) — a natural place to
revisit scheduling since that whole session was already in this code.
Confirmed with Mike before writing this: **zero real `event_definitions`
rows exist today** (the only ones on any device are this session's own
throwaway alarm-test bindings, already cleaned up or about to be) — so
this is a clean-cutover design, not a migration. No dual-format support,
no `schedule_hourly`/`schedule_daily`/`schedule_weekly` left running
alongside the new shape "just in case."

## The ask, as Mike put it

1. Minute granularity, not just hourly/daily/weekly.
2. A real frequency concept — "every 10 minutes," "every 4 hours," "every
   3 days," "every 7 weeks" — not three fixed buckets.
3. An anchor: "every 4 hours starting at 2026-09-05 10:20."

## Decision: replace the three fixed types with one generic one, not add a fourth

`event_definitions.event_type` currently has three separate scheduled
values (`schedule_hourly`, `schedule_daily`, `schedule_weekly`), each with
its own `schedule_config` shape and its own parallel logic duplicated
across `next_due_time.dart` (`_nextHourlyTime`/`_nextDailyTime`/
`_nextWeeklyTime`) and `background_schedule_service.dart` (`_isDue`'s own
three-way switch plus `_alreadyRanToday`/`_alreadyRanThisWeek`/
`_matchesConfiguredWeekday`/`_pastConfiguredTime`). Interval+unit+anchor is
the general case that subsumes all three — hourly is "every 1 hour, no
anchor needed since phase doesn't matter," daily is "every 1 day, anchored
to a time-of-day," weekly is "every 1 week, anchored to a weekday+time."

Given there's nothing to migrate, the plan is a clean retirement: one new
event type, `schedule_interval` (name open to bikeshedding, not
load-bearing), replaces all three. `app_launch` is untouched — it's not an
interval schedule at all, it fires from the app's own bootstrap, not the
background dispatcher.

## Schema — no DDL change needed

`event_definitions.event_type`/`schedule_config` are already plain `TEXT`
columns holding a free-form string/JSON respectively — this is purely an
application-level convention change. New `schedule_config` shape for
`schedule_interval`:

```json
{
  "interval": 4,
  "unit": "hours",
  "anchor": "2026-09-05T10:20:00"
}
```

- `interval` — a positive integer.
- `unit` — one of `"minutes"`, `"hours"`, `"days"`, `"weeks"`. No
  `"months"` — Mike didn't ask for it, and calendar-month arithmetic
  (variable-length months, "the 31st doesn't exist in February") is a
  genuinely different, harder problem than fixed-duration units; worth
  its own conversation later if actually wanted, not smuggled in here.
- `anchor` — **optional.** Local wall-clock, no timezone offset, same
  bare-`"HH:MM"`-style local-time convention `schedule_daily`/
  `schedule_weekly`'s existing `"time"` field already uses (device-local,
  not UTC). Omitted entirely means "no phase lock" — see below.

## Two modes: anchored vs. unanchored

This is the one real semantic fork, worth being explicit about rather
than papering over with "anchor defaults to now":

**No anchor — pure elapsed-time, generalizing today's hourly behavior.**
`next = lastRun == null ? now : lastRun + interval`. Simple, and it's what
"every 10 minutes" or "every 3 days" means if you don't care what wall
clock time it lands on, just that it's spaced out correctly from whenever
it last ran.

**Anchor present — phase-locked to fixed calendar/clock slots,
independent of `lastRun`.** The anchor plus the interval defines a fixed,
infinite sequence of slots (`anchor`, `anchor + interval`,
`anchor + 2*interval`, ...) that never drifts, the same way "daily at
8:00am" or "weekly on Monday at 8:00am" are fixed slots today, just
generalized to any interval. The key property: **once an anchor is set,
`lastRun` stops being the source of truth for *which* slot is next — only
for whether the *current* slot has already been serviced.** Concretely,
using one shared primitive:

```
anchorAlignedSlotAtOrBefore(anchor, interval, reference):
    if reference <= anchor: return anchor
    periods = floor((reference - anchor) / interval)
    return anchor + periods * interval
```

- **`nextDueTime`** (arms the next alarm): if `now < anchor`, the answer
  is just `anchor` itself (hasn't started yet — wait for the first real
  occurrence, don't fire early). Otherwise: `currentSlot =
  anchorAlignedSlotAtOrBefore(anchor, interval, now)`; if that slot's
  already been serviced (`lastRun != null && lastRun >= currentSlot`),
  the next due time is `currentSlot + interval`; otherwise it's
  `currentSlot` itself (already due, possibly slightly overdue — fine,
  same "overdue fires ASAP" behavior every schedule type already has).
- **`_isDue`** (the real-time safety recheck inside an actual dispatch
  pass): due iff `now >= anchor` and (`lastRun == null` or `lastRun` is
  before the current slot).

**Why not "catch up on every missed slot"?** If the alarm chain is broken
for a while (app force-stopped for a day, say) and comes back, the
existing hourly logic would technically let a very-overdue binding fire
immediately, then reschedule for `lastRun + 1h` — which, being still in
the past, fires again almost immediately, and again, until it's caught up
to real time. That's a mild, bounded annoyance at hourly granularity.
**With a 5-minute minimum interval, the equivalent "catch up on every
missed slot" behavior would mean potentially dozens of rapid-fire
catch-up cycles back to back** — exactly the kind of frequent-engine-boot
cost this whole alarm-based redesign exists to avoid (see the alarm
-scheduling design doc's own motivating incident). The anchored formula
above deliberately does **not** do this: it always jumps straight to the
current or next slot relative to *now*, silently skipping anything missed
while the chain was down, firing at most once per real check regardless
of how long the gap was. This is a genuine, deliberate behavior change
from today's hourly semantics (which does technically chain-fire on a
gap) — flagged here explicitly rather than silently altered, since it's
the kind of judgment call this project's own history says is worth
recording, not just deciding quietly.

## Minimum interval: 5 minutes, my call per Mike's "whatever you deem reasonable"

Enforced in two places, matching this project's usual "don't trust one
layer alone" posture (e.g. the required-lookup-field fix from the Table
Discovery phase, or `dropField`'s own index-safety check beyond what the
UI already prevents):
- **UI**: the new-schedule dialog disables Add / shows an inline error if
  `interval * unitToMinutes(unit) < 5`.
- **Defensive backstop**: the shared config parser clamps anything below
  5 minutes up to 5 minutes rather than trusting the UI alone — matters
  mainly as insurance against a future second UI surface (or, in
  principle, a hand-edited `schedule_config` reaching this code some other
  way) reaching the calculator with an unvalidated value.

Rationale for 5 minutes specifically: `android_alarm_manager_plus`'s
inexact/`allowWhileIdle` alarms already showed real-world batching drift
in this session's own step 2 spike (a 45-second test alarm actually fired
~80 seconds later) — sub-5-minute precision isn't reliably achievable
through this mechanism regardless of what's configured, so a floor around
5 minutes is honest about the real ceiling on precision, not an arbitrary
restriction. Easy to revisit if it turns out too conservative in practice.

## `nextDueTime`/`_isDue` de-duplication, a free side effect of this change

Today, `next_due_time.dart` and `background_schedule_service.dart` each
independently encode hourly/daily/weekly semantics — two parallel
implementations of the same three ideas, kept in sync by convention, not
by sharing code (already flagged as a soft duplication risk in
`next_due_time.dart`'s own doc comment: "Deliberately the same logic
`BackgroundScheduleService`'s private `_isDue`... already encode"). This
redesign is a natural point to fix that: `anchorAlignedSlotAtOrBefore`
and the config-parsing helper (`interval`/`unit`/`anchor` → a small
`RecurrenceConfig` record, with the 5-minute clamp applied once, in one
place) move into one new shared file — proposed
`lib/util/scripting/recurrence.dart` — imported by both `next_due_time
.dart` and `background_schedule_service.dart`, so the one true recurrence
formula only exists once.

## UI changes — `ScheduledEventsScreen`

`_NewScheduleDialog`'s current three-way `_eventType` dropdown
(`app_launch`/`schedule_hourly`/`schedule_daily`/`schedule_weekly`) plus
its conditional weekday/time pickers gets replaced with:

- **Schedule type**: `app_launch` or `schedule_interval` (two options,
  down from four).
- For `schedule_interval`: an integer field ("Every") + a unit dropdown
  (Minutes/Hours/Days/Weeks) — the `interval`/`unit` pair — with the
  5-minute-minimum validation live as you type, same "disable Add /
  show why" pattern the app already uses elsewhere (e.g. inline `select`
  fields needing at least one valid option before Add Field will submit).
- An optional **"Starting at"** toggle: off by default (no anchor — pure
  elapsed-since-last-run), or on, revealing a date+time picker for the
  anchor. Flutter's `showDatePicker`+`showTimePicker` combo, same as
  every other date/time entry in this app (e.g. the form screen's own
  date-field picker).
- `_describe()` needs a new rendering: `"Approximately every 4 hours"`
  (no anchor) vs. `"Approximately every 4 hours, starting 2026-09-05
  10:20"` (anchored) — same "approximately" wording the existing
  descriptions already use, honest about the alarm's own inexactness.

## Build order

1. `lib/util/scripting/recurrence.dart` — `RecurrenceConfig` (parse +
   5-minute clamp) and `anchorAlignedSlotAtOrBefore`, pure Dart, unit
   tested directly (mirrors this project's established pattern for every
   other pure calculator — `FormulaService`, `LinkedFieldService`,
   `next_due_time.dart` itself).
2. `lib/util/scripting/next_due_time.dart` — drop the three
   hourly/daily/weekly branches and their private helpers; add one
   `schedule_interval` branch built on `recurrence.dart`. Rewrite
   `test/next_due_time_test.dart`'s scheduling cases for the new shape
   (unanchored minute/hour/day/week intervals, anchored-in-the-future,
   anchored-in-the-past catch-up-to-now, the 5-minute clamp, malformed/
   missing config falling back to "due now").
3. `lib/db/event_definitions_dao.dart` — `scheduledEventTypes` becomes
   `['schedule_interval', 'app_launch']`.
4. `lib/util/scripting/background_schedule_service.dart` — replace
   `_isDue`'s three-way switch and its four private helpers with one
   `schedule_interval` check built on the same `recurrence.dart`
   primitive. Rewrite the due-check tests in
   `test/background_schedule_service_test.dart` for the new shape.
5. `lib/screens/scheduled_events_screen.dart` — the dialog and
   `_describe()` rewrite described above.
6. Real-device re-verification on MIKE-12R, same discipline as the
   alarm-scheduling design's own step 8: a short unanchored interval
   (e.g. every 5-10 minutes) actually fires close to on schedule and
   reschedules correctly; an anchored multi-hour interval computes the
   correct next slot and lands on it; deleting/editing a
   `schedule_interval` binding reschedules correctly (already-proven
   mechanism, just needs re-confirming against the new config shape).

## Missed-occurrence notifications — added mid-build, per Mike's explicit ask

Not in the original sketch -- Mike asked for this directly: whenever the
"jump to current slot instead of chain-firing" behavior above actually
happens, that should never be silent. `recurrence.dart` gained
`missedOccurrenceCount(anchor, interval, lastRun, now)`, computing exactly
how many whole slots were skipped (via the same `anchorAlignedSlotAtOrBefore`
primitive, applied to both `lastRun` and `now`). `BackgroundScheduleService
.runDueScheduledEvents()` calls it right before dispatching a due,
previously-run, anchored binding -- if the count is positive, it posts a
real OS notification (`_tryNotify`, the same mechanism a script's own
`notify()` call and the existing timeout/error notices already use) naming
the script and the count: `'"<script name>" fell behind schedule --
skipped N missed occurrence(s) and caught up to now.'` Only meaningful for
anchored schedules -- an unanchored one has no fixed slots to miss, so
there's nothing to report there. This notice always lands *before* the
real dispatch's own effects/timeout/error notices for that pass, not
instead of them.

## Build order, concluded

All six steps built in one pass:

1. `lib/util/scripting/recurrence.dart` -- `RecurrenceConfig`, the 5-minute
   clamp, `anchorAlignedSlotAtOrBefore`, and `missedOccurrenceCount`. 26
   unit tests (`test/recurrence_test.dart`).
2. `lib/util/scripting/next_due_time.dart` -- rewritten for one
   `schedule_interval` branch built on `recurrence.dart`. Test file
   rewritten (`test/next_due_time_test.dart`, 17 tests) covering
   unanchored minute/hour/day/week intervals, the 5-minute clamp, and
   every anchored case from this doc's own worked examples (future
   anchor, past-anchor-never-run, current-slot-already-serviced, the
   badly-overdue jump, an anchored daily-equivalent).
3. `lib/db/event_definitions_dao.dart` -- `scheduledEventTypes` is now
   `['schedule_interval', 'app_launch']`.
4. `lib/util/scripting/background_schedule_service.dart` -- `_isDue`
   rewritten onto the same `recurrence.dart` primitive; the
   missed-occurrence notification added (see above). `ScriptDefinitionsDao`
   gained `loadName(id)` for the notification's script-name lookup.
   `test/background_schedule_service_test.dart` rewritten against the real
   `essentials.db` -- 11 tests, including one confirming the
   missed-occurrence notice fires with the right script name and count on
   a badly-overdue anchored binding, and one confirming it does *not* fire
   for normal on-schedule progression.
5. `lib/screens/scheduled_events_screen.dart` -- the dialog replaced with
   "Every [N] [minutes/hours/days/weeks]" + an optional "Starting at"
   date+time picker, live 5-minute-minimum validation, and a rewritten
   `_describe()` (e.g. `"Approximately every 4 hours, starting 2026-09-05
   10:20"`).
6. `test/alarm_schedule_service_test.dart` also updated (5 tests) --
   `computeNextDueTimeForDevice` exercised against real `schedule_interval`
   bindings instead of the retired types.

`flutter analyze` clean project-wide (only the pre-existing, unrelated
`avoid_print` lints on `tool/fix_books_rating.dart`). All four touched
test files pass individually (60 tests total: 13 + 17 + 11 + 5, plus the
untouched `test/next_due_time_test.dart`'s companion counts already
folded into that 17). Both `flutter build windows` and `flutter build apk
--debug` clean (the pre-existing, documented KGP plugin warning aside).

## Real-device verification, concluded

Two real end-to-end passes on MIKE-12R, both confirmed via `dumpsys
alarm`/logcat and (for the notification) Mike's own direct observation on
the device, not just reasoning about the code:

1. **Mike's own real anchored binding** -- created through the actual
   `ScheduledEventsScreen` UI (not a tool script): every 20 minutes,
   starting at a specific time, bound to a throwaway leftover test script.
   Armed correctly for the exact configured anchor, fired ~2 minutes after
   the target (consistent with `android_alarm_manager_plus`'s own
   inexact/`allowWhileIdle` batching, already documented in the alarm
   -scheduling design), and rescheduled to exactly the next 20-minute slot
   -- confirmed by reading the alarm's own `origWhen` before and after.
2. **Missed-occurrence notification** -- `tool/create_missed_occurrence_test.dart`
   (paired with `tool/remove_missed_occurrence_test.dart`, same convention
   as every other throwaway-test-data pair in this project) created a real
   `schedule_interval` binding anchored 90 minutes in the past at a
   5-minute interval, then deliberately backdated MIKE-12R's own
   `schedule_last_run` for it to the anchor itself (~18 slots behind) via
   the real `ThemeSettingsDao` API, never raw SQL. Relaunching MIKE-12R
   picked it up, found it drastically overdue, dispatched it once (jumping
   to the current slot, not chain-firing through all 18), and posted the
   missed-occurrence notification -- which Mike confirmed seeing on the
   device itself. Both tool scripts' test data cleaned up (soft-deleted)
   afterward.

A UI bug was also found and fixed during this pass: the "New scheduled
event" dialog's content was a plain fixed-size `Column`, no scrolling --
once the anchor date/time row is showing, plus the on-screen keyboard for
the interval field halving available height, it overflowed on a phone
(`BOTTOM OVERFLOWED BY 119 PIXELS`, screenshotted by Mike). Fixed with a
height-capped `ConstrainedBox` + `SingleChildScrollView` around the
dialog's content -- the standard fix for a dialog whose content can
outgrow the viewport, rather than trying to guess a height that always
fits.

## Open items -- resolved during the build

- **Event type name** — kept as `schedule_interval`; never revisited.
- **Anchor date/time picker UX** — defaults to "now" (pre-filled from
  `DateTime.now()`/`TimeOfDay.now()` when the toggle is switched on), one
  tap to accept or adjust.
- Nothing else outstanding -- the algorithm, minimum, schema shape, and
  UI are all built and real-device verified (see above).
