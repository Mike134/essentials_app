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

1. **Limited CSV import** (side task, not a phase) — **DONE, 2026-08-23, real-device verified on MIKE-CU and MIKE-12R.** Import into an *existing* table's plain fields only. No auto-creating a new table from CSV headers, no importing into a linked/child-table field (needs Phase 4 first). CSV *export* already existed and needed no work — `GenericListScreen._exportCsv` is already format-aware. Built with the `csv: ^8.0.0` pub package, coercion logic in `lib/util/csv_import/csv_import_coercion.dart`, new `CsvImportScreen` (flat ListView reached via an "Import from CSV" toolbar icon), per-row commits via `GenericDao.insert`. 44 unit tests + 5 end-to-end tests. Full design in `claude/essentials-v2-csv-import-design.md`.
1a. **`color` field format** (small fix, not its own phase) — **DONE, 2026-08-23, real-device verified on MIKE-CU and MIKE-12R.** See the Field Model section above.
1b. **Boolean read-back bug fix** (found incidentally during CSV import work, not planned) — **DONE, 2026-08-23, real-device verified on MIKE-CU and MIKE-12R.** See the Field Model section above.
1c. **Column autocomplete** (side task, not a phase) — **DONE, 2026-08-24, real-device verified on MIKE-CU and MIKE-12R.** Type-ahead suggestions in `text`-format fields, sourced from distinct prior values in that column, in both the grid (`GenericListScreen`) and the form (`GenericFormScreen`). Full design and implementation notes in `claude/essentials-v2-column-autocomplete-design.md`. One real bug found and fixed during interactive verification (grid editor's `Autocomplete` needed the real `FocusNode` `trina_grid`'s `editCellRenderer` already hands it, not a disconnected internal one) — see that doc's "Implementation notes" section. One known, accepted gap: keyboard arrow/Enter highlight-navigation works in the form but not the grid, because `trina_grid`'s own cell `FocusNode` claims those key events first for cell navigation — not pursued further this session (bigger lift than the task warranted), documented in code at `GenericListScreen._buildGridAutocompleteEditor`. Mouse/touch tap-to-select and typed-value Enter/Tab/Escape are unaffected in both places.
2. **Phase 4 — Cross-Table Linking** — **DONE, 2026-08-24, real-device verified on MIKE-CU and MIKE-12R.** See the dedicated section below and `claude/essentials-v2-phase4-design.md`.
3. **Phase 6 — Global Search** — **design complete 2026-08-24, ready for Claude Code once Phase 4 wraps.** See the dedicated section below and `claude/essentials-v2-phase6-design.md`.
4. **Phase 5 — Scripts & Events**
5. **Phase 3 — View Types**
6. **Phase 7 — Import / Export / Templates** (the rest of it: Memento backup import, starter template library, full DB export/backup)

**Why Phase 4 before Phase 6/5/3:** core relational plumbing (`link_record`/`lookup`/`rollup`) that most of the rest of the app benefits from having, and it's what CSV import's "into a linked table" case is blocked on (see above) — building it early also means any later child-table import work is informed by real link-column UI/schema mechanics instead of guessed at.

**Why Phase 6 (Search) before Phase 5 (Scripts):** Scripts & Events is the single riskiest phase left on the roadmap — a new embedded JS runtime (`flutter_js`/QuickJS) with real sandboxing and cross-platform (Windows + Android) packaging risk, the same class of scope Phase 2's design doc explicitly flagged as too much surface area to pull in early for just one field format. That risk hasn't gone away by being later in the list. Search, by contrast, is SQLite FTS5 — same stack already in use, no new native dependency — and becomes more valuable the moment CSV import and Phase 4 start putting real data volume into the database. For a personal database, findability was judged more valuable sooner than automation.

**Why Phase 3 (Views) stays near the end:** view types are worth more once there's real data and real relational structure to look at. Building List/Card/Calendar/Kanban views for tables that are still mostly empty (the state most tables were in pre-CSV-import) has low marginal value; CSV import, Phase 4, and Phase 6 all land real, browsable data first.

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

**One open item carried forward, not blocking anything:** the `dropTable`-called-twice migration-halt bug above. Worth fixing before it bites a third time, but not scheduled to a specific phase.

### Phase 6 — Global Search — **design complete 2026-08-24, ready for Claude Code once Phase 4 wraps — sequenced before Phase 5, see "Roadmap sequencing" above**
- Full-text search across all tables
- SQLite FTS5 virtual tables per user table (or a unified search index)
- Search UI — results grouped by table, click-through to record

Full design in `claude/essentials-v2-phase6-design.md`, grounded in a read of `GenericDao`, `SyncService`, `MigrationService`, `database_helper.dart`, and `SchemaEditorService`. Two scope calls confirmed with Mike, resolving this section's own former "Open Decisions" entry: **one unified FTS5 virtual table** across every user table, not one per table (a per-table index would need its own migration every time a searchable field is added/removed/reformatted — real ongoing maintenance burden no other part of the schema engine carries); and **first pass indexes plain stored text only** (`text`/`text_multiline`/`url`/`barcode`/`link_file`), not resolved `select`/`link_record`/`lookup` display values — which is what lets Phase 6 be built independently of Phase 4's completion, in either order. No SQL triggers anywhere in this design (none exist anywhere in this codebase today, and this project already learned once, the hard way, that `ON DELETE CASCADE` never fires because `crdt.execute()` rewrites DELETE into an UPDATE — see Phase 1's "Critical risks" #3): local writes reindex via `GenericDao.insert`/`update`/`delete`, remote writes reindex via `SyncService.dataChanges` (the same stream `GenericListScreen` already uses to live-reload on remote edits) — both already-proven mechanisms, nothing new. Two things flagged for Claude Code to verify against the actual installed packages before committing to the shape: whether FTS5 is compiled into the SQLite build on both platforms, and whether `crdt.execute()` passes a virtual table with no CRDT bookkeeping columns through cleanly.

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
- ~~**Global search strategy**~~ — resolved 2026-08-24: one unified FTS5 virtual table, not per-table. See `claude/essentials-v2-phase6-design.md`.
- **Starter template set** — which 5–10 templates ship built-in?
- **Record history UI** — CRDT timestamps give implicit history; surface it to users?
- **Attachment phase number** — where local storage + sync (dropped from Phase 2) lands in the roadmap; not yet decided.
- ~~**CSV import design**~~ — done, built, and real-device verified, 2026-08-23. See `claude/essentials-v2-csv-import-design.md`.
- ~~**`color` field format**~~ — done and real-device verified, 2026-08-23. See `CLAUDE.md`'s note; no separate design doc was needed.
- ~~**Column autocomplete**~~ — done and real-device verified, 2026-08-24. See `claude/essentials-v2-column-autocomplete-design.md`.
