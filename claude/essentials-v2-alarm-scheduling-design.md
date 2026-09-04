# Alarm-based scheduling for scripted events — design (2026-09-04)

> Mirrors a claude.ai Project doc of the same name — the Project copy is the
> one actively edited across chat sessions; this repo copy is what Code/local
> tooling reads. Keep both in sync, same convention as every other design doc
> here (see CLAUDE.md "Repo move: CLAUDE.md/schema.sql").

**Status: build order steps 1-4 done, step 4 real-device verified on
MIKE-12R (including a real bug found and fixed along the way). Steps
5-7 not yet started** -- though step 5 (boot-survival receiver) is
already effectively done as a side effect of step 2's own finding, see
that step's own write-up. Grew directly out of the
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

**Confirmed by the step 2 spike, simpler than assumed above: no custom
Dart-side boot-completed receiver is needed at all.** Read the plugin's
own Java source directly (`AlarmService.java`/`RebootBroadcastReceiver
.java`) rather than trusting the README summary alone:
`oneShot(..., rescheduleOnReboot: true)` persists the full alarm request
(delay, callback handle, params, every flag) into the plugin's own
`SharedPreferences`, and natively flips its manifest-declared (initially
`android:enabled="false"`) `RebootBroadcastReceiver` on via
`PackageManager.setComponentEnabledSetting` — purely native code, no
Flutter engine involved until the alarm actually re-fires. On
`BOOT_COMPLETED`, that receiver calls `AlarmService
.reschedulePersistentAlarms()` itself, which re-registers the exact same
alarm from the persisted request. The only actual application-side work
is the manifest wiring (permission + the three components from the
README, verbatim) and passing `rescheduleOnReboot: true` when scheduling
-- no receiver class, no `BOOT_COMPLETED` handling in Dart or Kotlin at
all. Verified for real, not just read: rebooted MIKE-12R with a pending
spike alarm registered, reconnected once it came back up, and confirmed
the alarm had already fired *before* reconnection -- with the app process
never manually relaunched (`dumpsys activity activities` showed no
activity/task for the app at all afterward, confirming the only process
that ran was the plugin's own background isolate, not `MainActivity`).

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

## Build order steps 1-2, concluded

**Step 1 — `nextDueTime()` calculator + unit tests: done.**
`lib/util/scripting/next_due_time.dart` + `test/next_due_time_test.dart`
(19 tests, all passing), committed as `ef9bbea`. Pure Dart, mirrors
`BackgroundScheduleService`'s existing `_isDue`/`_pastConfiguredTime`/
`_matchesConfiguredWeekday` semantics exactly, reframed as "when next"
instead of "is it due now" -- same unconfigured-time/day-is-due-immediately
fallback this doc proposed above, now actually implemented and tested
rather than just proposed.

**Step 2 — spike: done, real-device verified on MIKE-12R, both halves.**
`android_alarm_manager_plus: ^5.1.1` added with zero dependency conflicts.
Manifest wiring per the package's own README (`RECEIVE_BOOT_COMPLETED`/
`WAKE_LOCK` permissions, the `AlarmService`/`AlarmBroadcastReceiver`/
`RebootBroadcastReceiver` components) landed cleanly -- **no manifest/Gradle
conflict with the existing `workmanager`/`flutter_js`/`mobile_scanner`
stack**, confirmed by a clean `flutter build apk --debug`. Hit, and fixed,
this project's own previously-documented XML-comment landmine again (a
bare `--` inside an added manifest `<!-- -->` comment breaks Gradle's
manifest merge) -- same failure mode as the `url_launcher`/`geolocator`
manifest additions in earlier sessions, worth remembering as a recurring
trap whenever writing prose-style comments into this file.

**No `SCHEDULE_EXACT_ALARM` permission needed** -- confirmed by reading
the plugin's own `oneShot` doc comment: that permission is only checked
when `exact: true`. This app's design (inexact, `allowWhileIdle: true`)
never needs it, exactly as this doc's "Exact vs. inexact alarm" section
above predicted, now confirmed against the real API rather than assumed
from the README's blanket "for apps targeting 31+" wording.

