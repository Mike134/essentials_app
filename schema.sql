-- Essentials.db schema
-- Generated from Essentials.xlsx (Personal domain data model)
-- Convention: every table has a surrogate integer `id`. The original 14
-- lookup tables still use `id INTEGER PRIMARY KEY AUTOINCREMENT`; every
-- entity table (`orders`, `order_items`, `journal`, `shipment`,
-- `subscription`) has since moved to a timestamp+random `id INTEGER
-- PRIMARY KEY DEFAULT (...)` scheme instead -- see CLAUDE.md "id convention
-- changed" for the original rationale, and "Syncing at the Record Level"
-- for why this is PRIMARY KEY (not the original UNIQUE NOT NULL DEFAULT)
-- as of the record-level sync migration. Not AUTOINCREMENT either way, so
-- there's still no shared per-file counter and no cross-device collision
-- risk -- only the SQL keyword wrapping the same generator expression
-- changed, not the generator itself.
-- Name-like columns keep UNIQUE constraints so they still work as natural
-- lookups, but nothing else references them.
-- All FKs default to ON DELETE RESTRICT per project convention.
--
-- Every table below also carries sqlite_crdt's four bookkeeping columns
-- (is_deleted, hlc, node_id, modified), added via migrations/004 and 005
-- ("Syncing at the Record Level" session). Declared here explicitly so this
-- file stays an accurate record of the live schema -- see CLAUDE.md for why
-- these exist (soft-delete CRDT tracking, not real deletes) and the
-- consequence that ON DELETE RESTRICT/CASCADE below are now purely
-- documentary at the SQLite level: they never fire through crdt.execute(),
-- which rewrites every DELETE into a soft-delete UPDATE. Enforcement lives
-- at the application layer now (GenericDao's RESTRICT pre-check, and
-- explicit app-level cascade-delete for order_items).

PRAGMA foreign_keys = ON;

-- ===================== LOOKUP / DOMAIN TABLES =====================

CREATE TABLE domain (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    active      INTEGER NOT NULL DEFAULT 1,
    position    INTEGER,
    color       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);

CREATE TABLE priority (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    active      INTEGER NOT NULL DEFAULT 1,
    position    INTEGER,
    color       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);

CREATE TABLE gender (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    active      INTEGER NOT NULL DEFAULT 1,
    position    INTEGER,
    color       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);

CREATE TABLE status (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    active      INTEGER NOT NULL DEFAULT 1,
    position    INTEGER,
    color       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);

CREATE TABLE quality (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    active      INTEGER NOT NULL DEFAULT 1,
    position    INTEGER,
    color       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);

CREATE TABLE condition (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    active      INTEGER NOT NULL DEFAULT 1,
    position    INTEGER,
    color       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);

CREATE TABLE unit (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL UNIQUE,
    abbreviation TEXT,
    definition   TEXT,
    active       INTEGER NOT NULL DEFAULT 1,
    position     INTEGER,
    color        TEXT,
    is_deleted   INTEGER DEFAULT 0,
    hlc          TEXT NOT NULL,
    node_id      TEXT NOT NULL,
    modified     TEXT NOT NULL
);

CREATE TABLE importance (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    active      INTEGER NOT NULL DEFAULT 1,
    position    INTEGER,
    color       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);

CREATE TABLE disposition (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    active      INTEGER NOT NULL DEFAULT 1,
    position    INTEGER,
    color       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);

-- NOTE: In the workbook, TimeFrame.Unit ('hour','day','month','year') matches
-- Unit.Name exactly (Unit table has hour/day/week/month/year rows at
-- positions 16-20). That's a real FK relationship the flat Excel table
-- didn't enforce -- wiring it up here.
CREATE TABLE time_frame (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,      -- hourly, daily, weekly, biweekly, monthly, yearly
    unit_id     INTEGER NOT NULL REFERENCES unit(id) ON DELETE RESTRICT,
    multiplier  INTEGER NOT NULL,
    description TEXT,
    active      INTEGER NOT NULL DEFAULT 1,
    position    INTEGER,
    color       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);
CREATE INDEX idx_time_frame_unit_id ON time_frame(unit_id);

CREATE TABLE class (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    active      INTEGER NOT NULL DEFAULT 1,
    position    INTEGER,
    color       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);

CREATE TABLE category (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    class_id    INTEGER REFERENCES class(id) ON DELETE RESTRICT,
    description TEXT,
    active      INTEGER NOT NULL DEFAULT 1,
    position    INTEGER,
    color       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);
