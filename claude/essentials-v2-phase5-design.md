# Essentials v2 — Phase 5: Scripts & Events

**Status: design pass in progress, 2026-08-26.** Nothing implemented yet — confirmed by reading `pubspec.yaml` (no `flutter_js`/`flutter_qjs` dependency) and `lib/`, `schema.sql` (no `script_definitions`/`event_definitions`). This doc records the decisions confirmed with Mike before handoff to Claude Code, per the same discipline every prior phase used.

Phase 5 is sequenced last on the roadmap deliberately, for risk isolation — see `claude/essentials-v2-architecture.md`'s "Roadmap sequencing." It remains the single riskiest phase left: a new embedded JS runtime, plus (per the decision below) true OS-level background execution on two different platforms.

---

## Confirmed decisions (2026-08-26, before handoff to Claude Code)

1. **Scheduled events fire in the true background, not just on app-open** — chosen over the simpler "catch up on launch" option, because the TickTick-replacement use case (a reminder that actually fires at 8am) is a real part of Scripts' value per Mike's own framing in the architecture doc. This is the highest-risk decision in this pass — see "Scheduled event runner" below for the platform split it forces.
2. **Script safety posture: timeout + catch + notify.** Every script execution (event-triggered or scheduled) runs under an execution timeout; a script that errors or exceeds the timeout is killed, logged, and surfaces a notification — never crashes the app or blocks the UI thread. See "Script safety" below for the real technical gap this decision runs into.
3. **Script editor UI: pick the package during implementation.** No `re_editor` vs. `code_text_field` vs. plain-text-field decision made now — Claude Code checks what's actively maintained and confirms Windows+Android integration when it builds the screen, same pattern as `mobile_scanner` in Phase 2. A plain monospace `TextField` is an acceptable fallback if nothing suitable is actively maintained; this is cosmetic (syntax highlighting), not a functional gap, so it should not block the rest of the phase.

---

## What the code already does today (verified by reading it)

- No JS engine dependency of any kind in `pubspec.yaml`.
- `formula` (Phase 2) is a small arithmetic expression subset, explicitly *not* built on `flutter_js` — confirmed reserved for this phase, per `CLAUDE.md` lines 6441-6442 and the architecture doc's Field Model section.
- `SyncService.dataChanges` (built during Phase 4, reused by Phase 6) already broadcasts local data-change events — this is the natural hook point for "Record created/saved/updated/deleted" script events; no new change-detection mechanism needed there.
- The sync hub (`server/bin/server.dart`) is a plain Dart CLI process (no Flutter engine), already running as an always-on system-tray-hosted background process on MIKE-CU. It is **not** a Flutter app and cannot host `flutter_js` as-is — this matters directly for the Windows half of the scheduled-event runner, see below.
- `search_index.db`'s Phase 6 finding is the standing architectural rule to carry forward: any new locally-derived, never-synced state cannot simply be a table inside `essentials.db`, because `sqlite_crdt` enumerates the whole physical file. `script_definitions`/`event_definitions` are **not** in that category — they sync across devices by design (a script written on MIKE-CU should run when its event fires on MIKE-12R too) — so they get the normal CRDT bookkeeping columns and go through `migration_log` like any other user-facing table. A script-run *log* (see below), if built, would be the locally-derived case instead.

---

## Data model

### `script_definitions` — new shared table, synced

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PRIMARY KEY | timestamp+random default, same convention as other entity tables |
| `name` | TEXT NOT NULL | user-facing label |
| `code` | TEXT NOT NULL | JavaScript source |
| `description` | TEXT | optional |
| CRDT bookkeeping | `is_deleted`, `hlc`, `node_id`, `modified` | standard four columns, every table |

### `event_definitions` — new shared table, synced

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PRIMARY KEY | timestamp+random default |
| `script_id` | INTEGER NOT NULL | FK to `script_definitions.id` — one script per event binding, matching the architecture doc's "each binding one script to one event" |
| `event_type` | TEXT NOT NULL | `button_clicked` / `form_opened` / `form_closed` / `record_created` / `record_saved` / `record_updated` / `record_deleted` / `field_changed` / `schedule_daily` / `schedule_weekly` / `schedule_hourly` / `app_launch` |
| `table_name` | TEXT | NULL for scheduled/app-launch events; the target table for data/UI events |
| `field_name` | TEXT | only set for `field_changed` |
| `schedule_config` | TEXT (JSON) | `{ time: "08:00" }` for daily, `{ day: "mon", time: "08:00" }` for weekly, null for hourly/app_launch |
| `enabled` | INTEGER DEFAULT 1 | lets a binding be disabled without deleting it |
| CRDT bookkeeping | `is_deleted`, `hlc`, `node_id`, `modified` | standard four columns |

Both tables go through the normal `schema_admin`/`migration_log` path — no special-casing needed, consistent with every other Phase 1+ table.

**A new field format: `button`.** Not previously in the Field Model table — needed for "Button clicked" UI events, since the architecture doc's event list assumes a button field exists to bind that event to. Ships this phase, not a separate side task: `{ label: 'Run script' }` in `options`, rendered as an actual button in the form (and optionally the grid, TBD during build — a toolbar button is the other place the architecture doc mentions, which doesn't need a field at all, just a per-table setting or a table-level event binding with no `field_name`).

---

## Sandboxing

Per the architecture doc's confirmed finding (2026-08-24 pub.dev/GitHub check): `flutter_js` runs QuickJS on Android (FFI) and Windows (bundled prebuilt shared libraries), with no sandboxing guarantee at the package level. The sandbox has to come entirely from what the app exposes into the JS global scope — the script API below, and nothing else. No `require`, no filesystem access, no network access, no access to Dart/Flutter internals beyond the defined functions.

