> **Source of truth: this repo file.** No claude.ai Project mirror is kept — Claude Code reads this directly; a claude.ai/Cowork session reads it live via the desktop-app device bridge when connected. See `claude/project-overview.md` for the file index.

---

# Essentials v2 — Phase 6: Global Search

**Session date:** 2026-08-24
**Status:** Design, grounded in a read of the live codebase (`lib/db/generic_dao.dart`, `lib/db/sync_service.dart`, `lib/db/migration_service.dart`, `lib/db/database_helper.dart`, `lib/db/schema_editor_service.dart`, `lib/db/schema_registry.dart`, `lib/screens/home_shell.dart`) — same discipline every prior phase followed. **Two scope calls confirmed 2026-08-24**, see below. **Prepared while Phase 4 is still executing in Claude Code** — this design doesn't depend on Phase 4 landing first (see "Field scope" below), so it's safe to build whenever Phase 4 wraps, in either order relative to Phase 4's own real-device verification.
**Companion docs:** `claude/essentials-v2-architecture.md` (the Phase 6 roadmap entry and "Roadmap sequencing"'s reasoning for why Search comes before Scripts), `claude/essentials-v2-phase1-design.md` (the `migration_log`/`MigrationService` self-apply pipeline this reuses for the index table's own creation)

---

## Confirmed decisions (2026-08-24, before handoff to Claude Code)

The architecture doc's own "Open Decisions" section explicitly left "Global search strategy — FTS5 per-table virtual tables vs. unified search index" unresolved. Both real judgment calls, confirmed before implementation:

- **One unified FTS5 virtual table across every user table**, not one per table. A dynamic, user-editable schema (fields added/removed/reformatted at any time through `AddFieldScreen`/`ManageFieldsScreen`, no code change) is a bad fit for per-table FTS5 — every field add/remove/format change on a searchable field would need its own `migration_log`-authored `DROP`/`CREATE VIRTUAL TABLE` to keep that table's index column set current, real ongoing maintenance burden no other feature in this schema engine carries. A unified index sidesteps this entirely: it's schema-shape-agnostic (`table_name`, `record_id`, `content` — never needs a migration when a field changes), and a reindex just picks up whatever fields currently exist.
- **First pass indexes plain stored text only** — `text`/`text_multiline`/`url`/`barcode`/`link_file` (anything whose real stored value is free text) — not resolved `select`/`link_record`/`lookup` display values. This is what keeps Phase 6 independent of Phase 4's completion/verification status: searching "Acme" finds a `supplier` record named Acme, not an `order` that merely links to it. Extending search to also index resolved link/lookup display text is a natural, low-risk follow-up once Phase 4 is real-device verified — not attempted now, not blocking now.

---

## What the code already does today (verified by reading it)