CREATE INDEX idx_category_class_id ON category(class_id);

CREATE TABLE account_type (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL UNIQUE,
    abbreviation TEXT,
    definition   TEXT,
    active       INTEGER NOT NULL DEFAULT 1,
    position     INTEGER,
    color        TEXT,
    is_deleted   INTEGER DEFAULT 0,
    hlc          TEXT NOT NULL,
    node_id      TEXT NOT NULL,
    modified     TEXT NOT NULL
);

-- ===================== ENTITY TABLES =====================

CREATE TABLE account (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL UNIQUE,
    code            TEXT UNIQUE,      -- e.g. 'CAPONE MC (7072)' -- referenced by subscription.payment_method_id
    institution     TEXT,
    account_type_id INTEGER REFERENCES account_type(id) ON DELETE RESTRICT,
    domain_id       INTEGER REFERENCES domain(id) ON DELETE RESTRICT,
    notes           TEXT,
    active          INTEGER NOT NULL DEFAULT 1,
    position        INTEGER,
    color           TEXT,
    is_deleted      INTEGER DEFAULT 0,
    hlc             TEXT NOT NULL,
    node_id         TEXT NOT NULL,
    modified        TEXT NOT NULL
);
CREATE INDEX idx_account_account_type_id ON account(account_type_id);
CREATE INDEX idx_account_domain_id ON account(domain_id);

CREATE TABLE supplier (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    hyperlink   TEXT,
    active      INTEGER NOT NULL DEFAULT 1,
    position    INTEGER,
    color       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);

CREATE TABLE shipper (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    hyperlink   TEXT,
    active      INTEGER NOT NULL DEFAULT 1,
    position    INTEGER,
    color       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);

CREATE TABLE person (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    gender_id   INTEGER REFERENCES gender(id) ON DELETE RESTRICT,
    active      INTEGER NOT NULL DEFAULT 1,
    position    INTEGER,
    color       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);
CREATE INDEX idx_person_gender_id ON person(gender_id);

-- ===================== TRANSACTIONAL / ONE-TO-MANY TABLES =====================

