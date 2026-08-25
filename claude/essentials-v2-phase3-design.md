> **Source of truth: this repo file.** No claude.ai Project mirror is kept — Claude Code reads this directly; a claude.ai/Cowork session reads it live via the desktop-app device bridge when connected. See `claude/project-overview.md` for the file index.

---

# Essentials v2 — Phase 3: View Types

**Session date:** 2026-08-25
**Status:** Design, grounded in a read of the live codebase (`schema.sql`, `lib/db/table_view_settings_dao.dart`, `lib/db/schema_metadata_dao.dart`, `lib/models/table_config.dart`, `lib/screens/home_shell.dart`, `lib/screens/generic_list_screen.dart`, `lib/screens/manage_tables_screen.dart`) — same discipline every prior phase followed. **Not yet handed to Claude Code.** The architecture doc's Phase 3 entry (`claude/essentials-v2-architecture.md`) had List/Calendar/Kanban's *product* shape confirmed 2026-08-24 but explicitly flagged the view-management UI and `view_definitions.config` JSON shape as undesigned; this doc is that missing pass.
**Companion docs:** `claude/essentials-v2-architecture.md` ("View Types (detail)" table and the Phase 3 roadmap section — this doc doesn't repeat the product-level decisions made there, only grounds them against real code and fills the implementation gap), `claude/essentials-v2-phase1-design.md` (`table_definitions`/`field_definitions` shape, the `migration_log` self-apply pipeline this reuses for `view_definitions`' own creation), `claude/essentials-v2-phase6-design.md` (the most recent phase design, same format followed here)

---

## Confirmed decisions (2026-08-25, before handoff to Claude Code)

