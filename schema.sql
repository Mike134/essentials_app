-- essentials.db schema -- Essentials v2 (dynamic schema engine)
--
-- WHAT THIS FILE IS NOW
-- ---------------------
-- The design-side record of the live schema, same role it has always had --
-- but that schema is now *ten infra/bookkeeping tables and nothing else*.
--
-- Business tables (what used to be `domain`, `person`, `subscription`,
-- `journal`, `orders`, and the rest) are no longer declared anywhere in
-- code or in this file. They are created at runtime by the user through
-- the app's own New Table UI, recorded as rows in `table_definitions` /
-- `field_definitions`, and propagated to every device and the sync hub as
-- `migration_log` entries. See claude/essentials-v2-phase1-design.md.
--
-- The 19 business tables this file used to declare were deliberately
-- dropped in the v2 clean-slate rebuild (2026-08-22) and are NOT recreated
-- automatically. Their old DDL remains in git history if it's ever useful
-- as a reference while recreating one by hand.
--
-- HOW A FRESH COPY IS CREATED
-- ---------------------------
-- Do NOT hand-run these statements in Letos/DBeaver against a new file.
-- Use `dart run tool/bootstrap_fresh_db.dart --out <path>` instead, which
-- runs this exact statement list through `SqliteCrdt.open()` so sqlite_crdt
-- performs its CREATE TABLE rewrite. That rewrite is what appends the four
-- bookkeeping columns; a hand-run copy would be missing them and could
-- never sync. `server/bin/server.dart`'s `schemaStatements` holds a
-- byte-identical copy for bootstrapping `hub.db` (separate Dart package,
-- can't share a file -- same duplication convention as
-- `safeChangesetBuilder` and `splitSqlStatements`).
--
-- CRDT BOOKKEEPING COLUMNS -- NOT DECLARED HERE, DELIBERATELY
-- -----------------------------------------------------------
-- Every table below also carries sqlite_crdt's four bookkeeping columns at
-- runtime:
--
--     is_deleted INTEGER DEFAULT 0,
--     hlc        TEXT NOT NULL,
--     node_id    TEXT NOT NULL,
--     modified   TEXT NOT NULL
--
-- Unlike the v1 version of this file, they are NOT written out below.
-- Verified live 2026-08-22 (tool/schema_engine_spike.dart, sqlite_crdt
-- ^3.0.4): sqlite_crdt's CREATE TABLE rewrite appends its own four columns
-- without checking whether the statement already declares them. Declaring
-- even one here does not produce a duplicate column -- SQLite rejects the
-- reconstructed statement outright ("duplicate column name: is_deleted")
-- and the entire CREATE TABLE fails. So this file declares only real
-- columns and lets the rewrite do the rest.
--
-- Consequence carried over from v1: all DELETEs are soft-deletes (rewritten
-- by crdt.execute() into UPDATEs), so SQLite's own FK actions never fire.
-- v2 goes further -- no table declares FK constraints at all. Referential
-- integrity is enforced entirely from `field_definitions` metadata, via
-- GenericDao.findBlockingReferences and each link field's `on_delete`
-- option. The one REFERENCES clause below (migration_status -> migration_log)
-- is documentary only, same as v1's were.
--
-- QUOTING
-- -------
-- Every identifier is double-quoted. The same spike confirmed the known
-- `sqlparser` bug is still live on this version: a bare `key` column is
-- silently dropped from the reconstructed table, along with any PRIMARY KEY
-- constraint referencing it. Quoting is a complete mitigation and costs
-- nothing. `app_settings`/`device_settings` also keep the `setting_key`
-- name from migrations/007 rather than reverting to `key`, so correctness
-- doesn't depend on remembering to quote forever.

PRAGMA foreign_keys = ON;

-- ===================== PLATFORM =====================

