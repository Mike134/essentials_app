-- Converts `subscription` from `id INTEGER PRIMARY KEY AUTOINCREMENT` to
-- the millisecond-timestamp + random-suffix `id` scheme `orders`/
-- `order_items` already use (see CLAUDE.md "id convention changed"). Same
-- table-rebuild procedure as migrations/001_journal_id_convention.sql --
-- see that file's header comment for the full rationale.
--
-- `subscription_computed` (a VIEW, `SELECT ... FROM subscription`) needs no
-- change of its own -- SQLite views resolve their referenced table by name
-- at query time, not at CREATE VIEW time, so once `subscription` exists
-- again under the same name with the same columns, the view resumes
-- working automatically. Verify this directly after running (query
-- subscription_computed, confirm yearly_cost/next_date still compute) --
-- don't just assume it from this comment.
--
-- Run with: sqlite3 essentials.db < migrations/003_subscription_id_convention.sql
-- Must run as one script, not statement-by-statement in a GUI tool.

PRAGMA foreign_keys = OFF;
BEGIN TRANSACTION;

CREATE TABLE subscription_new (
    id INTEGER UNIQUE NOT NULL DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
    ),
    name               TEXT NOT NULL UNIQUE,
    domain_id          INTEGER REFERENCES domain(id) ON DELETE RESTRICT,
    used_by_id         INTEGER REFERENCES person(id) ON DELETE RESTRICT,
    class_id           INTEGER REFERENCES class(id) ON DELETE RESTRICT,
    renewal_period_id  INTEGER REFERENCES time_frame(id) ON DELETE RESTRICT,
    cost               REAL,
    payment_method_id  INTEGER REFERENCES account(id) ON DELETE RESTRICT,
    importance_id      INTEGER REFERENCES importance(id) ON DELETE RESTRICT,
    disposition_id     INTEGER REFERENCES disposition(id) ON DELETE RESTRICT,
    start_date         TEXT,
    last_date          TEXT,
    link               TEXT,
    active             INTEGER NOT NULL DEFAULT 1,
    note               TEXT
);

INSERT INTO subscription_new SELECT * FROM subscription;

DROP TABLE subscription;
ALTER TABLE subscription_new RENAME TO subscription;

CREATE INDEX idx_subscription_domain_id ON subscription(domain_id);
CREATE INDEX idx_subscription_used_by_id ON subscription(used_by_id);
CREATE INDEX idx_subscription_class_id ON subscription(class_id);
CREATE INDEX idx_subscription_renewal_period_id ON subscription(renewal_period_id);
CREATE INDEX idx_subscription_payment_method_id ON subscription(payment_method_id);
CREATE INDEX idx_subscription_importance_id ON subscription(importance_id);
CREATE INDEX idx_subscription_disposition_id ON subscription(disposition_id);

-- Defensive check recommended by SQLite's own table-rebuild docs -- any
-- row here means an FK got broken by the rebuild; expect zero rows.
PRAGMA foreign_key_check;

COMMIT;
PRAGMA foreign_keys = ON;
