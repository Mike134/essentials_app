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
