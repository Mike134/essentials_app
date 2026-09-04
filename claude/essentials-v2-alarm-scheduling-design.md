# Alarm-based scheduling for scripted events — design (2026-09-04)

> Mirrors a claude.ai Project doc of the same name — the Project copy is the
> one actively edited across chat sessions; this repo copy is what Code/local
> tooling reads. Keep both in sync, same convention as every other design doc
> here (see CLAUDE.md "Repo move: CLAUDE.md/schema.sql").

**Status: design only, not yet implemented.** Grew directly out of the
2026-09-04 background-check memory-leak investigation (see CLAUDE.md's
session write-up) — not a new phase number, a scoped fix for a problem that
investigation found and fully diagnosed.

## The problem this solves (recap, not re-litigated here)

Confirmed by reading `workmanager_android`'s actual `BackgroundWorker.kt`
source directly: every ~15-minute periodic WorkManager fire on Android
constructs a brand-new, full `FlutterEngine` (Dart VM, Skia/Impeller
graphics subsystem, every plugin's native registration — the works, even
though nothing ever draws a pixel), runs `BackgroundScheduleService
.runDueScheduledEvents()`, then destroys the engine. This is architecturally
known to leave native engine-teardown residue each cycle (confirmed via
research — this is the documented, known cost of the `workmanager` plugin's
whole design, not a bug specific to this app). Live monitoring on MIKE-12R
the same day watched one process survive ~4.4 hours across many of these
cycles, climbing to 94.3MB before Android's own process reclaim finally
killed it (no crash that time) — and separately confirmed two real Dart-VM
out-of-memory crashes in this exact code path within the same week.

**The actual insight that makes this fixable:** `runDueScheduledEvents()`'s
own real work is trivial (a couple of SQLite reads/writes, a due-time
comparison) — almost all of the memory cost is the fixed overhead of
booting the engine at all, not the work done once it's up. Given every
binding on MIKE-12R today is hourly/daily/weekly (never every-15-minutes),
**the overwhelming majority of these engine-boot cycles find nothing due
and were entirely wasted.** The fix isn't making each cycle cheaper — it's
making cycles only happen when something is genuinely due.

## Confirmed direction

Mike's call, direct: switch from *periodic polling* ("wake up every 15 min,
check if anything's due") to *exact-time scheduling* ("compute the next
real due time across all bindings, and set one alarm for exactly that
moment"). This keeps the current Dart/JS scripting architecture entirely —
no rewrite to native Kotlin, no abandoning `flutter_js`/`sqlite_crdt`. It
only changes *when* the existing, unchanged dispatch logic gets triggered.

**Scope: Android first.** That's where all the crash/leak evidence lives.
Windows is a candidate follow-up (see below) but not proven to need this —
its background check is a real hidden-window EXE process via Task
Scheduler, a different (likely cheaper) cost model than an in-process
headless Flutter engine, and was never directly monitored this session.

## Architecture

### Core shape: a self-rescheduling chain of one-shot alarms, not a periodic timer

1. Compute the next due time across every enabled, non-`app_launch`
   scheduled binding.
2. Schedule exactly one alarm for that moment (nothing scheduled at all if
   no bindings are enabled — a real improvement over polling forever
   regardless).
3. On fire: run `BackgroundScheduleService().runDueScheduledEvents()`
   **completely unchanged** — see "Why the existing dispatch logic needs
   zero changes" below — then immediately recompute and reschedule the
   next alarm.
4. Also recompute + reschedule (not wait for the next fire) whenever:
   - A binding is created, edited, deleted, enabled, or disabled via
     `ScheduledEventsScreen` — the soonest-due binding may have just
     changed.
   - The app launches (also the practical trigger for the reboot case,
     with a caveat below).
   - A low-frequency safety-net check finds nothing currently scheduled
     (see "Safety net" below).

### New pure function: `nextDueTime`

A new, directly unit-testable calculator (same spirit as
`BackgroundScheduleService`'s own existing `_isDue`/`_pastConfiguredTime`/
`_matchesConfiguredWeekday` private methods, which already encode this
logic as a boolean "is it due *right now*" check — this is the same logic
reframed as "when will it next be due"):

```dart
DateTime? nextDueTime(
  List<EventDefinition> bindings,      // from EventDefinitionsDao.loadScheduled()
  Map<int, DateTime?> lastRunTimes,    // schedule_last_run:<id> per binding
  DateTime now,
)
```

