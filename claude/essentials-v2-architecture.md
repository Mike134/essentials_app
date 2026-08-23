> **Synced copy.** This file mirrors the claude.ai Project doc of the same name (Project: "Essentials"). The claude.ai Project is where I keep it updated across chat sessions; this repo copy is what Claude Code and any local tooling should read and trust for execution. Written to the repo 2026-08-22 after this exact gap caused Claude Code to correctly refuse to proceed on a destructive step — the doc was cited in code comments but never actually committed here. Keep both in sync going forward: when either copy changes, update the other in the same session.

---

# Essentials v2 — Architecture & Design Decisions

**Session date:** 2026-08-22  
**Goal:** Full Memento Database replacement — target everything, consciously defer what isn't worth the effort.

---

## Vision

A personal, local-first data management platform for Windows and Android. Users define their own tables, fields, views, and automation scripts — no coding required. No cloud dependency, no subscription, no account. Data stays on your devices and syncs only between them.

**Design north star:** If you know how to use a spreadsheet, you already know most of this. Every UI and data model decision should feel familiar to users of Excel, Google Sheets, or web database tools like AppSheet. This is a deliberate competitive advantage over Memento Database, which forces users to think in rigid field types. Essentials thinks in formats — put data in, format it how you want, change your mind later with no consequences.

Comparable products: **Enpass** (privacy/personal architecture model), **Memento Database** (feature completeness target), **Excel / Google Sheets** (UX familiarity target).

---

## Nomenclature

Traditional database terminology throughout. No invented product-specific terms.

| Concept | Term | Rejected |
|---|---|---|
| Named dataset with columns and rows | **Table** | Library (Memento) |
| A row of data | **Record** | Entry (Memento) |
| A column definition | **Field** | — |
| A named saved display configuration | **View** | — |
| The app's full collection of tables | **Database** | — |
| A single column condition | **Filter** | — |
| Filters + sort saved with a view | **View Filter** | — |
| User-written automation logic | **Script** | Macro, Action |
| What causes a script to run | **Event** | Trigger (reserved for SQL) |
| Field pointing to another table's record | **Link field** | — |
| File copied into app data folder | **Attachment field** | — |
| Stored path or URL to external file | **Link field** (file variant) | — |

### View Types

Grid · List · Card · Form · Calendar · Kanban

### Event Categories (for Scripts)

- **UI events** — button clicked, form opened, form closed
- **Data events** — record created, record saved, record deleted, field changed
- **Scheduled events** — daily at 8am, every hour, etc.

**Rationale for "Event" over "Trigger":** "Trigger" has a precise meaning in SQL (database-engine-level construct on INSERT/UPDATE/DELETE). Using it for user-facing automation creates confusion for anyone with SQL background. "Event" is the term used by MS Access and Google Apps Script — the two most familiar reference points for the target user base.

---

## Platform Targets

**Windows desktop + Android only.**

- iOS is not a target. Closed architecture, App Store friction, Apple Developer account requirement, stagnating platform trajectory, and over-complication of the build pipeline are all disqualifying.
- Mac is implicitly excluded (comes paired with iOS in Flutter).
- No web app target.

---

## Tech Stack

### Keep from Essentials v1

| Component | Technology | Notes |
|---|---|---|
| UI framework | Flutter / Dart | Single codebase → Windows + Android |
| Database | SQLite | Via `sqflite` (Android) + `sqflite_common_ffi` (Windows) |
| Grid/list view | TrinaGrid (`trina_grid`) | Maintained PlutoGrid fork; already integrated |
| CRDT sync | `sqlite_crdt` + custom `crdt_sync` | Proven, bidirectional, device-level |
| Sync hub server | `server.dart` (Dart) | System-tray hosted on MIKE-CU |
| UI component layer | `shadcn_ui` | Required as direct dep for TrinaGrid popups |

### New additions for v2

| Component | Technology | Purpose |
|---|---|---|
| Scripting engine | `flutter_js` (QuickJS) | JavaScript execution, sandboxed, cross-platform |
| Barcode scanning | `mobile_scanner` | Camera-based barcode/QR scan on Android; degrades to a plain text field on Windows. Added in Phase 2 — see that section's own note on the one accepted, tracked build-warning risk (Kotlin Gradle Plugin application). |

### Scripting Language: JavaScript

