# Scripting extensibility — brainstorm (2026-09-05, not designed, not built)

**Status: pure brainstorm, captured verbatim from a conversation, not a
committed direction.** No design pass has happened, nothing is scoped,
and nothing should be built from this doc alone. Written down so the
idea survives past the conversation it came from, per this project's own
standing practice for anything worth remembering later — see
`claude/essentials-v2-architecture.md`'s "Deferred" list for the same
treatment given to other not-yet-built ideas (e.g. `attachment` before
the image field design, `link_record`/`rollup` before Phase 4).

## Where this came from

Mike described a concrete use case: a stock-symbol table where a daily
scheduled script (around 18:00, either device) would fetch each symbol's
current price from the web and write it into a "last updated value"
field — replacing an unreliable Excel stock-price formula he uses today.

The script API as built (see `USER_GUIDE.md`'s "Scripts and events")
deliberately has **no network access at all** — `record`/`table()`/
`notify()`/`navigate`/`deviceId()`/`localTime()` are the entire surface,
on purpose (see `lib/util/scripting/script_api_runtime.dart`'s own doc
comment on why the sandbox is this narrow). A calculated (formula) field
can't do this either — it's a pure, local expression over other fields
in the same row, no I/O of any kind.

Mike's explicit framing, worth preserving verbatim in spirit: if this
capability is ever built into `essentials_app` itself, it has to be
**generic and workable entirely through the app's own UI** — no
user-specific hardcoding of "the stock API" or any other one-off
integration point. The reasoning: `essentials_app` is increasingly one
of a small number of tools Mike is building his actual workflow around
(alongside Microsoft 365, Obsidian, and AI assistants — Claude/ChatGPT —
across both Windows and Android), and anything added to it needs to be
something a future user other than Mike could also configure, not
something only Claude Code could set up by hand.

## The extensibility idea itself

Mike's proposed shape for how to build *this and any future scripting
capability*, not just network access specifically: give `essentials_app`
a real way to "play outside the sandbox" on both Windows and Android,
structured so that **new capabilities arrive as new function/method
calls added to the script bridge, with little to no impact on existing
code** — explicitly compared to COM add-ins (install a new version,
new functions are just there, nothing about the existing script API or
already-written scripts has to change).

Concretely, as sketched in conversation (not committed): the existing
`FieldFormatHandler`-style extension points and `ScriptApiRuntime
._installBridge`'s existing model (one `install('__bridge_x', ...)` call
plus a JS-side wrapper function, per capability) already have roughly
this shape for what's inside the sandbox today — `deviceId()`/
`localTime()` were added this same session without touching `record`/
`table()`/`notify()`/`navigate` at all. The open question is whether
that same additive, low-blast-radius pattern can be extended to
capabilities that need to leave the sandbox entirely (real network
calls, possibly future capabilities like reading a local file, calling
into another installed app, etc.) without turning script execution into
a genuine security/stability risk — an arbitrary script running with
real network access is a materially bigger trust boundary than one that
can only touch this app's own database.

## What would need real design work before building anything

None of this is decided — flagging the shape of the actual questions,
not answering them:

- **Trust model.** Every script currently runs with the same
  capabilities as every other script (this app has one user). A
  network-capable bridge function raises the same question any
  future multi-user version of this app would eventually have to answer:
  does *every* script get access, or does a capability need to be
  explicitly granted per script/per table, the way Android permissions
  work?
- **Configuration, not hardcoding.** Mike's own bar: a "fetch a URL"
  capability should be a generic `fetch(url)`-style bridge function
  (or similar), with the actual endpoint/API key/etc. living in the
  script or in ordinary app data (a settings table, a field on the
  calling record), never wired into the app's Dart source for one
  specific use case.
- **Failure/timeout semantics.** The existing 5-second script timeout
  and isolate-abandonment safety net (`ScriptApiRuntime`'s own doc
  comment on why a hung script can't be forcibly killed mid-native-call)
  were designed around fast, local SQLite operations. A real network
  call is slower and can hang in ways a local DB call can't — worth
  its own look before assuming the existing timeout model still fits.
- **Platform parity.** Whatever shape this takes needs to work
  identically on Windows and Android, including from a background/
  scheduled context (Android's exact-alarm chain, Windows's Scheduled
  Task poll) where there's no user present to intervene if something
  goes wrong.
- **"Install a new version and go"** is the part most worth testing
  directly against this project's own existing architecture before
  assuming it holds: does adding a new bridge function actually require
  zero changes to already-existing scripts/tables, the way Mike's COM
  add-in comparison implies? Early evidence (this session's `deviceId()`/
  `localTime()` addition) suggests yes for *sandboxed* capabilities;
  unconfirmed for anything that needs new permission/configuration
  plumbing (e.g. a per-script network-access grant) rather than just a
  new bridge function.

## Not scoped, not next

No build order, no chosen approach, no commitment to build this at all.
Revisit if/when Mike wants to turn this into a real design doc — same
process every other phase in this project went through (a dedicated
`claude/essentials-v2-<name>-design.md` pass before any code changes).
