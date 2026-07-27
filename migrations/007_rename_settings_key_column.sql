-- Renames app_settings.key -> app_settings.setting_key and
-- device_settings.key -> device_settings.setting_key.
--
-- Found by actually connecting a real built app to a real crdt_sync
-- server and watching the server's own console output, not by inspecting
-- SQL: sqlite_crdt's CREATE TABLE rewrite (via the sqlparser package it
-- depends on) silently drops a bare `key` column entirely -- and any
-- PRIMARY KEY constraint referencing it -- when parsing and reconstructing
-- a CREATE TABLE statement to append its own bookkeeping columns.
-- Reproduced minimally outside this project: `CREATE TABLE t (key TEXT
-- PRIMARY KEY, value TEXT)` run through sqlite_crdt loses the key column
-- entirely; renaming (or quoting) it fixes this. Renamed for durability --
-- essentials.db itself was never affected (it was never built via this
-- code path), but the crdt_sync server's own schema is, and so would any
-- future fresh device bootstrapped from schema.sql the same way -- see
-- that file's own comment on these two tables.
--
-- Uses ALTER TABLE RENAME COLUMN (SQLite 3.25+, well within the bundled
-- 3.50.6) rather than the usual rebuild dance -- no PRIMARY KEY/rowid
-- semantics involved here, a straight rename is sufficient and simpler.
--
-- Run with: sqlite3 essentials.db < migrations/007_rename_settings_key_column.sql

BEGIN TRANSACTION;

ALTER TABLE app_settings RENAME COLUMN key TO setting_key;
ALTER TABLE device_settings RENAME COLUMN key TO setting_key;

PRAGMA foreign_key_check;

COMMIT;
