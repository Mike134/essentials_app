> **Source of truth: this repo file.** As of 2026-08-24, this project stopped mirroring design docs into a claude.ai Project doc -- Mike is always on the desktop app, so a claude.ai/Cowork session can read this file directly (via the device bridge) whenever it needs it, and Claude Code always reads it locally. Maintaining two full copies was pure duplicated effort with no real benefit. The claude.ai Project now keeps a single short pointer doc (`claude/project-overview.md`, the Project's own trimmed copy) instead of a full mirror of every doc -- see that doc's note for the one edge case (a browser/mobile session, no desktop app connected) this doesn't cover.

---

# Essentials v2 — Phase 1: Dynamic Schema Engine

**Session date:** 2026-08-22
**Status:** Design, grounded in a read of the live codebase (`lib/`, `schema.sql`, `CLAUDE.md`)
**Companion doc:** `claude/essentials-v2-architecture.md`

---

## Summary

Phase 1 turns schema from something the developer writes into something the user creates in the app. The good news from reading the code: **v1 is already most of the way there.** `TableDiscoveryService` builds a complete `TableConfig` from SQLite introspection with zero hand-written Dart per table. `SchemaEditorService` already runs `ALTER TABLE ADD COLUMN` from inside the app. The migration system already propagates DDL to every device and the server in guaranteed order.

Phase 1 is therefore **not a rewrite**. It is three changes:

1. Replace *derived* schema knowledge (heuristics) with *stored* schema knowledge (metadata tables).
2. Add table creation — the one DDL operation the app can't do yet.
3. Route every DDL operation through `migration_log` so it reaches all devices, instead of being single-device.

Everything else — the grid, the forms, sync, the migration runner — carries forward unchanged.

---

## Clean-slate directive

**Confirmed 2026-08-22: Code has a green light to wipe all existing data in `essentials.db`, and to treat the rebuild as a genuinely blank slate — as if none of the 19 original tables ever existed.** Mike has the source data elsewhere; nothing here needs to be preserved or worked around, and nothing gets automatically recreated. This removes an entire category of complexity from Phase 1 and changes the plan materially:

- **The 19 existing tables are not migrated, preserved, or automatically rebuilt.** No registration pass, no rebuild script, no scripted replay. The database comes up with only its infra/bookkeeping tables — nothing else. If Mike wants a `domain` table or a `subscription` table again, he creates it through the New Table screen exactly like any table he'd never had before, whenever he wants, with no special status.
- There is therefore **no `is_builtin` concept at all.** Every table, whenever created and whatever it's named, is the same kind of thing. `schema.sql` stays around only as optional reference material — a memory aid if Mike wants to recreate a table's old field list by hand — never read by any code.
- Every field, whenever created, is **TEXT from day one** — no dual-tier "legacy columns keep native SQLite types" caveat, since nothing legacy survives into the rebuild.
- No declared FK constraints anywhere — full uniformity, since every table is created through the identical path (see FK section below).
- `field_metadata` and `table_configs.dart`'s hand-written configs are **deleted outright**, not deprecated-then-retired-later.
- **Lookup table reference data (domain, priority, gender, status, etc.)** only becomes relevant once Mike recreates one of those tables. When he does, its rows come back via CSV import or manual entry — confirmed 2026-08-22, specifically to avoid Code guessing at stale or subtly wrong values from old context.

**Scope of the wipe:** all three copies — `essentials.db` on MIKE-CU, MIKE-12R's copy, and the server's `hub.db` — rebuilt together, in the order the migration system expects (server/hub gets the new schema first, devices pull it fresh). Wiping one copy while another still holds old-scheme data recreates the exact asymmetric-state sync problem this project has already hit twice (see CLAUDE.md, migration bootstrap incidents).

---

## What the code already does (verified by reading it)

| Capability | Where | Phase 1 impact |
|---|---|---|
| Build `TableConfig` with no hand-written Dart | `TableDiscoveryService.buildConfig` | Rewrite source from heuristics → metadata |
| Field-level override layer (label, default, lookup display) | `field_metadata` + `FieldMetadataDao` | Superseded by `field_definitions` |
| `ALTER TABLE ADD COLUMN` from in-app UI | `SchemaEditorService.addColumn` | Extend; route through `migration_log` |
| Identifier injection guard | `assertSafeSqlIdentifier` | Reuse as-is for user-supplied names |
| Reserved column name rejection | `SchemaEditorService._reservedColumnNames` | Reuse as-is |
| Ordered, per-device DDL application with halt-on-failure | `MigrationService.applyPending` | Reuse as-is — this is the sync mechanism |
| Schema-before-data ordering guarantee | `MigrationService.fetchFromServer` (HTTP side-channel) | Reuse as-is — this is why Option A works |
| Timestamp+random id injection on insert | `GenericDao._idDefaultExpression` | Reuse as-is for user tables |
| App-layer FK enforcement (SQLite's own never fires) | `GenericDao.findBlockingReferences` | Rewrite source from `PRAGMA` → metadata |

---

## Decision: schema sync via `migration_log` (Option A) — confirmed

The concurrent-edit scenario (field added on MIKE-CU, data entered on MIKE-LP, field renamed on MIKE-12R) resolves cleanly, and **no locking is required.** Two properties make that true:

**1. Only two DDL operations ever run.** Everything else is metadata.

| User action | Mechanism | DDL? |
|---|---|---|
| Create table | `CREATE TABLE` via `migration_log` | Yes |
| Add field | `ALTER TABLE ADD COLUMN` via `migration_log` | Yes |
| **Permanently delete table** | `DROP TABLE` via `migration_log` | Yes |
| **Permanently delete field** | `ALTER TABLE DROP COLUMN` via `migration_log` | Yes |
| Rename field | `UPDATE field_definitions SET display_name` | **No** |
| Delete field | `UPDATE field_definitions SET is_deleted = 1` | **No** |
| Change format | `UPDATE field_definitions SET format` | **No** |
| Reorder fields | `UPDATE field_definitions SET position` | **No** |
| Rename table | `UPDATE table_definitions SET display_name` | **No** |
| Delete table | `UPDATE table_definitions SET is_deleted = 1` | **No** |

The physical SQLite identifier (`table_name`, `field_name`) is **immutable once created**. Only the `display_name` ever changes. This is the single most important rule in Phase 1 — it eliminates every hard case (`ALTER TABLE RENAME`, table rebuilds, FK repointing, orphaned settings rows in `table_column_settings` keyed on the old name).

The two *routine* DDL operations are purely additive and non-destructive. `ADD COLUMN` fills existing rows with NULL. `CREATE TABLE` produces an empty table. Neither conflicts with concurrent data entry on another device. The two destructive operations are deliberately not routine — see **Two-stage delete** below.

**2. `MigrationService` already guarantees schema-before-data.** `fetchFromServer()` pulls pending `migration_log` rows over plain HTTP and `applyPending()` runs them *before* `SyncService.connect()` opens the websocket. This exists because of a real, reproduced infinite-loop bug (CLAUDE.md, Part D live verification): once any peer applies a migration, its outgoing rows carry the new column, and a device that hasn't applied it can't merge the batch — including the `migration_log` row that would fix it.

That is exactly the failure Option B (CRDT-triggered DDL) would reintroduce. **Option B is rejected**: CRDT merge order within a batch is not guaranteed, so data rows carrying a new column can arrive before the `field_definitions` row that would trigger its creation.

### Two-stage delete

Delete is two distinct operations, not one.

**Stage 1 — Delete (soft).** `is_deleted = 1` on the `table_definitions` / `field_definitions` row. The table or field disappears from the UI everywhere. The physical table/column and all its data stay exactly where they are. No DDL, syncs like any other record change, fully undoable — clear the flag and everything is back.

**Stage 2 — Permanently delete (hard).** A separate, explicit action on an already-soft-deleted table or field. Generates `DROP TABLE "x"` or `ALTER TABLE "x" DROP COLUMN "y"` into `migration_log`, which reaches every device and the server in order like any other migration.

Why two stages rather than one:

- **An accidental click is recoverable.** Deleting a table the user spent months filling should not be one confirmation dialog away from unrecoverable.
- **It makes the hard drop safe to order.** A `DROP TABLE` that reaches a device still holding unsynced rows for that table produces exactly the merge failure the migration ordering fix exists to prevent (`crdt_sync`'s all-or-nothing batch — CLAUDE.md, Part D). Requiring the soft-delete first means the data is tombstoned and propagated before the drop is ever authored. The UI should refuse to offer "Permanently delete" until sync has confirmed the tombstone reached the server.
- **It keeps the database clean.** The user browses `essentials.db` in Letos. Soft-deleted-forever tables would accumulate as visible cruft, and a deleted table's name could never be reused. Stage 2 solves both.

**Implementation notes.** `DROP TABLE` also needs its `table_definitions` / `field_definitions` rows hard-removed, plus its `table_column_settings` / `table_view_settings` rows, in the same migration. `ALTER TABLE DROP COLUMN` requires SQLite 3.35+ and fails on a column that is part of a PRIMARY KEY, UNIQUE constraint, or index — none of which applies to a user-created field (no FKs, no indexes, TEXT storage), but the generator should check and report rather than emit DDL that fails on one device and halts its migration chain.

---

## Critical risks found in the code

### 1. The `sqlparser` bug now applies to every user-created table

**In v1 this was nearly harmless.** `CREATE TABLE` was run by hand in Letos against `essentials.db` — raw sqlite3, no `sqlite_crdt` involvement. The bug only bit on the server's own schema bootstrap and fresh-device bootstrap, and was fixed once by renaming `key` → `setting_key`.

**In v2 it is a live risk on every table a user creates.** `sqlite_crdt` parses `CREATE TABLE` via `sqlparser` to append its bookkeeping columns, and that parser silently drops a bare `key` column *and any PRIMARY KEY constraint referencing it* (CLAUDE.md: minimal reproduction isolated outside the project; migrations/007). Users will name fields whatever they want.

**Mitigation — mandatory:** every generated identifier is double-quoted. `schema.sql` records that *quoting or renaming both fix it*. Quoting is the general fix and costs nothing:

```sql
CREATE TABLE "my_table" (
  "id" INTEGER PRIMARY KEY DEFAULT (...),
  "key" TEXT,
  "notes" TEXT
)
```

`SchemaEditorService.buildDdl` already quotes correctly. The new `CREATE TABLE` generator must do the same, without exception.

**Verification spike run 2026-08-22** (`tool/schema_engine_spike.dart`, scratch db, `sqlite_crdt ^3.0.4`) — confirmed, not assumed:

- **(a) Quoting mitigation holds.** A quoted `"key"` column survives; an unquoted one reproduces the known drop, confirming the bug is still live on this version.
- **(b) CRDT columns append exactly once** on a `CREATE TABLE` that doesn't declare them.
- **(c) Answered, and it's a hard rule, not a preference:** a `CREATE TABLE` that already declares `is_deleted`/`hlc`/`node_id`/`modified` itself does **not** get silently duplicated — `sqlite_crdt`'s rewrite blindly appends its own four regardless, and SQLite rejects the reconstructed statement outright with `duplicate column name: is_deleted`. The whole `CREATE TABLE` fails.
- **(d) `ALTER TABLE ADD COLUMN` confirmed exempt from the rewrite.** A quoted, reserved-ish name (`"order"`) added via `ALTER TABLE` survives — matching `SchemaEditorService`'s existing doc comment that only `CREATE TABLE` goes through the `sqlparser` rewrite path. `addField`'s generator has no CRDT-column collision risk to guard against; the `createTable`-only rule above is the one that matters.

**Rule for `SchemaEditorService.createTable`'s generator: never emit the four CRDT bookkeeping columns.** The generated DDL declares only `id` and the user's own fields, fully quoted. `sqlite_crdt`'s rewrite is solely responsible for appending `is_deleted`/`hlc`/`node_id`/`modified` — predeclaring even one of them doesn't risk a duplicate column, it takes down the entire `CREATE TABLE`, which would fail on every device that applies that migration. Worth a code comment at the generator call site so this isn't silently reintroduced later (e.g. by a future contributor "helpfully" making the CRDT columns explicit for clarity).

### 2. `migration_log.id` is AUTOINCREMENT — single-author assumption breaks

`schema.sql` states the assumption explicitly:

> `id` is real AUTOINCREMENT here — unlike every entity table above, this is centrally authored from one place (schema_admin, MIKE-CU only), not independently written by multiple devices, so the cross-device collision problem that ruled AUTOINCREMENT out elsewhere doesn't apply.

**Phase 1 breaks that assumption.** Any device can create a table, so any device authors `migration_log` rows.

This is not a low-probability race. `AUTOINCREMENT` is not time-based — SQLite assigns `max(existing) + 1`, tracked in `sqlite_sequence`. Two devices that have both synced up to migration 10 will **both deterministically pick 11** for the next migration either one authors. The collision window is the sync interval (seconds to five minutes, or indefinitely if a device is offline), not a microsecond. Because `id` is the primary key, CRDT merges the two rows into one and the losing migration is silently lost — a table that exists on one device and simply never appears on the other, with no error anywhere.

**Fix:** migrate `migration_log.id` to the same timestamp+random scheme as the entity tables:

```sql
id INTEGER PRIMARY KEY DEFAULT (
  CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000 + (abs(random()) % 1000)
)
```

This preserves the `ORDER BY id ASC` semantics — the ids remain time-ordered — while removing the shared-counter collision. Clock skew between devices could theoretically reorder two migrations authored seconds apart on different devices; given that both surviving DDL operations are additive and independent (`CREATE TABLE` for distinct tables, `ADD COLUMN` for distinct columns), reordering is harmless. Document that reasoning rather than leaving it implicit.

This is itself a migration, authored the old way in `schema_admin`, and must land before any in-app table creation ships.

### 3. FK constraints vs. all-TEXT storage

The architecture doc commits to TEXT storage for all user fields. A `link_record` field stores the target's integer `id` in a TEXT column. A real SQLite `REFERENCES` constraint across mismatched affinity is fragile.

**It is also unnecessary.** `GenericDao.delete`'s own doc comment records that SQLite's FK enforcement *never fires* — `sqlite_crdt` rewrites every DELETE into a soft-delete UPDATE, so RESTRICT and CASCADE are already documentary. `findBlockingReferences` is the real enforcement, and it works by scanning `PRAGMA foreign_key_list` across every table.

**Decision: no table declares FK constraints — none, anywhere, ever.** With no `is_builtin` distinction and every table created through the same engine, there is no "some tables keep DDL-level FKs, others don't" split to maintain. One code path, one rule, from day one. Referential integrity is enforced entirely from metadata:

- `findBlockingReferences` queries `field_definitions WHERE format = 'select' AND options->>'mode' = 'linked'` and reads each one's `options.table` — this is the *only* enforcement path, not a fallback alongside `PRAGMA foreign_key_list`.
- A per-field `on_delete` option (`'restrict'` | `'cascade'` | `'ignore'`) in `field_definitions.options` replaces the DDL-level declaration, and is user-settable — which v1 never allowed.

This removes a whole class of problem: `ALTER TABLE ADD COLUMN` with a `REFERENCES` clause is legal in SQLite but constrained (default must be NULL), and adding one to a table with existing rows that would violate it is a trap. Not declaring them sidesteps it entirely.

---

## Metadata schema

Two new tables. Both follow the existing infra-table convention: composite natural primary key (like `field_metadata`, `table_column_settings`), CRDT bookkeeping columns, no AUTOINCREMENT. Natural keys avoid the cross-device id problem entirely — no id to collide.

```sql
-- One row per user-visible table. Supersedes TableDiscoveryService's
-- discoverTableNames() heuristics and the _display_column/_order_by
-- sentinel convention in field_metadata.
CREATE TABLE "table_definitions" (
    "table_name"    TEXT PRIMARY KEY,   -- physical SQLite identifier, IMMUTABLE
    "display_name"  TEXT NOT NULL,      -- user-facing, freely renameable
    "description"   TEXT,
    "icon"          TEXT,
    "display_field" TEXT,               -- chosen explicitly at creation, no heuristic
    "order_by"      TEXT,               -- chosen explicitly at creation, no heuristic
    "position"      INTEGER,
    "created_at"    TEXT NOT NULL,
    "is_deleted"    INTEGER DEFAULT 0,
    "hlc"           TEXT NOT NULL,
    "node_id"       TEXT NOT NULL,
    "modified"      TEXT NOT NULL
);

-- One row per field. Supersedes field_metadata entirely: that table held
-- only the *policy* half (label, default, lookup display column, is_link)
-- and derived the *structural* half from PRAGMA. This holds both.
CREATE TABLE "field_definitions" (
    "table_name"    TEXT NOT NULL,
    "field_name"    TEXT NOT NULL,      -- physical SQLite identifier, IMMUTABLE
    "display_name"  TEXT NOT NULL,      -- user-facing, freely renameable
    "format"        TEXT NOT NULL,      -- 'text' | 'number' | 'date' | 'select' | ...
    "options"       TEXT,               -- JSON: mask, symbol, select source, on_delete, ...
    "default_value" TEXT,
    "required"      INTEGER NOT NULL DEFAULT 0,
    "position"      INTEGER NOT NULL DEFAULT 0,
    "is_deleted"    INTEGER DEFAULT 0,
    "hlc"           TEXT NOT NULL,
    "node_id"       TEXT NOT NULL,
    "modified"      TEXT NOT NULL,
    PRIMARY KEY ("table_name", "field_name")
);
```

Both are added to `infraTables` in `table_discovery_service.dart` so they never appear as nav entries.

`view_definitions`, `script_definitions`, `event_definitions` are Phase 3/5 — not created in Phase 1.

### `field_metadata` retirement

`field_metadata` is not created in the rebuilt schema at all. `FieldMetadataDao` and `FieldMetadataScreen` are deleted, not deprecated. There is nothing to overlay or migrate — the clean-slate rebuild means no prior override data exists to lose.

---

## Starting genuinely empty

There is no rebuild script and nothing gets recreated automatically. Once Phase 1 ships, `essentials.db` contains only its infra/bookkeeping tables — `table_definitions`, `field_definitions`, `table_column_settings`, `table_view_settings`, `app_settings`, `device_settings`, `table_group`, `migration_log`, `migration_status`. Zero business tables, zero rows.

If and when Mike wants `domain`, `subscription`, `journal`, or any of the other 16 back, he creates each one through the New Table screen at whatever pace suits him — same mechanism as any table he'd never had before, no special path, no `is_builtin` flag, no automatic seeding. `schema.sql` remains readable in the repo purely as an optional memory aid for what fields a table used to have; nothing in the app reads it.

**Engine verification therefore isn't "do the 19 tables come back correctly"** — there's no automatic recreation to verify. It's simpler: create one or two tables by hand through the new UI (on both Windows and Android, syncing through the server) and confirm the full loop works — `CREATE TABLE`/`ADD COLUMN` via `migration_log`, metadata rows landing correctly, `SchemaRegistry` rendering the result through the existing grid/form screens unchanged. That's the checkpoint in the build order below.

`subscription`'s computed-column pattern (`subscription_computed` as read source, `yearly_cost`/`next_date`, `computePreview`) is documented here for whenever Mike recreates that table — at that point it's a candidate for a `formula` field (Phase 2) instead of the old hardcoded `table_configs.dart` layering. Not a Phase 1 concern since the table doesn't exist yet.

---

## Code changes

### `TableDiscoveryService` → `SchemaRegistry`

The heuristic derivation methods (`_deriveDisplayColumn`, `_deriveOrderBy`, `_deriveType`, `_deriveLabel`, `_looksLikeLink`, `_singleColumnUniques`, `_lookupDisplayColumnFor`) are **deleted outright**, not moved into a one-time pass — there is no discovery step left to replace. The rebuild script (above) is the only place that ever decided a table's display column, order-by, or field formats, and it decides them explicitly, not heuristically.

`buildConfig(tableName)` becomes: read `table_definitions` + `field_definitions`, produce the same `TableConfig` shape. `PRAGMA table_info` stays, but only as a **validation** step — reconciling metadata against physical reality and surfacing a clear error if they've diverged (a migration that failed on this device, a column that never got created). That check replaces the current `orphan_cleanup_service` behavior with something that reports rather than silently cleans.

### `TableConfig` / `FieldConfig`

`FieldType` (`text, integer, real, boolean, date, dateTime`) is replaced by `format` (String) + `options` (parsed JSON). `LookupConfig` folds into `select` format options. Keep `TableConfig` as the runtime shape the grid and form consume — it stays the interface, only its source changes. That keeps `generic_list_screen.dart` (89 KB) and `generic_form_screen.dart` largely untouched in Phase 1.

### `SchemaEditorService`

- `createTable(...)` — new. Generates fully-quoted `CREATE TABLE` with the timestamp+random `id` default — **declaring only `id` and the user's fields, never the four CRDT columns** (confirmed 2026-08-22 spike: predeclaring them makes the whole statement fail, not just duplicate) — writes it to `migration_log`, and writes the `table_definitions` row.
- `addField(...)` — extends `addColumn`. Always generates `TEXT` (no type picker; the user picks a *format* instead), writes to `migration_log` instead of executing locally, and writes the `field_definitions` row.
- `dropTable(...)` / `dropField(...)` — stage-2 permanent delete. Generates `DROP TABLE` / `ALTER TABLE DROP COLUMN` into `migration_log`, and hard-removes the corresponding `table_definitions` / `field_definitions` and `table_column_settings` / `table_view_settings` rows in the same migration. Refuses unless the target is already soft-deleted.
- Both write the `migration_log` row and the metadata row **in the same `crdt.transaction`**, so a device can never receive metadata for a table whose DDL it never got, or vice versa.
- Name generation: `display_name` → identifier via lowercase + non-alphanumeric → `_`, collision-checked against `sqlite_master` and `table_definitions`, then `assertSafeSqlIdentifier`. Reserved names (`id`, `is_deleted`, `hlc`, `node_id`, `modified`) rejected as they are today.

### `GenericDao.findBlockingReferences`

Rewritten to scan `field_definitions WHERE format = 'select' AND options->>'mode' = 'linked'` (plus `link_record` in Phase 4) instead of `PRAGMA foreign_key_list`, honoring each field's `options.on_delete`. Same signature, same call site in `GenericListScreen`.

### `server/bin/server.dart`

Since the 19 business tables no longer exist as hardcoded DDL anywhere (they're created via `migration_log` like any user table), `schemaStatements` **shrinks** to just the infra/bookkeeping tables: the CRDT-aware settings tables, `migration_log`/`migration_status`, and the two new metadata tables (`table_definitions`, `field_definitions`). The 19 business tables arrive at the fresh hub the same way they arrive at any device — by replaying `migration_log` via `MigrationService.applyPending`. This is a real simplification of the server bootstrap, not just a side effect of the rebuild.

---

## New UI

Three screens, all reachable from Settings and from the nav:

- **New Table** — display name, icon, initial fields. Shows the generated identifier so it's never a surprise.
- **Manage Fields** — per table: reorder (drag), rename (`display_name`), change format, edit format options, set default, mark required, soft-delete. Shows soft-deleted fields in a collapsed "Deleted" section with Restore and Permanently delete. Replaces `FieldMetadataScreen`.
- **Add Field** — name + format + format options. Replaces `AddColumnScreen`'s type picker with a format picker.

`FieldMetadataScreen` and `AddColumnScreen` are superseded and removed once the replacements are verified.

---

## Build order

1. ~~**Verification spike**~~ — **done, 2026-08-22.** Quoting mitigation confirmed; generator rule confirmed (never predeclare the four CRDT columns — see Critical Risks §1).
2. Wipe `essentials.db` (MIKE-CU), MIKE-12R's copy, and the server's `hub.db`. Rebuild each fresh with only the infra/bookkeeping tables, `migration_log`/`migration_status`, `table_definitions`, `field_definitions` — no `field_metadata`, no hand-written business-table DDL, no business tables at all. All three together, server first.
3. `SchemaEditorService.createTable` / `addField`, writing through `migration_log` from the start (no interim single-device version — the AUTOINCREMENT collision risk means there's no safe reason to build a local-only version first).
4. `SchemaRegistry.buildConfig` reads `table_definitions` + `field_definitions` only. `PRAGMA` demoted to validation.
5. **Checkpoint:** create one or two tables by hand through a minimal UI or direct calls, on both Windows and Android, confirm sync through the server, confirm the grid/form screens render them correctly. This is what "the engine works" means now — no 19-table rebuild to validate against.
6. `findBlockingReferences` reads `field_definitions` — single code path, no legacy fallback needed.
7. Full New Table / Manage Fields / Add Field UI screens.
8. Stage-1 soft delete for tables and fields (UI + metadata only, no DDL).
9. Stage-2 `dropTable` / `dropField` through `migration_log`.
10. Whenever Mike chooses: recreate any of the original 19 tables he wants back, through the ordinary New Table screen, then CSV import or manual entry for their reference data. Not a Phase 1 deliverable — just the natural first real usage of the finished engine.

---

## Open questions for implementation

- **`table_column_settings` / `table_view_settings` orphans** — these are keyed on `table_name`. Since identifiers are immutable and tables are soft-deleted, orphans can't be created by rename. Confirm the existing `orphan_cleanup_service` doesn't delete settings for a soft-deleted-but-recoverable table, and that stage-2 permanent delete removes them.
- **Index creation** — no table has FKs anymore, so no FK-driven indexes. Worth adding an index on `select`-formatted fields at creation time, or deferring until a table gets large enough to matter.
- **"Permanently delete" gating signal** — stage 2 should be unavailable until the soft-delete tombstone is confirmed synced. `SyncService` needs to expose something usable for that (last successful sync time vs. the tombstone's `modified`), or the UI falls back to a plain warning.