- `schedule_hourly`: `lastRun + 1h`, or `now` if never run.
- `schedule_daily`: today at the configured time if that hasn't passed yet,
  else tomorrow at that time.
- `schedule_weekly`: the next occurrence of the configured weekday + time.
- An unconfigured time/day (no `scheduleConfig`, matching the existing
  fallback semantics in `_pastConfiguredTime`/`_matchesConfiguredWeekday`)
  needs a defined "next" answer, not just "any time is fine" — proposed:
  treat as due immediately (`now`), same permissive default the current
  code already applies for "is it due" (open detail, flag for Mike during
  implementation, not a blocking design question).
- Returns the **minimum** across every enabled, non-`app_launch` binding;
  `null` if none are enabled — meaning nothing gets scheduled at all.

Zero platform dependency — pure Dart, pure function, testable with
`flutter test` against fabricated bindings/timestamps exactly like the
existing due-check tests, no device or plugin involved.

### Why `runDueScheduledEvents()` itself needs no changes

It already checks "is this genuinely due right now" before running
anything (`_isDue`) — that's a safety property that has to stay regardless
of what triggers the call (clock drift between "when we computed the next
due time" and "when the alarm actually fired" is real and small; a stale
alarm firing a few seconds late still correctly re-verifies before acting).
The new code is additive: a due-time calculator, alarm registration/
rescheduling glue, a reboot-survival receiver, and a safety-net fallback —
none of it touches the existing dispatch/status-recording function, so the
`BackgroundProcessesScreen`/`bg_check:*` status keys keep working
unchanged.

### The Android mechanism: `android_alarm_manager_plus`, not hand-rolled native code

Recommend the existing Flutter-community package
(`android_alarm_manager_plus`) over writing raw Kotlin `AlarmManager`/
`BroadcastReceiver` wiring by hand — it already solves the "register an
exact/inexact alarm that runs a Dart callback in a headless engine on
fire" problem, the same category of already-solved-problem instinct this
project already applied when choosing `workmanager` itself over hand-rolled
wiring.