---

## Script API (implementation target, per architecture doc)

```javascript
// Record access
record.get('field_name')
record.set('field_name', value)
record.save()
record.delete()

// Table queries
table('TableName').find({ field: value })
table('TableName').all()
table('TableName').create({ field: value, ... })

// Notifications
notify('Message text')

// Navigation
navigate.to('TableName')
navigate.toRecord(record)
```

`record` is only in scope for events bound to a specific record (data events, field-changed, button-on-a-record). Scheduled/app-launch events have no ambient `record` — a script bound to one of those has to reach records entirely through `table(...)`. `navigate.*` only makes sense when a UI is actually present — a no-op (or a queued "open this on next launch" action) when a scheduled event fires with the app backgrounded/closed, since there's no screen to navigate on.

---

## Script safety

The confirmed posture (timeout + catch + notify) runs into a real technical gap worth flagging rather than assuming away, the same discipline the rest of this project uses: **whether `flutter_js`'s QuickJS binding exposes a genuine execution interrupt/timeout hook is unconfirmed as of this design pass.** A `try/catch` around the call handles thrown errors cleanly, but a synchronous infinite loop (`while(true){}`) in QuickJS is not necessarily preemptible from Dart just by wrapping the call in `Future.timeout()` — that cancels the *Dart future*, not the JS engine's own execution, which may keep running (and could hang the isolate it's on) unless the binding exposes something like QuickJS's native `JS_SetInterruptHandler`. **This needs a real check against the installed `flutter_js` version during implementation, not an assumption** — if no interrupt hook is exposed, the fallback is running script execution in its own isolate (so a hang is killable by tearing down that isolate) rather than trying to preempt it in place. Either way, the user-facing behavior (kill, log, notify) stays the same — this only affects how "kill" is actually implemented.

---

## Scheduled event runner

This is where the two confirmed decisions (true background firing) collide with the fact that Windows and Android are architecturally very different here. Platform split, not a shared mechanism:

### Android — `workmanager`

The `fluttercommunity/flutter_workmanager` package (actively maintained, confirmed via a fresh pub.dev/GitHub check 2026-08-26) registers periodic/one-off background tasks that survive the app being killed, via Android's own `WorkManager`. Real constraints to design around, not gloss over:

- Android `WorkManager` periodic tasks have a **15-minute minimum interval** and are not exact-time — the OS batches execution for battery reasons. An "hourly" event is a reasonable fit; a "daily at 8:00am" event will fire at *approximately* 8am, not exactly — needs to be communicated to Mike as a real behavior, not a bug, when this ships.
- The background callback runs in a **separate background isolate**, without the main app's UI/state. It needs its own path to open `essentials.db` (same `sqflite_common_ffi`-style access the rest of the app uses), run the relevant script through its own `flutter_js` instance, and post an Android notification directly (`flutter_local_notifications` or equivalent) — it cannot call into the foreground app's `navigate.*`.
- Requires Android battery-optimization exemption to be reliable in practice (same category of setting most real reminder apps prompt for) — worth a one-time in-app prompt, not silently hoping the OS cooperates.

### Windows — extending the existing sync hub, not the Flutter app

There is no Windows equivalent of `workmanager`, and the Flutter app itself is not always running (it's a desktop app Mike opens, not a tray-resident process — the *sync hub*, `server.dart`, is the thing that's always on). Two real options, not yet decided between — flagged here rather than picked, since it's a genuine open call:

- **Extend `server.dart` itself** to also watch `event_definitions` for scheduled events and fire them — but `server.dart` is a plain Dart CLI process with no Flutter engine, so it cannot host `flutter_js` (a Flutter plugin) without pulling in a non-Flutter QuickJS FFI binding directly (e.g. `flutter_qjs`'s underlying FFI, or a separate pure-Dart QuickJS wrapper) — real added complexity, a second script-execution code path to keep in sync with the app's own.
- **A separate lightweight Windows Scheduled Task** that launches a small headless Dart/Flutter executable at each due time, does its one script run, and exits — closer in spirit to how Windows itself expects scheduled work to happen, avoids running a second long-lived process, but adds a second executable to build/ship/maintain alongside the main app and the server.

**This is the single open architectural question this design pass is not resolving** — recommend Claude Code do a short spike (can `flutter_js` run at all outside a Flutter widget tree, in a headless Dart entrypoint, on Windows?) before committing to either path, and bring the finding back for a quick confirm rather than guessing. Everything else in this doc does not depend on which way this goes.

### Both platforms — `app_launch` events

Straightforward regardless of the above: run once per app process start, in the normal foreground app, no background mechanism needed.

---

## Event binding UI

- **Data events** (`record_created`/`saved`/`updated`/`deleted`, `field_changed`) — bound per table (and per field for `field_changed`) from a new section in `ManageFieldsScreen` or a sibling table-settings screen (TBD during build which fits better) — pick a script from `script_definitions`, pick the event type.
- **UI events** — `form_opened`/`form_closed` bound per table the same way; `button_clicked` bound to a specific `button`-format field, configured at field-creation time via `AddFieldScreen`/`ManageFieldsScreen` (which script runs on tap).
- **Scheduled events** — a new global screen (not per-table) listing all scheduled bindings, since they're not attached to any one table's data — create/edit/delete a schedule, pick daily/weekly/hourly/app-launch, pick the script.

## Script editor UI

New `ScriptEditorScreen` — list of `script_definitions` (name, description, edit, delete, new), each opening a full-screen code editor (package choice deferred to implementation, see "Confirmed decisions" above). Reached via a new nav rail/drawer entry, same pattern as Search (Phase 6).

---

## Explicitly out of scope for this pass

- Debugging tools beyond the timeout+log+notify safety net (breakpoints, step-through, console output panel) — a real gap for anyone iterating on a script, but not blocking a working v1.
- Script versioning/history beyond what CRDT timestamps give implicitly (same open item as "Record history UI" in the architecture doc's Open Decisions).
- Any script triggering *another* script's event (chained automation) — not requested, real risk of infinite trigger loops on top of the infinite-execution-loop risk already being designed around.
- Per-script permission scoping (e.g. a script allowed to read but not write) — every script gets the same API surface for v1.

## Build order (suggested)

1. `script_definitions`/`event_definitions` schema + migrations, `button` field format
2. `flutter_js` integration behind a minimal internal wrapper (so the interrupt-handler question above can be resolved/worked around in one place)
3. Script API implementation against the wrapper — `record`/`table`/`notify`/`navigate`
4. Data + UI event wiring off `SyncService.dataChanges` and existing form lifecycle — the foreground, in-app path; exercises the whole API without touching background execution yet
5. Script editor UI + event binding UI
6. `app_launch` scheduled events (foreground-only, no background mechanism needed)
7. Android background firing via `workmanager`
8. Windows background firing — pending the spike above resolving which path to take
9. Real-device verification on both MIKE-CU and MIKE-12R, including the `crdt_sync` new-table batch-atomicity risk the architecture doc flags as expected to reproduce here (two new tables created live)

## Open questions / risks flagged, not resolved

- **Windows background execution path** — see "Scheduled event runner" above; needs a build-time spike before step 8.
- **Android WorkManager's ~15-minute batching** means "daily at 8:00am" is approximate, not exact — worth surfacing in the scheduling UI copy itself (e.g. "approximately 8:00am") rather than letting Mike discover the drift later.
- **Button field placement** — form only, or also a grid/toolbar affordance? Left for build-time UI judgment, consistent with how Phase 3's Kanban/List config details were pinned down.

## Step 2, concluded: `flutter_js` integration + `JsEngine` wrapper, build-verified

**The interrupt-hook question is resolved — empirically, and the real
answer contradicts what source/changelog reading suggested going in.**
`flutter_js: ^0.8.7` added. `QuickJsRuntime2`'s `timeout` (ms) constructor
parameter is genuinely passed straight into the native `jsNewRuntime` FFI
call (confirmed by reading the installed package's source), and the
package's own changelog (0.7.2: "upgraded quickjs code to allow set
timeout") strongly implied a real `JS_SetInterruptHandler`-style
interrupt. **A live test proved this wrong**:
`QuickJsRuntime2(timeout: 500).evaluate('while (true) {}')` did not
return — it hung the whole `flutter test` process until an external,
process-level timeout killed it. Whatever this installed version's
`timeout` actually gates, it is not the synchronous interpreter loop.

**The real, verified safety mechanism is isolate abandonment, not
interruption.** `lib/util/scripting/js_engine.dart`'s `JsEngine.run()`
spawns every script onto its own throwaway `Isolate` and races that
isolate's reply against a Dart-side `Future.timeout` on the *caller's*
side. A second live test confirmed the property that actually matters:
the caller reliably unblocks at the configured timeout **even when the
spawned isolate is permanently, unrecoverably stuck** in a genuine
infinite loop — a blocking native FFI call can't be preempted by Dart at
all, isolate boundary or not, but running it on a thread that isn't the
caller's means the caller (in production: the main app isolate) never
freezes because of it. The honest limitation, documented in
`JsEngine`'s own doc comment rather than hidden: a script that hangs
forever leaks its isolate/OS thread — `Isolate.kill` is called on
timeout as best-effort cleanup, but can't guarantee the underlying
thread is ever actually freed for a truly-hung script. This matches the
design doc's own original framing exactly ("the user-facing behavior —
kill, log, notify — stays the same, this only affects how 'kill' is
actually implemented") — it just turned out "kill" means "the app never
freezes," not "the runaway thread is always reclaimed."

**Real toolchain blocker found and fixed, unrelated to the interrupt
question:** `flutter_js`'s own `android/build.gradle` hardcodes
`kotlinOptions.jvmTarget = "1.8"` but never sets
`compileOptions.sourceCompatibility`/`targetCompatibility`, so it
silently inherited AGP 9.0.1's own default (11) for a bare
android-library module — AGP's Kotlin/Java consistency check then failed
`flutter build apk` outright ("Inconsistent JVM-target compatibility...
compileDebugJavaWithJavac (11) and compileDebugKotlin (1.8)"). Fixed with
a targeted `project(":flutter_js") { ... compileOptions { ... 1.8 } }`
override in the root `android/build.gradle.kts`, scoped to that one
subproject only (doesn't touch `:app`'s own Java 17 target) — same
category of fix as `windows/CMakeLists.txt`'s existing
`permission_handler_windows` coroutine-warning override: a project-level
compensation for an upstream plugin's own build config gap.

**`flutter build apk` now also names `flutter_js` alongside the
pre-existing `mobile_scanner` in the documented, non-fatal "applies
Kotlin Gradle Plugin (KGP) directly" warning** — same already-tracked
risk class (CLAUDE.md's Phase 2 Step 7 write-up), not a new one; revisit
alongside `mobile_scanner`'s if a future `flutter upgrade` ever turns
this into a hard failure.

**Tests:** `test/js_engine_test.dart` (4 tests) — a normal script
returns its value quickly, a thrown JS error reports as a failure (not a
timeout), a genuine `while (true) {}` reports `timedOut` and the caller
unblocks within ~1s (not never), a syntax error reports as a failure.
Run against the real QuickJS runtime, not mocked — needs
`quickjs_c_bridge.dll` copied from a prior `flutter build windows`
output into the repo root first, since `flutter test`'s plain console
host has no plugin-bundling step of its own (see the test file's own doc
comment) — not something to "fix," just a one-time local-run detail.
One real bug this test suite caught before it shipped: the first
`JsExecutionOutcome.timeout()` was a redirecting `const factory`
forwarding zero arguments to its target constructor, which silently
defaulted `timedOut` back to `false` — caught immediately by the
infinite-loop test failing with exactly that value, fixed by making it a
plain (non-redirecting) factory instead.

`flutter analyze` clean, `flutter build windows` and `flutter build apk
--debug` both clean (the `flutter_js`/`mobile_scanner` KGP warning
aside).

**Build-verified only — no UI/app wiring yet, none expected at this
step.** `JsEngine` is a standalone class with no consumer yet; the real
`record`/`table`/`notify`/`navigate` script API (step 3) is what actually
calls it from application code. Next: build order step 3.

## Step 3, concluded: the real `record`/`table`/`notify`/`navigate` script API, build-verified

**A real architectural tension surfaced immediately, resolved
deliberately rather than papered over:** QuickJS's `evaluate()` is
synchronous, but `sqlite_crdt`'s real write API is async, and this
project's own hardest-won rule (CLAUDE.md: "no record-level edits in
Letos/DBeaver, full stop") is that any write bypassing `sqlite_crdt`'s
own API silently never syncs. There is no way in Dart to synchronously
block one isolate's event loop on a `Future` without deadlocking it, so
a script's write calls can't get a real synchronous round-trip through
the correct async API on the same isolate that's running QuickJS.

**Resolved with a two-phase model, not a correctness-cutting
workaround.** `lib/util/scripting/script_api_runtime.dart`'s
`ScriptApiRuntime`:
- **Reads are genuinely synchronous** — `table('X').find()/.all()` are
  backed by a second, read-only connection opened with `package:sqlite3`
  directly (the real, non-async native call `sqflite_common_ffi` itself
  sits on top of) inside the same script-execution isolate. Safe because
  a `SELECT` needs no CRDT bookkeeping — no correctness risk, real
  synchronous mid-script data exactly as the design doc's API sketch
  implies.
- **Writes are deferred, not synchronous.** `record.save()`/`.delete()`
  and `table('X').create()` queue an in-memory action during the script
  (pure Dart, no I/O, so no synchronicity problem); once `evaluate()`
  returns — back in ordinary awaitable Dart code, not inside a
  synchronous native call frame — every queued write runs for real
  through a freshly-opened `SqliteCrdt` connection's own `execute()`,
  getting correct `hlc`/`node_id`/`modified` stamping automatically, the
  same way `GenericDao` already does it (including the identical
  rowid-alias-bypasses-DEFAULT fix for a new row's `id`). **Known,
  accepted v1 limitation, documented not hidden:** a script can't see
  its own `table('X').create()`/`record.save()` effects in a *later*
  read within the *same* run, since the read connection doesn't see a
  write that hasn't happened yet.
- **`notify`/`navigate` need no database access at all** — captured into
  an in-memory list during the script, reported back as `ScriptEffects`
  once the run finishes, never dispatched by this layer. Real dispatch
  (an actual SnackBar/Navigator push when a UI exists) is build order
  step 4's job — matches the design doc's own "navigate.* ... a no-op
  ... when the app is backgrounded" framing exactly: this layer doesn't
  know or care whether a UI exists, it just reports what the script
  asked for.

**A second real risk investigated and designed around before writing any
code: `sqlite_crdt`'s own identity derivation.** Reading `sql_crdt`'s
source confirmed a load-bearing, previously-undocumented mechanism: a
fresh `SqliteCrdt.open()` against an already-populated db has no stored
`node_id` at all — it derives its `nodeId` from `canonicalTime`, which
comes from `_getLastModified()`, a **global** `MAX(modified)` scan across
every table with no per-node filter. Any explicit `nodeId` argument to
`open()`/`init()` is silently discarded whenever the db already has data
(confirmed in `sql_crdt`'s own doc comment: "only works for empty
CRDTs"). This is not new risk introduced by this step — it's how the
real app's own `DatabaseHelper._open()` has always worked, every single
launch, already-proven-safe by weeks of real multi-device usage — but it
meant a naive design (stamping script writes with some invented,
different node id) would have risked a genuinely serious identity-hijack
bug: if that invented id ever became the single globally-most-recent
`modified` row before the next full app relaunch, the relaunching app's
*own* connection could adopt it as its permanent identity going forward.
Resolved by not inventing an identity at all — the deferred-write
connection is a completely ordinary fresh `SqliteCrdt.open()` against the
same file, deriving its `node_id` exactly the same way any other fresh
connection to this database already does (including the real app's own
next relaunch) — no new mechanism, no new risk, just the existing,
already-trusted one applied once more.

**Bridge mechanism, confirmed by reading `flutter_js`'s actual source,
not guessed:** the package's well-known `sendMessage`/`onMessage`
channel is one-way (JS sends, Dart receives, no return value at all) —
not usable for `record.get()` etc., which need a real value back.
`QuickJsRuntime2` separately supports wrapping a plain Dart `Function` as
a genuine, synchronously-callable JS global via its internal
`_DartFunction`/`JSInvokable` mechanism (the same primitive
`initChannelFunctions()` itself uses for `sendMessage`) — confirmed
working via `runtime.localContext['setToGlobalObject']`, a `JSInvokable`
already set up by `.init()`, invoked directly to install
`__bridge_record_get`/`__bridge_table_find`/etc. as real global
functions. A short JS prelude (evaluated once per run, before the
script) wraps these primitives into the `record`/`table()`/`notify`/
`navigate` shapes the design doc's own API sketch shows.

**`ScriptApiRuntime` deliberately duplicates `JsEngine`'s small
isolate-spawn/timeout-race pattern rather than reusing `JsEngine`
itself** — `JsEngine.run()` takes a bare code string with no hook to
install bridge functions or open a database connection first, and this
project already has an established precedent (`MigrationService`/
`schemaStatements`) for small duplication over forcing a shared
abstraction onto two genuinely different jobs.

**Deliberately out of scope, flagged rather than silently skipped:**
deferred writes don't reindex `search_index` (unlike `GenericDao
.insert()`/`.update()`) — `SearchIndexService` assumes the normal app's
own `DatabaseHelper`/`SchemaRegistry` bootstrap, which this isolate
deliberately doesn't replicate. A record a script creates or edits won't
be findable via Search until something else touches it. Worth closing
once this API has a real caller (step 4) and the gap's actual impact is
clearer.

**Tests:** `test/script_api_runtime_test.dart` (7 tests), every table
created through the real `SchemaEditorService` pipeline, run against the
real `essentials.db` — `record.get/set/save` round-trips to a real,
re-readable value; `record.delete()` really soft-deletes; `table(x)
.all()/.find()` see real committed rows; `table(x).create()` produces a
real row after the script finishes; `notify`/`navigate` calls are
captured as effects, never dispatched; a scheduled-style run with no
bound record sees `record === null`; `record.save()` with no bound
record fails clearly rather than crashing silently. All passed on the
first real run against the live db. Confirmed after: zero leaked
physical test tables, `PRAGMA integrity_check: ok`.

`flutter analyze` clean, `flutter build windows` and `flutter build apk
--debug` both clean (needs `quickjs_c_bridge.dll` copied from a prior
Windows build into the repo root to run `test/script_api_runtime_test
.dart`/`test/js_engine_test.dart` locally — see `JsEngine`'s own test
file for why).

**Build-verified only — no UI/event wiring yet.** `ScriptApiRuntime` has
no consumer yet; build order step 4 (data + UI event wiring off
`SyncService.dataChanges` and existing form lifecycle, the foreground
in-app path) is what actually calls it from real app code and gives
`notify`/`navigate`'s captured effects somewhere real to go.

## Step 4, concluded: foreground event wiring, build-verified

**A real correction to this design doc's own original assumption, found
by reading the actual code before wiring anything up.** The "What the
code already does today" section above claimed `SyncService.dataChanges`
"already broadcasts local data-change events." It doesn't — reading
`SyncService`'s source confirmed that stream is fed exclusively from
`onChangesetReceived`, which only fires for a changeset *received from a
remote peer*, never for a write made on this device. Wiring data events
to it as originally planned would have meant a "record created" script
never fires for the overwhelmingly common case (the user creating a
record through this device's own form) and instead fires in a burst for
every row a reconnect happens to pull in — backwards from the obvious
intent, and a real risk of a notification flood the first time a device
reconnects after being offline. **Data events are dispatched from the
real local write call sites instead** — `GenericFormScreen`'s save flow,
`GenericListScreen`'s delete flow — which is also where the design doc's
own UI events (`form_opened`/`form_closed`/`button_clicked`) already had
to hook in regardless. Flagged as an explicit, open follow-up, not
silently dropped: whether a data event should *also* fire for a change
that arrives purely via sync from another device is a real, unresolved
question, worth revisiting once real usage shows whether it's wanted.

**New: `lib/db/event_dispatch_service.dart`'s `EventDispatchService`** —
`dispatch()` finds every enabled `event_definitions` row matching an
event (table + event type, plus field name for `field_changed`), runs
each bound script through `ScriptApiRuntime`, and returns the results;
`dispatchAndApplyEffects(context, ...)` layers real UI dispatch on top —
a `notify()` becomes a `SnackBar`, a `navigate.*` becomes a real
`Navigator.push` (to `GenericListScreen` for `navigate.to`, or a real
`GenericFormScreen` pre-loaded with the target row for
`navigate.toRecord`), and a failed/timed-out script surfaces its own
`SnackBar` instead of silently vanishing. Deliberately split this way,
mirroring `ScriptApiRuntime`'s own "don't assume a UI exists" posture —
`dispatch()` alone is what a future background/scheduled caller (steps
6-8) will use, with no `BuildContext` anywhere near it.

**Wired into real screens:**
- `GenericFormScreen.initState`/`.dispose` — `form_opened`/`form_closed`,
  fire-and-forget (same reasoning as `ThemeController.load()`'s own
  initState call: nothing here needs to block rendering).
  `form_closed` deliberately uses bare `dispatch()`, not
  `dispatchAndApplyEffects` — the widget is already being torn down by
  the time a script would finish, so there's no context left to show
  anything in; the script's own database writes still happen normally.
- `GenericFormScreen._save` — `record_created` (insert only) or
  `record_updated` + one `field_changed` per actually-changed field
  (edit only, a plain value diff against `widget.existing`), then
  `record_saved` either way — all dispatched (and effects applied)
  *before* popping, while `context` is still guaranteed to be this
  screen's own mounted one, not whatever screen a pop already returned
  to.
- `GenericListScreen._delete` — `record_deleted`, after the real delete
  succeeds, before the grid reloads.
- **`button` fields are now real and clickable**, replacing step 1's
  disabled placeholder. Deliberately handled directly in
  `GenericFormScreen._buildField` (a new `_buildButtonField`), *not*
  through `ButtonFormatHandler.buildFormField` — the shared
  `FieldFormatHandler` interface has no way to pass a table name or
  record id, which a real `button_clicked` dispatch genuinely needs
  (unlike every other Phase 2 format). `ButtonFormatHandler` stays
  registered for `GenericListScreen`'s grid column alone, which needs no
  click-dispatch. Disabled until the record actually exists (no id yet
  on an unsaved Add) — same reasoning `TableConfig.openRowDetail`'s own
  doc comment already gives for the reverse-relation panel being
  edit-only.

**Deliberately out of scope for this step, flagged rather than silently
skipped:** `GenericListScreen`'s own inline grid cell-edit path
(`_saveCellEdit`) is a second, separate write call site that could fire
`record_updated`/`field_changed` too but doesn't yet — a known, bounded
scope limit rather than touching every code path in an already-large
screen in one pass.

**A real leak caught and fixed in this step's own test file, worth
remembering.** `test/event_dispatch_service_test.dart`'s first version
inserted real `script_definitions`/`event_definitions` rows with no
`addTearDown` cleanup at all — these two new infra tables are just as
`sqlite_crdt`-tracked as any other, so a bare `INSERT` with nothing
undoing it doesn't leave inert test residue, it leaves a **permanently
live row in the real production `essentials.db`**. Caught immediately by
checking the live db directly after the first test run (`is_deleted = 0`
on all 4 rows, not the tombstoned residue every other v2 test file's
discipline produces) — recovered via a real, synced soft-delete
(`crdt.execute('UPDATE ... SET is_deleted = 1 ...')`, never a raw
hard-delete) through a one-off throwaway script, then fixed at the
source: `bindScript`'s helper now registers real `addTearDown` cleanup
for both rows it creates. Re-run and reconfirmed clean afterward.

**Tests:** `test/event_dispatch_service_test.dart` (5 tests) cover
`dispatch()`'s own logic against the real `essentials.db` — a bound,
enabled script runs and its outcome/effects come back correctly; no
binding means nothing runs; a disabled binding doesn't run; `field_changed`
matches only its own field name; a dispatched script's real database
write actually persists. The UI half (`dispatchAndApplyEffects`'s
`SnackBar`/`Navigator` dispatch, and the real `GenericFormScreen`/
`GenericListScreen` wiring — button clicks, form lifecycle, save/delete)
needs a real widget tree and isn't covered by an automated test here;
build-verified only, Mike's own interactive pass is next.

`flutter analyze` clean, `flutter build windows` and `flutter build apk
--debug` both clean. Direct SQL check after: zero leaked physical test
tables, all `script_definitions`/`event_definitions` test rows correctly
tombstoned, `PRAGMA integrity_check: ok`.

**Build-verified only — not yet Mike-tested interactively.** Next, when
resumed: since no UI exists yet to create a real `event_definitions`
binding (that's build order step 5), Mike's own verification of this
step specifically needs either a hand-inserted test row (same shape this
step's own test file already uses) or waiting until step 5's Script
Editor/Event Binding UI exists to create one through the app itself.
Reasonable to build step 5 next before asking for a real interactive
pass, so there's an actual UI to test the whole chain (write a script →
bind it to an event → trigger the event → see the effect) end to end in
one go, rather than two disjointed checkpoints.

## Step 5, concluded: Script Editor + event binding UI, build-verified

**Script editor package, per the design doc's own confirmed "decide at
implementation time" call:** `flutter_code_editor` (akvelon) — pure
Dart/Flutter (`CodeController` extends `TextEditingController` directly,
no native platform code at all, unlike `flutter_js`/`mobile_scanner`, so
real integration risk was low), Windows+Android both supported, JS
syntax highlighting via the `highlight` package's language table.
`highlight` added as a direct dependency too (`langJavascript` is
imported directly for `CodeController`'s `language` parameter). The
design doc's own plain-`TextField` fallback was never needed — no
friction hit integrating it.

**New DAOs, `lib/db/script_definitions_dao.dart`/`event_definitions_dao
.dart`** — same shape/conventions as `TemplateDefinitionsDao`/
`ViewDefinitionsDao` (plain row-level CRDT writes against an
already-bootstrapped table, no `migration_log` involvement, since
writing a script's *code* or a binding is never DDL). Both correctly
inject `id`'s own SQL `DEFAULT` expression on create, same
rowid-alias-bypasses-DEFAULT fix every other timestamp+random-id table
in this app already needs — confirmed by checking, not assumed, since
`SqliteCrdtHelpers.insertGetId`'s "id is a rowid alias" shortcut
specifically doesn't hold here (these two tables use the same
timestamp+random scheme as `migration_log`/`view_definitions`, not a
plain `AUTOINCREMENT`).

**`lib/screens/script_editor_screen.dart`** — `ScriptEditorScreen` (list:
name, description, edit, delete, new) + `ScriptEditScreen` (full-screen
`CodeField` editor), reached via a new "Scripts" nav rail/drawer entry,
same pattern as Search (Phase 6) per the design doc's own instruction.

**Event binding UI, one real deviation from the design doc's own
sketch, deliberate and documented, not silent:** the doc's "Event binding
UI" section floated configuring `button_clicked` "at field-creation time
via `AddFieldScreen`/`ManageFieldsScreen`." Built differently:
`field_changed` and `button_clicked` are both just `event_definitions`
rows with a `field_name` set — exactly the same shape every other
binding already has — so `lib/screens/manage_events_screen.dart`'s
`ManageEventsScreen` handles **all** per-table event types uniformly
(data events, form lifecycle, `field_changed`, `button_clicked`) in one
screen, reached from Settings alongside Manage Tables/Manage Fields,
rather than splitting `button_clicked` out to a second UI surface for no
structural reason. Picking `button_clicked` narrows the field picker to
this table's own `button`-format fields only; every other field-scoped
type offers every field.

**`lib/screens/scheduled_events_screen.dart`'s `ScheduledEventsScreen`**
is the one genuinely *global* (not per-table) binding screen, per the
design doc's own explicit call — `app_launch`/hourly/daily/weekly,
`schedule_config` built as the exact JSON shape the design doc's schema
comment specifies (`{time: "08:00"}` / `{day: "mon", time: "08:00"}`).
**Deliberately inert right now, and says so in its own UI copy** — this
screen only builds the *binding*; `app_launch` actually firing is step 6,
real background firing for the other three is steps 7-8 (pending that
build's own Windows-path spike). Creating a schedule today is the same
"visibly staged, not yet functional" precedent `button` fields already
set between steps 1 and 4.

**Tests:** `test/script_event_daos_test.dart` (6 tests) — script
create/update/softDelete round-trip against `loadAll`; event bindings
round-trip for a table via `loadForTable`; a scheduled (no-table)
binding is found by `loadScheduled` and correctly absent from
`loadForTable`; `setEnabled` toggles a binding in place. All pass
against the real `essentials.db`, zero leaked active rows confirmed
directly after (`PRAGMA integrity_check: ok`). The UI screens themselves
(`ScriptEditorScreen`/`ManageEventsScreen`/`ScheduledEventsScreen`) have
no automated widget coverage — build-verified only, same as every prior
UI-heavy step in this project; Mike's own interactive pass is next.

`flutter analyze` clean, `flutter build windows` and `flutter build apk
--debug` both clean (the `flutter_js`/`mobile_scanner` KGP warning
aside, unchanged by this step).

**Build-verified only — not yet Mike-tested interactively.** Next, when
resumed: on MIKE-CU, write a real script (e.g. `notify('Hello from a
script!');`), bind it via Manage Events to `record_created` on a real
table, create a record through that table's form, confirm the SnackBar
appears; try a `button_clicked` binding on a `button` field and confirm
tapping it runs the script; try `form_opened`/`form_closed`; try
`field_changed` on one specific field and confirm it does *not* fire for
other fields; create a scheduled event and confirm the UI correctly
shows it as inert (no firing expected yet); then F5/relaunch MIKE-12R to
confirm scripts/bindings sync and work identically there. This is the
first real end-to-end interactive checkpoint for the whole phase so
far — everything through step 4 was build-verified only, with no UI to
create a binding through.

**Mike's first real check found the script editor worked correctly on
MIKE-CU (a "Test Script 1" script with `x=1;` created successfully,
confirmed via screenshot) — but "Scripts" was missing from MIKE-12R's
nav entirely.** Root-caused immediately, not a code bug: MIKE-12R was
simply running a build from before this whole session's work landed --
the exact same "Code never pushes installs to a device mid-session on
its own" pattern already documented for Phase 2's real-device pass.
Fixed by pushing the already-built debug APK directly (`adb install
-r`) -- confirmed a device was reachable first, no code change needed.

## Step 6, concluded: `app_launch` firing, build-verified

Per the design doc's own framing ("Both platforms — `app_launch`
events: Straightforward regardless of the above: run once per app
process start, in the normal foreground app, no background mechanism
needed") -- genuinely small once steps 3-5 existed to build on.

**`EventDispatchService.dispatch`/`.dispatchAndApplyEffects` widened to
accept `String? tableName`**, not just `String` -- a scheduled/
`app_launch` binding has `table_name IS NULL` per the design doc's own
schema, and the underlying SQL already used `IS` (not `=`) for exactly
this reason (confirmed correct, not just convenient, by the new test
below). This is what makes the *existing* dispatch machinery from step 4
reusable here with zero new querying logic -- `app_launch` firing needed
no new mechanism, just a wider type on an already-correct query.

**Wired into `HomeShell._bootstrapAndLoadGroups`**, fire-and-forget
(same reasoning as the neighboring `ThemeController.load()` call: nothing
here needs to block nav rendering), positioned *after* migrations are
applied so a launch script can safely reference current-session schema,
alongside the existing per-launch bootstrap work (search index,
sync connect). Runs once per real app process start, matching
`HomeShell`'s own lifetime -- it's the app's top-level widget, so its
`initState` only fires once per launch, not on every rebuild.

**`ScheduledEventsScreen` updated to stop implying all four schedule
types are equally live** -- `app_launch` now genuinely fires;
hourly/daily/weekly remain correctly stored but inert (steps 7-8), and
the screen's own copy and per-binding label now say so explicitly
("not yet active") rather than leaving Mike to discover the difference
by testing.

**Tests:** `test/event_dispatch_service_test.dart` extended (+1 test,
6 → 7) -- a null-`tableName` dispatch correctly matches an `app_launch`
binding (`table_name IS NULL`), and a table-scoped dispatch for the same
event type correctly matches nothing, confirming the `IS` comparison
isn't accidentally treating `null` as a wildcard in either direction.
All 7 pass against the real `essentials.db`. Confirmed after: the only
active `script_definitions` row is Mike's own real "Test Script 1" from
his interactive pass above, zero leaked test rows, `PRAGMA
integrity_check: ok`.

`flutter analyze` clean, `flutter build windows` and `flutter build apk
--debug` both clean (same pre-existing KGP warning). Debug APK pushed to
MIKE-12R directly, matching this step's own opening finding.

**Build-verified only — not yet Mike-tested interactively.** Next, when
resumed: bind a script to `app_launch` via Scheduled Events (e.g.
`notify('Welcome back!');`), fully close and relaunch the app on
MIKE-CU, confirm the SnackBar appears once at launch; confirm it does
*not* fire again on a hot-reload/rebuild, only a genuine process
relaunch; F5/relaunch MIKE-12R to confirm it works there too.

## Two real bugs found by Mike's first live test, both fixed same session

**`app_launch` itself worked perfectly** — bound `notify('App launched at
' + new Date().toLocaleTimeString());` to `app_launch`, relaunched, saw
the SnackBar with a live timestamp. Confirms step 6's actual mechanism
end to end, on real hardware, not just build-verified.

**Bug 1 (real, functional): `table()` required the physical table
identifier, never shown anywhere else in this app's UI.** Mike's second
test script, `table('Subscription Tracker').all()`, errored outright —
`Subscription Tracker` is the *display* name shown in the nav (the only
name a script author ever actually sees), but the bridge's
`assertSafeSqlIdentifier` check rejected it (the space fails the
identifier regex) before ever reaching a query. This app has a
long-standing, explicit rule for exactly this situation
(`SchemaRegistry.discoverTableNames()`'s own doc comment: a physical
identifier is never something a human should have to type) that the
script API's first version simply never applied. **Fixed:**
`_resolveTableName` (in `lib/util/scripting/script_api_runtime.dart`) —
`table('X')` now tries `X` as a real physical name first (so a script
author who already knows it isn't penalized), then falls back to a
case-insensitive match against `table_definitions.display_name`, and
throws a clear `"No table named ... found."` error naming exactly what
was looked up when neither matches, rather than a confusing raw SQL
failure. Applied to every table-name-taking bridge call
(`find`/`all`/`create`/`navigate.to`) — `_rowsToJson`'s injected
`__table` field (what `navigate.toRecord` later reads back) now carries
the *resolved* physical name too, so a follow-up `navigate.toRecord(row)`
on a row fetched by display name still works correctly.

**Bug 2 (real, cosmetic but confirmed live): the code editor never had a
real syntax-highlighting theme applied at all, which is also why selected
text was hard to read.** `CodeField` was never wrapped in a `CodeTheme` —
every token rendered the same plain color (defeating the whole reason
this package was chosen over a bare `TextField`), and this package's
fallback text/selection colors don't reliably contrast against each other
with no theme supplied, confirmed exactly matching what Mike saw.
**Fixed:** wrapped in `CodeTheme(data: CodeThemeData(styles:
monokaiSublimeTheme))` (from the `flutter_highlight` package, added as a
direct dependency alongside `highlight`) for real JS syntax coloring, plus
an explicit `TextSelectionThemeData` (amber selection/cursor, chosen
against `monokaiSublimeTheme`'s specific dark background rather than
trusting the ambient app `Theme.of(context)`, since this editor's
background is always dark independent of the app's own light/dark
setting).

**Tests:** `test/script_api_runtime_test.dart` extended (+2 tests, 7 → 9)
— `table()` resolves a real display name (including case-insensitively,
deliberately tested via `.toUpperCase()`), and an unknown name fails with
a clear, named error rather than a raw SQL one. One pre-existing test in
`test/event_dispatch_service_test.dart` needed fixing too, found while
re-running the suite -- its `app_launch` dispatch test assumed it was the
only such binding in the database, which stopped being true the moment
Mike's own real "Script 1" binding existed (same "don't assume you're the
only row of this shape" lesson this project already learned once for
`view_definitions_dao_test.dart`) -- fixed to assert against its own
uniquely-tagged notification instead of the total result count. All 9 +
6 tests pass against the real, now-live `essentials.db` (including Mike's
own real data), zero leaked test rows confirmed after,
`PRAGMA integrity_check: ok`.

`flutter analyze` clean, `flutter build windows` and `flutter build apk
--debug` both clean. Debug APK pushed to MIKE-12R directly.

**Not yet re-verified by Mike** — next: retry the exact `table('Subscription
Tracker').all()` script (or similar) and confirm it now works; check the
script editor's text coloring/selection contrast visually on both
platforms.

## Third bug, found on re-verification: a real setState/Future crash on MIKE-12R

**CU confirmed both fixes above worked.** MIKE-12R crashed opening the
script list at all -- Flutter's own "setState() callback argument
returned a Future" assertion, debug-build-only (confirmed: silent on
CU's release-ish exe, crashed on 12R's debug APK, exactly matching this
project's own already-documented pattern for this exact class of bug --
see Auto Memory `setstate_arrow_closure_bug.md`).

**Root cause:** `ScriptEditorScreen._reload()`'s
`setState(() => _scriptsFuture = _dao.loadAll())` -- an assignment
expression evaluates to its own right-hand value, so that arrow-bodied
callback's return type was itself `Future<List<ScriptDefinition>>`, not
`void`. A quick grep of every other `setState(() => ...)` written this
step (`ManageEventsScreen`, `ScheduledEventsScreen`) confirmed this was
the only instance actually assigning a `Future`-returning call -- every
other one assigns an already-resolved value (a dropdown's picked value,
a bool literal, an awaited result) and was never at risk.

**Fixed** by switching to a block-bodied `setState(() { ... })`, which
always returns `void` regardless of what runs inside it -- the same fix
this project's own memory already prescribes for this exact pitfall.
`flutter analyze` clean, both builds clean, pushed to MIKE-12R directly.

**Not yet re-verified by Mike on MIKE-12R** — next: confirm the script
list now opens without crashing there, then continue the original
checklist (the `table()` display-name fix, editor theming) on that
platform too.