**A real bug found and fixed live, worth remembering for step 3's real
implementation:** `AndroidAlarmManager.initialize()` uses a
`MethodChannel`, which needs `ServicesBinding.instance` to exist --
calling it before `runApp()` (as the plugin's own README example does)
throws `Binding has not yet been initialized` unless
`WidgetsFlutterBinding.ensureInitialized()` is called first. The plugin's
README does mention this ("Be sure to add this line if initialize() call
happens before runApp()") but it's easy to skim past; hit it for real on
the very first test run, full stack trace pointed straight at the
omission. Idempotent, so calling it defensively costs nothing.

**Reliability, confirmed with real timing data:** scheduled a 45-second
`oneShot` (`exact: false`, `allowWhileIdle: true`, `wakeup: true`), then
backgrounded the app (not force-stopped -- see the plugin's own FAQ:
force-stopping an app makes Android refuse to fire its alarms at all,
a real OS restriction, not a plugin bug). The alarm fired ~81 seconds
after being scheduled, not 45 -- consistent with Android batching an
inexact/`allowWhileIdle` alarm rather than firing it to the second,
exactly the tradeoff this doc's "Exact vs. inexact" section already
accepted. Confirmed by direct `device_settings` inspection (a temporary
spike-only key, not a permanent addition -- see below), not by trusting
logcat alone: `alarm_spike:fire_count`/`alarm_spike:last_fired_at`
landed correctly in `essentials.db` while the app was backgrounded.

**Reboot survival, confirmed for real, not just read from source** -- see
the corrected "Reboot survival" section above for the mechanism finding
(no custom receiver needed at all). Registered a fresh persistent alarm,
confirmed it via `adb shell dumpsys alarm` immediately before rebooting,
then ran a real `adb reboot` on MIKE-12R (with Mike's explicit go-ahead,
since it's disruptive to the physical device -- he re-enabled Wireless
debugging and supplied the fresh pairing IP/port to reconnect afterward,
same one-time-pairing dance as every prior wireless-adb reconnect in this
project). The alarm had already fired by the time adb reconnected, with
no activity/task for the app ever created (`dumpsys activity activities`
empty for the package) -- proof this ran purely through the plugin's own
native reboot-rescheduling path, not because the app got relaunched some
other way.

**Spike code fully removed after verification**, per this project's own
established convention for throwaway spikes (`tool/schema_engine_spike
.dart`, `tool/csv_parse_spike.dart`, etc. -- though this one couldn't be a
`dart run`/`flutter test` script the way those were, since it needed a
real device to prove anything): deleted
`lib/util/scripting/alarm_manager_spike.dart` and its temporary call site
in `main.dart` (the `WidgetsFlutterBinding.ensureInitialized()` +
`scheduleAlarmManagerSpike(...)` block, and the now-unused `dart:async`
import). **Kept**: the `android_alarm_manager_plus` pubspec dependency and
all of the `AndroidManifest.xml` wiring above -- step 3's real
implementation needs the identical plugin and manifest setup, so there's
no reason to rip it out and re-add it. `flutter analyze` clean, both
`flutter build windows`/`apk --debug` clean after removal, debug APK
reinstalled on MIKE-12R. The `alarm_spike:*` `device_settings` rows this
testing left behind on MIKE-12R are harmless, inert cruft -- same
"accumulated test residue, not worth chasing" posture this project has
already established for schema-engine test tombstones elsewhere; a
leftover persisted native alarm (id `990001`) may fire at most once more
with nothing listening for it, since the Dart code that would re-arm it
is gone.

## Build order step 3, built -- deliberately not yet wired in or real-device tested

**New file, `lib/util/scripting/alarm_schedule_service.dart`** -- exactly
the "wire the real fire path" scope build order step 3 asked for, no
more: `rescheduleNextAlarm()` (reads this device's real `event_definitions`/
`schedule_last_run:*` rows, calls `nextDueTime` from step 1, then arms or
cancels exactly one `AndroidAlarmManager.oneShotAt` alarm) and
`scheduledEventAlarmCallback()` (the top-level callback the alarm fires --
runs the existing, completely unchanged `BackgroundScheduleService
().runDueScheduledEvents()`, then reschedules the next alarm in a
`finally` block so a single failed dispatch pass can't silently end the
whole self-rescheduling chain). `computeNextDueTimeForDevice()` is
factored out as the one part of this file that doesn't touch
`AndroidAlarmManager` at all -- purely DB-to-`nextDueTime` plumbing --
specifically so it has real, DB-backed test coverage
(`test/alarm_schedule_service_test.dart`, 6 tests, all passing against
the real `essentials.db`) without needing a device. Every assertion there
is a before/after min-reduction invariant (adding a candidate binding can
only pull the aggregate result earlier or leave it unchanged, never
later) rather than an exact-value check, deliberately robust against
whatever real scheduled bindings already exist in Mike's own live usage.

**`AndroidAlarmManager.oneShotAt` used directly, not `oneShot`** -- `due`
is already the absolute moment `nextDueTime` computed; converting it to a
relative delay and back would be a pointless round trip. A due time
already in the past (an overdue binding) is fine -- confirmed live during
step 2's reboot test that `AlarmManager` fires an alarm requested for a
past time as soon as possible, exactly the desired catch-up behavior.

**Not wired into `HomeShell`/`ScheduledEventsScreen` yet, and not
real-device tested -- both deliberate, matching step 4's own separate
scope in this doc's build order.** `rescheduleNextAlarm()` is currently
called from nowhere: nothing ever arms the very first alarm, since that's
exactly what step 4 (`ScheduledEventsScreen`'s create/edit/delete/enable/
disable actions, and app launch) exists to wire up. Verifying this step
live before step 4 exists would mean hand-triggering `rescheduleNextAlarm()`
through some other temporary harness -- not worth building just to
re-verify mechanics the step 2 spike already proved live on real
hardware (a `oneShotAt` alarm firing reliably while backgrounded, and
surviving a real reboot with `rescheduleOnReboot: true`). Real end-to-end
verification of this file's own logic -- the *right* alarm getting armed
after a real dispatch pass, the chain continuing correctly hour after
hour -- is what step 8's "real-device verification" is for, once steps
4-7 give it something real to observe.

`flutter analyze` clean project-wide (only the pre-existing, unrelated
`avoid_print` lints on `tool/fix_books_rating.dart`). Both `flutter build
windows` and `flutter build apk --debug` clean; debug APK reinstalled on
MIKE-12R. Confirmed via direct query against the real, pulled
`essentials.db`: `PRAGMA integrity_check: ok`, and every `alarm-`/`bg-`
-tagged test row from this and prior sessions' test runs is correctly
tombstoned (`is_deleted = 1`), none live.

## Build order step 4, done and real-device verified on MIKE-12R

**Wired exactly where the design called for.** `HomeShell`'s bootstrap
(`_bootstrapAndLoadGroups`, right alongside the existing `workmanager`
registration call) now calls `rescheduleNextAlarm()` on every app launch,
Android-only. `ScheduledEventsScreen` calls a new private
`_afterScheduleChanged()` helper (`if (Platform.isAndroid)
unawaited(rescheduleNextAlarm())`) after `_add`/the enable-disable
`Switch`/the delete `IconButton` -- its own create/edit/delete/enable/
disable actions, exactly as the build order lists. One addition beyond
that literal list, made because the hook already existed and the cost is
negligible: `_onDataChanged` (this screen's existing `SyncService
.dataChanges` subscription, there to reload the list when another device
edits a binding) now also calls `_afterScheduleChanged()` -- a schedule
change made on a *different* device needs this device's own alarm
recomputed too, not just its displayed list refreshed. Without this,
correctness wouldn't be lost (the self-rescheduling chain in step 3
already recomputes on every real fire, so a stale alarm eventually
self-corrects), only responsiveness -- worth the one extra line rather
than leaving a real device to wait out however long its current alarm
still has left.

**Real-device verification, MIKE-12R, confirmed by direct observation
(`adb shell dumpsys alarm`, logcat), not just by reasoning about the
code:** before any launch, no alarm registered for the app at all. After
a fresh launch, `AlarmService started!` (confirms `AndroidAlarmManager
.initialize()` succeeded from `rescheduleNextAlarm()`) followed
immediately by `cancel: broadcast receiver not found` for alarm id `1` --
the correct, expected outcome given Mike's real `event_definitions` on
this device currently have no enabled hourly/daily/weekly binding (only
`app_launch`-type ones, which never contribute to `nextDueTime`): nothing
due, so `rescheduleNextAlarm()` correctly cancels (a safe no-op) rather
than arming anything. Confirms the wiring runs cleanly end-to-end for the
"nothing scheduled" case; the "a real binding gets armed and later fires
through this exact path" case needs an actual hourly/daily/weekly binding
to exist, which is Mike's own call to create through the real UI
whenever he wants to exercise it -- per this project's standing working
agreement, that's his interactive testing to do, not Code's to simulate.

**A real bug found and fixed during this same verification pass, unrelated
to step 4's own new code:** the very first post-fix launch logged a
genuine `Dart Error: Dart_LookupLibrary: library
'package:essentials_app/util/scripting/alarm_manager_spike.dart' not
found`. Root cause, confirmed by reading `AlarmService.java`'s
`reschedulePersistentAlarms`/`RebootBroadcastReceiver.java` directly, not
guessed: the now-deleted step 2 spike's own alarm (id `990001`,
`rescheduleOnReboot: true`) left a real entry persisted in the plugin's
own native `SharedPreferences` on MIKE-12R, from before that file was
ever deleted. This doc's own step 2 write-up assumed that leftover "may
fire at most once more" -- **wrong, confirmed live**: on this ROM
(ColorOS), a `BOOT_COMPLETED`-equivalent broadcast is redelivered to the
app's boot receiver not just on a genuine reboot but on *every*
force-stop-then-relaunch cycle, so the stale entry kept re-arming and
re-failing (harmlessly, but noisily) on every single relaunch during this
step's own testing, not just once. Fixed with a small, self-clearing
one-time cleanup: `_cancelLeftoverSpikeAlarm()` calls
`AndroidAlarmManager.cancel(990001)` (the plugin's own cancel API needs
only the numeric id, not the original callback reference, so this works
even with the callback's source file long gone) from inside
`rescheduleNextAlarm()` itself -- cheap and safe to call unconditionally,
including on a device that never ran the spike at all (the native side's
own `cancel()` just logs "broadcast receiver not found" and returns).
Verified fixed with two more relaunch cycles: the first cleared the
stale entry (one last harmless native-side reschedule attempt, no more
Dart error since our own cleanup call now races it and usually wins,
confirmed by its absence in that run's logcat), and the second showed the
entry gone for good -- `RebootBroadcastReceiver` disabling itself
natively once the persisted-alarm set became empty, so `Rescheduling
after boot!` stopped appearing at all. `PRAGMA integrity_check: ok`
reconfirmed on the pulled db afterward.

`flutter analyze` clean, both `flutter build windows`/`apk --debug`
clean, debug APK reinstalled on MIKE-12R with the fix. All 6
`alarm_schedule_service_test.dart` tests still pass (run individually,
per the standing rule).

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
