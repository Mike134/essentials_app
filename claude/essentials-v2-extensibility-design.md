# Scripting extensibility — design (2026-09-05)

**Status: built and real-device verified on MIKE-CU (Windows); see "Built
and verified" and "Renamed and extended" at the end of this doc.**
**Naming note:** everywhere below that says `readFirstLine(path)` is the
function's original name during design/first build -- it was renamed to
`readFileFirstLine(path)` immediately after, alongside a new sibling
`readFileLines(path, n)`, per Mike's own request for clearer naming. See
"Renamed and extended" for the final names and behavior; the reasoning
in the body below (no path restriction, verbatim error sentinel, sync
implementation) is unchanged and still applies to both functions.

Promotes two of the items from `claude/essentials-v2-extensibility-brainstorm.md`
(2026-09-05, pure brainstorm, not a committed direction) into a real,
buildable design. The brainstorm's other material — the stock-price use
case, the four-tool ecosystem framing, the open trust-model/configuration
questions for a *future*, more invasive capability — stays exactly where
it is, in that file. This doc narrows to what Mike confirmed ready to
build now, in a short back-and-forth that settled every open question
below by discussion, not by guessing:

1. Give the script sandbox a real way to reach outside itself, in the
   same additive, low-blast-radius style the sandbox already uses
   internally.
2. One concrete first capability to prove the pattern against:
   `readFirstLine(path)` — open a file, read its first line, close it,
   return the line (or a real error) to the script.

Network access (the original stock-price motivation) is deliberately
**not** this capability, and not designed here — Mike's own call: it
drags in API research, cost/availability/long-term-viability questions,
and probably a real permission/configuration model, "almost a project in
and of itself." `readFirstLine` is a plain, synchronous, local capability
with a small, closed failure surface — the better first proof of the
pattern. Network access stays named in the brainstorm doc as a future
example of the same pattern, to be designed on its own later.

## The core constraint: additive, isolated capability addition

This is the thing being proven, not just `readFirstLine` itself. The
rule, stated as something checkable, not just an aspiration:

**Adding a new script capability must never require changing an existing
installed bridge function or an existing JS-side wrapper.** It's always
exactly two additions: one new `install('__bridge_x', ...)` call in
`_installBridge` (`lib/util/scripting/script_api_runtime.dart`), and one
new small JS snippet in that same function's trailing `runtime.evaluate('''...''')`
block, defining the JS-facing name (a plain function, or a property added
onto an existing object like `record`/`navigate` if that's a better fit
— `readFirstLine` is a new bare global function, not a property of
anything that exists today).

This isn't a new mechanism — it's already exactly how this session's own
`deviceId()`/`localTime()`/`localTime.iso()` additions were built,
alongside the pre-existing `record`/`table()`/`notify()`/`navigate`.
Confirmed, not assumed: adding those two touched zero lines of the
`record`/`table`/`notify`/`navigate` code, and the full existing test
suite for `script_api_runtime.dart` and every scheduling test that
exercises it needed zero changes. `readFirstLine` is the next data point
proving the same claim, this time for a capability that genuinely leaves
the sandbox (real filesystem I/O) rather than one that stays inside it
(reading the device's own clock/name).

**What "isolated" concretely means here, checked at build time, not just
asserted:**
- No existing bridge function's Dart implementation changes.
- No existing JS wrapper's source changes.
- No change to `ScriptRunContext`, `ScriptEffects`, or `ScriptRunResult`'s
  shape — `readFirstLine` needs none of them; it's a pure synchronous
  call with a return value, same shape as `record.get()`.
- The full existing script-engine test suite passes unchanged.

**The one honest limit to this claim, carried over from the brainstorm
doc, not resolved here — flagged so it isn't quietly forgotten:** this
"just add a function" story is confirmed for a capability that's *purely*
additive, exactly what `readFirstLine` is (no configuration, no
permission gate, nothing stored anywhere about it). It is **not** yet
proven for a capability that needs configuration or a permission decision
attached to it (a hypothetical future `fetch(url)` might need "is this
script allowed to do this" plumbing that a bare bridge function doesn't).
Nothing here claims that harder case is solved — only that this specific,
concrete, unconfigured case is.

## `readFirstLine(path)`

### Behavior

- Takes one argument: a file path, exactly as given, on whichever device
  the script is currently executing on (same "local to this device"
  framing as `deviceId()`/`localTime()` — a path that's valid on MIKE-CU
  is not expected to mean anything on MIKE-12R, and that's fine, not a
  bug to guard against).
- **No path restriction of any kind.** Attempts to open exactly the path
  given, unconditionally — no allowed-directory list, no extension check,
  no size pre-check, no symlink handling, nothing. Mike's own explicit
  call: "let the file system decide what the user has access to." The
  real OS-level file permissions are the only gate that exists, exactly
  the same as any other program running as the same user on the same
  device — a script here has no more and no less filesystem reach than
  Mike himself already has, opening a terminal on the same device.
- On success: returns the file's first line as a plain string (no
  trailing newline character), exactly like reading line 1 of the file
  in a text editor.
- On any failure (file doesn't exist, permission denied, path is a
  directory, path is on a drive/share that isn't currently reachable, the
  file is empty, anything else): returns a single sentinel string,
  **the real underlying exception's own `toString()`, wrapped verbatim**:
  ```
  <<${exception.toString()}>>
  ```
  No categorization, no paraphrasing, no invented bucket of "the" reasons
  a read can fail. Whatever Dart's `File.openRead`/`readAsString`
  machinery actually reports (a `FileSystemException`'s own message,
  which already includes the OS error text and the path) comes through
  untouched. Deliberately not `try { ... } catch (e) { return '<<$e>>'
  }` narrowed to `FileSystemException` only — a bare `catch (e)` is
  correct here specifically because nothing about this function should
  ever crash the calling script; whatever actually goes wrong, the
  sentinel format is the same.
  **Why not several different canned messages ("Access denied.", "File
  not found.", ...):** discussed and rejected. A canned bucket loses
  real diagnostic information (which OS error, which path, sometimes an
  underlying errno) that the real exception text already has for free,
  and a fixed set of buckets means a support conversation every time a
  failure mode doesn't fit one of them ("why did I only get a generic
  message"). Passing the real text through once, verbatim, closes that
  off permanently — there is no bucket list to ever have to expand.
- An **empty file** (zero bytes) is not an error — returns an empty
  string `''`, the correctly literal "first line" of a file with no
  lines. Distinguished from every real failure case by not throwing at
  all.

### Why `<<...>>` as the sentinel, and how a script tells success from failure

`<<`/`>>` have no special meaning in Markdown (irrelevant here, since this
is a runtime string value, not markdown, but confirmed while discussing
this) and — more relevantly — no real file's first line plausibly
*starts* with a literal `<<`, so `result.startsWith('<<')` is a safe,
cheap way for a script to distinguish "this is an error" from "this is
real file content" without needing real JS `try`/`catch` around the call.

**This is deliberate, not a workaround for a known limitation.** Whether
a Dart exception thrown inside an `_installBridge`-installed native
function actually surfaces as a catchable JS exception through
`flutter_js`'s bridge mechanism has not been tested — nothing in this
codebase's existing bridge functions relies on that behavior today (every
existing one either can't fail, like `notify()`, or already returns
`null` on the "nothing to do" case, like `record.save()` with no bound
record, which throws a `StateError` rather than being probed for
JS-catchability). Returning a plain string sentinel sidesteps needing to
know the answer to that question at all -- correct and testable either
way, and consistent with the low-risk, don't-touch-what-already-works
posture the additive-isolation rule above asks for.

### Implementation sketch

`lib/util/scripting/script_api_runtime.dart`'s `_installBridge`, one new
`install(...)` call alongside the existing ones:

```dart
install('__bridge_read_first_line', (String path) {
  try {
    final file = File(path);
    final firstLine = file.openRead().transform(utf8.decoder)
        .transform(const LineSplitter()).first;
    // ...synchronous framing TBD at implementation time -- see "Sync
    // vs. async" below; this sketch shows the intent, not the final
    // exact call shape.
  } catch (e) {
    return '<<$e>>';
  }
});
```

And the matching JS-side wrapper, in the same function's trailing
`runtime.evaluate('''...''')` block:

```js
function readFirstLine(path) { return __bridge_read_first_line(path); }
```

**Sync vs. async, a real implementation detail to settle before writing
real code, not before this design:** the bridge mechanism this app uses
(`setToGlobalObject`/`JSInvokable`, per `_installBridge`'s own doc
comment) is documented as "a genuine synchronous Dart-function-as-JS-global."
Every existing bridge function backing this is synchronous Dart
(`sqlite3`'s own synchronous API, not `sqlite_crdt`'s async one — this is
exactly why `_runInIsolate` opens a raw `sqlite3.sqlite3.open()`
connection for reads, per that function's own doc comment). File I/O has
the identical shape available: Dart's `dart:io` offers both
`File.readAsStringSync()`/a manual synchronous line-1 extraction and the
async `Stream`-based API sketched above. **The synchronous form is very
likely the right choice** — matches every other bridge function's own
shape, avoids finding out the hard way whether this bridge mechanism
can even support an async native call at all (untested, and unlikely to
be worth being the first thing that tries). Read the *whole* file
synchronously and take its first line (splitting on `\n`, trimming a
trailing `\r`) rather than trying to stream-and-stop-at-the-first-newline
-- simpler, and the "large file" cost is a non-issue for the kind of file
this is meant to read (a small external sensor/log drop, not a video
file) -- if that assumption ever proves wrong, worth revisiting then,
not guarded against speculatively now.

### Test coverage, to write when this is implemented

Pure Dart, no `DatabaseHelper`/`SyncService` involved (same category as
`test/lookup_value_test.dart`/`test/bool_value_test.dart`) — a real
temporary file (via `dart:io`'s own `Directory.systemTemp`, cleaned up in
`tearDown`) is enough, no throwaway-table/schema-engine machinery needed
at all:
- Real file, one line, no trailing newline → that line back.
- Real file, multiple lines → only the first.
- Real file, empty → `''`, not an error sentinel.
- Path that doesn't exist → `<<...>>`, contains recognizable detail from
  the real exception (not a fixed string — assert `contains`, not
  `equals`, since the exact OS message can't be pinned across platforms).
- Path that's a directory → `<<...>>`.
- A full round-trip through the real JS wrapper (`runtime.evaluate` a
  script literally calling `notify(readFirstLine(path))` or similar, via
  `ScriptApiRuntime.run` end-to-end) at least once, matching how
  `deviceId()`/`localTime()` were verified — proves the JS-to-Dart
  plumbing itself, not just the Dart function in isolation.

## Not designed here, deliberately deferred

Everything below stays exactly as open as `claude/essentials-v2-extensibility-brainstorm.md`
already left it — restated here only so this doc doesn't read as if it
quietly answered them:

- **Network access** (`fetch`-style) — the original motivating idea,
  still a real future direction, still needs its own research pass
  (which API/service, cost, reliability) and its own design doc once
  Mike is ready to take that on as its own piece of work.
- **Any permission/configuration model** for a capability that needs
  one — `readFirstLine` doesn't need one (no restriction, by design), so
  this design proves nothing either way about how a future
  gated capability would work.
- **Writing to a file**, reading more than one line, or any other
  filesystem operation beyond "read the first line" — natural, obvious
  extensions of the exact same additive pattern (`writeLine(path,
  text)`, `readLines(path, n)`, ...), intentionally not built now. Naming
  them here is just so `readFirstLine`'s own narrow scope doesn't read as
  a permanent ceiling on what this mechanism could support later.

## Built and verified (2026-09-05)

Built exactly as designed above, no changes from the sketch:
`readFirstLineOf(String path)` (`lib/util/scripting/read_first_line.dart`)
is a small, pure Dart function -- `File(path).readAsLinesSync()`, empty
list -> `''`, any thrown exception -> `'<<$e>>'` verbatim, a bare
`catch (e)` on purpose. `script_api_runtime.dart`'s `_installBridge`
gained exactly one new line (`install('__bridge_read_first_line',
readFirstLineOf)`) and the JS-side wrapper `function readFirstLine(path)
{ return __bridge_read_first_line(path); }` -- confirming the additive-
isolation claim above held for real: zero changes to any existing bridge
function, zero changes to `record`/`table`/`notify`/`navigate`/
`deviceId`/`localTime`'s own code.

**Confirmed via the same diagnostic-table technique used for
`deviceId()`/`localTime()`** (a real throwaway table + an app_launch-bound
script, run through a real built Windows exe, not a test host --
`flutter_js` has no working implementation under `flutter test`, same
limitation as ever): a real file's first line came back correctly
(second line excluded), a missing path came back as `<<PathNotFoundException:
... errno = 2>>`, and a directory path came back as `<<PathAccessException:
... errno = 5>>` -- exact real exception text, verbatim, exactly as
designed. 6 new unit tests (`test/read_first_line_test.dart`) pass
independently of the bridge (single line, multi-line, CRLF, empty file,
missing path, directory path).

**Android verification did not reach a clean conclusion, for reasons
unrelated to the feature itself.** Testing on MIKE-12R ran straight into
this project's already well-documented `crdt_sync` batch-atomicity race
(a new table's `migration_log`/row data landing in one all-or-nothing
merge before the physical table exists at the receiving end -- see
CLAUDE.md's several "recurring batch-atomicity sync bug" writeups) --
recovered via the existing `tool/adopt_migrations.dart` playbook, but the
underlying schema/script/event metadata for this particular diagnostic
table never fully re-converged across MIKE-CU/the server/MIKE-12R before
diminishing returns set in for what was only ever meant to be a
verification nicety, not a real feature. Cleaned up fully afterward
(diagnostic table dropped and confirmed gone on MIKE-CU and the server,
`PRAGMA integrity_check: ok`, no residue left) rather than abandoned
mid-mess. **Not a finding about `readFirstLine` itself** -- the bridge
function's own code has zero platform-conditional logic (same
`_installBridge` code path runs on both platforms, already proven via
`deviceId()`/`localTime()` working identically on both), so the Windows
confirmation plus the pure-Dart unit tests are the real evidence this
works; the Android sync noise was purely an artifact of two overlapping
diagnostic tables sharing one display name in quick succession during
testing, not a code defect worth chasing further. Worth a plain
in-app confirmation on MIKE-12R next time Mike is using a real script
that calls it, but not treated as a blocking gap.

## Renamed and extended (2026-09-05, same day)

Mike asked for two changes right after the first build: rename
`readFirstLine(path)` to **`readFileFirstLine(path)`** ("makes clearer
what the function is doing") and add a sibling, **`readFileLines(path,
n)`**, for the more general "give me up to n lines" case he'd originally
had in mind. Both now live in `lib/util/scripting/read_file.dart`
(renamed from `read_first_line.dart`, since the two functions are
tightly related enough to share one small file, unlike e.g. `bool_value
.dart`/`lookup_value.dart`'s one-function-per-file norm).

**`readFileFirstLine(path)`** — unchanged behavior from everything
above, new name only (`readFileFirstLineOf` on the Dart side,
`__bridge_read_file_first_line` as the bridge name).

**`readFileLines(path, n)`** — same no-restriction/verbatim-error
posture, extended to a bounded line count:
- Returns up to `n` lines from the start of the file, as a **real JS
  array** of strings — not a single joined string. Follows this app's
  existing convention for structured values crossing the bridge
  (`table().find()`/`table().all()` already return JSON, parsed by the
  JS wrapper) rather than inventing a new shape: the Dart side
  (`readFileLinesOf`) returns a JSON-encoded array string;
  `readFileLines`'s JS wrapper calls `JSON.parse` on it, *unless* the
  string starts with `<<`, in which case it's an error and gets returned
  as-is (a real array and an error string are different JS types, so the
  wrapper has to check before parsing).
- **`n <= 0` means "every line in the file," not zero lines** — a
  deliberate default: there's no everyday reason a script would ask this
  function for nothing, so a non-positive count reads as "no limit"
  rather than a literal empty result. Requesting more lines than the
  file has just returns however many real lines exist — no padding, no
  error.
- An empty file still returns `''`/`[]` respectively for both functions,
  never an error, same reasoning as before.

Confirmed end-to-end through the real QuickJS bridge on MIKE-CU
(`build/windows`), same diagnostic-table technique as the first build:
`readFileFirstLine` unchanged (`Hello from a real file`), and
`JSON.stringify(readFileLines(path, 1))` correctly round-tripped a real
JS array (`["Hello from a real file"]`) through the JSON-encode/parse
bridge. 6 new unit tests added to `test/read_file_test.dart` (now 12
total across both functions, including the `n <= 0`/more-lines-than-exist/
empty-file/error cases for `readFileLinesOf`) — all pass. `flutter
analyze` clean. `USER_GUIDE.md` updated with both final names.