-- sqflite_common_ffi's own internal table. Not part of this app's design,
-- but Android's sqflite creates it locally, and the sync layer doesn't
-- distinguish business tables from anything else -- it tries to merge
-- whatever changesets a peer sends, for every table name mentioned.
-- Without a structural counterpart on every peer, merging this table's
-- changeset fails (found live against the real server, not assumed).
-- `locale` is a real PRIMARY KEY, not bare -- per migrations/006.
CREATE TABLE "android_metadata" (
    "locale" TEXT PRIMARY KEY
);

-- ===================== DYNAMIC SCHEMA METADATA =====================
-- The heart of the v2 engine. These two tables are what replaced
-- `table_configs.dart`'s hand-written Dart configs, `field_metadata`, and
-- TableDiscoveryService's introspection heuristics.

-- One row per user-visible table.
--
-- `table_name` is the physical SQLite identifier and is IMMUTABLE once
-- created -- only `display_name` ever changes. That single rule is what
-- makes rename, reorder, format change, and delete pure metadata
-- operations with zero DDL, and it's why `table_column_settings` /
-- `table_view_settings` rows (keyed on `table_name`) can never be orphaned
-- by a rename.
--
-- `display_field` and `order_by` are chosen explicitly at creation time,
-- not derived -- v1's _deriveDisplayColumn/_deriveOrderBy heuristics are
-- gone entirely, since there is no longer a discovery step to feed them.
-- `calendar_field` -- Essentials v2 Phase 3, build order step 5 -- a new
-- per-table setting, same "chosen explicitly, not derived" spirit as
-- `display_field`/`order_by` above, added later via `migration_log`
-- (`ALTER TABLE ... ADD COLUMN`, same DDL kind SchemaEditorService already
-- issues for user-added fields -- see tool/add_calendar_field_column.dart).
-- JSON, one of two shapes (see lib/util/calendar_field.dart):
--   {"mode": "single", "field": "due_date"}
--   {"mode": "range", "start_field": "trip_start", "end_field": "trip_end"}
-- NULL means "never explicitly set" -- the Calendar view falls back to the
-- first date/dateTime-format field by position, single mode, computed at
-- read time rather than backfilled into every existing row.
CREATE TABLE "table_definitions" (
    "table_name"     TEXT PRIMARY KEY,
    "display_name"   TEXT NOT NULL,
    "description"    TEXT,
    "icon"           TEXT,
    "display_field"  TEXT,
    "order_by"       TEXT,
    "position"       INTEGER,
    "created_at"     TEXT NOT NULL,
    "calendar_field" TEXT
);

-- One row per field. Supersedes v1's `field_metadata` entirely: that table
-- held only the *policy* half (display label, insert default, lookup
-- display column, is_link) and derived the *structural* half from PRAGMA
-- introspection. This holds both, so `field_metadata` no longer exists.
--
-- `format` is a presentation and input hint, NEVER a storage constraint.
-- Every user-created field's physical column is TEXT, always. The format
-- decides how a value is displayed and which input widget is offered; a
-- value that doesn't match its format displays as-is rather than erroring
-- (the Excel model -- see claude/essentials-v2-architecture.md). Changing a
-- field's format is therefore a single UPDATE here, with no DDL and no
-- data migration.
--
-- `options` is JSON, shape depending on `format` -- e.g. number mask and
-- prefix/suffix, currency symbol, date mask, select source table and
-- display field, link `on_delete` behavior, rating max.
--
-- `field_name` is the physical column identifier and is IMMUTABLE, same
-- rule as `table_name` above.
CREATE TABLE "field_definitions" (
    "table_name"    TEXT NOT NULL,
    "field_name"    TEXT NOT NULL,
    "display_name"  TEXT NOT NULL,
    "format"        TEXT NOT NULL,
    "options"       TEXT,
    "default_value" TEXT,
    "required"      INTEGER NOT NULL DEFAULT 0,
    "position"      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY ("table_name", "field_name")
);

