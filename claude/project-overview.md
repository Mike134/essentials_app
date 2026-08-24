> **Source of truth: this repo file.** As of 2026-08-24, this project stopped mirroring design docs into a claude.ai Project doc -- Mike is always on the desktop app, so a claude.ai/Cowork session can read this file directly (via the device bridge) whenever it needs it, and Claude Code always reads it locally. Maintaining two full copies was pure duplicated effort with no real benefit. The claude.ai Project now keeps a single short pointer doc (`claude/project-overview.md`, the Project's own trimmed copy) instead of a full mirror of every doc -- see that doc's note for the one edge case (a browser/mobile session, no desktop app connected) this doesn't cover.

---

# Essentials Project — Overview

## What it is

A personal data management Flutter app replacing Memento Database. Single Dart codebase compiling natively to **Windows desktop** and **Android**. Local SQLite backend, synced across devices via `sqlite_crdt`/`crdt_sync` (record-level sync over Wi-Fi) with a lightweight Dart server acting as the sync hub.

**Why Flutter:** Single codebase → Windows + Android. Direct `.db` file access via `sqflite`/`sqflite_common_ffi`. No server dependency for the data itself.

---

## Key File Locations

| What | Where |
|------|-------|
| Flutter project root + CLAUDE.md + schema.sql | `C:\Flutter\essentials_app` |
| Live database | `C:\Databases\essentials_app\essentials.db` |
| Sync server hub db | `C:\Databases\essentials_app\server\hub.db` |
| Old design files (retired, historical only) | `C:\Users\Mike\OneDrive\Documents\Essentials` |
| GitHub repo | private, "essentials_app" |

The database is **deliberately outside OneDrive** — Flutter builds generate churning files that fight with OneDrive sync.

---

## Devices

- **MIKE-CU** — Windows desktop (primary dev machine)
- **MIKE-12R** — OnePlus 12R, Android 16/API 36 (CPH2611)
- **MIKE-LP / MIKE-WP** — exist but not yet onboarded to the app

Android dev connection: wireless adb via Android 11+ "Wireless debugging" (Settings → Developer options → Wireless debugging → Pair device). Does not survive phone reboot — re-pair after each reboot.

---

## Tools

- **Flutter SDK 3.44.6** at `C:\src\flutter`
- **VS Code** with Flutter/Dart extensions — owns the hot-reload loop (`F5`). Claude Code cannot run `flutter run` (non-interactive shell).
- **Claude Code** (Code tab in Claude Desktop, pointed at `C:\Flutter\essentials_app`) — file editing, one-shot commands (`flutter build`, `flutter analyze`, `flutter test`). **Cannot do interactive hot-reload.**
- **Letos** (primary) + **DBeaver Community** (secondary) — SQLite browser/editor
- **GitHub Desktop** — day-to-day commits/push/pull
- **schema_admin** — separate Flutter project at `C:\Flutter\essentials_app\schema_admin\`, used to author and deploy schema migrations

---

## Database Schema

Full DDL is authoritative in `C:\Flutter\essentials_app\schema.sql`.

**As of the Essentials v2 clean-slate rebuild (2026-08-22), this section is historical.** `schema.sql` now documents only ten infra/bookkeeping tables. The 19 business tables named below no longer exist in the live schema and are not recreated automatically — see `claude/essentials-v2-architecture.md` and `claude/essentials-v2-phase1-design.md` for the current model (user-created tables via `table_definitions`/`field_definitions`).

**Lookup tables (14):** `domain`, `priority`, `gender`, `status`, `quality`, `condition`, `unit`, `importance`, `disposition`, `time_frame`, `class`, `category`, `account_type` + `account`

**Entity tables:** `supplier`, `shipper`, `person`, `shipment`, `subscription`, `journal`, `orders`, `order_items`

**View:** `subscription_computed` — computes `yearly_cost` and `next_date` at query time; never stored

**Settings/persistence tables:** `table_column_settings`, `table_view_settings`, `app_settings`, `device_settings`, `field_metadata`, `table_group`

**Migration system tables:** `migration_log`, `migration_status`

### ID convention
- Lookup tables: `INTEGER PRIMARY KEY AUTOINCREMENT`
- Entity tables (`journal`, `shipment`, `subscription`, `orders`, `order_items`): timestamp+random default — `id INTEGER PRIMARY KEY DEFAULT (CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000 + (abs(random()) % 1000))` — no AUTOINCREMENT, no cross-device collision risk

### CRDT bookkeeping columns (every table)
`is_deleted INTEGER DEFAULT 0`, `hlc TEXT NOT NULL`, `node_id TEXT NOT NULL`, `modified TEXT NOT NULL` — added via migrations 004/005. All DELETEs are soft-deletes (rewritten by `crdt.execute()`); ON DELETE RESTRICT/CASCADE in DDL is documentary only, enforcement is at app layer.

---

## Architecture

- **Generic CRUD:** `TableConfig`-driven — one `GenericListScreen` + `GenericFormScreen` pair handles all 19 tables. No hand-written per-table screens.
- **Grid:** TrinaGrid (`trina_grid` package — maintained fork of PlutoGrid). shadcn_ui must be a direct dependency (pulled transitively by trina_grid; without a `ShadTheme` ancestor, popups render blank).
- **Table Discovery:** `TableDiscoveryService` introspects SQLite `sqlite_master` at launch — no hand-written `TableConfig` entries needed for a new table after it's created.
- **Navigation:** Hand-rolled scrollable rail (not Flutter's `NavigationRail`, which can't scroll) on wide layouts; Drawer on Android.
- **Sync:** `sqlite_crdt` + custom `crdt_sync` server (`server.dart`). Key fix: `safeChangesetBuilder` drops the watermark (`modifiedAfter`) on the catch-up pull at every reconnect, sending the full dataset — prevents the global-watermark-race bug where frequent `table_column_settings` writes permanently strand slower-moving table edits.
- **Sync hub server:** Runs as a system-tray-hosted background process on MIKE-CU (VBS → PowerShell tray host → `server.exe` as hidden child). Auto-starts at login via Startup folder shortcut.
- **Periodic reconnect:** `SyncService` forces a disconnect+reconnect every 5 minutes, providing a guaranteed retry window for any merge that failed on connect.
- **device_id:** Windows uses `Platform.localHostname` (dart:io). Android uses a `MethodChannel` reading `Settings.Global.DEVICE_NAME` from `MainActivity.kt` — the user-set name (`MIKE-12R`), not a generic value.

---

## Schema Migration System

`schema_admin` (separate Flutter project) authors migrations to `migration_log` (via `essentials.db`, which syncs to all devices). `essentials_app` and `server/` each self-apply pending `migration_log` entries on launch/reconnect, recording outcome in `migration_status` per device. Ordering guarantee enforced — a failed migration halts subsequent ones until retracted via `is_deleted`. Migrations reach `server/` via a plain-HTTP side-channel (bypasses crdt_sync's all-or-nothing batch, which would strand a device that fell behind).

---

## Grid Features (all in GenericListScreen)

- Column widths, order, sort, filter, frozen/visible state — per-device, persisted to `table_column_settings`/`table_view_settings`
- Inline lookup-field editing (TrinaColumnType.select keyed on FK ids)
- Copy record (pre-fills new form from selected row, id excluded)
- Row grouping ("Group by this column") — TrinaGrid native, persisted as `group_column`
- Filter by value — dropdown of display options for lookup columns
- Footer aggregates (sum/average/min/max/count) on numeric columns — persisted as `aggregate`
- Export to CSV — current view, display values, hidden columns skipped
- Row coloring ("Use Color") — per-device, one color-source column at a time (`row_color_column`)
- Right-align numeric columns; scrollbar thickness 12.0

### Known sqlite_crdt upsert rule
Never DELETE + INSERT for a table managed by sqlite_crdt — DELETE is a tombstone, INSERT then fails UNIQUE. Always use `INSERT OR REPLACE` (upsert) per row, then delete only stale rows by column_name NOT IN (...).

---

## Governing Rule for Persisted State

| Bucket | Examples | Storage |
|--------|----------|---------|
| **Shared** (same on every device) | Theme, font, field labels/defaults, sidebar group membership | `essentials.db` — no `device_id` |
| **Per-device** (this screen, this hardware) | Column widths/order/sort/filter/frozen/visible, sidebar collapse state, row color column, group column | `essentials.db` with `device_id` column |

`device_id` = OS hostname, queried live at runtime.

---

## Current Status (as of last Claude Code session)

All 19 tables built and verified on Windows and Android. Sync fully operational (bidirectional, live-verified). Schema admin/migration system built and end-to-end verified. Six grid features added and verified. Two debugging sessions completed covering real bugs found in actual usage. Server running as system tray process. FieldMetadataScreen and AddColumnScreen built.

**Superseded 2026-08-22 by the Essentials v2 clean-slate rebuild** — see `claude/essentials-v2-architecture.md`, `claude/essentials-v2-phase1-design.md`, and `claude/essentials-v2-step2-wipe-procedure.md`. The 19-table status above describes the pre-rebuild state, kept for history.

**Open / deferred:**
- MIKE-LP and MIKE-WP onboarding — deliberately deferred until the app has more real usage
- `Essentials.xlsx` is retired; `migrate.py` is retired. All new data goes directly into `essentials.db` via Letos/CSV import.
- Orders/OrderItems: built and verified, but the original Excel data was never migrated in; data entry through the app is the path forward.

---

## New Table Checklist (quick reference)

**Superseded 2026-08-22.** This manual, multi-device checklist described the v1 workflow. In v2, table creation goes through the app's own New Table UI and propagates via `migration_log` automatically — see `claude/essentials-v2-phase1-design.md`. Kept below for history only.

1. Design schema (timestamp+random id for entity tables, AUTOINCREMENT for lookup tables)
2. Close `essentials_app` on every device (leave server running)
3. Run `CREATE TABLE` in Letos against MIKE-CU's `essentials.db` (includes the 4 CRDT columns)
4. Add to `schema.sql`
5. Run same statement on MIKE-12R via SQLite Pro (or `adb pull` → `sqlite3` → `adb push` if SQLite Pro doesn't persist)
6. Run against `server/hub.db` in Letos/DBeaver
7. Add to `server.dart`'s `schemaStatements` list and commit
8. Reopen `essentials_app` on all devices

## Add Column Checklist

**Superseded 2026-08-22** — same reason as above. Kept for history only.

Use Settings → "Add a column" from inside a running `essentials_app` on one device, then apply the resulting `ALTER TABLE` statement to every other device's db and to `server/hub.db`, and add it to `server.dart`'s `schemaStatements`.

---

## CLAUDE.md

The authoritative, full project reference is `C:\Flutter\essentials_app\CLAUDE.md` (3,872 lines). Every decision, session write-up, known issue, and operational procedure lives there. This document is a condensed orientation summary — go to CLAUDE.md for the full rationale and history.
