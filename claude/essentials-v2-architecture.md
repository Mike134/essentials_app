> **Source of truth: this repo file.** As of 2026-08-24, this project stopped mirroring design docs into a claude.ai Project doc -- Mike is always on the desktop app, so a claude.ai/Cowork session can read this file directly (via the device bridge) whenever it needs it, and Claude Code always reads it locally. Maintaining two full copies was pure duplicated effort with no real benefit. The claude.ai Project now keeps a single short pointer doc (`claude/project-overview.md`, the Project's own trimmed copy) instead of a full mirror of every doc -- see that doc's note for the one edge case (a browser/mobile session, no desktop app connected) this doesn't cover.

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

**Known bug, found and fixed 2026-08-23 — boolean fields reading back as always-false.** Every v2 `boolean` field's true value round-trips through SQLite's TEXT-affinity storage as the string `"1"`, not a real `int`/`bool`. `GenericFormScreen.initState` and `GenericListScreen._cellValueFor` both only matched a literal `int`/`bool` value when deciding whether a boolean was true, so every genuinely-true boolean field silently read back as false — in both the grid and the form, on every reload, on every v2 table. Found incidentally by Claude Code while building CSV import's end-to-end test (not something either of us had checked for directly). Fixed with a new shared helper, `coerceBoolValue()` in `lib/util/bool_value.dart`, now used at both call sites instead of the old `== 1 || == true` checks. New tests added; Mike verified the fix interactively on both MIKE-CU and MIKE-12R. Worth keeping on record as a real correctness bug, not just a changelog line, since it affected every boolean field in the app until this fix.

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
| `color` (styled `text`) | Swatch + color-picker popup | Swatch | `{ isColor: true }` — **shipped 2026-08-23, real-device verified on MIKE-CU and MIKE-12R — see below** |
| `barcode` | Camera scan (Android) / text (Windows) | As-is | — |
| `formula` | Read-only (computed) | Result of expression | `{ expression: '...', engine: 'simple' }` |
| `link_file` | File picker / URL input | Path or URL | — |
| `link_record` | Record picker (single or multi) | Configured display field | `{ table: 'table_name', displayField: 'field_name', multiple: bool, on_delete: '...' }` — **shipped Phase 4, 2026-08-24** |
| `lookup` | Read-only (resolved) | Value from linked record | `{ link_field: 'field_name', source_field: 'field_name' }` — **shipped Phase 4, 2026-08-24** |
| `rollup` | Read-only (computed) | Aggregate value | `{ link_field: 'field_name', source_field: 'field_name', aggregate: 'sum' }` — **shipped Phase 4, 2026-08-24** |
| `attachment` | File picker (embed) | Thumbnail + filename | — **dropped from Phase 2, not yet scheduled — see below** |

**Phase 1 shipped:** `text, integer, real, boolean, date, dateTime, select` (linked-table sub-mode only).

**Phase 2 shipped, 2026-08-23 — real-device verified on MIKE-CU and MIKE-12R:** `currency`, `percentage`, `real`'s `decimals` option, `rating`, `url` (as a `text`+`isLink` convenience, no new stored format), inline-mode `select`, `formula` (small expression subset, not full JS), and `barcode` (`mobile_scanner` on Android, plain text field on Windows — confirmed degrading cleanly, not just assumed). Full design, the `options` JSON reference, and the build order live in `claude/essentials-v2-phase2-design.md`; the real-device verification write-up (including the two real findings — a stale APK on MIKE-12R, and a `GenericFormScreen` Save-button/nav-bar overlap, both fixed) is in `CLAUDE.md`'s "Essentials v2 Phase 2" sections.

**Still not built:** `lookup`/`rollup` (need `link_record`, Phase 4's job) and `attachment` (dropped from Phase 2 entirely — a field that doesn't sync between devices was judged not worth shipping half-built; local storage and hub file-transfer sync will be designed and built together as their own future phase, not yet scheduled to a specific phase number).

**`color` — DONE, 2026-08-23, real-device verified on MIKE-CU and MIKE-12R.** `FieldConfig.isColor` rendering already worked everywhere (carried forward from v1's `domain.color`/`class.color` — grid swatch + tap-to-pick cell, form's palette-icon button, row-coloring's `colorableColumns`); the gap was that `FieldFormatChoice` had no `color` entry, so it wasn't creatable through `AddFieldScreen`. Fixed by adding `FieldFormatChoice.color` sharing `text`'s value exactly like `url` does (`options: {isColor: true}`), plus a new shared `ColorDefaultValueField` widget (`lib/util/color_default_value_field.dart`) wired into both `AddFieldScreen` and `ManageFieldsScreen`'s field editor, giving the default-value entry the same `pickColor()` popup the grid/form already use — Mike had flagged the value-entry picker specifically as important, and it landed on both screens, not just one. 4 new tests added.

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
| **Card** | Gallery/tile layout, image-prominent | Optional image field — **cut from Phase 3, 2026-08-24, demoted to "maybe someday," see "Deferred" below** |
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

1. **Limited CSV import** (side task, not a phase) — **DONE, 2026-08-23, real-device verified on MIKE-CU and MIKE-12R.** Import into an *existing* table's plain fields only. No auto-creating a new table from CSV headers, no importing into a linked/child-table field (needs Phase 4 first). CSV *export* already existed and needed no work — `GenericListScreen._exportCsv` is already format-aware. Built with the `csv: ^8.0.0` pub package, coercion logic in `lib/util/csv_import/csv_import_coercion.dart`, new `CsvImportScreen` (flat ListView reached via an "Import from CSV" toolbar icon), per-row commits via `GenericDao.insert`. 44 unit tests + 5 end-to-end tests. Full design in `claude/essentials-v2-csv-import-design.md`.
1a. **`color` field format** (small fix, not its own phase) — **DONE, 2026-08-23, real-device verified on MIKE-CU and MIKE-12R.** See the Field Model section above.
1b. **Boolean read-back bug fix** (found incidentally during CSV import work, not planned) — **DONE, 2026-08-23, real-device verified on MIKE-CU and MIKE-12R.** See the Field Model section above.
1c. **Column autocomplete** (side task, not a phase) — **DONE, 2026-08-24, real-device verified on MIKE-CU and MIKE-12R.** Type-ahead suggestions in `text`-format fields, sourced from distinct prior values in that column, in both the grid (`GenericListScreen`) and the form (`GenericFormScreen`). Full design and implementation notes in `claude/essentials-v2-column-autocomplete-design.md`. One real bug found and fixed during interactive verification (grid editor's `Autocomplete` needed the real `FocusNode` `trina_grid`'s `editCellRenderer` already hands it, not a disconnected internal one) — see that doc's "Implementation notes" section. One known, accepted gap: keyboard arrow/Enter highlight-navigation works in the form but not the grid, because `trina_grid`'s own cell `FocusNode` claims those key events first for cell navigation — not pursued further this session (bigger lift than the task warranted), documented in code at `GenericListScreen._buildGridAutocompleteEditor`. Mouse/touch tap-to-select and typed-value Enter/Tab/Escape are unaffected in both places.
2. **Phase 4 — Cross-Table Linking** — **DONE, 2026-08-24, real-device verified on MIKE-CU and MIKE-12R.** See the dedicated section below and `claude/essentials-v2-phase4-design.md`.
3. **Phase 6 — Global Search** — **DONE, 2026-08-24, real-device verified on MIKE-CU and MIKE-12R.** See the dedicated section below, `claude/essentials-v2-phase6-design.md`, and `CLAUDE.md`'s "Essentials v2 Phase 6" section for the full real-completion write-up.
4. **Phase 3 — View Types** — **DONE, 2026-08-25, real-device verified on MIKE-CU and MIKE-12R.**
5. **Phase 7 — Import / Export / Templates** — **DONE, 2026-08-26, real-device verified on MIKE-CU and MIKE-12R.** See the dedicated section below and `claude/essentials-v2-phase7-design.md`.
6. **Phase 5 — Scripts & Events** — **DONE, 2026-08-30, real-device verified on MIKE-CU and MIKE-12R — the last item on this list.** See the dedicated section below and `claude/essentials-v2-phase5-design.md`.

**All seven planned phases are now done.** Essentials v2's originally-scoped roadmap is complete as of 2026-08-30 — see each phase's own section below, and the "Deferred" list further down for what was consciously left out rather than forgotten. Next work is either Mike's own real usage surfacing new asks, or one of the already-identified deferred/open items (attachments, Card/gallery view, a real name for the app, etc.).

**Why Phase 4 before Phase 6/3/7/5:** core relational plumbing (`link_record`/`lookup`/`rollup`) that most of the rest of the app benefits from having, and it's what CSV import's "into a linked table" case is blocked on (see above) — building it early also means any later child-table import work is informed by real link-column UI/schema mechanics instead of guessed at.

**Why Phase 6 (Search) before Phase 3/7/5:** Search is SQLite FTS5 — same stack already in use, no new native dependency — and becomes more valuable the moment CSV import and Phase 4 start putting real data volume into the database. For a personal database, findability was judged more valuable sooner than the rest.

**Re-sequenced 2026-08-24 (Scripts & Events moved from position 4 to last):** originally planned as 4/5/6 = Phase 5, Phase 3, Phase 7. Revisited once Phase 4 and Phase 6 were both done and Phase 5 (Scripts & Events) came up next in line. Two reasons drove the change, worked out in discussion rather than assumed:

- **Risk isolation.** Scripts & Events is the single riskiest phase left on the roadmap — a new embedded JS runtime (`flutter_js`/QuickJS, confirmed via a fresh pub.dev/GitHub check on 2026-08-24: Windows and Android both run QuickJS, via bundled prebuilt shared libraries on Windows and FFI on Android; no explicit sandboxing guarantee at the package level, so the "sandboxed" property in this doc's Scripts & Events section has to come from the app only exposing its own intended API surface into the JS global scope, not from the library itself) with real cross-platform packaging risk, the same class of scope Phase 2's design doc explicitly flagged as too much surface area to pull in early for just one field format. Doing it last means taking on that risk once, against an app that's otherwise finished and already proven on both devices, rather than mid-stream while other things are still moving underneath it.
- **Templates depend on Scripts more than Scripts depends on Templates.** The Script API (`record.get/set/save/delete`, `table().find/all/create`, `notify()`, `navigate.to/toRecord()`) is defined against the record/table layer, stable since Phase 1/4 — it doesn't technically need View Types or Import/Export to exist first. But Phase 7's starter template library is much more useful if a template can ship with a pre-wired script (a "Recurring Bill" or "Daily Task" template with a scheduled event attached) than if templates ship first and scripts get retrofitted onto them later. So Scripts ended up ordered *before* Templates specifically, not just "last" arbitrarily — Phase 7's template work should leave a `default_scripts`-shaped hook in template metadata even before Phase 5 lands, so it isn't locked into a no-automation shape.

Mike's own framing, worth keeping on record: scheduled events (the TickTick-replacement use case) are a big part of what makes Scripts valuable, but that value doesn't depend on Views or Import/Export either — this was a deliberate "de-risk by sequencing" call, not a claim that Scripts needs those phases as a prerequisite.

**Process note, not a change:** each item above still gets its own short design pass before Code implements it, the same discipline Phase 1 and Phase 2 both used — "next in line" doesn't mean "skip straight to implementation." (The `color` fix was small enough it skipped a formal design doc — see the Field Model section — but the confirmation-before-implementation discipline still applied.)

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

### Limited CSV import — **DONE, 2026-08-23, real-device verified on MIKE-CU and MIKE-12R**
Not a phase — a side task, scoped to importing into an existing table's plain (non-linked) fields only. Full design (field-mapping, per-format coercion rules, malformed-value handling, UI flow, build order) in `claude/essentials-v2-csv-import-design.md`. Built with the `csv: ^8.0.0` package (its API turned out to be a `Csv().decode()` codec rather than the `CsvToListConverter` the design doc assumed — implementation detail, no behavior change). 44 unit tests + 5 end-to-end tests. See "Roadmap sequencing" above for the summary.

### `color` field format — **DONE, 2026-08-23, real-device verified on MIKE-CU and MIKE-12R**
`FieldConfig.isColor` rendering already worked everywhere; the fix added the missing `FieldFormatChoice` entry and a shared default-value color picker on both `AddFieldScreen` and `ManageFieldsScreen`. See the Field Model section above.

### Column autocomplete — **DONE, 2026-08-24, real-device verified on MIKE-CU and MIKE-12R**
Not a phase — a small side task, same category as the `color` fix and CSV import, done deliberately before Phase 4 starts. Scope narrowed during design to `text`-format fields only (`url`/`barcode`/`link_file`/`text_multiline` were considered and dropped — their values are typically distinct per row, so suggestions would mostly be noise). Suggestions come from a live `SELECT DISTINCT` against the column, prefix-matched, no cache table. Per-field opt-out via `options.autocomplete: false`, toggle in `AddFieldScreen`/`ManageFieldsScreen`. Shipped in both the grid (`trina_grid`'s `TrinaColumn.editCellRenderer` hook, confirmed present in the installed 2.2.2) and the form (Flutter's built-in `Autocomplete<String>`), sharing one debounced suggestion source (`ColumnAutocompleteSource`, `lib/util/column_autocomplete.dart`). Full design, implementation notes, and the one real bug found and fixed (grid editor's missing paired `FocusNode`) in `claude/essentials-v2-column-autocomplete-design.md`.

### Phase 4 — Cross-Table Linking — **DONE, 2026-08-24, real-device verified on MIKE-CU and MIKE-12R**
- Link to record field type
- Lookup and Rollup field types
- Link Definitions metadata
- UI for selecting linked table and display field

Full design in `claude/essentials-v2-phase4-design.md`, grounded in a read of the live schema engine, `GenericDao`, `GenericListScreen`/`GenericFormScreen`, and `AddFieldScreen`/`ManageFieldsScreen`. Two scope calls confirmed with Mike before handoff: `link_record` cardinality is configurable per field (`options.multiple`), not fixed to one or the other; and a reverse-relation panel (a linked-to record's form shows every other-table record linking back to it) ships in this pass, not deferred. `link_record` is new alongside `select`/linked (the existing single-FK-to-a-lookup-table mechanism), not a replacement for it — both coexist, and `link_record`'s JSON-array-of-ids TEXT storage needed `GenericDao._linkedFieldRefs`'s referential-integrity query extended for array-membership matching (`json_each`), not just a new format string recognized. `lookup`/`rollup` reuse `formula`'s existing read-only, computed-at-read-time pattern (`TableConfig.computePreview`, `GenericDao.getAll`) rather than a new mechanism.

**Mike's own multi-hour, both-devices interactive pass found six real issues, all documented and all but one fixed the same session** — full write-up in `claude/essentials-v2-phase4-design.md`'s "Findings from interactive testing" section:
- `select` and `link_record`'s Add Field labels were one word apart in the same dropdown (`'Linked to another table'` vs `'Link to another table'`) — Mike picked the wrong one on his first try. Relabeled both to be unmistakable.
- A pre-existing (not `link_record`-caused) crash: a `select`/linked field whose target table's display column wasn't literally named `name` threw `no such column` opening the grid. Fixed with a defensive fallback (`GenericDao._resolveDisplayColumn`) covering every field created before this fix, plus a real "Which field to show" picker on new fields going forward so this can't recur.
- `NewTableScreen` silently dropped `link_record` (and, same bug, `url`/`color`) — offered in the picker but never wrote real options, producing a field that looked created but wasn't actually linked. Fixed, and turned into a standing rule: a format only belongs in New Table's picker if it can be **fully** supported there, never listed-but-degraded.
- Two migration-halt incidents from the same root cause (`SchemaEditorService.dropTable` called twice on the same table — its precondition checks only `is_deleted`, not physical existence, so a second call authors a DDL guaranteed to fail and halts the whole device's migration queue). Recovered live both times. **The underlying fix is not yet done** — flagged as a real, standing gap worth a future small pass: `dropTable` should check `sqlite_master` directly and no-op or refuse cleanly instead of authoring a doomed DDL statement.
- Grids never refreshed live when another device changed the same table's data (sync itself always worked; nothing told an open `GenericListScreen` to reload). Fixed with a new `SyncService.dataChanges` stream, the same shape `schemaChanges` already used for nav — **this is also the mechanism `claude/essentials-v2-phase6-design.md` already designs Phase 6's remote-write reindexing around**, so Phase 6 depends on this fix being in, not just concurrent with it.
- The reverse-relation panel showed bare row ids with nothing to distinguish them — root cause was that no v2 table has ever actually set `display_field`. Fixed with a fallback to the table's own first field by position, shown alongside the id.

~~**One open item carried forward, not blocking anything:** the `dropTable`-called-twice migration-halt bug above.~~ **Fixed 2026-08-24, during Phase 6** — `dropTable`/`dropField` now no-op instead of authoring a second, doomed migration when the physical table/column is already gone, found as a natural fit while Phase 6 was already touching this code, confirmed against 4 real already-poisoned `migration_status` rows this exact bug had left behind. See Phase 6's own write-up below.

### Phase 6 — Global Search — **DONE, 2026-08-24, real-device verified on MIKE-CU and MIKE-12R**
- Full-text search across all tables
- SQLite FTS5 virtual tables per user table (or a unified search index)
- Search UI — results grouped by table, click-through to record

Full design in `claude/essentials-v2-phase6-design.md`; the real completion write-up (findings below are summarized from it) is in `CLAUDE.md`'s "Essentials v2 Phase 6" section, not the design doc itself this time — worth checking there directly for the full detail. Reached via a new "Search" entry in `HomeShell`'s nav rail/drawer. Both design-time scope calls held: one unified FTS5 index, not per-table; first pass indexes plain stored text only (`text`/`url`/`link_file`/`barcode`), not resolved `select`/`link_record`/`lookup` display values — a deliberate, deferred follow-up.

**A real architectural finding neither of the design's two flagged unknowns predicted, found mid-build, that changed the feature's whole shape.** The first implementation put `search_index` directly inside `essentials.db`. This broke `sql_crdt` outright: `SqliteCrdt.open()`'s `init()` and `getChangeset()` unconditionally enumerate *every* physical table in `sqlite_schema` and assume each one has `modified`/`hlc`/`node_id` columns — an FTS5 virtual table (plus its own shadow tables) has none, so the very next fresh connection to the real `essentials.db` threw `no such column: modified`. Caught by a test before shipping, not a live incident on its own — but recovering from the *attempted* fix became one (below). **Fix, and the resulting standing architectural rule for any future locally-derived, never-synced data:** `search_index` lives in its own separate SQLite file (`search_index.db`, alongside `essentials.db`), opened via a plain `sqflite_common_ffi` connection with zero `sqlite_crdt`/`migration_log`/`SchemaEditorService` involvement — not a table inside the CRDT-managed database at all. Worth remembering for Phase 5 (scripts) or any future feature that wants app-local state that isn't meant to sync: it cannot simply be a new table in `essentials.db`, regardless of whether it's CRDT-columned, because `sqlite_crdt` itself enumerates the whole file's schema, not just tables it recognizes.

**A second real incident, downstream of the first fix, not a new design gap:** the abandoned first design's own stray `migration_log` row wasn't cleaned up when the physical table was emergency-fixed locally, so it synced out normally to the server (`hub.db` grew the same stray table) and from there to MIKE-12R — whose next real launch hit the identical crash before any of this session's code fixes had reached that device. Recovered on all three copies (device, server, device) via the same synced-retraction discipline every prior sync incident in this project has used — retract through the real API, never a raw drop against a CRDT-managed file. Can't recur from the current code; nothing in `SearchIndexService` touches `migration_log` anymore.

**A real backfill gap, found by Mike's own first real search** (searching "new" found nothing, "project" worked) — two lookup tables with real pre-existing rows had zero rows in the index, since the index only ever grew from writes made *after* the feature went live, nothing backfilled what already existed. Fixed: `ensureIndexTable()` now runs a full `reindexAll()` backfill the first time it creates the table on a device (and was backfilled directly against the already-existing Windows index so the fix didn't wait for a relaunch).

**Also fixed, a natural fit found while touching this code, not originally Phase 6 scope:** the Phase 4 `dropTable`/`dropField` double-call migration-halt bug (see Phase 4's own write-up above) — now no-ops instead of authoring a second doomed migration, confirmed against 4 real already-poisoned rows this exact bug had left in the live database from two earlier sessions.

`flutter analyze` clean throughout every fix; new/touched test files (`search_index_content_test.dart`, `search_index_service_test.dart`, two new `schema_editor_service_drop_test.dart` regression tests) each pass individually per the standing rule for anything using `SchemaEditorService.createTable`. Both `flutter build windows`/`apk --debug` clean at every checkpoint. **Mike's interactive verification: done, passed, on both devices** — "project" correctly groups all 4 `Project` records, "new" correctly finds a `Condition` row with the match bolded in the snippet, on both platforms. One thing not yet separately re-confirmed after all the incident-recovery fixes landed: the remote-reindex path (edit on one device, becomes searchable on the other) — it was exercised as a side effect of the recovery work above, worth an explicit quick check next time either device is touched, not urgent.

### Phase 5 — Scripts & Events — **DONE, 2026-08-30, real-device verified on MIKE-CU and MIKE-12R — sequenced last, re-sequenced 2026-08-24, see "Roadmap sequencing" above**
- `flutter_js` integration
- Script editor UI (in-app, with syntax highlighting)
- Event binding UI
- Script API implementation
- Scheduled event runner

Full nine-step build order, every real bug found and fixed, and the final real-device verification pass live in `claude/essentials-v2-phase5-design.md`; the chronological pointer entry is in `CLAUDE.md`'s "Essentials v2 Phase 5" section. Schema + a new `button` field format; `flutter_js`/QuickJS integration behind an isolate-abandonment safety wrapper — **the confirmed technical gap this doc originally flagged turned out to be real**: `flutter_js`'s native `timeout:` constructor param does not actually interrupt a genuine infinite loop, confirmed empirically rather than assumed, so the real safety mechanism is abandoning the worker isolate, not an engine-level interrupt hook. A `record`/`table()`/`notify()`/`navigate` script API (synchronous JS calling into a worker isolate, writes queued and applied only after the script finishes, through a fresh `SqliteCrdt` connection so no custom node identity is ever invented); foreground data/UI event wiring; a script editor + per-table/global event-binding UI; `app_launch` firing; and true background firing on **both** platforms, resolving this doc's other flagged open question — Android via `workmanager`, Windows via a hidden-window relaunch of the same exe (`--background-schedule-check`) triggered by a one-time-registered Scheduled Task, after a real spike confirmed `flutter_js` cannot run in `server.dart`'s bare Dart process at all (it needs `dart:ui`, the same failure mode already documented for Phase 1's `table_config.dart`) — so the "extend the sync hub" option this doc left open was ruled out, not chosen.

Real bugs found and fixed during this phase, several serious enough to be worth remembering as general patterns rather than just this phase's own footnotes: a frozen-`hlc` bug in `SchemaMetadataDao.updateTable` that had silently broken cross-device sync for every table rename since Phase 3; a recurrence of the `crdt_sync` batch-atomicity/500-physical-table-limit incident (see "Known Systemic Risks" below), this time traced to this project's own test files' cleanup pattern; every v2 linked field's stored value being read as the wrong Dart type in both the grid and the form; a Windows-specific process hang from using `dart:io`'s bare `exit(0)` on a live Flutter GUI app instead of the engine's own `exitApplication` quit path; `DeviceId.resolve()` throwing `MissingPluginException` inside Android's `workmanager` background isolate (its platform channel only exists on `MainActivity`'s own engine, not the separate headless one WorkManager creates); and a genuine mid-session schema-change sync race that stranded MIKE-12R's real data until root-caused live via `adb logcat` and recovered through the established `adopt_migrations.dart` playbook. Every one confirmed fixed by Mike on real hardware during this phase's own final verification pass, not just re-tested in isolation.

**`USER_GUIDE.md`** (repo root) was written alongside this final pass — a brief, technical, user-facing reference covering the whole app, not just Phase 5, including a "Known gaps / not yet built" section. Distinct from this file and the rest of `claude/*.md`: those are the project/design history; `USER_GUIDE.md` is what Mike actually uses day to day.

### Phase 3 — View Types — **DONE, 2026-08-25, real-device verified on MIKE-CU and MIKE-12R**
- List view
- Calendar view
- Kanban view
- View management UI (create, rename, delete views per table)

**Card/gallery view — cut from Phase 3 scope, 2026-08-24.** Mike's call: the only place he uses a card view in real life is Excel on Android, and for him it's a waste there too — no real usage case for it in this app. Demoted to a "maybe someday" v2-later item, not deleted from the concept; see "Deferred" below. Phase 3 as actually scoped is List, Calendar, Kanban, plus the view-management UI.

**List view — confirmed design (2026-08-24, worked out from a real Memento Database Pro screenshot Mike supplied as a reference example — grouped-by-title library view, each group showing an entry count and each entry a bold title line plus a gray metadata line underneath).** Sorting drives the display, not the other way around — no independent "which field goes on Line 1/Line 2" pickers beyond what sorting already needs. Config surface, confirmed field-by-field in discussion rather than assumed from the screenshot alone:

- **Primary field** — the primary sort key. Always rendered as each row's Line 1, whether or not grouping is on.
- **Secondary field** — the secondary sort key. Always rendered as the first entry on each row's Line 2.
- **Additional Line 2 fields** (optional) — appended after the secondary field, in chosen order. Display-only; they never affect sort order. This is what lets Line 2 concatenate several fields the way the reference screenshot's subtitle line did (timestamp, then a few data fields, then user name).
- **Primary/secondary sort direction** — independent asc/desc toggle for each of the two sort levels.
- **Group checkbox** — on/off, *no field picker of its own*. When on, consecutive rows sharing the same Primary field value get a collapsible header (that value + a live entry count) drawn above them. This is a purely visual overlay on top of the same two-level sort — Line 1/Line 2 content is identical whether the checkbox is on or off, matching what the reference screenshot actually did (each entry's own Line 1 repeats the group header's value, e.g. "Ice Drop" appears both as the header and again on every entry under it). One level of grouping only — no nested subgroups.
- Net result: primary field IS the group key when grouping is on (there is no separate "group by" picker distinct from the primary sort field) — grouping and sorting are two independent axes (Mike's framing: "grouping and sorting are distinct"), but they deliberately share the same field choices rather than each getting independent pickers, so the whole config is 2 field pickers + 2 direction toggles + 1 checkbox + an ordered list for extra Line 2 fields.
- **Expand all / Collapse all — added 2026-08-25, Mike caught this as missing from the original List view pass.** A toolbar-level control (only visible/enabled when the Group checkbox is on) that expands every group header at once or collapses every group header at once, rather than only per-group tapping. Acts on all groups currently in the list, not a per-group setting — no new persisted config field needed; it's a one-shot action on the existing collapsed/expanded UI state each group header already has, not a new `view_definitions.config` value.

Maps cleanly onto `view_definitions.config` JSON (see "Metadata Schema" above) with no schema surprises expected — this is a display/sort configuration, not a new data concept.

**Calendar view — confirmed design (2026-08-24), worked out against a real TickTick screenshot Mike supplied as the reference model.** Essentials is not a single-purpose app the way TickTick is — most tables have no meaningful date at all — so the central design question was how to handle that, not assumed away.

- **Aggregate by default, not per-table.** One calendar surface overlays events from multiple tables at once, each toggle-able on/off via a checklist mirroring TickTick's "Lists" sidebar — not a separate calendar you switch between per table. Same view-management concept as the other view types, just scoped to "which tables contribute" instead of "which table this view belongs to."
- **Eligibility, not error states.** A table with zero date/datetime-format fields simply never appears in that checklist — no dead checkbox, nothing to design a failure state for. Same discipline as the existing "a format only appears where fully supported" rule from Phase 4's New Table fix, and consistent with the View Types table's existing "Calendar: one date/datetime field required" row.
- **`calendar_field` — a new per-table setting** (alongside `table_definitions`'s existing `display_field`/`order_by`), with two modes, picked once per table rather than re-asked every time the calendar loads:
  - **Single date** — one date/datetime field; the record shows on that one day.
  - **Date range** — a start field + end field pair (both date/datetime format); the record draws as a spanning bar across every day from start through end inclusive (a multi-day trip, a subscription period). Independent of which granularity (Day/Week/Month) is active — a range entry spans correctly in any of the three.
  - Defaults to the first date-format field by position, single mode, if never explicitly set.
- **Color comes from the table's own `color`-format field**, if it has one — reusing the existing Phase 1a `color` field/row-coloring convention directly, not a new per-table color assignment. A table with no `color` field renders with plain default foreground/background — whatever the active theme preset (system/Light/Dark, per `ThemeController`) already supplies — no calendar-specific fallback color invented.
- **Granularity: Day / Week / Month only.** TickTick's dropdown also offers Year/Agenda/Multi-Day/Multi-Week; explicitly cut from scope rather than silently dropped — not expected to see real use on a personal database.
- **Cell content** — not yet pinned down field-by-field, but expected to reuse the same "pick a field, optionally a second" idea List already settled (record title, optionally a time), rather than a fourth independent field-picker scheme.

**Kanban view — confirmed design (2026-08-24).** Same table/records as Grid, grouped into columns by one `select`-format field (per the View Types table's existing requirement). Moving a card between columns is a plain `GenericDao.update()` on that field — the same write path every other edit already uses, no new write logic needed there.

- **Group field** — one `select`-format field; its configured options, in their already-set order (same order the dropdown/select-editor already uses), become the columns. No separate "which field creates columns" concept beyond picking that field.
- **Card content and within-column order — deliberately the same two-tier model as List, not a third field-picker scheme.** A Primary field (card title, and the primary sort determining card order within each column) and a Secondary field (subtitle line, secondary sort), with optional extra fields appending to the subtitle the same way List's Line 2 does. Kanban and List share one mental model for "what shows on a record and in what order" rather than each view type inventing its own.
- **Empty or unmatched select values — never hide the record, same posture the app already takes everywhere else** (Phase 4's own rule: never crash or silently drop a row over bad field metadata). A blank/null select value gets an implicit **"(none)"** column. A value that doesn't match any of the field's currently configured options (a deleted option, a stray CSV-imported value) gets its own ad-hoc column labeled with that literal stored value, placed after the configured columns. Consistent with `format` being a presentation hint over raw TEXT, never a hard constraint, the same reasoning that governs every other format in this app.
- Swimlanes/sub-grouping: out of scope, not requested.

Phase 3's three view types (List, Calendar, Kanban) are now all conceptually settled; this section is the confirmed product shape. **The implementation-ready design pass — view-management UI, the `view_definitions` schema, per-view-type `config` JSON shapes, nav/UI integration, and build order — is done, see `claude/essentials-v2-phase3-design.md` (2026-08-25).**

**Built and real-device verified, 2026-08-25 — full write-up in `CLAUDE.md`'s "Essentials v2 Phase 3" section, not repeated here.** All three view types plus the view-management UI shipped as designed above, with a few implementation-time refinements found through Mike's own interactive testing, worth knowing if this section is read as the current product shape rather than just the historical design record:

- **Calendar's Month view is a continuous, freely-scrollable week-by-week list, not a paginated single-month grid** — changed after Mike tried the paginated version and asked for it to scroll instead. The prev/next arrows now step one week; a day outside the currently-framed month is still dimmed, same visual clarity as a reference app Mike pointed at, just computed against whichever month "owns" the majority of the visible week (Thursday-of-week, the same convention ISO week-numbering uses for edge weeks) rather than a hard page boundary.
- **The recurring `crdt_sync` batch-atomicity gap (a new table's own creating migration and its row data can arrive bundled in one changeset and crash/roll back together) is now a confirmed systemic risk, not a one-off** — hit three times across this phase alone. `tool/adopt_migrations.dart` is the general-purpose manual recovery tool this produced; a real fix at the `crdt_sync` integration level is still not attempted, flagged for a future pass if it keeps recurring.
- One real correctness bug worth remembering for any future long-range date arithmetic in this app: chaining many `Duration`-day additions from a fixed epoch in local time can drift a component-hour off midnight (Dart's `DateTime.add` is DST-aware) even when the resulting calendar date is correct — broke a strict `DateTime ==` "is this today" check silently. Compare by year/month/day fields, not object equality, for anything built this way.

### Phase 7 — Import / Export / Templates — **the rest of it, last; CSV import itself was pulled out and moved up, see above** — **done, 2026-08-26 — built, build-verified, and real-device verified on both MIKE-CU and MIKE-12R. See `claude/essentials-v2-phase7-design.md` and CLAUDE.md's own write-up.**
- ~~CSV import per table (already partially exists)~~ — pulled out as its own side task before Phase 4, see "Roadmap sequencing" above; the "already partially exists" claim was stale (no in-app CSV import code existed as of 2026-08-23 — confirmed by reading `lib/`, not assumed) and is corrected here rather than silently rewritten.
- Memento backup file import — **confirmed CSV, not a proprietary format** (verified against Memento's own documentation, 2026-08-25) — ships as an extension of the existing `CsvImportScreen`: delimiter/text-qualifier config plus create-a-new-table-from-headers. See design doc.
- Starter template library — **confirmed catalog, 2026-08-25: Contacts, Books, Movies, Expenses, Subscriptions, Journal, Household Inventory.** Passwords deliberately excluded — Mike's call, this app has no field-level encryption and a built-in Passwords template would misleadingly imply protection that doesn't exist. Built-in templates are compiled Dart data, not synced rows; user-saved templates ("Save as Template") get a new shared `template_definitions` table. See design doc.
- Full database export/backup — note CSV export of a single table already works today (`GenericListScreen._exportCsv`); this bullet is about a full-database backup/export, a different and larger scope. **Confirmed scope, 2026-08-25: export only, via `VACUUM INTO`, no guided restore in this phase** — see design doc for why restore is a separate, bigger risk surface.

### Deferred (explicitly, not forgotten)
- Reporting / printing — significant effort, moderate value
- iOS / Mac — not a target
- ~~Attachment fields~~ — **superseded and DONE, 2026-09-03.** A narrower `image`-only design shipped instead of the originally-sketched generic `attachment` field, real-device verified on MIKE-CU and MIKE-12R (capture, cross-device sync, byte-identical files confirmed both ends): `claude/essentials-v2-image-field-design.md`, `claude/essentials-v2-file-transfer-endpoint-design.md`, `claude/essentials-v2-image-field-ui-design.md`.
- Card/gallery view — cut from Phase 3, 2026-08-24 ("maybe someday" v2-later item, not deleted from the concept). Mike's real-life usage of card views elsewhere (Excel on Android) is nil-to-negative, so no case for building it here yet.

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

## Known Systemic Risks

### `crdt_sync` batch-atomicity gap around new-table creation — confirmed structural, not a one-off (consolidated 2026-08-25)

Hit **six times** across five different sessions, always the same shape:

1. `schema_admin` session ("Ordering guarantee" section) — a new column's data arriving before the migration that creates it, poisoning the batch and stranding `migration_log` itself.
2. Phase 1 Step 3 — the deliberate infinite-loop repro: `domain` row data referencing a column that didn't exist yet on the receiving device, same all-or-nothing rollback.
3–5. Phase 3 — three separate times in one session: `view_definitions`' own bootstrap, `kanban_test`, and `calendar_test`.
6. Image field design, build order step 6 real-device verification (2026-09-03) — `tool/create_image_test_table.dart`'s `image_field_test` table, created directly against MIKE-CU's local `essentials.db` (a script opening the file directly, not through a live `SyncService` connection — same "no live app pushing it" gap as `kanban_test`/`calendar_test` before it). Recovered the same way: `tool/adopt_migrations.dart` against the stopped hub, confirmed via the server's own connection log and a direct `hub.db` query afterward, then real-device-verified end to end on MIKE-12R (capture) and MIKE-CU (the photo showed up there too) once the table itself was unblocked.

**The mechanism, not just the symptom:** when a brand-new table's `migration_log`-authored DDL and its own row data land in the *same* changeset, and the receiving peer doesn't yet have the physical table (no cached PK info for it), the merge throws (`ON CONFLICT ()`) and the merge transaction — which spans every table in that batch, not just the new one — rolls back entirely. That takes the `migration_log` row down with it too, so the peer has no path to ever learn about the fix that would resolve it, without manual intervention.

**Scope going forward:** this is a `sql_crdt`/`crdt_sync` integration gap, not anything about views specifically — it's a create-table-window problem. Once a table physically exists on every device, ordinary row-level LWW sync is solid (proven since the Part A prototype). It reproduces on **any** phase that creates a new table live and syncs it shortly after — which is most phases now, since that's how tables get made post-`schema_admin`. **Worth checking for explicitly during real-device verification of Phase 5 and Phase 7**, both of which are expected to create tables live (Phase 7's template library instantiating starter tables; Phase 5 if any script ends up creating tables — TBD).

**Not fixed at the library-integration level.** A real fix would need something like the server withholding a new table's row data until its own creating migration is confirmed applied locally — not attempted. `tool/adopt_migrations.dart` (built during Phase 3) is the general-purpose manual recovery tool for when this recurs — faster than a bespoke fix each time, not a substitute for one. Its own doc comment flags this as a real open gap.

---

## Open Decisions (to resolve before relevant phase begins)

- **Home screen / dashboard** — configurable home with pinned tables and recent records, or simple table list?
- **App name** — "Essentials" is a working title; needs a real name before UI embeds it everywhere
- ~~**Global search strategy**~~ — resolved 2026-08-24: one unified FTS5 virtual table, not per-table. See `claude/essentials-v2-phase6-design.md`.
- **Starter template set** — which 5–10 templates ship built-in?
- **Record history UI** — CRDT timestamps give implicit history; surface it to users?
- ~~**Attachment phase number**~~ — resolved by shipping the narrower `image` field directly, 2026-09-03, real-device verified — see `claude/essentials-v2-image-field-design.md`. Its own open items (delete behavior, concurrent-edit orphaned files, size limits, content-addressing) remain genuinely open, not blocking further use.
- ~~**CSV import design**~~ — done, built, and real-device verified, 2026-08-23. See `claude/essentials-v2-csv-import-design.md`.
- ~~**`color` field format**~~ — done and real-device verified, 2026-08-23. See `CLAUDE.md`'s note; no separate design doc was needed.
- ~~**Column autocomplete**~~ — done and real-device verified, 2026-08-24. See `claude/essentials-v2-column-autocomplete-design.md`.