**Important, un-glamorous caveat, stated plainly so it isn't a surprise
later:** this package's Android implementation *also* boots a headless
`FlutterEngine` per firing — same underlying mechanism as `workmanager`,
same per-fire cost. **This design does not reduce the cost of one fire —
it reduces how often a fire happens at all.** That's still the real win
(every-15-minutes-regardless → only when genuinely due, likely a handful
of times a day given today's bindings), just worth being honest that the
per-cycle overhead itself isn't eliminated, only its frequency.

**Exact vs. inexact alarm — a real, deliberate choice, not a detail to
skip past:** Android offers `setExactAndAllowWhileIdle` (to-the-second,
Doze-aware) and `setAndAllowWhileIdle` (approximate, still Doze-aware,
batched by the OS for efficiency). Recommend the **inexact** variant:
- Hourly/daily/weekly scheduled scripts don't need to-the-minute precision
  — "close to the target time" is fine for this app's actual use case.
- The exact variant requires the `SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM`
  permission on Android 12+, which on some OEM builds means a real,
  user-facing consent screen — the same category of setup friction as the
  existing `MANAGE_EXTERNAL_STORAGE` permission-gate screen this project
  already has to carry. Avoiding it entirely (by not needing exact timing)
  is a real simplification, not just a technicality.
- If Mike ever wants to-the-minute precision for a specific future use
  case, that's a deliberate, revisitable tradeoff — not assumed here.

**Spike required before committing** (same discipline this project always
applies to a new pub dependency with real platform-integration risk — the
`mobile_scanner`/barcode spike, the `sqlite_crdt`/`sqlparser` spike,
etc.): confirm `android_alarm_manager_plus` actually fires reliably on
MIKE-12R, confirm its documented reboot-survival receiver pattern works as
described, and confirm no manifest/Gradle conflict with the existing
`workmanager`/`flutter_js`/`mobile_scanner` stack (three plugins already
carrying their own native Android wiring).

### Reboot survival — easy to miss, must not be skipped

`AlarmManager`-registered alarms do **not** survive a device reboot by
default — they're wiped from the OS's own alarm table on restart. Without
explicit handling, the entire mechanism would silently stop firing after
any reboot, with no user-visible symptom, until the app happened to be
opened again (which would re-trigger the recompute-and-schedule path via
the app-launch trigger above — but a reboot with the app never
manually reopened would otherwise go quiet indefinitely). Needs:
- `RECEIVE_BOOT_COMPLETED` permission declared in the manifest.
- A boot-completed broadcast receiver that runs the same
  recompute-and-schedule logic on `BOOT_COMPLETED`.
- `android_alarm_manager_plus` has documented support for exactly this
  pattern — confirm the exact API during the spike above rather than
  assuming.

### Safety net — don't remove all periodic redundancy

If the alarm-rescheduling chain ever silently breaks for any reason (a
bug in the reschedule-on-fire step, a missed reboot re-registration edge
case, an aggressive OEM background restriction eating the broadcast
receiver — this device's ColorOS has already fought this app's background
execution more than once, per CLAUDE.md's own history), there would be
**no periodic check left at all** to notice and recover — a real
regression from today's "at least it always tries every 15 minutes."

Recommend keeping one much-lower-frequency `workmanager` periodic task
(proposed: every 6–24 hours, open to adjustment) whose **only** job is
"is an alarm currently scheduled for anything? If not, recompute and
re-arm one." This preserves nearly all of the efficiency win — dropping
from ~96 engine-boot cycles/day to a small handful — while removing the
single-point-of-failure risk of the new mechanism going silently dark.
This safety-net task deliberately does **not** run the actual due-check/
dispatch logic itself, keeping its own engine-boot cost both minimal and
rare.

### Migration / coexistence

- The existing 15-minute `workmanager.registerPeriodicTask` registration
  must be cancelled (`Workmanager().cancelByUniqueName(_uniqueWorkName)`)
  when switching over, so the old and new mechanisms never run
  side-by-side.
- `BackgroundProcessesScreen`/the `bg_check:*` `device_settings` keys need
  no changes — they're written by `runDueScheduledEvents()` itself, which
  isn't changing.

### Windows — real candidate, deliberately deferred, not bundled

Windows' background check is a genuinely different cost shape — a real
hidden-window EXE process launched by Task Scheduler
(`windows_background_entrypoint.dart`'s own doc comment confirms: "there
is no headless Flutter engine on Windows the way Android's `workmanager`
gives one"), not an in-process engine create/destroy cycle. Whether it
carries an analogous accumulation risk was never directly investigated
this session — no Windows-side memory monitoring was done. The same
"schedule the next due time instead of firing every 15 minutes
regardless" idea would still cut needless process launches there too
(Windows Task Scheduler natively supports reprogramming a one-time
trigger), but recommend treating it as a genuine follow-up once the
Android side is built and verified, not something to design or build in
the same pass.

## Proposed build order

1. **`nextDueTime()` calculator + unit tests** — pure Dart, zero platform
   dependency, mirrors the existing `_isDue`-style test coverage. Buildable
   and fully verifiable without touching a device.
2. **Spike**: add `android_alarm_manager_plus`, confirm it fires reliably
   on MIKE-12R, confirm the reboot-survival receiver pattern, confirm no
   manifest/Gradle conflict with the existing plugin stack.
3. **Wire the real fire path**: on alarm fire, call the existing,
   unchanged `BackgroundScheduleService().runDueScheduledEvents()`, then
   recompute + reschedule the next alarm.
4. **Wire the other reschedule triggers**: `ScheduledEventsScreen`'s
   create/edit/delete/enable/disable actions; app launch.
5. **Boot-survival receiver.**
6. **Low-frequency safety-net `workmanager` task**, replacing the old
   15-minute one.
7. **Unregister the old periodic task.**
8. **Real-device verification**: an hourly/daily/weekly binding actually
   fires at roughly the right time; editing a binding reschedules
   correctly; reboot survival holds; and — the actual point of all this —
   re-run the same PSS-monitoring approach from the 2026-09-04
   investigation to directly confirm the *frequency* of engine-boot
   cycles (and therefore the memory churn) actually dropped, not just
   assumed to have.

## Open questions for Mike (judgment calls made above, worth confirming before/at build time)

- **Exact vs. inexact alarm precision** — recommended inexact (no extra
  permission, "close enough" timing), given hourly/daily/weekly
  granularity. Confirm this is acceptable, or flag if to-the-minute
  precision actually matters for some future use case.
- **Safety-net check frequency** — proposed 6–24 hours, arbitrary,
  genuinely open to adjustment.
- **Windows follow-up** — confirm it's fine to defer, given it was never
  shown to have the same problem.
- **Unconfigured time/day "next due" semantics** — proposed "due
  immediately," matching the current permissive fallback; flag if a
  different default is wanted.
