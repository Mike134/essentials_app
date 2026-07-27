-- Adds sqlite_crdt's four bookkeeping columns (is_deleted, hlc, node_id,
-- modified) to every real table that ISN'T going through a full rebuild in
-- 005 -- i.e. everything except shipment/subscription/journal/orders/
-- order_items, which get these same columns as part of their id-scheme
-- rebuild instead (see 005_entity_id_scheme_and_crdt_columns.sql).
--
-- Adopts every existing row into CRDT tracking "as of now" -- there's no
-- real prior modification history to preserve, so every row gets the SAME
-- literal hlc/modified value, generated once via the real Hlc/generateNodeId
-- code (not hand-rolled) and pushed for backfill via SQLite's own ADD
-- COLUMN ... DEFAULT mechanism (applies to every existing row automatically,
-- no separate UPDATE needed). node_id below becomes MIKE-CU's real,
-- permanent essentials_app node id going forward -- see CLAUDE.md "Syncing
-- at the Record Level" for where this value is recorded.
--
-- node_id: 2026f76a-33cf-4bd0-8262-ed32113bdc5c
-- hlc/modified: 2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c
--
-- Column shapes match exactly what sqlite_crdt's CrdtTableExecutor appends
-- to a fresh CREATE TABLE (confirmed by reading sql_crdt's source in the
-- Part A prototype): is_deleted is nullable (default 0, no NOT NULL);
-- hlc/node_id/modified are NOT NULL.
--
-- Run with: sqlite3 essentials.db < migrations/004_crdt_tracking_columns.sql

BEGIN TRANSACTION;

-- ===== Lookup tables =====
ALTER TABLE domain ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE domain ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE domain ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE domain ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE priority ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE priority ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE priority ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE priority ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE gender ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE gender ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE gender ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE gender ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE status ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE status ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE status ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE status ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE quality ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE quality ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE quality ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE quality ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE condition ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE condition ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE condition ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE condition ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE unit ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE unit ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE unit ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE unit ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE importance ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE importance ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE importance ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE importance ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE disposition ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE disposition ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE disposition ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE disposition ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE time_frame ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE time_frame ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE time_frame ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE time_frame ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE class ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE class ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE class ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE class ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE category ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE category ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE category ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE category ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE account_type ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE account_type ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE account_type ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE account_type ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

-- ===== Entity tables still on AUTOINCREMENT (not part of the id-scheme fix) =====
ALTER TABLE account ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE account ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE account ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE account ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE supplier ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE supplier ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE supplier ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE supplier ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE shipper ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE shipper ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE shipper ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE shipper ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE person ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE person ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE person ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE person ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

-- ===== sqflite-internal table =====
-- android_metadata is created by sqflite itself (holds only a `locale`
-- column), not app data -- but sqlite_crdt's getTables() picks up every
-- table in sqlite_schema indiscriminately (only sqlite_%-prefixed names
-- are excluded), and SqlCrdt.init()/_getLastModified() queries max(modified)
-- across every table it returns. Without these columns here too, opening
-- via SqliteCrdt.open() throws "no such column: modified" on this table
-- before the app ever gets a chance to run -- caught by actually opening
-- the migrated test copy with SqliteCrdt.open(), not just by inspecting
-- the SQL.
ALTER TABLE android_metadata ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE android_metadata ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE android_metadata ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE android_metadata ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

-- ===== Per-device / settings / metadata infra tables =====
-- These already have composite PRIMARY KEYs (table_name+device_id+... etc.),
-- which sqlite_crdt's merge already needs and already has -- only the
-- bookkeeping columns are new here.
ALTER TABLE table_column_settings ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE table_column_settings ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE table_column_settings ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE table_column_settings ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE table_view_settings ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE table_view_settings ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE table_view_settings ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE table_view_settings ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE app_settings ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE app_settings ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE app_settings ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE app_settings ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE device_settings ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE device_settings ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE device_settings ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE device_settings ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE field_metadata ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE field_metadata ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE field_metadata ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE field_metadata ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

ALTER TABLE table_group ADD COLUMN is_deleted INTEGER DEFAULT 0;
ALTER TABLE table_group ADD COLUMN hlc TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE table_group ADD COLUMN node_id TEXT NOT NULL DEFAULT '2026f76a-33cf-4bd0-8262-ed32113bdc5c';
ALTER TABLE table_group ADD COLUMN modified TEXT NOT NULL DEFAULT '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c';

-- Defensive check -- ADD COLUMN never touches FK relationships, but cheap
-- insurance costs nothing.
PRAGMA foreign_key_check;

COMMIT;
