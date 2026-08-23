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

Only `table_definitions` and `field_definitions` actually shipped in Phase 1. `view_definitions`, `script_definitions`, `event_definitions`, `template_definitions` are still just this list of names — no schema, no code — reserved for Phases 3/5/7 below, not yet designed in detail.

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
| `number` | Numeric keyboard | Format mask | `{ mask: '#,##0.00', prefix: '', suffix: '' }` |
| `currency` | Numeric keyboard | Currency mask | `{ symbol: '$', mask: '#,##0.00' }` |
| `percentage` | Numeric keyboard | % mask | `{ decimals: 2 }` |
| `date` | Calendar picker | Date mask | `{ mask: 'MM/DD/YYYY' }` |
| `time` | Time picker | Time mask | `{ mask: 'HH:mm' }` |
| `datetime` | Date+time picker | DateTime mask | `{ mask: 'MM/DD/YYYY HH:mm' }` |
| `boolean` | Toggle or checkbox | Configurable labels | `{ widget: 'checkbox', true_label: 'Yes', false_label: 'No' }` |
| `select` | Dropdown / picker | Display value | See **Select fields** below |
| `rating` | Star widget | Stars | `{ max: 5 }` |
| `url` | Text box | Tappable link | — |
| `barcode` | Camera scan (Android) / text (Windows) | As-is | — |
| `formula` | Read-only (computed) | Result of expression | `{ expression: '...' }` |
| `attachment` | File picker (embed) | Thumbnail + filename | — |
| `link_file` | File picker / URL input | Path or URL | — |
| `link_record` | Record picker | Configured display field | `{ table: 'table_name', display_field: 'field_name' }` |
| `lookup` | Read-only (resolved) | Value from linked record | `{ link_field: 'field_name', source_field: 'field_name' }` |
| `rollup` | Read-only (computed) | Aggregate value | `{ link_field: 'field_name', source_field: 'field_name', aggregate: 'sum' }` |

