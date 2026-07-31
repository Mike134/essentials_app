-- Bootstraps the schema-migration system's own tables (migration_log,
-- migration_status) -- see CLAUDE.md "schema_admin -- migration authoring
-- tool" and schema.sql's "SCHEMA MIGRATION SYSTEM" section. Necessarily a
-- one-time manual bootstrap, same as any other "Create a new table"
-- procedure step: schema_admin/the self-apply mechanism can't create
-- these tables themselves -- they don't exist yet to read a migration_log
-- row from. Run once against essentials.db (every device) and hub.db,
-- exactly like any other new table.
--
-- No default needed on hlc/node_id/modified -- both tables start empty,
-- so NOT NULL with zero rows to violate it is fine (same reasoning as
-- every other "Create a new table" bootstrap in this project).

BEGIN TRANSACTION;

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

COMMIT;