- **Grid stays exactly as it is today — not migrated into `view_definitions`.** The architecture doc's View Types table calls Grid "existing," and Phase 3's own scope list (List, Calendar, Kanban, view-management UI) never says "convert Grid." `GenericListScreen` plus `table_column_settings`/`table_view_settings` (per-device sort/filter/group/column-width state, per `lib/db/table_view_settings_dao.dart`) is working code with real usage behind it; folding it into a new shared-config system for no functional gain is exactly the kind of risk this project avoids elsewhere (Phase 6 was deliberately designed independent of Phase 4's completion for the same reason). Every table gets an **implicit** Grid view — first in the view switcher, always present, not a row in `view_definitions`, not renameable or deletable in this phase.
- **List and Kanban are per-table views; Calendar is table-agnostic.** List/Kanban rows in `view_definitions` belong to exactly one `table_name`, same as a table's own fields. Calendar does not — the architecture doc is explicit that it's "one calendar surface" overlaying toggle-able tables, not a per-table view. This forces `view_definitions.table_name` to be nullable (NULL = aggregate view, valid only for `view_type = 'calendar'`) — see "Data model" below. Only one calendar view is in scope for this phase (matches "one calendar surface," not a multi-calendar system); the schema doesn't prevent a second one later, but the UI won't offer creating one.
- **View config is shared (synced), not per-device — except column widths, which stay per-device.** This matches the architecture doc's "Per-device column widths; shared filter/sort" line directly. A named List/Calendar/Kanban view is a saved configuration Mike would expect to look identical on MIKE-CU and MIKE-12R, the same way `table_definitions`/`field_definitions` are shared. The one already-built exception is Grid's own column widths (`table_column_settings`, untouched, per-device) — new view types don't introduce column widths at all, so this exception doesn't extend to them.
- **Per-group collapse state (List view) is per-device, ephemeral, and unpersisted-by-default.** Mirrors the existing convention documented directly in `schema.sql`: "Which groups are expanded/collapsed is per-device and lives in `device_settings`." Same mechanism reused here, keyed per view rather than per sidebar table-group. The Expand-all/Collapse-all control added to the architecture doc yesterday (2026-08-25) is a bulk write against this same per-device state — confirmed, no new schema needed for it beyond what List view already requires.
- **`calendar_field` lives on `table_definitions`, not inside any view's config** — per the architecture doc's own text ("a new per-table setting, alongside `table_definitions`'s existing `display_field`/`order_by`"). This is a real schema change (`ALTER TABLE table_definitions ADD COLUMN calendar_field TEXT`) via the standard `migration_log` pipeline, not something `view_definitions.config` carries. Confirmed here because it was easy to misread the architecture doc's phrasing as "part of the calendar view's config" — it explicitly is not.

---

## What the code already does today (verified by reading it)

| Capability | Where | Relevance |
|---|---|---|
| One `TableConfig` per table drives one generic screen | `lib/models/table_config.dart`, instantiated per-table by `SchemaRegistry.buildConfig` (referenced, not yet re-read this session), consumed by `GenericListScreen` | Confirms there is currently exactly **one** screen class per table and **no view-switching concept anywhere in the codebase** — `HomeShell.build` (`lib/screens/home_shell.dart` line ~490) picks one `TableConfig` and instantiates exactly one `GenericListScreen`. A view switcher is new UI surface, not an extension of something partially built. |
| `GenericListScreen` owns its own `Scaffold`/`AppBar`/`drawer` | `lib/screens/generic_list_screen.dart` line ~1739 (`return Scaffold(appBar: AppBar(...), drawer: widget.drawer, ...)`) | Confirms each per-table screen is a fully self-contained top-level `Scaffold`, not a body swapped inside a shared chrome. New List/Calendar/Kanban screens should follow the identical contract (`config`, `drawer` constructor params; own `Scaffold`) so `HomeShell` can treat all four screen types interchangeably — see "Nav integration" below. |
| Grid's sort/filter/group is per-device today | `table_view_settings` (`schema.sql`), `TableViewSettingsDao.loadViewSettings`/`saveViewSettings` (`lib/db/table_view_settings_dao.dart`) | This is the thing the "shared filter/sort" decision above deliberately does **not** touch — Grid keeps its existing per-device `ViewSetting`/`ColumnSetting` shape unchanged. New view types get their own, separate, shared storage (`view_definitions`), not a retrofit of this DAO. |
| `select`-format inline fields already carry ordered options | `FieldConfig.inlineOptions` / `InlineOption` (`lib/models/table_config.dart` line ~85, ~204) | This is exactly the field shape Kanban's "group field" needs (architecture doc: "one `select`-format field; its configured options, in their already-set order... become the columns") — no new field-metadata concept required, Kanban's config just stores which existing field name to use. |
| `FieldType.date`/`FieldType.dateTime` already exist and are stored as plain ISO8601 TEXT | `lib/models/table_config.dart` line ~8 | Confirms Calendar's date-field requirement (single date, or start/end range) can be satisfied by referencing existing field names — no new field type needed, `calendar_field`'s JSON just names which existing date/datetime field(s) apply. |
| Shared vs. per-device metadata pattern, and the `migration_log` DDL pipeline, both already established | `schema.sql` (`table_definitions`/`field_definitions` shared; `table_column_settings`/`table_view_settings`/`device_settings` per-device), `SchemaMetadataDao` (`lib/db/schema_metadata_dao.dart`, `updateTable`/`softDeleteTable`/`restoreTable` methods) | `view_definitions` slots into the same shared bucket, using the same soft-delete/restore CRUD shape `SchemaMetadataDao` already establishes for tables and fields — a new `ViewDefinitionsDao` should read as a sibling of that class, not a novel pattern. |
| Manage-X screens (create/rename/delete, reorder) already have an established UI shape | `lib/screens/manage_tables_screen.dart` | The View-management UI (create/rename/delete views per table) should follow this screen's existing interaction pattern rather than inventing a new one — same list-with-drag-reorder-and-context-menu shape, scoped to one table's views instead of all tables. |

---

## Data model

### `view_definitions` — new shared infra table

```sql
CREATE TABLE "view_definitions" (
    "view_id"      INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
    ),
    "table_name"   TEXT,             -- NULL only for view_type = 'calendar' (aggregate, table-agnostic)
    "view_type"    TEXT NOT NULL,    -- 'list' | 'calendar' | 'kanban' (Grid is implicit, never a row here)
    "display_name" TEXT NOT NULL,
    "position"     INTEGER,
    "config"       TEXT,             -- JSON, shape keyed by view_type -- see below
    "created_at"   TEXT NOT NULL
);
```

Timestamp+random `view_id`, not `AUTOINCREMENT` — identical reasoning to `migration_log`'s own comment in `schema.sql`: any device can create a view (same as any device can create a table), so two devices creating a view in the same sync window must not collide on a shared counter. `table_name` is nullable specifically for the Calendar case above; every List/Kanban row always sets it. No `FOREIGN KEY` to `table_definitions.table_name` for the same reason every other table in this schema skips real FK constraints — `sqlite_crdt`'s soft-delete rewrite means SQLite's own FK actions never fire regardless (see `schema.sql`'s own note on this), so referential integrity is enforced at the app layer (a table delete should cascade-soft-delete its `view_definitions` rows, mirroring the existing `field_definitions` cascade `SchemaMetadataDao.softDeleteTable` should already be doing — confirm that behavior when this is built, don't assume).

Created via a single `migration_log`-authored `CREATE TABLE`, the exact same mechanism Phase 6 used for `search_index` and Phase 1 established generally — self-applies on every device via `MigrationService.applyPending`, no manual per-device SQL, no hand-editing `server/bin/server.dart`'s `schemaStatements` needed *if* the table should exist on the sync hub too. Unlike `search_index` (deliberately never synced — client-only, reconstructible), `view_definitions` **is** shared/synced data the same as `table_definitions`, so — unlike Phase 6 — this one *does* need a `server.dart` `schemaStatements` entry, since the hub's `hub.db` needs the physical table to merge changesets against it.

### `table_definitions.calendar_field` — new column, per-table setting

```sql
ALTER TABLE "table_definitions" ADD COLUMN "calendar_field" TEXT;
```

JSON, two shapes per the architecture doc's two modes:

```json
{"mode": "single", "field": "due_date"}
{"mode": "range", "start_field": "trip_start", "end_field": "trip_end"}
```

`NULL` (never explicitly set) means "defaults to the first date-format field by position, single mode" — computed at read time by whatever service resolves it, not backfilled into every existing table's row. Also via `migration_log` (`ALTER TABLE ... ADD COLUMN`), the same DDL kind `schema_editor_service.dart` already issues for user-added fields — no new DDL pattern needed, just a second `ALTER` on an existing infra table instead of a business table.

### Per-view-type `config` JSON shapes

**`list`** — directly encodes the architecture doc's confirmed List config surface:

```json
{
  "primary_field": "title",
  "primary_sort_dir": "asc",
  "secondary_field": "created_at",
  "secondary_sort_dir": "desc",
  "extra_line2_fields": ["owner", "status"],
  "grouped": true
}
```

**`kanban`** — same two-tier primary/secondary model as List, plus the one required group field:

```json
{
  "group_field": "status",
  "primary_field": "title",
  "primary_sort_dir": "asc",
  "secondary_field": "due_date",
  "secondary_sort_dir": "asc",
  "extra_fields": ["assignee"]
}
```

**`calendar`** — the one row (`table_name IS NULL`) holds only which tables currently contribute; per-table specifics (`calendar_field`, color) live on `table_definitions` itself, not here:

```json
{"table_ids": ["orders", "subscription", "journal"]}
```

Granularity (Day/Week/Month) is view *state*, not view *config* in the shared sense — it's closer to "which day am I looking at right now," the same kind of thing `_selectedTableName` is: transient UI state, not worth syncing or even persisting past the session unless real usage says otherwise. Left out of `config` deliberately; revisit only if Mike asks for it to be remembered.

### Per-device state — no new tables, existing `device_settings` key-value pattern reused

- **Which view is active per table** — `device_settings` key `selected_view:{table_name}`, value = the `view_id` (or the literal string `grid` for the implicit default). Same reasoning HomeShell already applies to `_selectedTableName` not being persisted today would suggest this *could* be in-memory-only too — but unlike table selection, a view choice per table is worth remembering across app restarts (Mike picking "Kanban" for one table is a standing preference, not a per-session accident), so it goes through the same `device_settings` mechanism sidebar-collapse state already uses, not `DeviceSettingsDao`-less in-memory `State`.
- **List view per-group collapse state** — `device_settings` key `list_collapsed_groups:{view_id}`, value = JSON array of collapsed group key values (mirrors `table_group`'s own doc-commented convention for sidebar groups). Expand-all writes `[]`; collapse-all writes every current group key. No `view_definitions.config` involvement, confirming the note added to the architecture doc yesterday.

### `ViewDefinitionsDao` (new) — sibling of `SchemaMetadataDao`

```dart
class ViewDefinitionsDao {
  Future<List<ViewDefinition>> loadViewsForTable(String tableName); // list/kanban views, ordered by position
  Future<ViewDefinition?> loadCalendarView();                       // the one table_name IS NULL row, if created
  Future<int> createView({required String? tableName, required String viewType, required String displayName, required Map<String, Object?> config});
  Future<void> renameView(int viewId, String displayName);
  Future<void> updateViewConfig(int viewId, Map<String, Object?> config);
  Future<void> reorderViews(String tableName, List<int> orderedViewIds);
  Future<void> softDeleteView(int viewId);
  Future<void> restoreView(int viewId);
}
```

Same soft-delete/restore shape as `SchemaMetadataDao.softDeleteTable`/`restoreTable` (`is_deleted` tombstone, never a hard delete from the app layer) and the same `INSERT OR REPLACE` upsert convention `TableViewSettingsDao` and `sql_helpers.dart`'s `SqliteCrdtHelpers.upsert` already use everywhere in this codebase.

---

## Nav / UI integration

**A view switcher becomes new chrome shared by all four screen types, not a `GenericListScreen`-only addition.** Since Grid, List, Calendar, and Kanban screens each own their own `Scaffold`/`AppBar` (per the "what the code already does today" finding above), the cleanest fit is a small shared widget — e.g. `ViewSwitcherBar`, rendered as each screen's `AppBar.bottom` (a `PreferredSize` row of tabs/chips) — rather than restructuring `HomeShell` to own a shared outer `Scaffold` that all four screens give up their own chrome to. This keeps every existing `GenericListScreen` AppBar action (column menu, filter, export CSV, etc.) exactly where it is today; the switcher is additive.

`ViewSwitcherBar` takes `tableName` + `currentViewId` (nullable → implicit Grid) + `onViewSelected`, loads that table's `view_definitions` rows via `ViewDefinitionsDao.loadViewsForTable` plus the always-present implicit "Grid" first tab, and renders them as a horizontal tab/chip row with a trailing "+" (opens a small "New View" dialog: pick type — List or Kanban only here, Calendar is the one aggregate surface reached separately, see below — plus a name) and a context menu per non-Grid tab for rename/delete, matching `manage_tables_screen.dart`'s existing interaction conventions rather than inventing new ones.

`HomeShell` needs one addition to its existing `selected`-table logic (`lib/screens/home_shell.dart` line ~479): alongside `_selectedTableName`, track `_selectedViewId` per table (restored from `device_settings` per the per-device state above), and switch which screen class it instantiates — `GenericListScreen` (`_selectedViewId == null`), `ListViewScreen`, or `KanbanViewScreen` — based on the resolved `view_definitions.view_type`. Calendar is reached as its own top-level nav destination (like the existing Search rail item, `_railSearchItem` at line ~537) rather than through any one table's switcher, since it isn't scoped to a table at all.

---

## Build order

Sequenced for lowest risk first, each step independently real-device-verifiable before the next, same discipline every prior phase's build-order section follows:

1. **`view_definitions` table + `ViewDefinitionsDao`** (migration_log-authored, both `essentials_app` and `server.dart` schemaStatements) — pure infra, nothing user-visible yet, safe to verify sync (create a view on MIKE-CU, confirm the row appears on MIKE-12R) before any UI exists.
2. **List view** — screen + config UI + `ViewSwitcherBar` (List is the only type needed to prove the switcher itself works, since Grid's tab is a no-op stub at this point). Includes the expand-all/collapse-all control confirmed 2026-08-25.
3. **Kanban view** — reuses `ViewSwitcherBar` unchanged, proves the switcher generalizes past one non-Grid type; new work is just the column-per-select-option board UI and the drag-to-`GenericDao.update()` interaction.
4. **View management polish** — reorder, rename, delete, once there's real multi-view usage to validate the UI against rather than designing it against zero real views.
5. **Calendar view** — last, because it's the one genuinely different shape (table-agnostic, needs the `table_definitions.calendar_field` migration first, needs its own top-level nav entry rather than living inside a table's switcher). Nothing above depends on it landing.

---

## Open questions / risks flagged, not resolved

- **`field_definitions` cascade on table delete** — confirm `SchemaMetadataDao.softDeleteTable` (or wherever table deletion is actually enforced) is extended to soft-delete that table's `view_definitions` rows too, or a deleted table's orphaned List/Kanban views will still enumerate in some future "all views" admin surface even though their table is gone. Flagged above, not verified against the current delete path this session.
- **`view_definitions` on the sync hub** — confirmed above that, unlike `search_index`, this table needs a real `server.dart` `schemaStatements` entry since it's shared/synced data. Double-check `server/bin/server.dart`'s existing list for the exact insertion convention before adding it — not re-read this session.
- **Field rename/delete touching a view's config** — a List/Kanban view's `config` stores raw field names (`primary_field`, `group_field`, etc.). If a field is renamed, `field_name` is immutable per `schema.sql`'s own convention so this is a non-issue; if a field is *deleted*, a view referencing it needs a defined fallback (same "never hide the record, never crash on bad field metadata" posture the architecture doc already commits Kanban to for unmatched select values) — worth a short explicit check when List/Kanban are actually built, not designed in full here since it's a straightforward extension of an already-decided posture.
