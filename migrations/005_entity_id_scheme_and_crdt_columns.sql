-- Combined fix for shipment/subscription/journal/orders/order_items:
--
-- 1. id scheme fix: these five tables currently declare
--    `id INTEGER UNIQUE NOT NULL DEFAULT (...)`, deliberately not PRIMARY
--    KEY (see schema.sql's own header comment on why). Confirmed in the
--    "Syncing at the Record Level" Part A prototype that sqlite_crdt's
--    merge() needs a declared PRIMARY KEY to build its conflict-resolution
--    target (`pragma_table_info` pk > 0) -- without one, cross-device
--    merges to these tables throw `ON CONFLICT ()` and are silently
--    dropped. Fix: `id INTEGER PRIMARY KEY DEFAULT (...)` -- same
--    generator expression, still NOT AUTOINCREMENT (so it's just a rowid
--    alias, no shared per-file counter, no collision risk reintroduced).
--
-- 2. sqlite_crdt tracking columns (is_deleted/hlc/node_id/modified), same
--    as 004_crdt_tracking_columns.sql adds to every other real table --
--    done here as part of the same rebuild these tables already need for
--    (1), rather than a separate ALTER pass.
--
-- Existing ids are preserved byte-for-byte (SQLite's documented
-- table-rebuild procedure: no ALTER COLUMN exists, so create the new
-- table, copy every row explicitly, drop the old table, rename the new one
-- into place) -- same procedure 001/002/003 already used for the id-scheme
-- change alone; this extends it to also backfill the CRDT columns in the
-- same pass. Every existing row is adopted into CRDT tracking "as of now"
-- -- there's no real prior modification history to preserve, so every row
-- gets the same literal hlc/modified value used in 004, generated once via
-- the real Hlc/generateNodeId code, not hand-rolled.
--
-- node_id: 2026f76a-33cf-4bd0-8262-ed32113bdc5c
-- hlc/modified: 2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c
--
-- subscription_computed is a VIEW that resolves `subscription` by name at
-- query time (confirmed safe across the drop/rename dance in the original
-- "ID Primary Key Conversion" session) -- no changes needed to it here.
--
-- Run with: sqlite3 essentials.db < migrations/005_entity_id_scheme_and_crdt_columns.sql
-- Must run as one script, not statement-by-statement -- later steps
-- reference table names an earlier step just renamed.

PRAGMA foreign_keys = OFF;
BEGIN TRANSACTION;

-- ===== shipment =====
CREATE TABLE shipment_new (
    id INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
    ),
    supplier_id    INTEGER REFERENCES supplier(id) ON DELETE RESTRICT,
    order_date     TEXT,
    due_date       TEXT,
    received_date  TEXT,
    domain_id      INTEGER REFERENCES domain(id) ON DELETE RESTRICT,
    order_id       TEXT,
    order_link     TEXT,
    shipper_id     INTEGER REFERENCES shipper(id) ON DELETE RESTRICT,
    tracking_id    TEXT,
    tracking_link  TEXT,
    items          TEXT,
    note           TEXT,
    is_deleted     INTEGER DEFAULT 0,
    hlc            TEXT NOT NULL,
    node_id        TEXT NOT NULL,
    modified       TEXT NOT NULL
);

INSERT INTO shipment_new (
    id, supplier_id, order_date, due_date, received_date, domain_id,
    order_id, order_link, shipper_id, tracking_id, tracking_link, items, note,
    is_deleted, hlc, node_id, modified
)
SELECT
    id, supplier_id, order_date, due_date, received_date, domain_id,
    order_id, order_link, shipper_id, tracking_id, tracking_link, items, note,
    0,
    '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c',
    '2026f76a-33cf-4bd0-8262-ed32113bdc5c',
    '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c'
FROM shipment;

DROP TABLE shipment;
ALTER TABLE shipment_new RENAME TO shipment;

CREATE INDEX idx_shipment_supplier_id ON shipment(supplier_id);
CREATE INDEX idx_shipment_domain_id ON shipment(domain_id);
CREATE INDEX idx_shipment_shipper_id ON shipment(shipper_id);

