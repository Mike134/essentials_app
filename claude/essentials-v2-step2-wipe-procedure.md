> **Synced copy.** This file mirrors the claude.ai Project doc of the same name (Project: "Essentials"). The claude.ai Project is where I keep it updated across chat sessions; this repo copy is what Claude Code and any local tooling should read and trust for execution. Written to the repo 2026-08-22 after this exact gap caused Claude Code to correctly refuse to proceed on a destructive step — the doc was cited in code comments but never actually committed here. Keep both in sync going forward: when either copy changes, update the other in the same session.

---

# Essentials v2 — Step 2: Wipe & Rebuild Procedure

**Companion to:** `claude/essentials-v2-phase1-design.md` (build order step 2)
**Status:** Ready to execute. Bootstrap script written to `tool/bootstrap_fresh_db.dart`.
**Destructive.** Everything in `essentials.db` is deleted. Confirmed green-lit 2026-08-22.

---

## Blockers to fix BEFORE wiping

Two pieces of code assume the old schema exists. Both will fail on a fresh database. Fix them first, or the app won't launch after the wipe.

### 1. `DatabaseHelper._verifyRealSchema` — hard launch blocker

`lib/db/database_helper.dart` currently gates every launch on the `domain` table existing and having an `hlc` column:

```dart
final columns = await db.rawQuery("PRAGMA table_info('domain')");
final hasDomainTable = columns.isNotEmpty;
final hasHlcColumn = columns.any((c) => c['name'] == 'hlc');
if (!hasDomainTable) { throw StateError('... missing the domain table ...'); }
```

After the wipe there is no `domain` table — it's a business table, and business tables no longer exist until Mike creates them. **The app would throw on startup, on both platforms, every launch.**

The guard itself is still worth keeping — it exists because of two real empty-db-propagation incidents (CLAUDE.md), and those risks don't go away. It just needs repointing at a table that survives the clean slate. `table_definitions` is the natural marker: it's created by the bootstrap, it's never user-deletable, and its presence means "this file has been through v2 bootstrap," which is exactly what the check is trying to establish.

```dart
final columns = await db.rawQuery("PRAGMA table_info('table_definitions')");
final hasMetadataTable = columns.isNotEmpty;
final hasHlcColumn = columns.any((c) => c['name'] == 'hlc');
```

Both error messages need rewording too — they currently name `domain`, `migrations/004`, and Syncthing, none of which is the right diagnosis anymore. New guidance should point at `tool/bootstrap_fresh_db.dart`.

### 2. `server/bin/server.dart` — `schemaStatements`

Currently bootstraps all 19 business tables plus infra. After Phase 1 it should bootstrap **only** the infra tables — business tables reach the hub the same way they reach any device, by replaying `migration_log`.

Replace the whole `schemaStatements` list with the `infraSchemaStatements` list from `tool/bootstrap_fresh_db.dart`, byte-for-byte. Keep them identical going forward, and say so in a comment — same duplication convention the project already uses for `safeChangesetBuilder` and `splitSqlStatements` across package boundaries.

Notable deletions from the current list: every business table, every `CREATE INDEX`, and `field_metadata` (superseded by `field_definitions`). Notable change: `migration_log.id` moves from `AUTOINCREMENT` to the timestamp+random default.

`createSchema()` itself is unchanged — it already runs each statement through `db.execute` on a `CrdtTableExecutor`, which is the correct path (lets the rewrite append the CRDT columns rather than declaring them, matching the spike finding).

### 3. Lower priority, but will break loudly

- `lib/config/table_configs.dart` and `table_registry.dart` — hand-written configs for tables that no longer exist. Delete.
- `lib/db/field_metadata_dao.dart` + `lib/screens/field_metadata_screen.dart` — `field_metadata` no longer exists. Delete.
- `lib/db/orphan_cleanup_service.dart` — reads `field_metadata`. Delete or repoint.
- `tool/seed_field_metadata_*.dart` (4 files) — one-time seeds for a table that's gone. Delete.
- `lib/screens/order_split_pane_screen.dart` — hardcoded to `orders`/`order_items`. Keep the file if the pattern is wanted later, but it can't be wired to anything until Mike recreates those tables.