| Capability | Where | Relevance |
|---|---|---|
| Every local write funnels through one class | `GenericDao.insert`/`update`/`delete` (`lib/db/generic_dao.dart`) — every screen goes through this, no table-specific subclassing | The natural, already-proven choke point to hook "reindex this record" for anything entered on *this* device. |
| Reactive notification when **remote** data changes | `SyncService.dataChanges` — `Stream<Set<String>>`, fires with the set of table names an incoming changeset touched, *before* the merge is visibly committed (fire first, listeners debounce a short beat — see that stream's own doc comment). `GenericListScreen` already subscribes to it to live-reload its grid. | **This is the answer to "how does search stay current with data synced in from another device without SQL triggers."** No triggers exist anywhere in this codebase today (confirmed by grep — every "trigger" match in `lib/` is the English word in a doc comment, never `CREATE TRIGGER`), and this project has already established, for a structurally similar problem (`ON DELETE CASCADE` never firing because `crdt.execute()` rewrites every DELETE into a soft-delete UPDATE — see `claude/essentials-v2-phase1-design.md`'s "Critical risks" #3), that relying on real SQL side-effects to react to CRDT-merged writes is exactly the kind of thing that quietly doesn't fire the way you'd expect. `SyncService.dataChanges` is this app's own already-proven, explicit-Dart-code answer to "something changed remotely, go re-derive the thing that depends on it" — reuse it rather than reach for triggers a second time. |
| Arbitrary DDL propagates to every device automatically | `migration_log` + `MigrationService.applyPending` (`lib/db/schema_editor_service.dart`'s `_insertMigrationLog`, `lib/db/migration_service.dart`) | The index table's own `CREATE VIRTUAL TABLE` needs to exist on every device without Mike running SQL by hand anywhere — this pipeline already solves exactly that problem for user-table DDL; nothing about it is specific to *business* tables, it just runs whatever SQL text is in the row. |
| `PRAGMA journal_mode = WAL` / `PRAGMA foreign_keys = ON` run via `crdt.execute()` directly, not `crdt.upsert()` | `database_helper.dart` | Confirms `crdt.execute()` is a plain "run this SQL" pass-through for statements that aren't a business-table INSERT/UPDATE/DELETE — the CRDT row-rewriting (HLC/node_id splicing, DELETE→UPDATE) is conditional on the target, not universal. Relevant to whether writing into an FTS5 virtual table through `crdt.execute()` is safe — see the flagged unknown below. |

---

## Data model

### The index itself: `search_index`, a new infra table

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(
  table_name UNINDEXED,
  record_id UNINDEXED,
  content
);
```

Not one of the ten existing infra/bookkeeping tables `project-overview.md` lists (`table_column_settings`, `app_settings`, etc.) in the sense of being hand-added to `schema.sql` and requiring a per-device manual `ALTER`/`CREATE` — instead, created the *Phase-1 way*: one `migration_log` row, authored once (a small one-off script, or a narrow new `SchemaEditorService` method that inserts into `migration_log` **without** also writing a `table_definitions` row — this must not become a user-visible "table" in nav, unlike everything `createTable` produces today), then picked up automatically by the exact same `MigrationService.applyPending` every device already runs on launch/reconnect. No manual per-device SQL, no `server.dart` `schemaStatements` entry — the server's `hub.db` has no reason to carry this table at all; search is a per-device, client-only, fully-reconstructible-from-already-synced-data feature, not something that needs to exist on the sync hub.

**Never synced, deliberately.** `search_index` holds nothing that isn't already derived from other tables' own (synced) data — every device can independently rebuild its own copy from what it already has, so there's no reason to give it CRDT bookkeeping columns (`is_deleted`/`hlc`/`node_id`/`modified`) at all, and genuinely no clean way to: an FTS5 virtual table's row shape is fixed by its `USING fts5(...)` declaration, and bolting CRDT columns onto it isn't how FTS5 works. Written to directly via plain `INSERT`/`DELETE` against the virtual table — content, not a real business row, is derived and disposable.

### `SearchIndexService` (new)

```dart
class SearchIndexService {
  Future<void> reindexRecord(String tableName, int id);      // one row: delete then re-insert
  Future<void> removeFromIndex(String tableName, int id);     // one row: delete only
  Future<void> reindexTable(String tableName);                // whole table: delete-all then bulk re-insert
  Future<void> reindexAll();                                  // every table -- first-run bootstrap + manual "Rebuild search index" escape hatch
  Future<List<SearchResult>> search(String query, {int limit = 50});
}
```

`reindexRecord`/`reindexTable`/`reindexAll` all build `content` the same way: load the table's `TableConfig` (`SchemaRegistry.buildConfig`), take every field where `field.type == FieldType.text && !field.isColor` **or** `field.isLink` **or** the format is `link_file`/`barcode` (i.e. every plain-stored-text format per the confirmed scope above — explicitly *not* `isLookup`/`isInlineSelect`/`isLinkRecord`/`isFieldLookup`/`isRollup`, all of which are either a different storage shape or resolved/computed rather than raw text), and join their non-null values with a single space. One `search_index` row per record, `table_name`/`record_id` as plain columns, `content` as the searchable text.

### Reindex triggers — no SQL triggers, two explicit Dart hooks

1. **Local writes** — `GenericDao.insert` calls `SearchIndexService().reindexRecord(config.tableName, id)` right before returning the new id; `GenericDao.update` calls it after its `UPDATE` succeeds; `GenericDao.delete` calls `removeFromIndex` for the row itself, and — since its cascade pass (`_linkedFieldRefs`/`onDelete: 'cascade'`) bulk-deletes child rows by `WHERE column = ?1` without ever materializing their individual ids — calls `reindexTable` on each cascaded child table instead of trying to track which specific rows vanished. Same "don't know individual ids, reindex the whole table" fallback the remote path below already needs for a different reason, reused rather than inventing a second shape for it.
2. **Remote writes (synced in from another device)** — a new lightweight listener (owned by `SearchIndexService` itself, subscribed once, e.g. from `main.dart` alongside the existing app-wide setup) on `SyncService.dataChanges`: for every table name in the received set, call `reindexTable(name)`. No per-row granularity available from that stream (by design — see its own doc comment), so a full-table reindex is the correct, already-established response, not a shortcut.

**Known, accepted staleness gap:** a field's `format` changing (e.g. `text` → `integer` via `ManageFieldsScreen`, or a new field added to an existing table) touches only `field_definitions` metadata, not row data — no write to any *row* flows through either hook above, so a table's index can lag behind a pure schema change until its rows are next individually touched. Personal-scale, infrequent event, graceful degradation (stale results, not wrong/crashing ones) rather than a hard guarantee — same posture this codebase already takes elsewhere (`lookup`'s non-numeric-value skip, `lastConnectedAt`'s "best-effort... not an ironclad guarantee"). Mitigated by `reindexAll()` being exposed as a manual "Rebuild search index" action in `SettingsScreen`, not by trying to catch every metadata-change code path.

---

## Two things to verify against the actual installed packages before committing to this shape — same discipline column autocomplete's `trina_grid` check and Phase 4's `json_each` reliance both already used

1. **FTS5 must actually be compiled into the SQLite build `sqflite_common_ffi`/`sqlite_crdt` links against.** FTS5 is a compile-time SQLite option, not universal — confirm `CREATE VIRTUAL TABLE ... USING fts5(...)` succeeds on both a fresh Windows build and a fresh Android build before writing anything else against it. If it's missing on either platform, the fallback is a plain `LIKE '%term%'` scan across the same field set this design already identifies (slower, no ranking/snippet, but zero new dependency risk) — worth a quick spike first, not an assumption either way.
2. **Whether `crdt.execute()` cleanly passes through `INSERT`/`DELETE` against a virtual table with no CRDT bookkeeping columns**, per the `database_helper.dart` evidence above (`PRAGMA` statements already go through `crdt.execute()` untouched) — plausible from that evidence, not confirmed by reading `sqlite_crdt`'s own source. If it turns out `crdt.execute()` unconditionally expects `is_deleted`/`hlc`/`node_id`/`modified` on *any* table it touches, `SearchIndexService` should open its own plain `sqflite`/FFI connection to the same database file for `search_index` reads/writes specifically, bypassing the CRDT wrapper entirely for this one local-only table — a small, contained change if needed, not a redesign.

---

## Search UI

New `SearchScreen`, reached via a search icon in `HomeShell`'s nav rail (Windows) / drawer (Android) — same placement pattern `SettingsScreen`/`ManageTablesScreen` already use, nothing new to invent there. Live search-as-you-type, same ~200ms debounce convention column autocomplete already established for this app's voice, rather than a submit button.

Results grouped by table (per the architecture doc's own spec), each group headed by that table's `display_name` (resolved the same lightweight way Phase 4's reverse-relation panel already resolves a table name to a label — reuse rather than duplicate), each row showing an FTS5 `snippet()` of the match in context (`snippet(search_index, 2, '**', '**', '…', 10)` — column index 2 is `content`) and, on tap, opens that record's `GenericFormScreen` the same way every other "tap a row to edit it" path in this app already does (`GenericListScreen`'s own row-tap, Phase 4's reverse-relation panel) — reuse the existing navigation, don't build a second one.

`search_index.record_id` is enough to open the record directly (`SchemaRegistry.buildConfig(tableName)` + `GenericDao(config)` + the id) without needing to re-run the table's own `getAll()`/full grid load first.

---

## Explicitly out of scope for this pass

- **Indexing resolved `select`/`link_record`/`lookup` display values** — confirmed deferred above; natural follow-up once Phase 4 is verified, not coupled to it now.
- **Fuzzy/typo-tolerant matching** — FTS5's own default tokenizer (plain `unicode61` or `porter` stemming, whichever Claude Code finds gives the more natural feel for short personal-data values — worth a quick empirical check rather than assuming) is the extent of "smart" matching in this pass; no separate fuzzy-match library.
- **Search across `migration_log`/infra tables themselves** — this indexes user business tables only (whatever `SchemaRegistry.discoverTableNames()` returns), not the app's own bookkeeping tables.
- **Ranking beyond FTS5's own built-in `rank`** — no custom relevance scoring (recency weighting, field-importance weighting, etc.) in this pass.
- **A dedicated `search_index` entry in `server.dart`'s `schemaStatements`** — deliberately never added; see "Data model" above for why the hub doesn't need this table at all.

---

## Suggested build order

1. **Verify the two flagged unknowns first** (FTS5 availability on both platforms, `crdt.execute()` behavior against the virtual table) — cheap spikes, and they decide real shape (plain FTS5 vs. `LIKE` fallback; wrapped `crdt.execute()` vs. a bypass connection) before anything else is worth building against.
2. **`search_index` table creation** via the one-off `migration_log` row + (if needed) the narrow new `SchemaEditorService` helper that inserts `migration_log` without a `table_definitions` row.
3. **`SearchIndexService`** — `reindexRecord`/`removeFromIndex`/`reindexTable`/`reindexAll`/`search`. Unit tests: content built correctly from a mixed-format table (only the confirmed-eligible formats included), reindexing is idempotent (delete-then-insert, no duplicate rows on a second call), `search` returns the right `(table_name, record_id)` pairs for a known query, an empty/whitespace query returns nothing rather than everything.
4. **Wire the two reindex hooks** — `GenericDao.insert`/`update`/`delete` (including the cascade-child full-table-reindex case), and the new `SyncService.dataChanges` listener. Unit/integration tests: a local insert becomes searchable immediately; a simulated incoming changeset (same shape `GenericListScreen`'s own `dataChanges` test coverage, if any exists, already uses) triggers a reindex of the right table.
5. **`SettingsScreen`**'s manual "Rebuild search index" action (`reindexAll()`), for the known metadata-staleness gap above.
6. **`SearchScreen`** — nav entry point, live debounced search, grouped results, snippet rendering, tap-to-open.
7. Build-verify at every step (`flutter analyze`, `flutter build windows`/`apk --debug`, unit tests) — then Mike's real-device pass on MIKE-CU and MIKE-12R, same "code builds and verifies, Mike tests" agreement every prior phase used. Worth specifically testing the remote-reindex path live (edit a record on one device, confirm it's searchable on the other within one reconnect cycle) — that's the one behavior no unit test can fully stand in for.

**Model tier:** step 1's two spikes and step 4's dual reindex-trigger wiring are where a wrong assumption would be expensive to unwind later (same class of risk Phase 4's referential-integrity SQL and Phase 2's formula evaluator were judged to need Opus for) — worth the same tier there. Steps 2, 3, 5, 6 are routine schema-engine/UI/DAO follow-through in the shape Sonnet has already handled repeatedly across every prior phase. Confirm this split with Mike before kicking off the build, same as every prior phase.
