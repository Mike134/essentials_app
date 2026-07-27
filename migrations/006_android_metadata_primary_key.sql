-- Fixes a real gap found by actually connecting the real, built app to a
-- real crdt_sync server and watching the server's own log, not just by
-- inspecting SQL: android_metadata (sqflite's own internal table, holds
-- just `locale`) got the four CRDT bookkeeping columns from migration 004
-- like every other table, but was never given a PRIMARY KEY -- it never
-- had one to begin with (sqflite creates it as a single bare `locale TEXT`
-- column). Same root cause as migrations/005: sqlite_crdt's merge() needs
-- a declared PRIMARY KEY to build its conflict-resolution target, or the
-- merge throws `ON CONFLICT ()` and is silently dropped (caught internally
-- by crdt_sync and logged, never surfaced to the caller -- confirmed by
-- watching the real server's console output during the first real
-- connection from the real app, not assumed).
--
-- android_metadata always holds exactly one row in practice -- `locale`
-- itself is a fine natural key, no surrogate id needed.
--
-- Run with: sqlite3 essentials.db < migrations/006_android_metadata_primary_key.sql

PRAGMA foreign_keys = OFF;
BEGIN TRANSACTION;

CREATE TABLE android_metadata_new (
    locale     TEXT PRIMARY KEY,
    is_deleted INTEGER DEFAULT 0,
    hlc        TEXT NOT NULL,
    node_id    TEXT NOT NULL,
    modified   TEXT NOT NULL
);

INSERT INTO android_metadata_new (locale, is_deleted, hlc, node_id, modified)
SELECT locale, is_deleted, hlc, node_id, modified
FROM android_metadata;

DROP TABLE android_metadata;
ALTER TABLE android_metadata_new RENAME TO android_metadata;

PRAGMA foreign_key_check;

COMMIT;
PRAGMA foreign_keys = ON;