---

## Procedure

Order matters. The server must come up on the new schema before either device connects, or a device carrying old-schema data will try to merge into a hub that no longer has those tables.

**1. Stop everything.**
- MIKE-CU: close `essentials_app`.
- MIKE-12R: force-stop the app (Settings → Apps → essentials_app → Force stop — the battery-optimization exemption means it can keep syncing in the background otherwise).
- MIKE-CU: exit the server from its system tray.

**2. Back up all three copies.** Not optional, even though the data is expendable — a backup is the difference between "re-import the CSVs" and "reconstruct from memory" if something about the new schema turns out wrong on the first try.
- `C:\Databases\essentials_app\essentials.db` (+ `-wal`, `-shm`)
- `C:\Databases\essentials_app\server\hub.db` (+ sidecars)
- MIKE-12R's copy via `adb pull` (pull the `-wal`/`-shm` too — a recent write can sit uncheckpointed in the WAL; this bit the project once already)

**3. Apply the code fixes above**, at minimum `DatabaseHelper._verifyRealSchema` and `server.dart`'s `schemaStatements`. Rebuild `server.exe`.

**4. Rebuild the hub.** Delete `hub.db` and its sidecars, then start the server — `SqliteCrdt.open(dbPath, version: 1, onCreate: createSchema)` recreates it from the new `schemaStatements`. Confirm the console shows the new hub node id and no migration errors.

**5. Rebuild MIKE-CU's database.**
```
dart run tool/bootstrap_fresh_db.dart --out C:\Databases\essentials_app\essentials.db --force
```
Expect `BOOTSTRAP OK` and an `OK` line for all 10 tables, each confirming the four CRDT columns landed. If any line says `FAIL`, stop — do not launch the app against that file.

**6. Rebuild MIKE-12R's database.** Create a separate copy locally *with a fresh node id*, then push it:
```
dart run tool/bootstrap_fresh_db.dart --out .\mike-12r-essentials.db --reset-node-id
adb push .\mike-12r-essentials.db /storage/emulated/0/Databases/essentials_app/essentials.db
```
`--reset-node-id` is not optional. Two devices sharing a node id makes `crdt_sync`'s handshake believe MIKE-12R already has everything MIKE-CU ever wrote, and the server silently never sends it — a real, silent non-propagation bug, documented in CLAUDE.md from when it was caught live. Also delete any stale `-wal`/`-shm` on the device alongside the old file.

**7. Launch and verify.**
- MIKE-CU app launches without the schema guard throwing.
- Nav is empty — no tables. This is correct, not a failure.
- MIKE-12R launches, connects to the hub, no merge errors in the server console.
- Both devices' `PRAGMA integrity_check` clean.

---

## What "done" looks like

`essentials.db` contains exactly ten tables — `android_metadata`, `table_definitions`, `field_definitions`, `table_column_settings`, `table_view_settings`, `app_settings`, `device_settings`, `table_group`, `migration_log`, `migration_status` — each with the four CRDT bookkeeping columns appended, and zero rows in all of them. Same on `hub.db`. Same on MIKE-12R, with a different node id.

Nothing else. No `domain`, no `subscription`, no `journal`, no `field_metadata`, no indexes, no views.

After this, step 3 (`SchemaEditorService.createTable` / `addField`) has a clean foundation to build on, and step 5's checkpoint — create a table by hand, watch it sync — becomes the first real proof the engine works.

---

## Note on `schema.sql`

**Decided 2026-08-22: rewritten.** `schema.sql` now documents the ten infra tables only, keeping its stated role as the design-side record of the live schema rather than drifting into being silently wrong. The 19 business tables' old DDL stays recoverable in git history if it's useful while recreating one by hand.

Its header now also carries the two rules that are easy to get wrong and expensive to rediscover: that the file must not be hand-run in Letos against a new database (it has to go through `SqliteCrdt.open()` so the rewrite appends the bookkeeping columns), and that the four CRDT columns are deliberately not declared in it.