-- ===== subscription =====
CREATE TABLE subscription_new (
    id INTEGER PRIMARY KEY DEFAULT (
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
    note               TEXT,
    is_deleted         INTEGER DEFAULT 0,
    hlc                TEXT NOT NULL,
    node_id            TEXT NOT NULL,
    modified           TEXT NOT NULL
);

INSERT INTO subscription_new (
    id, name, domain_id, used_by_id, class_id, renewal_period_id, cost,
    payment_method_id, importance_id, disposition_id, start_date, last_date,
    link, active, note,
    is_deleted, hlc, node_id, modified
)
SELECT
    id, name, domain_id, used_by_id, class_id, renewal_period_id, cost,
    payment_method_id, importance_id, disposition_id, start_date, last_date,
    link, active, note,
    0,
    '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c',
    '2026f76a-33cf-4bd0-8262-ed32113bdc5c',
    '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c'
FROM subscription;

DROP TABLE subscription;
ALTER TABLE subscription_new RENAME TO subscription;

CREATE INDEX idx_subscription_domain_id ON subscription(domain_id);
CREATE INDEX idx_subscription_used_by_id ON subscription(used_by_id);
CREATE INDEX idx_subscription_class_id ON subscription(class_id);
CREATE INDEX idx_subscription_renewal_period_id ON subscription(renewal_period_id);
CREATE INDEX idx_subscription_payment_method_id ON subscription(payment_method_id);
CREATE INDEX idx_subscription_importance_id ON subscription(importance_id);
CREATE INDEX idx_subscription_disposition_id ON subscription(disposition_id);

-- ===== journal =====
CREATE TABLE journal_new (
    id INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
    ),
    entry_time  TEXT NOT NULL,
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
    notes       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);

INSERT INTO journal_new (
    id, entry_time, entry, tag, status_id, location, who_id, domain_id,
    follow_up, scheduled, link, image, file, latitude, longitude, notes,
    is_deleted, hlc, node_id, modified
)
SELECT
    id, entry_time, entry, tag, status_id, location, who_id, domain_id,
    follow_up, scheduled, link, image, file, latitude, longitude, notes,
    0,
    '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c',
    '2026f76a-33cf-4bd0-8262-ed32113bdc5c',
    '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c'
FROM journal;

DROP TABLE journal;
ALTER TABLE journal_new RENAME TO journal;

CREATE INDEX idx_journal_status_id ON journal(status_id);
CREATE INDEX idx_journal_who_id ON journal(who_id);
CREATE INDEX idx_journal_domain_id ON journal(domain_id);

-- ===== orders =====
CREATE TABLE orders_new (
    id INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
    ),
    order_number TEXT UNIQUE,
    supplier_id  INTEGER REFERENCES supplier(id) ON DELETE RESTRICT,
    is_deleted   INTEGER DEFAULT 0,
    hlc          TEXT NOT NULL,
    node_id      TEXT NOT NULL,
    modified     TEXT NOT NULL
);

INSERT INTO orders_new (
    id, order_number, supplier_id,
    is_deleted, hlc, node_id, modified
)
SELECT
    id, order_number, supplier_id,
    0,
    '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c',
    '2026f76a-33cf-4bd0-8262-ed32113bdc5c',
    '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c'
FROM orders;

DROP TABLE orders;
ALTER TABLE orders_new RENAME TO orders;

-- ===== order_items =====
-- Deliberate exception to this project's RESTRICT-by-default FK
-- convention stays: ON DELETE CASCADE. Note this is now purely documentary
-- at the schema level -- see CLAUDE.md "Syncing at the Record Level" for
-- why sqlite_crdt's soft-delete rewrite means this FK action never
-- actually fires through crdt.execute(), and the app-level compensating
-- pattern (explicit child soft-delete in the same transaction as the
-- parent) that replaces it going forward.
CREATE TABLE order_items_new (
    id INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
    ),
    order_id    INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    description TEXT,
    cost        REAL,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);

INSERT INTO order_items_new (
    id, order_id, description, cost,
    is_deleted, hlc, node_id, modified
)
SELECT
    id, order_id, description, cost,
    0,
    '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c',
    '2026f76a-33cf-4bd0-8262-ed32113bdc5c',
    '2026-07-27T11:12:29.777653Z-0000-2026f76a-33cf-4bd0-8262-ed32113bdc5c'
FROM order_items;

DROP TABLE order_items;
ALTER TABLE order_items_new RENAME TO order_items;

-- Defensive check recommended by SQLite's own table-rebuild docs -- any
-- row here means an FK got broken by the rebuild; expect zero rows.
PRAGMA foreign_key_check;

COMMIT;
PRAGMA foreign_keys = ON;
