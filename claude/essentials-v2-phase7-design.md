> **Source of truth: this repo file.** No claude.ai Project mirror is kept — Claude Code reads this directly; a claude.ai/Cowork session reads it live via the desktop-app device bridge when connected. See `claude/project-overview.md` for the file index.

---

# Essentials v2 — Phase 7: Import / Export / Templates

**Session date:** 2026-08-25
**Status:** Design, grounded in a read of the live codebase (`claude/essentials-v2-csv-import-design.md` and its shipped code — `lib/screens/csv_import_screen.dart`, `lib/util/csv_import/csv_import_coercion.dart` — plus `lib/db/schema_editor_service.dart`, `lib/screens/new_table_screen.dart`, `lib/db/database_helper.dart`, `pubspec.yaml`) and a factual check of Memento Database's own documented export format (see "Memento's real export format" below — not assumed). **Done — built, build-verified, and real-device verified on both MIKE-CU and MIKE-12R (2026-08-26). See CLAUDE.md's "Essentials v2 Phase 7" write-up for the full build/verification history.**
**Companion docs:** `claude/essentials-v2-architecture.md` (Phase 7 roadmap entry, the `template_definitions` metadata-schema reservation, "Known Systemic Risks" — directly relevant here, see below), `claude/essentials-v2-csv-import-design.md` (the existing single-table CSV importer this phase extends, not replaces), `claude/essentials-v2-phase1-design.md` (`SchemaEditorService.createTable`/`addField`, the pipeline this phase's two new table-creation flows both reuse as-is)

---

## Confirmed decisions (2026-08-25, before handoff to Claude Code)

- **"Memento backup import" is CSV, not a proprietary format — confirmed by reading Memento's own documentation, not assumed.** Memento Database's help/wiki content describes only CSV for library data import/export, with a user-configurable field delimiter and text qualifier at export time; no documented JSON/XML/binary backup format exists to target. The architecture doc's own phrasing — "Memento backup file import (CSV-based)" — already anticipated this; this design doesn't invent a new file format, it extends the existing `CsvImportScreen`/`coerceCsvCell` pipeline with the two things a real Memento migration needs that today's importer doesn't have: a configurable delimiter/text-qualifier, and the ability to create a brand-new table from the CSV's own headers rather than only importing into a table that already exists.
- **New-table-from-headers and the starter template library share one mechanism, not two.** Both are "define a table's field list in bulk, then create it" — a CSV's headers and a template's fixed field catalog are just two different sources feeding the exact same `SchemaEditorService.createTable` + sequential `addField` calls `NewTableScreen._submit` already uses today, unmodified. No new schema-creation code path is written; both new flows produce a `List` of `(displayName, format, optionsJson)` and hand it to the same loop.
- **Built-in templates are compiled Dart data, not `template_definitions` rows.** They're identical on every install, never edited, and versioned with the app itself — seeding them as synced database rows would mean writing seven-plus `migration_log`/table_definitions-shaped inserts for data that isn't really *data*, and would needlessly touch the batch-atomicity risk (see below) for zero benefit. `template_definitions` (the table `architecture.md`'s Metadata Schema section already reserved) holds **only user-saved templates** — the "save this table as a template" half of the original "built-in and user-saved" description. A built-in template and a user-saved one are unified at the *picker UI* level (one list, one flow to instantiate either), not at the storage level.
- **Full database backup is export-only in this phase — no restore/import-a-backup UI.** A backup a user can't test-drive without real risk isn't worth building in the same pass as the risky half: restoring a live, actively-syncing CRDT database means replacing `essentials.db` out from under `sqlite_crdt` and every other synced device's expectations about HLC/node_id state — a materially bigger, separate risk surface than producing a consistent snapshot. Export gives Mike a real safety net today (copy the file back by hand via Letos, or before a reinstall, same as any SQLite file backup always has); guided restore is flagged below as a real gap, not silently dropped, for a future pass if it's ever actually needed.
- **No format auto-detection for CSV-derived fields.** Every field created from a CSV header defaults to `text` format, exactly like typing a field into `NewTableScreen` and leaving it at the default — the user reviews and changes formats in the same screen before committing, same "consciously defer what isn't worth the effort" call the original CSV import design already made about encoding auto-detection. Sniffing "looks like a date" or "looks like a number" from sample data is real, error-prone work for a feature that (per Mike's own framing) mostly exists to migrate a handful of Mike's own old Memento libraries once, not to be bulletproof against arbitrary CSVs forever.
- **Model tier: Sonnet throughout.** Nothing here resembles the formula evaluator's novel-parsing-and-evaluation shape — it's well-specified extensions to an already-shipped screen, a template catalog, and a single `VACUUM INTO` call, the same bucket every routine UI/plumbing step in Phases 2/3/6 already used Sonnet for.

---

## Memento's real export format — verified, not assumed

Checked directly against Memento Database's own help/wiki content before designing against it (see Sources below):

- Data export/import is described only as **CSV**, with a user-chosen **field delimiter** and **text qualifier** at export time (Memento's own import UI asks the user to pick both). No documented proprietary binary/JSON/XML backup format exists for library *data* — a "library structure" export exists separately (recreates an empty library's field definitions on the same device) but isn't documented as an interchange format this app could reliably parse, and isn't needed here since Phase 7's own new-table-from-headers already solves "get the field list into Essentials," just from CSV headers instead.
- Memento auto-fills calculation/formula fields on import even if they weren't in the source CSV — not relevant to Essentials' own `formula` format (computed independently, at read time, from this app's own expression subset), but worth knowing so a "why doesn't this computed column match what Memento showed" question doesn't get chased as a bug later.

**Practical conclusion:** a real Memento migration is "export each old library as CSV with Mike's chosen delimiter/qualifier, then run it through Essentials' new-table-from-CSV flow, review the auto-created fields, fix formats and add any linked/computed fields by hand afterward via `AddFieldScreen`." No Memento-specific parsing code is needed beyond delimiter/qualifier support — the rest is just this phase's general CSV-to-new-table capability.

Sources: [Importing and exporting data - Memento Database Wiki](https://wiki.mementodatabase.com/index.php/Importing_and_exporting_data), [Importing & Exporting data – Memento Database Help](https://help.mementodatabase.com/knowledge-base/importing-exporting-data-2/)

---

## What the code already does today (verified by reading it)

| Capability | Where | Relevance |
|---|---|---|
| Table + field creation, fully sync-safe | `SchemaEditorService.createTable`/`addField` (`lib/db/schema_editor_service.dart` lines ~77, ~129) — one `migration_log` row + one metadata row per call, in a transaction, then local `MigrationService.applyPending()` | The exact mechanism both new-table-from-CSV and template instantiation reuse unchanged — confirmed by reading it end to end, not assumed to exist in a reusable shape. |
| A working multi-step "define fields, then create" screen | `NewTableScreen` (`lib/screens/new_table_screen.dart`) — `_pendingFields` list, per-field format picker, sequential `_editor.addField` calls after `_editor.createTable` | Both new flows extend this screen's existing shape (pre-populating `_pendingFields` from a template or CSV headers) rather than building a second screen from scratch. |
| CSV parsing already proven | `Csv().decode(content)` (`csv` package, `lib/screens/csv_import_screen.dart` line ~151) | Already handles quoted/embedded-comma/embedded-newline CSV correctly per the original design doc's build-order step 1 verification. Delimiter/qualifier configurability needs checking against the installed `csv` package version's actual API — flagged below, not assumed. |
| Existing importable-field filtering and coercion | `isCsvImportable`, `coerceCsvCell` (`lib/util/csv_import/csv_import_coercion.dart`) | Reused completely unchanged for the row-import half of new-table-from-CSV — once the table and fields exist (created fresh instead of pre-existing), row coercion/commit is identical to today's "import into existing table" path. |
| DB file location, resolved per-platform | `DatabaseHelper._windowsDirectory`/`_androidDirectory`, `_fileName = 'essentials.db'` (`lib/db/database_helper.dart` lines ~30-33, ~154-160) | The path `VACUUM INTO` backs up *from* — confirms it's a single physical file per platform, no multi-file bundle to worry about (attachments don't exist yet — dropped from Phase 2, no assigned phase — so there's no `files/` directory to include in a backup even if one existed). |
| `PRAGMA`/non-CRDT-row SQL already passes through `crdt.execute()` cleanly | `database_helper.dart` (`PRAGMA journal_mode = WAL`, `PRAGMA foreign_keys = ON`) | Same precedent Phase 6 used to justify writing directly against `search_index`'s FTS5 table — `VACUUM INTO` is the same kind of "plain SQL, not a business-table row write" statement, plausible to run the same way, not confirmed against `sqlite_crdt`'s source (see open questions). |
| No zip/archive or file-save dependency yet | `pubspec.yaml` (`file_picker: 12.0.0-beta.7`, `csv: ^8.0.0`, no `archive`/`path_provider`/`share_plus`) | A single-file `VACUUM INTO` backup needs no new dependency — `file_picker`'s save-location flow (already used for CSV export) covers "where does the backup file go." |

---

## Data model

### `template_definitions` — new shared table, user-saved templates only

```sql
CREATE TABLE "template_definitions" (
    "template_id"  INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
    ),
    "display_name" TEXT NOT NULL,
    "description"  TEXT,
    "icon"         TEXT,
    "fields_json"  TEXT NOT NULL,   -- JSON array of {display_name, format, options_json}
    "created_at"   TEXT NOT NULL
);
```

Same timestamp+random id convention as `view_definitions`/`migration_log` (any device can save a template). Shared/synced, same bucket as `table_definitions` — a template Mike saves on MIKE-CU should be pickable from MIKE-12R. Created via the standard `migration_log`-authored `CREATE TABLE`, self-applying on every device the usual way, and — like `view_definitions` — needs a real `server/bin/server.dart` `schemaStatements` entry since it's shared data the hub must be able to merge against.

`fields_json` is deliberately the same shape `SchemaEditorService.addField` already consumes (`display_name`, `format`, `options` JSON) — a saved template is nothing but a captured list of `addField` calls, so instantiating one is the same loop `NewTableScreen._submit` already runs, just fed from `template_definitions` instead of the user's own typed-in field rows.

### Built-in templates — a static Dart catalog, not database rows

```dart
class BuiltinTemplate {
  const BuiltinTemplate({required this.displayName, required this.icon, required this.fields});
  final String displayName;
  final String icon;
  final List<TemplateField> fields; // same shape as template_definitions.fields_json, in-memory
}

const builtinTemplates = <BuiltinTemplate>[ /* the seven below */ ];
```

No `template_id`, no sync, no `migration_log` entries — these exist only as compiled data the picker UI reads directly, identical on every device by construction. Confirmed decision above explains why; the practical payoff is that shipping/editing the built-in set is a plain code change (a future template added in a later release), never a data migration.

### Saving a table as a template

New action (e.g. in `ManageTablesScreen`'s per-table menu, or `ManageFieldsScreen`'s toolbar — exact placement is an implementation detail, not a design question): reads that table's current `field_definitions` (via `SchemaMetadataDao.loadFields`, already used elsewhere), maps each to `{display_name, format, options}`, and inserts one `template_definitions` row. **Fields that reference another table by name — `select` in linked mode, `link_record`, `lookup`, `rollup` — are captured with their target table name as-is.** On *instantiation* (not on save), if the referenced table no longer exists, that one field is skipped with a warning, the rest of the template still instantiates — the same "never hide the record, never crash on bad field metadata" posture Kanban's unmatched-select-value handling and CSV import's malformed-value handling already established, applied here to a new case rather than invented fresh. `formula` fields are captured with their expression as-is (portable — the expression doesn't reference other tables).

### Full database backup

```sql
VACUUM INTO '<chosen path>\essentials_backup_2026-08-25.db';
```

Run via `crdt.execute()` against the live `essentials.db` connection — `VACUUM INTO` is SQLite's own built-in, WAL-safe way to write a single consistent snapshot of the current database state to a new file, without needing to close the app, pause sync, or stop writes. Produces one plain `.db` file, openable in Letos/DBeaver like any other SQLite file — not a zip, not a proprietary container, matching this project's consistent preference for the simplest correct mechanism (same instinct that kept `view_definitions`/`search_index` as plain tables rather than reaching for something heavier). `search_index.db` (Phase 6, deliberately never synced, fully reconstructible) is **not** included — same reasoning that already excludes it from sync applies to backup.

---

## The starter template catalog (confirmed 2026-08-25)

All seven use only formats already shipped in Phase 1/2 — no new field-format work needed for the catalog itself.

| Template | Fields |
|---|---|
| **Contacts** | Name (text) · Phone (text) · Email (text) · Address (text_multiline) · Birthday (date) · Notes (text_multiline) |
| **Books** | Title (text) · Author (text) · ISBN (barcode) · Genre (select, inline: Fiction / Non-fiction / Biography / Sci-Fi / Mystery / Other) · Rating (rating) · Read (boolean) · Notes (text_multiline) |
| **Movies** | Title (text) · Director (text) · Year (integer) · Genre (select, inline) · Rating (rating) · Watched (boolean) · Notes (text_multiline) |
| **Expenses** | Description (text) · Amount (currency) · Date (date) · Category (select, inline: Food / Transport / Housing / Entertainment / Health / Other) · Paid (boolean) |
| **Subscriptions** | Name (text) · Cost (currency) · Renewal Period (select, inline: Weekly / Monthly / Yearly) · Next Renewal (date) · Color (color) |
| **Journal** | Date (date) · Title (text) · Entry (text_multiline) · Mood (select, inline: Great / Good / Okay / Bad / Terrible) |
| **Household Inventory** | Item (text) · Location (text) · Quantity (integer) · Value (currency) · Barcode (barcode) |

**Passwords deliberately left out, confirmed with Mike 2026-08-25** — this app has no field-level encryption (every value is physically plain TEXT, the "Excel model" the whole schema engine is built on), and a built-in Passwords template would visually imply a level of protection that doesn't exist. Not a technical limitation being worked around — a real product judgment call: don't ship a template whose whole premise misleads about what the app actually does with the data. Nothing stops Mike from building his own Passwords table by hand if he wants one, same as any other table — this only affects the curated built-in list.

---

## CSV import extension: new-table-from-headers + delimiter/qualifier config

Extends `CsvImportScreen` (no new screen) with a mode choice at the top: **"Import into an existing table"** (today's behavior, unchanged) or **"Create a new table from this file."**

New-table mode's flow, reusing `NewTableScreen`'s field-list UI rather than reinventing it:

1. Pick CSV file first (headers are needed before field names can be proposed) — same `file_picker` step, now with two optional fields alongside it: **Field delimiter** (default `,`) and **Text qualifier** (default `"`), for a Memento export using non-default choices. *(Verify the installed `csv` package version's actual API supports custom delimiter/qualifier before committing to this UI — flagged below, not assumed from the package name alone.)*
2. Table display name (same `TextField` + live physical-identifier preview `NewTableScreen` already has, via `SchemaEditorService.previewTableIdentifier`).
3. One row per CSV header, pre-populated exactly like `NewTableScreen`'s field-add row: display name defaults to the header text (editable), format defaults to `text` (editable, same picker `NewTableScreen` already offers, same exclusions — no `lookup`/`rollup`/inline-`select`/`formula` at creation time, identical reasoning `_supportedInitialFieldFormats`'s own doc comment already gives). A header the user doesn't want as a field can be excluded, same as "Don't import this column" in the existing mapping UI.
4. **Create** — runs `SchemaEditorService.createTable` then sequential `addField` calls (identical code path to `NewTableScreen._submit`), then immediately proceeds into the existing row-coercion/commit flow (`_coerceRow`/`dao.insert` per row, same batching, same skip/warn summary) against the table and fields that now exist.

Everything from "then existing row-coercion/commit flow" onward is literally the same code already shipped — the only new work is steps 1–4 producing a target table and column mapping instead of the user picking a pre-existing one.

---

## UI integration

- **CSV import mode toggle** — a segmented control or two buttons atop `CsvImportScreen`, gating which of the two flows (existing-table mapping vs. new-table-from-headers) the rest of the screen shows. Same screen, same entry point (the toolbar button next to "Export to CSV" in `GenericListScreen`).
- **"New Table" entry point gains a template option** — `NewTableScreen`'s opening state offers "Start from scratch" (today's behavior) or "Start from a template," the latter showing one combined list (built-in catalog + any `template_definitions` rows) with a preview of each template's field list before committing. Picking a template pre-populates `_pendingFields` exactly as if the user had typed each one in by hand — every field stays editable/removable before Create Table, same as today.
- **"Save as Template"** — a new action reachable from wherever a table's other management actions live (`ManageTablesScreen` or `ManageFieldsScreen`'s toolbar — Claude Code's call at implementation time which fits the existing menu shape better), prompting for a template display name/description, then writing the `template_definitions` row per "Data model" above.
- **"Backup Database"** — a new `SettingsScreen` action (alongside where CSV import/export already live conceptually), invoking `file_picker`'s save-file flow for a destination path, then the `VACUUM INTO` call, with a simple success/failure confirmation. No progress UI needed — `VACUUM INTO` on a personal-scale database is expected to be fast, not a long-running operation requiring cancellation/progress reporting (confirm this assumption holds against Mike's actual data volume during real-device verification, not assumed indefinitely).

---

## Build order

1. **New-table-from-CSV** (the CSV mode toggle, delimiter/qualifier config, header-to-field-row UI, wired to the existing `createTable`/`addField`/row-commit pipeline) — the piece a real Memento migration actually needs, and the one most worth real-device verifying early since it's the only genuinely new UI flow in this phase.
2. **`template_definitions` table** (migration_log-authored, both `essentials_app` and `server/bin/server.dart` schemaStatements) + the built-in template Dart catalog — pure data/infra, no new UI logic beyond what step 1's field-row UI already proved.
3. **"Start from a template" in `NewTableScreen`** — reuses step 1's proof that pre-populating `_pendingFields` from an external source works cleanly.
4. **"Save as Template"** — the reverse direction, once there's at least one real user-created table worth saving to validate against.
5. **Full database backup** (`VACUUM INTO`, Settings action) — independent of everything else above, safe to build in any order relative to 1–4; sequenced last only because it's the lowest-risk, most self-contained piece and there's no reason to front-load it ahead of the two features Mike is actually waiting on for his Memento migration.

---

## Open questions / risks flagged, not resolved

- **`csv` package delimiter/qualifier API** — confirm the installed `csv: ^8.0.0` version actually exposes configurable field-delimiter/text-qualifier options (the package's own docs should cover this, not re-checked here) before committing to that part of the UI. If it doesn't, the fallback is documenting "re-save the Memento export with comma delimiter and double-quote qualifier before importing" rather than blocking the whole feature on it.
- **`VACUUM INTO` through `crdt.execute()`** — plausible from the existing `PRAGMA`-passthrough precedent (see "what the code already does today" above), not confirmed against `sqlite_crdt`'s own source. If it turns out `crdt.execute()` unconditionally expects CRDT bookkeeping columns on anything it touches (same open question Phase 6 flagged for `search_index` and never fully closed), the fallback is opening a second, plain `sqflite`/FFI connection to the same file specifically for the `VACUUM INTO` call, bypassing the CRDT wrapper for this one read-only-of-effect statement.
- **The batch-atomicity gap (`claude/essentials-v2-architecture.md`'s "Known Systemic Risks") applies directly to both new table-creation flows here, more so than most prior phases.** New-table-from-CSV and template instantiation both create a brand-new table via `migration_log` *and then immediately bulk-insert however many rows the source has* — exactly the create-table-window trigger condition already confirmed five times. Real-device verification for both flows should specifically include creating a table with a real batch of rows (not just one or two) and confirming the other device receives both the schema and the data cleanly, with `tool/adopt_migrations.dart` as the known recovery path if it doesn't. Worth treating as an expected finding to check for, not a surprise if it recurs a sixth time.
- **Guided restore-from-backup is out of scope, flagged above as a real gap** — if Mike ever needs it for real (not just "nice to have"), it's a separate design pass given the CRDT-desync risk a naive file-replace would carry.
- **Exact menu placement for "Save as Template"** — `ManageTablesScreen` vs. `ManageFieldsScreen` vs. somewhere in `GenericListScreen`'s own toolbar — left to Claude Code's judgment at implementation time, matching whichever existing menu shape fits without forcing a new one.