-- ===================== PER-DEVICE TABLE VIEW STATE =====================
-- Column widths/order/sort/filter/frozen/visibility are all per-device by
-- the governing rule (see CLAUDE.md "Real-usage findings") -- `device_id`
-- is the live OS-reported hostname, queried at runtime, never hardcoded.
--
-- One row per column per table per device -- deliberately not a JSON blob,
-- so it stays inspectable in Letos/DBeaver. That per-row shape was chosen
-- in v1 specifically to generalize toward dynamically-created tables
-- without a schema change; v2 is that payoff -- a user-created table's
-- settings accumulate here through the same mechanism, no change needed.

CREATE TABLE "table_column_settings" (
    "table_name"    TEXT NOT NULL,
    "device_id"     TEXT NOT NULL,
    "column_name"   TEXT NOT NULL,
    "width"         REAL,
    "display_order" INTEGER,
    "visible"       INTEGER NOT NULL DEFAULT 1,
    "frozen"        TEXT,   -- NULL, 'left', or 'right'
    "wrap_text"     INTEGER NOT NULL DEFAULT 0,
    "aggregate"     TEXT,   -- NULL, 'sum', 'average', 'min', 'max', or 'count'
    PRIMARY KEY ("table_name", "device_id", "column_name")
);

CREATE TABLE "table_view_settings" (
    "table_name"       TEXT NOT NULL,
    "device_id"        TEXT NOT NULL,
    "sort_column"      TEXT,
    "sort_direction"   TEXT,   -- 'asc' or 'desc'
    "filter_json"      TEXT,   -- JSON array of {column,type,value}
    "group_column"     TEXT,   -- one column at a time, not stacked
    "row_color_column" TEXT,   -- color/lookup field driving row text color
    PRIMARY KEY ("table_name", "device_id")
);

-- ===================== APP / DEVICE SETTINGS, GROUPS =====================

-- Shared (same value on every device) -- theme, font family, font color,
-- background color. Flexible key-value so a new setting never needs a
-- schema migration.
--
-- Column is `setting_key`, not the more obvious `key` -- migrations/007
-- renamed it after a real `sqlparser` bug was isolated: a bare `key` column
-- is silently dropped by sqlite_crdt's CREATE TABLE rewrite, along with any
-- PRIMARY KEY constraint referencing it. Quoting also fixes it (and
-- everything here is quoted now), but the rename stands so this can never
-- depend on remembering to quote.
CREATE TABLE "app_settings" (
    "setting_key" TEXT PRIMARY KEY,
    "value"       TEXT
);

-- Per-device equivalent of app_settings -- font size (real DPI differences
-- between a Windows desktop and a phone), sidebar group collapse state.
CREATE TABLE "device_settings" (
    "device_id"   TEXT NOT NULL,
    "setting_key" TEXT NOT NULL,
    "value"       TEXT,
    PRIMARY KEY ("device_id", "setting_key")
);

-- Sidebar group membership -- shared, one group per table. Which groups are
-- expanded/collapsed is per-device and lives in `device_settings`.
CREATE TABLE "table_group" (
    "table_name"     TEXT PRIMARY KEY,
    "group_name"     TEXT NOT NULL,
    "group_position" INTEGER
);

