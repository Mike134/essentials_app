> **Source of truth: this repo file.** As of 2026-08-24, this project stopped mirroring design docs into a claude.ai Project doc -- Mike is always on the desktop app, so a claude.ai/Cowork session can read this file directly (via the device bridge) whenever it needs it, and Claude Code always reads it locally. Maintaining two full copies was pure duplicated effort with no real benefit. The claude.ai Project now keeps a single short pointer doc (`claude/project-overview.md`, the Project's own trimmed copy) instead of a full mirror of every doc -- see that doc's note for the one edge case (a browser/mobile session, no desktop app connected) this doesn't cover.

---

# Essentials v2 — Phase 1 Handoff (start Phase 2 from here)

**Written:** 2026-08-23, at the end of the chat session that designed Phase 1, and the following session that code-reviewed it. Purpose: let a brand-new chat session pick up Phase 2 without re-reading this session's full transcript — everything durable is here or in the docs this points to.

---

## Status: Phase 1 is done and verified. Nothing is blocking Phase 2.

Phase 1 (the dynamic schema engine — `table_definitions`/`field_definitions`, `createTable`/`addField`/`dropTable`/`dropField`, the New Table / Manage Fields / Add Field / Manage Tables UI, two-stage delete) shipped in commits `da6c39f`, `38ee0b2`, `e7aa892`, `9b7a091` on the repo at `C:\Flutter\essentials_app`. It was:

1. Designed against a real read of the live v1 codebase (`claude/essentials-v2-phase1-design.md`).
2. Verified with a live spike before any implementation code was written (confirmed the `sqlite_crdt`/sqlparser quoting behavior and the CRDT-column-predeclaration failure mode — see that doc's "Critical risks" section).
3. Implemented by Claude Code, then live-verified end to end on real hardware (MIKE-CU + MIKE-12R + the sync server), which surfaced and fixed 6 real bugs beyond the original design scope (documented in `CLAUDE.md`, tail section).
4. Independently code-reviewed by me, file by file, against every design rule — full verdict below.

**One thing worth knowing, not a defect:** table/field name collisions now auto-suffix rather than reject outright (v1 rejected). A deliberate UX difference, not a bug.

There is no open question, no half-finished step, no known bug blocking further work.

---

## What to read, and in what order, to get real context

Don't re-derive any of this — it's all written down:

1. `claude/essentials-v2-architecture.md` — the full vision, nomenclature, tech stack, field model, and the 7-phase roadmap. Phase 1 is now marked **DONE** in its Features Roadmap section (I just corrected a stale bullet there that still said the 19 v1 tables would be "ported as built-in tables" — that's wrong, see the clean-slate decision below).
2. `claude/essentials-v2-phase1-design.md` — Phase 1's actual design: the metadata schema, the immutable-identifier rule, two-stage delete, the migration_log routing decision, the build order (all 10 steps done), and the "Starting genuinely empty" section explaining the clean-slate decision in full.
3. `claude/project-overview.md` — quick-reference orientation (file locations, devices, tools, grid features). Its "Current Status" section describes the pre-rebuild v1 state and is marked superseded; it has not yet been rewritten to describe the current, post-Phase-1 state — see "One real gap" below.
4. `CLAUDE.md` (in the repo, ~6000 lines) — the authoritative full history. Its tail section documents the live-verification session and the 6 bugs found and fixed. Anything you need the exact reasoning or code shape for is there.

All four architecture/design docs carry a "Synced copy" header explaining that the claude.ai Project and the git repo are two separate storage systems that must be kept in sync manually — **this caused a real incident** (Claude Code correctly refused a destructive step because a cited doc existed only in the Project, not the repo). Whenever you write or update one of these docs, write it to both places in the same session.

---

## Key facts a fresh session needs, that aren't obvious from a first read

- **The database is genuinely empty.** After the Phase 1 wipe, `essentials.db` has 10 infra/bookkeeping tables and zero business tables. None of the original 19 v1 tables (domain, priority, person, shipment, subscription, etc.) exist anymore, and nothing recreates them automatically. If Phase 2 work wants to exercise real field types against real data, a table needs to be created by hand first through the New Table screen — there's no seed data to assume.
- **Field types actually shipped in Phase 1 are narrower than the architecture doc's full target list.** `FieldFormatChoice` (`lib/util/field_format_choice.dart`) only has `text, integer, real, boolean, date, dateTime, select`. Everything from `rating` through `rollup` in the architecture doc's format table is still just a design entry — that's Phase 2's actual job.
- **`select` only supports the "linked table" sub-mode**, not "inline list." If Phase 2 wants inline option lists (e.g. a Low/Medium/High dropdown with no backing table), that's new work, not something already there to extend.
- **No table declares real SQL foreign keys, anywhere, ever, in v2.** Referential integrity is 100% driven by `field_definitions` metadata. Any Phase 2 field type work needs to keep following that pattern, not reach for FK constraints as a shortcut.
- **Every field's physical SQLite column is TEXT.** This is permanent, not just a Phase 1 simplification — it's the "Excel model" the whole architecture is built on. Phase 2's richer formats (formula, rollup, currency masks, etc.) are presentation/computation layered on top of TEXT storage, not new physical column types.
- **CRDT bookkeeping columns (`is_deleted`, `hlc`, `node_id`, `modified`) must never be predeclared in generated DDL** — confirmed by live spike to make `CREATE TABLE` throw outright, not silently duplicate. Any new DDL-generating code in Phase 2 (e.g. if a script-authoring feature ever generates SQL) must follow this.
- **Two Claude sessions do the work here, with a hard boundary.** This cloud session (claude.ai) designs, reviews, and hands off precise written instructions. Claude Code, running locally against `C:\Flutter\essentials_app`, is the one that edits files and runs Dart/Flutter/git commands. Neither can do the other's job — this session has no way to run `flutter build` or `flutter analyze` on Mike's machine.

---

## Practical notes for the next session

- Model tier: Phase 1's implementation work ran on Opus for the harder design/spike reasoning and Sonnet for more mechanical follow-through, per guidance given mid-session. Ask again once Phase 2's actual shape is clearer — the right tier depends on what Phase 2's hardest sub-problem turns out to be (formula expression evaluation is a plausible candidate for something that benefits from a stronger model; routine UI screens don't).
- This session hit a context-window compaction once already, from reading many full source files and docs directly. If Phase 2 involves another close code review pass, expect to budget for that the same way — it's a hard technical limit, not something to route around, just plan for it.

---

## Not yet done, not blocking, worth doing soon

- `claude/project-overview.md`'s "Current Status" section still describes the pre-rebuild v1 state. It's correctly marked superseded, but hasn't been rewritten to describe what's actually true now (Phase 1 shipped, database empty, 10 infra tables, New Table UI live). Worth a rewrite early in the Phase 2 session, or whenever it's next touched — not urgent enough to block anything.