**Phase 1 actually shipped a smaller set** — `text, integer, real, boolean, date, dateTime, select` (see `lib/util/field_format_choice.dart`'s `FieldFormatChoice` enum). `select` supports only the "linked table" sub-mode below; inline-option selects, and every format from `rating` down through `rollup` in the table above, are still just this design-doc entry — Phase 2+ work, not yet built.

**Phase 2's actual scope for this table was designed 2026-08-23** (`claude/essentials-v2-phase2-design.md`) and narrows/corrects it in three ways: `lookup`/`rollup` moved out to Phase 4 (both need `link_record`, not yet built); `formula` is scoped to a small spreadsheet-style expression subset rather than full JS; `attachment` is scoped to local-only storage for Phase 2, with cross-device sync (the "File / Attachment Sync" section below) deferred as its own follow-up design. See that doc for the full format catalog, `options` JSON shapes, and the render-layer change (`FieldFormatHandler`) it identified as a prerequisite.

### Select fields

A `select` format has two sub-modes, configured in options:

- **Inline list** — options defined directly on the field, stored as JSON in `field_definitions.options`. Suitable for small, stable lists (e.g. Low/Medium/High). Stored value is the option key.
- **Linked table** — points to another table. Stored value is the linked record's `id` (integer FK). Display value is resolved at render time from the configured display field. If the display value changes on the source record, the stored ID still resolves correctly. This is the default for anything relational.

```json
// Inline select
{ "mode": "inline", "options": [{"key": 1, "label": "Low"}, {"key": 2, "label": "Medium"}, {"key": 3, "label": "High"}] }

// Linked table select
{ "mode": "linked", "table": "priority", "display_field": "name", "multi": false }
```

### Attachment vs. Link (file) — separate formats, separate storage mechanisms

- **`attachment`** — file is copied into `C:\Databases\essentials_app\files\{table}\{record_id}\`. App owns it. Synced via file transfer endpoint on hub server. Android equivalent: app data directory. **Dropped from Phase 2 entirely (confirmed 2026-08-23) — local storage and sync will be designed and built together in a future phase, see `claude/essentials-v2-phase2-design.md`.**
- **`link_file`** — stores a path string or URL. Points to a file the app does not own or manage. Not synced. Displays content if accessible, handles gracefully if not.

A record can have both formats on different fields simultaneously. Users add whichever they need.

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

**Not built yet as of 2026-08-23** (confirmed by reading `server/bin/server.dart` — no file/upload endpoint exists). `attachment` was dropped from Phase 2 entirely (confirmed 2026-08-23) rather than shipped local-only as originally proposed — this section's implementation, local storage and sync together, is deferred to its own future phase. See `claude/essentials-v2-phase2-design.md`.

---

## Features Roadmap

### Phase 1 — Dynamic Schema Engine — **DONE, 2026-08-22**
- `table_definitions` + `field_definitions` metadata schema
- Dynamic DDL execution (CREATE TABLE, ALTER TABLE)
- Table creation / field management UI
- ~~Port 19 current tables as built-in registered tables (data preserved)~~ — **did not happen, correctly.** Superseded by the clean-slate decision recorded above and in `claude/essentials-v2-phase1-design.md`: the database starts genuinely empty, no business tables auto-recreated, no `is_builtin` concept. This bullet was never updated when that decision was made — flagging it here rather than silently deleting it, same reasoning as the Metadata Schema section's correction above.
- `TableDiscoveryService` replaced by `SchemaRegistry`, reading from metadata (not `sqlite_master` heuristics)

Implementation detail, verification results, and the full build order live in `claude/essentials-v2-phase1-design.md`. Code-reviewed complete 2026-08-23 (see `claude/project-overview.md`'s Current Status section) — every design rule (never emit CRDT columns, full identifier quoting, same-transaction `migration_log` + metadata writes, two-stage delete, metadata-driven referential integrity) verified actually implemented, not just designed.

### Phase 2 — Rich Field Types — **complete and real-device verified 2026-08-23** — all 7 build order steps built, then confirmed working on both MIKE-CU and MIKE-12R the same day, including two real findings fixed live (a stale 12R build, and a Save-button nav-bar overlap in `GenericFormScreen`) — see CLAUDE.md's Phase 2 sections
- `number` (revised, `decimals` option) / `currency` / `percentage` / `rating` / `url` / `link_file` / `barcode` / `formula`, plus inline-mode `select`
- Formula field — **scoped to a small spreadsheet-style expression subset for Phase 2**, not full JS (`flutter_js` stays reserved for Phase 5). Confirmed 2026-08-23; implementation runs on Opus, rest of Phase 2 on Sonnet. **Built 2026-08-23** (build order step 6) — hand-rolled evaluator after a real pub.dev check, `options: {expression, resultType, decimals}`, value computed at read time into an always-NULL physical column so format changes stay metadata-only. Full write-up in CLAUDE.md's Phase 2 Step 6 section.
- Barcode scan integration (Android camera / Windows text fallback) — **built 2026-08-23** (build order step 7). Spiked and chosen: `mobile_scanner: ^7.4.0`, bundled MLKit mode (no Play Services dependency), confirmed not to break the Windows build. See CLAUDE.md's Phase 2 Step 7 section for the spike write-up and a real, tracked KGP-warning caveat.
- **`lookup`/`rollup` moved out of Phase 2 to Phase 4**, where they correctly belong (both need `link_record`, which Phase 4 builds) — the format table above still lists them under the general spec; this bullet is the correction, same convention as Phase 1's corrections above.
- **Image/attachment field dropped from Phase 2 entirely, confirmed 2026-08-23** — not even local-only. A field that doesn't sync between devices was judged not worth shipping half-built; local storage and hub file-transfer sync (see "File / Attachment Sync" above, still unbuilt) will be designed and built together as their own future phase.

Full design — the format catalog, `options` JSON shapes for every Phase 2 format, and the `FieldFormatHandler` render-layer change identified as a prerequisite (both `GenericListScreen`/`GenericFormScreen` currently branch on a 6-value `FieldType` enum in 3-4 places each; adding this many more formats the same way was judged not to scale) — lives in `claude/essentials-v2-phase2-design.md`.

### Phase 3 — View Types
- List view
- Card/gallery view
- Calendar view
- Kanban view
- View management UI (create, rename, delete views per table)

### Phase 4 — Cross-Table Linking
- Link to record field type
- Lookup and Rollup field types
- Link Definitions metadata
- UI for selecting linked table and display field

### Phase 5 — Scripts & Events
- `flutter_js` integration
- Script editor UI (in-app, with syntax highlighting)
- Event binding UI
- Script API implementation
- Scheduled event runner

### Phase 6 — Global Search
- Full-text search across all tables
- SQLite FTS5 virtual tables per user table (or a unified search index)
- Search UI — results grouped by table, click-through to record

### Phase 7 — Import / Export / Templates
- CSV import per table (already partially exists)
- Memento backup file import (CSV-based)
- Starter template library (Contacts, Books, Movies, Passwords, Expenses, etc.)
- Full database export/backup

### Deferred (explicitly, not forgotten)
- Reporting / printing — significant effort, moderate value
- iOS / Mac — not a target

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