-- ===================== VIEWS (Essentials v2 Phase 3) =====================
-- Saved List/Kanban (per-table) and Calendar (aggregate) views -- shared/
-- synced, same bucket as table_definitions/field_definitions, NOT per-device
-- like table_column_settings/table_view_settings above. See
-- claude/essentials-v2-phase3-design.md, "Data model".
--
-- `table_name` is nullable: NULL only for the one `view_type = 'calendar'`
-- row (an aggregate surface overlaying multiple tables' own date fields, not
-- scoped to a single table -- see that doc's "Confirmed decisions"). Every
-- `list`/`kanban` row always sets it.
--
-- `view_id` is the timestamp+random scheme, not AUTOINCREMENT -- same
-- collision-avoidance reasoning as `migration_log.id`: any device can create
-- a view, so two devices creating one in the same sync window must not
-- collide on a shared counter.
--
-- No FOREIGN KEY to table_definitions.table_name, same reasoning as every
-- other table in this schema (see the header above -- sqlite_crdt's
-- soft-delete rewrite means SQLite's own FK actions never fire regardless).
-- A table delete is expected to cascade-soft-delete its own view_definitions
-- rows at the app layer, mirroring the field_definitions cascade
-- SchemaMetadataDao.softDeleteTable already does.
--
-- `config` is JSON, shape keyed by `view_type` -- see the design doc for the
-- `list`/`kanban`/`calendar` shapes. Bootstrapped once, out-of-band, by
-- tool/add_view_definitions_table.dart (same reasoning as table_definitions/
-- field_definitions' own original bootstrap -- the migration_log mechanism
-- that self-applies everything else can't create the table it depends on to
-- record what to apply). MUST be kept identical to server/bin/server.dart's
-- schemaStatements / tool/bootstrap_fresh_db.dart's infraSchemaStatements
-- for a from-scratch rebuild.
CREATE TABLE "view_definitions" (
    "view_id"      INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
    ),
    "table_name"   TEXT,
    "view_type"    TEXT NOT NULL,
    "display_name" TEXT NOT NULL,
    "position"     INTEGER,
    "config"       TEXT,
    "created_at"   TEXT NOT NULL
);

-- ===================== SCHEMA MIGRATION SYSTEM =====================
-- Every DDL operation in v2 goes through here: CREATE TABLE and ALTER TABLE
-- ADD COLUMN routinely, DROP TABLE and ALTER TABLE DROP COLUMN for stage-2
-- permanent deletes. essentials_app and server/ each independently
-- self-apply pending entries in strict `id` order on launch/reconnect, and
-- record the per-device outcome in `migration_status`. A failed migration
-- halts subsequent ones on that device until retracted via `is_deleted`.
--
-- `id` is the timestamp+random scheme, NOT AUTOINCREMENT -- changed in v2.
-- v1's AUTOINCREMENT was safe only because migrations were authored from
-- exactly one place (schema_admin, MIKE-CU only). v2 breaks that: any device
-- can create a table, so any device authors rows here. AUTOINCREMENT is
-- max(existing)+1, so two devices both synced through migration N will BOTH
-- deterministically pick N+1 -- and since `id` is the primary key, CRDT
-- merges the two rows into one and a migration is silently lost. Not a
-- narrow race: the window is the entire sync interval, or indefinite while a
-- device is offline. The timestamp+random scheme keeps `ORDER BY id ASC`
-- meaningfully time-ordered while removing the shared counter. Clock skew
-- could reorder two migrations authored seconds apart on different devices;
-- harmless, because the routine DDL operations are additive and independent
-- (CREATE TABLE for distinct tables, ADD COLUMN for distinct columns).
CREATE TABLE "migration_log" (
    "id" INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
    ),
    "sql_text"    TEXT NOT NULL,
    "description" TEXT,
    "created_at"  TEXT NOT NULL
);

-- outcome: 'succeeded' | 'failed'. Absence of a row for a given
-- (migration_id, device_id) means "not yet reported" -- a third, genuinely
-- distinct state. Never conflate it with 'failed'.
--
-- The REFERENCES clause is documentary only, like every FK in v1 was --
-- sqlite_crdt's soft-delete rewrite means SQLite's own FK actions never
-- fire. It's the only REFERENCES clause left in the schema.
CREATE TABLE "migration_status" (
    "migration_id"  INTEGER NOT NULL REFERENCES "migration_log"("id"),
    "device_id"     TEXT NOT NULL,
    "outcome"       TEXT NOT NULL,
    "error_message" TEXT,
    "attempted_at"  TEXT,
    PRIMARY KEY ("migration_id", "device_id")
);