JavaScript via `flutter_js` (QuickJS engine). Reasons:
- Only viable cross-platform embedded scripting option for Flutter (Windows + Android)
- Memento Database uses JavaScript — direct migration familiarity
- Google Apps Script uses JavaScript — the named familiarity benchmark
- JSON/object model maps naturally to record data
- Most broadly used language globally (Stack Overflow #1 for 10+ consecutive years)
- Python embedding in Flutter has no production-ready cross-platform solution

---

## Core Architecture Change: Dynamic Schema

### v1 (current)
Schema is code. Tables are designed by developer, defined in `schema.sql`, reflected in `TableConfig` objects. Adding a new entity type requires a code change.

### v2 (target)
Schema is data. Users create tables through the UI. The app executes DDL (`CREATE TABLE`, `ALTER TABLE`) at runtime. Schema definition lives in metadata tables.

### Approach: Real Dynamic DDL

When a user creates a table, the app runs `CREATE TABLE`. When a user adds a field, the app runs `ALTER TABLE ADD COLUMN`. This gives:
- Full SQLite query performance on all fields
- Existing SQLite tooling (Letos, DBeaver) works normally
- CRDT sync carries forward unchanged — it works at the table level regardless of schema

Rejected alternatives:
- **JSON column per row** — slow filtering/sorting, complex TrinaGrid integration
- **EAV (Entity-Attribute-Value)** — worst query performance, most complex joins, avoid

### Metadata Schema (new tables)

```
table_definitions     — user-created tables (name, display_name, created_at, icon, etc.)
field_definitions     — fields per table (table_id, name, display_name, format, options JSON, sort_order, etc.)
view_definitions      — saved views per table (table_id, name, view_type, config JSON)
script_definitions    — user scripts
event_definitions     — script → event bindings
template_definitions  — built-in and user-saved templates
```

Note: `format` replaces `field_type`. It is a presentation and input hint, not a storage constraint. Physical column type in SQLite is always TEXT for all user-defined fields. `link_definitions` is removed as a separate table — cross-table relationships are expressed via `format: 'link_record'` options in `field_definitions`.

**Superseded 2026-08-22 by the clean-slate decision** (see `claude/essentials-v2-phase1-design.md`, "Clean-slate directive"): the 19 tables are NOT ported or auto-registered. The rebuilt database starts with zero business tables; any of the original 19 comes back only if/when recreated by hand through the New Table UI, with no special status. This line originally said the opposite ("ported as built-in tables") — left visible via git history rather than silently rewritten, since the phase1 doc is the one to trust on this point.

`table_definitions` and `field_definitions` shipped in Phase 1. `view_definitions`, `script_definitions`, `event_definitions`, `template_definitions` are still just this list of names — no schema, no code — reserved for later phases below, not yet designed in detail.

---

## Field Model

### Core principle: TEXT storage + format specification

**All user-defined field values are stored as TEXT in SQLite.** Always. The `format` in `field_definitions` is a presentation and input hint — it is not a storage constraint.

This mirrors Excel's behavior: a cell holds a value, and a format specification controls how it is displayed and what input widget is offered. If the value matches the format it is rendered accordingly; if it doesn't match it is displayed as-is. No errors, no data loss, no blowup.

- **Changing a field's format** is a metadata-only operation — one UPDATE to `field_definitions`. Zero DDL. Instant CRDT sync. Existing data is untouched.
- **Non-conforming values** display as raw text. A number format applied to "dog" shows "dog". Graceful, not broken.
- **Input widgets** are driven by format, not storage type. A date format shows a calendar picker. A select format shows a dropdown. A boolean format shows a checkbox or toggle — the user chooses the UI representation. Storage is always TEXT (0/1, true/false, or the display value for booleans depending on format options).

### Format specifications

| Format | Input widget | Display | Options (stored as JSON in field_definitions) |
|---|---|---|---|
| `text` | Single-line text box | As-is | `{ multiline: false }` |
| `text_multiline` | Multi-line textarea | As-is | `{ multiline: true }` |
| `integer` / `real` | Numeric keyboard | Format mask | `{ decimals: int }` (real only) |
| `currency` | Numeric keyboard | Currency mask | `{ symbol: '$', decimals: 2 }` |
| `percentage` | Numeric keyboard | % mask | `{ decimals: 0 }` |
| `date` | Calendar picker | Date mask | — |
| `dateTime` | Date+time picker | DateTime mask | — |
| `boolean` | Toggle or checkbox | Configurable labels | — |
| `select` | Dropdown / picker | Display value | See **Select fields** below |
| `rating` | Star widget | Stars | `{ max: 5 }` |
| `url` (styled `text`) | Text box | Tappable link | `{ isLink: true }` |
| `color` (styled `text`) | Swatch + color-picker popup | Swatch | `{ isColor: true }` — **rendering already works (carried from v1), but not yet pickable in `AddFieldScreen` — queued small fix, see below** |
| `barcode` | Camera scan (Android) / text (Windows) | As-is | — |
| `formula` | Read-only (computed) | Result of expression | `{ expression: '...', engine: 'simple' }` |
| `link_file` | File picker / URL input | Path or URL | — |
| `link_record` | Record picker | Configured display field | `{ table: 'table_name', display_field: 'field_name' }` — **Phase 4** |
| `lookup` | Read-only (resolved) | Value from linked record | `{ link_field: 'field_name', source_field: 'field_name' }` — **Phase 4** |
| `rollup` | Read-only (computed) | Aggregate value | `{ link_field: 'field_name', source_field: 'field_name', aggregate: 'sum' }` — **Phase 4** |
| `attachment` | File picker (embed) | Thumbnail + filename | — **dropped from Phase 2, not yet scheduled — see below** |

**Phase 1 shipped:** `text, integer, real, boolean, date, dateTime, select` (linked-table sub-mode only).

**Phase 2 shipped, 2026-08-23 — real-device verified on MIKE-CU and MIKE-12R:** `currency`, `percentage`, `real`'s `decimals` option, `rating`, `url` (as a `text`+`isLink` convenience, no new stored format), inline-mode `select`, `formula` (small expression subset, not full JS), and `barcode` (`mobile_scanner` on Android, plain text field on Windows — confirmed degrading cleanly, not just assumed). Full design, the `options` JSON reference, and the build order live in `claude/essentials-v2-phase2-design.md`; the real-device verification write-up (including the two real findings — a stale APK on MIKE-12R, and a `GenericFormScreen` Save-button/nav-bar overlap, both fixed) is in `CLAUDE.md`'s "Essentials v2 Phase 2" sections.

**Still not built:** `lookup`/`rollup` (need `link_record`, Phase 4's job) and `attachment` (dropped from Phase 2 entirely — a field that doesn't sync between devices was judged not worth shipping half-built; local storage and hub file-transfer sync will be designed and built together as their own future phase, not yet scheduled to a specific phase number).

**`color` — found 2026-08-23, queued as a small fix (not a phase, no design doc):** `FieldConfig.isColor` rendering already works everywhere (carried forward from v1's `domain.color`/`class.color` — grid swatch + tap-to-pick cell, form's palette-icon button, row-coloring's `colorableColumns`), but `FieldFormatChoice` has no `color` entry, so `AddFieldScreen` can't actually create one on a new v2 field — same shape gap `url` had before Phase 2. Fix, confirmed with Mike: add a `color` entry sharing `text`'s value exactly like `url` does (`options: {isColor: true}`), **and** give `AddFieldScreen`'s default-value entry the same `pickColor()` popup the grid/form already use instead of a bare hex-typing box — Mike flagged the picker specifically as important, not a nice-to-have. See `CLAUDE.md`'s "expose `color` as a pickable field format" note for the full two-part fix.

### Select fields

A `select` format has two sub-modes, configured in options:

- **Inline list** — options defined directly on the field, stored as JSON in `field_definitions.options`. Suitable for small, stable lists (e.g. Low/Medium/High). Stored value is the option key. **Shipped in Phase 2.**
- **Linked table** — points to another table. Stored value is the linked record's `id` (integer FK). Display value is resolved at render time from the configured display field. If the display value changes on the source record, the stored ID still resolves correctly. This is the default for anything relational. **Shipped in Phase 1.**

```json
// Inline select
{ "mode": "inline", "options": [{"key": "low", "label": "Low"}, {"key": "med", "label": "Medium"}, {"key": "high", "label": "High"}] }

// Linked table select
{ "mode": "linked", "table": "priority", "displayField": "name", "valueField": "id", "on_delete": "restrict" }
```

### Attachment vs. Link (file) — separate formats, separate storage mechanisms

- **`attachment`** — file is copied into `C:\Databases\essentials_app\files\{table}\{record_id}\`. App owns it. Synced via file transfer endpoint on hub server. Android equivalent: app data directory. **Dropped from Phase 2 entirely (confirmed 2026-08-23) — local storage and sync will be designed and built together in a future phase, see `claude/essentials-v2-phase2-design.md`.**
- **`link_file`** — stores a path string or URL. Points to a file the app does not own or manage. Not synced. Displays content if accessible, handles gracefully if not. **Shipped in Phase 2.**

A record can have both formats on different fields simultaneously, once `attachment` exists.

---

## View Types (detail)

| View | Description | Key fields required |
|---|---|---|
| **Grid** | TrinaGrid spreadsheet layout (existing) | Any |
| **List** | Compact rows — title + subtitle | One designated title field |
| **Card** | Gallery/tile layout, image-prominent | Optional image field |
| **Form** | Single record, full field editing | Any |
| **Calendar** | Date-field driven layout | One date/datetime field |
| **Kanban** | Status-field driven columns | One single-select field |

Each view is a saved configuration: display mode + view filters + sort + visible fields + column widths (grid). Multiple views per table. Per-device column widths; shared filter/sort.

---

## Scripts & Events

### Scripts
- Written in JavaScript (QuickJS via `flutter_js`)
- Sandboxed — access only to a defined API surface (record data, table queries, notifications, navigation)
- Stored in `script_definitions`, synced across devices

### Events
Stored in `event_definitions`, each binding one script to one event.

**UI Events**
- Button clicked (user places a button field or toolbar button)
- Form opened
- Form closed

**Data Events**
- Record created
- Record saved (create or update)
- Record updated
- Record deleted
- Field value changed (specific field)

**Scheduled Events**
- Daily at [time]
- Weekly on [day] at [time]
- Hourly
- App launch

### Script API (design target)

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

---

## File / Attachment Sync

Attachment files live alongside the database:
- Windows: `C:\Databases\essentials_app\files\`
- Android: app data directory equivalent

Sync mechanism: hub server (`server.dart`) gets a file transfer endpoint alongside the existing CRDT WebSocket. When CRDT sync detects a new attachment record on a device, the file is pulled from whichever device owns it via the hub. File identity keyed by `{table}/{record_id}/{field_name}/{filename}` to avoid collisions.

**Not built yet as of 2026-08-23** (confirmed by reading `server/bin/server.dart` — no file/upload endpoint exists). `attachment` was dropped from Phase 2 entirely (confirmed 2026-08-23) rather than shipped local-only as originally proposed — this section's implementation, local storage and sync together, is deferred to its own future phase, not yet scheduled to a specific phase number.

---

## Features Roadmap

**Execution order is not phase-number order — see "Roadmap sequencing" immediately below before assuming Phase 3 comes after Phase 2.** The phase numbers below are stable labels for what each chunk of work contains, same as they've always been; they are not a promise about what gets built next.

### Roadmap sequencing (confirmed 2026-08-23, after Phase 2)

With Phase 1 and Phase 2 done, the actual build order for what comes next was deliberately reordered away from strict phase-number order, for reasons worth keeping on record rather than re-litigating later:

1. **Limited CSV import** (side task, not a phase) — import into an *existing* table's plain fields only. No auto-creating a new table from CSV headers (real format-detection work, not worth doing yet), no importing into a linked/child-table field (needs Phase 4's link-column mechanics understood first — doing it before Phase 4 would mean building it blind). CSV *export* already exists and needs no work — confirmed by reading `GenericListScreen._exportCsv`, which is already format-aware (reads through the grid's own `formattedValueForDisplay`, so it already picks up every Phase 2 format correctly). The Phase 7 bullet below claiming CSV import "already partially exists" is stale — that referred to the old v1 practice of importing externally via Letos, not an in-app feature; grepping `lib/` for CSV/import code as of 2026-08-23 found no in-app import path at all. **Designed 2026-08-23** — full field-mapping/coercion rules, malformed-value handling, and UI flow in `claude/essentials-v2-csv-import-design.md`. **In progress as of 2026-08-23** — Claude Code started this session.
1a. **`color` field format** (small fix, queued right after CSV import, not its own phase) — see the Field Model section above and `CLAUDE.md`'s note for the two-part fix (picker entry + default-value color picker in `AddFieldScreen`).
2. **Phase 4 — Cross-Table Linking**
3. **Phase 6 — Global Search**
4. **Phase 5 — Scripts & Events**
5. **Phase 3 — View Types**
6. **Phase 7 — Import / Export / Templates** (the rest of it: Memento backup import, starter template library, full DB export/backup)

**Why Phase 4 before Phase 6/5/3:** core relational plumbing (`link_record`/`lookup`/`rollup`) that most of the rest of the app benefits from having, and it's what CSV import's "into a linked table" case is blocked on (see above) — building it early also means any later child-table import work is informed by real link-column UI/schema mechanics instead of guessed at.

**Why Phase 6 (Search) before Phase 5 (Scripts):** Scripts & Events is the single riskiest phase left on the roadmap — a new embedded JS runtime (`flutter_js`/QuickJS) with real sandboxing and cross-platform (Windows + Android) packaging risk, the same class of scope Phase 2's design doc explicitly flagged as too much surface area to pull in early for just one field format. That risk hasn't gone away by being later in the list. Search, by contrast, is SQLite FTS5 — same stack already in use, no new native dependency — and becomes more valuable the moment CSV import and Phase 4 start putting real data volume into the database. For a personal database, findability was judged more valuable sooner than automation.

**Why Phase 3 (Views) stays near the end:** view types are worth more once there's real data and real relational structure to look at. Building List/Card/Calendar/Kanban views for tables that are still mostly empty (the state most tables are in today, pre-CSV-import) has low marginal value; CSV import, Phase 4, and Phase 6 all land real, browsable data first.

**Process note, not a change:** each item above still gets its own short design pass before Code implements it, the same discipline Phase 1 and Phase 2 both used — "next in line" doesn't mean "skip straight to implementation." (The `color` fix is small enough it skipped a formal design doc — see the Field Model section — but the confirmation-before-implementation discipline still applied.)

### Phase 1 — Dynamic Schema Engine — **DONE, 2026-08-22**
- `table_definitions` + `field_definitions` metadata schema
- Dynamic DDL execution (CREATE TABLE, ALTER TABLE)
- Table creation / field management UI
- ~~Port 19 current tables as built-in registered tables (data preserved)~~ — **did not happen, correctly.** Superseded by the clean-slate decision recorded above and in `claude/essentials-v2-phase1-design.md`: the database starts genuinely empty, no business tables auto-recreated, no `is_builtin` concept.
- `TableDiscoveryService` replaced by `SchemaRegistry`, reading from metadata (not `sqlite_master` heuristics)

Implementation detail, verification results, and the full build order live in `claude/essentials-v2-phase1-design.md`. Code-reviewed complete 2026-08-23 — every design rule verified actually implemented, not just designed.

### Phase 2 — Rich Field Types — **DONE, 2026-08-23, real-device verified**
- `currency` / `percentage` / `real`'s `decimals` option / `rating` / `url` / `link_file` / `barcode` / `formula`, plus inline-mode `select`
- `formula` shipped as a small spreadsheet-style expression subset, not full JS (`flutter_js` stays reserved for Phase 5) — built on Opus per the confirmed model-tier split, rest of Phase 2 on Sonnet
- `barcode` shipped via `mobile_scanner` — camera scan on Android, plain text field (no icon at all, not a greyed-out one) on Windows, confirmed degrading cleanly on real hardware
- **`lookup`/`rollup` moved out of Phase 2 to Phase 4**, where they correctly belong (both need `link_record`, which Phase 4 builds)
- **`attachment` dropped from Phase 2 entirely, confirmed 2026-08-23** — not even local-only. Local storage and hub file-transfer sync (see "File / Attachment Sync" above, still unbuilt) will be designed and built together as their own future phase.

All seven build-order steps confirmed working on **both** MIKE-CU and MIKE-12R through a real "All Types" table, cross-synced live — not just build-verified. Two real findings surfaced and were fixed during that pass: MIKE-12R was running a stale pre-Phase-2 build the first time it was checked (an install gap, not a code bug — fixed via `adb install`), and `GenericFormScreen`'s Save button sat under MIKE-12R's system nav bar (a real bug, the same overlap class five other screens already had fixed — this screen just hadn't been touched yet). Full design, the format catalog, `options` JSON reference, and the `FieldFormatHandler`/`FieldFormatRegistry` render-layer change live in `claude/essentials-v2-phase2-design.md`; the real-device verification write-up is in `CLAUDE.md`'s "Essentials v2 Phase 2" sections.

### Limited CSV import — **in progress, designed 2026-08-23, see "Roadmap sequencing" above**
Not a phase — a side task, scoped to importing into an existing table's plain (non-linked) fields only. Full design (field-mapping, per-format coercion rules, malformed-value handling, UI flow, build order) in `claude/essentials-v2-csv-import-design.md`. Claude Code started implementation 2026-08-23.

### `color` field format — **queued next, small fix, no design doc**
`FieldConfig.isColor` rendering already works everywhere; `AddFieldChoice` just has no entry for it yet, and the default-value box needs the same picker the grid/form already use. See the Field Model section above and `CLAUDE.md`'s note for the full two-part fix.

### Phase 4 — Cross-Table Linking — **up next after CSV import and the color fix**
- Link to record field type
- Lookup and Rollup field types
- Link Definitions metadata
- UI for selecting linked table and display field

### Phase 6 — Global Search — **sequenced before Phase 5, see "Roadmap sequencing" above**
- Full-text search across all tables
- SQLite FTS5 virtual tables per user table (or a unified search index)
- Search UI — results grouped by table, click-through to record

### Phase 5 — Scripts & Events — **sequenced after Phase 6, see "Roadmap sequencing" above**
- `flutter_js` integration
- Script editor UI (in-app, with syntax highlighting)
- Event binding UI
- Script API implementation
- Scheduled event runner

### Phase 3 — View Types — **sequenced near the end, see "Roadmap sequencing" above**
- List view
- Card/gallery view
- Calendar view
- Kanban view
- View management UI (create, rename, delete views per table)

### Phase 7 — Import / Export / Templates — **the rest of it, last; CSV import itself was pulled out and moved up, see above**
- ~~CSV import per table (already partially exists)~~ — pulled out as its own side task before Phase 4, see "Roadmap sequencing" above; the "already partially exists" claim was stale (no in-app CSV import code existed as of 2026-08-23 — confirmed by reading `lib/`, not assumed) and is corrected here rather than silently rewritten.
- Memento backup file import (CSV-based)
- Starter template library (Contacts, Books, Movies, Passwords, Expenses, etc.)
- Full database export/backup — note CSV export of a single table already works today (`GenericListScreen._exportCsv`); this bullet is about a full-database backup/export, a different and larger scope.

### Deferred (explicitly, not forgotten)
- Reporting / printing — significant effort, moderate value
- iOS / Mac — not a target
- Attachment fields (local storage + hub file-transfer sync, designed and built together) — dropped from Phase 2, not yet assigned a phase number

---

## Carry-Forward from v1

These do not change:

- CRDT sync architecture (`sqlite_crdt` + `crdt_sync`)
- Migration system (`schema_admin` + `migration_log` + `migration_status`)
- Per-device vs. shared state governance model
- Sync hub server (system-tray hosted on MIKE-CU)
- Periodic reconnect (5-minute forced reconnect in `SyncService`)
- `safeChangesetBuilder` watermark-drop fix
- `device_id` via hostname (Windows) / `Settings.Global.DEVICE_NAME` (Android)
- Grid features: column persistence, row coloring, grouping, aggregates, CSV export, filter by value
- TrinaGrid upsert rule: never DELETE + INSERT; always `INSERT OR REPLACE`

---

## Open Decisions (to resolve before relevant phase begins)

- **Home screen / dashboard** — configurable home with pinned tables and recent records, or simple table list?
- **App name** — "Essentials" is a working title; needs a real name before UI embeds it everywhere
- **Global search strategy** — FTS5 per-table virtual tables vs. unified search index
- **Starter template set** — which 5–10 templates ship built-in?
- **Record history UI** — CRDT timestamps give implicit history; surface it to users?
- **Attachment phase number** — where local storage + sync (dropped from Phase 2) lands in the roadmap; not yet decided.
- ~~**CSV import design**~~ — done, 2026-08-23, see `claude/essentials-v2-csv-import-design.md`.
- ~~**`color` field format**~~ — confirmed 2026-08-23, queued small fix, see `CLAUDE.md`'s note; no separate design doc needed.