-- Converted from AUTOINCREMENT to the timestamp+random `id` scheme in the
-- "ID Primary Key Conversion" session -- see CLAUDE.md "id convention
-- changed" for the full rationale and the rebuild script
-- (essentials_app/migrations/002_shipment_id_convention.sql). Existing rows'
-- ids were preserved unchanged; only new rows get this DEFAULT. `id` moved
-- from UNIQUE NOT NULL to PRIMARY KEY in migrations/005 (see file header).
CREATE TABLE shipment (
    id INTEGER PRIMARY KEY DEFAULT (
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
    note           TEXT,
    is_deleted     INTEGER DEFAULT 0,
    hlc            TEXT NOT NULL,
    node_id        TEXT NOT NULL,
    modified       TEXT NOT NULL
);
CREATE INDEX idx_shipment_supplier_id ON shipment(supplier_id);
CREATE INDEX idx_shipment_domain_id ON shipment(domain_id);
CREATE INDEX idx_shipment_shipper_id ON shipment(shipper_id);

-- YearlyCost and NextDate were Excel formulas (EDATE/XLOOKUP-driven). Per
-- Mike's decision, these are NOT stored -- they're computed at query time
-- (via the subscription_computed view below) so they can never go stale
-- relative to cost/start_date/renewal_period.
-- Converted from AUTOINCREMENT to the timestamp+random `id` scheme in the
-- "ID Primary Key Conversion" session -- see CLAUDE.md "id convention
-- changed" for the full rationale and the rebuild script
-- (essentials_app/migrations/003_subscription_id_convention.sql). Existing
-- rows' ids were preserved unchanged; only new rows get this DEFAULT. `id`
-- moved from UNIQUE NOT NULL to PRIMARY KEY in migrations/005.
-- subscription_computed below needed no changes -- it resolves
-- `subscription` by name at query time, not at CREATE VIEW time.
CREATE TABLE subscription (
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
CREATE INDEX idx_subscription_domain_id ON subscription(domain_id);
CREATE INDEX idx_subscription_used_by_id ON subscription(used_by_id);
CREATE INDEX idx_subscription_class_id ON subscription(class_id);
CREATE INDEX idx_subscription_renewal_period_id ON subscription(renewal_period_id);
CREATE INDEX idx_subscription_payment_method_id ON subscription(payment_method_id);
CREATE INDEX idx_subscription_importance_id ON subscription(importance_id);
CREATE INDEX idx_subscription_disposition_id ON subscription(disposition_id);

-- Query-time equivalent of the Excel YearlyCost / NextDate formulas.
-- Scope note: like the original Excel formulas, this is written for the
-- CURRENT use case only -- Monthly/Yearly renewals, where time_frame.multiplier
-- is expressed in months (1 and 12 respectively). If Hourly/Daily/Weekly/
-- Biweekly renewals get activated later, this view needs a unit-aware
-- rewrite (branch on time_frame.unit_id the same way the Excel IF/LET
-- version would have), the same expansion flagged back when the Excel
-- formula was first built.
--
-- Also carrying forward a data note found while building this: the
-- "yearly" row's unit is literally "year" while its multiplier (12) is
-- actually a month count, not a year count -- harmless today since this
-- view never reads unit_id, but worth reconciling before any future
-- unit-aware version reads that column.
CREATE VIEW subscription_computed AS
SELECT
    s.*,
    tf.multiplier AS renewal_multiplier_months,
    ROUND(s.cost * 12.0 / tf.multiplier, 2) AS yearly_cost,
    CASE
        WHEN s.start_date IS NULL OR tf.multiplier IS NULL THEN NULL
        WHEN date(s.start_date) > date('now') THEN s.start_date
        ELSE date(
            s.start_date,
            '+' || (
                (
                    (
                        (CAST(strftime('%Y','now') AS INTEGER) - CAST(strftime('%Y', s.start_date) AS INTEGER)) * 12
                        + (CAST(strftime('%m','now') AS INTEGER) - CAST(strftime('%m', s.start_date) AS INTEGER))
                        - (CASE WHEN CAST(strftime('%d','now') AS INTEGER) < CAST(strftime('%d', s.start_date) AS INTEGER) THEN 1 ELSE 0 END)
                    ) / tf.multiplier + 1
                ) * tf.multiplier
            ) || ' months'
        )
    END AS next_date
FROM subscription s
LEFT JOIN time_frame tf ON tf.id = s.renewal_period_id;

-- Journal.Tag and Journal.Location are free text in the workbook (no matching
-- lookup table exists yet) -- left as TEXT. Journal.Status matches tblStatus
-- exactly, so that one is wired as a real FK.
-- Converted from AUTOINCREMENT to the timestamp+random `id` scheme in the
-- "ID Primary Key Conversion" session -- see CLAUDE.md "id convention
-- changed" for the full rationale and the rebuild script
-- (essentials_app/migrations/001_journal_id_convention.sql). Existing rows'
-- ids were preserved unchanged; only new rows get this DEFAULT. `id` moved
-- from UNIQUE NOT NULL to PRIMARY KEY in migrations/005.
CREATE TABLE journal (
    id INTEGER PRIMARY KEY DEFAULT (
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
    notes       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);
CREATE INDEX idx_journal_status_id ON journal(status_id);
CREATE INDEX idx_journal_who_id ON journal(who_id);
CREATE INDEX idx_journal_domain_id ON journal(domain_id);

-- ===================== PER-DEVICE TABLE VIEW STATE =====================
-- Settings & Persistence Architecture phase (see CLAUDE.md "Real-usage
-- findings"). Column widths/order/sort/filter/frozen/visibility are all
-- per-device by the governing rule -- Mike confirmed sort/filter should NOT
-- be shared either, despite that being the closer call of the set. device_id
-- is the live OS-reported hostname (Windows: Platform.localHostname;
-- Android: Settings.Global.DEVICE_NAME via a platform channel -- see
-- lib/util/device_id.dart), queried at runtime, never hardcoded.
--
-- One row per column per table per device -- deliberately not a JSON blob,
-- so it stays fully inspectable in Letos/DBeaver and generalizes cleanly
-- toward the long-term "dynamically discovered table" direction (see
-- CLAUDE.md) without a schema change specific to that later feature.

CREATE TABLE table_column_settings (
    table_name    TEXT NOT NULL,
    device_id     TEXT NOT NULL,
    column_name   TEXT NOT NULL,
    width         REAL,
    display_order INTEGER,
    visible       INTEGER NOT NULL DEFAULT 1,
    frozen        TEXT,  -- NULL, 'left', or 'right'
    wrap_text     INTEGER NOT NULL DEFAULT 0,
    aggregate     TEXT,  -- NULL, 'sum', 'average', 'min', 'max', or 'count'; see GenericListScreen
    is_deleted    INTEGER DEFAULT 0,
    hlc           TEXT NOT NULL,
    node_id       TEXT NOT NULL,
    modified      TEXT NOT NULL,
    PRIMARY KEY (table_name, device_id, column_name)
);

CREATE TABLE table_view_settings (
    table_name     TEXT NOT NULL,
    device_id      TEXT NOT NULL,
    sort_column    TEXT,
    sort_direction TEXT,  -- 'asc' or 'desc'
    filter_json    TEXT,  -- JSON array of {column,type,value}; see GenericListScreen
    group_column   TEXT,  -- one column at a time, not stacked; see GenericListScreen
    row_color_column TEXT,  -- color/lookup field driving row text color; see GenericListScreen
    is_deleted     INTEGER DEFAULT 0,
    hlc            TEXT NOT NULL,
    node_id        TEXT NOT NULL,
    modified       TEXT NOT NULL,
    PRIMARY KEY (table_name, device_id)
);

-- ===================== APP/DEVICE SETTINGS, FIELD METADATA, GROUPS =======
-- Settings & Persistence Architecture phase, Step 3 (see CLAUDE.md
-- "Real-usage findings") -- schema only this step; first UI consumer
-- (Font/Color/Theme screen, sidebar grouping) comes in later steps.

-- Shared (same value on every device) -- theme_name, font_family,
-- font_color, background_color. Flexible key-value so a new setting never
-- needs a schema migration to add.
--
-- Column is `setting_key`, not the more obvious `key` -- found the hard
-- way, by actually connecting a real built app to a real server and
-- watching the server's own console output: sqlite_crdt's CREATE TABLE
-- rewrite (via the sqlparser package) silently drops a bare `key` column
-- entirely (and any PRIMARY KEY constraint referencing it) when parsing
-- and reconstructing the statement to append its own bookkeeping columns
-- -- confirmed as a minimal, reproducible bug isolated outside this
-- project, not a schema mistake (renaming or quoting the column both fix
-- it; renamed for durability rather than relying on remembering to quote
-- it forever). Only matters for a *fresh* `CREATE TABLE` run through
-- sqlite_crdt (e.g. the crdt_sync server's own schema, or bootstrapping a
-- brand new device from scratch) -- migrations/007 renames it on
-- essentials.db too, purely so this file stays the single schema every
-- copy can be built from without hitting the same landmine later.
CREATE TABLE app_settings (
    setting_key TEXT PRIMARY KEY,
    value       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);

-- Per-device equivalent of app_settings -- currently just font_size (real
-- DPI/screen-size differences between Windows desktop and an Android
-- phone are the one case shared didn't make sense for) and, later, sidebar
-- group collapse/expand state (device-scoped by the same governing rule as
-- table_column_settings/table_view_settings above). `setting_key`, not
-- `key` -- same sqlite_crdt CREATE TABLE bug as app_settings above.
CREATE TABLE device_settings (
    device_id   TEXT NOT NULL,
    setting_key TEXT NOT NULL,
    value       TEXT,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL,
    PRIMARY KEY (device_id, setting_key)
);

-- Field-level *policy* metadata (display label, insert default, which
-- lookup column to show, is_link) -- distinct from TableConfig's
-- *structural* half (field exists, SQL type, FK target), which stays
-- compiled into table_configs.dart for now (see CLAUDE.md "Long-term
-- direction"). A value present here overrides the compiled Dart default;
-- absence falls back to what's hardcoded -- same override pattern as the
-- Theme vs. explicit font/color override model, applied here to fields.
CREATE TABLE field_metadata (
    table_name            TEXT NOT NULL,
    field_name             TEXT NOT NULL,
    display_label          TEXT,
    default_value           TEXT,
    lookup_display_column  TEXT,
    is_link                 INTEGER,
    is_deleted              INTEGER DEFAULT 0,
    hlc                     TEXT NOT NULL,
    node_id                 TEXT NOT NULL,
    modified                TEXT NOT NULL,
    PRIMARY KEY (table_name, field_name)
);

-- Sidebar group membership -- shared, one group per table (single
-- membership). Which groups are currently expanded/collapsed is a
-- separate, per-device concern -- see device_settings above, not stored
-- here.
CREATE TABLE table_group (
    table_name     TEXT PRIMARY KEY,
    group_name     TEXT NOT NULL,
    group_position INTEGER,
    is_deleted     INTEGER DEFAULT 0,
    hlc            TEXT NOT NULL,
    node_id        TEXT NOT NULL,
    modified       TEXT NOT NULL
);

-- ===================== ORDERS / ORDER_ITEMS ==============================
-- "Split-Pane Layout" session (see CLAUDE.md "Parent-child (one-to-many)
-- relationships") -- created directly in essentials.db via Letos before
-- this file was updated to match; added here afterward so schema.sql stays
-- the design-side record of the live schema, per this file's own stated
-- purpose. The app's Table Discovery mechanism needs no entry here to
-- work -- this is documentation, not something the app reads.

-- First tables to use the new `id` convention: a millisecond-timestamp +
-- random-suffix SQL default instead of INTEGER PRIMARY KEY AUTOINCREMENT.
-- Originally declared UNIQUE NOT NULL (deliberately not PRIMARY KEY, to
-- avoid id collisions between Windows and Android inserting new rows
-- offline) -- moved to PRIMARY KEY in migrations/005 for sqlite_crdt
-- compatibility (see that migration's header and CLAUDE.md "Syncing at the
-- Record Level"). Still not AUTOINCREMENT, so the original collision
-- reasoning still holds: no shared per-file counter either way.
-- TableDiscoveryService treats a literal `id` column as the structural
-- surrogate key regardless of this scheme -- see CLAUDE.md "New-table
-- conventions."
CREATE TABLE orders (
    id INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
    ),
    order_number TEXT UNIQUE,  -- added same session, after Mike noticed the
                                -- displayColumn heuristic fell through to
                                -- the bare id without it -- see
                                -- table_discovery_service.dart's UNIQUE-
                                -- column displayColumn heuristic.
    supplier_id  INTEGER REFERENCES supplier(id) ON DELETE RESTRICT,
    is_deleted   INTEGER DEFAULT 0,
    hlc          TEXT NOT NULL,
    node_id      TEXT NOT NULL,
    modified     TEXT NOT NULL
);

-- Deliberate exception to this project's RESTRICT-by-default FK
-- convention: order_items are owned by their order, not merely related to
-- it, so deleting an order should cascade to its items rather than block.
-- See CLAUDE.md "Parent-child (one-to-many) relationships" for the original
-- rationale, and "Syncing at the Record Level" for why ON DELETE CASCADE
-- below is now purely documentary at the SQLite level as of the
-- record-level sync migration -- crdt.execute() rewrites every DELETE into
-- a soft-delete UPDATE, which never fires SQLite's own FK actions.
-- Enforcement is now an explicit app-level cascade (soft-delete order_items
-- in the same transaction as the parent order) rather than relying on this
-- declaration.
CREATE TABLE order_items (
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

-- ===================== SCHEMA MIGRATION SYSTEM =====================
-- schema_admin (essentials_app/schema_admin/, its own separate Flutter
-- project) writes migration_log rows -- it never executes DDL itself.
-- essentials_app and server/ each independently self-apply pending
-- entries on launch/reconnect and record the outcome per device in
-- migration_status. See CLAUDE.md "schema_admin -- migration authoring
-- tool" for the full design, and "Repo move: CLAUDE.md/schema.sql" for
-- why this superseded the earlier "no schema-change auto-propagation"
-- decision.
--
-- id is real AUTOINCREMENT here -- unlike every entity table above, this
-- is centrally authored from one place (schema_admin, MIKE-CU only), not
-- independently written by multiple devices, so the cross-device
-- collision problem that ruled AUTOINCREMENT out elsewhere doesn't apply.
CREATE TABLE migration_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    sql_text    TEXT NOT NULL,
    description TEXT,
    created_at  TEXT NOT NULL,
    is_deleted  INTEGER DEFAULT 0,
    hlc         TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    modified    TEXT NOT NULL
);

-- outcome: 'succeeded' | 'failed' -- absence of a row for a given
-- (migration_id, device_id) means "not yet reported," a third, genuinely
-- distinct state from either -- never conflate it with 'failed'.
CREATE TABLE migration_status (
    migration_id  INTEGER NOT NULL REFERENCES migration_log(id),
    device_id     TEXT NOT NULL,
    outcome       TEXT NOT NULL,
    error_message TEXT,
    attempted_at  TEXT,
    is_deleted    INTEGER DEFAULT 0,
    hlc           TEXT NOT NULL,
    node_id       TEXT NOT NULL,
    modified      TEXT NOT NULL,
    PRIMARY KEY (migration_id, device_id)
);
