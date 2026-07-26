-- Converts `shipment` from `id INTEGER PRIMARY KEY AUTOINCREMENT` to the
-- millisecond-timestamp + random-suffix `id` scheme `orders`/`order_items`
-- already use (see CLAUDE.md "id convention changed"). Same table-rebuild
-- procedure as migrations/001_journal_id_convention.sql -- see that file's
-- header comment for the full rationale.
--
-- Run with: sqlite3 essentials.db < migrations/002_shipment_id_convention.sql
-- Must run as one script, not statement-by-statement in a GUI tool.

PRAGMA foreign_keys = OFF;
BEGIN TRANSACTION;

CREATE TABLE shipment_new (
    id INTEGER UNIQUE NOT NULL DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
    ),
    supplier_id    INTEGER REFERENCES supplier(id) ON DELETE RESTRICT,
    order_date     TEXT,     -- ISO8601 date: YYYY-MM-DD
    due_date       TEXT,
    received_date  TEXT,
    domain_id      INTEGER REFERENCES domain(id) ON DELETE RESTRICT,
    order_id       TEXT,
    order_link     TEXT,
    shipper_id     INTEGER REFERENCES shipper(id) ON DELETE RESTRICT,
    tracking_id    TEXT,
    tracking_link  TEXT,
    items          TEXT,
    note           TEXT
);

INSERT INTO shipment_new SELECT * FROM shipment;

DROP TABLE shipment;
ALTER TABLE shipment_new RENAME TO shipment;

CREATE INDEX idx_shipment_supplier_id ON shipment(supplier_id);
CREATE INDEX idx_shipment_domain_id ON shipment(domain_id);
CREATE INDEX idx_shipment_shipper_id ON shipment(shipper_id);

-- Defensive check recommended by SQLite's own table-rebuild docs -- any
-- row here means an FK got broken by the rebuild; expect zero rows.
PRAGMA foreign_key_check;

COMMIT;
PRAGMA foreign_keys = ON;
