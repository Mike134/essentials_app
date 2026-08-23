> **Synced copy.** This file mirrors the claude.ai Project doc of the same name (Project: "Essentials"). The claude.ai Project is where I keep it updated across chat sessions; this repo copy is what Claude Code and any local tooling should read and trust for execution. Keep both in sync going forward: when either copy changes, update the other in the same session.

---

# Essentials v2 — Phase 2 Handoff (start Phase 3, or real usage, from here)

**Written:** 2026-08-23, at the end of the chat session that designed Phase 2, immediately after Claude Code's build-and-real-device-verify session confirmed it complete. Purpose: let a brand-new session pick up from here without re-reading this session's full transcript — everything durable is here or in the docs this points to.

---

## Status: Phase 2 is done and real-device verified. Nothing is blocking Phase 3.

Phase 2 (rich field types — `currency`/`percentage`/`real.decimals`/`rating`/`url`/`link_file`/`barcode`/`formula`, plus inline-mode `select`) shipped in one continuous Claude Code session on 2026-08-23. It was:

1. Designed against a real read of the live v2 codebase (`claude/essentials-v2-phase2-design.md`), correcting two things the architecture doc had gotten ahead of the code on (`lookup`/`rollup` actually belong in Phase 4, not Phase 2; the render layer needed a `FieldFormatHandler`/`FieldFormatRegistry` prerequisite before adding nine more formats the old way).
2. Scoped down from the architecture doc's full vision on two formats, both confirmed with Mike before implementation started: `formula` ships as a small arithmetic expression subset (not full JS — `flutter_js` stays reserved for Phase 5), and `attachment` was **dropped from Phase 2 entirely**, not shipped local-only as this doc originally proposed.
3. Implemented by Claude Code across all seven build-order steps, model-tier-split exactly as confirmed beforehand: Sonnet for six steps, Opus for the `formula` evaluator alone.
4. Build-verified at every step (`flutter analyze` clean, `flutter build windows`/`apk --debug` clean, real unit/widget tests — 128 total, up from Phase 1's count) — then **real-device verified** by Mike on both MIKE-CU and MIKE-12R through an actual "All Types" table (one field per format), cross-synced live.

**Two real findings came out of the real-device pass, both fixed same session, neither a design defect:**

- MIKE-12R was running a stale, pre-Phase-2 build the first time it was checked — an install gap (Claude Code doesn't push installs to a device mid-session on its own; that's normally Mike's own `adb install`/F5), not a code bug. Fixed by installing the session's current debug APK.
- `GenericFormScreen`'s Save button sat under MIKE-12R's system nav bar — a real bug, the same overlap class five other schema-engine screens already had fixed in Phase 1's real-device pass. This screen just predates that fix and hadn't been touched since. Fixed with the same `EdgeInsets.fromLTRB(..., 16 + MediaQuery.paddingOf(context).bottom)` pattern already used elsewhere.

One deliberate scope call surfaced and confirmed during verification, not a gap: `barcode`'s scan affordance is form-only — no scan icon in the grid cell, unlike `link_file`'s "open" icon or `rating`'s tappable stars, which both do appear in the grid. Mike confirmed this is the right call.

There is no open question, no half-finished step, no known bug blocking further work.

---

## What to read, and in what order, to get real context

1. `claude/essentials-v2-phase2-design.md` — the actual design: the `FieldFormatHandler`/`FieldFormatRegistry` prerequisite, the full format catalog and `options` JSON shapes, the confirmed scope decisions (formula subset, attachment dropped, lookup/rollup deferred to Phase 4), and the seven-step build order.
2. `claude/essentials-v2-architecture.md` — updated 2026-08-23: the Phase 2 roadmap bullet now says DONE, the format specification table reflects what actually shipped (not the original aspirational table), and the "File / Attachment Sync" section is flagged as still unbuilt with no phase number assigned yet.
3. `CLAUDE.md` (in the repo) — the authoritative full history. Its "Essentials v2 Phase 2" sections (search for that heading) document the build-order implementation session and the separate real-device verification session, including the `mobile_scanner`/Kotlin-Gradle-Plugin build-warning risk that was accepted and tracked rather than blocking.

---

## Key facts a fresh session needs, that aren't obvious from a first read

- **Every Phase 2 format is still physically TEXT.** No exception was needed, including `formula` (computed at read time, nothing stored) and `barcode` (identical storage/parsing to a plain text field — the format only changes the input method). The "Excel model" held all the way through Phase 2 without a single carve-out.
- **`FieldFormatHandler` only covers the new formats.** Phase 1's original six formats (`text`, `integer`, `real`, `boolean`, `date`, `dateTime`) plus `select` still run through the original `FieldType`-enum branches in `GenericListScreen`/`GenericFormScreen`, untouched. `url` and `formula` also don't have handlers — `url` reuses `FieldConfig.isLink`, `formula` reuses `FieldConfig.readOnly`/`computePreview`, both pre-existing mechanisms. Only `link_file`, `currency`, `percentage`, `rating`, and `barcode` are actual `FieldFormatHandler` implementations. See the design doc's own table mapping each build-order step to its mechanism.
- **`attachment` genuinely does not exist anywhere in the codebase** — not a stub, not a disabled menu entry. If a future session wants it, it starts from the architecture doc's "File / Attachment Sync" section and the design doc's now-reference-only `attachment` write-up, as a new design pass, not a resume of anything.
- **`barcode` pulled in a new dependency, `mobile_scanner`**, with one accepted, tracked risk: `flutter build apk` prints a non-fatal warning that a future Flutter release may turn into a hard failure (Kotlin Gradle Plugin application path). Documented in both `pubspec.yaml`'s comment and `BarcodeFormatHandler`'s doc comment. Not urgent, but a future `flutter upgrade` that starts failing the Android build should check this first before assuming it's something new.
- **The "Code builds and verifies; Mike tests" working agreement held throughout**, including the finding that surfaced it explicitly this time: Claude Code cannot and does not install builds onto MIKE-12R mid-session on its own — that step is always Mike's, and the stale-APK finding above is what that looks like when it's skipped even briefly.
- **Two Claude sessions still do the work here, same hard boundary as Phase 1.** This cloud session (claude.ai) designs, reviews, and hands off precise written instructions. Claude Code, running locally against `C:\Flutter\essentials_app`, implements and build-verifies. Mike does the real-device interactive pass. All three roles showed up for real in this phase — the design session caught the lookup/rollup and render-layer issues before code was written, Claude Code caught the stale test-rot on the string `'barcode'` becoming a real format, and Mike's own pass caught both real-device findings above that neither prior stage could have caught.

---

## Practical notes for the next session

- Model tier: Phase 2 confirmed Opus for the formula evaluator specifically, Sonnet for everything else — that data point (formula/expression work benefits from the stronger model, routine UI/handler work doesn't) is now confirmed twice (flagged as plausible after Phase 1, borne out in Phase 2). Worth defaulting to the same split for any future expression/evaluation-shaped work, and asking again for anything that doesn't obviously fit either bucket.
- Phase 3 (View Types — List, Card, Calendar, Kanban) is the natural next phase per the roadmap, but nothing requires starting there immediately. Real usage of the finished Phase 1+2 catalog (recreating `subscription` as a `formula`-backed table, building out real tables with the new formats) is equally reasonable next work, and was explicitly named as a valid alternative in this session's own `CLAUDE.md` write-up.

---

## Not yet done, not blocking, worth doing soon

- `claude/project-overview.md`'s "Current Status" section still describes the pre-Phase-1-rebuild state (flagged as a gap in the Phase 1 handoff too, still not rewritten). Worth a rewrite whenever it's next touched — not urgent enough to block anything.
- **Attachment fields have no assigned phase number.** Dropped from Phase 2 entirely rather than shipped half-built; needs its own design pass (local storage + hub file-transfer sync together) whenever Mike wants to prioritize it. Not scheduled.
