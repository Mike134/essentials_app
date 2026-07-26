-- Converts `journal` from `id INTEGER PRIMARY KEY AUTOINCREMENT` to the
-- millisecond-timestamp + random-suffix `id` scheme `orders`/`order_items`
-- already use (see CLAUDE.md "id convention changed"). SQLite has no
-- ALTER COLUMN, so this is SQLite's documented table-rebuild procedure:
-- create the new table, copy every row unchanged, drop the old table,
-- rename the new one into place. Existing ids are copied byte-for-byte,
-- NOT renumbered -- only the DEFAULT changes, affecting rows inserted
-- after this runs.
--
-- Run with: sqlite3 essentials.db < migrations/001_journal_id_convention.sql
-- Must run as one script (not statement-by-statement in a GUI tool) --
-- an early step renames the table away before a later step references the
-- old name if split apart.

PRAGMA foreign_keys = OFF;
BEGIN TRANSACTION;

CREATE TABLE journal_new (
    id INTEGER UNIQUE NOT NULL DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
    ),
    entry_time  TEXT NOT NULL,   -- ISO8601 datetime: YYYY-MM-DD HH:MM:SS
    entry       TEXT NOT NULL,
    tag         TEXT,
    status_id   INTEGER REFERENCES status(id) ON DELETE RESTRICT,
    location    TEXT,
    who_id      INTEGER REFERENCES person(id) ON DELETE RESTRICT,
    domain_id   INTEGER REFERENCES domain(id) ON DELETE RESTRICT,
    follow_up   TEXT,
    scheduled   INTEGER NOT NULL DEFAULT 0,
    link        TEXT,
    image       TEXT,
    file        TEXT,
    latitude    REAL,
    longitude   REAL,
    notes       TEXT
);

INSERT INTO journal_new SELECT * FROM journal;

DROP TABLE journal;
ALTER TABLE journal_new RENAME TO journal;

CREATE INDEX idx_journal_status_id ON journal(status_id);
CREATE INDEX idx_journal_who_id ON journal(who_id);
CREATE INDEX idx_journal_domain_id ON journal(domain_id);

-- Defensive check recommended by SQLite's own table-rebuild docs -- any
-- row here means an FK got broken by the rebuild; expect zero rows.
PRAGMA foreign_key_check;

COMMIT;
PRAGMA foreign_keys = ON;
